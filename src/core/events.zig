//! X event dispatch and main event loop
//! Handles X events, OS signals, and config reload, driving the WM's main loop.

const std   = @import("std");
const build = @import("build_options");

const core      = @import("core");
    const xcb   = core.xcb;
const utils     = @import("utils");
const constants = @import("constants");
const types     = @import("types");

const debug  = @import("debug");
const config = @import("config");
const input  = @import("input");
const window = @import("window");
const focus  = @import("focus");

const tiling = if (build.has_tiling) @import("tiling");
const bar    = if (build.has_bar) @import("bar");
const prompt = if (build.has_prompt and build.has_bar) @import("prompt");

// Indices into the poll fd array.
const FD_XCB    = 0;
const FD_SIGNAL = 1;

// Aliases to canonical definitions in constants.zig.
const EVENT_DISPATCH_TABLE = constants.Limits.EVENT_DISPATCH_TABLE;
const MAX_KEYBIND_COOKIES  = constants.Limits.MAX_KEYBIND_COOKIES;
const LOCK_MODIFIERS       = constants.LOCK_MODIFIERS;

// Self-pipe for portable signal delivery.
// Signal handlers write to [1]; the event loop polls [0].
var signal_pipe: [2]std.posix.fd_t = .{ -1, -1 };

// Dispatch table

const EventHandler = *const fn (event: *anyopaque) void;

inline fn asHandler(comptime f: anytype) EventHandler {
    return @ptrCast(&f);
}

/// Fans out PropertyNotify to both bar (title) and window (WM_PROTOCOLS cache).
fn handlePropertyNotify(event: *anyopaque) void {
    const e: *xcb.xcb_property_notify_event_t = @ptrCast(@alignCast(event));
    if (build.has_bar) bar.handlePropertyNotify(e);
    window.handlePropertyNotify(e);
}

/// O(1) dispatch via a comptime-built table indexed by XCB event type (low 7 bits).
const dispatch_table = blk: {
    var table = [_]?EventHandler{null} ** EVENT_DISPATCH_TABLE;

    table[xcb.XCB_ENTER_NOTIFY] = asHandler(window.handleEnterNotify);
    table[xcb.XCB_LEAVE_NOTIFY] = asHandler(window.handleLeaveNotify);

    table[xcb.XCB_MAP_REQUEST]       = asHandler(window.handleMapRequest);
    table[xcb.XCB_CONFIGURE_REQUEST] = asHandler(window.handleConfigureRequest);
    table[xcb.XCB_UNMAP_NOTIFY]      = asHandler(window.handleUnmapNotify);
    table[xcb.XCB_DESTROY_NOTIFY]    = asHandler(window.handleDestroyNotify);
    table[xcb.XCB_CLIENT_MESSAGE]    = asHandler(window.handleClientMessage);

    table[xcb.XCB_KEY_PRESS]       = asHandler(input.handleKeyPress);
    table[xcb.XCB_BUTTON_PRESS]    = asHandler(input.handleButtonPress);
    table[xcb.XCB_BUTTON_RELEASE]  = asHandler(input.handleButtonRelease);
    table[xcb.XCB_MOTION_NOTIFY]   = asHandler(input.handleMotionNotify);
    table[xcb.XCB_FOCUS_IN]        = asHandler(focus.handleFocusIn);
    table[xcb.XCB_PROPERTY_NOTIFY] = asHandler(handlePropertyNotify);

    if (build.has_bar) table[xcb.XCB_EXPOSE] = asHandler(bar.handleExpose);

    break :blk table;
};

pub fn dispatch(event_type: u8, event: *anyopaque) void {
    const idx = event_type & 0x7F; // strip XCB synthetic-event bit
    if (dispatch_table[idx]) |handler| handler(event);
}

// Signal handling

/// Converts any signal value — enum or integer — to its raw u8 number.
inline fn sigToU8(sig: anytype) u8 {
    return switch (@typeInfo(@TypeOf(sig))) {
        .@"enum" => @intCast(@intFromEnum(sig)),
        else     => @intCast(sig),
    };
}

