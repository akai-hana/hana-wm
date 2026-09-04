//! Model-pipeline entry glue. This module owns the global Model instance,
//! builds the per-reconcile sync.Ctx from live state, and exposes the
//! reconcile slots entry points call.
//!
//! Call sites (all marked `// PIPELINE:`):
//!   src/main.zig    startup calls init(alloc)
//!   input.zig       finishTilingOp calls tilingOpFinished()
//!   floating.zig    updateDrag calls dragTick()
//!   window.zig      unmanage/EWMH call actions.unmanage / fullscreenToggleWindow

const std = @import("std");
const model_mod = @import("model");
const sync = @import("sync");
const core = @import("core");
const utils = @import("utils");
const borders = @import("borders");
const focus = @import("focus");
const xcb_sink = @import("sink");
const screen = @import("screen");
const types = @import("types");
const debug = @import("debug");
const build_options = @import("build_options");
const surfaces = @import("plugins").Surfaces;
// Fullscreen EWMH/bar-arming hooks are reached through the build-generated
// `window_modules` registry; `window_mods` is the auto-discovered
// `[N]WindowModule` array, and the uniform loop below no-ops without fullscreen.
const window_mods = @import("window_modules").modules;

/// Layout registry (build-generated); the active layout is a `u8` index into
/// it (see model.LayoutParams.kind). Empty when the tiling subsystem is
/// absent. Gated on has_tiling so tree variants without tiling compile.
const tiling_mods = @import("plugin").tiling_mods;
const tiling = if (build_options.has_tiling) @import("tiling") else struct {};

/// True after init(); tracking's facade gates every model access on this so
/// boot order never touches the undefined global instance.
pub var initialized: bool = false;

var instance: model_mod.Model = undefined;
pub fn init(_: std.mem.Allocator) void {
    instance = .{}; // bounded lists: no allocator inside the model
    initialized = true;
    sync.init();
}
pub inline fn model() *model_mod.Model {
    if (!initialized) @panic("pipeline.model() called before init()");
    return &instance;
}

/// Returns the current tiling layout (a registry index, see
/// model.LayoutParams.kind) from the live model state. Falls back to config
/// name resolution pre-init. An unresolvable config name (removed module,
/// unknown spelling) is loud, never silent.
pub inline fn getCurrentLayout() u8 {
    if (initialized) return model().ws[model().current].params.kind;
    const cs = core.getState();
    if (!build_options.has_tiling) return 0;
    return @intCast(tiling.layoutByName(cs.config.tiling.layout) orelse blk: {
        debug.warn(
            "Config: layout name '{s}' did not resolve to a registered " ++
                "layout; using default layout '{s}'",
            .{
                cs.config.tiling.layout,
                tiling.moduleName(tiling.defaultKind()),
            },
        );
        break :blk tiling.defaultKind();
    });
}

var g_sink: ?xcb_sink.XcbSink = null;

/// Lazily-build the shared XCB sink. Cache hit after first build: pure pointer
/// deref + vtable copy, no syscalls, no config/screen reads.
inline fn sink() sync.Sink {
    if (g_sink == null) g_sink = .{ .conn = core.getState().conn };
    return (&g_sink.?).sink();
}

var g_ctx: sync.Ctx = undefined;

