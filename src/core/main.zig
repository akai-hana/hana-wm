// Main event loop - Event-driven architecture (OPTIMIZED)

const std = @import("std");
const posix = std.posix;
const builtin = @import("builtin");

const config = @import("config");
const defs = @import("defs");
const xkbcommon = @import("xkbcommon");
const events = @import("events");
const input = @import("input");
const utils = @import("utils");
const bar = @import("bar");
const focus = @import("focus");
const tiling = @import("tiling");

const xcb = defs.xcb;
const WM = defs.WM;

const WM_EVENT_MASK = xcb.XCB_EVENT_MASK_SUBSTRUCTURE_REDIRECT |
    xcb.XCB_EVENT_MASK_SUBSTRUCTURE_NOTIFY | xcb.XCB_EVENT_MASK_KEY_PRESS |
    xcb.XCB_EVENT_MASK_ENTER_WINDOW | xcb.XCB_EVENT_MASK_PROPERTY_CHANGE;

const LOCK_MODIFIERS = [_]u16{ 0, defs.MOD_LOCK, defs.MOD_2, defs.MOD_LOCK | defs.MOD_2 };

// Cursor glyph constants for clarity
const CURSOR_LEFT_PTR = 68;
const CURSOR_LEFT_PTR_MASK = 69;

var should_reload = std.atomic.Value(bool).init(false);
var running = std.atomic.Value(bool).init(true);

fn setupSignalFd() !posix.fd_t {
    // Block signals so they don't interrupt - we'll handle via signalfd
    var sigset: std.os.linux.sigset_t = std.mem.zeroes(std.os.linux.sigset_t);
    std.os.linux.sigaddset(&sigset, posix.SIG.HUP);
    std.os.linux.sigaddset(&sigset, posix.SIG.TERM);
    std.os.linux.sigaddset(&sigset, posix.SIG.INT);
    
    _ = std.os.linux.sigprocmask(posix.SIG.BLOCK, &sigset, null);
    
    // Create signalfd - use raw flags (not a struct like timerfd)
    const sfd = std.os.linux.signalfd(-1, &sigset, std.os.linux.SFD.NONBLOCK | std.os.linux.SFD.CLOEXEC);
    if (sfd < 0) return error.SignalFdFailed;
    
    return @intCast(sfd);
}

fn setupTimerFd() !posix.fd_t {
    const tfd = std.os.linux.timerfd_create(.MONOTONIC, .{ .NONBLOCK = true, .CLOEXEC = true });
    if (tfd < 0) return error.TimerFdFailed;
    
    const spec = std.os.linux.itimerspec{
        .it_interval = .{ .sec = 1, .nsec = 0 },
        .it_value = .{ .sec = 1, .nsec = 0 },
    };
    
    if (std.os.linux.timerfd_settime(@intCast(tfd), .{}, &spec, null) < 0) {
        posix.close(@intCast(tfd));
        return error.TimerFdSetFailed;
    }
    
    return @intCast(tfd);
}

fn handleSignalFd(signal_fd: posix.fd_t, reload_flag: *std.atomic.Value(bool), running_flag: *std.atomic.Value(bool)) void {
    // Drain all pending signals (multiple may have arrived)
    while (true) {
        var siginfo: std.os.linux.signalfd_siginfo = undefined;
        const bytes_read = posix.read(signal_fd, std.mem.asBytes(&siginfo)) catch break;
        
        if (bytes_read != @sizeOf(std.os.linux.signalfd_siginfo)) break;
        
        // Inline signal comparisons for efficiency
        switch (siginfo.signo) {
            @intFromEnum(posix.SIG.HUP) => reload_flag.store(true, .release),
            @intFromEnum(posix.SIG.TERM), @intFromEnum(posix.SIG.INT) => running_flag.store(false, .release),
            else => {},
        }
    }
}

fn setupRootCursor(conn: *xcb.xcb_connection_t, screen: *xcb.xcb_screen_t) void {
    const font = xcb.xcb_generate_id(conn);
    _ = xcb.xcb_open_font(conn, font, 6, "cursor");
    const cursor = xcb.xcb_generate_id(conn);
    _ = xcb.xcb_create_glyph_cursor(conn, cursor, font, font, 
        CURSOR_LEFT_PTR, CURSOR_LEFT_PTR_MASK, 0, 0, 0, 65535, 65535, 65535);
    _ = xcb.xcb_change_window_attributes(conn, screen.*.root, xcb.XCB_CW_CURSOR, &[_]u32{cursor});
    _ = xcb.xcb_close_font(conn, font);
}

