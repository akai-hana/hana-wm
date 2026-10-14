//! Bar visibility: policy + wire glue.
//!
//! Two halves in one file, policy first:
//!
//!   1. POLICY — every decision about when the bar is shown/hidden
//!      (fullscreen-occupancy reactions, workspace-scoped recomputation,
//!      prompt forced-show/undo, the shared-screen predicate) as pure
//!      computations over the core model. The model is a parameter, so every
//!      decision is a pure function of what the caller handed in; the policy
//!      itself issues NO X11 requests and imports no pipeline.
//!   2. WIRE GLUE — the apply* family (plus the prompt's present/dismiss
//!      pair) that turns those decisions into X11 map/unmap + screen-claim
//!      writes and the reconcile that reacts to a claim change. All wire
//!      tokens live in this half (see the check-layers.sh allowlist entry).
//!
//! (Formerly split into `visibility.zig` + `visibility_glue.zig`; the split
//! was policy-vs-application, not a cycle — the glue imported the policy
//! one-way — so the two halves were merged back 2026-10-09 as one
//! "bar visibility" unit. The host state (`State`, `gBar`) lives in
//! `state.zig` and the draw submission in `repaint.zig`; this file reads
//! state through that leaf and never imports `bar.zig` back.)

const build_options = @import("build_options");
const model = @import("model");
const core = @import("core");
const xcb = core.xcb;
const log = @import("log");
const query = @import("query");
const pipeline = @import("pipeline");
const usable_area = @import("usable_area");
const segmod = @import("segment");

const state = @import("state");
const repaint = @import("repaint");
const State = state.State;

// ---------------------------------------------------------------------------
// Policy (pure): decisions over the model, no wire.
// ---------------------------------------------------------------------------

/// True when a fullscreen window on `ws` forces the bar hidden (shared-screen
/// reaction). Compile-time folded when the fullscreen module is absent: the
/// model read is comptime-unreachable, matching the inlined guards that used
/// to live at each decision site.
/// `m` is the model the decision is made AGAINST, passed in rather than
/// reached for through pipeline. visibility.zig no longer imports the pipeline
/// at all, so a decision can no longer be computed against a model that is not
/// the one its caller is about to act on -- the two used to be reached
/// independently, and the bar's own comment noted the dependency was the only
/// thing keeping the partition honest.
pub fn barForcedHiddenByFullscreen(m: *const model.Model, ws: u8) bool {
    return if (build_options.has_fullscreen)
        model.coveringOccupantOnWs(m, model.WSId.fromIndex(ws)) != null
    else
        false;
}

/// The core shared-screen predicate: the bar is shown only when the user
/// wants it visible AND no fullscreen window on the workspace claims the
/// screen (fullscreen coverage and the user toggle both keep it hidden).
pub fn shouldBeVisible(is_globally_visible: bool, forced_hidden_by_fullscreen: bool) bool {
    return !forced_hidden_by_fullscreen and is_globally_visible;
}

/// Why the bar wants the visibility it wants.
pub const Reason = enum {
    /// The user toggle and the current workspace both want the bar shown.
    user_and_workspace,
    /// The user turned the bar off.
    user_hidden,
    /// A fullscreen window on this workspace claims the whole screen.
    fullscreen_claims_screen,
};

const DesiredVisibility = struct {
    should_be_visible: bool,
    reason: Reason,
};

