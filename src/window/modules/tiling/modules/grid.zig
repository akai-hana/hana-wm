//! Grid tiling layout.
//!
//! Arranges windows in the smallest square grid that fits all windows.
//! Two variants are supported via `State.layout_variants.grid`:
//!   - `.rigid`   — all windows share equal cell widths.
//!   - `.relaxed` — windows on a partial last row divide the full screen width,
//!                  so the last row doesn't have awkward narrow cells.

const constants = @import("constants");
const utils     = @import("utils");
const layouts   = @import("layouts");
const tiling    = @import("tiling");
const State     = tiling.State;

/// Tile `windows` into a grid using the given screen area.
pub fn tileWithOffset(
    ctx:      *const layouts.LayoutCtx,
    state:    *State,
    windows:  []const u32,
    screen_w: u16,
    screen_h: u16,
    y_offset: u16,
) void {
    const n = windows.len;
    if (n == 0) return;

    const m    = state.margins();
    const grid = calcGridShape(n);
    const bm   = 2 * m.border;

    const cell_w = (screen_w -| (grid.cols + 1) * m.gap) / grid.cols;
    const cell_h = (screen_h -| (grid.rows + 1) * m.gap) / grid.rows;
    const win_h  = cellToWindowSize(cell_h, bm);

    // In relaxed mode, windows on a partial last row divide the full screen
    // width among themselves rather than using the narrower grid-column width.
    const last_row_count = n % grid.cols;
    const partial_cell_w: u16 = if (last_row_count != 0) blk: {
        const count: u16 = @intCast(last_row_count);
        break :blk (screen_w -| (count + 1) * m.gap) / count;
    } else cell_w;

    for (windows, 0..) |win, idx| {
        const col: u16 = @intCast(idx % grid.cols);
        const row: u16 = @intCast(idx / grid.cols);

        const is_partial_row = last_row_count != 0 and row == grid.rows - 1;
        const effective_cell_w: u16 = switch (state.layout_variants.grid) {
            .rigid   => cell_w,
            .relaxed => if (is_partial_row) partial_cell_w else cell_w,
        };

        layouts.configureWithHints(ctx, win, utils.Rect{
            .x      = @intCast(m.gap +| col *| (effective_cell_w + m.gap)),
            .y      = @intCast(y_offset +| m.gap +| row *| (cell_h + m.gap)),
            .width  = cellToWindowSize(effective_cell_w, bm),
            .height = win_h,
        });
    }
}

// ============================================================================
// Private helpers
// ============================================================================

/// Returns the window content dimension for a cell of `cell_size`, subtracting
/// the combined border margin. Falls back to MIN_WINDOW_DIM on underflow.
inline fn cellToWindowSize(cell_size: u16, border_margin: u16) u16 {
    return if (cell_size > border_margin) cell_size - border_margin else constants.MIN_WINDOW_DIM;
}

/// Returns the column and row count for the smallest square grid that holds `n`
/// windows. Special-cases `n == 3` to produce a single row of three rather than
/// a 2×2 grid with a dead cell.
///
/// Uses integer ceiling-sqrt to avoid the float pipeline entirely; terminates
/// in at most 12 iterations for any realistic window count.
inline fn calcGridShape(n: usize) struct { cols: u16, rows: u16 } {
    if (n == 3) return .{ .cols = 3, .rows = 1 };
    var cols: u16 = 1;
    while (@as(usize, cols) * cols < n) cols += 1;
    return .{ .cols = cols, .rows = @intCast((n + cols - 1) / cols) };
}
