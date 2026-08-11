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

    // Pick the top (visible) window: prefer the focused window, falling back
    // to the list tail if focus info is unavailable. On close, this ensures
    // the last-focused window resurfaces rather than an arbitrary one.
    //
    // (A focus change alone doesn't retile, since monocle hides windows via
    // offscreen positioning rather than stack order — snapScrollToFocused()
    // in tiling.zig retiles on focus-cycle keypresses to compensate. On
    // spawn, window.zig's mapWindowToScreen passes the new window in as
    // ctx.focused_win via retileCurrentWorkspaceWithPendingFocus, since
    // focus.setFocus for it hasn't run yet at retile time.)
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

    // Only raise on-screen: a background retile (see LayoutCtx.is_background)
    // is purely a geometry-cache warm-up for a workspace nobody is viewing,
    // and raising `top_win` here would make it first in the *global*
    // stacking order — above the bar and every window on the workspace
    // actually being looked at — with nothing to ever lower it again.
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
