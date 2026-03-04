//! X event dispatch, signal handling, config reload, and the main event loop.

const std = @import("std");

const defs      = @import("defs");
const xcb       = defs.xcb;
    const WM    = defs.WM;
const constants = @import("constants");
const config    = @import("config");
const utils     = @import("utils");
const debug     = @import("debug");
const xkbcommon = @import("xkbcommon");

const input      = @import("input");
const window     = @import("window");
const tiling     = @import("tiling");
const workspaces = @import("workspaces");
const bar        = @import("bar");
const minimize   = @import("minimize");
const drun       = @import("drun");

const IoUring = std.os.linux.IoUring;

// User-data tags for io_uring CQEs.
const TAG_XCB    : u64 = 1;
const TAG_SIGNAL : u64 = 2;
const TAG_CLOCK  : u64 = 3;
const TAG_BLINK  : u64 = 4;

// Stable storage for the clock timeout timespec.
// Must outlive the io_uring operation
// (i.e. remain valid from submission until the CQE arrives).
var clock_ts: std.os.linux.kernel_timespec = .{ .sec = 0, .nsec = 0 };

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

/// Comptime O(1) dispatch table indexed by XCB event type (low 7 bits).
const dispatch_table = blk: {
    var table = [_]?EventHandler{null} ** constants.Limits.EVENT_DISPATCH_TABLE;
    table[xcb.XCB_KEY_PRESS]         = asHandler(input.handleKeyPress);
    table[xcb.XCB_BUTTON_PRESS]      = asHandler(input.handleButtonPress);
    table[xcb.XCB_BUTTON_RELEASE]    = asHandler(input.handleButtonRelease);
    table[xcb.XCB_MOTION_NOTIFY]     = asHandler(input.handleMotionNotify);
    table[xcb.XCB_ENTER_NOTIFY]      = asHandler(window.handleEnterNotify);
    table[xcb.XCB_LEAVE_NOTIFY]      = asHandler(window.handleLeaveNotify);
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
    if (idx < dispatch_table.len) {
        if (dispatch_table[idx]) |handler| handler(event, wm);
    }
}

// Module lifecycle

pub fn initModules(wm: *WM) !void {
    try input.init(wm);
    workspaces.init(wm);
    tiling.init(wm);
    minimize.init(wm);
    drun.init(wm.conn);
}

pub fn deinitModules() void {
    drun.deinit();
    minimize.deinit();
    tiling.deinit();
    workspaces.deinit();
    input.deinit();
}

// Signal handling

/// Creates a signalfd (for SIGHUP / SIGTERM / SIGINT).
pub fn setupSignalFd() !std.posix.fd_t {
    var sigset: std.os.linux.sigset_t = std.mem.zeroes(std.os.linux.sigset_t);
    std.os.linux.sigaddset(&sigset, std.posix.SIG.HUP);
    std.os.linux.sigaddset(&sigset, std.posix.SIG.TERM);
    std.os.linux.sigaddset(&sigset, std.posix.SIG.INT);
    _ = std.os.linux.sigprocmask(std.posix.SIG.BLOCK, &sigset, null);
    const sfd = std.os.linux.signalfd(-1, &sigset,
        std.os.linux.SFD.NONBLOCK | std.os.linux.SFD.CLOEXEC);
    if (sfd < 0) return error.SignalFdFailed;
    return @intCast(sfd);
}

