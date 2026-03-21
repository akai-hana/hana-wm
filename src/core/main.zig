//! hana's entry point and main loop.
//!
//! Global WM state (conn, screen, root, allocator, config, dpi_info) lives in
//! core.zig and is initialized here at startup. Modules import core directly.

// Zig stdlib
const std = @import("std");

// core/
const core   = @import("core");
const utils  = @import("utils");
const events = @import("events");
const scale  = @import("scale");
const config = @import("config");
const xcb    = core.xcb;

// input/
const input = @import("input");

// window/
const window     = @import("window");
const focus      = @import("focus");
const fullscreen = @import("fullscreen");
const minimize   = @import("minimize");
const workspaces = @import("workspaces");

// tiling/
const build_options = @import("build_options");
const tiling = if (build_options.has_tiling) @import("tiling") else struct {};

// bar/
const bar    = @import("bar");
const prompt = @import("prompt");

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
    core.dpi_info = scale.detect(x.conn, x.screen);

    input.setup(x.conn, x.screen, x.root);
    try input.initXkb(x.conn);
    defer input.deinitXkb();

    core.config = try config.load(core.alloc, x.screen, input.getXkbState());
    defer core.config.deinit(core.alloc);

    try initGlobalState(x.conn, core.alloc);
    // Defers run in LIFO order: core.config.deinit() must run before deinitGlobalState().
    defer deinitGlobalState();

    try events.setupSignalPipe();
    defer events.deinitSignalPipe();

    try events.grabKeybindings();
    try initModules();
    defer deinitModules();

    initBar();
    defer bar.deinit();

    bar.updateTimerState();
    _ = xcb.xcb_flush(core.conn);
    debug.info("hana booted up successfully!", .{});

    try events.run();
    debug.info("Shutting down gracefully...", .{});
}

/// Event mask registered on the root window at startup.
/// SubstructureRedirect is what makes hana the WM: the X server sends all
/// MapRequest / ConfigureRequest events here instead of honoring them directly.
const ROOT_WINDOW_EVENT_MASK: u32 =
    xcb.XCB_EVENT_MASK_SUBSTRUCTURE_REDIRECT |
    xcb.XCB_EVENT_MASK_SUBSTRUCTURE_NOTIFY   |
    xcb.XCB_EVENT_MASK_KEY_PRESS             |
    xcb.XCB_EVENT_MASK_BUTTON_PRESS          |
    xcb.XCB_EVENT_MASK_ENTER_WINDOW          |
    xcb.XCB_EVENT_MASK_LEAVE_WINDOW          |
    xcb.XCB_EVENT_MASK_PROPERTY_CHANGE;

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
        &[_]u32{ROOT_WINDOW_EVENT_MASK},
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

/// Initializes all WM modules that require explicit lifecycle management.
fn initModules() !void {
    fullscreen.init();
    tiling.init();      // must precede workspaces.init(): workspaces.init() calls tiling.getState()
    workspaces.init();
    window.init();      // populates atom cache required by handleMapRequest
    try minimize.init();
    try prompt.init(core.alloc, core.conn);
}

/// Tears down all WM modules in reverse init order.
fn deinitModules() void {
    // minimize state is owned by WM.deinit — no separate deinit here.
    prompt.deinit();
    workspaces.deinit();
    tiling.deinit();
    fullscreen.deinit();
}

/// Initializes global WM state: X atom cache, focus property cache, and focus tracking.
fn initGlobalState(conn_: *xcb.xcb_connection_t, alloc: std.mem.Allocator) !void {
    try utils.initAtomCache(conn_);   // Intern frequently used X atoms
    utils.initInputModelCache();      // Build per-window focus property cache (no allocator — static array)
    focus.init(alloc);
}

/// Tears down global WM state initialized by initGlobalState.
fn deinitGlobalState() void {
    utils.deinitInputModelCache();
    focus.deinit();
}
