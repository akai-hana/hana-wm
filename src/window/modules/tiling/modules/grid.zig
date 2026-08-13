//! Grid tiling layout
//! Arranges windows in an evenly divided grid, with rigid or relaxed row sizing.

const utils = @import("utils");
const layouts = @import("layouts");
const tiling = @import("tiling");
const State = tiling.State;

/// Tile `windows` into a grid using the given screen area.
pub fn tileWithOffset(
    ctx: *const layouts.LayoutCtx,
    state: *State,
    windows: []const u32,
    screen_w: u16,
    screen_h: u16,
    y_offset: u16,
) void {
    // Windows list is guaranteed non-empty by invokeLayout (see tiling.zig).
    const n = windows.len;

    const m = state.margins();
    const grid = calcGridShape(n);
    const bm = utils.doubledBorder(m);

    const cell_w = (screen_w -| (grid.cols + 1) *| m.gap) / grid.cols;
    const cell_h = (screen_h -| (grid.rows + 1) *| m.gap) / grid.rows;
    const win_h = layouts.shrinkClamped(cell_h, bm, state.config.min_window_dim);

    // In relaxed mode, a partial last row's windows share the full screen
    // width rather than the narrower grid-column width. Gated on .relaxed so
    // the division is skipped entirely on the default .rigid path.
    const last_row_count = n % grid.cols;
    const partial_cell_w: u16 = if (state.config.layout_variants.grid == .relaxed and last_row_count != 0) blk: {
        const count: u16 = @intCast(last_row_count);
        break :blk (screen_w -| (count + 1) * m.gap) / count;
    } else cell_w;

    // emitOrDefer honors ctx.defer_win — see LayoutCtx.defer_win.
    for (windows, 0..) |win, idx| {
        const col: u16 = @intCast(idx % grid.cols);
        const row: u16 = @intCast(idx / grid.cols);

        const is_partial_row = last_row_count != 0 and row == grid.rows - 1;
        const effective_cell_w: u16 = if (is_partial_row) partial_cell_w else cell_w;

        const rect = utils.Rect{
            .x = @intCast(m.gap +| col *| (effective_cell_w + m.gap)),
            .y = @intCast(y_offset +| m.gap +| row *| (cell_h + m.gap)),
            .width = layouts.shrinkClamped(effective_cell_w, bm, state.config.min_window_dim),
            .height = win_h,
        };
        layouts.emitOrDefer(ctx, win, rect);
    }
}

/// Returns the column/row counts of the smallest square grid holding `n`
/// windows. Special-cases `n == 3` (one row of three, not a 2×2 with a dead
/// cell). Uses integer ceiling-sqrt to avoid floats; at most 12 iterations.
inline fn calcGridShape(n: usize) struct { cols: u16, rows: u16 } {
    if (n == 3) return .{ .cols = 3, .rows = 1 };
    var cols: u16 = 1;
    while (@as(usize, cols) * cols < n) cols += 1;
    return .{ .cols = cols, .rows = @intCast((n + cols - 1) / cols) };
}
