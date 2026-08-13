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
    // order) — snapScrollToFocused retiles on focus cycling, and on spawn
    // mapWindowToScreen passes the new window as ctx.focused_win.
    const top_win: u32 = blk: {
        if (ctx.focused_win) |f| if (std.mem.indexOfScalar(u32, windows, f) != null) break :blk f;
        break :blk windows[windows.len - 1];
    };

    const top_rect = utils.Rect{
        .x = @intCast(inset),
        .y = @intCast(y_offset +| inset),
        .width = layouts.shrinkClamped(screen_w, total_margin, state.config.min_window_dim),
        .height = layouts.shrinkClamped(screen_h, total_margin, state.config.min_window_dim),
    };

    // Only raise on-screen: a background retile (LayoutCtx.is_background) is a
    // cache warm-up for an unviewed workspace, and raising would leave `top_win`
    // first in the global stacking order with nothing to ever lower it again.
    layouts.configureWithHintsAndRaiseIfVisible(ctx, top_win, top_rect);

    pushBackgroundWindowsOffscreen(ctx, windows, top_win);
}

/// Push all windows except `top_win` offscreen so they never show through a
/// transparent top window.
fn pushBackgroundWindowsOffscreen(
    ctx: *const layouts.LayoutCtx,
    windows: []const u32,
    top_win: u32,
) void {
    for (windows) |win| {
        if (win == top_win) continue;
        layouts.pushWindowOffscreenAndInvalidate(ctx, win);
    }
}
