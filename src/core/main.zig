//! Main entry point with optimized event loop
const std = @import("std");
const posix = std.posix;
const builtin = @import("builtin");

const config = @import("config");
const defs = @import("defs");
const xkbcommon = @import("xkbcommon");
const events = @import("events");
const input = @import("input");
const utils = @import("utils");

const xcb = defs.xcb;
const WM = defs.WM;

// ============================================================================
// CONSTANTS
// ============================================================================

const WM_EVENT_MASK = xcb.XCB_EVENT_MASK_SUBSTRUCTURE_REDIRECT |
    xcb.XCB_EVENT_MASK_SUBSTRUCTURE_NOTIFY |
    xcb.XCB_EVENT_MASK_KEY_PRESS |
    xcb.XCB_EVENT_MASK_ENTER_WINDOW;

// ============================================================================
// GLOBAL STATE
// ============================================================================

var should_reload = std.atomic.Value(bool).init(false);

// ============================================================================
// SIGNAL HANDLING
// ============================================================================

fn setupSignalHandler() void {
    const handler = struct {
        fn h(_: posix.SIG) callconv(.c) void {
            should_reload.store(true, .release);
        }
    }.h;

    var sa = posix.Sigaction{
        .handler = .{ .handler = handler },
        .mask = std.mem.zeroes(posix.sigset_t),
        .flags = posix.SA.RESTART,
    };
    posix.sigaction(posix.SIG.HUP, &sa, null);
}

// ============================================================================
// X11 SETUP
// ============================================================================

fn setupRootCursor(conn: *xcb.xcb_connection_t, screen: *xcb.xcb_screen_t) void {
    const font = xcb.xcb_generate_id(conn);
    _ = xcb.xcb_open_font(conn, font, 6, "cursor");

    const cursor = xcb.xcb_generate_id(conn);
    _ = xcb.xcb_create_glyph_cursor(conn, cursor, font, font, 68, 69, 0, 0, 0, 65535, 65535, 65535);
    _ = xcb.xcb_change_window_attributes(conn, screen.*.root, xcb.XCB_CW_CURSOR, &[_]u32{cursor});
    _ = xcb.xcb_close_font(conn, font);
}

fn becomeWindowManager(conn: *xcb.xcb_connection_t, root: u32) !void {
    const cookie = xcb.xcb_change_window_attributes_checked(conn, root,
        xcb.XCB_CW_EVENT_MASK, &[_]u32{WM_EVENT_MASK});

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

        // Skip if override-redirect or unmapped
        const attrs_cookie = xcb.xcb_get_window_attributes(conn, win);
        const attrs = xcb.xcb_get_window_attributes_reply(conn, attrs_cookie, null) orelse continue;
        defer std.c.free(attrs);

        if (attrs.*.override_redirect != 0 or attrs.*.map_state != xcb.XCB_MAP_STATE_VIEWABLE) continue;


        // Setup event mask
        _ = xcb.xcb_change_window_attributes(conn, win, xcb.XCB_CW_EVENT_MASK,
            &[_]u32{xcb.XCB_EVENT_MASK_ENTER_WINDOW | xcb.XCB_EVENT_MASK_LEAVE_WINDOW});
    }
}

// ============================================================================
// KEYBINDING MANAGEMENT
// ============================================================================

fn grabKeybindings(wm: *WM) !void {
    _ = xcb.xcb_ungrab_key(wm.conn, xcb.XCB_GRAB_ANY, wm.root, xcb.XCB_MOD_MASK_ANY);

    for (wm.config.keybindings.items) |kb| {
        const keycode = kb.keycode orelse continue;

        // Grab with all lock combinations
        for ([_]u16{ 0, defs.MOD_LOCK, defs.MOD_2, defs.MOD_LOCK | defs.MOD_2 }) |lock| {
            const cookie = xcb.xcb_grab_key_checked(wm.conn, 0, wm.root,
                @intCast(kb.modifiers | lock), keycode,
                xcb.XCB_GRAB_MODE_ASYNC, xcb.XCB_GRAB_MODE_ASYNC);

            if (xcb.xcb_request_check(wm.conn, cookie)) |err| {
                std.c.free(err);
            }
        }
    }

    utils.flush(wm.conn);
}

fn handleConfigReload(wm: *WM) !void {
    var new_config = try config.loadConfigDefault(wm.allocator);
    errdefer new_config.deinit(wm.allocator);

    config.resolveKeybindings(new_config.keybindings.items,
        @ptrCast(@alignCast(wm.xkb_state)));

    wm.config.deinit(wm.allocator);
    wm.config = new_config;

    try grabKeybindings(wm);
    try input.rebuildKeybindMap(wm);

    @import("tiling").reloadConfig(wm);

    std.log.info("[config] Reloaded successfully", .{});
}

// ============================================================================
// MAIN
// ============================================================================

pub fn main() !void {
    // === X11 Connection ===
    const conn = xcb.xcb_connect(null, null) orelse return error.X11ConnectionFailed;
    defer xcb.xcb_disconnect(conn);

    if (xcb.xcb_connection_has_error(conn) != 0) return error.X11ConnectionFailed;

    const setup = xcb.xcb_get_setup(conn);
    const screen = xcb.xcb_setup_roots_iterator(setup).data orelse return error.X11ScreenFailed;
    const root = screen.*.root;

    try becomeWindowManager(conn, root);
    setupRootCursor(conn, screen);
    input.setupGrabs(conn, root);

    // === Allocator ===
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = if (builtin.mode == .Debug) gpa.allocator() else std.heap.c_allocator;

    // === XKB Setup ===
    const xkb_state = try allocator.create(xkbcommon.XkbState);
    defer allocator.destroy(xkb_state);
    xkb_state.* = try xkbcommon.XkbState.init(conn);
    defer xkb_state.deinit();

    // === Config ===
    var user_config = try config.loadConfigDefault(allocator);
    config.resolveKeybindings(user_config.keybindings.items, xkb_state);

    // === WM State ===
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
    };
    defer wm.deinit();

    setupSignalHandler();

    // === Module Initialization ===
    events.initModules(&wm);
    defer events.deinitModules(&wm);

    try grabKeybindings(&wm);
    setupExistingWindows(conn, root);
    utils.flush(conn);

    std.log.info("[hana] Window manager started", .{});

    // === Main Event Loop ===
    while (true) {
        const event = xcb.xcb_wait_for_event(conn) orelse break;
        defer std.c.free(event);

        const event_type = @as(*u8, @ptrCast(event)).*;

        // Check config reload
        if (should_reload.swap(false, .acq_rel)) {
            handleConfigReload(&wm) catch |err| {
                std.log.err("Config reload failed: {}", .{err});
            };
        }

        // Dispatch event - uses comptime jump table for O(1) dispatch
        events.dispatchFast(event_type, event, &wm);

        // Single flush per event
        utils.flush(conn);
    }
}
