
//! X event dispatch, signal handling, config reload, and the main event loop.

const std   = @import("std");
const build = @import("build_options");

const core      = @import("core");
    const xcb   = core.xcb;
const utils     = @import("utils");
const constants = @import("constants");

const debug = @import("debug");

const config = @import("config");

const input = @import("input");

const window = @import("window");
const focus  = @import("focus");

const tiling = if (build.has_tiling) @import("tiling") else struct {};

const bar = if (build.has_bar) @import("bar") else struct {
    pub fn pollTimeoutMs() i32 { return -1; }
    pub fn checkClockUpdate() void {}
    pub fn submitDraw(_: bool) void {}
    pub fn handleExpose(_: *anyopaque) void {}
    pub fn handlePropertyNotify(_: *anyopaque) void {}
    pub fn updateIfDirty() !void {}
    pub fn updateTimerState() void {}
    pub fn reload() void {}
};

const prompt = if (build.has_bar and build.has_prompt) @import("prompt") else struct {
    pub fn blinkPollTimeoutMs() i32 { return -1; }
    pub fn blinkTick() void {}
};


// Indices into the poll fd array.
const FD_XCB    = 0;
const FD_SIGNAL = 1;

// Event dispatch constants — alias to the canonical definitions in constants.zig.
const EVENT_DISPATCH_TABLE = constants.Limits.EVENT_DISPATCH_TABLE;
const MAX_KEYBIND_COOKIES  = constants.Limits.MAX_KEYBIND_COOKIES;
const LOCK_MODIFIERS       = constants.LOCK_MODIFIERS;

// Self-pipe for portable signal delivery.
// Signal handlers write to [1]; the event loop polls [0].
var signal_pipe: [2]std.posix.fd_t = .{ -1, -1 };

// Dispatch table

const EventHandler = *const fn (event: *anyopaque) void;

/// Coerces a concrete handler fn to EventHandler at comptime with zero runtime cost.
inline fn asHandler(comptime f: anytype) EventHandler {
    return @ptrCast(&f);
}

/// Fans out PropertyNotify to both bar (title) and window (WM_PROTOCOLS cache).
fn handlePropertyNotify(event: *anyopaque) void {
    const e: *xcb.xcb_property_notify_event_t = @ptrCast(@alignCast(event));
    bar.handlePropertyNotify(e);
    window.handlePropertyNotify(e);
}

/// O(1) dispatch via a comptime-built table indexed by XCB event type (low 7 bits).
const dispatch_table = blk: {
    var table = [_]?EventHandler{null} ** EVENT_DISPATCH_TABLE;
    table[xcb.XCB_KEY_PRESS]         = asHandler(input.handleKeyPress);
    table[xcb.XCB_BUTTON_PRESS]      = asHandler(input.handleButtonPress);
    table[xcb.XCB_BUTTON_RELEASE]    = asHandler(input.handleButtonRelease);
    table[xcb.XCB_MOTION_NOTIFY]     = asHandler(input.handleMotionNotify);
    table[xcb.XCB_ENTER_NOTIFY]      = asHandler(window.handleEnterNotify);
    table[xcb.XCB_LEAVE_NOTIFY]      = asHandler(window.handleLeaveNotify);
    table[xcb.XCB_FOCUS_IN]          = asHandler(focus.handleFocusIn);
    table[xcb.XCB_MAP_REQUEST]       = asHandler(window.handleMapRequest);
    table[xcb.XCB_CONFIGURE_REQUEST] = asHandler(window.handleConfigureRequest);
    table[xcb.XCB_UNMAP_NOTIFY]      = asHandler(window.handleUnmapNotify);
    table[xcb.XCB_DESTROY_NOTIFY]    = asHandler(window.handleDestroyNotify);
    table[xcb.XCB_EXPOSE]            = asHandler(bar.handleExpose);
    table[xcb.XCB_PROPERTY_NOTIFY]   = asHandler(handlePropertyNotify);
    table[xcb.XCB_CLIENT_MESSAGE]    = asHandler(window.handleClientMessage);
    break :blk table;
};

