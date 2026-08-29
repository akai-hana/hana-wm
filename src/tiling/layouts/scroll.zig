//! Scroll tiling layout.
//! Places windows in half-screen slots along a scrollable horizontal strip.

const utils = @import("utils");
const model = @import("model");
const engine = @import("engine");

// CALLER DUTIES: the viewport bookkeeping on params.scroll_offset /
// params.scroll_prev_count. Offset clamping is internal to compute(), so only
// the snap-right-on-grow and the count update are required
// (pipeline.preReconcileDuties):
//   1. if (n > scroll_prev_count) scroll_offset = maxOffset(n, slotWidth(wa.w), wa.w);
//   2. scroll_prev_count = n;
// slotWidth/maxOffset are the single source of truth for these adjustments
// and are also consumed directly by window/actions.zig.

/// Pixel width of one scroll slot: exactly half the screen width. Single
/// source of truth; maxOffset and compute derive their geometry from it.
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

/// Compute scroll layout. Origin top-left, y-down. Each slot is half the
/// screen width; full gap at screen edges, half-gap at interior slot
/// boundaries. Off-viewport slots are hidden. Scroll offset is caller-set;
/// compute clamps it internally. All dims u16, clamped to min_dim.
pub fn compute(v: engine.View, out: *engine.List) void {
    const windows = v.order;

    const m = v.env.margins;

    const screen_w = v.workarea.width;
    const screen_h = v.workarea.height;

    const slot_w: i32 = slotWidth(screen_w);

    const sw_i32: i32 = @intCast(screen_w);

    // Clamp internally so compute is self-contained; callers that pre-clamp
    // (pipeline.preReconcileDuties) are still correct but no longer required.
    const scroll: i32 = @max(0, @min(v.params.scroll_offset, maxOffset(windows.len, slot_w, screen_w)));

    // Border is subtracted here (once) from the full screen height. emitView
    // calls applyHints which only applies ICCCM constraints (inc snap,
    // max-size clamp, aspect ratio). It does NOT touch border, so there is
    // no double-subtraction.
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
