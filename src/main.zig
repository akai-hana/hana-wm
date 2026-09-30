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

/// The longest captured diagnostic line `--check-config` can print without
/// truncating it; a longer one is clipped rather than wrapped, so the count is
/// never the thing a reader has to reconstruct.
const check_line_buf = 1024;

/// True when the process was asked to validate its config and stop. Checked
/// before ANY X11 work on purpose: a config check that needs a display (or
/// claims a window-manager role) is unusable from CI, which is the only place
/// it earns its keep.
fn checkConfigRequested(args: std.process.Args) bool {
    var it = std.process.Args.Iterator.init(args);
    _ = it.skip(); // argv[0]
    while (it.next()) |arg| {
        if (std.mem.eql(u8, arg, "--check-config")) return true;
    }
    return false;
}

fn runCheckConfig() !void {
    var diag: log.Collector = .{ .allocator = alloc };
    defer diag.deinit();
    try config.checkConfig(alloc, &diag);
    const n = diag.count();
    var buf: [check_line_buf]u8 = undefined;
    for (diag.items.items) |d| {
        // A diagnostic longer than the buffer is clipped with a marker rather
        // than silently cut, so a truncated line is never mistaken for a
        // complete one.
        const line = try log.Collector.line(d, &buf);
        std.debug.print("{s}{s}\n", .{ line, if (line.len == buf.len) "  [truncated]" else "" });
    }
    std.debug.print("hana --check-config: {d} diagnostic(s) in the loaded config\n", .{n});
    // Non-zero ONLY for warn/err: a clean load and a clean check agree, which
    // is what lets a CI job gate on this.
    std.process.exit(if (n == 0) 0 else 1);
}

pub fn main(init: std.process.Init) !void {
    if (checkConfigRequested(init.minimal.args)) try runCheckConfig();

    const x = try connectToX();
    defer x.deinit();

    // Intern the atom cache before any module reads atoms: scale.detectDpi()
    // resolves RESOURCE_MANAGER through the cache, so it must be populated
    // first or Xft.dpi would never be read.
    try atoms.initAtomCache(x.conn);

    input.setup(x.conn, x.screen);
    try input.initXkb(x.conn);
    defer input.deinitXkb();

    const loaded_config = try config.load(alloc);

    // DPI is resolved here, once, because it has two possible sources and the
    // winner is a config question: detection reads Xft.dpi and falls back to
    // a physical-size guess, so a nested-X or HiDPI panel the compositor has
    // not described yields a value that is merely plausible. A configured
    // [display] dpi overrides it. Resolving after `config.load` is what makes
    // the override possible; resolving before meant the config could not be
    // consulted, which is why the override had to live in main anyway.
    const dpi = if (loaded_config.dpi) |configured|
        configured
    else
        scale.detectDpi(x.conn, x.screen);

    // Heap-allocate config so core.State holds a pointer; this allows
    // atomic pointer-swap on reload instead of by-value copy aliasing.
    const config_ptr = try alloc.create(types.Config);
    config_ptr.* = loaded_config;

    // core.init() takes ownership of config_ptr; must run before any
    // core.getState() call.
    core.init(x.conn, x.screen, x.root, alloc, config_ptr, dpi);

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

    // Re-exec session hand-off (restart.execNext sets restart_env).
    if (restart.restorePathFromEnv()) |restore_path_z| {
        restore.adoptSession(std.mem.span(restore_path_z));
    }

    events.run();

    // This session's restore file is a hand-off record, and a graceful exit
    // is the one case where the NEXT boot must not adopt it: the XIDs it
    // names have already been given back, so the server may have recycled
    // them and the successor would adopt unrelated windows. (After a crash
    // or a re-exec the file is exactly what recovery needs, which is why
    // this runs only here.)
    if (restart.restorePathFromEnv()) |restore_path_z| {
        std.Io.Dir.deleteFileAbsolute(std.Options.debug_io, std.mem.span(restore_path_z)) catch |err| switch (err) {
            error.FileNotFound => {},
            else => log.warn("Could not remove restore file: {}", .{err}),
        };
    }
    log.info("Shutting down gracefully...", .{});
}

/// The X connection, OWNING. `deinit` encodes the has-error rule that every
/// call site used to have to remember: a connection that has errored was
/// already torn down by the server, and `xcb_disconnect` on it can crash
/// inside libxcb's teardown, while a LIVE connection must be disconnected or
/// the process leaks the socket (and, for a WM, the root grab survives until
/// the kernel reaps it). Both facts live in one method now.
const XSession = struct {
    conn: core.Connection,
    screen: core.Screen,
    root: core.WindowId,

    /// Disconnects a healthy connection; a no-op on an errored one.
    fn deinit(self: XSession) void {
        if (xcb.xcb_connection_has_error(self.conn) != 0) return;
        xcb.xcb_disconnect(self.conn);
    }
};

fn connectToX() !XSession {
    const conn = xcb.xcb_connect(null, null) orelse return error.X11ConnectionFailed;

    if (xcb.xcb_connection_has_error(conn) != 0) {
        log.err("X11 connection failed", .{});
        // Nothing to release: the error already tore the stream down, which is
        // why XSession.deinit skips errored connections too.
        return error.X11ConnectionFailed;
    }

    // From here the connection is LIVE, so every remaining exit must release
    // it. These two returns used to leak it: a null screen iterator, and a
    // failed WM-role claim (which is the common one -- another WM holding
    // SubstructureRedirect means we exit right here).
    errdefer xcb.xcb_disconnect(conn);

    const screen = xcb.xcb_setup_roots_iterator(
        xcb.xcb_get_setup(conn),
    ).data orelse return error.X11ScreenFailed;

    // Claim SubstructureRedirectMask on the root window to become the WM.
    try requests.claimWindowManagerRole(conn, screen.*.root);

    return .{ .conn = conn, .screen = screen, .root = screen.*.root };
}
