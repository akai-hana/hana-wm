//! Main entry point for hana.
//! Boots the window manager: either validates config via `--check-config`
//! (no X11), or connects to X, claims the WM role, initializes subsystems,
//! and enters the event loop.

const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");

const core = @import("core");
const xcb = core.xcb;
const events = @import("events");
const config = @import("config");
const diagnostics = @import("diagnostics");
const composed = @import("composed");
// The dpi module under the local name `scale`, so the resolved value below
// can be called `dpi` without shadowing the module it came from.
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
const window = @import("window");
// The model_config module under the local name `seed` (its role here is
// boot-time seeding); its log scope stays `.model_config`.
const seed = @import("model_config");
const pipeline = @import("pipeline");
const process = @import("process");
const admission = @import("admission");
const session = @import("session");
const atoms = @import("atoms");
const requests = @import("requests");

/// The process allocator. One binding: a second `std.heap.c_allocator` spelling
/// is a second place to change, and two sites can disagree about what they
/// are even naming.
const alloc = std.heap.c_allocator;
// Call sites log through this scope; the sink is `logFn` below.
const log = std.log.scoped(.main);
// Build-mode policy: a Debug build carries every diagnostic facility and a
// release build carries none of them.
//
//   .debug level + segfault handler + stack traces  -> Debug
//   .err only, no handler, no stack traces          -> every release mode
//
// The win is ~35s of LLVM optimize time and ~0.9 MB of ReleaseFast binary:
// warn/info formatting (177 call sites) and std's DWARF/ELF symbol lookup
// (2.1 MB of sort kernels) dominate both. The cost is that a release crash
// aborts with no trace, and a release build cannot SEE config warnings --
// which is why `--check-config` refuses to answer there instead of claiming a
// config is clean.
const log_warn_available = builtin.mode == .Debug;

/// Config-family scopes whose warn sites a `-Dconfig-warn` release build
/// retains (D1). Debug already logs everything via `log_level = .debug`, so
/// the map stays empty there; the shipped default release binary is
/// byte-identical to the pre-flag behavior because `config_warn` defaults
/// off (the always-on experiment cost +145 KB, see REFACTOR-PLAN.md §3).
/// These scopes only run during config load/reload/parse, so the retained
/// sites have zero hot-path cost.
const config_warn_scopes: []const std.log.ScopeLevel = if (build_options.config_warn and !log_warn_available) &.{
    .{ .scope = .config, .level = .warn },
    .{ .scope = .parser, .level = .warn },
    .{ .scope = .document, .level = .warn },
    .{ .scope = .knob, .level = .warn },
    .{ .scope = .color, .level = .warn },
    .{ .scope = .discover, .level = .warn },
    .{ .scope = .fallback, .level = .warn },
    .{ .scope = .binds, .level = .warn },
    .{ .scope = .action_names, .level = .warn },
    .{ .scope = .reload, .level = .warn },
    .{ .scope = .snapshot, .level = .warn },
    .{ .scope = .model_config, .level = .warn },
} else &.{};

