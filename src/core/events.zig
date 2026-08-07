//! X event dispatch and main event loop
//! Handles X events, OS signals, and config reload, driving the WM's main loop.

const std = @import("std");

const core = @import("core");
const xcb = core.xcb;
const utils = @import("utils");
const constants = @import("constants");
const types = @import("types");

const debug = @import("debug");
const config = @import("config");
const input = @import("input");
const window = @import("window");
const focus = @import("focus");

const tiling = @import("tiling");
const bar = @import("bar");
const prompt = @import("prompt");
const fullscreen = @import("fullscreen");

// Indices into the poll fd array.
const FD_XCB = 0;
const FD_SIGNAL = 1;

// Aliases to canonical definitions in constants.zig.
const EVENT_DISPATCH_TABLE = constants.Limits.EVENT_DISPATCH_TABLE;
const MAX_KEYBIND_COOKIES = constants.Limits.MAX_KEYBIND_COOKIES;
const LOCK_MODIFIERS = constants.LOCK_MODIFIERS;

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
    bar.handlePropertyNotify(e);
    window.handlePropertyNotify(e);
}

/// Routes ConfigureNotify to the fullscreen deferred-bar-hide/show logic.
fn handleConfigureNotify(event: *anyopaque) void {
    const e: *xcb.xcb_configure_notify_event_t = @ptrCast(@alignCast(event));
    fullscreen.notifyConfigureIfPending(e.window, e.width, e.height);
}

/// Notifies fullscreen of the destroyed window before delegating to window.zig.
/// This clears any pending deferred bar-show for a window that exits fullscreen
/// and is then destroyed before it can send a ConfigureNotify.
fn handleDestroyNotify(event: *anyopaque) void {
    const e: *xcb.xcb_destroy_notify_event_t = @ptrCast(@alignCast(event));
    fullscreen.onWindowGone(e.window);
    window.handleDestroyNotify(e);
}

/// O(1) dispatch via a comptime-built table indexed by XCB event type (low 7 bits).
const dispatch_table = blk: {
    var table = [_]?EventHandler{null} ** EVENT_DISPATCH_TABLE;

    table[xcb.XCB_ENTER_NOTIFY] = asHandler(window.handleEnterNotify);
    table[xcb.XCB_LEAVE_NOTIFY] = asHandler(window.handleLeaveNotify);

    table[xcb.XCB_MAP_REQUEST] = asHandler(window.handleMapRequest);
    table[xcb.XCB_CONFIGURE_REQUEST] = asHandler(window.handleConfigureRequest);
    table[xcb.XCB_UNMAP_NOTIFY] = asHandler(window.handleUnmapNotify);
    table[xcb.XCB_DESTROY_NOTIFY] = asHandler(handleDestroyNotify);
    table[xcb.XCB_CLIENT_MESSAGE] = asHandler(window.handleClientMessage);

    table[xcb.XCB_KEY_PRESS] = asHandler(input.handleKeyPress);
    table[xcb.XCB_BUTTON_PRESS] = asHandler(input.handleButtonPress);
    table[xcb.XCB_BUTTON_RELEASE] = asHandler(input.handleButtonRelease);
    table[xcb.XCB_MOTION_NOTIFY] = asHandler(input.handleMotionNotify);
    table[xcb.XCB_FOCUS_IN] = asHandler(focus.handleFocusIn);
    table[xcb.XCB_PROPERTY_NOTIFY] = asHandler(handlePropertyNotify);

    table[xcb.XCB_EXPOSE] = asHandler(bar.handleExpose);

    table[xcb.XCB_CONFIGURE_NOTIFY] = asHandler(handleConfigureNotify);

    break :blk table;
};

pub fn dispatch(event_type: u8, event: *anyopaque) void {
    const idx = event_type & 0x7F; // strip XCB synthetic-event bit
    if (dispatch_table[idx]) |handler| handler(event);
}

// Signal handling

// anytype: called with both std.os.linux.SIG (signalHandler, the kernel's
// callback signature) and std.posix.SIG (sigaction setup and dispatchSignal)
// — two different enum types for the same signal numbers.
inline fn sigToU8(sig: anytype) u8 {
    return @intCast(@intFromEnum(sig));
}

/// Async-signal-safe handler: writes the signal number as a byte to the pipe.
fn signalHandler(signo: std.os.linux.SIG) callconv(.c) void {
    _ = std.os.linux.write(signal_pipe[1], &[_]u8{sigToU8(signo)}, 1);
}

