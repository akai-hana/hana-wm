//! Monocle tiling layout. Stacks all windows fullscreen, showing only the
//! topmost one, with optional gap insets.

const std = @import("std");
const utils = @import("utils");
const model = @import("model");
const tiling = @import("tiling");

/// Compute monocle layout. Origin top-left, y-down. Gaps: full gap on each
/// screen edge when gaps enabled, else zero. All dimensions are u16 and
/// shrunk via shrinkClamped (floor clamped to min_dim).
pub fn compute(v: tiling.View, out: *tiling.List) void {
    // Empty workspace: the top-window pick indexes order[len - 1], which
    // would underflow. Emit nothing instead.
    if (v.order.len == 0) return;

    const m = v.env.margins;
    // Module-owned translation of the generic core variant index: the gaps
    // variant is active when the index equals gap_variant, which MUST equal
    // this module's plugin.Layout.gap_mode / variant_parse target (both 1 =
    // "gaps"). Mirrors the pipeline's former caller-side gaps flag.
    const gap_variant: u8 = 1;
    const inset: u16 = if (v.env.variant_idx == gap_variant) m.gap else 0;
    const total_margin = utils.doubledBorder(m) + inset * 2;

    // Pick the top (visible) window: prefer the focused window, else the list
    // tail, so the last-focused window resurfaces on close. A focus change
    // alone doesn't retile (monocle hides via offscreen positioning, not stack
    // order); snapScrollToFocused / mapWindowToScreen handle the retiles.
    const top_win = tiling.focusedElse(&v, v.order, v.order[v.order.len - 1]);

    const top_rect = utils.Rect{
        .x = @intCast(inset),
        .y = @intCast(tiling.waY(&v) +| inset),
        .width = tiling.shrinkClamped(v.workarea.width, total_margin, v.env.min_dim),
        .height = tiling.shrinkClamped(v.workarea.height, total_margin, v.env.min_dim),
    };

    // showOneHideRest: raise/configure `top` on-screen, park every other window.
    tiling.emitView(&v, out, top_win, top_rect, true);
    for (v.order) |win| {
        if (win == top_win) continue;
        tiling.emitHidden(out, win);
    }
}

/// Cast shim: plugin's type-free seam -> compute's typed params.
fn computeHook(view: *const anyopaque, out: *anyopaque) void {
    const v: *const tiling.View = @ptrCast(@alignCast(view));
    const o: *tiling.List = @ptrCast(@alignCast(out));
    compute(v.*, o);
}

/// Parses a monocle variant VALUE-STRING into its variant index, mapping the
/// accepted variant spellings to their ordinal slots (gapless=0, gaps=1),
/// exact-case. null for any other string.
fn variantParse(str: []const u8) ?u8 {
    if (std.mem.eql(u8, str, "gapless")) return 0;
    if (std.mem.eql(u8, str, "gaps")) return 1;
    return null;
}

/// This layout's registry contribution: metadata plus the dispatch hook.
pub const module: @import("plugin").Layout = .{
    .name = "monocle",
    .compute = computeHook,
    .variant_count = 2,
    .has_variants = true,
    .gap_mode = 1,
    .variant_parse = variantParse,
    .icon = "[M]",
    .indicators = &.{ "<->", ">-<" },
};