pub inline fn dispatch(event_type: u8, event: *anyopaque) void {
    const idx = event_type & 0x7F; // strip XCB synthetic-event bit
    if (dispatch_table[idx]) |handler| handler(event);
}

// Signal handling

/// Derive the correct signal number parameter type directly from what
/// std.posix.Sigaction's handler field actually expects, so this stays
/// correct regardless of future stdlib changes.
const SigNumType = param: {
    const handler_field_type = @FieldType(@FieldType(std.posix.Sigaction, "handler"), "handler");
    const handler_sig        = @typeInfo(@typeInfo(handler_field_type).optional.child).pointer.child;
    break :param @typeInfo(handler_sig).@"fn".params[0].type.?;
};

/// Converts any signal value — enum or integer — to its raw u8 number.
/// Used by both signalHandler (runtime) and handleSignalPipe (comptime prongs).
inline fn sigToU8(sig: anytype) u8 {
    return switch (@typeInfo(@TypeOf(sig))) {
        .@"enum" => @intCast(@intFromEnum(sig)),
        else     => @intCast(sig),
    };
}

/// Async-signal-safe handler: writes the signal number as a byte to the pipe.
/// write(2) is async-signal-safe on all POSIX platforms.
fn signalHandler(signo: SigNumType) callconv(.c) void {
    _ = std.os.linux.write(signal_pipe[1], &[_]u8{sigToU8(signo)}, 1);
}

/// Creates a pipe with O_NONBLOCK | O_CLOEXEC set on both ends atomically via pipe2(2).
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

/// Creates the signal self-pipe and installs handlers for SIGHUP/SIGTERM/SIGINT.
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
}

/// Closes both ends of the signal pipe.
pub fn deinitSignalPipe() void {
    for (&signal_pipe) |*fd| {
        if (fd.* == -1) continue;
        _ = std.os.linux.close(fd.*);
        fd.* = -1;
    }
}

/// Drains the non-blocking signal pipe and dispatches each signal.
fn handleSignalPipe(fd: std.posix.fd_t) void {
    var byte: [1]u8 = undefined;
    while (true) {
        const rc = std.os.linux.read(fd, &byte, 1);
        switch (std.posix.errno(rc)) {
            .SUCCESS => {},
            else     => break,
        }
        switch (byte[0]) {
            sigToU8(std.posix.SIG.HUP)  => utils.reload(),
            sigToU8(std.posix.SIG.TERM),
            sigToU8(std.posix.SIG.INT)  => utils.quit(),
            else => {},
        }
    }
}

// Keybindings

