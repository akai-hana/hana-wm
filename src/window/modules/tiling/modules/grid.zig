//! Grid tiling layout
//! Arranges windows in an evenly divided grid, with rigid or relaxed row sizing.

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
    const grid = calcGridShape(n, screen_w, screen_h);
    const bm   = 2 *| m.border;

    const cell_w = (screen_w -| (grid.cols + 1) *| m.gap) / grid.cols;
    const cell_h = (screen_h -| (grid.rows + 1) *| m.gap) / grid.rows;
    const win_h  = cellToWindowSize(cell_h, bm);

    // In relaxed mode, windows on a partial last row divide the full screen
    // width among themselves rather than using the narrower grid-column width.
    // The computation is gated on .relaxed so the division is skipped entirely
    // on the default .rigid path where partial_cell_w is never used.
    const last_row_count = n % grid.cols;
    const partial_cell_w: u16 = if (state.layout_variants.grid == .relaxed and last_row_count != 0) blk: {
        const count: u16 = @intCast(last_row_count);
        break :blk (screen_w -| (count + 1) * m.gap) / count;
    } else cell_w;

    var defer_slot = layouts.DeferredConfigure.init();

    for (windows, 0..) |win, idx| {
        const col: u16 = @intCast(idx % grid.cols);
        const row: u16 = @intCast(idx / grid.cols);

        const is_partial_row = last_row_count != 0 and row == grid.rows - 1;
        const effective_cell_w: u16 = switch (state.layout_variants.grid) {
            .rigid   => cell_w,
            .relaxed => if (is_partial_row) partial_cell_w else cell_w,
        };

        const rect = utils.Rect{
            .x      = @intCast(m.gap +| col *| (effective_cell_w + m.gap)),
            .y      = @intCast(y_offset +| m.gap +| row *| (cell_h + m.gap)),
            .width  = cellToWindowSize(effective_cell_w, bm),
            .height = win_h,
        };
        if (!defer_slot.capture(ctx, win, rect))
            layouts.configureWithHints(ctx, win, rect);
    }
    defer_slot.flush(ctx);
}

/// Returns the window content dimension for a cell of `cell_size`, subtracting
/// the combined border margin. Falls back to MIN_WINDOW_DIM on underflow.
inline fn cellToWindowSize(cell_size: u16, border_margin: u16) u16 {
    return if (cell_size > border_margin) cell_size - border_margin else constants.MIN_WINDOW_DIM;
}

/// Returns column and row count for a grid that holds `n` windows, weighted
/// by the screen aspect ratio so landscape monitors get more columns than rows.
///
/// Algorithm: cols ≈ sqrt(n × aspect), rounded to the nearest integer.  A
/// tightening pass then reduces cols until doing so would increase the row
/// count (i.e. every column is necessary).  This eliminates most dead cells
/// without requiring special-case logic for individual counts.
inline fn calcGridShape(n: usize, screen_w: u16, screen_h: u16) struct { cols: u16, rows: u16 } {
    const aspect: f32 = @as(f32, @floatFromInt(screen_w)) / @as(f32, @floatFromInt(screen_h));
    const cols_f = @sqrt(@as(f32, @floatFromInt(n)) * aspect);
    var cols: u16 = @max(1, @as(u16, @intFromFloat(@round(cols_f))));
    const rows: u16 = @intCast((n + cols - 1) / cols);
    // Tighten: drop a column if the row count is unchanged (dead cell removal).
    while (cols > 1 and (cols - 1) * rows >= n) cols -= 1;
    return .{ .cols = cols, .rows = rows };
}
