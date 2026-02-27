//! Main event loop
//!
//! Uses POLL_ADD for the XCB and signal file descriptors plus an optional
//! TIMEOUT for the clock segment.  Each operation is resubmitted after it
//! fires (no MULTI flag, so kernel 5.4+ suffices).

const std     = @import("std");
const builtin = @import("builtin");

const defs      = @import("defs");
    const WM    = defs.WM;
    const xcb   = defs.xcb;
const constants = @import("constants");
const config    = @import("config");
const utils     = @import("utils");
const dpi       = @import("dpi");
const debug     = @import("debug");

const xkbcommon = @import("xkbcommon");
const input     = @import("input");
const events    = @import("events");

const lifecycle = @import("lifecycle");
const tiling    = @import("tiling");
const layouts   = @import("layouts");

const bar = @import("bar");

//TODO: replace with something that is also bsd-compatible
const IoUring = std.os.linux.IoUring; // async I/O interface

// User-data tags for io_uring CQEs.
const TAG_XCB    : u64 = 1;
const TAG_SIGNAL : u64 = 2;
const TAG_CLOCK  : u64 = 3;

// Stable storage for the clock timeout timespec.
// Must outlive the io_uring operation
// (i.e. remain valid from submission until the CQE arrives).
var clock_ts: std.os.linux.kernel_timespec = .{ .sec = 0, .nsec = 0 };

/// Creates a signalfd (for SIGHUP / SIGTERM / SIGINT).
fn setupSignalFd() !std.posix.fd_t {
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
            @intFromEnum(std.posix.SIG.HUP)  => lifecycle.reload(),
            @intFromEnum(std.posix.SIG.TERM),
            @intFromEnum(std.posix.SIG.INT)  => lifecycle.quit(),
            else => {},
        }
    }
}

fn setupRootCursor(conn: *xcb.xcb_connection_t, screen: *xcb.xcb_screen_t) void {
    const font   = xcb.xcb_generate_id(conn);
    const cursor = xcb.xcb_generate_id(conn);
    _ = xcb.xcb_open_font(conn, font, 6, "cursor");
    _ = xcb.xcb_create_glyph_cursor(conn, cursor, font, font,
            constants.CURSOR_LEFT_PTR, constants.CURSOR_LEFT_PTR_MASK,
            0, 0, 0, 65535, 65535, 65535);
    _ = xcb.xcb_change_window_attributes(conn, screen.*.root,
            xcb.XCB_CW_CURSOR, &[_]u32{cursor});
    _ = xcb.xcb_close_font(conn, font);
}

fn becomeWindowManager(conn: *xcb.xcb_connection_t, root: u32) !void {
    if (xcb.xcb_request_check(conn, xcb.xcb_change_window_attributes_checked(
        conn, root, xcb.XCB_CW_EVENT_MASK, &[_]u32{constants.EventMasks.ROOT_WINDOW}))) |err| {
        std.c.free(err);
        debug.err("Another window manager is running", .{});
        return error.AnotherWMRunning;
    }
}

