//! Grid layout: arrange windows in an optimal grid.

const constants = @import("constants");
const utils     = @import("utils");
const layouts   = @import("layouts");
const tiling    = @import("tiling");
const State     = tiling.State;

inline fn toWinDim(cell: u16, border_margin: u16) u16 {
    return if (cell > border_margin) cell - border_margin else constants.MIN_WINDOW_DIM;
}

// Integer ceiling-sqrt: smallest c such that c*c >= n.
// Avoids the float pipeline entirely; terminates in ≤12 iterations for any
// realistic window count.
inline fn calcGridDims(n: usize) struct { cols: u16, rows: u16 } {
    if (n == 3) return .{ .cols = 3, .rows = 1 };
    var cols: u16 = 1;
    while (@as(usize, cols) * cols < n) cols += 1;
    return .{ .cols = cols, .rows = @intCast((n + cols - 1) / cols) };
}

pub fn tileWithOffset(ctx: *const layouts.LayoutCtx, state: *State, windows: []const u32, screen_w: u16, screen_h: u16, y_offset: u16) void {
    const n = windows.len;
    if (n == 0) return;

    const m    = state.margins();
    const dims = calcGridDims(n);
    const bm   = 2 * m.border;

    const cell_w = (screen_w -| (dims.cols + 1) * m.gap) / dims.cols;
    const cell_h = (screen_h -| (dims.rows + 1) * m.gap) / dims.rows;
    const win_h  = toWinDim(cell_h, bm);

    // In relaxed mode, windows on a partial last row divide the full screen
    // width among themselves rather than inheriting the narrower grid-column width.
    const last_row_count = n % dims.cols;
    const partial_cell_w: u16 = if (last_row_count != 0) blk: {
        const count: u16 = @intCast(last_row_count);
        break :blk (screen_w -| (count + 1) * m.gap) / count;
    } else cell_w;

    for (windows, 0..) |win, idx| {
        const col: u16 = @intCast(idx % dims.cols);
        const row: u16 = @intCast(idx / dims.cols);

        const cw: u16 = switch (state.layout_variations.grid) {
            .rigid   => cell_w,
            .relaxed => if (last_row_count != 0 and row == dims.rows - 1) partial_cell_w else cell_w,
        };

        layouts.configureSafe(ctx, win, utils.Rect{
            .x      = @intCast(m.gap +| col *| (cw + m.gap)),
            .y      = @intCast(y_offset +| m.gap +| row *| (cell_h + m.gap)),
            .width  = toWinDim(cw, bm),
            .height = win_h,
        });
    }
}