/// Creates the signal self-pipe and installs handlers for SIGHUP/SIGTERM/SIGINT/SIGCHLD.
pub fn setupSignalPipe() !void {
    signal_pipe = try utils.makePipe();

    const sa: std.posix.Sigaction = .{
        .handler = .{ .handler = signalHandler },
        .mask = std.posix.sigemptyset(),
        .flags = std.posix.SA.RESTART,
    };

    std.posix.sigaction(std.posix.SIG.HUP, &sa, null);
    std.posix.sigaction(std.posix.SIG.TERM, &sa, null);
    std.posix.sigaction(std.posix.SIG.INT, &sa, null);
    std.posix.sigaction(std.posix.SIG.CHLD, &sa, null); // reaped in dispatchSignal, below
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
        sigToU8(std.posix.SIG.HUP) => utils.reload(),
        sigToU8(std.posix.SIG.TERM), sigToU8(std.posix.SIG.INT) => utils.quit(),
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
/// kernel returns a negative value, which wraps to a huge unsigned number;
/// an unsigned comparison against that value never reads as negative, so it
/// would escape unchecked into @intCast and the slice bounds check.  Bitcast
/// to isize first and treat any non-positive result (error or EOF) as a stop
/// condition.
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
    const cs = core.getState();
    for (cs.config.keybindings.items) |kb| {
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
                    cs.conn,
                    0,
                    cs.root,
                    @intCast(kb.modifiers | lock),
                    keycode,
                    xcb.XCB_GRAB_MODE_ASYNC,
                    xcb.XCB_GRAB_MODE_ASYNC,
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
    const conn = core.getState().conn;
    for (cookies) |entry| {
        if (xcb.xcb_request_check(conn, entry.cookie)) |err| {
            std.c.free(err);
            debug.warn("Failed to grab keycode: {}", .{entry.keycode});
            failed += 1;
        }
    }
    return failed;
}

/// Ungrabs all keys, then re-grabs every configured keybinding across all lock modifier combinations.
/// Fires all grab cookies before reading any reply to reduce round-trips.
pub fn grabKeybindings() void {
    const cs = core.getState();
    _ = xcb.xcb_ungrab_key(cs.conn, xcb.XCB_GRAB_ANY, cs.root, xcb.XCB_MOD_MASK_ANY);

    var cookies: [MAX_KEYBIND_COOKIES]CookieEntry = undefined;
    const n = fillGrabCookies(&cookies);

    const failed = checkGrabCookies(cookies[0..n]);
    if (failed > 0) debug.warn("{} keybinding(s) failed to grab", .{failed});

    _ = xcb.xcb_flush(cs.conn);
}

// Config reload

/// Applies a validated config: resolves keybindings and notifies all
/// subsystems of the change. grabKeybindings() is deliberately not called
/// here — see the comment in handleConfigReload for why.
fn applyConfig(new_config: *types.Config) !void {
    const cs = core.getState();
    new_config.keybind_resolver.build(new_config.keybindings.items, input.getXkbState(), cs.alloc);
    config.finalizeConfig(new_config, cs.screen);

    window.reloadBorders();
    tiling.reloadConfig();
    bar.reload();
}

/// Loads and validates a new config, then applies it atomically.
/// On failure, the old config remains active.
fn handleConfigReload() !void {
    debug.info("Reload requested", .{});
    const cs = core.getState();

    var new_config = config.loadConfigDefault(cs.alloc) catch |err| {
        debug.err("Failed to load: {}, keeping old", .{err});
        return err;
    };
    errdefer new_config.deinit(cs.alloc);

    try config.validate(&new_config);
    try applyConfig(&new_config);

    var old_config = cs.config;
    cs.config = new_config;
    old_config.deinit(cs.alloc);

    // grabKeybindings() must run after this swap, not inside applyConfig:
    // fillGrabCookies() reads core.getState().config.keybindings, so calling
    // it before the swap would re-grab the OLD keycodes.
    grabKeybindings();

    // Rebuild after the swap so borrowed key slices point into the new config's memory.
    window.buildRulesMap();

    debug.info("Reload complete", .{});
}

// Event loop

/// Ticks the clock and cursor blink on poll timeout, then flushes to the compositor.
fn handleTimerEvents(cursor_is_blinking: bool) void {
    // poll() now times out only for cursor blink; the clock and carousel
    // threads draw directly via bar.checkClockUpdate()/bar.tickCarousel().
    if (cursor_is_blinking) {
        prompt.blinkTick();
        bar.submitDraw();
        _ = xcb.xcb_flush(core.getState().conn);
    }
}

/// Drains all pending XCB events for this batch, then runs post-batch housekeeping.
fn handleXcbEvents() void {
    const conn = core.getState().conn;
    while (xcb.xcb_poll_for_event(conn)) |event| {
        defer std.c.free(event);
        dispatch(@as(*u8, @ptrCast(event)).*, event);
    }

    // Drain any spawn pipes that became readable during this event batch.
    // This catches the common case where SIGCHLD and the MapRequest arrive in
    // the same poll wakeup: the spawn pipe's EOF will be readable before
    // SIGCHLD fires, so registerSpawn runs before handleMapRequest needs the
    // spawn queue entry.
    input.drainPendingSpawns();

    tiling.retileIfDirty();
    focus.drainPendingConfirm();
    focus.drainPointerSync();
    window.updateWorkspaceBordersIfNeeded();
    bar.updateIfDirty() catch |err| debug.err("Failed to update bar: {}", .{err});

    _ = xcb.xcb_flush(conn);
}

pub fn run() !void {
    const x_fd: std.posix.fd_t = xcb.xcb_get_file_descriptor(core.getState().conn);
    const signal_fd: std.posix.fd_t = signal_pipe[0];

    var fds = [_]std.posix.pollfd{
        .{ .fd = x_fd, .events = std.posix.POLL.IN, .revents = 0 },
        .{ .fd = signal_fd, .events = std.posix.POLL.IN, .revents = 0 },
    };

    while (utils.running.load(.acquire)) {
        const blink_ms = prompt.blinkPollTimeoutMs();
        const cursor_is_blinking = blink_ms >= 0;
        const poll_rc = std.os.linux.poll(&fds, fds.len, blink_ms);
        const ready: usize = switch (std.posix.errno(poll_rc)) {
            .SUCCESS => @intCast(poll_rc),
            .INTR => continue,
            else => |err| {
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
