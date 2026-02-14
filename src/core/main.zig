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

fn handleSignalFd(signal_fd: posix.fd_t, reload_flag: *std.atomic.Value(bool), running_flag: *std.atomic.Value(bool)) void {
    while (true) {
        var siginfo: std.os.linux.signalfd_siginfo = undefined;
        const bytes_read = posix.read(signal_fd, std.mem.asBytes(&siginfo)) catch break;
        
        if (bytes_read != @sizeOf(std.os.linux.signalfd_siginfo)) break;
        
        switch (siginfo.signo) {
            @intFromEnum(posix.SIG.HUP) => reload_flag.store(true, .seq_cst),
            @intFromEnum(posix.SIG.TERM), @intFromEnum(posix.SIG.INT) => running_flag.store(false, .seq_cst),
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

fn setupExistingWindows(conn: *xcb.xcb_connection_t, root: u32, allocator: std.mem.Allocator) !void {
    const reply = xcb.xcb_query_tree_reply(conn, xcb.xcb_query_tree(conn, root), null) orelse return;
    defer std.c.free(reply);

    const children = xcb.xcb_query_tree_children(reply);
    const len: usize = @intCast(xcb.xcb_query_tree_children_length(reply));
    if (len == 0) return;

    const event_mask = xcb.XCB_EVENT_MASK_ENTER_WINDOW | xcb.XCB_EVENT_MASK_LEAVE_WINDOW;
    
    // Use stack allocation for common case (≤32 windows), heap for many
    var stack_cookies: [constants.Sizes.WINDOW_CAPACITY]xcb.xcb_get_window_attributes_cookie_t = undefined;
    const cookies = if (len <= constants.Sizes.WINDOW_CAPACITY) 
        stack_cookies[0..len] 
    else 
        try allocator.alloc(xcb.xcb_get_window_attributes_cookie_t, len);
    defer if (len > constants.Sizes.WINDOW_CAPACITY) allocator.free(cookies);
    
    for (0..len) |i| {
        cookies[i] = xcb.xcb_get_window_attributes(conn, children[i]);
    }
    _ = xcb.xcb_flush(conn);
    
    for (cookies, 0..) |cookie, i| {
        const attrs = xcb.xcb_get_window_attributes_reply(conn, cookie, null) orelse continue;
        defer std.c.free(attrs);
        if (attrs.*.override_redirect != 0 or attrs.*.map_state != xcb.XCB_MAP_STATE_VIEWABLE) continue;
        _ = xcb.xcb_change_window_attributes(conn, children[i], xcb.XCB_CW_EVENT_MASK, &[_]u32{event_mask});
    }
    _ = xcb.xcb_flush(conn);
}

fn grabKeybindings(wm: *WM) !void {
    _ = xcb.xcb_ungrab_key(wm.conn, xcb.XCB_GRAB_ANY, wm.root, xcb.XCB_MOD_MASK_ANY);
    
    var failed_count: usize = 0;
    
    for (wm.config.keybindings.items) |kb| {
        const keycode = kb.keycode orelse continue;
        var failed_this_kb = false;
        
        for (constants.LOCK_MODIFIERS) |lock| {
            const cookie = xcb.xcb_grab_key_checked(
                wm.conn, 0, wm.root,
                @intCast(kb.modifiers | lock), 
                keycode, 
                xcb.XCB_GRAB_MODE_ASYNC, 
                xcb.XCB_GRAB_MODE_ASYNC
            );
            
            if (xcb.xcb_request_check(wm.conn, cookie)) |err| {
                std.c.free(err);
                failed_this_kb = true;
                failed_count += 1;
            }
        }
        
        if (failed_this_kb) {
            debug.warn("Failed to grab keycode: {}", .{keycode});
        }
    }
    
    if (failed_count > 0) {
        debug.warn("{} grab(s) failed", .{failed_count});
    }
    
    _ = xcb.xcb_flush(wm.conn);
}

fn handleConfigReload(wm: *WM) !void {
    debug.info("Reload requested", .{});

    var new_config = config.loadConfigDefault(wm.allocator) catch |err| {
        debug.err("Failed to load: {}, keeping old", .{err});
        return err;
    };
    errdefer new_config.deinit(wm.allocator);

    // Validate config before applying it
    if (new_config.tiling.master_count == 0) {
        debug.err("Invalid config: master_count must be > 0, keeping old", .{});
        return error.InvalidConfig;
    }
    if (new_config.tiling.master_width.value <= 0
    or new_config.tiling.master_width.value > 1.0) {
        debug.err("Invalid config: master_width must be between 0 and 1, keeping old", .{});
        return error.InvalidConfig;
    }

    config.resolveKeybindings(new_config.keybindings.items, @ptrCast(@alignCast(wm.xkb_state)));
    config.finalizeConfig(&new_config, wm.screen);

    var old_config = wm.config;
    wm.config = new_config;

    grabKeybindings(wm) catch |err| {
        debug.err("Keybind grab failed: {}, reverting", .{err});
        new_config.deinit(wm.allocator);
        wm.config = old_config;
        return err;
    };

    old_config.deinit(wm.allocator);
    try input.rebuildKeybindMap(wm);
    tiling.reloadConfig(wm);
    clock.updateTimerState(wm);
    
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
    utils.initWMTakeFocusCache(wm.allocator);
    defer utils.deinitWMTakeFocusCache();
    defer drawing.deinitFontCache(allocator);
    
    const fds = try setupPollFds();
    defer posix.close(fds.signal);
    defer posix.close(fds.timer);
    
    events.initModules(&wm);
    defer events.deinitModules(&wm);

    bar.init(&wm) catch |err| {
        if (err != error.BarDisabled) debug.err("Failed to initialize: {}", .{err});
    };
    defer bar.deinit();

    clock.updateTimerState(&wm);

    try grabKeybindings(&wm);
    try setupExistingWindows(conn, root, allocator);
    _ = xcb.xcb_flush(conn);
    debug.info("Started", .{});

    const x_fd = xcb.xcb_get_file_descriptor(conn);

    var pollfds = [_]posix.pollfd{
        .{ .fd = x_fd, .events = posix.POLL.IN, .revents = 0 },
        .{ .fd = fds.signal, .events = posix.POLL.IN, .revents = 0 },
        .{ .fd = fds.timer, .events = posix.POLL.IN, .revents = 0 },
    };
    
    while (running.load(.seq_cst)) {
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
            
            tiling.retileIfDirty(&wm);
            bar.updateIfDirty(&wm) catch |err| {
                debug.err("Failed to update bar: {}", .{err});
            };
            _ = xcb.xcb_flush(conn);
        }
        
        // Signals
        if (pollfds[1].revents & posix.POLL.IN != 0) {
            handleSignalFd(fds.signal, &should_reload, &running);
            
            if (should_reload.swap(false, .seq_cst)) {
                handleConfigReload(&wm) catch |err| {
                    debug.err("Reload failed: {}", .{err});
                };
            }
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
