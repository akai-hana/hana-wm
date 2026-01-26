//! Main entry point and event loop.

const std = @import("std");
const posix = std.posix;
const builtin = @import("builtin");

const config = @import("config");
const defs = @import("defs");
const xkbcommon = @import("xkbcommon");
const events = @import("events");
const input = @import("input");
const utils = @import("utils");
const async = @import("async");
const bar = @import("bar");
const workspaces = @import("workspaces");

// Note: bar state module removed from polling system

const xcb = defs.xcb;
const WM = defs.WM;

const WM_EVENT_MASK = xcb.XCB_EVENT_MASK_SUBSTRUCTURE_REDIRECT |
    xcb.XCB_EVENT_MASK_SUBSTRUCTURE_NOTIFY |
    xcb.XCB_EVENT_MASK_KEY_PRESS |
    xcb.XCB_EVENT_MASK_ENTER_WINDOW |
    xcb.XCB_EVENT_MASK_PROPERTY_CHANGE;

const EventFlags = packed struct {
    critical: bool = false,
    batchable: bool = false,
};

const EVENT_FLAGS = blk: {
    var flags = [_]EventFlags{.{}} ** 128;
    flags[xcb.XCB_MAP_REQUEST] = .{ .critical = true };
    flags[xcb.XCB_CONFIGURE_REQUEST] = .{ .critical = true };
    flags[xcb.XCB_KEY_PRESS] = .{ .critical = true };
    flags[xcb.XCB_BUTTON_PRESS] = .{ .critical = true };
    flags[xcb.XCB_BUTTON_RELEASE] = .{ .critical = true };
    flags[xcb.XCB_ENTER_NOTIFY] = .{ .batchable = true };
    flags[xcb.XCB_LEAVE_NOTIFY] = .{ .batchable = true };
    flags[xcb.XCB_FOCUS_IN] = .{ .batchable = true };
    flags[xcb.XCB_FOCUS_OUT] = .{ .batchable = true };
    flags[xcb.XCB_EXPOSE] = .{ .batchable = true };
    break :blk flags;
};

inline fn getEventFlags(event_type: u8) EventFlags {
    return if (event_type < 128) EVENT_FLAGS[event_type] else .{};
}

var should_reload = std.atomic.Value(bool).init(false);
var running = std.atomic.Value(bool).init(true);

fn setupSignalHandler() void {
    const handler = struct {
        fn reload(_: posix.SIG) callconv(.c) void {
            should_reload.store(true, .release);
        }
        fn terminate(_: posix.SIG) callconv(.c) void {
            running.store(false, .release);
        }
    };

    var sa_reload = posix.Sigaction{
        .handler = .{ .handler = handler.reload },
        .mask = std.mem.zeroes(posix.sigset_t),
        .flags = posix.SA.RESTART,
    };
    posix.sigaction(posix.SIG.HUP, &sa_reload, null);

    var sa_term = posix.Sigaction{
        .handler = .{ .handler = handler.terminate },
        .mask = std.mem.zeroes(posix.sigset_t),
        .flags = posix.SA.RESTART,
    };
    posix.sigaction(posix.SIG.TERM, &sa_term, null);
    posix.sigaction(posix.SIG.INT, &sa_term, null);
}

fn setupRootCursor(conn: *xcb.xcb_connection_t, screen: *xcb.xcb_screen_t) void {
    const font = xcb.xcb_generate_id(conn);
    _ = xcb.xcb_open_font(conn, font, 6, "cursor");

    const cursor = xcb.xcb_generate_id(conn);
    _ = xcb.xcb_create_glyph_cursor(conn, cursor, font, font, 68, 69, 0, 0, 0, 65535, 65535, 65535);
    _ = xcb.xcb_change_window_attributes(conn, screen.*.root, xcb.XCB_CW_CURSOR, &[_]u32{cursor});
    _ = xcb.xcb_close_font(conn, font);
}

