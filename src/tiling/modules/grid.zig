//! Grid tiling layout.
//! Splits the work area into equal cells, rigid or relaxed per the variant.

const utils = @import("utils");
const tiling = @import("tiling");

/// Compute grid layout. Full gap between cells and at screen edges; u16
/// integer-divided cells, last partial row wider in relaxed mode.
pub fn compute(v: tiling.View, out: *tiling.List) void {
    const n = v.order.len;

    const m = v.env.margins;
    const grid = calcGridShape(n);
    // Both sides of each window's border, used to shrink usable cell dimensions.
    const bm = utils.doubledBorder(m);

    const screen_w = v.workarea.width;
    const screen_h = v.workarea.height;

    const cell_w = (screen_w -| (grid.cols + 1) *| m.gap) / grid.cols;
    const cell_h = (screen_h -| (grid.rows + 1) *| m.gap) / grid.rows;
    const win_h = tiling.shrinkClamped(cell_h, bm, v.env.min_dim);
    const win_w = tiling.shrinkClamped(cell_w, bm, v.env.min_dim);
    const wa_y = tiling.waY(&v);

    // In relaxed mode a partial last row shares the full screen width.
    // Core variant index -> relaxed (variant 1 of "rigid"/"relaxed").
    const relax_variant: u8 = 1;
    const last_row_count = n % grid.cols;
    const partial_cell_w: u16 = if (v.env.variant_idx == relax_variant and last_row_count != 0)
        widenedLastRowCellWidth(screen_w, last_row_count, m.gap)
    else
        cell_w;
    const partial_win_w: u16 = tiling.shrinkClamped(partial_cell_w, bm, v.env.min_dim);

    var col: u16 = 0;
    var row: u16 = 0;
    for (v.order) |win| {
        const is_partial_row = last_row_count != 0 and row == grid.rows - 1;
        // Partial-row columns are spaced by the wider partial cell so the
        // relaxed cells don't overlap each other.
        const cell_w_here: u16 = if (is_partial_row) partial_cell_w else cell_w;

        const rect = utils.Rect{
            .x = @intCast(m.gap +| col *| (cell_w_here +| m.gap)),
            .y = @intCast(wa_y +| m.gap +| row *| (cell_h + m.gap)),
            .width = if (is_partial_row) partial_win_w else win_w,
            .height = win_h,
        };
        tiling.emitView(&v, out, win, rect, true);

        col += 1;
        if (col == grid.cols) {
            col = 0;
            row += 1;
        }
    }
}

/// Width of a widened (relaxed) last row's cell, sharing `screen_w` across
/// `count` windows with full gaps on each side.
inline fn widenedLastRowCellWidth(screen_w: u16, count: usize, gap: u16) u16 {
    const c: u16 = @intCast(count);
    return (screen_w -| (c + 1) *| gap) / c;
}

/// Column/row counts of the smallest square grid holding `n` windows; uses
/// a 1x3 layout for `n == 3`. Integer ceiling-sqrt loop.
inline fn calcGridShape(n: usize) struct { cols: u16, rows: u16 } {
    if (n == 3) return .{ .cols = 3, .rows = 1 };
    var cols: u16 = 1;
    while (@as(usize, cols) * cols < n) cols += 1;
    return .{ .cols = cols, .rows = @intCast((n + cols - 1) / cols) };
}

/// This layout's registry contribution: metadata plus the dispatch hook.
pub const module: @import("plugin").Layout = .{
    .name = "grid",
    .compute = tiling.computeHook(compute),
    .variant_count = 2,
    .variant_parse = tiling.variantParse(&.{ "rigid", "relaxed" }),
    .icon = "[+]",
    .indicators = &.{ "[#]", "[~]" },
};
