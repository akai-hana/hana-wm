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

    var loaded_config = try config.load(alloc, x.screen, input.getXkbState());
    loaded_config.bar.scaled_font_size = scale.scaleFontSize(loaded_config.bar.font_size, x.screen);

    // Everything core.getState() will ever hand out is ready now — conn, screen,
    // root, alloc, and the fully-resolved config — so this is the one point where
    // core's process-wide state comes into existence. No other module may call
    // core.getState() before this line.
    //
    // core.init() copies loaded_config by value; from here on the copy living in
    // core's state is the canonical one (and the one a SIGHUP reload replaces —
    // see events.handleConfigReload), so the deferred deinit below targets
    // core.getState().config rather than the now-redundant local. Deinit'ing the
    // local instead would free memory the copy in core's state still points to.
    core.init(x.conn, x.screen, x.root, alloc, loaded_config);
    defer core.getState().config.deinit(alloc);
    // Defers are LIFO: deinitKeybindMap runs before the config deinit above, so
    // the map is cleared (backing array freed) while its action pointers are
    // still valid.
    defer config.deinitKeybindMap(alloc);

    try utils.initAtomCache(x.conn);
    // No defer needed: atom values are plain integers (xcb_atom_t) with no heap
    // allocation on our side.  The X server's atom table is global per-server and
    // persists until the server itself exits; xcb_disconnect (deferred above)
    // tears down the connection and the server frees all server-side resources.

    try events.setupSignalPipe();
    defer events.deinitSignalPipe();

    events.grabKeybindings();
    try window.init(alloc);
    defer window.deinit();

    // bar.init() asserts core.getState().config.bar.enabled; check here so a
    // config with bar disabled is always safe, regardless of how the binary was built.
    if (core.getState().config.bar.enabled) {
        bar.init() catch |err| {
            debug.err("Bar init failed: {}", .{err});
        };
    }
    defer if (core.getState().config.bar.enabled) bar.deinit();

    bar.updateTimerState();
    _ = xcb.xcb_flush(x.conn);
    debug.info("hana booted up successfully!", .{});

    try events.run();
    // When event loop exits, it must mean hana's shutting down
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
    // Pass null for both display and screen number: XCB reads $DISPLAY and
    // selects screen 0. The screen number parameter is a legacy X11 concept —
    // modern multi-monitor setups use a single unified screen via Xrandr/Xinerama.
    const conn = xcb.xcb_connect(null, null) orelse unreachable;

    if (xcb.xcb_connection_has_error(conn) != 0) {
        debug.err("X11 connection failed", .{});
        return error.X11ConnectionFailed;
    }

    const screen = xcb.xcb_setup_roots_iterator(xcb.xcb_get_setup(conn)).data orelse return error.X11ScreenFailed;

    // Claim SubstructureRedirectMask on the root window to become the WM.
    // The X server rejects this if another WM already holds it.
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
