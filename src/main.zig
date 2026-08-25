//! Main entry point for hana.
//! Sets up all subsystems and hands off to the event loop.

const std = @import("std");

const core = @import("core");
const xcb = core.xcb;
const utils = @import("utils");
const events = @import("events");
const signals = @import("signals");
const config = @import("config");
const types = @import("types");
const constants = @import("constants");
const scale = @import("scale");
const debug = @import("debug");
const build_options = @import("build_options");
const bar = if (build_options.has_bar) @import("bar") else null;
const input = @import("input");
const window = @import("window");
const actions = @import("actions");
const pipeline = @import("pipeline");

pub fn main() !void {
    const x = try connectToX();
    defer xcb.xcb_disconnect(x.conn);

    const alloc = std.heap.c_allocator;

    // Intern the atom cache before any module reads atoms: scale.detectDpi()
    // resolves RESOURCE_MANAGER through the cache, so it must be populated
    // first or Xft.dpi would never be read.
    try utils.initAtomCache(x.conn);

    core.dpi_info.store(scale.detectDpi(x.conn, x.screen), .release);

    input.setup(x.conn, x.screen, x.root);
    try input.initXkb(x.conn);
    defer input.deinitXkb();

    const loaded_config = try config.load(alloc, x.screen, input.getXkbState());

    // Heap-allocate config so core.State holds a pointer; this allows
    // atomic pointer-swap on reload instead of by-value copy aliasing.
    const config_ptr = try alloc.create(types.Config);
    errdefer alloc.destroy(config_ptr);
    config_ptr.* = loaded_config;

    // core.init() takes ownership of config_ptr; must run before any
    // core.getState() call.
    core.init(x.conn, x.screen, x.root, alloc, config_ptr);

    // Config.deinit tears the keybind_resolver down internally, before
    // freeing the keybindings whose Actions it points into; so a single
    // defer on the config pointer suffices (see KeybindResolver in types.zig).
    //
    // The guard matters: a config reload swaps cs.config and the reload path
    // (events.handleConfigReload) deinits the displaced boot config itself.
    // Without the identity check this defer would free it a second time at
    // shutdown — the GP fault seen in reload-then-quit runs.
    const initial_config = core.getState().config;
    defer if (core.getState().config == initial_config) initial_config.deinit(alloc);

    utils.advertiseEwmhSupport(x.conn, x.screen, x.root);

    try signals.setup();
    defer signals.deinit();

    events.grabKeybindings();
    try window.init(alloc);
    defer window.deinit();

    pipeline.init(alloc); // owns the model; the model path IS the path

    // Boot-time config seeding. Without this the config's layout kind,
    // variants, master count, and per-workspace overrides stay inert until
    // the first explicit reload. No reconcile here: nothing is managed yet,
    // so there is no X state to push.
    actions.seedParamsFromConfig();

    // D8: direct subsystem init (the plugin registry was deleted — only bar
    // ever registered hooks).
    if (build_options.has_bar) bar.init() catch |err| debug.err("bar init failed: {}", .{err});
    defer if (build_options.has_bar) bar.deinit();

    _ = xcb.xcb_flush(x.conn);
    debug.info("hana booted up successfully!", .{});

    try events.run();
    debug.info("Shutting down gracefully...", .{});
}

const X = struct {
    conn: core.Connection,
    screen: core.Screen,
    root: core.WindowId,
};

fn connectToX() !X {
    const conn = xcb.xcb_connect(null, null) orelse return error.X11ConnectionFailed;

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
        &[_]u32{constants.EventMasks.root_window},
    );
    if (xcb.xcb_request_check(conn, cookie)) |err| {
        debug.err("Another window manager is already running: {*}", .{err});
        std.c.free(err);
        return error.AnotherWMRunning;
    }

    return .{ .conn = conn, .screen = screen, .root = screen.*.root };
}