/// The pre-computed show/hide decision shared by the workspace-switch path
/// (`updateBarVisibilityForWorkspace`) and the fullscreen-fact reaction
/// (`applyFullscreenVisibility`): recompute the desired visibility from the
/// workspace + user level. The POLICY states the target and why; COMPARING
/// that target against the bar's currently mapped state belongs to the
/// orchestrator, because that comparison reads live window state and is
/// the thing that decides whether any wire request happens.
///
/// `is_visible` (the bar's mapped state) is deliberately NOT a parameter.
/// `desiredVisibility` used to take it and return `needs_change`, making one
/// function both the policy and the comparator, so the bar then early-returned
/// on a field the policy had already folded in. Asking the policy for the
/// target and reason, and letting the caller compare, is one step instead of
/// two and keeps the mapped state at the one place that can see it.
pub fn desiredVisibility(m: *const model.Model, ws: u8, is_globally_visible: bool) DesiredVisibility {
    // Short-circuit the model walk when the user toggle already hides the bar:
    // `shouldBeVisible` ignores `forced_hidden` on that row of its truth table,
    // so reading the fullscreen occupant there could only produce a reason the
    // caller never asks for (user_hidden wins by definition).
    const forced_hidden = is_globally_visible and barForcedHiddenByFullscreen(m, ws);
    return .{
        .should_be_visible = shouldBeVisible(is_globally_visible, forced_hidden),
        .reason = if (!is_globally_visible)
            Reason.user_hidden
        else if (forced_hidden)
            Reason.fullscreen_claims_screen
        else
            Reason.user_and_workspace,
    };
}

/// Decision for `dismissAfterPrompt`: whether the prompt's forced-show
/// override should be kept because the bar IS shown at its natural, freshly
/// recomputed visibility. The prompt can outlive the state that justified the
/// override (e.g. the fullscreen window closes on its own), so this is
/// recomputed from the CURRENT workspace at prompt-exit time rather than
/// trusting the decision made at activation. One decision function, not a
/// second hand-rolled fold of the same two inputs.
pub fn keepPromptOverride(m: *const model.Model, ws: u8, is_globally_visible: bool) bool {
    return desiredVisibility(m, ws, is_globally_visible).should_be_visible;
}

// ---------------------------------------------------------------------------
// Wire glue: apply* family + prompt present/dismiss. All X traffic lives
// below this line (check-layers.sh Rule-1 allowlist).
// ---------------------------------------------------------------------------

/// Pushes the bar's current screen-space claim to core.screen. Called
/// at each point where the bar's occupancy of the screen changes
/// (visibility toggle, edge/position change) immediately before the
/// reconcile that re-derives window placement from the new usable
/// area. Core owns the area math; the bar only contributes "I take
/// this many pixels from this edge."
pub fn syncScreenClaim() void {
    const s = state.gBar.state orelse return;
    const cs = core.getState();
    const edge: usable_area.Edge = if (cs.config.bar.bar_position == .bottom) .bottom else .top;
    const px: u16 = if (s.vis.shown) s.render.height else 0;
    usable_area.setClaim(edge, px);
}

pub fn raiseBar() void {
    if (state.gBar.state) |s|
        _ = xcb.xcb_configure_window(
            s.win.conn,
            s.win.win_id,
            xcb.XCB_CONFIG_WINDOW_STACK_MODE,
            &[_]u32{xcb.XCB_STACK_MODE_ABOVE},
        );
}

/// Forces the bar to the absolute top of the stacking order and guarantees it
/// is mapped, overriding whatever would normally keep it hidden or covered:
/// a fullscreen window, the user toggling the bar off, or another window
/// raised above it. Used by the inline prompt (prompt.zig) so it is always
/// visible and reachable while active.
///
/// Never touches window geometry or retiles: the bar overlays whatever is
/// already there (fullscreen included), the way a dock/OSD overlays fullscreen
/// video. Pair with `dismissAfterPrompt` so the bar returns to its prior state.
pub fn presentForPrompt() void {
    const s = state.gBar.state orelse return;
    if (!s.vis.shown) {
        // The bar is hidden; map it before drawing so the blit lands in a
        // mapped window (a draw queued while unmapped is discarded by the
        // server, leaving a blank bar until the next unrelated redraw) and a
        // compositor never presents an empty frame.
        state.gBar.prompt_forced_visible = true;
        s.vis.shown = true;
        segmod.runVoidHook(.onBarShown);
        _ = xcb.xcb_map_window(s.win.conn, s.win.win_id);
        repaint.submitDrawBlockingFull();
    }
    raiseBar();
    _ = xcb.xcb_flush(s.win.conn);
}

