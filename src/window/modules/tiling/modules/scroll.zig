//! Scrolling tiling layout
//! Arranges windows in a horizontal strip of equal-width slots (each half the screen width)
//! with a scrollable viewport. New windows snap the viewport right so they appear immediately;
//! manual scrolling and window closes are handled by clamping on every retile.

const std = @import("std");

const core      = @import("core");
const utils     = @import("utils");
const constants = @import("constants");

const tiling  = @import("tiling");
const layouts = @import("layouts");

// i16 bounds for utils.Rect.x; positions outside this range are parked at
// OFFSCREEN_X_POSITION rather than sent as an overflowing cast to the X server.
const I16_MAX: i32 = std.math.maxInt(i16);
const I16_MIN: i32 = std.math.minInt(i16);

pub fn tileWithOffset(
    ctx:      *const layouts.LayoutCtx,
    state:    *tiling.State,
    windows:  []const u32,
    screen_w: u16,
    screen_h: u16,
    y_offset: u16,
) void {
    const n = windows.len;
    if (n == 0) return;

    const m = state.margins();

    // Every slot is exactly half the screen width.
    const slot_w: i32 = @intCast(screen_w / 2);

    const n_i32: i32  = @intCast(n);
    const sw_i32: i32 = @intCast(screen_w);

    // Max scroll: reached when the last window's right edge is flush with the screen.
    const max_off: i32 = @max(0, n_i32 * slot_w - sw_i32);

    // New window: snap viewport right so it is immediately visible.
    // Killed window: the clamp below is sufficient.
    if (n > state.scroll.prev_n) {
        state.scroll.offset = max_off;
    }
    state.scroll.prev_n = n;

    // Clamp keeps the offset in [0, max_off] after manual scrolling or kills.
    state.scroll.offset = std.math.clamp(state.scroll.offset, 0, max_off);
    const scroll: i32 = state.scroll.offset;

    const content_h: u16 = calcContentH(screen_h, m);
    const win_y: i32     = @as(i32, @intCast(y_offset)) + @as(i32, @intCast(m.gap));

    // Full gap at screen edges; half-gap at interior slot boundaries so that
    // adjacent windows together share exactly one full gap.
    const gap_i32:  i32 = @intCast(m.gap);
    const gap_half: i32 = @intCast(m.gap / 2);
    const border2:  i32 = 2 * @as(i32, @intCast(m.border));

    var defer_slot = layouts.DeferredConfigure.init(ctx);

    for (windows, 0..) |win, i| {
        const col: i32 = @intCast(i);

        const slot_left: i32 = col * slot_w - scroll;

        // <= / >= rather than < / > to handle off-by-one from integer-division of odd screen widths.
        const left_inset:  i32 = if (slot_left <= 0)               gap_i32 else gap_half;
        const right_inset: i32 = if (slot_left + slot_w >= sw_i32) gap_i32 else gap_half;

        const x: i32         = slot_left + left_inset;
        const avail: i32     = slot_w - left_inset - right_inset - border2;
        const content_w: u16 = if (avail > constants.MIN_WINDOW_DIM)
            @intCast(avail)
        else
            constants.MIN_WINDOW_DIM;

        const right: i32 = x + avail + border2;

        // Completely off-screen: park the window.
        if (x >= sw_i32 or right <= 0) {
            if (x < I16_MIN or x > I16_MAX) {
                _ = core.xcb.xcb_configure_window(
                    ctx.conn, win,
                    core.xcb.XCB_CONFIG_WINDOW_X,
                    &[_]u32{@bitCast(constants.OFFSCREEN_X_POSITION)},
                );
                ctx.cache.getOrPut(win).value_ptr.rect = tiling.zero_rect;
            } else {
                const rect = utils.Rect{
                    .x = @intCast(x), .y = @intCast(win_y),
                    .width = content_w, .height = content_h,
                };
                if (!defer_slot.capture(ctx, win, rect))
                    layouts.configureWithHints(ctx, win, rect);
            }
            continue;
        }

        const rect = utils.Rect{
            .x = @intCast(x), .y = @intCast(win_y),
            .width = content_w, .height = content_h,
        };
        if (!defer_slot.capture(ctx, win, rect))
            layouts.configureWithHints(ctx, win, rect);
    }
    defer_slot.flush(ctx);
}

/// Height of each window: full screen height minus top + bottom gap and borders.
inline fn calcContentH(screen_h: u16, m: utils.Margins) u16 {
    const overhead = m.gap *| 2 +| m.border *| 2;
    return if (screen_h > overhead) screen_h - overhead else constants.MIN_WINDOW_DIM;
}