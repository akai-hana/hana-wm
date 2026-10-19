//! Status bar
//! Creates and manages the WM status bar, rendering all configured segments.
//!
//! Rendering uses per-segment dirty tracking: the dirty set is registry-sized
//! (one bool per bar_modules entry); only dirty segments are repainted on
//! each draw. The whole-bar flag alongside an all-dirty set (the folded "full
//! redraw" request) triggers a complete background clear + render.
//! Coalescing happens in the batch: every module request queued during a
//! batch folds into ONE full redraw (`render.foldModuleRedraw`), and
//! `updateIfDirty`'s re-request loop is capped by `max_batched_redraws` so a
//! module that keeps re-asking cannot busy-spin the batch.
//!
//! Bar segments are an open, drop-in addon set: the build generates the
//! `bar_modules.modules` registry and this orchestrator owns NO segment logic.
//! Lifecycle/polls/draw/width/click/prompt-extras are all driven by uniform
//! loops over that registry, dispatching through the Segment contract. The bar
//! never names a specific segment module: services flow one-way
//! through `segmod.BarHandlers`, the prompt overlay lives in the title module,
//! and reverse edges are resolved through the registry.

const std = @import("std");

const core = @import("core");
const xcb = core.xcb;
const usable_area = @import("usable_area");
const log = std.log.scoped(.bar);

const types = @import("types");

const focus = @import("focus");
const pipeline = @import("pipeline");
const model = @import("model");
const query = @import("query");

const window = @import("window");

const drawing = @import("drawing");
const metrics = @import("metrics");
const Metrics = metrics.Metrics;
const segmod = @import("segment");
const barwin = @import("win");

// Bar visibility: the pure policy (desired show/hide decisions over the
// model). The apply* wire family lives in this file, in the visibility
// wire section below.
const visibility = @import("visibility");
const input_events = @import("input_events");
const render = @import("render");

// Window-addon registry (generated): the hidden-set synthesis is routed
// through the collectHiddenSet hook instead of naming the minimize or
// fullscreen module directly.
const contract = @import("bar_contract");
const dispatch = @import("contract_dispatch");

const state = @import("state");
// The state itself lives in state.zig (a leaf, so the render /
// input_events satellites can read it without importing this file back --
// that import would be a cycle). Aliased here
// so this file's own call sites keep their vocabulary; `gBar` is a
// POINTER to the shared handle, because a struct-by-value alias would
// silently copy it.
const Bar = state.Bar;
const State = state.State;
const anyBoolHook = segmod.anyBoolHook;
const gBar = &state.gBar;
const max_batched_redraws = state.max_batched_redraws;
const renderBar = state.renderBar;
const runVoidHook = segmod.runVoidHook;
const self_ticking_ids = segmod.self_ticking_ids;

/// Uniform poll wakeup: runs every module's onPollWakeup hook (prompt caret
/// blink, marquee repaint-marking, ...) then submits a draw. The bar never
/// names a segment.
pub fn onPollWakeup() void {
    // First gate is the lifecycle: with no live bar (disabled via config
    // reload, pre-init, or post-deinit), module hooks must not run at all --
    // the cadence here is what would put a dead-module background wake up at
    // the frame rate.
    const s = gBar.state orelse return;
    // This wake is the one owed frame's landing (pollTimeoutMs's 0-deadline
    // report). Clear the debt before folding: one-shot, so a module that
    // keeps re-requesting gets the ordinary timer cadence from here rather
    // than a self-wake that never lets the poll sleep.
    s.owed_redraw = false;
    runVoidHook(.onPollWakeup);
    // A module's poll hook (e.g. the prompt's caret-blink toggle) must reach
    // the draw's repaint gate: fold any queued module redraw request into the
    // dirty state as a full redraw, exactly as the X-batch update path
    // (updateIfDirty) does, so the animation is visible even when the loop is
    // waking only on the poll timer with no X traffic to trigger that path.
    // performDraw consumes the redraw request itself; no consume here.
    _ = render.foldModuleRedraw(s);
    render.performDraw();
}

