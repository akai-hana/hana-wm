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
    const win_w = if (cell_w > 2 * m.border) cell_w - 2 * m.border else utils.MIN_WINDOW_DIM;
    const win_h = if (cell_h > 2 * m.border) cell_h - 2 * m.border else utils.MIN_WINDOW_DIM;

    for (windows, 0..) |win, idx| {
        const col: u16 = @intCast(idx % dims.cols);
        const row: u16 = @intCast(idx / dims.cols);

        utils.configureWindow(wm.conn, win, .{
            .x = @intCast(m.gap + col * (cell_w + m.gap)),
            .y = @intCast(m.gap + row * (cell_h + m.gap)),
            .width = win_w,
            .height = win_h,
        });
    }
}
