//! Monocle layout - All windows fullscreen, stacked
/// OPTIMIZED: Direct XCB calls - no batch overhead

const std = @import("std");
const defs = @import("defs");
const utils = @import("utils");
const layouts = @import("layouts");

const tiling = @import("tiling");
const State = tiling.State;
const xcb = defs.xcb;

pub fn tileWithOffset(conn: *xcb.xcb_connection_t, state: *State, windows: []const u32, screen_w: u16, screen_h: u16, y_offset: u16) void {
    _ = state;
    if (windows.len == 0) return;

    const rect = utils.Rect{
        .x = 0,
        .y = @intCast(y_offset),
        .width = screen_w,
        .height = screen_h,
    };

    // Configure all windows to fullscreen
    for (windows) |win| {
        layouts.configureSafe(conn, win, rect);
    }

    // Raise the last window (most recently focused in tiled_windows order)
    const top_win = windows[windows.len - 1];
    _ = xcb.xcb_configure_window(conn, top_win, xcb.XCB_CONFIG_WINDOW_STACK_MODE, &[_]u32{xcb.XCB_STACK_MODE_ABOVE});
}