/// Undoes `presentForPrompt` once the prompt exits (entered or cancelled).
///
/// If the bar was shown solely to make the prompt visible, hides it again,
/// but only if it *should still* be hidden. The prompt can outlive the state
/// that justified the override (e.g. the fullscreen window closes on its own),
/// so this recomputes the bar's natural visibility at exit time rather than
/// trusting the decision made at activation.
///
/// If the bar was already visible, this leaves it as-is: the forced
/// top-of-stack position needs no explicit undo, since focusing any other
/// window already raises it above the bar again (see focus.zig).
pub fn dismissAfterPrompt() void {
    const s = state.gBar.state orelse return;
    if (!state.gBar.prompt_forced_visible) return;
    state.gBar.prompt_forced_visible = false;
    const current_ws = query.getCurrentWorkspace() orelse 0;
    const should_show = keepPromptOverride(pipeline.model(), current_ws, s.vis.preferred);
    if (should_show) return; // conditions changed while the prompt was open; stay visible
    s.vis.shown = false;
    _ = xcb.xcb_unmap_window(s.win.conn, s.win.win_id);
    _ = xcb.xcb_flush(s.win.conn);
}

/// Applies a decided visibility change: updates `vis.shown`, draws when
/// shown, maps/unmaps, and re-derives the screen claim. `do_reconcile`
/// additionally grabs the server, reconciles (the usable area changed with
/// the claim) and flushes -- used by the fullscreen-fact reaction path, not
/// by the workspace-switch path whose caller runs its own reconcile. The
/// reconcile-show path also re-raises the bar LAST (inside the same flush,
/// after the reconcile's geometry sends), so a moved winner that got raised
/// above it (sync raises a placing winner on motion even without
/// force_restack) cannot leave a freshly shown bar buried under the window
/// it just stopped covering.
fn applyVisibility(s: *State, should_be_visible: bool, do_reconcile: bool) void {
    s.vis.shown = should_be_visible;
    const conn = core.getState().conn;
    // Optional token: the workspace-switch path (do_reconcile false) must NOT
    // grab, and the conditional used to be two hand-matched sites (grab here,
    // ungrabAndFlush at the bottom) that a new early return could unpair.
    // Publish the claim BEFORE the grab, because `grabScoped` snapshots the
    // reconcile ctx and the ctx carries `usable_area.workArea`. Claiming after
    // the snapshot meant the reconcile that reacted to the claim change
    // re-derived geometry from the workarea it was about to invalidate: on
    // fullscreen exit the bar came back and took its pixels while the windows
    // were re-tiled against the FULL screen -- "the bar is back but the layout
    // still ignores it" -- and the next workspace switch, which rebuilds the
    // ctx from scratch, was what finally corrected the geometry.
    //
    // `syncScreenClaim` is a pure in-memory write (no wire traffic), so moving
    // it above the grab costs nothing and does not reorder any X request: the
    // map/unmap below is still queued before the geometry sends.
    syncScreenClaim();
    var grab: ?pipeline.ScopedGrab = null;
    if (do_reconcile) grab = pipeline.grabScoped();
    defer if (grab) |g| g.deinit();
    _ = if (should_be_visible) xcb.xcb_map_window(conn, s.win.win_id) else xcb.xcb_unmap_window(conn, s.win.win_id);
    // Draw AFTER the map request so the blit lands in an already-mapped
    // window. A copy queued to an unmapped window is discarded by the server
    // (and, under a compositor, the view of a freshly remapped window starts
    // blank until the first damage), which is what left the bar invisible --
    // a bare gap in the shelf -- until an unrelated later redraw happened to
    // repaint it. Ordering the map before the draw in this same flush closes
    // that gap on every show (boot, workspace switch, fullscreen exit, Mod+B).
    if (should_be_visible) {
        // Tell continuous-motion segments the bar is (re)appearing, so the
        // title marquee resumes from its last shown offset instead of
        // teleporting across the whole hidden gap on this first frame.
        segmod.runVoidHook(.onBarShown);
        if (do_reconcile) {
            // Fullscreen toggle path: render to the off-screen pixmap inside
            // the grab so the caller's single ungrabAndFlush ships geometry +
            // blit as exactly one compositor frame.
            repaint.submitDrawBlockingFull();
        } else {
            // Workspace-switch path: skip the redundant inline render. The
            // switch already bumped the window fact, so updateIfDirty repaints
            // this bar once at end-of-batch (within the same batch as the
            // switch); an inline draw here would be a full duplicate render AND
            // would paint the stale pre-switch focused-title (model.focused has
            // not landed on the new workspace yet).
            repaint.requestFullRedraw();
        }
    }
    if (grab) |g| {
        g.reconcileNow(.{});
        if (should_be_visible) raiseBar();
    }
}