fn grabKeybindings(wm: *WM) !void {
    _ = xcb.xcb_ungrab_key(wm.conn, xcb.XCB_GRAB_ANY, wm.root, xcb.XCB_MOD_MASK_ANY);
    const CookieEntry = struct { cookie: xcb.xcb_void_cookie_t, keycode: u8 };
    var cookies: [constants.Sizes.MAX_KEYBIND_COOKIES]CookieEntry = undefined;
    var n: usize = 0;
    for (wm.config.keybindings.items) |kb| {
        const keycode = kb.keycode orelse continue;
        for (constants.LOCK_MODIFIERS) |lock| {
            if (n >= cookies.len) {
                debug.warn("Too many keybindings. Increase Sizes.MAX_KEYBIND_COOKIES (currently {})", .{constants.Sizes.MAX_KEYBIND_COOKIES});
                break;
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

fn maybeReload(wm: *WM) void {
    if (lifecycle.consumeReload())
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
        debug.err("rebuildKeybindMap failed: {}, reverting\n", .{err});
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
    while (true) return iou.get_sqe() catch {
        _ = iou.submit_and_wait(0) catch |err| {
            debug.err("io_uring submit_and_wait failed in getSqe: {s}", .{@errorName(err)});
        };
        continue;
    };
}

fn submitPollAdd(iou: *IoUring, fd: std.posix.fd_t, tag: u64) void {
    getSqe(iou).* = .{
        .opcode       = .POLL_ADD,
        .flags        = 0,
        .ioprio       = 0,
        .fd           = fd,
        .off          = 0,
        .addr         = 0,
        .len          = 0,
        .rw_flags     = std.posix.POLL.IN,
        .user_data    = tag,
        .buf_index    = 0,
        .personality  = 0,
        .splice_fd_in = 0,
        .addr3        = 0,
        .resv         = 0,
    };
}

fn submitClockTimeout(iou: *IoUring, ms: i32) void {
    const ns: i64 = @as(i64, ms) * std.time.ns_per_ms;
    clock_ts = .{
        .sec  = @intCast(@divFloor(ns, std.time.ns_per_s)),
        .nsec = @intCast(@mod(ns, std.time.ns_per_s)),
    };
    getSqe(iou).* = .{
        .opcode       = .TIMEOUT,
        .flags        = 0,
        .ioprio       = 0,
        .fd           = 0,
        .off          = 0,
        .addr         = @intFromPtr(&clock_ts),
        .len          = 1,
        .rw_flags     = 0,
        .user_data    = TAG_CLOCK,
        .buf_index    = 0,
        .personality  = 0,
        .splice_fd_in = 0,
        .addr3        = 0,
        .resv         = 0,
    };
}

// Entry point 

pub fn main() !void {
    const conn = xcb.xcb_connect(null, null) orelse {
        debug.err("Failed to connect to X11 server", .{});
        return error.X11ConnectionFailed;
    };
    defer xcb.xcb_disconnect(conn);

    if (xcb.xcb_connection_has_error(conn) != 0) {
        debug.err("X11 connection has errors", .{});
        return error.X11ConnectionFailed;
    }

    const setup  = xcb.xcb_get_setup(conn);
    const screen = xcb.xcb_setup_roots_iterator(setup).data orelse return error.X11ScreenFailed;
    const root   = screen.*.root;

    try becomeWindowManager(conn, root);
    setupRootCursor(conn, screen);
    input.setupGrabs(conn, root);

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = if (builtin.mode == .Debug) gpa.allocator() else std.heap.c_allocator;

    const dpi_info = try dpi.detect(conn, screen);
    debug.info("DPI Detection - DPI: {d:.1}, Scale: {d:.2}x", .{ dpi_info.dpi, dpi_info.scale_factor });

    const xkb_state = try allocator.create(xkbcommon.XkbState);
    defer allocator.destroy(xkb_state);
    xkb_state.* = try xkbcommon.XkbState.init(conn, allocator);
    defer xkb_state.deinit();

    var user_config = try config.loadConfigDefault(allocator);
    config.resolveKeybindings(user_config.keybindings.items, xkb_state, allocator);
    config.finalizeConfig(&user_config, screen);

    var wm = WM{
        .allocator  = allocator,
        .conn       = conn,
        .screen     = screen,
        .root       = root,
        .config     = user_config,
        .fullscreen = defs.FullscreenState.init(allocator),
        .xkb_state  = xkb_state,
        .dpi_info   = dpi_info,
    };
    defer wm.deinit();

    try utils.initAtomCache(conn);
    utils.initInputModelCache(wm.allocator);
    defer utils.deinitInputModelCache();
    defer layouts.deinitSizeHintsCache(allocator);

    const signal_fd = try setupSignalFd();
    defer std.posix.close(signal_fd);

    try events.initModules(&wm);
    defer events.deinitModules();

    bar.init(&wm) catch |err| {
        if (err != error.BarDisabled) debug.err("Bar init failed: {}", .{err});
    };
    defer bar.deinit();

    bar.updateTimerState();
    try grabKeybindings(&wm);
    _ = xcb.xcb_flush(conn);
    debug.info("Started", .{});

    const x_fd: std.posix.fd_t = xcb.xcb_get_file_descriptor(conn);

    var iou = try IoUring.init(8, 0);
    defer iou.deinit();

    // Submit initial polls.
    submitPollAdd(&iou, x_fd, TAG_XCB);
    submitPollAdd(&iou, signal_fd, TAG_SIGNAL);
    var clock_pending = blk: {
        const ms = bar.pollTimeoutMs();
        if (ms >= 0) { submitClockTimeout(&iou, ms); break :blk true; }
        break :blk false;
    };

    var cqes: [16]std.os.linux.io_uring_cqe = undefined;

    while (lifecycle.running.load(.acquire)) {
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
                else => {},
            }
        }

        if (x_dead or xcb.xcb_connection_has_error(conn) != 0) {
            debug.err("X11 connection error, shutting down", .{});
            break;
        }

        if (saw_xcb) {
            while (xcb.xcb_poll_for_event(conn)) |event| {
                defer std.c.free(event);
                events.dispatch(@as(*u8, @ptrCast(event)).*, event, &wm);
            }
            maybeReload(&wm);
            tiling.retileIfDirty(&wm);
            bar.updateIfDirty(&wm) catch |err| debug.err("Failed to update bar: {}", .{err});
            _ = xcb.xcb_flush(conn);
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
            maybeReload(&wm);
            submitPollAdd(&iou, signal_fd, TAG_SIGNAL);
        }

        if (saw_clock) {
            bar.checkClockUpdate();
            const ms = bar.pollTimeoutMs();
            if (ms >= 0) { submitClockTimeout(&iou, ms); clock_pending = true; }
        }
    }

    debug.info("Shutting down gracefully", .{});
}