/// Ungrabs all keys, then re-grabs every configured keybinding across all LOCK_MODIFIERS combinations.
/// Fires all xcb_grab_key cookies before reading any reply to reduce round-trips.
pub fn grabKeybindings() !void {
    _ = xcb.xcb_ungrab_key(core.conn, xcb.XCB_GRAB_ANY, core.root, xcb.XCB_MOD_MASK_ANY);
    const CookieEntry = struct { cookie: xcb.xcb_void_cookie_t, keycode: u8 };
    var cookies: [MAX_KEYBIND_COOKIES]CookieEntry = undefined;
    var n: usize = 0;
    outer: for (core.config.keybindings.items) |kb| {
        const keycode = kb.keycode orelse continue;
        for (LOCK_MODIFIERS) |lock| {
            if (n >= cookies.len) {
                debug.warn("Too many keybindings. Increase MAX_KEYBIND_COOKIES (currently {})", .{MAX_KEYBIND_COOKIES});
                break :outer;
            }
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
    var failed: usize = 0;
    for (cookies[0..n]) |entry| {
        if (xcb.xcb_request_check(core.conn, entry.cookie)) |err| {
            std.c.free(err);
            debug.warn("Failed to grab keycode: {}", .{entry.keycode});
            failed += 1;
        }
    }
    if (failed > 0) debug.warn("{} keybinding(s) failed to grab", .{failed});
    _ = xcb.xcb_flush(core.conn);
}

// Config reload

/// Triggers a config reload if one has been requested via the signal pipe. No-op otherwise.
inline fn maybeReload() void {
    if (utils.consumeReload())
        handleConfigReload() catch |err| debug.err("Reload failed: {}", .{err});
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

    // Rebuild the workspace-rule fast-lookup map now that core.config points
    // at the new config.  Must happen AFTER the swap so the borrowed key slices
    // in g_rules_map point into the new config's allocations, not the freed old ones.
    window.rebuildRulesMap();

    debug.info("Reload complete", .{});
}

/// Validates config constraints that cannot be checked at parse time.
fn validateConfig(cfg: *const @import("types").Config) !void {
    if (cfg.tiling.master_count == 0) {
        debug.err("Invalid config: master_count must be > 0, keeping old", .{});
        return error.InvalidConfig;
    }
}

/// Applies a validated config: resolves keybindings, swaps globals, re-grabs keys,
/// and notifies all subsystems of the change.  window.rebuildRulesMap() is called
/// by the caller (handleConfigReload) after core.config is swapped, not here,
/// because the map borrows key slices from the live config allocation.
fn applyConfig(new_config: *@import("types").Config) !void {
    config.resolveKeybindings(new_config.keybindings.items, input.getXkbState(), core.alloc);
    config.finalizeConfig(new_config, core.screen);
    
    grabKeybindings() catch |err| {
        debug.err("Keybind grab failed: {}, reverting", .{err});
        return err;
    };
    
    if (build.has_tiling) tiling.reloadConfig();
    window.reloadBorders();
    bar.updateTimerState();
    bar.reload();
    // Unconditional flush: ensures border and tiling commands from reloadBorders()
    // and reloadConfig() are sent even when bar.reload() takes an early-return path
    // (e.g. bar disabled) that does not call its own ungrabAndFlush().
    _ = xcb.xcb_flush(core.conn);
}

// Event loop

/// Returns the shortest timeout across all subsystems that need periodic wakeups,
/// or -1 if nothing needs one right now (block indefinitely).
fn combinedTimeoutMs(blink_ms: i32) i32 {
    const clock_ms = bar.pollTimeoutMs();
    if (clock_ms < 0) return blink_ms;
    if (blink_ms < 0) return clock_ms;
    return @min(clock_ms, blink_ms);
}

pub fn run() !void {
    const x_fd: std.posix.fd_t      = xcb.xcb_get_file_descriptor(core.conn);
    const signal_fd: std.posix.fd_t = signal_pipe[0];

    var fds = [_]std.posix.pollfd{
        .{ .fd = x_fd,      .events = std.posix.POLL.IN, .revents = 0 },
        .{ .fd = signal_fd, .events = std.posix.POLL.IN, .revents = 0 },
    };

    while (utils.running.load(.acquire)) {
        const blink_ms = prompt.blinkPollTimeoutMs();
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
            bar.checkClockUpdate();
            if (cursor_is_blinking) {
                prompt.blinkTick();
                bar.submitDraw();
            }
            continue;
        }

        if ((fds[FD_XCB].revents & (std.posix.POLL.ERR | std.posix.POLL.HUP)) != 0) {
            debug.err("X11 connection error, shutting down", .{});
            break;
        }

        if ((fds[FD_XCB].revents & std.posix.POLL.IN) != 0) {
            while (xcb.xcb_poll_for_event(core.conn)) |event| {
                defer std.c.free(event);
                dispatch(@as(*u8, @ptrCast(event)).*, event);
            }
            if (build.has_tiling) tiling.retileIfDirty();
            focus.drainPendingConfirm();
            focus.drainPointerSync();
            window.updateWorkspaceBordersIfNeeded();
            bar.updateIfDirty() catch |err| debug.err("Failed to update bar: {}", .{err});
            _ = xcb.xcb_flush(core.conn);
        }

        if ((fds[FD_SIGNAL].revents & std.posix.POLL.IN) != 0) {
            handleSignalPipe(signal_fd);
            maybeReload();
        }
    }
}
