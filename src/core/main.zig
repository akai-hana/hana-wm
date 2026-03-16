//! hana's entry point and main loop.
//!
//! Global WM state (conn, screen, root, allocator, config, dpi_info) lives in
//! core.zig and is initialized here at startup. Modules import core directly.

// Zig stdlib
const std     = @import("std");
const builtin = @import("builtin");

// core/
const core    = @import("core");
const utils   = @import("utils");
const events  = @import("events");
const dpi     = @import("dpi");
const config  = @import("config");
const xcb     = core.xcb;

// input/
const input = @import("input");
const focus = @import("focus");

// tiling/
const layouts = @import("layouts");

// bar/
const bar = @import("bar");

// debug/
const debug = @import("debug");

/// hana's startup sequence and event-loop entry point.
pub fn main() !void {
    const x = try connectToX();
    defer xcb.xcb_disconnect(x.conn);

    core.conn     = x.conn;
    core.screen   = x.screen;
    core.root     = x.root;
    core.alloc    = std.heap.c_allocator;
    core.dpi_info = dpi.detect(x.conn, x.screen);

    input.setup(x.conn, x.screen, x.root);
    try input.initXkb(x.conn, core.alloc);
    defer input.deinitXkb();

    core.config = try config.load(core.alloc, x.screen, input.getXkbState());
    defer core.config.deinit();

    try initGlobalCaches(x.conn, core.alloc);
    // Defers run in LIFO order: core.config.deinit() must run before deinitGlobalCaches().
    defer deinitGlobalCaches(core.alloc);

    try events.setupSignalPipe();
    defer events.deinitSignalPipe();

    try events.grabKeybindings();
    try events.initModules();
    defer events.deinitModules();

    initBar();
    defer bar.deinit();

    bar.updateTimerState();
    _ = xcb.xcb_flush(core.conn);
    debug.info("hana booted up successfully!", .{});

    try events.run();
    debug.info("Shutting down gracefully...", .{});
}

/// X server connection context returned by connectToX.
const X = struct {
    conn:   *xcb.xcb_connection_t,
    screen: *xcb.xcb_screen_t,
    root:   core.WindowId,
};

/// Opens an X server connection, fetches screen 0, and registers hana as the WM.
/// Fails if the display is unavailable, the screen cannot be retrieved,
/// or another WM is already running.
fn connectToX() !X {
    // Pass null for both display and screen number: XCB reads $DISPLAY and
    // selects screen 0. The screen number parameter is a legacy X11 concept —
    // modern multi-monitor setups use a single unified screen via Xrandr/Xinerama.
    const conn_ = xcb.xcb_connect(null, null).?;

    if (xcb.xcb_connection_has_error(conn_) != 0) {
        debug.err("X11 connection failed", .{});
        return error.X11ConnectionFailed;
    }

    const screen_ = xcb.xcb_setup_roots_iterator(xcb.xcb_get_setup(conn_)).data
        orelse return error.X11ScreenFailed;

    // Claim SubstructureRedirectMask on the root window to become the WM.
    // The X server rejects this if another WM already holds it.
    const cookie = xcb.xcb_change_window_attributes_checked(
        conn_, screen_.*.root, xcb.XCB_CW_EVENT_MASK,
        &[_]u32{@import("constants").EventMasks.ROOT_WINDOW},
    );
    if (xcb.xcb_request_check(conn_, cookie)) |err| {
        debug.err("Another window manager is already running: {}", .{err});
        std.c.free(err);
        return error.AnotherWMRunning;
    }

    return .{ .conn = conn_, .screen = screen_, .root = screen_.*.root };
}

/// Initializes the bar, logging the outcome if it is disabled or not found.
///
/// if/else used instead of switch because bar.init's error set is inferred/anyerror,
/// so BarDisabled and BarNotFound are not statically declared members and can't be switch arms.
fn initBar() void {
    bar.init() catch |err| {
        if (err == error.BarDisabled) {
            debug.info("Bar disabled on user config.", .{});
        } else if (err == error.BarNotFound) {
            debug.info("Bar not found; either purposefully removed by user, or changed bar.zig's name/path from defaults (src/bar/bar.zig).", .{});
        } else {
            debug.err("Bar init failed: {}", .{err});
        }
    };
}

/// Initializes global utility caches.
fn initGlobalCaches(conn_: *xcb.xcb_connection_t, alloc: std.mem.Allocator) !void {
    try utils.initAtomCache(conn_);    // Intern frequently used X atoms
    utils.initInputModelCache(alloc);  // Build keysym to keycode lookup tables
    focus.init(alloc);
}

/// Cleans up global utility caches.
fn deinitGlobalCaches(alloc: std.mem.Allocator) void {
    utils.deinitInputModelCache();
    layouts.deinitSizeHintsCache(alloc); // Also frees cached ICCCM size hints
    focus.deinit();
}
