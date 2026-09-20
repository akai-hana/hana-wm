//! BSP (leaf) tiling layout.
//! Recursively bisects the screen along the longer axis to produce balanced regions.

const utils = @import("utils");
const model = @import("model");
const tiling = @import("tiling");
const Region = tiling.Region;

/// Compute BSP layout: recursive bisection of the longer axis 50/50 with one
/// gap at each seam; border subtracted at leaf nodes only.
pub fn compute(v: *const tiling.View, out: *tiling.List) void {
    const ctx = tiling.LayoutCtx{
        .v = v,
        .out = out,
        .m = v.env.margins,
        .min_dim = v.env.min_dim,
    };

    // Strip the outer gap; each recursive split inserts one gap at its seam
    // (adjacent windows stay one gap_width apart).
    const area = tiling.outerArea(v.workarea, ctx.m.gap);
    tileRegion(ctx, v.order, area);
}

/// Recursively tile `windows` into the region, splitting the longer axis
/// 50/50 with one gap per seam (border at leaf nodes; ties favour vertical).
fn tileRegion(
    ctx: tiling.LayoutCtx,
    windows: []const model.WindowId,
    r: Region,
) void {
    const n = windows.len;
    const border2: u16 = utils.doubledBorder(ctx.m);

    if (n == 1) {
        // All leaf placements are visible; hints applied by tiling.emitView.
        tiling.emitView(ctx.v, ctx.out, windows[0], tiling.insetRect(r.x, r.y, r.w, r.h, border2, ctx.min_dim));
        return;
    }

    const n_left: usize = n / 2;
    const gap = ctx.m.gap;

    const horizontal = r.w >= r.h;
    const dim: u32 = if (horizontal) r.w else r.h;
    // The pane cannot hold two min-dim children plus the seam gap: the leaf
    // inset would floor both halves to min_dim and push the second past the
    // parent (overlapping its neighbor). Hand the whole region to the focused
    // window and park the rest, the same overflow-share shape fibonacci uses.
    if (dim < @as(@TypeOf(dim), ctx.min_dim) * 2 +| @as(@TypeOf(dim), gap)) {
        const top = tiling.focusedElse(ctx.v, windows, windows[0]);
        tiling.emitOverflowShare(ctx, windows, top, r);
        return;
    }

    // bisectRegion keeps the pair inside the parent: `first + gap + second`
    // never exceeds `dim`, so a tight pane can't push a child past it.
    const split = tiling.bisectRegion(@intCast(dim), gap);
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
