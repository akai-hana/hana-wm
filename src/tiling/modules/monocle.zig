//! Monocle tiling layout. Stacks all windows fullscreen, showing only the
//! topmost one, with optional gap insets.

const tiling = @import("tiling");

// Variant index of the "gaps" variant; must match variantParse order below.
/// The ONE variant table for this layout.
const variants = [_]tiling.Variant{
    .{ .name = "gapless", .indicator = "<->" },
    .{ .name = "gaps", .indicator = ">-<" },
};

/// Ordinal of the "gaps" variant, read from the table above.
const variant_gaps: u8 = tiling.variantIndex(&variants, "gaps");

/// Compute monocle layout. Origin top-left, y-down. Gaps: full gap on each
/// screen edge when gaps enabled, else zero. All dimensions are u16 and
/// shrunk via shrinkClamped (floor clamped to min_dim).
pub fn compute(v: *const tiling.View, out: *tiling.List) void {
    // Guard the empty-order read below: a direct/test caller passing n==0
    // would otherwise panic on v.order[len - 1].
    if (v.order.len == 0) return;
    const m = v.env.margins;
    const gaps = v.params.variant_idx == variant_gaps;
    const inset: u16 = if (gaps) m.gap else 0;
    const total_margin = tiling.totalInset(inset, m);

    // focusedElse: fallback is the list tail, so the last-focused window
    // resurfaces on close.
    const top_win = tiling.focusedElse(v, v.order, v.order[v.order.len - 1]);

    // top_rect insets use the FULL workarea origin, not just waY: the x axis
    // was missing v.workarea.x and the top window landed at the screen's left
    // edge whenever the workarea started off-origin.
    const top_rect = tiling.insetRect(
        v.workarea.x + @as(i32, inset),
        tiling.waY(v) +| inset,
        v.workarea.width,
        v.workarea.height,
        total_margin,
        v.env.min_dim,
    );

    // One pass, in View.order order, one placement per window: the previous
    // shape emitted `top_win` first regardless of its position in v.order,
    // which broke the positional contract the sink relies on and left the top
    // window's stacking position dependent on where focus sat in the list.
    // (Emitting every window at the shared rect and hiding afterwards does not
    // work: appendPlacement only ever appends, so that shape double-counts.)
    for (v.order) |win| {
        if (win == top_win) tiling.emitView(v, out, win, top_rect) else tiling.emitHidden(out, win);
    }
}

/// This layout's registry contribution: metadata plus the dispatch hook.
pub const module = tiling.layoutModule("monocle", "[M]", compute, &variants, .{});