fn becomeWindowManager(conn: *xcb.xcb_connection_t, root: u32) !void {
    const cookie = xcb.xcb_change_window_attributes_checked(conn, root, xcb.XCB_CW_EVENT_MASK, &[_]u32{WM_EVENT_MASK});
    if (xcb.xcb_request_check(conn, cookie)) |err| {
        std.c.free(err);
        std.log.err("Another window manager is running", .{});
        return error.AnotherWMRunning;
    }
}

fn setupExistingWindows(conn: *xcb.xcb_connection_t, root: u32) void {
    const cookie = xcb.xcb_query_tree(conn, root);
    const reply = xcb.xcb_query_tree_reply(conn, cookie, null) orelse return;
    defer std.c.free(reply);

    const children = xcb.xcb_query_tree_children(reply);
    const len: usize = @intCast(xcb.xcb_query_tree_children_length(reply));

    for (0..len) |i| {
        const win = children[i];
        const attrs_cookie = xcb.xcb_get_window_attributes(conn, win);
        const attrs = xcb.xcb_get_window_attributes_reply(conn, attrs_cookie, null) orelse continue;
        defer std.c.free(attrs);

        if (attrs.*.override_redirect != 0 or attrs.*.map_state != xcb.XCB_MAP_STATE_VIEWABLE) continue;

        _ = xcb.xcb_change_window_attributes(conn, win, xcb.XCB_CW_EVENT_MASK, &[_]u32{xcb.XCB_EVENT_MASK_ENTER_WINDOW | xcb.XCB_EVENT_MASK_LEAVE_WINDOW});
    }
}

fn grabKeybindings(wm: *WM) !void {
    _ = xcb.xcb_ungrab_key(wm.conn, xcb.XCB_GRAB_ANY, wm.root, xcb.XCB_MOD_MASK_ANY);

    for (wm.config.keybindings.items) |kb| {
        const keycode = kb.keycode orelse continue;

        for ([_]u16{ 0, defs.MOD_LOCK, defs.MOD_2, defs.MOD_LOCK | defs.MOD_2 }) |lock| {
            const cookie = xcb.xcb_grab_key_checked(wm.conn, 0, wm.root, @intCast(kb.modifiers | lock), keycode, xcb.XCB_GRAB_MODE_ASYNC, xcb.XCB_GRAB_MODE_ASYNC);
            if (xcb.xcb_request_check(wm.conn, cookie)) |err| std.c.free(err);
        }
    }

    utils.flush(wm.conn);
}

