//! Monocle layout: all windows fullscreen, stacked; only the top window visible.

const defs      = @import("defs");
const constants = @import("constants");
const utils     = @import("utils");
const layouts   = @import("layouts");
const tiling    = @import("tiling");
const State     = tiling.State;
const xcb       = defs.xcb;

pub fn tileWithOffset(ctx: *const layouts.LayoutCtx, state: *State, windows: []const u32, screen_w: u16, screen_h: u16, y_offset: u16) void {
    if (windows.len == 0) return;

    const margin  = state.margins();
    const gap     = margin.gap;
    const border2 = margin.border * 2;

    // Only configure and raise the top window; background windows are
    // configured lazily when brought to top, keeping cost O(1).
    const top_win = windows[windows.len - 1];

    const gap2b = gap * 2 + border2;
    const rect: utils.Rect = switch (state.layout_variations.monocle) {
        .gapless => .{
            .x      = 0,
            .y      = @intCast(y_offset),
            .width  = if (screen_w > border2) screen_w - border2 else constants.MIN_WINDOW_DIM,
            .height = if (screen_h > border2) screen_h - border2 else constants.MIN_WINDOW_DIM,
        },
        .gaps => .{
            .x      = @intCast(gap),
            .y      = @intCast(y_offset +| gap),
            .width  = if (screen_w > gap2b) screen_w - gap2b else constants.MIN_WINDOW_DIM,
            .height = if (screen_h > gap2b) screen_h - gap2b else constants.MIN_WINDOW_DIM,
        },
    };

    layouts.configureSafe(ctx, top_win, rect);
    _ = xcb.xcb_configure_window(ctx.conn, top_win, xcb.XCB_CONFIG_WINDOW_STACK_MODE, &[_]u32{xcb.XCB_STACK_MODE_ABOVE});

    // Push non-top windows offscreen so they never show through a transparent
    // top window. Their cached rects are zeroed so restoreWorkspaceGeom won't
    // replay stale on-screen positions — it will fall back to a full retile,
    // which repeats this offscreen push correctly.
    for (windows[0 .. windows.len - 1]) |win| {
        _ = xcb.xcb_configure_window(ctx.conn, win,
            xcb.XCB_CONFIG_WINDOW_X,
            &[_]u32{@bitCast(@as(i32, constants.OFFSCREEN_X_POSITION))});
        if (ctx.cache) |cache| {
            if (cache.getPtr(win)) |wd| wd.rect = .{ .x = 0, .y = 0, .width = 0, .height = 0 };
        }
    }
}
