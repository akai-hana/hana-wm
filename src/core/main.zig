//! Main event loop
//!
//! Uses POLL_ADD for the XCB and signal file descriptors plus an optional
//! TIMEOUT for the clock segment.  Each operation is resubmitted after it
//! fires (no MULTI flag, so kernel 5.4+ suffices).

const std     = @import("std");
const builtin = @import("builtin");

const defs      = @import("defs");
    const WM    = defs.WM;
    const xcb   = defs.xcb;

const constants = @import("constants");
const config    = @import("config");
const utils     = @import("utils");
const dpi       = @import("dpi");
const debug     = @import("debug");

const xkbcommon = @import("xkbcommon");
const input     = @import("input");
const events    = @import("events");

const bar     = @import("bar");

// xcb-cursor extern declarations.
// Declared manually instead of via cImport because xcb_cursor_load_name is a
// static inline function in some versions of the header, which Zig's cImport
// silently drops. extern declarations resolve directly against the linker symbol.
const XcbCursorContext = opaque {};
extern fn xcb_cursor_context_new(
    conn:   *xcb.xcb_connection_t,
    screen: *xcb.xcb_screen_t,
    ctx:    *?*XcbCursorContext,
) c_int;
extern fn xcb_cursor_load_cursor(ctx: *XcbCursorContext, name: [*:0]const u8) u32;
extern fn xcb_cursor_context_free(ctx: ?*XcbCursorContext) void;

fn setupRootCursor(conn: *xcb.xcb_connection_t, screen: *xcb.xcb_screen_t) void {
    var ctx: ?*XcbCursorContext = null;
    if (xcb_cursor_context_new(conn, screen, &ctx) >= 0) {
        defer xcb_cursor_context_free(ctx);
        const cursor = xcb_cursor_load_cursor(ctx.?, "left_ptr");
        if (cursor != xcb.XCB_NONE) {
            _ = xcb.xcb_change_window_attributes(
                conn, screen.*.root, xcb.XCB_CW_CURSOR, &[_]u32{cursor},
            );
            _ = xcb.xcb_free_cursor(conn, cursor);
            return;
        }
    }

    // Fallback: themed cursor unavailable, use core glyph cursor.
    debug.warn("xcb_cursor unavailable, falling back to core cursor", .{});
    const font   = xcb.xcb_generate_id(conn);
    const cursor = xcb.xcb_generate_id(conn);
    _ = xcb.xcb_open_font(conn, font, 6, "cursor");
    _ = xcb.xcb_create_glyph_cursor(
        conn, cursor, font, font,
        constants.CURSOR_LEFT_PTR, constants.CURSOR_LEFT_PTR_MASK,
        0, 0, 0, 65535, 65535, 65535,
    );
    _ = xcb.xcb_change_window_attributes(
        conn, screen.*.root, xcb.XCB_CW_CURSOR, &[_]u32{cursor},
    );
    _ = xcb.xcb_close_font(conn, font);
}

fn becomeWindowManager(conn: *xcb.xcb_connection_t, root: u32) !void {
    if (xcb.xcb_request_check(conn, xcb.xcb_change_window_attributes_checked(
        conn, root, xcb.XCB_CW_EVENT_MASK, &[_]u32{constants.EventMasks.ROOT_WINDOW}))) |err| {
        std.c.free(err);
        debug.err("Another window manager is running", .{});
        return error.AnotherWMRunning;
    }
}

pub fn main() !void {
    const conn = xcb.xcb_connect(null, null) orelse {
        debug.err("Failed to connect to X11 server", .{});
        return error.X11ConnectionFailed;
    };
    defer xcb.xcb_disconnect(conn);

    if (xcb.xcb_connection_has_error(conn) != 0) {
        debug.err("X11 connection has errors", .{});
        return error.X11ConnectionFailed;
    }

    const setup  = xcb.xcb_get_setup(conn);
    const screen = xcb.xcb_setup_roots_iterator(setup).data orelse return error.X11ScreenFailed;
    const root   = screen.*.root;

    try becomeWindowManager(conn, root);
    setupRootCursor(conn, screen);
    input.setupGrabs(conn, root);

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = if (builtin.mode == .Debug) gpa.allocator() else std.heap.c_allocator;

    const dpi_info = dpi.detect(conn, screen);
    debug.info("DPI Detection - DPI: {d:.1}, Scale: {d:.2}x", .{ dpi_info.dpi, dpi_info.scale_factor });

    const xkb_state = try allocator.create(xkbcommon.XkbState);
    defer allocator.destroy(xkb_state);
    xkb_state.* = try xkbcommon.XkbState.init(conn, allocator);
    defer xkb_state.deinit();

    var user_config = try config.loadConfigDefault(allocator);
    config.resolveKeybindings(user_config.keybindings.items, xkb_state, allocator);
    config.finalizeConfig(&user_config, screen);

    var wm = WM{
        .allocator  = allocator,
        .conn       = conn,
        .screen     = screen,
        .root       = root,
        .config     = user_config,
        .fullscreen = defs.FullscreenState.init(allocator),
        .xkb_state  = xkb_state,
        .dpi_info   = dpi_info,
    };
    defer wm.deinit();

    try utils.initAtomCache(conn);
    utils.initInputModelCache(wm.allocator);
    defer utils.deinitInputModelCache();

    const signal_fd = try events.setupSignalFd();
    defer std.posix.close(signal_fd);

    try events.initModules(&wm);
    defer events.deinitModules();

    bar.init(&wm) catch |err| {
        if (err != error.BarDisabled) debug.err("Bar init failed: {}", .{err});
    };
    defer bar.deinit();

    bar.updateTimerState();
    try events.grabKeybindings(&wm);
    _ = xcb.xcb_flush(conn);
    debug.info("Started", .{});

    try events.run(&wm, signal_fd);

    debug.info("Shutting down gracefully", .{});
}