/// Combines every module's poll deadline (clock tick, prompt caret blink,
/// carousel scroll) into the shortest non-negative wait, or null when no
/// module wants one.
pub fn pollTimeoutMs() ?i32 {
    // A bar-less session wants no wakeups from module hooks at all: polling,
    // then dispatching every dead module's cadence at the frame rate, is a
    // real idle-consumption bug (a bar disabled via reload never stops its
    // clocks but keeps dispatching).
    const s = gBar.state orelse return null;
    // A hidden bar paints nothing, so no per-frame deadline (clock tick,
    // caret blink, carousel scroll) can make progress...
    if (!s.vis.shown) return null;

    // Module hooks still speak in negatives ("no wake needed"); THIS is the
    // single place that turns that into absence, because it is the bar's
    // whole contribution to core's deadline reduction. Reducing to `null`
    // here is what keeps a hidden or empty-set bar from starving other tick
    // sources -- a bare -1 would slip past the reduce as an immediate
    // "want to wake NOW" preference.
    var nearest: ?i32 = null;
    for (segmod.all()) |m| {
        if (m.pollTimeoutMs) |h| {
            const t = h();
            if (t >= 0 and (nearest == null or t < nearest.?)) nearest = t;
        }
    }
    // ...and the bar's own debt outranks them all: a frame a capped batch
    // still owes must land NOW, not at the nearest module deadline (idle:
    // the clock's second boundary -- the "the bar only settles when the
    // clock ticks" symptom). After the hidden-bar gate above, because a
    // bar that paints nothing owes no wake.
    if (s.owed_redraw) return 0;
    return nearest;
}

/// Routes a keypress through every module that consumes one (the chrome
/// overlay segment).
pub fn chromeHandleKeypress(
    event: *const xcb.xcb_key_press_event_t,
    matched: ?*const types.Action,
) bool {
    // `Segment.handleKeypress` takes the OPAQUE `contract.KeyPressEvent`, so
    // the cast happens here: this is the one place a real X key-press event
    // enters the segment registry, and the bar is the only producer of it.
    const key_event: *const contract.KeyPressEvent = @ptrCast(event);
    return anyBoolHook(.handleKeypress, .{ key_event, matched });
}

/// Toggles the chrome overlay. Routed through the resolved title module's
/// onClick hook (right-click path): the overlay lives in the title module
/// and the bar must not name it.
pub fn chromeToggleOverlay() void {
    const s = gBar.state orelse return;
    if (input_events.titleIdBound(s)) |tb| {
        const is_right_click = true;
        input_events.dispatchClick(s, tb.id, 0, false, is_right_click);
    }
}

/// Bar-provided service handles for mechanism segments (the prompt), owned for
/// the whole bar lifetime. MUST NOT be a stack local in `init()`: the registry
/// init loop hands `&g_bar_handlers` to each segment, and the prompt retains
/// that pointer past init() to call back on every toggle/keystroke. A local
/// would dangle the moment init() returns and crash on the first prompt toggle
/// (use-after-return). The three handlers are stateless bar functions, so the
/// value is assigned once at init and never changes.
var g_bar_handlers: segmod.BarHandlers = undefined;

/// Everything a fully-initialised bar owns; returned by createBar.
const BarSetup = struct {
    setup: barwin.BarWindowSetup,
    state: *State,
};

/// Creates the bar window, off-screen draw context, and live State.
/// On any failure, everything already created is freed before returning.
fn createBar(m: Metrics, y_pos: i16) !BarSetup {
    const height = m.height;
    const cs = core.getState();
    const setup = barwin.createBarWindow(height, y_pos, cs.config.bar.getAlpha16() < 0xFFFF);
    errdefer barwin.destroyBarWindow(cs.conn, setup.win_id, setup.colormap);
    barwin.setWindowProperties(setup.win_id, height);
    const dc = try barwin.createDrawContext(setup, height, m.font_size);
    errdefer dc.deinit();
    log.info(
        "Bar transparency: {s}",
        .{if (setup.has_argb) "enabled (ARGB)" else "disabled (opaque)"},
    );
    const st = try State.init(
        cs.alloc,
        cs.conn,
        setup.win_id,
        setup.colormap,
        cs.screen.width_in_pixels,
        height,
        dc,
        cs.config.bar,
    );
    return .{ .setup = setup, .state = st };
}

// Lifecycle

