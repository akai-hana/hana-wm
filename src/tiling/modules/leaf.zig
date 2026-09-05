//! BSP (leaf) tiling layout.
//! Recursively bisects the screen along the longer axis to produce balanced regions.

const utils = @import("utils");
const model = @import("model");
const tiling = @import("tiling");

/// Compute BSP layout: recursive bisection of the longer axis 50/50 with one
/// gap at each seam; border subtracted at leaf nodes only.
pub fn compute(v: tiling.View, out: *tiling.List) void {
    const m = v.env.margins;

    // Strip the outer gap; each recursive split inserts one gap at its seam
    // (adjacent windows stay one gap_width apart).
    const area = tiling.outerArea(v.workarea, m.gap);
    tileRegion(&v, out, v.order, m, v.env.min_dim, area.x, area.y, area.w, area.h);
}

// Splits `dim` into two halves separated by `gap`, each clamped to `min_dim`.
// When `dim < 2*min_dim + gap` the halves can't both fit and the pair overflows
// the parent region; that degrades more gracefully than rendering sub-min_dim
// halves that would overlap each other in the seam.
inline fn halveWithMin(dim: u16, gap: u16, min_dim: u16) struct { first: u16, second: u16 } {
    const first: u16 = @max(min_dim, if (dim > gap) (dim - gap) / 2 else 0);
    const second: u16 = @max(min_dim, if (dim > first +| gap) dim - first - gap else 0);
    return .{ .first = first, .second = second };
}

/// Recursively tile `windows` into the region, splitting the longer axis
/// 50/50 with one gap per seam (border at leaf nodes; ties favour vertical).
fn tileRegion(
    v: *const tiling.View,
    out: *tiling.List,
    windows: []const model.WindowId,
    m: utils.Margins,
    min_dim: u16,
    x: i32,
    y: i32,
    w: u16,
    h: u16,
) void {
    const n = windows.len;
    if (n == 0) return;

    const border2: u16 = utils.doubledBorder(m);

    if (n == 1) {
        const rect = tiling.insetRect(x, y, w, h, border2, min_dim);
        // All leaf placements are visible; hints applied by tiling.emitView.
        tiling.emitView(v, out, windows[0], rect, true);
        return;
    }

    const n_left: usize = n / 2;
    const gap = m.gap;

    const horizontal = w >= h;
    const split = halveWithMin(if (horizontal) w else h, gap, min_dim);
    const split_offset: i32 = @as(i32, @intCast(split.first +| gap));
    const second_x: i32 = if (horizontal) x + split_offset else x;
    const second_y: i32 = if (horizontal) y else y + split_offset;

    tileRegion(v, out, windows[0..n_left], m, min_dim, x, y, if (horizontal) split.first else w, if (horizontal) h else split.first);
    tileRegion(v, out, windows[n_left..], m, min_dim, second_x, second_y, if (horizontal) split.second else w, if (horizontal) h else split.second);
}

/// This layout's registry contribution: metadata plus the dispatch hook.
pub const module: @import("plugin").Layout = .{
    .name = "leaf",
    .compute = tiling.computeHook(compute),
    .icon = "BSP",
};
