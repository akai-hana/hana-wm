//! Monocle tiling layout
//! Stacks all windows fullscreen, showing only the topmost one, with optional gap insets.

const std = @import("std");

const utils = @import("utils");
const layouts = @import("layouts");
const tiling = @import("tiling");
const State = tiling.State;

/// Tile `windows` into monocle mode using the given screen area.
pub fn tileWithOffset(
    ctx: *const layouts.LayoutCtx,
    state: *State,
    windows: []const u32,
    screen_w: u16,
    screen_h: u16,
    y_offset: u16,
) void {
    const m = state.margins();
    const inset: u16 = if (state.config.layout_variants.monocle == .gaps) m.gap else 0;
    const total_margin = utils.doubledBorder(m) + inset * 2;

    // Pick the top (visible) window: prefer the focused window, else the list
    // tail, so the last-focused window resurfaces on close. A focus change
    // alone doesn't retile (monocle hides via offscreen positioning, not stack
    // order); snapScrollToFocused / mapWindowToScreen handle the retiles.
    const top_win = layouts.focusedElse(ctx, windows, windows[windows.len - 1]);

    const top_rect = utils.Rect{
        .x = @intCast(inset),
        .y = @intCast(y_offset +| inset),
        .width = layouts.shrinkClamped(screen_w, total_margin, state.config.min_window_dim),
        .height = layouts.shrinkClamped(screen_h, total_margin, state.config.min_window_dim),
    };

    layouts.showOneHideRest(ctx, windows, top_win, top_rect);
}
