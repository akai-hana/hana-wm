//! WM entry point and main event loop.
//!
//! Inits the X11 connection, loads configuration, and drives all I/O through `poll`.

// Zig stdlib
const std     = @import("std");
const builtin = @import("builtin");

// core/
const utils     = @import("utils");
const constants = @import("constants");
const events    = @import("events");
const dpi       = @import("dpi");

// config/
const config    = @import("config");
const defs      = @import("defs");
    const WM    = defs.WM;
    const xcb   = defs.xcb;

// input/
const input     = @import("input");
const xkbcommon = @import("xkbcommon");

// tiling/
const layouts = @import("layouts");

// bar/
const bar     = @import("bar");

// debug/
const debug     = @import("debug");

// xcb-cursor extern declarations.
//
// Declared manually instead of via cImport because xcb_cursor_load_name is a static
// inline function in some versions of the header, which Zig's cImport silently drops.
// Extern declarations resolve directly against the linker symbol.
const XcbCursorContext = opaque {};

extern fn xcb_cursor_context_new(
    conn:   *xcb.xcb_connection_t,
    screen: *xcb.xcb_screen_t,
    ctx:    *?*XcbCursorContext,
) c_int;

extern fn xcb_cursor_load_cursor(ctx: *XcbCursorContext, name: [*:0]const u8) u32;
extern fn xcb_cursor_context_free(ctx: ?*XcbCursorContext) void;

/// Sets the root window cursor to the standard left-pointer shape.
/// Prefers a themed cursor via xcb-cursor; falls back to X11's built-in
/// cursor font (always present on a conforming server) if loading fails.
fn setupRootCursor(conn: *xcb.xcb_connection_t, screen: *xcb.xcb_screen_t) void {
    var cursor_ctx: ?*XcbCursorContext = null;
    if (xcb_cursor_context_new(conn, screen, &cursor_ctx) >= 0) {
        defer xcb_cursor_context_free(cursor_ctx);
        const cursor = xcb_cursor_load_cursor(cursor_ctx.?, "left_ptr");
        if (cursor != xcb.XCB_NONE) {
            _ = xcb.xcb_change_window_attributes(
                conn, screen.*.root, xcb.XCB_CW_CURSOR, &[_]u32{cursor},
            );
            _ = xcb.xcb_free_cursor(conn, cursor);
            return;
        }
    }

    // FALLBACK CODE LOGIC; COMMENTED OUT BECAUSE I'M NOT EVEN SURE IT WORKS
    // debug.warn("xcb_cursor unavailable, falling back to core cursor", .{});
    // const font   = xcb.xcb_generate_id(conn);
    // const cursor = xcb.xcb_generate_id(conn);
    // _ = xcb.xcb_open_font(conn, font, "cursor".len, "cursor");
    // const rgb_channel_min: u16 = 0;
    // const rgb_channel_max: u16 = 65535;
    // _ = xcb.xcb_create_glyph_cursor(
    //     conn, cursor, font, font,
    //     constants.CURSOR_LEFT_PTR, constants.CURSOR_LEFT_PTR_MASK,
    //     rgb_channel_min, rgb_channel_min, rgb_channel_min,
    //     rgb_channel_max, rgb_channel_max, rgb_channel_max,
    // );
    // _ = xcb.xcb_change_window_attributes(
    //     conn, screen.*.root, xcb.XCB_CW_CURSOR, &[_]u32{cursor},
    // );
    // _ = xcb.xcb_close_font(conn, font);
}

/// Attempts to claim the WM role by subscribing to substructure-redirect
/// events on the root window.  X11 permits only one client to hold this
/// mask at a time, so the server returns an error if another WM is running.
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
    // GPA tracks every allocation in debug builds so leaks surface at exit;
    // in release builds the C allocator is faster and avoids the overhead.
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
        .dpi_info   = dpi_info,
    };
    defer wm.deinit();

    try utils.initAtomCache(conn);
    utils.initInputModelCache(wm.allocator);
    defer utils.deinitInputModelCache();
    defer layouts.deinitSizeHintsCache(allocator);

    const signal_fd = try events.setupSignalPipe();
    defer std.posix.close(signal_fd);
    defer events.deinitSignalPipe();

    try events.initModules(&wm, xkb_state);
    defer events.deinitModules();

    bar.init(&wm) catch |err| {
        if (err != error.BarDisabled) debug.err("Bar init failed: {}", .{err});
    };
    defer bar.deinit();

    bar.updateTimerState();
    try events.grabKeybindings(&wm);
    // XCB batches requests; flush now so every setup call above reaches the
    // server before we block in the event loop waiting for replies/events.
    _ = xcb.xcb_flush(conn);
    debug.info("Started", .{});

    try events.run(&wm, signal_fd);

    debug.info("Shutting down gracefully", .{});
}

