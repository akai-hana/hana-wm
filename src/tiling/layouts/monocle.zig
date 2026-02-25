//! Monocle layout: all windows fullscreen, stacked; only top window visible.

const defs    = @import("defs");
const utils   = @import("utils");
const layouts = @import("layouts");

const tiling = @import("tiling");
const State  = tiling.State;
const xcb    = defs.xcb;

pub fn tileWithOffset(conn: *xcb.xcb_connection_t, state: *State, windows: []const u32, screen_w: u16, screen_h: u16, y_offset: u16) void {
    if (windows.len == 0) return;

    const margin = state.margins();
    const gap    = margin.gap;
    const border = margin.border;

    // All windows share the same geometry but only the top one is visible.
    // Configure and raise only that one; the others are configured lazily
    // when brought to the top, keeping cost O(1).
    const top_win = windows[windows.len - 1];

    const rect: utils.Rect = switch (state.layout_variations.monocle) {
        .gapless => .{
            .x      = 0,
            .y      = @intCast(y_offset),
            .width  = if (screen_w > border * 2) screen_w - border * 2 else defs.MIN_WINDOW_DIM,
            .height = if (screen_h > border * 2) screen_h - border * 2 else defs.MIN_WINDOW_DIM,
        },
        .gaps => .{
            .x      = @intCast(gap),
            .y      = @intCast(y_offset +| gap),
            .width  = if (screen_w > gap * 2 + border * 2) screen_w - gap * 2 - border * 2 else defs.MIN_WINDOW_DIM,
            .height = if (screen_h > gap * 2 + border * 2) screen_h - gap * 2 - border * 2 else defs.MIN_WINDOW_DIM,
        },
    };

    layouts.configureSafe(conn, top_win, rect);
    _ = xcb.xcb_configure_window(conn, top_win, xcb.XCB_CONFIG_WINDOW_STACK_MODE, &[_]u32{xcb.XCB_STACK_MODE_ABOVE});
}
