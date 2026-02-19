//! Monocle layout - All windows fullscreen, stacked
/// Direct XCB calls - no batch overhead

const std = @import("std");
const defs = @import("defs");
const utils = @import("utils");
const layouts = @import("layouts");

const tiling = @import("tiling");
const State = tiling.State;
const xcb = defs.xcb;

pub fn tileWithOffset(conn: *xcb.xcb_connection_t, state: *State, windows: []const u32, screen_w: u16, screen_h: u16, y_offset: u16) void {
    if (windows.len == 0) return;

    const margin = state.margins();
    const gap    = margin.gap;
    const border = margin.border;

    // All windows in monocle share the same geometry, but only the top window
    // is ever visible — the rest are entirely hidden behind it.  Configure and
    // raise only that one window; the others are configured lazily the moment
    // they are brought to the top, so the cost here is always O(1).
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
            .y      = @intCast(y_offset + gap),
            .width  = if (screen_w > gap * 2 + border * 2) screen_w - gap * 2 - border * 2 else defs.MIN_WINDOW_DIM,
            .height = if (screen_h > gap * 2 + border * 2) screen_h - gap * 2 - border * 2 else defs.MIN_WINDOW_DIM,
        },
    };

    layouts.configureSafe(conn, top_win, rect);
    _ = xcb.xcb_configure_window(conn, top_win, xcb.XCB_CONFIG_WINDOW_STACK_MODE, &[_]u32{xcb.XCB_STACK_MODE_ABOVE});
}
