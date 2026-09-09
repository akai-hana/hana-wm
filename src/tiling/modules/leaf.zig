//! BSP (leaf) tiling layout.
//! Recursively bisects the screen along the longer axis to produce balanced regions.

const utils = @import("utils");
const model = @import("model");
const tiling = @import("tiling");

const Region = struct {
    x: i32,
    y: i32,
    w: u16,
    h: u16,
};

/// Compute BSP layout: recursive bisection of the longer axis 50/50 with one
/// gap at each seam; border subtracted at leaf nodes only.
pub fn compute(v: tiling.View, out: *tiling.List) void {
    const ctx = tiling.LayoutCtx{
        .v = &v,
        .out = out,
        .m = v.env.margins,
        .min_dim = v.env.min_dim,
    };

    // Strip the outer gap; each recursive split inserts one gap at its seam
    // (adjacent windows stay one gap_width apart).
    const area = tiling.outerArea(v.workarea, ctx.m.gap);
    tileRegion(ctx, v.order, .{ .x = area.x, .y = area.y, .w = area.w, .h = area.h });
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
    ctx: tiling.LayoutCtx,
    windows: []const model.WindowId,
    r: Region,
) void {
    const n = windows.len;
    if (n == 0) return;

    const border2: u16 = utils.doubledBorder(ctx.m);

    if (n == 1) {
        // All leaf placements are visible; hints applied by tiling.emitView.
        tiling.emitView(ctx.v, ctx.out, windows[0], tiling.insetRect(r.x, r.y, r.w, r.h, border2, ctx.min_dim), true);
        return;
    }

    const n_left: usize = n / 2;
    const gap = ctx.m.gap;

    const horizontal = r.w >= r.h;
    const split = halveWithMin(if (horizontal) r.w else r.h, gap, ctx.min_dim);
    const split_offset: i32 = @as(i32, @intCast(split.first +| gap));

    const first = Region{ .x = r.x, .y = r.y, .w = if (horizontal) split.first else r.w, .h = if (horizontal) r.h else split.first };
    const second = if (horizontal)
        Region{ .x = r.x + split_offset, .y = r.y, .w = split.second, .h = r.h }
    else
        Region{ .x = r.x, .y = r.y + split_offset, .w = r.w, .h = split.second };

    tileRegion(ctx, windows[0..n_left], first);
    tileRegion(ctx, windows[n_left..], second);
}

/// This layout's registry contribution: metadata plus the dispatch hook.
pub const module = tiling.layoutModule("leaf", "BSP", compute, .{});
