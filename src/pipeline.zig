//! Model-pipeline entry glue (REARCHITECTURE_PLAN.md §E.7). The strangler
//! flag is gone (fix P1-6): the model path IS the path. This module owns the
//! global Model instance, builds the per-reconcile sync.Ctx from live state,
//! and exposes the reconcile slots entry points call.
//!
//! Call sites (all marked `// PIPELINE:`):
//!   core/main.zig   startup        → init(alloc)
//!   events.zig      dispatch tail  → postDispatch() (scheduled reconciles)
//!   input.zig       finishTilingOp → tilingOpFinished()
//!   floating.zig    updateDrag     → dragTick()
//!   window.zig      unmanage/EWMH  → actions.unmanage / fullscreenToggleWindow

const std = @import("std");
const model_mod = @import("model");
const sync = @import("sync");
const layouts = @import("layouts");
const core = @import("core");
const utils = @import("utils");
const borders = @import("borders");
const focus = @import("focus");
const xcb_sink = @import("xcb_sink");
const build_options = @import("build_options");
const bar = if (build_options.has_bar) @import("bar") else null;

/// True after init(); tracking's facade gates every model access on this so
/// boot order never touches the undefined global instance.
pub var initialized: bool = false;

var instance: model_mod.Model = undefined;
pub fn init(gpa: std.mem.Allocator) void {
    instance = .{ .gpa = gpa };
    initialized = true;
    sync.init(gpa);
}
pub inline fn model() *model_mod.Model {
    return &instance;
}

var g_sink: ?xcb_sink.XcbSink = null;
var g_ctx: sync.Ctx = undefined;

/// Builds the per-retile Ctx from live state exactly as invokeLayout resolved
/// its inputs (§7.4 step 3): workarea via bar's helper, margins/min_dim and
/// variant booleans from config, border width from borders.width(), colors
/// from config.tiling. Only valid after init().
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
        .workarea = if (build_options.has_bar) bar.workAreaRect() else .{
            .x = 0,
            .y = 0,
            .width = cs.screen.width_in_pixels,
            .height = screen_h,
        },
        .cfg_bw = borders.width(),
        .env = .{
            .margins = .{
                .gap = utils.scaling.scaleBorderWidth(cs.config.tiling.gap_width, screen_h),
                .border = utils.scaling.scaleBorderWidth(cs.config.tiling.border_width, screen_h),
            },
            .min_dim = cs.config.tiling.min_window_dim,
            .master_on_right = cs.config.tiling.master_side == .right,
            // Variant booleans resolve from the CURRENT workspace's model
            // params (train g): per-ws overrides and stepVariant must reach
            // the engine, which takes booleans caller-side (§7.4 step 3).
            .grid_relaxed = variantBool(.grid),
            .monocle_gaps = variantBool(.monocle),
        },
        .color_of = colorOf,
        .bar_win = if (build_options.has_bar and bar.isVisible()) bar.getBarWindow() else null,
    };
    return &g_ctx;
}

/// Variant boolean for the current workspace's params (train g): the engine
/// takes resolved booleans caller-side (§7.4 step 3).
fn variantBool(comptime kind: model_mod.LayoutKind) bool {
    const p = &model().ws[model().current].params;
    return p.kind == kind and p.variant_idx == 1;
}

/// Ported from borders.color minus its fullscreen check: fullscreen windows
/// get bw=0/pixel=0 through the fullscreen branch policy in sync instead.
/// Reads MODEL focus (fix P2-8) — focus.zig mirrors every transition into
/// m.focused, so this is the same single source of truth as everything else.
fn colorOf(win: model_mod.WindowId, m: *const model_mod.Model) u32 {
    const cfg = &core.getState().config.tiling;
    return if (m.focused == win) cfg.border_focused else cfg.border_unfocused;
}

pub inline fn postDispatch() void {
    // Consume the focus-change-class flag (fix P1-4): one flushless diff
    // against LastSent sends only stale border pixels/geometry, then the
    // dispatch tail owns the flush (I2).
    if (sync.takeScheduled()) {
        preReconcileDuties();
        sync.reconcile(&instance, ctx(), .{});
        ctx().sink.flush();
    }
}

/// Schedule a coalesced end-of-dispatch reconcile (focus-color class).
pub inline fn scheduleReconcile() void {
    sync.scheduled = true;
}
pub inline fn tilingOpFinished() void {
    reconcileUnderGrabNow(.{});
}
pub inline fn dragTick() void {
    reconcileNow();
}

/// Scroll viewport caller duties (changelog 2026-08-22, C-D2/D3) applied at
/// the single reconcile choke point: snap right when the visible count grew
/// since the last retile (spawn/restore/tag-add), then clamp to content.
fn preReconcileDuties() void {
    const algo_scroll = @import("algo_scroll");
    const m = model();
    const p = &m.ws[m.current].params;
    if (p.kind != .scroll) return;
    var n: usize = 0;
    for (m.ws[m.current].tiled_order.items) |w| {
        const e = m.store.get(w) orelse continue;
        if (e.mask & @import("model").bit(m.current) == 0) continue;
        n += 1;
    }
    const wa = if (build_options.has_bar) bar.workAreaRect() else return;
    const slot_w = algo_scroll.slotWidth(wa.width);
    const max_off = algo_scroll.maxOffset(n, slot_w, wa.width);
    if (n > p.scroll_prev_count) p.scroll_offset = max_off;
    p.scroll_offset = std.math.clamp(p.scroll_offset, 0, max_off);
    p.scroll_prev_count = @intCast(n);
}

/// Grab server → reconcile → ungrabAndFlush, atomically (train step a:
/// BC06 minimize atomicity; E.6 wrappers call this after model transitions).
pub inline fn reconcileUnderGrabNow(o: sync.ReconcileOpts) void {
    preReconcileDuties();
    sync.reconcileUnderGrab(&instance, ctx(), o);
}

/// Flushless reconcile against the current ctx (drag tick path).
pub inline fn reconcileNow() void {
    preReconcileDuties();
    sync.reconcile(&instance, ctx(), .{});
}

/// Reconcile while the CALLER holds the server grab and owns the flush
/// (train h: bar show/hide path). No grab, no flush here.
pub inline fn reconcileInGrab() void {
    preReconcileDuties();
    sync.reconcile(&instance, ctx(), .{});
}