pub fn init() !void {
    const cs = core.getState();
    std.debug.assert(cs.config.bar.enabled);
    barwin.initAtoms();
    const m = metrics.resolveBarMetrics();
    const bar = try createBar(m, barwin.calcBarYPos(cs.config.bar.bar_position, cs.screen.height_in_pixels, m.height));
    gBar.state = bar.state;
    usable_area.setSurfaceWindow(bar.setup.win_id);
    // Map before the first draw (same rationale as applyVisibility: a blit to
    // an unmapped window is discarded, and compositors start remapped windows
    // blank until first damage).
    _ = xcb.xcb_map_window(cs.conn, bar.setup.win_id);
    render.performDraw();
    // That first paint reserved row slots from the startup probes; every
    // segment it painted whose measured width differs owes one re-layout
    // redraw (the first-paint settle). Fold and draw them HERE, before the
    // flush, so both copy_areas ship in this one batch and the compositor's
    // first presented frame is the settled row -- not the probe layout that
    // a later event batch or timer tick has to correct. Without this the
    // settle rode the cap (`max_batched_redraws`) and, on an idle bar, the
    // leftover frame waited for the clock's next whole-second wakeup.
    if (render.foldModuleRedraw(bar.state)) render.performDraw();
    _ = xcb.xcb_flush(cs.conn);
    // Uniform lifecycle: every registered mechanism segment (incl. the prompt,
    // whose init owns the vim addon lifecycle) is initialised with the
    // bar's one-way service handles. The handles live in the file-scope
    // g_bar_handlers (bar-lifetime storage); a pointer to a stack local would
    // dangle as soon as this init returns, and the prompt calls back through
    // it on the first toggle.
    g_bar_handlers = .{
        .presentForPrompt = presentForPrompt,
        .dismissAfterPrompt = dismissAfterPrompt,
        .isBarWindow = isBarWindow,
    };
    for (segmod.all()) |seg| if (seg.init) |f| try f(cs.alloc, cs.conn, &g_bar_handlers);
    syncScreenClaim();
}

pub fn deinit() void {
    const alloc = core.getState().alloc;
    dispatch.callAll(contract.Segment, segmod.all(), .deinit, .{alloc});
    if (gBar.state) |s| {
        s.render.dc.deinit();
        s.deinit();
        gBar.state = null;
    }
    usable_area.releaseClaim();
    usable_area.clearSurfaceWindow();
}

pub fn reload() void {
    const old = gBar.state orelse {
        if (core.getState().config.bar.enabled) {
            init() catch |err| log.err("Bar init failed: {}", .{err});
        }
        return;
    };
    if (!core.getState().config.bar.enabled) {
        deinit();
        return;
    }
    applyReload(old, metrics.resolveBarMetrics()) catch |err| {
        log.err("Bar reload failed ({s}), keeping old bar", .{@errorName(err)});
    };
}

fn applyReload(old: *State, m: Metrics) !void {
    const height = m.height;
    const cs = core.getState();
    // The reload tears down and rebuilds the bar window, so the whole swap has
    // to be atomic: without a grab the old bar can be destroyed and the new one
    // not yet mapped, which shows as a blank shelf. grabOnly (not grabScoped)
    // because the reload runs no geometry pass: building a ctx here would run
    // the pre-reconcile duties, and with no reconcile to follow they would
    // mutate the model for nothing.
    const grab = pipeline.grabOnly();
    defer grab.deinit();
    // Module caches (font widths, caret geometry) are built against the old
    // config; the new one is live from here on either way, so drop them up
    // front, including on the failure path below, where the surviving bar
    // re-points at the NEW live config too.
    runVoidHook(.invalidateReloadCaches);
    // The new bar's metrics were resolved from the NEW config (percentage
    // sizes refine against the new height). If it fails to materialize the
    // surviving bar keeps its OWN metrics -- they live on the old State's
    // value now, so there is no global left to save and put back.
    const new_bar = createBar(m, barwin.calcBarYPos(cs.config.bar.bar_position, cs.screen.height_in_pixels, height)) catch |err| {
        // The caller has already swapped cs.config to the new config and frees
        // the OLD config when this returns. The old bar survives this failed
        // reload; it reads the live config (renderBar), so there is nothing to
        // repair.
        return err;
    };
    const new_state = new_bar.state;
    new_state.vis.shown = old.vis.shown;
    new_state.vis.preferred = old.vis.preferred;
    gBar.state = new_state;
    usable_area.setSurfaceWindow(new_bar.setup.win_id);
    syncScreenClaim();
    render.submitDrawBlockingFull();
    if (new_state.vis.shown) _ = xcb.xcb_map_window(cs.conn, new_bar.setup.win_id);
    // No explicit destroy: `deinit` owns the window and its colormap.
    old.render.dc.deinit();
    old.deinit();
}

