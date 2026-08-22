//! Monocle tiling layout (pure port of modules/monocle.zig, WP2 calibration).
//! Stacks all windows fullscreen, showing only the topmost one, with optional gap insets.

const utils = @import("utils");
const model = @import("model");
const engine = @import("engine");

const View = engine.View;
const List = engine.List;

pub fn compute(v: View, out: *List) void {
    const m = v.margins;
    // Variant resolved by the caller (legacy: layout_variants.monocle == .gaps).
    const inset: u16 = if (v.monocle_gaps) m.gap else 0;
    const total_margin = utils.doubledBorder(m) + inset * 2;

    // Pick the top (visible) window: prefer the focused window, else the list
    // tail, so the last-focused window resurfaces on close. A focus change
    // alone doesn't retile (monocle hides via offscreen positioning, not stack
    // order); snapScrollToFocused / mapWindowToScreen handle the retiles.
    const top_win = engine.focusedElse(&v, v.order, v.order[v.order.len - 1]);

    const top_rect = utils.Rect{
        .x = @intCast(inset),
        .y = @intCast(engine.waY(&v) +| inset),
        .width = engine.shrinkClamped(v.workarea.width, total_margin, v.min_dim),
        .height = engine.shrinkClamped(v.workarea.height, total_margin, v.min_dim),
    };

    // showOneHideRest: raise/configure `top` on-screen, park every other window.
    engine.emitView(&v, out, top_win, top_rect, true);
    for (v.order) |win| {
        if (win == top_win) continue;
        engine.emitHidden(out, win);
    }
}