/// Async-signal-safe handler: writes the signal number as a byte to the pipe.
/// sigToU8 accepts the SIG enum used by Zig master's Sigaction signature.
fn signalHandler(signo: std.os.linux.SIG) callconv(.c) void {
    _ = std.os.linux.write(signal_pipe[1], &[_]u8{sigToU8(signo)}, 1);
}

/// Creates a pipe with O_NONBLOCK | O_CLOEXEC on both ends via pipe2(2).
fn createPipe() ![2]std.posix.fd_t {
    var fds: [2]std.posix.fd_t = undefined;
    const flags = std.os.linux.O{ .CLOEXEC = true, .NONBLOCK = true };
    switch (std.posix.errno(std.os.linux.pipe2(&fds, flags))) {
        .SUCCESS => {},
        .MFILE   => return error.ProcessFdQuotaExceeded,
        .NFILE   => return error.SystemFdQuotaExceeded,
        else     => |err| return std.posix.unexpectedErrno(err),
    }
    return fds;
}

/// Creates the signal self-pipe and installs handlers for SIGHUP/SIGTERM/SIGINT/SIGCHLD.
pub fn setupSignalPipe() !void {
    signal_pipe = try createPipe();

    const sa: std.posix.Sigaction = .{
        .handler = .{ .handler = signalHandler },
        .mask    = std.posix.sigemptyset(),
        .flags   = std.posix.SA.RESTART,
    };

    std.posix.sigaction(std.posix.SIG.HUP,  &sa, null);
    std.posix.sigaction(std.posix.SIG.TERM, &sa, null);
    std.posix.sigaction(std.posix.SIG.INT,  &sa, null);
    // SIGCHLD: fired when an intermediate child exits after the double-fork spawn.
    // The handler writes the signal byte to the self-pipe; dispatchSignal then
    // calls reapPendingChildren() (waitpid WNOHANG) and drainPendingSpawns().
    std.posix.sigaction(std.posix.SIG.CHLD, &sa, null);
}

/// Closes both ends of the signal pipe.
pub fn deinitSignalPipe() void {
    for (&signal_pipe) |*fd| {
        if (fd.* == -1) continue;
        _ = std.os.linux.close(fd.*);
        fd.* = -1;
    }
}

/// Dispatches a single signal byte to the appropriate handler.
inline fn dispatchSignal(byte: u8) void {
    switch (byte) {
        sigToU8(std.posix.SIG.HUP)  => utils.reload(),
        sigToU8(std.posix.SIG.TERM),
        sigToU8(std.posix.SIG.INT)  => utils.quit(),
        // SIGCHLD: an intermediate double-fork child has exited.
        // Reap it with WNOHANG, then immediately drain the spawn pipes so
        // registerSpawn fires without waiting for the next XCB event batch.
        sigToU8(std.posix.SIG.CHLD) => {
            input.reapPendingChildren();
            input.drainPendingSpawns();
        },
        else => {},
    }
}

const SIGNAL_DRAIN_BUF = 16; // drain a burst in one syscall rather than one per byte

/// Drains the non-blocking signal pipe and dispatches each signal.
///
/// std.os.linux.read returns usize (the raw syscall result).  On error the
/// kernel returns a negative value, which wraps to a huge unsigned number.
/// Passing that usize to std.posix.errno triggers an unsigned comparison
/// that never sees the value as negative, so errno returns .SUCCESS and the
/// giant number escapes into @intCast / the slice bounds check — producing
/// the "index out of bounds" panic.  The fix is to bitcast to isize first
/// and treat any non-positive result (error or EOF) as a stop condition.
fn handleSignalPipe(fd: std.posix.fd_t) void {
    var buf: [SIGNAL_DRAIN_BUF]u8 = undefined;
    while (true) {
        const rc: isize = @bitCast(std.os.linux.read(fd, &buf, buf.len));
        if (rc <= 0) break; // 0 = EOF on write-end close, negative = error/EAGAIN
        const n: usize = @intCast(rc);
        for (buf[0..n]) |byte| dispatchSignal(byte);
    }
}