pub const std_options: std.Options = .{
    .log_level = if (log_warn_available) .debug else .err,
    .log_scope_levels = config_warn_scopes,
    .enable_segfault_handler = log_warn_available,
    .allow_stack_tracing = log_warn_available,
    .signal_stack_size = if (log_warn_available) (1 << 18) else null,
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
    // Outside Debug (and outside a `-Dconfig-warn` build), `log_level`
    // comptime-elides every warn site, so the bag below would always be empty
    // and this would exit 0 on a config the WM would reject. Refuse instead:
    // a check that cannot check must not look clean. Exit 2 rather than 1 so
    // a caller can tell "bad config" from "cannot validate". A `-Dconfig-warn`
    // build retains the config-family warn scopes, so the diagnostics ARE
    // visible there and the check proceeds (D1).
    if (comptime !log_warn_available and !build_options.config_warn) {
        std.debug.print(
            "hana --check-config: config diagnostics are compiled out of this build ({s}); rebuild with -Doptimize=Debug or -Dconfig-warn to validate\n",
            .{@tagName(builtin.mode)},
        );
        std.process.exit(2);
    }
    var diag: diagnostics.Diagnostics = .{ .allocator = alloc };
    defer diag.deinit();
    // An error here means the check could not LOAD a config (I/O, OOM), not
    // that the config is bad: exit 2 -- the same "cannot validate" code the
    // compiled-out-diagnostics guard above uses -- so a caller can tell the
    // two failures apart instead of seeing one exit 1 for both.
    config.checkConfig(alloc, &diag) catch |err| {
        std.debug.print("hana --check-config: could not load config: {}\n", .{err});
        std.process.exit(2);
    };
    const n = diag.count();
    var buf: [check_line_buf]u8 = undefined;
    for (diag.items.items) |d| {
        // A diagnostic longer than the buffer is clipped with a marker rather
        // than silently cut, so a truncated line is never mistaken for a
        // complete one. `line` reports the clip via `truncated` (bufPrint
        // itself REFUSES to truncate, so the clip is hand-rolled there).
        const line = diagnostics.Diagnostics.line(d, &buf);
        std.debug.print("{s}{s}\n", .{ line.text, if (line.truncated) "  [truncated]" else "" });
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

    var loaded_config = try config.load(alloc);

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
    const config_ptr = blk: {
        const p = alloc.create(composed.Config) catch |err| {
            // OOM at boot: the loaded config's internals would leak with the
            // box that never came to be, so release them before propagating.
            loaded_config.deinit(alloc);
            return err;
        };
        // Nothing fallible until core.init below takes ownership, but a
        // future try would otherwise leak both the box and the config it is
        // about to hold. Scoped to this block, so it is cancelled the moment
        // the block completes and can never fire after the ownership
        // transfer (which would double-free against core.deinitOwnedConfig).
        errdefer {
            p.destroy();
            loaded_config.deinit(alloc);
        }
        p.* = loaded_config;
        break :blk p;
    };

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
    // request can arrive (process.init). Infallible by contract (returns
    // void; a failed /proc read only disables re-exec and warns), so there
    // is nothing for a defer to undo. The one allocation it makes -- the
    // dupeZ of the exec path -- is process-lifetime BY DESIGN and never
    // freed, so the unpaired init is deliberate: process.deinit below pairs
    // with process.setup's signal pipe alone.
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
    // A failed init is logged, not fatal, and the unconditional defer below
    // is safe on BOTH paths: the surface's deinit is written to tolerate a
    // half-completed init (its state slot is optional, so a createBar
    // failure leaves nothing to tear down, and the usable-area claim release
    // is null-safe).
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
/// reaps it). Both facts live in `disconnectIfHealthy` below.
const XSession = struct {
    conn: core.Connection,
    screen: core.Screen,
    root: core.WindowId,

    /// Disconnects a healthy connection; a no-op on an errored one.
    fn deinit(self: XSession) void {
        disconnectIfHealthy(self.conn);
    }
};

/// Disconnects a healthy connection; a no-op on an errored one. Shared by
/// `XSession.deinit` and `connectToX`'s errdefer: a request can fail BECAUSE
/// the connection died mid-flight (the checked request in
/// `claimWindowManagerRole` reports connection failures too, not just
/// another WM's BadAccess), so the errdefer needs the same guard the
/// success-path teardown has.
fn disconnectIfHealthy(conn: core.Connection) void {
    if (xcb.xcb_connection_has_error(conn) != 0) return;
    xcb.xcb_disconnect(conn);
}

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
    // SubstructureRedirect means we exit right here). The guard inside
    // matters for the latter: the claim's checked request can fail because
    // the CONNECTION errored mid-flight, and disconnecting that would be
    // the crash XSession.deinit's has-error rule exists to prevent.
    errdefer disconnectIfHealthy(conn);

    const screen = xcb.xcb_setup_roots_iterator(
        xcb.xcb_get_setup(conn),
    ).data orelse return error.X11ScreenFailed;

    // Claim SubstructureRedirectMask on the root window to become the WM.
    try requests.claimWindowManagerRole(conn, screen.*.root);

    return .{ .conn = conn, .screen = screen, .root = screen.*.root };
}
