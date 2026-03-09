//! X event dispatch, signal handling, config reload, and the main event loop.

// Zig stdlib
const std        = @import("std");
const builtin    = @import("builtin");
const fullscreen = @import("fullscreen");

// core/
const utils     = @import("utils");
const constants = @import("constants");

// config/
const config  = @import("config");
const defs    = @import("defs");
    const WM  = defs.WM;
    const xcb = defs.xcb;

// debug/
const debug = @import("debug");

// input/
const input     = @import("input");
const xkbcommon = @import("xkbcommon");

// window/
const window         = @import("window");
    const focus      = @import("focus");
    const minimize   = @import("minimize");
    const workspaces = @import("workspaces");

// tiling/
const tiling = @import("tiling");

// bar/
const bar        = @import("bar");
    const prompt = @import("prompt");

// Indices into the poll fd array.
const FD_XCB:    usize = 0;
const FD_SIGNAL: usize = 1;

// Self-pipe for portable signal delivery.
// Signal handlers write to [1]; the event loop polls [0].
var signal_pipe: [2]std.posix.fd_t = .{ -1, -1 };

// Dispatch table

const EventHandler = *const fn (event: *anyopaque, wm: *WM) void;

/// Coerces a concrete handler fn to EventHandler at comptime with zero runtime cost.
inline fn asHandler(comptime f: anytype) EventHandler {
    return @ptrCast(&f);
}

/// Fans out PropertyNotify to both bar (title) and window (WM_PROTOCOLS cache).
fn handlePropertyNotify(event: *anyopaque, wm: *WM) void {
    const e: *xcb.xcb_property_notify_event_t = @ptrCast(@alignCast(event));
    bar.handlePropertyNotify(e, wm);
    window.handlePropertyNotify(e, wm);
}

/// O(1) dispatch via a comptime-built table indexed by XCB event type (low 7 bits).
const dispatch_table = blk: {
    var table = [_]?EventHandler{null} ** constants.Limits.EVENT_DISPATCH_TABLE;
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
    table[xcb.XCB_PROPERTY_NOTIFY]   = asHandler(handlePropertyNotify); // multi-target fan-out: bar + window
    break :blk table;
};

pub inline fn dispatch(event_type: u8, event: *anyopaque, wm: *WM) void {
    const idx = event_type & 0x7F; // strip XCB synthetic-event bit
    if (dispatch_table[idx]) |handler| handler(event, wm);
}

// Module lifecycle

pub fn initModules(wm: *WM, xkb_state: *xkbcommon.XkbState) !void {
    try input.init(wm, xkb_state);
    fullscreen.init(wm);
    workspaces.init(wm);
    try tiling.init(wm);
    try minimize.init(wm);
    prompt.init(wm.conn);
}

pub fn deinitModules() void {
    // minimize state is owned by WM.deinit — no separate deinit here.
    prompt.deinit();
    tiling.deinit();
    workspaces.deinit();
    fullscreen.deinit();
    input.deinit();
}

// Signal handling

/// Derive the correct signal number parameter type directly from what
/// std.posix.Sigaction's handler field actually expects, so this stays
/// correct regardless of future stdlib changes.
const SigNumType = param: {
    const handler_fn = @FieldType(@FieldType(std.posix.Sigaction, "handler"), "handler");
    const fn_info = @typeInfo(@typeInfo(handler_fn).optional.child).pointer.child;
    break :param @typeInfo(fn_info).@"fn".params[0].type.?;
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
    _ = std.posix.write(signal_pipe[1], &[_]u8{sigToU8(signo)}) catch {};
}

