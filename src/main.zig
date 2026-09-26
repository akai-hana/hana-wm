//! Main entry point for hana.
//! Sets up all subsystems and hands off to the event loop.

const std = @import("std");

const core = @import("core");
const xcb = core.xcb;
const events = @import("events");
const signals = @import("signals");
const config = @import("config");
const types = @import("types");
const scale = @import("dpi");
const log = @import("log");
const build_options = @import("build_options");
// The optional chrome surface's boot lifecycle (init/deinit) is invoked
// through the core-owned `surfaces` composition root, never by importing the
// bar module here.
const surfaces = @import("surfaces").Surfaces;
const input = @import("input");

/// The process allocator. One binding: a second `std.heap.c_allocator` spelling
/// is a second place to change, and the two former sites disagreed about what
/// they were even naming.
const alloc = std.heap.c_allocator;
const window = @import("window");
const actions = @import("actions");
const pipeline = @import("pipeline");
const restart = @import("restart");
const persist = @import("persist");
const restore = @import("restore");
const focus = @import("focus");

const atoms = @import("atoms");
const requests = @import("requests");
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

    // Intern the atom cache before any module reads atoms: scale.detectDpi()
    // resolves RESOURCE_MANAGER through the cache, so it must be populated
    // first or Xft.dpi would never be read.
    try atoms.initAtomCache(x.conn);

    core.dpi_info = scale.detectDpi(x.conn, x.screen);

    input.setup(x.conn, x.screen);
    try input.initXkb(x.conn);
    defer input.deinitXkb();

    const loaded_config = try config.load(alloc);

    // Heap-allocate config so core.State holds a pointer; this allows
    // atomic pointer-swap on reload instead of by-value copy aliasing.
    const config_ptr = try alloc.create(types.Config);
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

    // Drop the Config internals and the heap box core owns. No identity guard:
    // a reload goes through core.replaceOwnedConfig, which releases the
    // displaced box there and leaves the new one to this defer, so exactly one
    // call frees each box. (The guard this replaces existed because the reload
    // path used to free the box itself while main also held a reference to it
    // -- the GP fault seen in reload-then-quit runs.)
    defer core.deinitOwnedConfig();
    // Registered AFTER the config-deinit defer, so (LIFO) the resolver's map
    // is released before the keybindings its entries borrow are freed.
    defer input.deinitKeybinds();

    requests.advertiseEwmhSupport(x.conn, x.screen, x.root);

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
    surfaces.init() catch |err| log.err("surface init failed: {}", .{err});
    defer surfaces.deinit();

    requests.flush(x.conn);
    log.info("hana booted up successfully!", .{});

    // Re-exec session hand-off (restart.execNext sets HANA_RESTORE).
    if (std.c.getenv("HANA_RESTORE")) |restore_path_z| {
        restore.adoptSession(std.mem.span(restore_path_z));
    }

    events.run();

    // This session's restore file is a hand-off record, and a graceful exit
    // is the one case where the NEXT boot must not adopt it: the XIDs it
    // names have already been given back, so the server may have recycled
    // them and the successor would adopt unrelated windows. (After a crash
    // or a re-exec the file is exactly what recovery needs, which is why
    // this runs only here.)
    if (std.c.getenv("HANA_RESTORE")) |restore_path_z| {
        std.Io.Dir.deleteFileAbsolute(std.Options.debug_io, std.mem.span(restore_path_z)) catch |err| switch (err) {
            error.FileNotFound => {},
            else => log.warn("Could not remove restore file: {}", .{err}),
        };
    }
    log.info("Shutting down gracefully...", .{});
}

const XSession = struct {
    conn: core.Connection,
    screen: core.Screen,
    root: core.WindowId,
};

fn connectToX() !XSession {
    const conn = xcb.xcb_connect(null, null) orelse return error.X11ConnectionFailed;

    if (xcb.xcb_connection_has_error(conn) != 0) {
        log.err("X11 connection failed", .{});
        return error.X11ConnectionFailed;
    }

    const screen = xcb.xcb_setup_roots_iterator(
        xcb.xcb_get_setup(conn),
    ).data orelse return error.X11ScreenFailed;

    // Claim SubstructureRedirectMask on the root window to become the WM.
    try requests.claimWindowManagerRole(conn, screen.*.root);

    return .{ .conn = conn, .screen = screen, .root = screen.*.root };
}
