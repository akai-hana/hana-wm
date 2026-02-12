// Main event loop - IMPROVED: No event counter management

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
const constants = @import("constants");

const xcb = defs.xcb;
const WM = defs.WM;

// FIXED: Document thread safety guarantees
/// Thread-safe: Written by signal handler, read by main loop
/// Memory ordering: Sequential consistency for cross-thread visibility
var should_reload = std.atomic.Value(bool).init(false);

/// Thread-safe: Written by signal handler, read by main loop  
/// Memory ordering: Sequential consistency for cross-thread visibility
var running = std.atomic.Value(bool).init(true);

const FDs = struct { signal: posix.fd_t, timer: posix.fd_t };

inline fn setupSignalSet() std.os.linux.sigset_t {
    var sigset: std.os.linux.sigset_t = std.mem.zeroes(std.os.linux.sigset_t);
    std.os.linux.sigaddset(&sigset, posix.SIG.HUP);
    std.os.linux.sigaddset(&sigset, posix.SIG.TERM);
    std.os.linux.sigaddset(&sigset, posix.SIG.INT);
    return sigset;
}

fn setupPollFds() !FDs {
    var sigset = setupSignalSet();
    _ = std.os.linux.sigprocmask(posix.SIG.BLOCK, &sigset, null);
    const sfd = std.os.linux.signalfd(-1, &sigset, std.os.linux.SFD.NONBLOCK | std.os.linux.SFD.CLOEXEC);
    if (sfd < 0) return error.SignalFdFailed;
    errdefer posix.close(@intCast(sfd));
    
    const tfd = std.os.linux.timerfd_create(.MONOTONIC, .{ .NONBLOCK = true, .CLOEXEC = true });
    if (tfd < 0) return error.TimerFdFailed;
    
    // OPTIMIZATION: Start with timer disabled - will be enabled if clock is visible
    clock.setTimerFd(@intCast(tfd));
    
    return .{ .signal = @intCast(sfd), .timer = @intCast(tfd) };
}

