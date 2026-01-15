// Master-left tiling layout (dwm-style)
// Master windows on the left, stack windows on the right
const std = @import("std");
const defs = @import("defs");
const builtin = @import("builtin");
const WM = defs.WM;
const tiling_types = @import("tiling_types");
const TilingState = tiling_types.TilingState;

/// Calculate row geometry for a window in a column
fn calculateRowGeometry(
    row: u16, 
    total_rows: u16, 
    screen_h: u16, 
    gap: u16, 
    bw: u16
) struct { y: u16, h: u16 } {
    const row_height = screen_h / total_rows;
    const y = gap + (row * row_height);
    const is_last = (row == total_rows - 1);
    
    const h = if (is_last)
        tiling_types.calcAvailableSpace(screen_h - y, gap, bw)
    else
        tiling_types.calcWindowDimension(row_height, gap, bw);
    
    return .{ .y = y, .h = h };
}

pub fn tile(wm: *WM, state: *TilingState, windows: []const u32, screen_w: u16, screen_h: u16) void {
    const n = windows.len;
    if (n == 0) return;

    const gap = state.gaps;
    const bw = state.border_width;

    // Determine how many windows in master vs stack
    const m_count = @min(state.master_count, n);
    const s_count = if (n > m_count) n - m_count else 0;

    if (builtin.mode == .Debug) {
        std.debug.print("[master-left] n={}, master_count={}, m_count={}, s_count={}, screen_w={}\n",
            .{n, state.master_count, m_count, s_count, screen_w});
    }

    // Calculate master column width
    const master_width: u16 = if (s_count == 0)
        screen_w
    else
        @intFromFloat(@as(f32, @floatFromInt(screen_w)) * state.master_width_factor);

    // Calculate stack column width
    const stack_width: u16 = if (s_count > 0) screen_w - master_width else 0;

    for (windows, 0..) |win, idx| {
        var x: u16 = 0;
        var y: u16 = 0;
        var w: u16 = 0;
        var h: u16 = 0;

        if (idx < m_count) {
            // MASTER COLUMN (left side)
            const row = @as(u16, @intCast(idx));
            const geom = calculateRowGeometry(row, @intCast(m_count), screen_h, gap, bw);

            x = gap;
            y = geom.y;
            w = tiling_types.calcWindowDimension(master_width, gap, bw);
            h = geom.h;
        } else {
            // STACK COLUMN (right side)
            const stack_idx = idx - m_count;
            const row = @as(u16, @intCast(stack_idx));
            const geom = calculateRowGeometry(row, @intCast(s_count), screen_h, gap, bw);

            x = master_width + gap;
            y = geom.y;
            w = tiling_types.calcWindowDimension(stack_width, gap, bw);
            h = geom.h;
        }

        tiling_types.configureWindow(wm, win, x, y, w, h);

        if (builtin.mode == .Debug) {
            std.debug.print("[master-left] Window {}: x={}, y={}, w={}, h={} (master={})\n",
                .{idx, x, y, w, h, idx < m_count});
        }
    }
}
