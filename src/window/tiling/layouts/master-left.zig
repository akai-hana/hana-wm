//! Master-left tiling layout implementation.
//!
//! ┌──────────┬──────┐
//! │          │  S1  │
//! │          ├──────┤
//! │  Master  │  S2  │
//! │          ├──────┤
//! │          │  S3  │
//! └──────────┴──────┘
//!
//! - Left side: One or more "master" windows (configurable count)
//! - Right side: Remaining windows stacked vertically
//! - Master width is configurable as percentage of screen

const std = @import("std");
const defs = @import("defs");
const log = @import("logging");
const WM = defs.WM;
const types = @import("types");
const TilingState = types.TilingState;

/// Minimum window dimensions to keep windows visible
const MIN_WINDOW_DIM: u16 = 50;

/// Calculate window dimensions for a vertical column of windows
fn calcColumnHeight(screen_h: u16, count: u16, gap: u16, bw: u16) struct { win_h: u16 } {
    const gap32: u32 = gap;
    const bw32: u32 = bw;
    const count32: u32 = count;

    // Total overhead = outer gaps + all borders + inner gaps
    const outer_gaps = 2 * gap32;
    const borders = count32 * 2 * bw32;
    const inner_gaps = if (count > 1) (count32 - 1) * gap32 else 0;
    const total_overhead = outer_gaps + borders + inner_gaps;

    // Distribute remaining space evenly
    const available = if (screen_h > total_overhead)
        @as(u32, screen_h) - total_overhead
    else
        count32 * MIN_WINDOW_DIM; // Use minimum size as fallback

    return .{ .win_h = @max(MIN_WINDOW_DIM, @as(u16, @intCast(available / count32))) };
}

pub fn tile(wm: *WM, state: *TilingState, windows: []const u32, screen_w: u16, screen_h: u16) void {
    const n = windows.len;
    if (n == 0) return;

    const gap = state.gaps;
    const bw = state.border_width;
    const m_count: u16 = @intCast(@min(state.master_count, n));
    const s_count: u16 = @intCast(if (n > m_count) n - m_count else 0);

    log.debugLayoutMasterLeft(n, state.master_count, m_count, s_count, screen_w);

    // Calculate column widths
    const master_width: u16 = if (s_count == 0)
        screen_w // No stack, master takes full width
    else
        @intFromFloat(@as(f32, @floatFromInt(screen_w)) * state.master_width_factor);

    // Pre-calculate window heights for each column
    const master_dims = calcColumnHeight(screen_h, m_count, gap, bw);
    const stack_dims = if (s_count > 0)
        calcColumnHeight(screen_h, s_count, gap, bw)
    else
        @TypeOf(master_dims){ .win_h = 0 };

    for (windows, 0..) |win, idx| {
        var x: u16 = undefined;
        var y: u16 = undefined;
        var w: u16 = undefined;
        var h: u16 = undefined;

        if (idx < m_count) {
            // Master Area
            const row: u16 = @intCast(idx);
            x = gap; // Gap from left edge
            y = @intCast(gap + row * (master_dims.win_h + 2 * bw + gap));
            // Width: master area minus gaps on both sides and borders
            w = if (master_width > 2 * gap + 2 * bw)
                master_width - 2 * gap - 2 * bw
            else
                MIN_WINDOW_DIM;
            // Ensure minimum size
            w = @max(MIN_WINDOW_DIM, w);
            h = master_dims.win_h;
        } else {
            // Stack Area
            const row: u16 = @intCast(idx - m_count);
            const stack_width = screen_w - master_width;
            x = master_width; // Starts where master ends (no gap between)
            y = @intCast(gap + row * (stack_dims.win_h + 2 * bw + gap));
            // Width: stack area minus gap on right and borders
            w = if (stack_width > gap + 2 * bw)
                stack_width - gap - 2 * bw
            else
                MIN_WINDOW_DIM;
            // Ensure minimum size
            w = @max(MIN_WINDOW_DIM, w);
            h = stack_dims.win_h;
        }

        types.configureWindow(wm, win, x, y, w, h);

        log.debugLayoutWindowGeometry(idx, x, y, w, h, idx < m_count);
    }
}
