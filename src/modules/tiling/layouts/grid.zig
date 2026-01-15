// Grid layout - windows arranged in a grid pattern
const std = @import("std");
const defs = @import("defs");
const builtin = @import("builtin");
const WM = defs.WM;
const tiling_types = @import("tiling_types");
const TilingState = tiling_types.TilingState;

pub fn tile(wm: *WM, state: *TilingState, windows: []const u32, screen_w: u16, screen_h: u16) void {
    const n = windows.len;
    if (n == 0) return;

    const gap = state.gaps;
    const bw = state.border_width;

    // Calculate grid dimensions
    const cols_f = @ceil(@sqrt(@as(f32, @floatFromInt(n))));
    const cols = @as(u16, @intFromFloat(cols_f));
    const rows = @as(u16, @intCast((n + cols - 1) / cols));

    if (builtin.mode == .Debug) {
        std.debug.print("[grid] Tiling {} windows in {}x{} grid\n", .{n, cols, rows});
    }

    const cell_w = screen_w / cols;
    const cell_h = screen_h / rows;

    for (windows, 0..) |win, idx| {
        const col = @as(u16, @intCast(idx % cols));
        const row = @as(u16, @intCast(idx / cols));

        const x = gap + (col * cell_w);
        const y = gap + (row * cell_h);
        const w = tiling_types.calcWindowDimension(cell_w, gap, bw);
        const h = tiling_types.calcWindowDimension(cell_h, gap, bw);

        tiling_types.configureWindow(wm, win, x, y, w, h);
    }
}