fn handleSignalFd(signal_fd: posix.fd_t, reload_flag: *std.atomic.Value(bool), running_flag: *std.atomic.Value(bool)) void {
    while (true) {
        var siginfo: std.os.linux.signalfd_siginfo = undefined;
        const bytes_read = posix.read(signal_fd, std.mem.asBytes(&siginfo)) catch break;
        
        if (bytes_read != @sizeOf(std.os.linux.signalfd_siginfo)) break;
        
        switch (siginfo.signo) {
            // FIXED: Use seq_cst for consistency across all atomic operations
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
    _ = xcb.xcb_create_glyph_cursor(conn, cursor, font, font, constants.Cursors.LEFT_PTR, constants.Cursors.LEFT_PTR_MASK, 0, 0, 0, 65535, 65535, 65535);
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

// ============================================================================
// PHASE 2 IMPROVEMENT: Reduced Allocations in setupExistingWindows
// ============================================================================

/// Typical window count - most systems have ≤32 windows at startup
/// This allows zero-allocation fast path for common case
const TYPICAL_WINDOW_COUNT = 32;

fn setupExistingWindows(conn: *xcb.xcb_connection_t, root: u32, allocator: std.mem.Allocator) !void {
    const reply = xcb.xcb_query_tree_reply(conn, xcb.xcb_query_tree(conn, root), null) orelse return;
    defer std.c.free(reply);

    const children = xcb.xcb_query_tree_children(reply);
    const len: usize = @intCast(xcb.xcb_query_tree_children_length(reply));
    if (len == 0) return;

    // PHASE 2 OPTIMIZATION: Use stack allocation for typical case (≤32 windows)
    // Only allocate heap memory if we have more windows than typical
    var cookie_buffer: [TYPICAL_WINDOW_COUNT]xcb.xcb_get_window_attributes_cookie_t = undefined;
    
    // Note: We use a minimal event mask here (enter/leave) for existing windows
    // Full MANAGED_WINDOW mask is applied in window.zig when windows are properly managed
    const event_mask = xcb.XCB_EVENT_MASK_ENTER_WINDOW | xcb.XCB_EVENT_MASK_LEAVE_WINDOW;
    
    if (len <= TYPICAL_WINDOW_COUNT) {
        // Fast path: Use stack allocation (zero heap allocations!)
        for (0..len) |i| {
            cookie_buffer[i] = xcb.xcb_get_window_attributes(conn, children[i]);
        }
        _ = xcb.xcb_flush(conn);
        
        for (cookie_buffer[0..len], 0..) |cookie, i| {
            const attrs = xcb.xcb_get_window_attributes_reply(conn, cookie, null) orelse continue;
            defer std.c.free(attrs);
            if (attrs.*.override_redirect != 0 or attrs.*.map_state != xcb.XCB_MAP_STATE_VIEWABLE) continue;
            _ = xcb.xcb_change_window_attributes(conn, children[i], xcb.XCB_CW_EVENT_MASK, &[_]u32{event_mask});
        }
    } else {
        // Slow path: Need heap allocation for many windows
        const cookies = try allocator.alloc(xcb.xcb_get_window_attributes_cookie_t, len);
        defer allocator.free(cookies);
        
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
    }
    _ = xcb.xcb_flush(conn);
}

fn grabKeybindings(wm: *WM) !void {
    _ = xcb.xcb_ungrab_key(wm.conn, xcb.XCB_GRAB_ANY, wm.root, xcb.XCB_MOD_MASK_ANY);
    
    const max_grabs = wm.config.keybindings.items.len * constants.LOCK_MODIFIERS.len;
    if (max_grabs == 0) return;
    
    const cookies = try wm.allocator.alloc(xcb.xcb_void_cookie_t, max_grabs);
    defer wm.allocator.free(cookies);
    
    var cookie_idx: usize = 0;
    for (wm.config.keybindings.items) |kb| {
        const keycode = kb.keycode orelse continue;
        for (constants.LOCK_MODIFIERS) |lock| {
            cookies[cookie_idx] = xcb.xcb_grab_key_checked(wm.conn, 0, wm.root,
                @intCast(kb.modifiers | lock), keycode, xcb.XCB_GRAB_MODE_ASYNC, xcb.XCB_GRAB_MODE_ASYNC);
            cookie_idx += 1;
        }
    }
    
    utils.flush(wm.conn);
    
    var has_errors = false;
    var failed_count: usize = 0;
    
    for (cookies[0..cookie_idx]) |cookie| {
        if (xcb.xcb_request_check(wm.conn, cookie)) |err| {
            std.c.free(err);
            has_errors = true;
            failed_count += 1;
        }
    }
    
    if (has_errors) {
        debug.warn("{} grab(s) failed, identifying culprits...", .{failed_count});
        
        for (wm.config.keybindings.items) |kb| {
            const keycode = kb.keycode orelse continue;
            var failed_this_kb = false;
            for (constants.LOCK_MODIFIERS) |lock| {
                if (xcb.xcb_request_check(wm.conn, xcb.xcb_grab_key_checked(wm.conn, 0, wm.root,
                    @intCast(kb.modifiers | lock), keycode, xcb.XCB_GRAB_MODE_ASYNC, xcb.XCB_GRAB_MODE_ASYNC))) |err| {
                    std.c.free(err);
                    failed_this_kb = true;
                }
            }
            if (failed_this_kb) {
                debug.warn("Failed to grab keycode: {}", .{keycode});
            }
        }
    }
}

fn handleConfigReload(wm: *WM) !void {
    debug.info("Reload requested", .{});

    var new_config = config.loadConfigDefault(wm.allocator) catch |err| {
        debug.err("Failed to load: {}, keeping old", .{err});
        return err;
    };
    errdefer new_config.deinit(wm.allocator);

    // FIXED: Validate config before applying it
    if (new_config.tiling.master_count == 0) {
        debug.err("Invalid config: master_count must be > 0, keeping old", .{});
        new_config.deinit(wm.allocator);
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
        // FIXED: Don't try grabbing again - just revert and propagate error
        // Trying again could fail and leave us with inconsistent state
        new_config.deinit(wm.allocator);
        wm.config = old_config;
        return err;
    };

    old_config.deinit(wm.allocator);
    try input.rebuildKeybindMap(wm);
    tiling.reloadConfig(wm);
    
    // OPTIMIZATION: Update timer state in case clock visibility changed
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

    // ADDED: Detect DPI and print info
    const dpi_info = try dpi.detect(conn, screen);
    debug.info("DPI Detection - DPI: {d:.1}, Scale: {d:.2}x", .{dpi_info.dpi, dpi_info.scale_factor});

    const xkb_state = try allocator.create(xkbcommon.XkbState);
    defer allocator.destroy(xkb_state);
    xkb_state.* = try xkbcommon.XkbState.init(conn, allocator);
    defer xkb_state.deinit();

    var user_config = try config.loadConfigDefault(allocator);
    config.resolveKeybindings(user_config.keybindings.items, xkb_state);
    config.finalizeConfig(&user_config, screen);

    // OPTIMIZATION: Pre-allocate WM windows hash map
    var wm_windows = std.AutoHashMap(u32, void).init(allocator);
    // FIXED: Log allocation failure instead of silently ignoring it
    wm_windows.ensureTotalCapacity(constants.Sizes.DEFAULT_WINDOW_CAPACITY) catch |err| {
        debug.warn("Failed to pre-allocate window capacity: {}", .{err});
        // Continue with default capacity - not critical for functionality
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
        .dpi_info = dpi_info, // ADDED: Store DPI info in WM
    };
    defer wm.deinit();

    try utils.initAtomCache(conn);
    
    const fds = try setupPollFds();
    defer posix.close(fds.signal);
    defer posix.close(fds.timer);
    
    events.initModules(&wm);
    defer events.deinitModules(&wm);

    bar.init(&wm) catch |err| {
        if (err != error.BarDisabled) debug.err("Failed to initialize: {}", .{err});
    };
    defer bar.deinit();

    // OPTIMIZATION: Enable timer only if clock is visible
    clock.updateTimerState(&wm);

    try grabKeybindings(&wm);
    try setupExistingWindows(conn, root, allocator);
    utils.flush(conn);
    debug.info("Started", .{});

    const x_fd = xcb.xcb_get_file_descriptor(conn);

    var pollfds = [_]posix.pollfd{
        .{ .fd = x_fd, .events = posix.POLL.IN, .revents = 0 },
        .{ .fd = fds.signal, .events = posix.POLL.IN, .revents = 0 },
        .{ .fd = fds.timer, .events = posix.POLL.IN, .revents = 0 },
    };
    
    // IMPROVED: Main loop without event counter management
    // Focus control is now handled through intelligent filtering in EnterNotify
    // FIXED: Use seq_cst for consistency with signal handler stores
    while (running.load(.seq_cst)) {
        _ = posix.poll(&pollfds, -1) catch |err| {
            if (err == error.Interrupted) continue;
            debug.err("Poll error: {}", .{err});
            continue;
        };
        
        // X11 events
        if (pollfds[0].revents & posix.POLL.IN != 0) {
            // Drain all available events
            while (xcb.xcb_poll_for_event(conn)) |event| {
                defer std.c.free(event);
                events.dispatch(@as(*u8, @ptrCast(event)).*, event, &wm);
                
                // REMOVED: Event counter increments
                // The new approach uses pointer tracking and context-aware suppression
                // No need to count events anymore!
            }
            
            // Post-processing
            tiling.retileIfDirty(&wm);
            bar.updateIfDirty(&wm) catch |err| {
                debug.err("Failed to update bar: {}", .{err});
            };
            utils.flush(conn);
        }
        
        // Signals
        if (pollfds[1].revents & posix.POLL.IN != 0) {
            handleSignalFd(fds.signal, &should_reload, &running);
            
            // FIXED: Use seq_cst for consistency with signal handler stores
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
            bar.checkClockUpdate() catch |err| {
                debug.err("Clock update failed: {}", .{err});
            };
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