/// Drains the non-blocking signal fd and dispatches each signal.
fn handleSignalFd(fd: std.posix.fd_t) void {
    while (true) {
        var siginfo: std.os.linux.signalfd_siginfo = undefined;
        const n = std.posix.read(fd, std.mem.asBytes(&siginfo)) catch break;
        if (n != @sizeOf(std.os.linux.signalfd_siginfo)) break;
        switch (siginfo.signo) {
            @intFromEnum(std.posix.SIG.HUP)  => utils.reload(),
            @intFromEnum(std.posix.SIG.TERM),
            @intFromEnum(std.posix.SIG.INT)  => utils.quit(),
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
    config.resolveKeybindings(new_config.keybindings.items, @ptrCast(@alignCast(wm.xkb_state)), wm.allocator);
    config.finalizeConfig(&new_config, wm.screen);
    var old_config = wm.config;
    wm.config = new_config;
    grabKeybindings(wm) catch |err| {
        debug.err("Keybind grab failed: {}, reverting", .{err});
        wm.config = old_config;
        return err;
    };
    // rebuildKeybindMap must succeed before we release the old config.
    // If it fails we can still roll back by restoring old_config; once
    // old_config.deinit() is called that rollback window is permanently closed.
    input.rebuildKeybindMap(wm) catch |err| {
        debug.err("rebuildKeybindMap failed: {}, reverting", .{err});
        wm.config = old_config;
        // new_config is still live (errdefer will deinit it on return)
        return err;
    };
    old_config.deinit();
    tiling.reloadConfig(wm);
    bar.updateTimerState();
    bar.reload(wm);
    debug.info("Reload complete", .{});
}

// io_uring helpers

fn getSqe(iou: *IoUring) *std.os.linux.io_uring_sqe {
    // The ring is initialised with depth 8 and we submit at most 3 ops at once
    // (XCB poll + signal poll + optional clock timeout), so get_sqe should
    // almost never fail.  submit_and_wait(0) flushes pending SQEs without
    // blocking to free ring slots; if it errors we log and retry rather than
    // silently looping forever.
    while (true) {
        if (iou.get_sqe()) |sqe| return sqe else |_| {}
        _ = iou.submit_and_wait(0) catch |err| {
            debug.err("io_uring submit_and_wait failed in getSqe: {s}", .{@errorName(err)});
        };
    }
}

inline fn submitPollAdd(iou: *IoUring, fd: std.posix.fd_t, tag: u64) void {
    var sqe = std.mem.zeroes(std.os.linux.io_uring_sqe);
    sqe.opcode    = .POLL_ADD;
    sqe.fd        = fd;
    sqe.rw_flags  = std.posix.POLL.IN;
    sqe.user_data = tag;
    getSqe(iou).* = sqe;
}

inline fn submitClockTimeout(iou: *IoUring, ms: i32) void {
    const ns: i64 = @as(i64, ms) * std.time.ns_per_ms;
    clock_ts = .{
        .sec  = @intCast(@divFloor(ns, std.time.ns_per_s)),
        .nsec = @intCast(@mod(ns, std.time.ns_per_s)),
    };
    var sqe = std.mem.zeroes(std.os.linux.io_uring_sqe);
    sqe.opcode    = .TIMEOUT;
    sqe.addr      = @intFromPtr(&clock_ts);
    sqe.len       = 1;
    sqe.user_data = TAG_CLOCK;
    getSqe(iou).* = sqe;
}

// Event loop

pub fn run(wm: *WM, signal_fd: std.posix.fd_t) !void {
    const x_fd: std.posix.fd_t = xcb.xcb_get_file_descriptor(wm.conn);
    const bfd = drun.blinkFd();
    const blink_pending = bfd >= 0;

    var iou = try IoUring.init(8, 0);
    defer iou.deinit();

    // Submit initial polls.
    submitPollAdd(&iou, x_fd, TAG_XCB);
    submitPollAdd(&iou, signal_fd, TAG_SIGNAL);
    if (blink_pending) submitPollAdd(&iou, bfd, TAG_BLINK);
    const ms_init = bar.pollTimeoutMs();
    var clock_pending = ms_init >= 0;
    if (clock_pending) submitClockTimeout(&iou, ms_init);

    var cqes: [16]std.os.linux.io_uring_cqe = undefined;

    while (utils.running.load(.acquire)) {
        _ = iou.submit_and_wait(1) catch |err| {
            if (err == error.SignalInterrupt) continue;
            debug.err("io_uring error: {s}", .{@errorName(err)});
            break;
        };

        const n = iou.copy_cqes(&cqes, 0) catch |err| blk: {
            if (err == error.SignalInterrupt) break :blk @as(u32, 0);
            debug.err("copy_cqes error: {s}", .{@errorName(err)});
            break :blk @as(u32, 0);
        };

        var saw_xcb    = false;
        var saw_signal = false;
        var saw_clock  = false;
        var saw_blink  = false;
        var x_dead     = false;

        for (cqes[0..n]) |cqe| {
            switch (cqe.user_data) {
                TAG_XCB => {
                    if (cqe.res < 0) {
                        x_dead = true;
                    } else {
                        const revents: u32 = @bitCast(cqe.res);
                        if (revents & (std.posix.POLL.ERR | std.posix.POLL.HUP) != 0)
                            x_dead = true
                        else
                            saw_xcb = true;
                    }
                },
                TAG_SIGNAL => { saw_signal = true; },
                TAG_CLOCK  => { clock_pending = false; saw_clock = true; },
                TAG_BLINK  => { saw_blink = true; },
                else => {},
            }
        }

        if (x_dead or xcb.xcb_connection_has_error(wm.conn) != 0) {
            debug.err("X11 connection error, shutting down", .{});
            break;
        }

        if (saw_xcb) {
            while (xcb.xcb_poll_for_event(wm.conn)) |event| {
                defer std.c.free(event);
                dispatch(@as(*u8, @ptrCast(event)).*, event, wm);
            }
            maybeReload(wm);
            tiling.retileIfDirty(wm);
            bar.updateIfDirty(wm) catch |err| debug.err("Failed to update bar: {}", .{err});
            _ = xcb.xcb_flush(wm.conn);
            submitPollAdd(&iou, x_fd, TAG_XCB);
            // If the clock was inactive (e.g. bar had no clock before reload),
            // check again after reload may have added one.
            if (!clock_pending) {
                const ms = bar.pollTimeoutMs();
                if (ms >= 0) { submitClockTimeout(&iou, ms); clock_pending = true; }
            }
        }

        if (saw_signal) {
            handleSignalFd(signal_fd);
            maybeReload(wm);
            submitPollAdd(&iou, signal_fd, TAG_SIGNAL);
        }

        if (saw_clock) {
            bar.checkClockUpdate();
            const ms = bar.pollTimeoutMs();
            if (ms >= 0) { submitClockTimeout(&iou, ms); clock_pending = true; }
        }

        if (saw_blink) {
            drun.blinkTick();
            bar.submitDrawAsync(wm);
            submitPollAdd(&iou, bfd, TAG_BLINK);
        }
    }
}