/// Builds the per-retile Ctx from live state: workarea via bar's helper,
/// margins/min_dim and variant booleans from config, border width from
/// borders.width(), colors from config.tiling. Only valid after init().
fn ctx() *sync.Ctx {
    const cs = core.getState();
    const screen_h = cs.screen.height_in_pixels;
    const p = &model().ws[model().current].params;
    g_ctx = .{
        .sink = sink(),
        .screen = .{
            .x = 0,
            .y = 0,
            .width = cs.screen.width_in_pixels,
            .height = screen_h,
        },
        .workarea = screen.workArea(cs.screen),
        .cfg_bw = borders.width(),
        .env = .{
            .margins = .{
                .gap = utils.scaling.scaleBorderWidth(cs.config.tiling.gap_width, screen_h),
                .border = utils.scaling.scaleBorderWidth(cs.config.tiling.border_width, screen_h),
            },
            .min_dim = cs.config.tiling.min_window_dim,
            .primary_on_right = cs.config.tiling.master_side == .right,
            // The model already stores the variant index for the current
            // workspace's layout params; pass it through generically. Each
            // layout MODULE translates this index to its own behavior
            // (e.g. monocle.gap_variant, grid.relax_variant) inside its own
            // file — the core carries no layout-feature booleans.
            .variant_idx = p.variant_idx,
        },
        .color_of = colorOf,
        .bar_win = screen.mappedSurfaceWindow(),
    };
    return &g_ctx;
}

/// Ported from borders.color minus its fullscreen check: fullscreen windows
/// get bw=0/pixel=0 through the fullscreen branch policy in sync instead.
/// Reads MODEL focus; focus.zig mirrors every transition into m.focused,
/// so this is the same single source of truth.
fn colorOf(win: model_mod.WindowId, m: *const model_mod.Model) u32 {
    const cfg = &core.getState().config.tiling;
    return if (m.focused == win) cfg.border_focused else cfg.border_unfocused;
}

pub inline fn tilingOpFinished() void {
    reconcileUnderGrabNow(.{});
}
var drag_tick_sum_ns: u64 = 0;
var drag_tick_count: u64 = 0;

/// Per-tick latency instrumentation for the drag reconcile (targeted path).
/// Measured from just before reconcileDragTick to just after it returns
/// (all work is in-process: one queued XCB configure, no round trip).
pub inline fn dragTick(win: model_mod.WindowId) void {
    const s = sink();
    const t0 = utils.monotonicNs();
    sync.reconcileDragTick(&instance, s, win);
    drag_tick_sum_ns += utils.monotonicNs() - t0;
    drag_tick_count += 1;
}

/// Running average of the per-tick drag reconcile latency, in nanoseconds.
pub fn dragTickLatency() ?struct { avg_ns: u64, count: u64 } {
    if (drag_tick_count == 0) return null;
    return .{ .avg_ns = drag_tick_sum_ns / drag_tick_count, .count = drag_tick_count };
}

/// Scroll viewport caller duties applied at the single reconcile choke
/// point, dispatched through the active layout module's preReconcile hook
/// (the scroll addon registers snap-right-on-growth + clamp; a layout that
/// provides no hook has no pre-reconcile duty).
fn preReconcileDuties() void {
    if (!build_options.has_tiling) return;
    const m = model();
    const p = &m.ws[m.current].params;
    if (p.kind >= tiling_mods.len) return;
    const md = tiling_mods[p.kind];
    if (md.preReconcile == null) return;
    var n: usize = 0;
    for (m.ws[m.current].tiled_order.constSlice()) |w| {
        const e = m.store.get(w) orelse continue;
        if (e.mask & @import("model").bit(m.current) == 0) continue;
        n += 1;
    }
    const wa = screen.workArea(core.getState().screen);
    md.preReconcile.?(@ptrCast(p), n, wa.width);
}

/// Grab server, reconcile, then ungrabAndFlush, atomically.
pub inline fn reconcileUnderGrabNow(o: sync.ReconcileOpts) void {
    preReconcileDuties();
    sync.reconcileUnderGrab(&instance, ctx(), o);
}

/// Grab server, run the focus transition, reconcile, then ungrabAndFlush (or
/// the reverse order) atomically. When `focus_before` is true, focus lands
/// before geometry (most actions); when false it lands after (mapRequest,
/// where the window must be mapped before xcb_set_input_focus targets it).
pub inline fn reconcileGrabFocus(
    o: sync.ReconcileOpts,
    t: focus.FocusTransition,
    focus_before: bool,
) void {
    preReconcileDuties();
    const c = ctx();
    c.sink.grabServer();
    defer c.sink.ungrabAndFlush();
    if (focus_before) focus.applyPendingFocus(t);
    sync.reconcile(&instance, c, o);
    if (!focus_before) focus.applyPendingFocus(t);
}

