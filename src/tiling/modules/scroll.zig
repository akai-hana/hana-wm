//! Scroll tiling layout.
//! Places windows in half-screen slots along a scrollable horizontal strip.

const utils = @import("utils");
const model = @import("model");
const tiling = @import("tiling");
const std = @import("std");

// CALLER DUTIES: the viewport bookkeeping on params.viewport_offset /
// params.viewport_prev_count. Offset clamping is internal to compute(), so only
// the snap-right-on-grow and the count update are required
// (pipeline.preReconcileDuties):
//   1. if (n > viewport_prev_count) viewport_offset = maxOffset(n, slotWidth(wa.w), wa.w);
//   2. viewport_prev_count = n;
// slotWidth/maxOffset are the single source of truth for these adjustments
// and are also consumed directly by window/actions.zig.

/// Pixel width of one scroll slot: exactly half the screen width. Single
/// source of truth; maxOffset and compute derive their geometry from it.
pub fn slotWidth(screen_w: u16) i32 {
    return @intCast(screen_w / 2);
}

/// Maximum scroll offset: reached when the last of `n` windows' right edge
/// is flush with the screen's right edge. Zero (nothing to scroll) when the
/// strip is no wider than the screen.
pub fn maxOffset(n: usize, slot_w: i32, screen_w: u16) i32 {
    const n_i32: i32 = @intCast(n);
    const sw_i32: i32 = @intCast(screen_w);
    return @max(0, n_i32 * slot_w - sw_i32);
}

/// Compute scroll layout. Origin top-left, y-down. Each slot is half the
/// screen width; full gap at screen edges, half-gap at interior slot
/// boundaries. Off-viewport slots are hidden. Scroll offset is caller-set;
/// compute clamps it internally. All dims u16, clamped to min_dim.
pub fn compute(v: tiling.View, out: *tiling.List) void {
    const windows = v.order;

    const m = v.env.margins;

    const screen_w = v.workarea.width;
    const screen_h = v.workarea.height;

    const slot_w: i32 = slotWidth(screen_w);

    const sw_i32: i32 = @intCast(screen_w);

    // Clamp internally so compute is self-contained; callers that pre-clamp
    // (pipeline.preReconcileDuties) are still correct but no longer required.
    const scroll: i32 = @max(0, @min(v.params.viewport_offset, maxOffset(windows.len, slot_w, screen_w)));

    // Border is subtracted here (once) from the full screen height. emitView
    // calls applyHints which only applies ICCCM constraints (inc snap,
    // max-size clamp, aspect ratio). It does NOT touch border, so there is
    // no double-subtraction.
    const content_h: u16 = tiling.shrinkClamped(screen_h, m.gap *| 2 +| m.border *| 2, v.env.min_dim);
    const win_y: i32 = @as(i32, @intCast(tiling.waY(&v))) + @as(i32, @intCast(m.gap));

    // Full gap at screen edges; half-gap at interior slot boundaries so that
    // adjacent windows together share exactly one full gap.
    const gap_i32: i32 = @intCast(m.gap);
    const gap_half: i32 = @intCast(m.gap / 2);
    const border2: i32 = @as(i32, utils.doubledBorder(m));

    for (windows, 0..) |win, i| {
        const col: i32 = @intCast(i);

        const slot_left: i32 = col * slot_w - scroll;

        // <= / >= rather than < / > to handle off-by-one from integer division of odd screen widths.
        const left_inset: i32 = if (slot_left <= 0) gap_i32 else gap_half;
        const right_inset: i32 = if (slot_left + slot_w >= sw_i32) gap_i32 else gap_half;

        const x: i32 = slot_left + left_inset;
        const avail: i32 = slot_w - left_inset - right_inset - border2;
        const content_w: u16 = if (avail > v.env.min_dim)
            @intCast(avail)
        else
            v.env.min_dim;

        const right: i32 = x + avail + border2;

        // Slots entirely off-viewport are parked by the algorithm itself
        // (visibility modeled; sync owns the actual parking geometry).
        // The computed x can exceed i16 range, hence this check BEFORE casting.
        if (x >= sw_i32 or right <= 0) {
            tiling.emitHidden(out, win);
            continue;
        }
        const rect = utils.Rect{
            .x = @intCast(x),
            .y = @intCast(win_y),
            .width = content_w,
            .height = content_h,
        };
        tiling.emitView(&v, out, win, rect, true);
    }
}

/// Pre-reconcile duty, exactly the former pipeline.preReconcileDuties body:
/// snap right when the visible count grew (spawn/restore/tag-add), then
/// clamp to content. `p` is `*model.LayoutParams`.
fn preReconcileHook(p: *anyopaque, n: usize, wa_width: u16) void {
    const lp: *model.LayoutParams = @ptrCast(@alignCast(p));
    const slot_w = slotWidth(wa_width);
    const max_off = maxOffset(n, slot_w, wa_width);
    if (n > lp.viewport_prev_count) lp.viewport_offset = max_off;
    lp.viewport_offset = std.math.clamp(lp.viewport_offset, 0, max_off);
    lp.viewport_prev_count = @intCast(n);
}

/// This layout's registry contribution: metadata plus the dispatch hooks.
pub const module: @import("plugin").Layout = .{
    .name = "scroll",
    .compute = tiling.computeHook(compute),
    .variant_count = 1,
    .slotWidth = slotWidth,
    .maxOffset = maxOffset,
    .preReconcile = preReconcileHook,
    .icon = "[|]",
};
