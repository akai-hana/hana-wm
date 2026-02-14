/// Common layout interface and utilities

const std   = @import("std");
const utils = @import("utils");
const debug = @import("debug");
const defs  = @import("defs");
const xcb   = defs.xcb;

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
    utils.configureWindow(conn, win, rect);
}