// Keybindings

const CookieEntry = struct { cookie: xcb.xcb_void_cookie_t, keycode: u8 };

/// Fills `cookies` with one grab request per (keybinding × lock modifier) pair.
/// Returns the number of entries written.
fn fillGrabCookies(cookies: []CookieEntry) usize {
    var n: usize = 0;
    for (core.config.keybindings.items) |kb| {
        const keycode = kb.keycode orelse continue;

        // Check once per keybinding that the full lock-modifier set fits.
        // Avoids a per-lock branch and prevents partial grabs if the buffer is nearly full.
        if (n + LOCK_MODIFIERS.len > cookies.len) {
            debug.warn("Too many keybindings. Increase MAX_KEYBIND_COOKIES (currently {})", .{MAX_KEYBIND_COOKIES});
            break;
        }

        for (LOCK_MODIFIERS) |lock| {
            cookies[n] = .{
                .cookie = xcb.xcb_grab_key_checked(
                    core.conn, 0, core.root, @intCast(kb.modifiers | lock), keycode,
                    xcb.XCB_GRAB_MODE_ASYNC, xcb.XCB_GRAB_MODE_ASYNC,
                ),
                .keycode = keycode,
            };
            n += 1;
        }
    }
    return n;
}

/// Checks each cookie for an XCB error. Returns the number of failures.
fn checkGrabCookies(cookies: []const CookieEntry) usize {
    var failed: usize = 0;
    for (cookies) |entry| {
        if (xcb.xcb_request_check(core.conn, entry.cookie)) |err| {
            std.c.free(err);
            debug.warn("Failed to grab keycode: {}", .{entry.keycode});
            failed += 1;
        }
    }
    return failed;
}

/// Ungrabs all keys, then re-grabs every configured keybinding across all lock modifier combinations.
/// Fires all grab cookies before reading any reply to reduce round-trips.
pub fn grabKeybindings() !void {
    _ = xcb.xcb_ungrab_key(core.conn, xcb.XCB_GRAB_ANY, core.root, xcb.XCB_MOD_MASK_ANY);

    var cookies: [MAX_KEYBIND_COOKIES]CookieEntry = undefined;
    const n = fillGrabCookies(&cookies);

    const failed = checkGrabCookies(cookies[0..n]);
    if (failed > 0) debug.warn("{} keybinding(s) failed to grab", .{failed});

    _ = xcb.xcb_flush(core.conn);
}

// Config reload

/// Validates config constraints that cannot be checked at parse time.
fn validateConfig(cfg: *const types.Config) !void {
    if (cfg.tiling.master_count == 0) {
        debug.err("Invalid config: master_count must be > 0, keeping old", .{});
        return error.InvalidConfig;
    }
}

/// Applies a validated config: resolves keybindings and notifies all
/// subsystems of the change.  grabKeybindings() is intentionally NOT called
/// here — it reads core.config.keybindings, so it must run after the
/// core.config swap in handleConfigReload.  Calling it here would re-grab
/// the OLD keycodes while g_keybind_map already points to the new ones.
fn applyConfig(new_config: *types.Config) !void {
    config.resolveKeybindings(new_config.keybindings.items, input.getXkbState(), core.alloc);
    config.finalizeConfig(new_config, core.screen);

    window.reloadBorders();
    if (build.has_tiling) tiling.reloadConfig();
    if (build.has_bar) {
        bar.updateTimerState();
        bar.reload();
    }
}

/// Loads and validates a new config, then applies it atomically.
/// On failure, the old config remains active.
fn handleConfigReload() !void {
    debug.info("Reload requested", .{});

    var new_config = config.loadConfigDefault(core.alloc) catch |err| {
        debug.err("Failed to load: {}, keeping old", .{err});
        return err;
    };
    errdefer new_config.deinit(core.alloc);

    try validateConfig(&new_config);
    try applyConfig(&new_config);

    var old_config = core.config;
    core.config = new_config;
    old_config.deinit(core.alloc);

    // Re-grab keybindings now that core.config points to the new config so
    // fillGrabCookies reads the correct (new) keycodes, not the old ones.
    try grabKeybindings();

    // Rebuild after the swap so borrowed key slices point into the new config's memory.
    window.rebuildRulesMap();

    debug.info("Reload complete", .{});
}

