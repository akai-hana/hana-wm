//! Status bar
//! Creates and manages the WM status bar, rendering all configured segments.
//!
//! Rendering uses per-segment dirty tracking: the dirty set is registry-sized
//! (one bool per bar_modules entry); only dirty segments are repainted on
//! each draw. The whole-bar flag alongside an all-dirty set (the folded "full
//! redraw" request) triggers a complete background clear + repaint.
//! Coalescing happens in the batch: every module request queued during a
//! batch folds into ONE full redraw (`repaint.foldModuleRedraw`), and
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
const log = @import("log");

const types = @import("types");

const tracking = @import("tracking");
const focus = @import("focus");
const pipeline = @import("pipeline");
const model = @import("model");

const window = @import("window");

const drawing = @import("drawing");
const metrics = @import("metrics");
const Metrics = metrics.Metrics;
const segmod = @import("segment");
const barwin = @import("win");

// Bar visibility: `visibility` holds the pure policy decisions; `visibility_glue`
// holds the map/unmap + screen-claim wire glue that applies them.
const visibility = @import("visibility");
const visibility_glue = @import("visibility_glue");
const input_events = @import("input_events");
const repaint = @import("repaint");

// Window-addon registry (generated): the hidden-set synthesis is routed
// through the collectHiddenSet seam instead of naming the minimize or
// fullscreen module directly.
const contract = @import("contract");

const requests = @import("requests");

// Bar-segment registry (generated). Raw `@import("X_modules").modules` at
// point of use is the one spelling every registry consumer uses; state.zig's
// alias of the same expression is file-local, not API.
const bar_mods = @import("bar_modules").modules;

const state = @import("state");
// The state itself now lives in state.zig (a leaf, so the repaint /
// visibility_glue / input_events satellites can read it without
// importing this file back -- that import was the cycle). Aliased here
// so this file's own call sites keep their vocabulary; `gBar` is a
// POINTER to the shared handle, because a struct-by-value alias would
// silently copy it.
const Bar = state.Bar;
const State = state.State;
const anyBoolHook = state.anyBoolHook;
const gBar = &state.gBar;
const max_batched_redraws = state.max_batched_redraws;
const renderBar = state.renderBar;
const runVoidHook = state.runVoidHook;
const self_ticking_ids = state.self_ticking_ids;

// Bar height / font-size resolution.
//
// The RULES live in bar/metrics.zig (`metrics.resolve`), which is pure: it
// takes the configured values, the screen, and a font probe, and returns a
// `Metrics` value. This section only supplies the two live pieces -- the
// current config, and a probe that measures through
// drawing.probeFontMetrics' throwaway surface (no live DrawContext is
// touched) -- and threads the result into bar creation, draw-context
// construction, and the surviving State's own value. No global, no config
// mutation, and no save/restore: a bar's metrics belong to that bar (21.5).

/// Measures the configured fonts at `trial_pt`. The point size is always
/// explicit: the only two callers are the metric probe itself (a fixed trial
/// size) and `metrics.resolve`'s height decision, which measures at the
/// DPI-scaled base.
fn probeMetrics(trial_pt: u16) ?drawing.FontMetrics {
    const cs = core.getState();
    var sized = drawing.SizedFontList.build(cs.alloc, cs.config.bar.fonts.items, trial_pt) catch return null;
    defer sized.deinit();
    return drawing.probeFontMetrics(
        cs.alloc,
        core.dpi(),
        sized.items,
    );
}

/// Resolves the bar's metrics from the live config and screen. The rules
/// themselves live in `metrics.resolve` (21.5); this only supplies them.
fn resolveBarMetrics() Metrics {
    const cs = core.getState();
    return metrics.resolve(.{
        .font_size = cs.config.bar.font_size,
        .height = cs.config.bar.height,
        .screen_height = cs.screen.height_in_pixels,
    }, probeTextHeight);
}

/// The `metrics.Probe` adapter: the configured fonts' ascent+descent at a
/// trial point size, or null when none could be measured.
///
/// Pango reports i16 and a descent is a positive-downward distance here, so
/// the total is taken in i32 and floored at 0: a font that reports a
/// pathological negative total must clamp to "no measurement" rather than
/// wrap through `@intCast` in ReleaseFast.
fn probeTextHeight(trial_pt: u16) ?u32 {
    const m = probeMetrics(trial_pt) orelse return null;
    const total: i32 = @as(i32, m.ascent) + @as(i32, m.descent);
    if (total <= 0) return null;
    return @intCast(total);
}