fn becomeWindowManager(conn: *xcb.xcb_connection_t, root: u32) !void {
    if (xcb.xcb_request_check(conn, xcb.xcb_change_window_attributes_checked(
        conn, root, xcb.XCB_CW_EVENT_MASK, &[_]u32{WM_EVENT_MASK}))) |err| {
        std.c.free(err);
        std.log.err("Another window manager is running", .{});
        return error.AnotherWMRunning;
    }
}

fn setupExistingWindows(conn: *xcb.xcb_connection_t, root: u32) void {
    const reply = xcb.xcb_query_tree_reply(conn, xcb.xcb_query_tree(conn, root), null) orelse return;
    defer std.c.free(reply);

    const children = xcb.xcb_query_tree_children(reply);
    const len: usize = @intCast(xcb.xcb_query_tree_children_length(reply));
    if (len == 0) return;

    const MAX_BATCH = 256;
    var cookies: [MAX_BATCH]xcb.xcb_get_window_attributes_cookie_t = undefined;
    
    var processed: usize = 0;
    while (processed < len) {
        const batch_size = @min(len - processed, MAX_BATCH);
        
        // Queue all requests in this batch
        for (0..batch_size) |i| {
            cookies[i] = xcb.xcb_get_window_attributes(conn, children[processed + i]);
        }
        _ = xcb.xcb_flush(conn);

        // Process replies
        for (0..batch_size) |i| {
            const attrs = xcb.xcb_get_window_attributes_reply(conn, cookies[i], null) orelse continue;
            defer std.c.free(attrs);
            
            if (attrs.*.override_redirect != 0 or attrs.*.map_state != xcb.XCB_MAP_STATE_VIEWABLE) continue;
            
            _ = xcb.xcb_change_window_attributes(conn, children[processed + i], xcb.XCB_CW_EVENT_MASK,
                &[_]u32{xcb.XCB_EVENT_MASK_ENTER_WINDOW | xcb.XCB_EVENT_MASK_LEAVE_WINDOW});
        }
        
        processed += batch_size;
    }
}

fn grabKeybindings(wm: *WM) !void {
    _ = xcb.xcb_ungrab_key(wm.conn, xcb.XCB_GRAB_ANY, wm.root, xcb.XCB_MOD_MASK_ANY);
    
    var failed_count: usize = 0;
    
    for (wm.config.keybindings.items) |kb| {
        const keycode = kb.keycode orelse continue;
        for (LOCK_MODIFIERS) |lock| {
            if (xcb.xcb_request_check(wm.conn, xcb.xcb_grab_key_checked(wm.conn, 0, wm.root,
                @intCast(kb.modifiers | lock), keycode, xcb.XCB_GRAB_MODE_ASYNC, xcb.XCB_GRAB_MODE_ASYNC))) |err| {
                std.c.free(err);
                failed_count += 1;
            }
        }
    }
    
    if (failed_count > 0) {
        std.log.warn("[keybind] {} key grab(s) failed", .{failed_count});
    }
    
    utils.flush(wm.conn);
}

fn handleConfigReload(wm: *WM) !void {
    std.log.info("[config] Reload requested", .{});

    var new_config = config.loadConfigDefault(wm.allocator) catch |err| {
        std.log.err("[config] Failed to load: {}, keeping old config", .{err});
        return err;
    };
    errdefer new_config.deinit(wm.allocator);

    config.resolveKeybindings(new_config.keybindings.items, @ptrCast(@alignCast(wm.xkb_state)));

    var old_config = wm.config;
    wm.config = new_config;

    grabKeybindings(wm) catch |err| {
        std.log.err("[config] Failed to grab keybindings: {}, reverting", .{err});
        new_config.deinit(wm.allocator);
        wm.config = old_config;
        try grabKeybindings(wm);
        return err;
    };

    old_config.deinit(wm.allocator);
    input.rebuildKeybindMap(wm) catch |err| {
        std.log.err("[config] Failed to rebuild keybind map: {}", .{err});
        return err;
    };
    tiling.reloadConfig(wm);
    std.log.info("[config] Reload complete", .{});
}

