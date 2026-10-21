//! Monocle tiling layout. Stacks all windows fullscreen, showing only the
//! topmost one, with optional gap insets.

const tiling = @import("tiling");

const variants = [_]tiling.Variant{
    .{ .name = "gapless", .indicator = "<->" },
    .{ .name = "gaps", .indicator = ">-<" },
};

const variant_gaps: u8 = tiling.variantIndex(&variants, "gaps");

/// Compute monocle layout, origin top-left, y-down. A full gap on each screen
/// edge when gaps are enabled, else zero; dimensions are u16, shrunk via
/// shrinkClamped (floored to min_dim).
fn compute(v: *const tiling.View, out: *tiling.List) void {
    const ctx = tiling.LayoutCtx.init(v, out);
    const m = ctx.m;
    const gaps = v.params.variant_idx == variant_gaps;
    const inset: u16 = if (gaps) m.gap else 0;
    const total_margin = tiling.totalInset(inset, m);

    // focusedElse: fallback is the list tail, so the last-focused window
    // resurfaces on close.
    const top_win = tiling.focusedElse(v, v.order, v.order[v.order.len - 1]);

    // top_rect insets use the FULL workarea origin, not just waY: without
    // v.workarea.x a workarea starting off-origin would land the top window at
    // the screen's left edge.
    const top_rect = tiling.insetRect(
        tiling.waX(v.workarea) + @as(i32, inset),
        tiling.waY(v.workarea) +| @as(i32, inset),
        tiling.waWidth(v.workarea),
        tiling.waHeight(v.workarea),
        total_margin,
        ctx.min_dim,
    );

    // One pass in View.order order, one placement per window: the sink
    // consumes `out` positionally against `order`, so emitting `top_win` first
    // would break that contract (and make stacking depend on where focus sat).
    // Emitting all at the shared rect and hiding after does not work either:
    // appendPlacement only appends, so that double-counts. A workarea that
    // cannot hold the inset at a positive size parks every window including the
    // top one -- the min_dim floor would flare the rect past the workarea edge.
    const fits = tiling.insetFits(tiling.waWidth(v.workarea), tiling.waHeight(v.workarea), total_margin);
    for (v.order) |win| {
        if (win == top_win and fits) tiling.emitView(v, out, win, top_rect) else tiling.emitHidden(out, win);
    }
}

pub const module = tiling.layoutModule("monocle", "[M]", compute, &variants, .{});