/// Uniform poll wakeup: runs every module's onPollWakeup hook (prompt caret
/// blink, marquee repaint-marking, ...) then submits a draw. The bar never
/// names a segment.
pub fn onPollWakeup() void {
    // First gate is the lifecycle: with no live bar (disabled via config
    // reload, pre-init, or post-deinit), module hooks must not run at all --
    // the cadence here is what would put a dead-module background wake up at
    // the frame rate.
    const s = gBar.state orelse return;
    runVoidHook(.onPollWakeup);
    // A module's poll hook (e.g. the prompt's caret-blink toggle) must reach
    // the draw's repaint gate: fold any queued module redraw request into the
    // dirty state as a full redraw, exactly as the X-batch update path
    // (updateIfDirty) does, so the animation is visible even when the loop is
    // waking only on the poll timer with no X traffic to trigger that path.
    // performDraw consumes the redraw request itself; no consume here.
    _ = repaint.foldModuleRedraw(s);
    repaint.performDraw();
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
    for (bar_mods) |m| {
        if (m.pollTimeoutMs) |h| {
            const t = h();
            if (t >= 0 and (nearest == null or t < nearest.?)) nearest = t;
        }
    }
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
    warnUnknownSegments();
    barwin.initAtoms();
    const m = resolveBarMetrics();
    const bar = try createBar(m, barwin.calcBarYPos(cs.config.bar.bar_position, cs.screen.height_in_pixels, m.height));
    gBar.state = bar.state;
    usable_area.setSurfaceWindow(bar.setup.win_id);
    // Map before the first draw (same rationale as applyVisibility: a blit to
    // an unmapped window is discarded, and compositors start remapped windows
    // blank until first damage).
    _ = xcb.xcb_map_window(cs.conn, bar.setup.win_id);
    repaint.performDraw();
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
    for (bar_mods) |seg| if (seg.init) |f| try f(cs.alloc, cs.conn, &g_bar_handlers);
    visibility_glue.syncScreenClaim();
}

pub fn deinit() void {
    const alloc = core.getState().alloc;
    contract.callAll(contract.Segment, bar_mods[0..], .deinit, .{alloc});
    if (gBar.state) |s| {
        s.render.dc.deinit();
        s.deinit();
        gBar.state = null;
    }
    usable_area.releaseClaim();
    usable_area.clearSurfaceWindow();
}

/// Warns about every segment name in the live bar layout that does not resolve
/// to a registry entry. All four layout consumers skip an unresolvable name
/// (`segmod.segId(name) orelse continue`), so a typo -- or a segment dropped from the
/// build -- silently shortens the bar with nothing on stderr to say which entry
/// is the problem. The layout tree is flat (`BarLayout` is a position plus a
/// segment list), so one nested loop is the whole walk.
///
/// This lives here, not in `config.validate`, because the registry is a
/// `bar_modules` comptime table: config sits below the bar in the dependency
/// graph and importing upward would break the no-bar build.
fn warnUnknownSegments() void {
    if (comptime !segmod.hasRegisteredSegments()) return;
    const cfg = &core.getState().config.bar;
    for (cfg.layout.items) |lay| {
        for (lay.segments.items) |name| {
            if (segmod.segId(name) == null) log.warn(
                "Bar: segment '{s}' is not registered; ignoring it. Check the " ++
                    "spelling, or whether this build includes the module.",
                .{name},
            );
        }
    }
}

pub fn reload() void {
    const old = gBar.state orelse {
        if (core.getState().config.bar.enabled) {
            warnUnknownSegments();
            init() catch |err| log.err("Bar init failed: {}", .{err});
        }
        return;
    };
    if (!core.getState().config.bar.enabled) {
        deinit();
        return;
    }
    warnUnknownSegments();
    applyReload(old, resolveBarMetrics()) catch |err| {
        log.err("Bar reload failed ({s}), keeping old bar", .{@errorName(err)});
    };
}

fn applyReload(old: *State, m: Metrics) !void {
    const height = m.height;
    const cs = core.getState();
    // The reload tears down and rebuilds the bar window, so the whole swap has
    // to be atomic: without a grab the old bar can be destroyed and the new one
    // not yet mapped, which shows as a blank shelf. This path used to call
    // ungrabAndFlush() at the end while NOTHING here took a grab -- an unpaired
    // xcb_ungrab_server. grabOnly (not grabScoped) because the reload runs no
    // geometry pass: building a ctx here would run the pre-reconcile duties,
    // and with no reconcile to follow they would mutate the model for nothing.
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
    // value now, so there is no global left to save and put back (21.5).
    const new_bar = createBar(m, barwin.calcBarYPos(cs.config.bar.bar_position, cs.screen.height_in_pixels, height)) catch |err| {
        // The caller has already swapped cs.config to the new config and frees
        // the OLD config when this returns. The old bar survives this failed
        // reload; it used to need its cached config copy re-pointed here or the
        // next draw would read freed memory. It reads the live config now
        // (renderBar), so there is nothing to repair.
        return err;
    };
    const new_state = new_bar.state;
    new_state.vis.shown = old.vis.shown;
    new_state.vis.preferred = old.vis.preferred;
    gBar.state = new_state;
    usable_area.setSurfaceWindow(new_bar.setup.win_id);
    visibility_glue.syncScreenClaim();
    repaint.submitDrawBlockingFull();
    if (new_state.vis.shown) _ = xcb.xcb_map_window(cs.conn, new_bar.setup.win_id);
    // No explicit destroy: `deinit` now owns the window and its colormap.
    old.render.dc.deinit();
    old.deinit();
}

// Public event handlers & queries

