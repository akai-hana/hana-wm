//! Grid layout: windows arranged in a square grid.

const std = @import("std");
const defs = @import("defs");
const utils = @import("utils");
const atomic = @import("atomic");
const bar = @import("bar");

const tiling = @import("tiling");
const State = tiling.State;

pub fn tile(tx: *atomic.Transaction, state: *State, windows: []const u32, screen_w: u16, screen_h: u16) void {
    const n = windows.len;
    if (n == 0) return;

    const bar_height = bar.getHeight();
    const usable_h = screen_h - bar_height;

    const m = state.margins();
    const dims = utils.calcGridDims(n);

    const cell_w = (screen_w -| (dims.cols + 1) * m.gap) / dims.cols;
    const cell_h = (usable_h -| (dims.rows + 1) * m.gap) / dims.rows;

    const border_margin = 2 * m.border;
    const win_w = if (cell_w > border_margin) cell_w - border_margin else utils.MIN_WINDOW_DIM;
    const win_h = if (cell_h > border_margin) cell_h - border_margin else utils.MIN_WINDOW_DIM;

    const cell_spacing_w = cell_w + m.gap;
    const cell_spacing_h = cell_h + m.gap;

    for (windows, 0..) |win, idx| {
        const col: u16 = @intCast(idx % dims.cols);
        const row: u16 = @intCast(idx / dims.cols);

        const rect = utils.Rect{
            .x = @intCast(m.gap + col * cell_spacing_w),
            .y = @intCast(bar_height + m.gap + row * cell_spacing_h),
            .width = win_w,
            .height = win_h,
        };
        tx.configureWindow(win, rect) catch |err| {
            std.log.err("[grid] Failed to configure window {}: {}", .{ win, err });
            continue;
        };
    }
}
