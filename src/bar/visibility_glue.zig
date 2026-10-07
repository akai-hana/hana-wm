//! The bar's visibility wire glue: the apply* family that turns the
//! pure policy in `visibility.zig` into X11 map/unmap + screen-claim
//! writes. The policy half (what SHOULD be visible, and why) stays in
//! `visibility.zig`, pure and unit-tested; this file owns only the
//! wire side -- map/unmap, the claim publish, and the reconcile that
//! reacts to the claim change.
//!
//! The host state (`State`, `gBar`) lives in `state.zig` and the draw
//! submission in `repaint.zig`; this file reads the state through that leaf
//! and never imports `bar.zig` back. `bar.zig` imports this file for the
//! apply* entry points -- one direction, so there is no cycle at all.

const core = @import("core");
const xcb = core.xcb;
const log = @import("log");
const tracking = @import("tracking");
const pipeline = @import("pipeline");
const usable_area = @import("usable_area");
const visibility = @import("visibility");

const state = @import("state");
const repaint = @import("repaint");
const State = state.State;

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
        state.runVoidHook(.onBarShown);
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
    applyVisibilityDecision(tracking.getCurrentWorkspace() orelse 0, true);
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
    const decision = visibility.desiredVisibility(pipeline.model(), ws, s.vis.preferred);
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
