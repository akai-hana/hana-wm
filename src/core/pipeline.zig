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
const xcb_sink = @import("wire");
const screen = @import("screen");
const types = @import("types");
const build_options = @import("build_options");
// The fullscreen EWMH/bar-arming hooks are reached through the build-generated
// `window_modules` registry (never by naming a sub-system module here),
// mirroring the surfaces seam. `window_mods` is the auto-discovered
// `[N]WindowModule` array; a tree without fullscreen simply has no module
// providing these hooks, so the uniform loop below no-ops for it.
const window_mods = @import("window_modules").modules;

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

/// Returns the current tiling layout from the live model state.
/// Falls back to config pre-init.
pub inline fn getCurrentLayout() types.Layout {
    if (initialized) {
        const mm = model();
        const p = &mm.ws[mm.current].params;
        return @enumFromInt(@intFromEnum(p.kind));
    }
    const cs = core.getState();
    return std.meta.stringToEnum(types.Layout, cs.config.tiling.layout) orelse types.layout_table[0].tag;
}

var g_sink: ?xcb_sink.XcbSink = null;
var g_ctx: sync.Ctx = undefined;

/// Builds the per-retile Ctx from live state: workarea via bar's helper,
/// margins/min_dim and variant booleans from config, border width from
/// borders.width(), colors from config.tiling. Only valid after init().
fn ctx() *sync.Ctx {
    const cs = core.getState();
    if (g_sink == null) g_sink = .{ .conn = cs.conn };
    const screen_h = cs.screen.height_in_pixels;
    g_ctx = .{
        .sink = (&g_sink.?).sink(),
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
            .master_on_right = cs.config.tiling.master_side == .right,
            // Variant booleans resolve from the CURRENT workspace's model
            // params: per-ws overrides and stepVariant must reach the engine,
            // which takes booleans caller-side.
            .grid_relaxed = variantBool(.grid),
            .monocle_gaps = variantBool(.monocle),
        },
        .color_of = colorOf,
        .bar_win = screen.mappedSurfaceWindow(),
    };
    return &g_ctx;
}

/// Variant boolean for the current workspace's params: the engine takes
/// resolved booleans caller-side.
fn variantBool(comptime kind: model_mod.LayoutKind) bool {
    const p = &model().ws[model().current].params;
    return p.kind == kind and p.variant_idx == 1;
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
pub inline fn dragTick() void {
    reconcileNow();
}

/// Scroll viewport caller duties applied at the single reconcile choke
/// point: snap right when the visible count grew since the last retile
/// (spawn/restore/tag-add), then clamp to content.
fn preReconcileDuties() void {
    if (!build_options.has_tiling) return;
    if (!build_options.has_layout_scroll) return;
    const algo_scroll = @import("scroll");
    const m = model();
    const p = &m.ws[m.current].params;
    if (p.kind != .scroll) return;
    var n: usize = 0;
    for (m.ws[m.current].tiled_order.constSlice()) |w| {
        const e = m.store.get(w) orelse continue;
        if (e.mask & @import("model").bit(m.current) == 0) continue;
        n += 1;
    }
    const wa = screen.workArea(core.getState().screen);
    const slot_w = algo_scroll.slotWidth(wa.width);
    const max_off = algo_scroll.maxOffset(n, slot_w, wa.width);
    if (n > p.scroll_prev_count) p.scroll_offset = max_off;
    p.scroll_offset = std.math.clamp(p.scroll_offset, 0, max_off);
    p.scroll_prev_count = @intCast(n);
}

/// Grab server, reconcile, then ungrabAndFlush, atomically.
pub inline fn reconcileUnderGrabNow(o: sync.ReconcileOpts) void {
    preReconcileDuties();
    sync.reconcileUnderGrab(&instance, ctx(), o);
}

/// Grab server, run the focus transition, reconcile, then ungrabAndFlush (or
/// the reverse order) atomically. When `focus_before` is true, focus lands
/// BEFORE geometry, which most actions want when the target window is already
/// mapped and focus must precede the retile. When false, focus lands
/// AFTER geometry; used on mapRequest where the window must be mapped (by
/// reconcile) before xcb_set_input_focus can target it without BadMatch.
pub inline fn reconcileGrabFocus(o: sync.ReconcileOpts, t: focus.FocusTransition, focus_before: bool) void {
    preReconcileDuties();
    const c = ctx();
    c.sink.grabServer();
    defer c.sink.ungrabAndFlush();
    if (focus_before) focus.applyPendingFocus(t);
    sync.reconcile(&instance, c, o);
    if (!focus_before) focus.applyPendingFocus(t);
}

/// Grab server, commit focus transition, reconcile, then ungrabAndFlush,
/// atomically. Focus lands BEFORE geometry: for most actions where the target
/// window is already mapped and focus must precede the retile so border colors
/// and stacking are correct on the first frame.
pub inline fn reconcileUnderGrabNowWithFocus(o: sync.ReconcileOpts, t: focus.FocusTransition) void {
    reconcileGrabFocus(o, t, true);
}

/// Grab server, reconcile, commit focus transition, then ungrabAndFlush,
/// atomically. Focus lands AFTER geometry: for mapRequest where the window
/// must be mapped (by reconcile) before xcb_set_input_focus can target it
/// without BadMatch. Both map+focus under one grab eliminates the atomicity
/// gap where a client could observe the mapped-but-unfocused window.
pub inline fn reconcileUnderGrabNowWithFocusAfter(o: sync.ReconcileOpts, t: focus.FocusTransition) void {
    reconcileGrabFocus(o, t, false);
}

/// Grab server, reconcile, do EWMH + bar arming, then ungrabAndFlush, atomically.
/// Specialised for the fullscreen toggle path where EWMH writes and deferred
/// bar state must land inside the same grab as geometry (Gap 2 atomicity).
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
    // the was_switch/was_exit/instance.focused logic are unchanged.
    for (window_mods) |m| {
        if (m.setEwmhFullscreenState) |f| {
            if (was_switch) {
                if (prev_fs_win) |old| f(old, false);
            }
            f(win, !was_exit);
        }
    }
    // Deferred bar state inside the grab: pure flag sets, no X traffic.
    // was_exit is binary, so each module runs at most one of the two arms,
    // preserving the original if/else-if exclusion per module.
    for (window_mods) |m| {
        if (m.armPendingBarHide) |f| {
            if (!was_exit) f(win);
        }
        if (m.armPendingBarShow) |show| {
            if (was_exit) if (instance.focused) |w| show(w);
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
