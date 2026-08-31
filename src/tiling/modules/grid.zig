//! Grid tiling layout.
//! Splits the work area into equal cells, rigid or relaxed per the variant.

const std = @import("std");
const utils = @import("utils");
const tiling = @import("tiling");

/// Compute grid layout. Origin top-left, y-down. Gaps: full gap between cells
/// and at screen edges (`gap * (cols+1)` / `gap * (rows+1)` subtracted from
/// screen dims). Cell dimensions are u16, integer-divided; last partial row
/// may be wider in relaxed mode. All dims clamped to min_dim.
pub fn compute(v: tiling.View, out: *tiling.List) void {
    const n = v.order.len;
    // Empty workspace: calcGridShape(0) yields rows == 0, which would divide
    // by zero below. Emit nothing instead.
    if (n == 0) return;

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

    // In relaxed mode a partial last row shares the full screen width
    // rather than a narrower grid-column width, so fewer columns means
    // less wasted horizontal space. Gated on the caller-resolved flag so
    // the division is skipped entirely on the default rigid path.
    // Module-owned translation of the generic core variant index: the relaxed
    // mode is active when the index equals relax_variant, which MUST equal
    // this module's plugin.Layout.relax_mode / variant_parse target (both 1 =
    // "relaxed"). Mirrors the pipeline's former caller-side relaxed flag.
    const relax_variant: u8 = 1;
    const last_row_count = n % grid.cols;
    const partial_win_w: u16 = if (v.env.variant_idx == relax_variant and last_row_count != 0) blk: {
        const count: u16 = @intCast(last_row_count);
        const partial_cell_w = (screen_w -| (count + 1) *| m.gap) / count;
        break :blk tiling.shrinkClamped(partial_cell_w, bm, v.env.min_dim);
    } else win_w;

    var col: u16 = 0;
    var row: u16 = 0;
    for (v.order) |win| {
        const is_partial_row = last_row_count != 0 and row == grid.rows - 1;

        const rect = utils.Rect{
            .x = @intCast(m.gap +| col *| (cell_w + m.gap)),
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

/// Returns the column/row counts of the smallest square grid holding `n`
/// windows. Special-cases `n == 3` to use a 1x3 layout instead of 2x2 with
/// a dead cell. Uses an integer ceiling-sqrt loop; at most 7 iterations
/// for n <= 64.
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
    .has_variants = true,
    .variant_parse = tiling.variantParse(&.{ "rigid", "relaxed" }),
    .relax_mode = 1,
    .icon = "[+]",
    .indicators = &.{ "[#]", "[~]" },
};
