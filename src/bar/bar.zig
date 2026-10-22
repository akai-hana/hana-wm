//! Status bar: creates and manages the WM status bar over per-segment dirty
//! tracking (one bool per bar_modules entry); the whole-bar flag folds "full
//! redraw" requests. Batched module requests fold into ONE full redraw
//! (`render.foldModuleRedraw`), and `updateIfDirty`'s re-request loop is capped
//! by `max_batched_redraws` so a misbehaving module cannot busy-spin the batch.
//!
//! Bar segments are an open, drop-in addon set: the build generates the
//! `bar_modules.modules` registry; this orchestrator owns NO segment logic --
//! lifecycle/polls/draw/width/click are uniform loops over the Segment contract.

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

// Pure visibility policy (desired show/hide over the model); the apply*
// wire family lives in this file.
const visibility = @import("visibility");
const input_events = @import("input_events");
const render = @import("render");

const contract = @import("bar_contract");
const dispatch = @import("contract_dispatch");

const state = @import("state");
// The state itself lives in state.zig (a leaf, so render / input_events can
// read it without importing this file back). `gBar` is a POINTER to the
// shared handle: a struct-by-value alias would silently copy it.
const Bar = state.Bar;
const State = state.State;
const anyBoolHook = segmod.anyBoolHook;
const gBar = &state.gBar;
const renderBar = state.renderBar;
const runVoidHook = segmod.runVoidHook;
const self_ticking_ids = segmod.self_ticking_ids;

/// Uniform poll wakeup: runs every module's onPollWakeup hook (prompt caret
/// blink, marquee repaint-marking, ...) then submits a draw.
pub fn onPollWakeup() void {
    // First gate is the lifecycle: with no live bar, module hooks must not
    // run at all.
    const s = gBar.state orelse return;
    // This wake is the one owed frame's landing (pollTimeoutMs's 0-deadline
    // report). Clear the debt before folding: one-shot, so a module that keeps
    // re-requesting gets the ordinary cadence rather than a never-sleeping wake.
    s.owed_redraw = false;
    runVoidHook(.onPollWakeup);
    // Fold any queued module redraw into the dirty state as a full redraw,
    // exactly as the X-batch update path (updateIfDirty) does.
    _ = render.foldModuleRedraw(s);
    render.performDraw();
}

