/// Common layout interface and utilities
/// Eliminates duplication across all layout modules
/// OPTIMIZED: Direct XCB calls instead of batch overhead

const std = @import("std");
const utils = @import("utils");
const tiling = @import("tiling");
const debug = @import("debug");
const defs = @import("defs");
const xcb = defs.xcb;

const State = tiling.State;

/// Direct configure operation - no batch overhead
/// XCB already buffers internally, so we just call directly
pub inline fn configure(
    conn: *xcb.xcb_connection_t,
    win: u32,
    rect: utils.Rect
) void {
    const values = [_]u32{
        @bitCast(@as(i32, rect.x)),
        @bitCast(@as(i32, rect.y)),
        rect.width,
        rect.height,
    };
    _ = xcb.xcb_configure_window(conn, win,
        xcb.XCB_CONFIG_WINDOW_X | xcb.XCB_CONFIG_WINDOW_Y |
        xcb.XCB_CONFIG_WINDOW_WIDTH | xcb.XCB_CONFIG_WINDOW_HEIGHT,
        &values);
}

/// Unified error-handling wrapper for configure operations
/// Provides consistent error logging across all layouts
pub inline fn configureSafe(
    conn: *xcb.xcb_connection_t,
    win: u32,
    rect: utils.Rect
) void {
    if (!rect.isValid()) {
        debug.err("Invalid rect for window 0x{x}: {}x{} at {},{}", 
            .{ win, rect.width, rect.height, rect.x, rect.y });
        return;
    }
    configure(conn, win, rect);
}