/// Creates a pipe with O_NONBLOCK | O_CLOEXEC set on both ends.
fn createPipe() ![2]std.posix.fd_t {
    var fds: [2]std.posix.fd_t = undefined;

    const rc = if (builtin.os.tag == .linux)
        std.os.linux.pipe(&fds)
    else
        std.os.system.pipe(&fds);

    switch (std.posix.errno(rc)) {
        .SUCCESS => {},
        .MFILE   => return error.ProcessFdQuotaExceeded,
        .NFILE   => return error.SystemFdQuotaExceeded,
        else     => |err| return std.posix.unexpectedErrno(err),
    }

    errdefer {
        std.posix.close(fds[0]);
        std.posix.close(fds[1]);
    }

    const o_nonblock = comptime @as(u32, @bitCast(std.posix.O{ .NONBLOCK = true }));

    for (fds) |fd| {
        _ = try std.posix.fcntl(fd, std.posix.F.SETFD, std.posix.FD_CLOEXEC);
        _ = try std.posix.fcntl(fd, std.posix.F.SETFL, o_nonblock);
    }

    return fds;
}

/// Creates the signal self-pipe and installs handlers for SIGHUP/SIGTERM/SIGINT.
/// Returns the read end; the caller polls it and closes it on shutdown.
pub fn setupSignalPipe() !std.posix.fd_t {
    signal_pipe = try createPipe();

    const sa: std.posix.Sigaction = .{
        .handler = .{ .handler = signalHandler },
        .mask    = std.posix.sigemptyset(),
        .flags   = std.posix.SA.RESTART,
    };

    // sigaction returns void in modern Zig Master; no 'try' needed.
    std.posix.sigaction(std.posix.SIG.HUP,  &sa, null);
    std.posix.sigaction(std.posix.SIG.TERM, &sa, null);
    std.posix.sigaction(std.posix.SIG.INT,  &sa, null);

    return signal_pipe[0];
}

/// Closes the write end of the signal pipe. The read end is closed by the caller.
pub fn deinitSignalPipe() void {
    if (signal_pipe[1] != -1) {
        std.posix.close(signal_pipe[1]);
        signal_pipe[1] = -1;
    }
}

/// Drains the non-blocking signal pipe and dispatches each signal.
fn handleSignalPipe(fd: std.posix.fd_t) void {
    var byte: [1]u8 = undefined;
    while (true) {
        const n = std.posix.read(fd, &byte) catch break;
        if (n == 0) break;
        switch (byte[0]) {
            sigToU8(std.posix.SIG.HUP)  => utils.reload(),
            sigToU8(std.posix.SIG.TERM),
            sigToU8(std.posix.SIG.INT)  => utils.quit(),
            else => {},
        }
    }
}

// Keybindings

pub fn grabKeybindings(wm: *WM) !void {
    _ = xcb.xcb_ungrab_key(wm.conn, xcb.XCB_GRAB_ANY, wm.root, xcb.XCB_MOD_MASK_ANY);
    const CookieEntry = struct { cookie: xcb.xcb_void_cookie_t, keycode: u8 };
    var cookies: [constants.Limits.MAX_KEYBIND_COOKIES]CookieEntry = undefined;
    var n: usize = 0;
    outer: for (wm.config.keybindings.items) |kb| {
        const keycode = kb.keycode orelse continue;
        for (constants.LOCK_MODIFIERS) |lock| {
            if (n >= cookies.len) {
                debug.warn("Too many keybindings. Increase Limits.MAX_KEYBIND_COOKIES (currently {})", .{constants.Limits.MAX_KEYBIND_COOKIES});
                break :outer;
            }
            cookies[n] = .{
                .cookie = xcb.xcb_grab_key_checked(
                    wm.conn, 0, wm.root, @intCast(kb.modifiers | lock), keycode,
                    xcb.XCB_GRAB_MODE_ASYNC, xcb.XCB_GRAB_MODE_ASYNC,
                ),
                .keycode = keycode,
            };
            n += 1;
        }
    }
    var failed: usize = 0;
    for (cookies[0..n]) |entry| {
        if (xcb.xcb_request_check(wm.conn, entry.cookie)) |err| {
            std.c.free(err);
            debug.warn("Failed to grab keycode: {}", .{entry.keycode});
            failed += 1;
        }
    }
    if (failed > 0) debug.warn("{} keybinding(s) failed to grab", .{failed});
    _ = xcb.xcb_flush(wm.conn);
}

