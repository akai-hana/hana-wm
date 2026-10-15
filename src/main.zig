//! Main entry point for hana.
//! Boots the window manager: either validates config via `--check-config`
//! (no X11), or connects to X, claims the WM role, initializes subsystems,
//! and enters the event loop.

const std = @import("std");

const core = @import("core");
const xcb = core.xcb;
const events = @import("events");
const config = @import("config");
const diagnostics = @import("diagnostics");
const types = @import("types");
const composed = @import("composed");
const scale = @import("dpi");
const hz = @import("hz");
// The optional chrome surface's boot lifecycle (init/deinit) is invoked
// through the core-owned `surfaces` composition root, never by importing the
// bar module here.
const surfaces = @import("surfaces").Surfaces;
// The input subsystem has no facade here: the composition root names
// exactly the three pieces it sequences at boot (XKB lifecycle, bind
// compilation + root grabs, cursor theming).
const xkb = @import("xkb");
const keybinds = @import("keybinds");
const cursor = @import("cursor");

/// The process allocator. One binding: a second `std.heap.c_allocator` spelling
/// is a second place to change, and two sites can disagree about what they
/// are even naming.
const alloc = std.heap.c_allocator;
// Call sites log through this scope; the sink is `logFn` below.
const log = std.log.scoped(.main);
const window = @import("window");
const seed = @import("model_config");
const pipeline = @import("pipeline");
const process = @import("process");
const admission = @import("admission");
const session = @import("session");
const focus = @import("focus");

const atoms = @import("atoms");
const requests = @import("requests");
// Crash machinery is off by default: both flags cost ~12s of LLVM optimize
// time and ~14.5% of the release binary, because they pull std's DWARF/ELF
// symbol lookup (2.1 MB of sort kernels) into the link. The tradeoff is that
// an uncaught SIGSEGV/SIGBUS in a ReleaseFast build aborts with no trace —
// diagnose those with `-Doptimize=Debug`, which keeps symbolized stacks.
// Flip both to `true` to restore ~/hana-crash.log fault reports.
pub const std_options: std.Options = .{
    .enable_segfault_handler = false,
    .allow_stack_tracing = false,
    .logFn = logFn,
};

