//! Main event loop.

const std     = @import("std");
const posix   = std.posix;
const builtin = @import("builtin");

const debug     = @import("debug");
const config    = @import("config");
const defs      = @import("defs");
const xkbcommon = @import("xkbcommon");
const events    = @import("events");
const input     = @import("input");
const utils     = @import("utils");
const bar       = @import("bar");
const tiling    = @import("tiling");
const layouts   = @import("layouts");
const clock     = @import("clock");
const dpi       = @import("dpi");
const drawing   = @import("drawing");
const constants  = @import("constants");
const c_bindings = @import("c_bindings");
const lifecycle  = @import("lifecycle");

const xcb = defs.xcb;
const WM  = defs.WM;

const FDs = struct { signal: posix.fd_t, timer: posix.fd_t };

/// Creates a signalfd (for SIGHUP / SIGTERM / SIGINT) and a timerfd for the clock module.
fn setupPollFds() !FDs {
    var sigset: std.os.linux.sigset_t = std.mem.zeroes(std.os.linux.sigset_t);
    std.os.linux.sigaddset(&sigset, posix.SIG.HUP);
    std.os.linux.sigaddset(&sigset, posix.SIG.TERM);
    std.os.linux.sigaddset(&sigset, posix.SIG.INT);
    _ = std.os.linux.sigprocmask(posix.SIG.BLOCK, &sigset, null);

    const sfd = std.os.linux.signalfd(-1, &sigset, std.os.linux.SFD.NONBLOCK | std.os.linux.SFD.CLOEXEC);
    if (sfd < 0) return error.SignalFdFailed;
    errdefer posix.close(@intCast(sfd));

    const tfd = std.os.linux.timerfd_create(.MONOTONIC, .{ .NONBLOCK = true, .CLOEXEC = true });
    if (tfd < 0) return error.TimerFdFailed;

    clock.setTimerFd(@intCast(tfd));
    return .{ .signal = @intCast(sfd), .timer = @intCast(tfd) };
}

fn handleSignalFd(signal_fd: posix.fd_t) void {
    while (true) {
        var siginfo: std.os.linux.signalfd_siginfo = undefined;
        const n = posix.read(signal_fd, std.mem.asBytes(&siginfo)) catch break;
        if (n != @sizeOf(std.os.linux.signalfd_siginfo)) break;

        switch (siginfo.signo) {
            @intFromEnum(posix.SIG.HUP)  => lifecycle.reload(),
            @intFromEnum(posix.SIG.TERM),
            @intFromEnum(posix.SIG.INT)  => lifecycle.quit(),
            else => {},
        }
    }
}

fn setupRootCursor(conn: *xcb.xcb_connection_t, screen: *xcb.xcb_screen_t) void {
    // Try xcb-cursor first: reads Xcursor.theme + Xcursor.size from Xresources
    // and loads the fully-themed cursor, matching what client windows display.
    var ctx: *c_bindings.xcb_cursor_context_t = undefined;
    if (c_bindings.xcb_cursor_context_new(conn, screen, &ctx) >= 0) {
        defer c_bindings.xcb_cursor_context_free(ctx);
        const cursor = c_bindings.xcb_cursor_load_cursor(ctx, "left_ptr");
        if (cursor != 0) {
            _ = xcb.xcb_change_window_attributes(conn, screen.*.root,
                    xcb.XCB_CW_CURSOR, &[_]u32{cursor});
            return;
        }
        debug.warn("xcb-cursor: left_ptr load failed, falling back to bitmap cursor", .{});
    } else {
        debug.warn("xcb-cursor: context init failed, falling back to bitmap cursor", .{});
    }

    // Fallback: plain bitmap cursor from the built-in X11 cursor font.
    // Correct shape but ignores the user's Xcursor theme.
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

/// Registers as the window manager on `root`. Returns `error.AnotherWMRunning` if taken.
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
    // Upper-bound alloc; n tracks actual entries used.
    const cookies = try wm.allocator.alloc(CookieEntry, wm.config.keybindings.items.len * constants.LOCK_MODIFIERS.len);
    defer wm.allocator.free(cookies);

    // Fire all grab requests before waiting for any reply (one write pass, then one read pass).
    var n: usize = 0;
    for (wm.config.keybindings.items) |kb| {
        const keycode = kb.keycode orelse continue;
        for (constants.LOCK_MODIFIERS) |lock| {
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

/// Consumes the reload flag and, if set, reloads the configuration.
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
    errdefer new_config.deinit(wm.allocator);

    // master_count must be non-zero; master_width is clamped by the tiling module.
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
        return err; // errdefer fires here — frees new_config exactly once
    };

    old_config.deinit(wm.allocator);
    try input.rebuildKeybindMap(wm);
    tiling.reloadConfig(wm);
    clock.updateTimerState();
    // The bar caches dimensions, fonts, and layout at init time; reload recreates it.
    bar.reload(wm);
    debug.info("Reload complete", .{});
}

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
    defer drawing.deinitFontCache(allocator);
    defer layouts.deinitSizeHintsCache(allocator);

    const fds = try setupPollFds();
    defer posix.close(fds.signal);
    defer posix.close(fds.timer);

    try events.initModules(&wm);
    defer events.deinitModules();

    bar.init(&wm) catch |err| {
        if (err != error.BarDisabled) debug.err("Bar init failed: {}", .{err});
    };
    defer bar.deinit();

    clock.updateTimerState();
    try grabKeybindings(&wm);
    _ = xcb.xcb_flush(conn);
    debug.info("Started", .{});

    const x_fd = xcb.xcb_get_file_descriptor(conn);
    var pollfds = [_]posix.pollfd{
        .{ .fd = x_fd,       .events = posix.POLL.IN, .revents = 0 },
        .{ .fd = fds.signal, .events = posix.POLL.IN, .revents = 0 },
        .{ .fd = fds.timer,  .events = posix.POLL.IN, .revents = 0 },
    };

    while (lifecycle.running.load(.acquire)) {
        _ = posix.poll(&pollfds, -1) catch |err| {
            if (err == error.Interrupted) continue;
            debug.err("Poll error: {}", .{err});
            continue;
        };

        // Detect a dead X11 connection before dispatching events.
        if ((pollfds[0].revents & (posix.POLL.ERR | posix.POLL.HUP)) != 0 or
            xcb.xcb_connection_has_error(conn) != 0) {
            debug.err("X11 connection error, shutting down", .{});
            break;
        }

        // X11 events
        if (pollfds[0].revents & posix.POLL.IN != 0) {
            while (xcb.xcb_poll_for_event(conn)) |event| {
                defer std.c.free(event);
                events.dispatch(@as(*u8, @ptrCast(event)).*, event, &wm);
            }
            // The .reload_config keybinding sets should_reload from the X11 path;
            // pollfds[1] only wakes on SIGHUP, so we must also check here.
            maybeReload(&wm);
            tiling.retileIfDirty(&wm);
            bar.updateIfDirty(&wm) catch |err| debug.err("Failed to update bar: {}", .{err});
            _ = xcb.xcb_flush(conn);
        }

        // Signals
        if (pollfds[1].revents & posix.POLL.IN != 0) {
            handleSignalFd(fds.signal);
            maybeReload(&wm);
        }

        // Timer (clock tick)
        if (pollfds[2].revents & posix.POLL.IN != 0) {
            var expiration: u64 = 0;
            _ = posix.read(fds.timer, std.mem.asBytes(&expiration)) catch {};
            bar.checkClockUpdate();
        }
    }

    debug.info("Shutting down gracefully", .{});
}
