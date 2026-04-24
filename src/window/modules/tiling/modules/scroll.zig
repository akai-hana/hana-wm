//! Scrolling tiling layout

const std = @import("std");

const utils     = @import("utils");
const constants = @import("constants");

const tiling  = @import("tiling");
const layouts = @import("layouts");

// Max/min signed positions representable in a `utils.Rect.x`.
// Windows whose strip position falls outside this range are parked at constants.OFFSCREEN_X_POSITION,
// rather than sent with an overflowing cast.
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

    // Every window slot is exactly half the screen width.
    const slot_w: i32 = @intCast(screen_w / 2);

    // Clamp the stored scroll offset so:
    //   • we never scroll left past window 0  (offset >= 0)
    //   • we never scroll right past the last window
    //     (the last window's right edge stays <= screen_w)
    //     → max_offset = (n-2)*slot_w  [0 when n <= 2]
    const n_i32: i32   = @intCast(n);
    const sw_i32: i32  = @intCast(screen_w);
    const max_off: i32 = @max(0, (n_i32 - 1) * slot_w + slot_w - sw_i32);
    state.scrolling_offset = std.math.clamp(state.scrolling_offset, 0, max_off);
    const scroll: i32 = state.scrolling_offset;

    // Geometry constants shared by all windows.
    const content_w: u16 = calcContentW(slot_w, m);
    const content_h: u16 = calcContentH(screen_h, m);
    const win_y: i32     = @as(i32, @intCast(y_offset)) + @as(i32, @intCast(m.gap));

    // gap_half: symmetric gap — half a gap inset on each side of a slot boundary.
    const gap_half: i32 = @intCast(m.gap / 2);

    for (windows, 0..) |win, i| {
        const col: i32 = @intCast(i);

        // Signed strip X of the window's content area.
        const x: i32 = col * slot_w + gap_half - scroll;

        // Right edge including borders (what the X server clips against).
        const border2: i32 = 2 * @as(i32, @intCast(m.border));
        const right: i32   = x + @as(i32, @intCast(content_w)) + border2;

        // Completely off-screen to the right or left: park the window.
        if (x >= sw_i32 or right <= 0) {
            // If the natural strip coordinate overflows i16, park at the
            // offscreen sentinel so the X server does not receive a garbage
            // position.  Otherwise, configure at the correct (but invisible)
            // strip position so the cache stays coherent: when the user scrolls
            // back to this window it will be a cache-hit and no extra configure
            // is needed.
            if (x < I16_MIN or x > I16_MAX) {
                _ = @import("core").xcb.xcb_configure_window(
                    ctx.conn, win,
                    @import("core").xcb.XCB_CONFIG_WINDOW_X,
                    &[_]u32{@bitCast(constants.OFFSCREEN_X_POSITION)},
                );
                // Invalidate the cache entry so the next on-screen retile
                // always reconfigures the window correctly.
                ctx.cache.getOrPut(win).value_ptr.rect = tiling.zero_rect;
            } else {
                layouts.configureWithHints(ctx, win, .{
                    .x      = @intCast(x),
                    .y      = @intCast(win_y),
                    .width  = content_w,
                    .height = content_h,
                });
            }
            continue;
        }

        // Window is (at least partially) on screen: normal configure path.
        layouts.configureWithHints(ctx, win, .{
            .x      = @intCast(x),
            .y      = @intCast(win_y),
            .width  = content_w,
            .height = content_h,
        });
    }
}

// Private helpers

/// Height of each window: full screen height minus top + bottom gap and borders.
inline fn calcContentH(screen_h: u16, m: utils.Margins) u16 {
    const overhead = m.gap *| 2 +| m.border *| 2;
    return if (screen_h > overhead) screen_h - overhead else constants.MIN_WINDOW_DIM;
}

/// Width of a window inside a half-screen slot.
/// gap/2 is inset on each side (symmetric), then 2*border is subtracted.
inline fn calcContentW(slot_w: i32, m: utils.Margins) u16 {
    const gap_i32:   i32 = @intCast(m.gap);
    const border2_i32: i32 = 2 * @as(i32, @intCast(m.border));
    const avail: i32 = slot_w - gap_i32 - border2_i32;
    return if (avail > constants.MIN_WINDOW_DIM) @intCast(avail) else constants.MIN_WINDOW_DIM;
}