// Config reload

inline fn maybeReload(wm: *WM) void {
    if (utils.consumeReload())
        handleConfigReload(wm) catch |err| debug.err("Reload failed: {}", .{err});
}

fn handleConfigReload(wm: *WM) !void {
    debug.info("Reload requested", .{});
    var new_config = config.loadConfigDefault(wm.allocator) catch |err| {
        debug.err("Failed to load: {}, keeping old", .{err});
        return err;
    };
    errdefer new_config.deinit();
    if (new_config.tiling.master_count == 0) {
        debug.err("Invalid config: master_count must be > 0, keeping old", .{});
        return error.InvalidConfig;
    }
    config.resolveKeybindings(new_config.keybindings.items, input.getXkbState(), wm.allocator);
    config.finalizeConfig(&new_config, wm.screen);
    var old_config = wm.config;
    wm.config = new_config;
    grabKeybindings(wm) catch |err| {
        debug.err("Keybind grab failed: {}, reverting", .{err});
        wm.config = old_config;
        return err;
    };
    input.rebuildKeybindMap(wm) catch |err| {
        debug.err("rebuildKeybindMap failed: {}, reverting", .{err});
        wm.config = old_config;
        grabKeybindings(wm) catch {}; // restore X server state to match old config
        return err;
    };
    old_config.deinit();
    tiling.reloadConfig(wm);
    bar.updateTimerState();
    bar.reload(wm);
    debug.info("Reload complete", .{});
}

// Event loop

/// Returns the shortest timeout across all subsystems that need periodic wakeups,
/// or -1 if nothing needs one right now (block indefinitely).
fn combinedTimeoutMs() i32 {
    const clock_ms = bar.pollTimeoutMs();
    const blink_ms = prompt.blinkPollTimeoutMs();
    if (clock_ms < 0) return blink_ms;
    if (blink_ms < 0) return clock_ms;
    return @min(clock_ms, blink_ms);
}

pub fn run(wm: *WM, signal_fd: std.posix.fd_t) !void {
    const x_fd: std.posix.fd_t = xcb.xcb_get_file_descriptor(wm.conn);

    var fds = [_]std.posix.pollfd{
        .{ .fd = x_fd,      .events = std.posix.POLL.IN, .revents = 0 },
        .{ .fd = signal_fd, .events = std.posix.POLL.IN, .revents = 0 },
    };

    while (utils.running.load(.acquire)) {
        const ready = std.posix.poll(&fds, combinedTimeoutMs()) catch |err| {
            if (err == error.SignalInterrupt) continue;
            debug.err("poll error: {s}", .{@errorName(err)});
            break;
        };

        if (ready == 0) {
            bar.checkClockUpdate();
            if (prompt.blinkPollTimeoutMs() >= 0) {
                prompt.blinkTick();
                bar.submitDraw(wm, false);
            }
            continue;
        }

        if ((fds[FD_XCB].revents & (std.posix.POLL.ERR | std.posix.POLL.HUP)) != 0) {
            debug.err("X11 connection error, shutting down", .{});
            break;
        }

        if ((fds[FD_XCB].revents & std.posix.POLL.IN) != 0) {
            while (xcb.xcb_poll_for_event(wm.conn)) |event| {
                defer std.c.free(event);
                dispatch(@as(*u8, @ptrCast(event)).*, event, wm);
            }
            tiling.retileIfDirty(wm);
            bar.updateIfDirty(wm) catch |err| debug.err("Failed to update bar: {}", .{err});
            _ = xcb.xcb_flush(wm.conn);
        }

        if ((fds[FD_SIGNAL].revents & std.posix.POLL.IN) != 0) {
            handleSignalPipe(signal_fd);
            maybeReload(wm);
        }
    }
}
