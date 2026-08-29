//! BSP (leaf) tiling layout.
//! Recursively bisects the screen along the longer axis to produce balanced regions.

const utils = @import("utils");
const model = @import("model");
const engine = @import("engine");

/// Compute BSP (binary space partition) layout. Origin top-left, y-down.
/// Outer gap stripped first; each recursive split halves the longer axis
/// 50/50 with one gap at the seam. Ties (w == h) favour vertical split.
/// Border subtracted at leaf nodes only. All dims u16, clamped to min_dim.
pub fn compute(v: engine.View, out: *engine.List) void {
    const m = v.env.margins;

    // Strip the outer gap; each recursive split inserts one gap at its seam
    // (adjacent windows stay one gap_width apart).
    const area = engine.outerArea(v.workarea, m.gap);
    tileRegion(&v, out, v.order, m, v.env.min_dim, area.x, area.y, area.w, area.h);
}

// Splits `dim` into two halves separated by `gap`, clamping each half to
// `min_dim` when `dim` is too small. `first + gap + second ~= dim` for
// normal inputs; recursive calls never produce zero-size regions.
inline fn halveWithMin(dim: u16, gap: u16, min_dim: u16) struct { first: u16, second: u16 } {
    const first: u16 = if (dim > gap) (dim - gap) / 2 else min_dim;
    const second: u16 = if (dim > first +| gap) dim - first - gap else min_dim;
    return .{ .first = first, .second = second };
}

/// Recursively tile `windows` into the region (x, y, w, h).
/// Splits the longer axis 50/50, inserting one gap at each seam; border subtracted at leaf nodes only.
/// Ties (w == h) favour a vertical split.
fn tileRegion(
    v: *const engine.View,
    out: *engine.List,
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
        const rect = utils.Rect{
            .x = @intCast(x),
            .y = @intCast(y),
            .width = engine.shrinkClamped(w, border2, min_dim),
            .height = engine.shrinkClamped(h, border2, min_dim),
        };
        // All leaf placements are visible; hints applied by engine.emitView.
        engine.emitView(v, out, windows[0], rect, true);
        return;
    }

    const n_left: usize = n / 2;
    const gap = m.gap;

    if (w >= h) {
        const split = halveWithMin(w, gap, min_dim);
        const right_x: i32 = x + @as(i32, @intCast(split.first +| gap));
        tileRegion(v, out, windows[0..n_left], m, min_dim, x, y, split.first, h);
        tileRegion(v, out, windows[n_left..], m, min_dim, right_x, y, split.second, h);
    } else {
        const split = halveWithMin(h, gap, min_dim);
        const bottom_y: i32 = y + @as(i32, @intCast(split.first +| gap));
        tileRegion(v, out, windows[0..n_left], m, min_dim, x, y, w, split.first);
        tileRegion(v, out, windows[n_left..], m, min_dim, x, bottom_y, w, split.second);
    }
}
