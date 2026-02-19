// Main event loop

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
const focus     = @import("focus");
const tiling    = @import("tiling");
const clock     = @import("clock");
const dpi       = @import("dpi");
const drawing   = @import("drawing");
const constants = @import("constants");

const xcb = defs.xcb;
const WM = defs.WM;

/// Thread-safe: Written by signal handler, read by main loop
var should_reload = std.atomic.Value(bool).init(false);

/// Thread-safe: Written by signal handler, read by main loop  
var running = std.atomic.Value(bool).init(true);

const FDs = struct { signal: posix.fd_t, timer: posix.fd_t };

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
        const bytes_read = posix.read(signal_fd, std.mem.asBytes(&siginfo)) catch break;
        
        if (bytes_read != @sizeOf(std.os.linux.signalfd_siginfo)) break;
        
        switch (siginfo.signo) {
            @intFromEnum(posix.SIG.HUP) => should_reload.store(true, .seq_cst),
            @intFromEnum(posix.SIG.TERM), @intFromEnum(posix.SIG.INT) => running.store(false, .seq_cst),
            else => {},
        }
    }
}

fn setupRootCursor(conn: *xcb.xcb_connection_t, screen: *xcb.xcb_screen_t) void {
    const font = xcb.xcb_generate_id(conn);
    const cursor = xcb.xcb_generate_id(conn);
    _ = xcb.xcb_open_font(conn, font, 6, "cursor");
    _ = xcb.xcb_create_glyph_cursor(conn, cursor, font, font, constants.CURSOR_LEFT_PTR, constants.CURSOR_LEFT_PTR_MASK, 0, 0, 0, 65535, 65535, 65535);
    _ = xcb.xcb_change_window_attributes(conn, screen.*.root, xcb.XCB_CW_CURSOR, &[_]u32{cursor});
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

    const CookieEntry = struct {
        cookie:  xcb.xcb_void_cookie_t,
        keycode: u8,
    };
    // Upper-bound alloc: keybindings without a resolved keycode are skipped below.
    // n tracks actual entries used; the slice may be slightly over-sized.
    const cookies = try wm.allocator.alloc(CookieEntry, wm.config.keybindings.items.len * constants.LOCK_MODIFIERS.len);
    defer wm.allocator.free(cookies);

    // Fire every grab request without waiting for a reply — all requests are
    // written to the output buffer in one shot before any are flushed.
    var n: usize = 0;
    for (wm.config.keybindings.items) |kb| {
        const keycode = kb.keycode orelse continue;
        for (constants.LOCK_MODIFIERS) |lock| {
            cookies[n] = .{
                .cookie = xcb.xcb_grab_key_checked(
                    wm.conn, 0, wm.root,
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

    // Now collect all results.  The first xcb_request_check flushes the buffer
    // and waits; subsequent calls find replies already in the read buffer.
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

/// Initialize the bar, silently ignoring BarDisabled (config opt-out).
fn initBar(wm: *WM) void {
    bar.init(wm) catch |err| {
        if (err != error.BarDisabled) debug.err("Bar init failed: {}", .{err});
    };
}

/// Consume the reload flag and, if set, reload configuration.
fn maybeReload(wm: *WM) void {
    if (should_reload.swap(false, .seq_cst))
        handleConfigReload(wm) catch |err| debug.err("Reload failed: {}", .{err});
}

fn handleConfigReload(wm: *WM) !void {
    debug.info("Reload requested", .{});

    var new_config = config.loadConfigDefault(wm.allocator) catch |err| {
        debug.err("Failed to load: {}, keeping old", .{err});
        return err;
    };
    errdefer new_config.deinit(wm.allocator);

    // Validate config before applying it.
    // master_count must be nonzero or the layout has no master windows.
    // master_width is a ScalableValue (percentage or absolute pixels) and is
    // intentionally not validated here — computeMasterWidth in tiling.zig
    // clamps whatever the parser produces to [MIN_MASTER_WIDTH, MAX_MASTER_WIDTH].
    // Validating .value directly was wrong because a percentage like 50% is
    // stored as 50.0, which would always fail a > 1.0 guard.
    if (new_config.tiling.master_count == 0) {
        debug.err("Invalid config: master_count must be > 0, keeping old", .{});
        return error.InvalidConfig;
    }

    config.resolveKeybindings(new_config.keybindings.items, @ptrCast(@alignCast(wm.xkb_state)));
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
    clock.updateTimerState(wm);

    // Reinitialize the bar — it caches dimensions, fonts, and layout from the
    // config at init time and has no incremental update path.  Deinit destroys
    // the old X11 bar window; init creates a fresh one from the new config.
    bar.deinit();
    initBar(wm);
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

    const setup = xcb.xcb_get_setup(conn);
    const screen = xcb.xcb_setup_roots_iterator(setup).data orelse return error.X11ScreenFailed;
    const root = screen.*.root;

    try becomeWindowManager(conn, root);
    setupRootCursor(conn, screen);
    input.setupGrabs(conn, root);

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = if (builtin.mode == .Debug) gpa.allocator() else std.heap.c_allocator;

    const dpi_info = try dpi.detect(conn, screen);
    debug.info("DPI Detection - DPI: {d:.1}, Scale: {d:.2}x", .{dpi_info.dpi, dpi_info.scale_factor});

    const xkb_state = try allocator.create(xkbcommon.XkbState);
    defer allocator.destroy(xkb_state);
    xkb_state.* = try xkbcommon.XkbState.init(conn, allocator);
    defer xkb_state.deinit();

    var user_config = try config.loadConfigDefault(allocator);
    config.resolveKeybindings(user_config.keybindings.items, xkb_state);
    config.finalizeConfig(&user_config, screen);

    var wm_windows = std.AutoHashMap(u32, void).init(allocator);
    wm_windows.ensureTotalCapacity(constants.Sizes.WINDOW_CAPACITY) catch |err| {
        debug.warn("Failed to pre-allocate window capacity: {}", .{err});
    };

    var wm = WM{
        .allocator = allocator,
        .conn = conn,
        .screen = screen,
        .root = root,
        .config = user_config,
        .windows = wm_windows,
        .focused_window = null,
        .fullscreen = defs.FullscreenState.init(allocator),
        .xkb_state = xkb_state,
        .should_reload_config = &should_reload,
        .running = &running,
        .dpi_info = dpi_info,
    };
    defer wm.deinit();

    try utils.initAtomCache(conn);
    utils.initInputModelCache(wm.allocator);
    defer utils.deinitInputModelCache();
    defer drawing.deinitFontCache(allocator);
    
    const fds = try setupPollFds();
    defer posix.close(fds.signal);
    defer posix.close(fds.timer);
    
    events.initModules(&wm);
    defer events.deinitModules(&wm);

    initBar(&wm);
    defer bar.deinit();

    clock.updateTimerState(&wm);

    try grabKeybindings(&wm);
    _ = xcb.xcb_flush(conn);
    debug.info("Started", .{});

    const x_fd = xcb.xcb_get_file_descriptor(conn);

    var pollfds = [_]posix.pollfd{
        .{ .fd = x_fd, .events = posix.POLL.IN, .revents = 0 },
        .{ .fd = fds.signal, .events = posix.POLL.IN, .revents = 0 },
        .{ .fd = fds.timer, .events = posix.POLL.IN, .revents = 0 },
    };
    
    while (running.load(.acquire)) {
        _ = posix.poll(&pollfds, -1) catch |err| {
            if (err == error.Interrupted) continue;
            debug.err("Poll error: {}", .{err});
            continue;
        };
        
        // X11 events
        if (pollfds[0].revents & posix.POLL.IN != 0) {
            while (xcb.xcb_poll_for_event(conn)) |event| {
                defer std.c.free(event);
                events.dispatch(@as(*u8, @ptrCast(event)).*, event, &wm);
            }

            // Check reload flag here as well as in the signal branch: the
            // .reload_config keybinding sets wm.should_reload_config (which
            // points at the module-level `should_reload`) from the X11 event
            // path, and pollfds[1] only wakes up on SIGHUP — it never fires
            // for a keypress, so without this check the flag would sit set
            // forever and the reload would silently never happen.
            maybeReload(&wm);
            
            tiling.retileIfDirty(&wm);
            bar.updateIfDirty(&wm) catch |err| {
                debug.err("Failed to update bar: {}", .{err});
            };
            _ = xcb.xcb_flush(conn);
        }
        
        // Signals
        if (pollfds[1].revents & posix.POLL.IN != 0) {
            handleSignalFd(fds.signal);
            maybeReload(&wm);
        }
        
        // Timer
        if (pollfds[2].revents & posix.POLL.IN != 0) {
            var expiration: u64 = 0;
            _ = posix.read(fds.timer, std.mem.asBytes(&expiration)) catch {};
            bar.checkClockUpdate();
        }
        
        // Error handling
        if ((pollfds[0].revents & (posix.POLL.ERR | posix.POLL.HUP)) != 0 or
            xcb.xcb_connection_has_error(conn) != 0) {
            debug.err("X11 connection error, shutting down", .{});
            break;
        }
    }

    debug.info("Shutting down gracefully", .{});
}
