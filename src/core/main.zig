//! hana's main loop
//! Entry point to and orchestrator of all hana's subsystems.

const std = @import("std");

const core = @import("core");
const xcb = core.xcb;
const utils = @import("utils");
const events = @import("events");
const config = @import("config");
const constants = @import("constants");
const scale = @import("scale");
const debug = @import("debug");
const input = @import("input");
const window = @import("window");
const bar = @import("bar");

/// hana's startup sequence and event-loop entry point.
pub fn main() !void {
    const x = try connectToX();
    defer xcb.xcb_disconnect(x.conn);

    const alloc = std.heap.c_allocator;
    core.dpi_info = scale.detectDpi(x.conn, x.screen);

    input.setup(x.conn, x.screen, x.root);
    try input.initXkb(x.conn);
    defer input.deinitXkb();

    const loaded_config = try config.load(alloc, x.screen, input.getXkbState());

    // core.init() copies loaded_config by value and becomes the canonical
    // owner; must run before any core.getState() call.
    core.init(x.conn, x.screen, x.root, alloc, loaded_config);
    // config.load() already built loaded_config's keybind_resolver, and
    // Config.deinit tears it down internally (before freeing the keybindings
    // whose Actions it points into) — see KeybindResolver in types.zig. That
    // used to be two separate `defer`s here, relying on their LIFO relative
    // order to get the teardown sequence right; now it's just this one
    // (item 10 in the config-subsystem review).
    defer core.getState().config.deinit(alloc);

    try utils.initAtomCache(x.conn);
    utils.advertiseEwmhSupport(x.conn, x.screen, x.root);

    try events.setupSignalPipe();
    defer events.deinitSignalPipe();

    events.grabKeybindings();
    try window.init(alloc);
    defer window.deinit();

    const bar_enabled = core.getState().config.bar.enabled;
    if (bar_enabled) {
        bar.init() catch |err| debug.err("Bar init failed: {}", .{err});
    }
    defer if (bar_enabled) bar.deinit();

    _ = xcb.xcb_flush(x.conn);
    debug.info("hana booted up successfully!", .{});

    try events.run();
    debug.info("Shutting down gracefully...", .{});
}

/// X server connection context returned by connectToX.
const X = struct {
    conn: *xcb.xcb_connection_t,
    screen: *xcb.xcb_screen_t,
    root: core.WindowId,
};

/// Opens an X server connection, fetches screen 0, and registers hana as the WM.
/// Fails if the display is unavailable, the screen cannot be retrieved,
/// or another WM is already running.
fn connectToX() !X {
    const conn = xcb.xcb_connect(null, null) orelse unreachable;

    if (xcb.xcb_connection_has_error(conn) != 0) {
        debug.err("X11 connection failed", .{});
        return error.X11ConnectionFailed;
    }

    const screen = xcb.xcb_setup_roots_iterator(xcb.xcb_get_setup(conn)).data orelse return error.X11ScreenFailed;

    // Claim SubstructureRedirectMask on the root window to become the WM;
    // the X server rejects this if another WM already holds it.
    const cookie = xcb.xcb_change_window_attributes_checked(
        conn,
        screen.*.root,
        xcb.XCB_CW_EVENT_MASK,
        &[_]u32{constants.EventMasks.ROOT_WINDOW},
    );
    if (xcb.xcb_request_check(conn, cookie)) |err| {
        debug.err("Another window manager is already running: {*}", .{err});
        std.c.free(err);
        return error.AnotherWMRunning;
    }

    return .{ .conn = conn, .screen = screen, .root = screen.*.root };
}
