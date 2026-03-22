//! Monocle layout: all windows fullscreen, stacked; only the top window visible.

const core      = @import("core");
const constants = @import("constants");
const utils     = @import("utils");
const layouts   = @import("layouts");
const tiling    = @import("tiling");
const State     = tiling.State;
const xcb       = core.xcb;

pub fn tileWithOffset(ctx: *const layouts.LayoutCtx, state: *State, windows: []const u32, screen_w: u16, screen_h: u16, y_offset: u16) void {
    if (windows.len == 0) return;

    const margin  = state.margins();
    const gap     = margin.gap;
    const border2 = margin.border * 2;

    // Only configure and raise the top window; background windows are
    // configured lazily when brought to top, keeping cost O(1).
    const top_win = windows[windows.len - 1];

    const inset: u16 = if (state.layout_variants.monocle == .gaps) gap else 0;
    const total_margin = border2 + inset * 2;
    const rect: utils.Rect = .{
        .x      = @intCast(inset),
        .y      = @intCast(y_offset +| inset),
        .width  = if (screen_w > total_margin) screen_w - total_margin else constants.MIN_WINDOW_DIM,
        .height = if (screen_h > total_margin) screen_h - total_margin else constants.MIN_WINDOW_DIM,
    };

    layouts.configureSafe(ctx, top_win, rect);
    _ = xcb.xcb_configure_window(ctx.conn, top_win, xcb.XCB_CONFIG_WINDOW_STACK_MODE, &[_]u32{xcb.XCB_STACK_MODE_ABOVE});

    // Push non-top windows offscreen so they never show through a transparent
    // top window.
    //
    // Optimization: if the cache entry for a window has already been zeroed
    // (either by a previous monocle pass or by a workspace-switch push), the
    // window is already offscreen and sending another configure_window is
    // redundant. We still zero any valid cached rect so restoreWorkspaceGeom
    // does not replay a stale on-screen position for background windows.
    for (windows[0 .. windows.len - 1]) |win| {
        if (ctx.cache.getPtr(win)) |wd| {
            if (!wd.hasValidRect()) continue; // already offscreen — skip the round-trip
            wd.rect = tiling.ZERO_RECT;       // invalidate before sending
        }
        _ = xcb.xcb_configure_window(ctx.conn, win,
            xcb.XCB_CONFIG_WINDOW_X,
            &[_]u32{@bitCast(@as(i32, constants.OFFSCREEN_X_POSITION))});
    }
}