fn handleConfigReload(wm: *WM) !void {
    std.log.info("[config] Reload requested, waiting for pending jobs...", .{});

    const queue = async.getGlobal() orelse return error.AsyncQueueNotInitialized;

    var wait_iterations: usize = 0;
    const max_wait_iterations: usize = 100;
    while (queue.hasPending() and wait_iterations < max_wait_iterations) : (wait_iterations += 1) {
        async.processPending(wm);
        std.posix.nanosleep(0, 1 * std.time.ns_per_ms);
    }

    if (queue.hasPending()) {
        std.log.warn("[config] Timeout waiting for jobs to complete, clearing queue", .{});
        queue.clear();
    }

    var new_config = config.loadConfigDefault(wm.allocator) catch |err| {
        std.log.err("[config] Failed to load new config: {}, keeping old config", .{err});
        return err;
    };
    errdefer new_config.deinit(wm.allocator);

    config.resolveKeybindings(new_config.keybindings.items, @ptrCast(@alignCast(wm.xkb_state)));

    var old_config = wm.config;
    wm.config = new_config;

    grabKeybindings(wm) catch |err| {
        std.log.err("[config] Failed to grab keybindings: {}, reverting to old config", .{err});
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

    @import("tiling").reloadConfig(wm);

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
    xkb_state.* = try xkbcommon.XkbState.init(conn);
    defer xkb_state.deinit();

    var user_config = try config.loadConfigDefault(allocator);
    config.resolveKeybindings(user_config.keybindings.items, xkb_state);

    var wm = WM{
        .allocator = allocator,
        .conn = conn,
        .screen = screen,
        .root = root,
        .config = user_config,
        .windows = std.AutoHashMap(u32, defs.Window).init(allocator),
        .focused_window = null,
        .xkb_state = xkb_state,
        .should_reload_config = &should_reload,
        .running = &running,
    };
    defer wm.deinit();

    try async.initGlobal(allocator);
    defer async.deinitGlobal(allocator);

    setupSignalHandler();
    events.initModules(&wm);
    defer events.deinitModules(&wm);

    bar.init(&wm) catch |err| {
        if (err != error.BarDisabled) {
            std.log.err("[bar] Failed to initialize: {}", .{err});
        }
    };
    defer bar.deinit();

    try grabKeybindings(&wm);
    setupExistingWindows(conn, root);
    utils.flush(conn);

    std.log.info("[hana] Started", .{});

    var batch_count: usize = 0;
    var idle_count: usize = 0;
    var last_flush_time: i64 = 0;
    const FLUSH_INTERVAL_NS: i64 = 16 * std.time.ns_per_ms;

    while (running.load(.acquire)) {
        // Process async jobs
        async.processPending(&wm);

        const event = xcb.xcb_poll_for_event(conn);

        if (xcb.xcb_connection_has_error(conn) != 0) {
            std.log.err("[main] X11 connection error detected, shutting down", .{});
            break;
        }

        if (event) |ev| {
            defer std.c.free(ev);
            idle_count = 0;

            const event_type = @as(*u8, @ptrCast(ev)).*;

            if (should_reload.swap(false, .acq_rel)) {
                handleConfigReload(&wm) catch |err| {
                    std.log.err("[config] Reload failed: {}", .{err});
                };
            }

            events.dispatch(event_type, ev, &wm);

            const flags = getEventFlags(event_type);
            if (flags.critical) {
                utils.flush(conn);
                batch_count = 0;
                if (std.posix.clock_gettime(std.posix.CLOCK.REALTIME)) |ts| {
                    last_flush_time = ts.sec * std.time.ns_per_s + ts.nsec;
                } else |_| {}
            } else if (flags.batchable) {
                batch_count += 1;

                const now = if (std.posix.clock_gettime(std.posix.CLOCK.REALTIME)) |ts|
                    ts.sec * std.time.ns_per_s + ts.nsec
                else |_|
                    last_flush_time;

                if (batch_count >= defs.MAX_EVENT_BATCH_SIZE or
                    (now - last_flush_time) >= FLUSH_INTERVAL_NS)
                {
                    utils.flush(conn);
                    batch_count = 0;
                    last_flush_time = now;
                }
            } else {
                utils.flush(conn);
                batch_count = 0;
                if (std.posix.clock_gettime(std.posix.CLOCK.REALTIME)) |ts| {
                    last_flush_time = ts.sec * std.time.ns_per_s + ts.nsec;
                } else |_| {}
            }
        } else {
            if (batch_count > 0) {
                utils.flush(conn);
                batch_count = 0;
                if (std.posix.clock_gettime(std.posix.CLOCK.REALTIME)) |ts| {
                    last_flush_time = ts.sec * std.time.ns_per_s + ts.nsec;
                } else |_| {}
            }

            if (!async.getGlobal().?.hasPending()) {
                idle_count += 1;
                const sleep_ns = if (idle_count < defs.IDLE_THRESHOLD_SHORT)
                    defs.EVENT_POLL_SLEEP_NS
                else if (idle_count < defs.IDLE_THRESHOLD_LONG)
                    defs.EVENT_POLL_SLEEP_NS * defs.SLEEP_MULTIPLIER_MEDIUM
                else
                    defs.EVENT_POLL_SLEEP_NS * defs.SLEEP_MULTIPLIER_LONG;

                std.posix.nanosleep(0, sleep_ns);
            } else {
                idle_count = 0;
            }
        }
    }

    std.log.info("[hana] Shutting down gracefully", .{});
}
