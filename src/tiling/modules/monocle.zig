//! Monocle tiling layout. Stacks all windows fullscreen, showing only the
//! topmost one, with optional gap insets.

const utils = @import("utils");
const tiling = @import("tiling");

/// Compute monocle layout. Origin top-left, y-down. Gaps: full gap on each
/// screen edge when gaps enabled, else zero. All dimensions are u16 and
/// shrunk via shrinkClamped (floor clamped to min_dim).
pub fn compute(v: tiling.View, out: *tiling.List) void {
    const m = v.env.margins;
    // Core variant index -> gaps-enabled (variant 1 of "gapless"/"gaps").
    const gap_variant: u8 = 1;
    const inset: u16 = if (v.env.variant_idx == gap_variant) m.gap else 0;
    const total_margin = utils.doubledBorder(m) + inset * 2;

    // Pick the top (visible) window: prefer the focused window, else the
    // list tail, so the last-focused window resurfaces on close.
    const top_win = tiling.focusedElse(&v, v.order, v.order[v.order.len - 1]);

    const top_rect = tiling.insetRect(inset, tiling.waY(&v) +| inset, v.workarea.width, v.workarea.height, total_margin, v.env.min_dim);

    // showOneHideRest: raise/configure `top` on-screen, park every other window.
    tiling.emitView(&v, out, top_win, top_rect, true);
    tiling.showOneHideRest(out, v.order, top_win);
}

/// This layout's registry contribution: metadata plus the dispatch hook.
pub const module: @import("plugin").Layout = .{
    .name = "monocle",
    .compute = tiling.computeHook(compute),
    .variant_count = 2,
    .variant_parse = tiling.variantParse(&.{ "gapless", "gaps" }),
    .icon = "[M]",
    .indicators = &.{ "<->", ">-<" },
};