/// Combines every module's poll deadline (clock tick, prompt caret blink,
/// carousel scroll) into the shortest non-negative wait, or null when no
/// module wants one.
pub fn pollTimeoutMs() ?i32 {
    // A bar-less session wants no wakeups from module hooks at all: polling,
    // then dispatching every dead module's cadence at the frame rate, is a
    // real idle-consumption bug.
    const s = gBar.state orelse return null;
    // A hidden bar paints nothing, so no per-frame deadline can make
    // progress...
    if (!s.vis.shown) return null;

    // Module hooks still speak in negatives ("no wake needed"); THIS is the
    // single place that turns that into absence -- the bar's whole contribution
    // to core's deadline reduction. `null` keeps a hidden/empty bar from starving
    // other tick sources; a bare -1 would slip past as an immediate "wake NOW".
    var nearest: ?i32 = null;
    for (segmod.all()) |m| {
        if (m.pollTimeoutMs) |h| {
            const t = h();
            if (t >= 0 and (nearest == null or t < nearest.?)) nearest = t;
        }
    }
    // ...and the bar's own debt outranks them all: a frame a capped batch still
    // owes must land NOW, not at the nearest module deadline. After the hidden-bar
    // gate above, because a bar that paints nothing owes no wake.
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
    // the cast happens here -- the one place a real X key-press enters the registry.
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

/// Bar-provided service handles for mechanism segments (the prompt), owned
/// for the whole bar lifetime. MUST NOT be a stack local in `init()`: the
/// registry init loop hands `&g_bar_handlers` to each segment and the prompt
/// retains that pointer -- a local would dangle the moment init() returns.
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
    // Map before the first draw (same rationale as applyVisibility: a blit
    // to an unmapped window is discarded, and compositors start remapped
    // windows blank until first damage).
    _ = xcb.xcb_map_window(cs.conn, bar.setup.win_id);
    render.performDraw();
    // That first paint reserved row slots from the startup probes; every segment
    // whose measured width differs owes one re-layout redraw (the first-paint
    // settle). Fold and draw them HERE, before the flush, so both copy_areas
    // ship in this one batch and the compositor's first frame is the settled row.
    if (render.foldModuleRedraw(bar.state)) render.performDraw();
    _ = xcb.xcb_flush(cs.conn);
    // Uniform lifecycle: every registered mechanism segment is initialised
    // with the bar's one-way service handles.
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
    // The reload tears down and rebuilds the bar window, so the swap has to be
    // atomic: without a grab the old bar can be destroyed and the new one not yet
    // mapped -- a blank shelf. grabOnly (not grabScoped) because the reload runs
    // no geometry pass: building a ctx here would run the pre-reconcile duties,
    // which with no reconcile to follow would mutate the model for nothing.
    const grab = pipeline.grabOnly();
    defer grab.deinit();
    // Module caches (font widths, caret geometry) are built against the old
    // config; the new one is live from here on either way, so drop them up
    // front -- including on the failure path (the surviving bar uses NEW config).
    runVoidHook(.invalidateReloadCaches);
    // The new bar's metrics were resolved from the NEW config. If it fails
    // to materialize the surviving bar keeps its OWN metrics -- they live on
    // the old State's value now, so there is no global left to save.
    const new_bar = createBar(m, barwin.calcBarYPos(cs.config.bar.bar_position, cs.screen.height_in_pixels, height)) catch |err| {
        // The caller already swapped cs.config to the new config and frees the
        // OLD config when this returns. The old bar survives this failed reload
        // reading the live config (renderBar), so there is nothing to repair.
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

// Bar visibility wire glue: the apply* family plus the prompt's present/dismiss
// pair -- these turn policy decisions (visibility.zig) into X11 map/unmap +
// screen-claim writes. bar.zig is the Rule-1 allowlisted home; policy stays pure.

/// Pushes the bar's current screen-space claim to core.screen. Core owns the
/// area math; the bar only contributes "I take this many pixels from this
/// edge."
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

/// Forces the bar to the absolute top of the stacking order and guarantees it is
/// mapped, overriding whatever would normally keep it hidden or covered. Used by
/// the inline prompt so it is always visible while active. Never touches geometry
/// or retiles; pair with `dismissAfterPrompt` to return to prior state.
fn presentForPrompt() void {
    const s = gBar.state orelse return;
    if (!s.vis.shown) {
        // The bar is hidden; map it before drawing so the blit lands in a mapped
        // window (a draw queued while unmapped is discarded by the server, leaving
        // a blank bar until the next unrelated redraw).
        gBar.prompt_forced_visible = true;
        s.vis.shown = true;
        runVoidHook(.onBarShown);
        _ = xcb.xcb_map_window(s.win.conn, s.win.win_id);
        render.submitDrawBlockingFull();
    }
    raiseBar();
    _ = xcb.xcb_flush(s.win.conn);
}

/// Undoes `presentForPrompt` once the prompt exits. If the bar was shown solely
/// for the prompt, hides it again -- but only if it *should still* be hidden: the
/// prompt can outlive the state that justified the override, so this recomputes
/// natural visibility at exit. An already-visible bar needs no restore.
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

/// Applies a decided visibility change: updates `vis.shown`, draws when shown,
/// maps/unmaps, and re-derives the screen claim. `do_reconcile` additionally
/// grabs the server and reconciles. `resize_parked` is true only for the user
/// toggle (pre-resizes every OTHER workspace's parked windows); the fullscreen
/// reaction must NOT. The reconcile-show path re-raises the bar LAST.
fn applyVisibility(s: *State, should_be_visible: bool, do_reconcile: bool, resize_parked: bool) void {
    s.vis.shown = should_be_visible;
    const conn = core.getState().conn;
    // Publish the claim BEFORE the grab, because `grabScoped` snapshots the
    // reconcile ctx and the ctx carries `usable_area.workArea`. Claiming after
    // the snapshot would make the reconcile re-derive from the invalidated workarea.
    syncScreenClaim();
    var grab: ?pipeline.ScopedGrab = null;
    if (do_reconcile) grab = pipeline.grabScoped();
    defer if (grab) |g| g.deinit();
    _ = if (should_be_visible) xcb.xcb_map_window(conn, s.win.win_id) else xcb.xcb_unmap_window(conn, s.win.win_id);
    // Draw AFTER the map request so the blit lands in an already-mapped
    // window (a copy to an unmapped window is discarded by the server).
    if (should_be_visible) {
        // Marquee resumes from its last shown offset instead of teleporting.
        runVoidHook(.onBarShown);
        if (do_reconcile) {
            // Fullscreen toggle path: render inside the grab so the caller's
            // single ungrabAndFlush ships geometry + blit as one frame.
            render.submitDrawBlockingFull();
        } else {
            // Workspace-switch path: the switch already bumped the window
            // fact, so updateIfDirty repaints at end-of-batch; an inline
            // draw would be a duplicate and paint the stale focused-title.
            render.requestFullRedraw();
        }
    }
    if (grab) |g| {
        g.reconcileNow(.{ .resize_parked = resize_parked });
        if (should_be_visible) raiseBar();
    }
}

/// Pre-computes and applies the bar's visibility state for `ws` (X11
/// map/unmap + screen claim) WITHOUT triggering a reconcile, preventing the
/// two-reconcile flicker caused by a deferred visibility update.
fn updateBarVisibilityForWorkspace(ws: u8) void {
    applyVisibilityDecision(ws, false, false);
}

/// Immediately unmaps the bar and updates the screen claim, without a separate
/// reconcile. Called from the fullscreen-enter grab so the bar disappears
/// atomically with the fullscreen geometry. No-ops when already hidden.
fn hideBarForFullscreen() void {
    const s = gBar.state orelse return;
    if (!s.vis.shown) return;
    // The prompt overlay is a use-case for being on-top: a fullscreen enter
    // while the inline prompt is open must not yank the workspace switch.
    // dismissAfterPrompt recomputes the natural decision at exit.
    if (gBar.prompt_forced_visible) return;
    applyVisibility(s, false, false, false);
}

/// Reacts to a change in core's fullscreen-occupancy fact: recomputes whether the
/// bar must be hidden to share the screen with a fullscreen window. `resize_parked`
/// selects whether that reconcile also pre-resizes other workspaces' parked windows.
fn applyFullscreenVisibility(resize_parked: bool) void {
    applyVisibilityDecision(query.getCurrentWorkspace() orelse 0, true, resize_parked);
}

/// Computes the desired visibility for `ws` via the shared visibility policy
/// and, when it differs from current state, applies the change.
fn applyVisibilityDecision(ws: u8, do_reconcile: bool, resize_parked: bool) void {
    const s = gBar.state orelse return;
    // While the inline prompt has forced the bar above everything, any natural-
    // visibility recompute must not unmap it below the prompt; dismissAfterPrompt
    // recomputes the natural decision when the prompt exits.
    if (gBar.prompt_forced_visible) return;
    const decision = visibility.desiredVisibility(pipeline.state(), ws, s.vis.preferred);
    // The comparison against the bar's mapped state is the ORCHESTRATOR's, not
    // the policy's: the policy returns the target; whether to touch the wire stays.
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
/// and reports its occupancy. It does NOT decide which edge (core owns that flip)
/// and does NOT reconcile -- that takes the X grab, a layering violation from a
/// rendering module.
fn applyBarScreenPosition() i16 {
    const s = gBar.state orelse return 0;
    const cs = core.getState();
    const new_y = barwin.calcBarYPos(cs.config.bar.bar_position, cs.screen.height_in_pixels, s.render.height);
    barwin.setWindowProperties(s.win.win_id, s.render.height);
    render.requestFullRedraw();
    // Drop every recorded self-ticker bound so a stale tick cannot
    // region-scope a repaint before the layout pass re-records them.
    for (&s.clock.segs) |*sc| sc.valid = false;
    // One token owns grab+ungrab+flush. The claim publish is inside the
    // token because it writes a core fact that a reconcile reads; publishing
    // it outside would leave a window between the move and the grab flush.
    const grab = pipeline.grabScoped();
    defer grab.deinit();
    _ = xcb.xcb_configure_window(
        cs.conn,
        s.win.win_id,
        xcb.XCB_CONFIG_WINDOW_Y,
        &[_]u32{model.toXcbCoord(new_y)},
    );
    // Publishes the new edge to core BEFORE the caller's reconcile
    // re-derives any placement from it.
    syncScreenClaim();
    return new_y;
}

/// The surface hook for the toggle-bar-position action: flip the bar's edge
/// (the `config.bar.bar_position` mutation lives here -- the bar owns its
/// edge), then re-anchor. The reconcile that follows is the caller's.
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

/// Sets the bar's user-level visibility state. Only the user toggle path arrives
/// here (keybind / config action). Fullscreen-driven hide/show is NOT a named
/// call: the bar derives it reactively from the core fullscreen fact revision.
///
/// The toggle is the ONE path that passes `resize_parked = true`: its workarea
/// change persists across workspace switches, so other workspaces pre-resize now.
pub fn setBarState(action: types.Action) void {
    const s = gBar.state orelse return;
    if (action == .toggle_bar_visibility) s.vis.preferred = !s.vis.preferred;
    applyFullscreenVisibility(true);
}

pub fn updateIfDirty() void {
    const s = gBar.state orelse return;

    // Fullscreen-occupancy reaction runs even when the bar is currently hidden
    // (it may need to become visible again on fullscreen exit). Diff the core
    // fact revision; when changed, recompute shared-screen visibility. Core owns
    // the fact; we react over a one-way signal rather than being poked.
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
    // facts; we react over a one-way signal (revision counters) rather than being
    // poked by name. Layout changes force a full redraw; window/workspace changes
    // repaint all segments (via `.frame`); focus changes mark only the title.
    const focus_rev = core.focus.rev();
    const window_rev = core.window.rev();
    const layout_rev = core.layout.rev();
    if (s.facts.focus_rev != focus_rev) render.markDirtySource(s, .focus);
    if (s.facts.window_rev != window_rev) render.markDirtySource(s, .frame);
    if (s.facts.layout_rev != layout_rev) {
        render.requestFullRedraw();
    }
    s.facts.focus_rev = focus_rev;
    s.facts.window_rev = window_rev;
    s.facts.layout_rev = layout_rev;

    // Fold any module redraw request into a full dirty (as the poll wakeup path
    // does), then draw. Loop: a module may queue another request while drawing
    // (the variants segment collapses to zero width on a layout switch and must
    // re-lay the row in the SAME batch). Each iteration clears the request it
    // consumed, so the loop terminates unless a module genuinely re-requests;
    // iterations are capped (`max_batched_redraws`).
    const redraw_cap: u8 = core.getState().config.bar.max_batched_redraws;
    var redraw_iter: u8 = 0;
    while (redraw_iter < redraw_cap) : (redraw_iter += 1) {
        _ = render.foldModuleRedraw(s);
        if (!s.dirty.flag) break;
        render.performDraw();
    }
    if (redraw_iter == redraw_cap) {
        // The cap protects one batch from a runaway re-request loop; it must not
        // strand the frame it stopped mid-settle. Consume the overflow into the
        // dirty state and owe the WAKE that lands it, so the redraw completes
        // immediately instead of at the next module deadline (the clock tick).
        if (render.foldModuleRedraw(s)) s.owed_redraw = true;
        log.info("bar: updateIfDirty redraw loop hit its iteration cap; owed frame deferred to self-wake", .{});
    }
}

/// Redraws just the clock segment when its on-screen content is stale (second
/// rolled over, the display mode changed, or a config reload changed the
/// format). Cheap to call on every event batch: it no-ops unless stale.
///
/// A display-mode cycle also changes a self-ticking segment's slot width, and
/// that case reflows the row rather than ticking in place; the check runs BEFORE
/// any paint, off the live probes.
pub fn updateClock() void {
    const s = gBar.state orelse return;
    if (!s.vis.shown) return;
    if (self_ticking_ids.len == 0) return;
    const fmt = drawing.clockFormat(core.getState().config.bar);
    if (!anyBoolHook(.secondsElapsed, .{fmt})) return;

    if (render.adoptFreshClockWidth(s)) {
        // Re-lay and repaint the row in this same call, then ship it. updateClock
        // is the last statement of the event loop body -- it runs AFTER the end-of-
        // batch flush and the batch's own updateIfDirty, so merely flagging the
        // redraw would leave the reflow to the next loop iteration -- up to a whole
        // second idle, exactly the stale window this closes; performDraw queues the blit.
        render.requestFullRedraw();
        render.performDraw();
        _ = xcb.xcb_flush(core.getState().conn);
        return;
    }
    render.drawClockOnly(s);
}

/// The chrome-surface hook set a surface module binds to. The bar binds its
/// `surfaces` value to this; with no surface compiled in the generated hook set
/// is a full set of no-op hooks (build.zig), so this is ONE type in every build.
pub const Surfaces = struct {
    // Boot lifecycle, invoked from startup through surfaces.Surfaces so the
    // boot sequence never needs to name the bar module directly.
    init: *const fn () anyerror!void,
    deinit: *const fn () void,
    // Event-loop hooks.
    handleExpose: *const fn (*const xcb.xcb_expose_event_t) void,
    /// No error union: the bar records its own failures (module draw errors are
    /// logged and leave the segment dirty) rather than propagating, and an
    /// `anyerror!void` here forced every call site to write a `catch` that only logs.
    updateIfDirty: *const fn () void,
    /// The nearest wakeup this surface wants, or null for "block until an fd is
    /// ready". The loop reduces this over its own `Timers` list, so the surface
    /// reports ONE answer and does not re-state the min/absence rule.
    pollTimeoutMs: *const fn () ?i32,
    onPollWakeup: *const fn () void,
    updateClock: *const fn () void,
    onReload: *const fn () void,
    // Input routing. The chrome overlay pre-empts key handling (returns true when
    // it consumed the key), button presses on the surface window are routed to it,
    // and the three surface config actions mutate chrome state.
    chromeHandleKeypress: *const fn (*const xcb.xcb_key_press_event_t, ?*const types.Action) bool,
    isBarWindow: *const fn (u32) bool,
    handleButtonPress: *const fn (*const xcb.xcb_button_press_event_t) void,
    /// Press-hold motion over the surface: X's implicit grab keeps delivering
    /// motion to the surface window while a button is held, so a scrub-drag tracks
    /// the pointer past the bar's edge. The surface routes it.
    handleButtonMotion: *const fn (*const xcb.xcb_motion_notify_event_t) void,
    /// Releases end a press-hold scrub on the surface; the surface clears
    /// its drag anchor here.
    handleButtonRelease: *const fn (*const xcb.xcb_button_release_event_t) void,
    setBarState: *const fn (types.Action) void,
    /// Pre-computes and applies bar visibility for `ws` (X-free, no
    /// reconcile) so the workspace-switch path gets the correct workarea on
    /// the first reconcile.
    updateBarVisibilityForWorkspace: *const fn (u8) void,
    /// Immediately unmaps the bar and updates the screen claim, without a separate
    /// reconcile. Called from the fullscreen-enter grab so the bar disappears
    /// atomically with the fullscreen geometry. No-ops when already hidden.
    hideBarForFullscreen: *const fn () void,
    toggleBarSegmentAnchor: *const fn () void,
    /// True when fullscreen currently forces the bar hidden. The action layer
    /// needs this to decide whether a re-anchor's reconcile is meaningful; reached
    /// through the hook table rather than imported directly.
    barForcedHiddenByFullscreen: ?*const fn (*const model.Model, u8) bool,
    chromeToggleOverlay: *const fn () void,
};

/// Comptime-registered UI-surface hooks for core's event loop (the one place the
/// loop knows the bar exists). Core calls these through a single `surfaces.Surfaces`
/// alias; when the bar is absent the whole set is `null` and call sites compile
/// away. The emitter lives here, so detaching the bar detaches its handlers.
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
