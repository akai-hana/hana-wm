//! Grid layout: windows arranged in a square grid.

const std = @import("std");
const defs = @import("defs");
const utils = @import("utils");
const WM = defs.WM;

// Import the State type from tiling module
const tiling = @import("tiling");
const State = tiling.State;

pub fn tile(wm: *WM, state: *State, windows: []const u32, screen_w: u16, screen_h: u16) void {
    const n = windows.len;
    if (n == 0) return;

    const m = state.margins();
    const dims = utils.calcGridDims(n);

    const cell_w = (screen_w -| (dims.cols + 1) * m.gap) / dims.cols;
    const cell_h = (screen_h -| (dims.rows + 1) * m.gap) / dims.rows;

    // Pre-calculate window dimensions
    const border_margin = 2 * m.border;
    const win_w = if (cell_w > border_margin) cell_w - border_margin else utils.MIN_WINDOW_DIM;
    const win_h = if (cell_h > border_margin) cell_h - border_margin else utils.MIN_WINDOW_DIM;

    // Pre-calculate cell spacing
    const cell_spacing_w = cell_w + m.gap;
    const cell_spacing_h = cell_h + m.gap;

    for (windows, 0..) |win, idx| {
        const col: u16 = @intCast(idx % dims.cols);
        const row: u16 = @intCast(idx / dims.cols);

        utils.configureWindow(wm.conn, win, .{
            .x = @intCast(m.gap + col * cell_spacing_w),
            .y = @intCast(m.gap + row * cell_spacing_h),
            .width = win_w,
            .height = win_h,
        });
    }
}
