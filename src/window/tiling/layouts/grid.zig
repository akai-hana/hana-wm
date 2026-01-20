// grid.zig
//! Grid layout - windows arranged in a square grid.
//!
//! Windows are arranged in rows and columns to form an approximately
//! square grid. Number of columns is calculated as ceil(sqrt(N)).
//!
//! ┌─────┬─────┬─────┐
//! │  1  │  2  │  3  │
//! ├─────┼─────┼─────┤
//! │  4  │  5  │  6  │
//! └─────┴─────┴─────┘

const std = @import("std");
const defs = @import("defs");
const log = @import("logging");
const WM = defs.WM;
const types = @import("types");
const TilingState = types.TilingState;

/// Minimum window dimensions to keep windows visible
const MIN_WINDOW_DIM: u16 = 50;

pub fn tile(wm: *WM, state: *TilingState, windows: []const u32, screen_w: u16, screen_h: u16) void {
    const n = windows.len;
    if (n == 0) return;

    const gap = state.gaps;
    const bw = state.border_width;

    // Calculate grid dimensions (approximately square)
    const cols_f = @ceil(@sqrt(@as(f32, @floatFromInt(n))));
    const cols = @as(u16, @intFromFloat(cols_f));
    const rows = @as(u16, @intCast((n + cols - 1) / cols));

    // Ensure we don't have zero columns/rows
    std.debug.assert(cols > 0);
    std.debug.assert(rows > 0);

    log.debugLayoutTiling("grid", n, cols, rows);

    // Calculate cell size accounting for gaps between cells
    // Layout: gap + cell + gap + cell + ... + gap
    // Total width: (cols + 1) * gap + cols * cell_w = screen_w
    const cell_w = (screen_w -| (cols + 1) * gap) / cols;
    const cell_h = (screen_h -| (rows + 1) * gap) / rows;

    // Window size is cell size minus borders, with minimum enforced
    const win_w = @max(MIN_WINDOW_DIM, if (cell_w > 2 * bw) cell_w - 2 * bw else MIN_WINDOW_DIM);
    const win_h = @max(MIN_WINDOW_DIM, if (cell_h > 2 * bw) cell_h - 2 * bw else MIN_WINDOW_DIM);

    for (windows, 0..) |win, idx| {
        const col = @as(u16, @intCast(idx % cols));
        const row = @as(u16, @intCast(idx / cols));

        // Position: gap + col * (cell_w + gap) for even spacing
        const x = gap + col * (cell_w + gap);
        const y = gap + row * (cell_h + gap);

        types.configureWindow(wm, win, x, y, win_w, win_h);
    }
}