// Bar visibility wire glue
//
// The apply* family plus the prompt's present/dismiss pair: these turn the
// policy's decisions (visibility.zig) into X11 map/unmap + screen-claim
// writes, and the reconcile that reacts to a claim change. They are bar
// self-management -- bar.zig is the Rule-1 allowlisted home for it -- and the
// policy half stays pure in `visibility.zig`.

/// Pushes the bar's current screen-space claim to core.screen. Called
/// at each point where the bar's occupancy of the screen changes
/// (visibility toggle, edge/position change) immediately before the
/// reconcile that re-derives window placement from the new usable
/// area. Core owns the area math; the bar only contributes "I take
/// this many pixels from this edge."
fn syncScreenClaim() void {
    const s = gBar.state orelse return;
    const cs = core.getState();
    const edge: usable_area.Edge = if (cs.config.bar.bar_position == .bottom) .bottom else .top;
    const px: u16 = if (s.vis.shown) s.render.height else 0;
    usable_area.setClaim(edge, px);
}

fn raiseBar() void {
    if (gBar.state) |s|
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
fn presentForPrompt() void {
    const s = gBar.state orelse return;
    if (!s.vis.shown) {
        // The bar is hidden; map it before drawing so the blit lands in a
        // mapped window (a draw queued while unmapped is discarded by the
        // server, leaving a blank bar until the next unrelated redraw) and a
        // compositor never presents an empty frame.
        gBar.prompt_forced_visible = true;
        s.vis.shown = true;
        runVoidHook(.onBarShown);
        _ = xcb.xcb_map_window(s.win.conn, s.win.win_id);
        render.submitDrawBlockingFull();
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
fn dismissAfterPrompt() void {
    const s = gBar.state orelse return;
    if (!gBar.prompt_forced_visible) return;
    gBar.prompt_forced_visible = false;
    const current_ws = query.getCurrentWorkspace() orelse 0;
    const should_show = visibility.keepPromptOverride(pipeline.state(), current_ws, s.vis.preferred);
    if (should_show) return; // conditions changed while the prompt was open; stay visible
    s.vis.shown = false;
    _ = xcb.xcb_unmap_window(s.win.conn, s.win.win_id);
    _ = xcb.xcb_flush(s.win.conn);
}

/// Applies a decided visibility change: updates `vis.shown`, draws when
/// shown, maps/unmaps, and re-derives the screen claim. `do_reconcile`
/// additionally grabs the server, reconciles (the usable area changed with
/// the claim) and flushes -- used by the fullscreen-fact reaction path, not
/// by the workspace-switch path whose caller runs its own reconcile. When it
/// reconciles, `resize_parked` is passed through to the reconciler: true only
/// for the user toggle, which pre-resizes every OTHER workspace's parked
/// windows to the new workarea so a later switch is a pure position change
/// (the fullscreen reaction must NOT do that -- its workarea change is
/// local to the fullscreen workspace and is recomputed at every switch).
/// The reconcile-show path also re-raises the bar LAST (inside the same
/// flush, after the reconcile's geometry sends), so a moved winner that got
/// raised above it (sync raises a placing winner on motion even without
/// force_restack) cannot leave a freshly shown bar buried under the window
/// it just stopped covering.
fn applyVisibility(s: *State, should_be_visible: bool, do_reconcile: bool, resize_parked: bool) void {
    s.vis.shown = should_be_visible;
    const conn = core.getState().conn;
    // Optional token: the workspace-switch path (do_reconcile false) must NOT
    // grab; the grab and its ungrabAndFlush are one token, so no early return
    // can unpair them.
    // Publish the claim BEFORE the grab, because `grabScoped` snapshots the
    // reconcile ctx and the ctx carries `usable_area.workArea`. Claiming after
    // the snapshot would make the reconcile that reacts to the claim change
    // re-derive geometry from the workarea it just invalidated: on fullscreen
    // exit the bar would come back and take its pixels while the windows are
    // re-tiled against the FULL screen -- "the bar is back but the layout
    // still ignores it".
    //
    // `syncScreenClaim` is a pure in-memory write (no wire traffic), so
    // publishing it above the grab costs nothing and does not reorder any X
    // request: the map/unmap below is still queued before the geometry sends.
    syncScreenClaim();
    var grab: ?pipeline.ScopedGrab = null;
    if (do_reconcile) grab = pipeline.grabScoped();
    defer if (grab) |g| g.deinit();
    _ = if (should_be_visible) xcb.xcb_map_window(conn, s.win.win_id) else xcb.xcb_unmap_window(conn, s.win.win_id);
    // Draw AFTER the map request so the blit lands in an already-mapped
    // window. A copy queued to an unmapped window is discarded by the server
    // (and, under a compositor, the view of a freshly remapped window starts
    // blank until the first damage), leaving the bar invisible -- a bare gap
    // in the shelf -- until some unrelated redraw repaints it. Ordering the
    // map before the draw in this same flush closes that gap on every show
    // (boot, workspace switch, fullscreen exit, Mod+B).
    if (should_be_visible) {
        // Tell continuous-motion segments the bar is (re)appearing, so the
        // title marquee resumes from its last shown offset instead of
        // teleporting across the whole hidden gap on this first frame.
        runVoidHook(.onBarShown);
        if (do_reconcile) {
            // Fullscreen toggle path: render to the off-screen pixmap inside
            // the grab so the caller's single ungrabAndFlush ships geometry +
            // blit as exactly one compositor frame.
            render.submitDrawBlockingFull();
        } else {
            // Workspace-switch path: skip the redundant inline render. The
            // switch already bumped the window fact, so updateIfDirty repaints
            // this bar once at end-of-batch (within the same batch as the
            // switch); an inline draw here would be a full duplicate render AND
            // would paint the stale pre-switch focused-title (model.focused has
            // not landed on the new workspace yet).
            render.requestFullRedraw();
        }
    }
    if (grab) |g| {
        g.reconcileNow(.{ .resize_parked = resize_parked });
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
fn updateBarVisibilityForWorkspace(ws: u8) void {
    applyVisibilityDecision(ws, false, false);
}

/// Immediately unmaps the bar and updates the screen claim, without a
/// separate reconcile. Called from the fullscreen-enter grab so the bar
/// disappears atomically with the fullscreen geometry. No-ops when the bar
/// is already hidden or not initialised.
fn hideBarForFullscreen() void {
    const s = gBar.state orelse return;
    if (!s.vis.shown) return;
    // The prompt overlay is a use-case for being on-top: a fullscreen enter
    // while the inline prompt is open must not yank the workspace switch,
    // since the user is typing into a chrome state that expects the overlay.
    // dismissAfterPrompt recomputes the natural decision at exit.
    if (gBar.prompt_forced_visible) return;
    applyVisibility(s, false, false, false);
}

/// Reacts to a change in core's fullscreen-occupancy fact: recomputes whether
/// the bar must be hidden to share the screen with a fullscreen window on the
/// current workspace, then maps/unmaps and updates the screen claim. Core owns
/// the fact revision; the bar merely reads the model & screen facts it already
/// consumes. Calls `reconcileNow` after a visibility claim change because the
/// usable area geometry changed (a write-path side effect from a rendering
/// module: documented in the check-layers.sh allowlist). `resize_parked`
/// selects whether that reconcile also pre-resizes other workspaces'
/// parked windows (true only for the user toggle -- see applyVisibility).
fn applyFullscreenVisibility(resize_parked: bool) void {
    applyVisibilityDecision(query.getCurrentWorkspace() orelse 0, true, resize_parked);
}

/// Computes the desired visibility for `ws` via the shared visibility policy
/// and, when it differs from current state, applies the change. `do_reconcile`
/// selects the workspace-switch flavor (no reconcile; the caller reconciles)
/// vs the fullscreen-fact reaction (reconciles inside the claim).
/// `resize_parked` is passed through to that reconcile (see applyVisibility).
fn applyVisibilityDecision(ws: u8, do_reconcile: bool, resize_parked: bool) void {
    const s = gBar.state orelse return;
    // While the inline prompt has forced the bar above everything, any
    // natural-visibility recompute (workspace switch, fullscreen fact tick)
    // must not unmap it below the prompt; dismissAfterPrompt recomputes the
    // natural decision when the prompt exits.
    if (gBar.prompt_forced_visible) return;
    const decision = visibility.desiredVisibility(pipeline.state(), ws, s.vis.preferred);
    // The comparison against the bar's mapped state is the ORCHESTRATOR's, not
    // the policy's: the policy returns the target and why, and deciding whether
    // to touch the wire stays here.
    if (decision.should_be_visible == s.vis.shown) return;
    applyVisibility(s, decision.should_be_visible, do_reconcile, resize_parked);
    log.info(
        "Bar {s} for workspace {d} ({s})",
        .{ if (decision.should_be_visible) "shown" else "hidden", ws, @tagName(decision.reason) },
    );
}

// Public event handlers & queries

/// Moves the bar window to the edge the config now names, and publishes the
/// resulting screen claim. Returns the new edge-relative y.
///
/// Strictly the renderer's half of a position change: it moves its own window
/// and reports its new occupancy. It does NOT decide which edge that is (core
/// owns that flip), and it does NOT reconcile -- reconciling takes the X grab,
/// and doing that from a rendering module is the layering violation this
/// split exists to remove. The caller reconciles, after this has
/// published the claim, so window placement is re-derived from the new usable
/// area.
fn applyBarScreenPosition() i16 {
    const s = gBar.state orelse return 0;
    const cs = core.getState();
    const new_y = barwin.calcBarYPos(cs.config.bar.bar_position, cs.screen.height_in_pixels, s.render.height);
    barwin.setWindowProperties(s.win.win_id, s.render.height);
    render.requestFullRedraw();
    // The shared bar window is being re-anchored; drop every recorded
    // self-ticker bound so a stale tick cannot region-scope a repaint before
    // the layout pass re-records them.
    for (&s.clock.segs) |*sc| sc.valid = false;
    // One token owns grab+ungrab+flush. The claim publish is inside the token
    // because it writes a core fact that a reconcile reads; publishing it
    // outside would leave a window between the move and the grab flush.
    const grab = pipeline.grabScoped();
    defer grab.deinit();
    _ = xcb.xcb_configure_window(
        cs.conn,
        s.win.win_id,
        xcb.XCB_CONFIG_WINDOW_Y,
        &[_]u32{model.toXcbCoord(new_y)},
    );
    // The bar window has already moved and bar_position changed, so this
    // publishes the new edge to core BEFORE the caller's reconcile re-derives
    // any placement from it. Core owns the area math; the bar only
    // contributes "I take this many pixels from this edge."
    syncScreenClaim();
    return new_y;
}

/// The surface hook for the toggle-bar-position action: flip the bar's edge
/// (the `config.bar.bar_position` mutation lives here — the bar owns its
/// edge), then re-anchor. The reconcile that follows is the caller's (see
/// core/input/dispatch.zig's `.toggle_bar_position` action), because it is a
/// layout decision made outside the renderer.
pub fn toggleBarSegmentAnchor() void {
    const cfg = &core.getState().config.bar;
    cfg.bar_position = switch (cfg.bar_position) {
        .top => .bottom,
        .bottom => .top,
    };
    _ = applyBarScreenPosition();
}

pub fn isBarWindow(win: u32) bool {
    return if (gBar.state) |s| s.win.win_id == win else false;
}

/// Sets the bar's user-level visibility state. Only the user toggle path
/// arrives here (keybind / config action). Fullscreen-driven hide/show is NOT
/// a named call: the bar derives it reactively from the core fullscreen fact
/// revision in `applyFullscreenVisibility`, so no subsystem pokes the bar.
///
/// The toggle is the ONE path that passes `resize_parked = true`: its
/// workarea change persists across workspace switches (the preferred flag is
/// global), so every other workspace's parked windows must be pre-resized now
/// or they re-size visibly at their next show. The fullscreen reaction
/// (updateIfDirty) passes false: that change is local to the fullscreen
/// workspace and is recomputed at every switch, so pre-sizing parked windows
/// to the full screen there would only make the switch size them back on show
/// -- the flicker the toggle's pass exists to remove.
pub fn setBarState(action: types.Action) void {
    const s = gBar.state orelse return;
    if (action == .toggle_bar_visibility) s.vis.preferred = !s.vis.preferred;
    applyFullscreenVisibility(true);
}

pub fn updateIfDirty() void {
    const s = gBar.state orelse return;

    // Fullscreen-occupancy reaction runs even when the bar is currently hidden
    // (it may need to become visible again on fullscreen exit). Diff the core
    // fact revision; when changed, we recompute shared-screen visibility. Core
    // owns the fact; we react over a one-way signal rather than being poked.
    const fullscreen_rev = core.fullscreen.rev();
    if (s.facts.fullscreen_rev != fullscreen_rev) {
        s.facts.fullscreen_rev = fullscreen_rev;
        // resize_parked false: the fullscreen reaction's workarea change is
        // local to this workspace and recomputed at every switch; only the
        // user toggle pre-resizes parked workspaces (see setBarState).
        applyFullscreenVisibility(false);
    }
    if (!s.vis.shown) return;

    // Diff core's fact revisions against what we last drew. Core owns these
    // facts; we react over a one-way signal (revision counters) rather than
    // being poked by name. Layout changes force a full redraw; window/workspace
    // changes repaint all segments (split-view titles/tile counts); focus
    // changes cheaply mark only the title. Each revision is read once and
    // reused for both the check and the assignment below.
    const focus_rev = core.focus.rev();
    const window_rev = core.window.rev();
    const layout_rev = core.layout.rev();
    if (s.facts.focus_rev != focus_rev) render.markDirtySource(s, .focus);
    // window_rev marks the `.frame` source (title and tags declare they want
    // it), which keeps the non-frame segments (clock, carousel, systatus)
    // from being swept along on every window churn fact bump.
    if (s.facts.window_rev != window_rev) render.markDirtySource(s, .frame);
    if (s.facts.layout_rev != layout_rev) {
        render.requestFullRedraw();
    }
    s.facts.focus_rev = focus_rev;
    s.facts.window_rev = window_rev;
    s.facts.layout_rev = layout_rev;

    // Fold any module redraw request into a full dirty (as the poll
    // wakeup path does), then draw. Loop: a module may queue another request
    // while drawing (the variants segment collapses to zero width on a layout
    // switch and must re-lay the row in the SAME batch, before the
    // end-of-batch flush, so the gap closes seamlessly rather than waiting on
    // the next unrelated event). Each iteration clears the request it
    // consumed, so the loop terminates unless a module genuinely re-requests.
    // Cap the iterations so a misbehaving module that re-requests forever
    // can't busy-spin this batch.
    var redraw_iter: u8 = 0;
    while (redraw_iter < max_batched_redraws) : (redraw_iter += 1) {
        _ = render.foldModuleRedraw(s);
        if (!s.dirty.flag) break;
        render.performDraw();
    }
    if (redraw_iter == max_batched_redraws) {
        // The cap protects one batch from a runaway re-request loop; it must
        // not strand the frame it stopped mid-settle. Consume the overflow
        // into the dirty state and owe the WAKE that lands it, so the
        // redraw completes immediately instead of at the next module
        // deadline -- on an idle bar that is the clock tick, which is what
        // made a capped boot settle "when the clock fires".
        if (render.foldModuleRedraw(s)) s.owed_redraw = true;
        log.info("bar: updateIfDirty redraw loop hit its iteration cap; owed frame deferred to self-wake", .{});
    }
}

/// Redraws just the clock segment when its on-screen content is stale
/// (second rolled over, the display mode changed, or a config reload changed
/// the format). Cheap to call on every event batch: it no-ops unless staleness
/// is detected.
///
/// A display-mode cycle also changes a self-ticking segment's slot width, and
/// that case reflows the row rather than ticking in place. The check runs
/// BEFORE any paint, off the live width probes, because the region-scoped tick
/// blit can only paint inside the slot the last layout pass reserved: shipping
/// that first would show the new mode's text stranded in the outgoing mode's
/// (wider) slot while its neighbours stayed put.
pub fn updateClock() void {
    const s = gBar.state orelse return;
    if (!s.vis.shown) return;
    if (self_ticking_ids.len == 0) return;
    const fmt = drawing.clockFormat(core.getState().config.bar);
    if (!anyBoolHook(.secondsElapsed, .{fmt})) return;

    if (render.adoptFreshClockWidth(s)) {
        // Re-lay and repaint the row in this same call, then ship it. updateClock
        // is the last statement of the event loop body, i.e. it runs AFTER the
        // end-of-batch flush and after the batch's own updateIfDirty, so merely
        // flagging the redraw would leave the reflow to the next loop iteration
        // -- up to a whole second on an idle bar, which is exactly the
        // stale-length window this path exists to close. performDraw queues its
        // blit, so the flush is ours to make.
        render.requestFullRedraw();
        render.performDraw();
        _ = xcb.xcb_flush(core.getState().conn);
        return;
    }
    render.drawClockOnly(s);
}

/// The chrome-surface hook set a surface module binds to. The bar binds its
/// `surfaces` value to this; when no surface is compiled in, the generated
/// `surfaces.Surfaces` is a full set of no-op hooks (see build.zig), so this is
/// ONE type in every build and call sites never test a build flag.
pub const Surfaces = struct {
    // Boot lifecycle, invoked from startup through surfaces.Surfaces so the
    // boot sequence never needs to name the bar module directly.
    init: *const fn () anyerror!void,
    deinit: *const fn () void,
    // Event-loop hooks.
    handleExpose: *const fn (*const xcb.xcb_expose_event_t) void,
    /// No error union: the bar records its own failures (module draw errors
    /// are logged and leave the segment dirty) rather than propagating, and an
    /// `anyerror!void` here forced every call site to write a `catch` arm that
    /// could only ever log the same thing.
    updateIfDirty: *const fn () void,
    /// The nearest wakeup this surface wants, or null for "block until an
    /// fd is ready". The loop reduces this over its own `Timers` list, so the
    /// surface reports ONE answer and does not re-state the min/absence rule.
    pollTimeoutMs: *const fn () ?i32,
    onPollWakeup: *const fn () void,
    updateClock: *const fn () void,
    onReload: *const fn () void,
    // Input routing. The chrome overlay pre-empts key handling (returns true
    // when it consumed the key), button presses on the surface window are
    // routed to it, and the three surface config actions mutate chrome state.
    chromeHandleKeypress: *const fn (*const xcb.xcb_key_press_event_t, ?*const types.Action) bool,
    isBarWindow: *const fn (u32) bool,
    handleButtonPress: *const fn (*const xcb.xcb_button_press_event_t) void,
    /// Press-hold motion over the surface: X's implicit grab keeps delivering
    /// motion to the surface window while a button is held, so a scrub-drag
    /// (e.g. a slider sub, volume) can track the pointer even past the bar's
    /// edge. The surface decides whether a segment drag is live and routes it.
    handleButtonMotion: *const fn (*const xcb.xcb_motion_notify_event_t) void,
    /// Releases end a press-hold scrub on the surface; the surface clears its
    /// drag anchor here.
    handleButtonRelease: *const fn (*const xcb.xcb_button_release_event_t) void,
    setBarState: *const fn (types.Action) void,
    /// Pre-computes and applies bar visibility for `ws` (X-free, no
    /// reconcile) so the workspace-switch path gets the correct workarea on
    /// the first reconcile.
    updateBarVisibilityForWorkspace: *const fn (u8) void,
    /// Immediately unmaps the bar and updates the screen claim, without a
    /// separate reconcile. Called from the fullscreen-enter grab so the bar
    /// disappears atomically with the fullscreen geometry — no deferred
    /// ConfigureNotify wait. No-ops when the bar is already hidden.
    hideBarForFullscreen: *const fn () void,
    toggleBarSegmentAnchor: *const fn () void,
    /// True when fullscreen currently forces the bar hidden. The action layer
    /// needs this to decide whether a re-anchor's reconcile is meaningful
    /// The predicate is the bar's, so it is reached through the same
    /// hook table as the re-anchor itself rather than imported directly.
    barForcedHiddenByFullscreen: ?*const fn (*const model.Model, u8) bool,
    chromeToggleOverlay: *const fn () void,
};

/// Comptime-registered UI-surface hooks for core's event loop (comptime
/// reference point: the one place the loop knows the bar exists). Core calls
/// these through a single `surfaces.Surfaces` alias; when the bar is absent the
/// whole set is `null` and every such call site compiles away. The emitter
/// lives in this module, so detaching the bar detaches its handlers. The hook
/// types are `Surfaces`, directly above: this module defines and binds them.
pub const surfaces = Surfaces{
    .init = init,
    .deinit = deinit,
    .handleExpose = input_events.handleExpose,
    .updateIfDirty = updateIfDirty,
    .pollTimeoutMs = pollTimeoutMs,
    .onPollWakeup = onPollWakeup,
    .updateClock = updateClock,
    .onReload = reload,
    .chromeHandleKeypress = chromeHandleKeypress,
    .isBarWindow = isBarWindow,
    .handleButtonPress = input_events.handleButtonPress,
    .handleButtonMotion = input_events.handleButtonMotion,
    .handleButtonRelease = input_events.handleButtonRelease,
    .setBarState = setBarState,
    .hideBarForFullscreen = hideBarForFullscreen,
    .updateBarVisibilityForWorkspace = updateBarVisibilityForWorkspace,
    .toggleBarSegmentAnchor = toggleBarSegmentAnchor,
    .barForcedHiddenByFullscreen = visibility.barForcedHiddenByFullscreen,
    .chromeToggleOverlay = chromeToggleOverlay,
};
