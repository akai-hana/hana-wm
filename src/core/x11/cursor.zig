//! Root-window cursor theming via libxcb-cursor.
//!
//! Lives here, not in `input/input.zig`, because applying a cursor theme to the
//! root window is root DECORATION rather than input: it is one startup call
//! that touches the X connection and the screen and nothing else. `input` used
//! to carry it as a shim whose only purpose was to justify the extern
//! declarations, which then read as if input owned cursor policy.
//!
//! The declarations are hand-written because `xcb_cursor_load_cursor` is a
//! static inline function in the C header, which cImport cannot bind.

const std = @import("std");
const core = @import("core");
const xcb = core.xcb;
const log = @import("log");

const Context = opaque {};

extern fn xcb_cursor_context_new(
    conn: core.Connection,
    screen: *xcb.xcb_screen_t,
    ctx: *?*Context,
) c_int;
extern fn xcb_cursor_load_cursor(ctx: *Context, name: [*:0]const u8) u32;
extern fn xcb_cursor_context_free(ctx: ?*Context) void;

/// Applies the user's cursor theme to the root window. Falls back silently
/// if xcb-cursor is unavailable or the cursor cannot be loaded.
pub fn setupRoot(conn: core.Connection, screen: core.Screen) void {
    var cursor_ctx: ?*Context = null;
    if (xcb_cursor_context_new(conn, screen, &cursor_ctx) < 0) return;
    defer xcb_cursor_context_free(cursor_ctx);

    const cursor = xcb_cursor_load_cursor(cursor_ctx.?, "left_ptr");
    if (cursor == xcb.XCB_NONE) return;

    const cookie = xcb.xcb_change_window_attributes_checked(
        conn,
        screen.root,
        xcb.XCB_CW_CURSOR,
        &[_]u32{cursor},
    );
    if (xcb.xcb_request_check(conn, cookie)) |err| {
        log.err("Failed to set root cursor: error_code={}", .{err.*.error_code});
        std.c.free(err);
    }

    // The server reference-counts cursors; freeing our handle is safe;
    // it stays alive as long as the root window holds a reference.
    _ = xcb.xcb_free_cursor(conn, cursor);
}