// Event loop

/// Returns the shortest timeout across all subsystems, or -1 to block indefinitely.
fn combinedTimeoutMs(blink_ms: i32) i32 {
    if (!build.has_bar) return -1;

    const clock_ms = bar.pollTimeoutMs();
    if (clock_ms < 0) return blink_ms;
    if (blink_ms < 0) return clock_ms;

    return @min(clock_ms, blink_ms);
}

/// Ticks the clock and cursor blink on poll timeout, then flushes to the compositor.
fn handleTimerEvents(cursor_is_blinking: bool) void {
    if (build.has_bar) {
        var drew = false;

        if (bar.checkClockUpdate()) drew = true;

        if (cursor_is_blinking) {
            prompt.blinkTick();
            bar.submitDraw();
            drew = true;
        }

        if (drew) _ = xcb.xcb_flush(core.conn);
    }
}

/// Drains all pending XCB events for this batch, then runs post-batch housekeeping.
fn handleXcbEvents() void {
    while (xcb.xcb_poll_for_event(core.conn)) |event| {
        defer std.c.free(event);
        dispatch(@as(*u8, @ptrCast(event)).*, event);
    }

    // Drain any spawn pipes that became readable during this event batch.
    // This catches the common case where SIGCHLD and the MapRequest arrive in
    // the same poll wakeup: exec_pipe EOF will be readable before SIGCHLD fires,
    // so registerSpawn runs before handleMapRequest needs the spawn queue entry.
    input.drainPendingSpawns();

    if (build.has_tiling) tiling.retileIfDirty();
    focus.drainPendingConfirm();
    focus.drainPointerSync();
    window.updateWorkspaceBordersIfNeeded();
    if (build.has_bar) bar.updateIfDirty() catch |err| debug.err("Failed to update bar: {}", .{err});

    _ = xcb.xcb_flush(core.conn);
}

pub fn run() !void {
    const x_fd: std.posix.fd_t      = xcb.xcb_get_file_descriptor(core.conn);
    const signal_fd: std.posix.fd_t = signal_pipe[0];

    var fds = [_]std.posix.pollfd{
        .{ .fd = x_fd,      .events = std.posix.POLL.IN, .revents = 0 },
        .{ .fd = signal_fd, .events = std.posix.POLL.IN, .revents = 0 },
    };

    while (utils.running.load(.acquire)) {
        const blink_ms = if (build.has_prompt) prompt.blinkPollTimeoutMs() else -1;
        const cursor_is_blinking = blink_ms >= 0;
        const poll_rc = std.os.linux.poll(&fds, fds.len, combinedTimeoutMs(blink_ms));
        const ready: usize = switch (std.posix.errno(poll_rc)) {
            .SUCCESS => @intCast(poll_rc),
            .INTR    => continue,
            else     => |err| {
                debug.err("poll error: {s}", .{@errorName(std.posix.unexpectedErrno(err))});
                break;
            },
        };

        if (ready == 0) {
            handleTimerEvents(cursor_is_blinking);
            continue;
        }

        if ((fds[FD_XCB].revents & (std.posix.POLL.ERR | std.posix.POLL.HUP)) != 0) {
            debug.err("X11 connection error, shutting down", .{});
            break;
        }

        if ((fds[FD_XCB].revents & std.posix.POLL.IN) != 0) handleXcbEvents();

        if ((fds[FD_SIGNAL].revents & std.posix.POLL.IN) != 0) {
            handleSignalPipe(signal_fd);
            if (utils.consumeReload())
                handleConfigReload() catch |err| debug.err("Reload failed: {}", .{err});
        }
    }
}
