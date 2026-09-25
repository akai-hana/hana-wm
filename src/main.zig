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
const masks = @import("masks");
const scale = @import("scale");
const debug = @import("debug");
const build_options = @import("build_options");
// The optional chrome surface's boot lifecycle (init/deinit) is invoked
// through the core-owned `surfaces` composition root, never by importing the
// bar module here.
const surfaces = @import("surfaces").Surfaces;
const input = @import("input");
const window = @import("window");
const actions = @import("actions");
const pipeline = @import("pipeline");
const restart = @import("restart");
const persist = @import("persist");
const focus = @import("focus");

// Always keep Zig's crash handler armed, even though this project defaults to
// the release profile (ReleaseFast strips DWARF and disables runtime safety,
// so an uncaught SIGSEGV/SIGBUS would otherwise abort with zero trace, the
// "silent death" misdiagnosed as a hang). With the handler, the fault address
// lands in ~/hana-crash.log (and full symbolized stacks in Debug builds).
pub const std_options: std.Options = .{
    .enable_segfault_handler = true,
    .allow_stack_tracing = true,
};

pub fn main() !void {
    const x = try connectToX();
    // Only disconnect when the connection never errored. A dropped X
    // server has already torn the stream down; xcb_disconnect on an errored
    // connection can crash inside libxcb's teardown.
    defer if (xcb.xcb_connection_has_error(x.conn) == 0) xcb.xcb_disconnect(x.conn);

    const alloc = std.heap.c_allocator;

    // Intern the atom cache before any module reads atoms: scale.detectDpi()
    // resolves RESOURCE_MANAGER through the cache, so it must be populated
    // first or Xft.dpi would never be read.
    try utils.initAtomCache(x.conn);

    core.dpi_info = scale.detectDpi(x.conn, x.screen);

    input.setup(x.conn, x.screen);
    try input.initXkb(x.conn);
    defer input.deinitXkb();

    const loaded_config = try config.load(alloc);

    // Heap-allocate config so core.State holds a pointer; this allows
    // atomic pointer-swap on reload instead of by-value copy aliasing.
    const config_ptr = try alloc.create(types.Config);
    errdefer alloc.destroy(config_ptr);
    config_ptr.* = loaded_config;

    // core.init() takes ownership of config_ptr; must run before any
    // core.getState() call.
    core.init(x.conn, x.screen, x.root, alloc, config_ptr);

    // Build the key dispatch map now that both the live config and the XKB
    // state exist. Owned by the input layer (see input/keybind.zig); rebuilt
    // on every reload. Its entries borrow Actions from the live config.
    input.buildKeybinds(config_ptr.keybindings.items);

    // Arm the unified reload: resolve the exec path before any reload/reexec
    // request can arrive (restart.init).
    restart.init();

    // Drop the Config internals and the heap box core.init() owns; the keybind
    // resolver (input-owned) is deinited separately above. The identity guard
    // matters: a config reload swaps cs.config and the reload path
    // (events.handleConfigReload) deinits AND destroys the displaced boot
    // config itself, so this safely no-ops after a swap -- without it the
    // defer would free the box a second time at shutdown, the GP fault seen in
    // reload-then-quit runs.
    const initial_config = core.getState().config;
    defer if (core.getState().config == initial_config) {
        initial_config.deinit(alloc);
        alloc.destroy(initial_config);
    };
    // Registered AFTER the config-deinit defer, so (LIFO) the resolver's map
    // is released before the keybindings its entries borrow are freed.
    defer input.deinitKeybinds();

    utils.advertiseEwmhSupport(x.conn, x.screen, x.root);

    try signals.setup();
    defer signals.deinit();

    events.grabKeybindings();
    try window.init(alloc);
    defer window.deinit();

    pipeline.init(); // owns the model; must run before seedParamsFromConfig/model()

    // Boot-time config seeding. Without this the config's layout kind,
    // variants, master count, and per-workspace overrides stay inert until
    // the first explicit reload. No reconcile here: nothing is managed yet,
    // so there is no X state to push.
    actions.seedParamsFromConfig();

    // Direct subsystem init: only the bar ever registered hooks (no plugin
    // registry anymore).
    if (build_options.has_bar) surfaces.init() catch |err| debug.err("bar init failed: {}", .{err});
    defer if (build_options.has_bar) surfaces.deinit();

    _ = xcb.xcb_flush(x.conn);
    debug.info("hana booted up successfully!", .{});

    // Re-exec session hand-off (restart.execNext sets HANA_RESTORE).
    if (std.c.getenv("HANA_RESTORE")) |restore_path_z| {
        adoptRestoredSession(std.mem.span(restore_path_z));
    }

    try events.run();
    debug.info("Shutting down gracefully...", .{});
}

/// Re-exec session hand-off (restart.execNext sets HANA_RESTORE before execv;
/// a plain boot has no such var). The session's windows survive a re-exec
/// because hana never reparents: clients are direct root children, so the
/// successor adopts them, re-applies the persisted model level, then runs ONE
/// reconcile that places everything exactly as it was. Called after bar init
/// so the bar-aware workarea is live.
fn adoptRestoredSession(restore_path: []const u8) void {
    const alloc = std.heap.c_allocator;
    if (persist.loadToGlobal(alloc, restore_path)) {
        const n = window.adoptRootWindows() catch |err| blk: {
            debug.err("Window adoption failed: {}", .{err});
            break :blk 0;
        };
        if (n > 0) {
            actions.applyRestoredLevel();
            // Restore X input focus on the session's focused window;
            // the mapRequest path uses the same focus-after-geometry
            // entry (the adopted window is already mapped).
            if (pipeline.model().focused) |focused| {
                const ft = focus.prepareFocus(focused, .window_spawn);
                pipeline.reconcileGrabFocus(.{}, ft, .after, null);
            } else {
                pipeline.reconcileUnderGrabNow(.{});
            }
        }
    }
}

const XSession = struct {
    conn: core.Connection,
    screen: core.Screen,
    root: core.WindowId,
};

fn connectToX() !XSession {
    const conn = xcb.xcb_connect(null, null) orelse return error.X11ConnectionFailed;

    if (xcb.xcb_connection_has_error(conn) != 0) {
        debug.err("X11 connection failed", .{});
        return error.X11ConnectionFailed;
    }

    const screen = xcb.xcb_setup_roots_iterator(
        xcb.xcb_get_setup(conn),
    ).data orelse return error.X11ScreenFailed;

    // Claim SubstructureRedirectMask on the root window to become the WM;
    // the X server rejects this if another WM already holds it.
    const cookie = xcb.xcb_change_window_attributes_checked(
        conn,
        screen.*.root,
        xcb.XCB_CW_EVENT_MASK,
        &[_]u32{masks.EventMasks.root_window},
    );
    if (xcb.xcb_request_check(conn, cookie)) |err| {
        debug.err(
            "Another window manager is already running (error_code={d}, type={d})",
            .{ err.*.error_code, err.*.response_type },
        );
        std.c.free(err);
        return error.AnotherWMRunning;
    }

    return .{ .conn = conn, .screen = screen, .root = screen.*.root };
}
