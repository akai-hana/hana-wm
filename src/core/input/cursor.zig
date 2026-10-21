//! Root-window cursor theming plus the startup mouse-bind reachability report.
//! Wire traffic: `xcb_change_window_attributes` on the root -- a root
//! DECORATION taken once at startup before the event loop, not a per-window
//! mutation, which is why this file carries its own allowlist entry in
//! check-layers.sh. The report is pure config-vs-grab analysis that `setup`
//! fires right after the theme is applied.
const std = @import("std");

const core = @import("core");
const xcb = core.xcb;
const log = std.log.scoped(.cursor);
const mouse = @import("mouse");

/// libxcb-cursor declarations, hand-written because `xcb_cursor_load_cursor` is
/// a static inline function in the C header, which cImport cannot bind.
const Context = opaque {};

extern fn xcb_cursor_context_new(
    conn: core.Connection,
    screen: *xcb.xcb_screen_t,
    ctx: *?*Context,
) c_int;
extern fn xcb_cursor_load_cursor(ctx: *Context, name: [*:0]const u8) u32;
extern fn xcb_cursor_context_free(ctx: ?*Context) void;

/// Applies the user's cursor theme to the root window; falls back silently if
/// xcb-cursor is unavailable or the cursor cannot be loaded.
fn setupRoot(conn: core.Connection, screen: core.Screen) void {
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

/// Applies the user's cursor theme and reports mouse binds that can never fire.
/// The root mouse grab itself is installed by the caller (main.zig calls
/// `keybinds.grabMouseButtons` next); the report is pure analysis of the config
/// against `keybinds.mouse_grab_buttons`, so it needs no grab to exist yet.
pub fn setup(conn: core.Connection, screen: core.Screen) void {
    setupRoot(conn, screen);
    mouse.reportUndeliverableMouseBinds();
}
