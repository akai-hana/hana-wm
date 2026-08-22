//! Grid tiling layout (pure port of modules/grid.zig).
//! Arranges windows in an evenly divided grid, with rigid or relaxed row sizing.

const utils = @import("utils");
const engine = @import("engine");

const View = engine.View;
const List = engine.List;

pub fn compute(v: View, out: *List) void {
    const n = v.order.len;

    const m = v.margins;
    const grid = calcGridShape(n);
    // Both sides of each window's border, used to shrink usable cell dimensions.
    const bm = utils.doubledBorder(m);

    const screen_w = v.workarea.width;
    const screen_h = v.workarea.height;

    const cell_w = (screen_w -| (grid.cols + 1) *| m.gap) / grid.cols;
    const cell_h = (screen_h -| (grid.rows + 1) *| m.gap) / grid.rows;
    const win_h = engine.shrinkClamped(cell_h, bm, v.min_dim);
    const win_w = engine.shrinkClamped(cell_w, bm, v.min_dim);

    // In relaxed mode a partial last row shares the full screen width
    // rather than a narrower grid-column width, so fewer columns means
    // less wasted horizontal space. Gated on the caller-resolved flag so
    // the division is skipped entirely on the default rigid path.
    const last_row_count = n % grid.cols;
    const partial_win_w: u16 = if (v.grid_relaxed and last_row_count != 0) blk: {
        const count: u16 = @intCast(last_row_count);
        const partial_cell_w = (screen_w -| (count + 1) * m.gap) / count;
        break :blk engine.shrinkClamped(partial_cell_w, bm, v.min_dim);
    } else win_w;

    var col: u16 = 0;
    var row: u16 = 0;
    for (v.order) |win| {
        const is_partial_row = last_row_count != 0 and row == grid.rows - 1;

        const rect = utils.Rect{
            .x = @intCast(m.gap +| col *| (cell_w + m.gap)),
            .y = @intCast(engine.waY(&v) +| m.gap +| row *| (cell_h + m.gap)),
            .width = if (is_partial_row) partial_win_w else win_w,
            .height = win_h,
        };
        engine.emitView(&v, out, win, rect, true);

        col += 1;
        if (col == grid.cols) {
            col = 0;
            row += 1;
        }
    }
}

/// Returns the column/row counts of the smallest square grid holding `n`
/// windows. Special-cases `n == 3` to use a 1x3 layout instead of 2x2 with
/// a dead cell. Uses integer ceiling-sqrt; at most 6 iterations for n <= 64.
inline fn calcGridShape(n: usize) struct { cols: u16, rows: u16 } {
    if (n == 3) return .{ .cols = 3, .rows = 1 };
    var cols: u16 = 1;
    while (@as(usize, cols) * cols < n) cols += 1;
    return .{ .cols = cols, .rows = @intCast((n + cols - 1) / cols) };
}