/// Grab server, commit focus transition, reconcile, then ungrabAndFlush
/// atomically. Focus lands before geometry so border colors and stacking are
/// correct on the first frame.
pub inline fn reconcileUnderGrabNowWithFocus(o: sync.ReconcileOpts, t: focus.FocusTransition) void {
    reconcileGrabFocus(o, t, true);
}

/// Focus lands after geometry, for mapRequest: the window must be mapped (by
/// reconcile) before xcb_set_input_focus can target it without BadMatch.
/// Both map+focus under one grab eliminates the atomicity gap where a client
/// could observe the mapped-but-unfocused window.
pub inline fn reconcileUnderGrabNowWithFocusAfter(
    o: sync.ReconcileOpts,
    t: focus.FocusTransition,
) void {
    reconcileGrabFocus(o, t, false);
}

/// Grab server, reconcile, do EWMH + bar hide, then ungrabAndFlush, atomically.
/// Specialised for the fullscreen toggle path so EWMH writes and the bar
/// unmap/hide land inside the same grab as geometry (Gap 2 atomicity); the
/// enter path unmaps the bar immediately rather than deferring to ConfigureNotify.
pub inline fn reconcileUnderGrabNowFullscreen(
    o: sync.ReconcileOpts,
    win: model_mod.WindowId,
    prev_fs_win: ?model_mod.WindowId,
    was_exit: bool,
    was_switch: bool,
) void {
    preReconcileDuties();
    const c = ctx();
    c.sink.grabServer();
    defer c.sink.ungrabAndFlush();
    sync.reconcile(&instance, c, o);
    // EWMH advertisement inside the grab: clear for whoever left
    // fullscreen, set for entrant. All fire-and-forget (xcb_change_property).
    // Uniform loop over the sub-system set: each module that provides the
    // hook runs it. In practice only fullscreen does, preserving the old
    // gated single hook call exactly; the loop just makes the dispatch
    // mechanism uniform rather than a merged struct. Ordering and
    // the was_switch/was_exit/instance.focused logic is unchanged.
    for (window_mods) |m| {
        if (m.setEwmhFullscreenState) |f| {
            if (was_switch) {
                if (prev_fs_win) |old| f(old, false);
            }
            f(win, !was_exit);
        }
    }
    // Bar hide/show inside the grab: no separate grab/reconcile cycle.
    //
    // ENTER: immediately unmap the bar via the surfaces seam. The fullscreen
    // client is already mapped+raised+screen-sized by sync.reconcile, so it
    // covers the bar before the unmap reaches the server. Cancel any stale
    // pending bar show from a previous exit (a new enter supersedes it).
    //
    // EXIT: arm the deferred show. The bar reappears after the client's
    // ConfigureNotify confirms non-fullscreen dimensions.
    if (!was_exit) {
        // Cancel any stale pending bar show from a previous exit.
        for (window_mods) |m| _ = m.armPendingBarShow;
        // Immediate bar unmap when fullscreen claims the screen.
        if (build_options.has_bar) surfaces.hideBarForFullscreen();
    } else {
        // Exit: deferred bar show (unchanged path).
        for (window_mods) |m| {
            if (m.armPendingBarShow) |show| {
                if (instance.focused) |w| show(w);
            }
        }
    }
}

/// Flushless reconcile against the current ctx (drag tick path).
pub inline fn reconcileNow() void {
    preReconcileDuties();
    sync.reconcile(&instance, ctx(), .{});
}

/// Run pre-reconcile duties and return the pipeline context for the caller
/// to manage a manual server grab. The caller MUST call
/// ctx.sink.ungrabAndFlush() when done (typically via defer). Used by
/// switchTo where a pointer query must land inside the grab body.
pub fn grabCtx() *sync.Ctx {
    preReconcileDuties();
    return ctx();
}
