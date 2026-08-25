//! Scroll tiling layout (pure port of modules/scroll.zig, viewport state model-owned).
//! Half-screen slots in a scrollable horizontal strip with viewport management.

const utils = @import("utils");
const model = @import("model");
const engine = @import("engine");

const View = engine.View;
const List = engine.List;

// CALLER DUTIES: before compute(), the caller must replicate on
// params.scroll_offset / params.scroll_prev_count:
//   1. if (n > scroll_prev_count) scroll_offset = maxOffset(n, slotWidth(wa.w), wa.w);
//   2. scroll_offset = clamp(scroll_offset, 0, maxOffset(...));
//   3. scroll_prev_count = n;
// This module exposes slotWidth/maxOffset as the single source of truth for
// those adjustments (mirrors legacy exports consumed by actions/tiling.zig).

/// Pixel width of one scroll slot: exactly half the screen width. Single
/// source of truth; step, snapOffsetToWindow, and compute all derive
/// their geometry from it.
pub inline fn slotWidth(screen_w: u16) i32 {
    return @intCast(screen_w / 2);
}

/// Maximum scroll offset: reached when the last of `n` windows' right edge
/// is flush with the screen's right edge. Zero (nothing to scroll) when the
/// strip is no wider than the screen.
pub inline fn maxOffset(n: usize, slot_w: i32, screen_w: u16) i32 {
    const n_i32: i32 = @intCast(n);
    const sw_i32: i32 = @intCast(screen_w);
    return @max(0, n_i32 * slot_w - sw_i32);
}

pub fn compute(v: View, out: *List) void {
    const windows = v.order;

    const m = v.env.margins;

    const screen_w = v.workarea.width;
    const screen_h = v.workarea.height;

    const slot_w: i32 = slotWidth(screen_w);

    const sw_i32: i32 = @intCast(screen_w);

    // Caller pre-clamped (see header); consumed read-only.
    const scroll: i32 = v.params.scroll_offset;

    const content_h: u16 = engine.shrinkClamped(screen_h, m.gap *| 2 +| m.border *| 2, v.env.min_dim);
    const win_y: i32 = @as(i32, @intCast(engine.waY(&v))) + @as(i32, @intCast(m.gap));

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
            engine.emitHidden(out, win);
            continue;
        }
        const rect = utils.Rect{
            .x = @intCast(x),
            .y = @intCast(win_y),
            .width = content_w,
            .height = content_h,
        };
        engine.emitView(&v, out, win, rect, true);
    }
}
