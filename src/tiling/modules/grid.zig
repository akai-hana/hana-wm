//! Grid tiling layout.
//! Splits the work area into equal cells, rigid or relaxed per the variant.

const tiling = @import("tiling");
const model = @import("model");

/// The ONE variant table for this layout.
const variants = [_]tiling.Variant{
    .{ .name = "rigid", .indicator = "[#]" },
    .{ .name = "relaxed", .indicator = "[~]" },
};

/// Ordinal of the "relaxed" variant, read from the table above.
const variant_relaxed: u8 = tiling.variantIndex(&variants, "relaxed");

/// Even share of `total` across `count` cells, with a full `gap` between every
/// pair plus one at each outer edge. The cell math behind grid's rigid and
/// widened-last-row shapes.
inline fn paneCell(total: u16, count: u16, gap: u16) u16 {
    return (total -| (count + 1) *| gap) / count;
}

/// Compute grid layout. Full gap between cells and at screen edges; u16
/// integer-divided cells, last partial row wider in relaxed mode.
pub fn compute(v: *const tiling.View, out: *tiling.List) void {
    const n = v.order.len;

    const m = v.env.margins;
    const grid = calcGridShape(n);
    // Both sides of each window's border, used to shrink usable cell dimensions.
    const bm = model.doubledBorder(m);

    const screen_w = v.workarea.width;
    const screen_h = v.workarea.height;

    const cell_w = paneCell(screen_w, grid.cols, m.gap);
    const cell_h = paneCell(screen_h, grid.rows, m.gap);
    // Window content area within a cell, never exceeding the cell: the
    // shrinkClamped min_dim floor used to flare a window past its own cell in
    // a congested grid, overlapping the neighbours.
    const win_h = @max(@min(tiling.shrinkClamped(cell_h, bm, v.env.min_dim), cell_h -| bm), 1);
    const win_w = @max(@min(tiling.shrinkClamped(cell_w, bm, v.env.min_dim), cell_w -| bm), 1);
    const wa_y = tiling.waY(v);

    // In relaxed mode a partial last row shares the full screen width.
    const last_row_count = n % grid.cols;
    const partial_cell_w: u16 = if (v.params.variant_idx == variant_relaxed and last_row_count != 0)
        paneCell(screen_w, @intCast(last_row_count), m.gap)
    else
        cell_w;
    const partial_win_w: u16 = @max(@min(tiling.shrinkClamped(partial_cell_w, bm, v.env.min_dim), partial_cell_w -| bm), 1);

    for (v.order, 0..) |win, i| {
        const col: u16 = @intCast(i % grid.cols);
        const row: u16 = @intCast(i / grid.cols);
        const is_partial_row = last_row_count != 0 and row == grid.rows - 1;
        // Partial-row columns are spaced by the wider partial cell so the
        // relaxed cells don't overlap each other.
        const spacing_w: u16 = if (is_partial_row) partial_cell_w else cell_w;

        tiling.emitRect(
            v,
            out,
            win,
            @as(i32, @intCast(m.gap +| tiling.cellStride(spacing_w, m.gap, col))) + v.workarea.x,
            @intCast(wa_y +| m.gap +| tiling.cellStride(cell_h, m.gap, row)),
            if (is_partial_row) partial_win_w else win_w,
            win_h,
        );
    }
}

/// Column/row counts of the smallest square grid holding `n` windows; uses
/// a 3-column, 1-row layout for `n == 3`. Integer ceiling-sqrt loop.
inline fn calcGridShape(n: usize) struct { cols: u16, rows: u16 } {
    if (n == 3) return .{ .cols = 3, .rows = 1 };
    var cols: u16 = 1;
    while (@as(usize, cols) * cols < n) cols += 1;
    return .{ .cols = cols, .rows = @intCast((n + cols - 1) / cols) };
}

/// This layout's registry contribution: metadata plus the dispatch hook.
pub const module = tiling.layoutModule("grid", "[+]", compute, &variants, .{});