/// The process-wide log sink. Captures warn/err into the check-config bag
/// (no-op unless `--check-config` installed one), then writes the same
/// "[module] message" line the old hand-rolled wrapper produced. The scope is
/// passed as `.default` with the tag baked into the format because
/// `defaultLog` prints its own "(scope): " infix for non-default scopes,
/// which would double up with the bracketed tag.
fn logFn(
    comptime message_level: std.log.Level,
    comptime scope: @EnumLiteral(),
    comptime format: []const u8,
    args: anytype,
) void {
    diagnostics.capture(message_level, scope, format, args);
    std.log.defaultLog(message_level, .default, "[{t}] " ++ format, .{scope} ++ args);
}

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
    var diag: diagnostics.Diagnostics = .{ .allocator = alloc };
    defer diag.deinit();
    try config.checkConfig(alloc, &diag);
    const n = diag.count();
    var buf: [check_line_buf]u8 = undefined;
    for (diag.items.items) |d| {
        // A diagnostic longer than the buffer is clipped with a marker rather
        // than silently cut, so a truncated line is never mistaken for a
        // complete one.
        const line = try diagnostics.Diagnostics.line(d, &buf);
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

    try xkb.initXkb(x.conn);
    defer xkb.deinitXkb();

    const loaded_config = try config.load(alloc);

    // DPI is resolved here, once, because it has two possible sources and the
    // winner is a config question: detection reads Xft.dpi and falls back to
    // a physical-size guess, so a nested-X or HiDPI panel the compositor has
    // not described yields a value that is merely plausible. A configured
    // [display] dpi overrides it. The override lives here because it needs
    // the loaded config: resolution must come after `config.load`, and
    // `scale.detectDpi` has no config to consult.
    const dpi = if (loaded_config.core.dpi) |configured|
        configured
    else
        scale.detectDpi(x.conn, x.screen);

    // Heap-allocate config so core.State holds a pointer; this allows
    // atomic pointer-swap on reload instead of by-value copy aliasing.
    const config_ptr = try alloc.create(composed.Config);
    config_ptr.* = loaded_config;

    // core.init() takes ownership of config_ptr; must run before any
    // core.getState() call.
    core.init(x.conn, x.screen, x.root, alloc, config_ptr, dpi);

    // Arm refresh-rate detection once at boot: a display feature (the
    // rate serves bar render pacing and the floating drag throttle),
    // idempotent, and it needs the root window core.init just published.
    hz.ensureRefreshRateDetected(x.conn);

    // Mouse grabs and the cursor theme both read the live config (the bind
    // table and the theme name), so both run only after core.init above has
    // published the state: any earlier, getState() panics ("called before
    // init()"). Placement also keeps the input layer's own order reading
    // setup-then-buildKeybinds.
    cursor.setup(x.conn, x.screen);
    keybinds.grabMouseButtons();

    // Build the key dispatch map now that both the live config and the XKB
    // state exist. Owned by core/input/keybinds.zig; rebuilt on every
    // reload. Its entries borrow Actions from the live config.
    keybinds.buildKeybinds(config_ptr.core.keybindings.items);

    // Arm the unified reload: resolve the exec path before any reload/reexec
    // request can arrive (process.init).
    process.init();

    // Drop the Config internals and the heap box core owns. No identity guard:
    // a reload goes through core.replaceOwnedConfig, which releases the
    // displaced box there and leaves the new one to this defer, so exactly one
    // call frees each box.
    defer core.deinitOwnedConfig();
    // Registered AFTER the config-deinit defer, so (LIFO) the resolver's map
    // is released before the keybindings its entries borrow are freed.
    defer keybinds.deinitKeybinds();

    requests.advertiseEwmhSupport(x.conn, x.screen, x.root);

    try process.setup();
    defer process.deinit();

    keybinds.grabKeybindings(keybinds.resolvedKeybinds());
    try window.init(alloc);
    defer window.deinit();

    pipeline.init(); // owns the model; must run before seedParamsFromConfig/state()

    // Boot-time config seeding. Without this the config's layout kind,
    // variants, master count, and per-workspace overrides stay inert until
    // the first explicit reload. No reconcile here: nothing is managed yet,
    // so there is no X state to push.
    seed.seedParamsFromConfig();

    // Direct subsystem init: surfaces is the composition root for chrome;
    // window/tiling/bar hooks dispatch through the build-generated registries.
    surfaces.init() catch |err| log.err("surface init failed: {}", .{err});
    defer surfaces.deinit();

    requests.flush(x.conn);
    log.info("hana booted up successfully!", .{});

    // Re-exec session hand-off (process.execNext sets restore_env). The env
    // var is the ONLY adoption gate: execNext sets it alongside a file it has
    // just written, so an env-gated boot always reads its own predecessor's
    // record. A cold boot (no env) adopts nothing, and discards a leftover
    // record from a session that crashed instead of exiting cleanly. Read
    // ONCE: the same record drives the adoption below and the retirement at
    // the end, and nothing in this process writes restore_env (execNext's
    // setenv runs in the predecessor, and is noreturn here anyway).
    const restore_path_z = process.restorePathFromEnv();
    if (restore_path_z) |path_z| {
        admission.adoptSession(std.mem.span(path_z));
    } else {
        session.discardOrphan(alloc);
    }

    events.run();

    // Retire this session's restore file. It names the windows we are about
    // to give back, so it must not outlive the session: the server may recycle
    // those XIDs the moment we release them, and a record pointing at
    // unrelated windows is worse than no record. Adoption is env-gated (above),
    // so nothing reads this file after this exit -- delete it as dead state;
    // a later cold boot would find it and discard it as an orphan anyway.
    if (restore_path_z) |path_z| {
        std.Io.Dir.deleteFileAbsolute(std.Options.debug_io, std.mem.span(path_z)) catch |err| switch (err) {
            error.FileNotFound => {},
            else => log.warn("Could not remove restore file: {}", .{err}),
        };
    }
    log.info("Shutting down gracefully...", .{});
}

/// The X connection, OWNING. `deinit` encodes the has-error rule so no call
/// site has to remember it: a connection that has errored was already torn
/// down by the server, and `xcb_disconnect` on it can crash inside libxcb's
/// teardown, while a LIVE connection must be disconnected or the process
/// leaks the socket (and, for a WM, the root grab survives until the kernel
/// reaps it). Both facts live in one method.
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
    // it, including the two below: a null screen iterator, and a failed
    // WM-role claim (which is the common one -- another WM holding
    // SubstructureRedirect means we exit right here).
    errdefer xcb.xcb_disconnect(conn);

    const screen = xcb.xcb_setup_roots_iterator(
        xcb.xcb_get_setup(conn),
    ).data orelse return error.X11ScreenFailed;

    // Claim SubstructureRedirectMask on the root window to become the WM.
    try requests.claimWindowManagerRole(conn, screen.*.root);

    return .{ .conn = conn, .screen = screen, .root = screen.*.root };
}