/// Pre-computes and applies the bar's visibility state for `ws` (X11
/// map/unmap + screen claim) WITHOUT triggering a reconcile. Used by the
/// workspace-switch path so the bar's screen claim (and thus the workarea
/// used by the FIRST reconcile on the new workspace) is correct from the
/// start, preventing the two-reconcile flicker caused by a deferred
/// visibility update. The reconcile comes from the caller's own switch
/// reconcile; the bar merely updates its occupancy state here.
pub fn updateBarVisibilityForWorkspace(ws: u8) void {
    applyVisibilityDecision(ws, false);
}

/// Immediately unmaps the bar and updates the screen claim, without a
/// separate reconcile. Called from the fullscreen-enter grab so the bar
/// disappears atomically with the fullscreen geometry. No-ops when the bar
/// is already hidden or not initialised.
pub fn hideBarForFullscreen() void {
    const s = state.gBar.state orelse return;
    if (!s.vis.shown) return;
    // The prompt overlay is a use-case for being on-top: a fullscreen enter
    // while the inline prompt is open must not yank the workspace switch,
    // since the user is typing into a chrome state that expects the overlay.
    // dismissAfterPrompt recomputes the natural decision at exit.
    if (state.gBar.prompt_forced_visible) return;
    applyVisibility(s, false, false);
}

/// Reacts to a change in core's fullscreen-occupancy fact: recomputes whether
/// the bar must be hidden to share the screen with a fullscreen window on the
/// current workspace, then maps/unmaps and updates the screen claim. Core owns
/// the fact revision; the bar merely reads the model & screen facts it already
/// consumes. Calls `reconcileNow` after a visibility claim change because the
/// usable area geometry changed (a write-path side effect from a rendering
/// module: documented in the check-layers.sh allowlist).
pub fn applyFullscreenVisibility() void {
    applyVisibilityDecision(query.getCurrentWorkspace() orelse 0, true);
}

/// Computes the desired visibility for `ws` via the shared visibility policy
/// and, when it differs from current state, applies the change. `do_reconcile`
/// selects the workspace-switch flavor (no reconcile; the caller reconciles)
/// vs the fullscreen-fact reaction (reconciles inside the claim).
fn applyVisibilityDecision(ws: u8, do_reconcile: bool) void {
    const s = state.gBar.state orelse return;
    // While the inline prompt has forced the bar above everything, any
    // natural-visibility recompute (workspace switch, fullscreen fact tick)
    // must not unmap it below the prompt; dismissAfterPrompt recomputes the
    // natural decision when the prompt exits.
    if (state.gBar.prompt_forced_visible) return;
    const decision = desiredVisibility(pipeline.model(), ws, s.vis.preferred);
    // The comparison against the bar's mapped state is the ORCHESTRATOR's, not
    // the policy's: the policy returns the target and why, and deciding whether
    // to touch the wire stays here.
    if (decision.should_be_visible == s.vis.shown) return;
    applyVisibility(s, decision.should_be_visible, do_reconcile);
    log.info(
        "Bar {s} for workspace {d} ({s})",
        .{ if (decision.should_be_visible) "shown" else "hidden", ws, @tagName(decision.reason) },
    );
}