/// Moves the bar window to the edge the config now names, and publishes the
/// resulting screen claim. Returns the new edge-relative y.
///
/// Strictly the renderer's half of a position change: it moves its own window
/// and reports its new occupancy. It does NOT decide which edge that is (core
/// owns that flip), and it does NOT reconcile -- reconciling takes the X grab,
/// and doing that from a rendering module was the layering violation this
/// split exists to remove (20.2). The caller reconciles, after this has
/// published the claim, so window placement is re-derived from the new usable
/// area.
pub fn applyBarScreenPosition() i16 {
    const s = gBar.state orelse return 0;
    const cs = core.getState();
    const new_y = barwin.calcBarYPos(cs.config.bar.bar_position, cs.screen.height_in_pixels, s.render.height);
    barwin.setWindowProperties(s.win.win_id, s.render.height);
    repaint.requestFullRedraw();
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
    visibility_glue.syncScreenClaim();
    return new_y;
}

/// The surface hook for the toggle-bar-position action: ask core to flip the
/// edge, then re-anchor. The reconcile that follows is the caller's (see
/// input.zig's `.toggle_bar_position` action), because it is a layout
/// decision made outside the renderer.
pub fn toggleBarSegmentAnchor() void {
    _ = core.toggleBarScreenPosition();
    _ = applyBarScreenPosition();
}

pub fn isBarWindow(win: u32) bool {
    return if (gBar.state) |s| s.win.win_id == win else false;
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
        repaint.submitDrawBlockingFull();
    }
    visibility_glue.raiseBar();
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
    const s = gBar.state orelse return;
    if (!gBar.prompt_forced_visible) return;
    gBar.prompt_forced_visible = false;
    const current_ws = tracking.getCurrentWorkspace() orelse 0;
    const should_show = visibility.keepPromptOverride(pipeline.model(), current_ws, s.vis.preferred);
    if (should_show) return; // conditions changed while the prompt was open; stay visible
    s.vis.shown = false;
    _ = xcb.xcb_unmap_window(s.win.conn, s.win.win_id);
    _ = xcb.xcb_flush(s.win.conn);
}

/// Sets the bar's user-level visibility state. Only the user toggle path
/// arrives here (keybind / config action). Fullscreen-driven hide/show is NOT
/// a named call: the bar derives it reactively from the core fullscreen fact
/// revision in `applyFullscreenVisibility`, so no subsystem pokes the bar.
pub fn setBarState(action: types.Action) void {
    const s = gBar.state orelse return;
    if (action == .toggle_bar_visibility) s.vis.preferred = !s.vis.preferred;
    visibility_glue.applyFullscreenVisibility();
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
        visibility_glue.applyFullscreenVisibility();
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
    if (s.facts.focus_rev != focus_rev) s.markDirtySource(.focus);
    // window_rev previously skipped through blanket `markDirty()` even though
    // title and tags declare they want `.frame` dirtying; using the frame
    // source keeps the non-frame segments (clock, carousel, systatus) from
    // being swept along on every window churn fact bump.
    if (s.facts.window_rev != window_rev) s.markDirtySource(.frame);
    if (s.facts.layout_rev != layout_rev) {
        repaint.requestFullRedraw();
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
        _ = repaint.foldModuleRedraw(s);
        if (!s.dirty.flag) break;
        repaint.performDraw();
    }
    if (redraw_iter == max_batched_redraws)
        log.info("bar: updateIfDirty redraw loop hit its iteration cap, stalling re-request", .{});
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

    if (s.adoptFreshClockWidth()) {
        // Re-lay and repaint the row in this same call, then ship it. updateClock
        // is the last statement of the event loop body, i.e. it runs AFTER the
        // end-of-batch flush and after the batch's own updateIfDirty, so merely
        // flagging the redraw left the reflow to the next loop iteration --
        // up to a whole second on an idle bar, which is exactly the stale-length
        // window this path exists to close. performDraw queues its blit, so the
        // flush is ours to make.
        repaint.requestFullRedraw();
        repaint.performDraw();
        _ = xcb.xcb_flush(core.getState().conn);
        return;
    }
    repaint.drawClockOnly(s);
}

/// Comptime-registered UI-surface hooks for core's event loop (comptime
/// reference point: the one place the loop knows the bar exists). Core calls
/// these through a single `surfaces.Surfaces` alias; when the bar is absent the
/// whole set is `null` and every such call site compiles away. The emitter
/// lives in this module, so detaching the bar detaches its handlers. The hook
/// types themselves live in the core-owned `plugin` interface contract, not
/// here: this module only binds its functions to that contract.
pub const surfaces = @import("seams").Surfaces{
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
    .hideBarForFullscreen = visibility_glue.hideBarForFullscreen,
    .updateBarVisibilityForWorkspace = visibility_glue.updateBarVisibilityForWorkspace,
    .toggleBarSegmentAnchor = toggleBarSegmentAnchor,
    .barForcedHiddenByFullscreen = visibility.barForcedHiddenByFullscreen,
    .chromeToggleOverlay = chromeToggleOverlay,
};