pub fn main() !void {
    const conn = xcb.xcb_connect(null, null) orelse return error.X11ConnectionFailed;
    defer xcb.xcb_disconnect(conn);
    if (xcb.xcb_connection_has_error(conn) != 0) return error.X11ConnectionFailed;

    const setup = xcb.xcb_get_setup(conn);
    const screen = xcb.xcb_setup_roots_iterator(setup).data orelse return error.X11ScreenFailed;
    const root = screen.*.root;

    try becomeWindowManager(conn, root);
    setupRootCursor(conn, screen);
    input.setupGrabs(conn, root);

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = if (builtin.mode == .Debug) gpa.allocator() else std.heap.c_allocator;

    const xkb_state = try allocator.create(xkbcommon.XkbState);
    defer allocator.destroy(xkb_state);
    xkb_state.* = try xkbcommon.XkbState.init(conn, allocator);
    defer xkb_state.deinit();

    var user_config = try config.loadConfigDefault(allocator);
    config.resolveKeybindings(user_config.keybindings.items, xkb_state);

    var wm = WM{
        .allocator = allocator,
        .conn = conn,
        .screen = screen,
        .root = root,
        .config = user_config,
        .windows = std.AutoHashMap(u32, void).init(allocator),
        .focused_window = null,
        .fullscreen = defs.FullscreenState.init(allocator),
        .xkb_state = xkb_state,
        .should_reload_config = &should_reload,
        .running = &running,
    };
    defer wm.deinit();

    try utils.initAtomCache(conn);
    
    const signal_fd = try setupSignalFd();
    defer posix.close(signal_fd);
    
    const timer_fd = try setupTimerFd();
    defer posix.close(timer_fd);
    
    events.initModules(&wm);
    defer events.deinitModules(&wm);

    bar.init(&wm) catch |err| {
        if (err != error.BarDisabled) std.log.err("[bar] Failed to initialize: {}", .{err});
    };
    defer bar.deinit();

    try grabKeybindings(&wm);
    setupExistingWindows(conn, root);
    utils.flush(conn);
    std.log.info("[hana] Started", .{});

    const x_fd = xcb.xcb_get_file_descriptor(conn);

    var pollfds = [_]posix.pollfd{
        .{ .fd = x_fd, .events = posix.POLL.IN, .revents = 0 },
        .{ .fd = signal_fd, .events = posix.POLL.IN, .revents = 0 },
        .{ .fd = timer_fd, .events = posix.POLL.IN, .revents = 0 },
    };
    
    while (running.load(.acquire)) {
        // Block until activity on any fd - true zero-CPU idle
        _ = posix.poll(&pollfds, -1) catch |err| {
            if (err == error.Interrupted) continue;
            std.log.err("[main] Poll error: {}", .{err});
            continue;
        };
        
        // Handle X11 events (drain all available)
        if (pollfds[0].revents & posix.POLL.IN != 0) {
            var events_handled: u32 = 0;
            while (xcb.xcb_poll_for_event(conn)) |event| {
                defer std.c.free(event);
                events_handled += 1;
                events.dispatch(@as(*u8, @ptrCast(event)).*, event, &wm);
            }
            
            if (events_handled > 0) {
                focus.releaseProtection();
                tiling.retileIfDirty(&wm);
                bar.updateIfDirty(&wm) catch |err| {
                    std.log.err("[main] Failed to update bar: {}", .{err});
                };
                utils.flush(conn);
            }
        }
        
        // Handle signals (drain all pending)
        if (pollfds[1].revents & posix.POLL.IN != 0) {
            handleSignalFd(signal_fd, &should_reload, &running);
            
            if (should_reload.swap(false, .acq_rel)) {
                handleConfigReload(&wm) catch |err| {
                    std.log.err("[config] Reload failed: {}", .{err});
                };
            }
        }
        
        // Handle timer
        if (pollfds[2].revents & posix.POLL.IN != 0) {
            var expiration: u64 = 0;
            _ = posix.read(timer_fd, std.mem.asBytes(&expiration)) catch {};
            bar.checkClockUpdate() catch |err| {
                std.log.err("[bar] Clock update failed: {}", .{err});
            };
        }
        
        // Check connection health only if we saw POLLERR/POLLHUP
        if ((pollfds[0].revents & (posix.POLL.ERR | posix.POLL.HUP)) != 0 or
            xcb.xcb_connection_has_error(conn) != 0) {
            std.log.err("[main] X11 connection error, shutting down", .{});
            break;
        }
        
        // Note: poll() automatically resets revents, no manual reset needed
    }

    std.log.info("[hana] Shutting down gracefully", .{});
}
