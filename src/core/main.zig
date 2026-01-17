//! Main entry point and event loop for Hana window manager.
//!
//! This module handles:
//! - X11 connection setup and screen initialization
//! - XKB keyboard state management
//! - Module initialization and lifecycle
//! - Main event loop with optimized module dispatch
//! - Configuration hot-reloading via SIGHUP

const std = @import("std");
const posix = std.posix;
const builtin = @import("builtin");

const config = @import("config");
const defs = @import("defs");
const xkbcommon = @import("xkbcommon");
const window = @import("window");
const input = @import("input");
const tiling = @import("tiling");
const workspaces = @import("workspaces");
const error_handling = @import("error_handling");
const log = @import("logging");

const xcb = defs.xcb;
const WM = defs.WM;

/// All registered modules that handle X11 events
/// Order matters: workspaces must come before window/tiling to track window lifecycle
const modules = [_]defs.Module{
    defs.generateModule(workspaces),
    defs.generateModule(window),
    defs.generateModule(input),
    defs.generateModule(tiling),
};

/// Atomic flag set by SIGHUP signal OR keybinding to trigger config reload
var should_reload_config_storage = std.atomic.Value(bool).init(false);

/// Event mask for root window - what events we want to receive
const WM_EVENT_MASK = xcb.XCB_EVENT_MASK_SUBSTRUCTURE_REDIRECT |
    xcb.XCB_EVENT_MASK_SUBSTRUCTURE_NOTIFY |
    xcb.XCB_EVENT_MASK_KEY_PRESS |
    xcb.XCB_EVENT_MASK_ENTER_WINDOW;

/// Sets up a left-pointing arrow cursor for the root window
fn setupRootCursor(conn: *xcb.xcb_connection_t, screen: *xcb.xcb_screen_t) void {
    const cursor_font = xcb.xcb_generate_id(conn);
    _ = xcb.xcb_open_font(conn, cursor_font, 6, "cursor");

    const cursor_id = xcb.xcb_generate_id(conn);
    // Cursor 68 (left_ptr) - standard arrow pointer
    _ = xcb.xcb_create_glyph_cursor(conn, cursor_id, cursor_font, cursor_font,
        68, 69, 0, 0, 0, 65535, 65535, 65535);

    _ = xcb.xcb_change_window_attributes(conn, screen.*.root, xcb.XCB_CW_CURSOR, &[_]u32{cursor_id});
    _ = xcb.xcb_close_font(conn, cursor_font);
}

/// Installs SIGHUP handler to trigger config reload
fn setupSignalHandler() void {
    const handler = struct {
        fn h(_: posix.SIG) callconv(.c) void {
            should_reload_config_storage.store(true, .release);
        }
    }.h;

    var sa = posix.Sigaction{
        .handler = .{ .handler = handler },
        .mask = std.mem.zeroes(posix.sigset_t),
        .flags = posix.SA.RESTART,
    };
    posix.sigaction(posix.SIG.HUP, &sa, null);
}

/// Sets up event mask for a client window to track enter/leave events
fn setupWindowEventMask(conn: *xcb.xcb_connection_t, window_id: u32) void {
    const client_mask = xcb.XCB_EVENT_MASK_ENTER_WINDOW | xcb.XCB_EVENT_MASK_LEAVE_WINDOW;
    _ = xcb.xcb_change_window_attributes(conn, window_id, xcb.XCB_CW_EVENT_MASK, &[_]u32{client_mask});
}

pub fn main() !void {
    // === X11 Setup ===
    const conn = try error_handling.connectToX11();
    defer xcb.xcb_disconnect(@ptrCast(conn));

    const screen = try error_handling.getX11Screen(conn);
    const root = screen.*.root;

    try error_handling.becomeWindowManager(conn, root, WM_EVENT_MASK);
    setupRootCursor(conn, screen);
    input.setupGrabs(conn, root);
    log.debugWMStarted();

    // === Memory Setup ===
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = if (builtin.mode == .Debug) gpa.allocator() else std.heap.c_allocator;

    // === XKB Keyboard Setup ===
    const xkb_state = try allocator.create(xkbcommon.XkbState);
    defer allocator.destroy(xkb_state);
    xkb_state.* = try xkbcommon.XkbState.init(conn);
    defer xkb_state.deinit();

    // === Config Loading ===
    var user_config = try config.loadConfigDefault(allocator);
    config.resolveKeybindings(user_config.keybindings.items, xkb_state);

    // === WM State Initialization ===
    var wm = WM{
        .allocator = allocator,
        .conn = conn,
        .screen = screen,
        .root = root,
        .config = user_config,
        .windows = std.AutoHashMap(u32, defs.Window).init(allocator),
        .focused_window = null,
        .xkb_state = xkb_state,
        .should_reload_config = &should_reload_config_storage,
    };
    defer wm.deinit();

    setupSignalHandler();

    // === Module Initialization ===
    var initialized_count: usize = 0;
    errdefer {
        // Clean up already-initialized modules on error
        var i = initialized_count;
        while (i > 0) {
            i -= 1;
            if (modules[i].deinit_fn) |deinit_fn| deinit_fn(&wm);
        }
    }

    inline for (modules) |m| {
        m.init_fn(&wm);
        initialized_count += 1;
    }

    defer {
        var i = initialized_count;
        while (i > 0) {
            i -= 1;
            if (modules[i].deinit_fn) |deinit_fn| deinit_fn(&wm);
        }
    }

    try grabKeybindings(&wm);

    // Setup event masks for any existing windows
    setupExistingWindows(conn, root);

    _ = xcb.xcb_flush(conn);

    // === Main Event Loop ===
    while (true) {
        const event = xcb.xcb_wait_for_event(conn) orelse break;
        defer std.c.free(event);

        const response_type = @as(*u8, @ptrCast(event)).* & 0x7F;

        // Handle config reload if requested
        if (should_reload_config_storage.swap(false, .acq_rel)) {
            handleConfigReload(&wm) catch |err| {
                log.errorConfigReloadFailed(err);
            };
        }

        // Dispatch event to appropriate module(s)
        inline for (modules) |m| {
            inline for (m.event_types) |et| {
                if (et == response_type) {
                    m.handle_fn(response_type, event, &wm);
                    break;
                }
            }
        }

        _ = xcb.xcb_flush(conn);
    }
}

/// Sets up event masks for all windows that existed before we started
fn setupExistingWindows(conn: *xcb.xcb_connection_t, root: u32) void {
    const tree_cookie = xcb.xcb_query_tree(conn, root);
    if (xcb.xcb_query_tree_reply(conn, tree_cookie, null)) |tree_reply| {
        defer std.c.free(tree_reply);
        const children = xcb.xcb_query_tree_children(tree_reply);
        const children_len: usize = @intCast(xcb.xcb_query_tree_children_length(tree_reply));
        for (0..children_len) |i| {
            const win = children[i];
            
            // Get window attributes to filter special windows
            const attrs_cookie = xcb.xcb_get_window_attributes(conn, win);
            const attrs = xcb.xcb_get_window_attributes_reply(conn, attrs_cookie, null) orelse continue;
            defer std.c.free(attrs);
            
            // Skip override-redirect windows (popups, tooltips, etc.)
            if (attrs.*.override_redirect != 0) continue;
            
            // Skip unmapped windows
            if (attrs.*.map_state != xcb.XCB_MAP_STATE_VIEWABLE) continue;
            
            setupWindowEventMask(conn, win);
        }
    }
}

/// Grabs all configured keybindings on the root window
fn grabKeybindings(wm: *WM) !void {
    // Clear any existing grabs
    _ = xcb.xcb_ungrab_key(wm.conn, xcb.XCB_GRAB_ANY, wm.root, xcb.XCB_MOD_MASK_ANY);

    // Grab each keybinding with all lock modifier combinations
    for (wm.config.keybindings.items) |keybind| {
        const keycode = keybind.keycode orelse continue;

        // Grab with CapsLock, NumLock, and both combinations to handle all cases
        inline for ([_]u16{ 0, defs.MOD_LOCK, defs.MOD_2, defs.MOD_LOCK | defs.MOD_2 }) |lock| {
            const cookie = xcb.xcb_grab_key_checked(wm.conn, 0, wm.root,
                @intCast(keybind.modifiers | lock), keycode,
                xcb.XCB_GRAB_MODE_ASYNC, xcb.XCB_GRAB_MODE_ASYNC);
            if (!error_handling.xcbCheckError(wm.conn, cookie, "grab key")) {
                std.log.warn("[keybind] Failed to grab: mod=0x{x} key={}", 
                    .{keybind.modifiers, keycode});
            }
        }
    }
    _ = xcb.xcb_flush(wm.conn);
    log.debugKeybindingsGrabbed(wm.config.keybindings.items.len);
}

/// Reloads configuration from disk and re-grabs keybindings
fn handleConfigReload(wm: *WM) !void {
    log.debugConfigReloading();

    var new_config = try config.loadConfigDefault(wm.allocator);
    errdefer new_config.deinit(wm.allocator);

    config.resolveKeybindings(new_config.keybindings.items, @ptrCast(@alignCast(wm.xkb_state)));

    wm.config.deinit(wm.allocator);
    wm.config = new_config;

    try grabKeybindings(wm);
    try input.rebuildKeybindMap(wm);
    tiling.reloadConfig(wm);
    // Note: Workspace count changes require restart

    log.debugConfigReloaded();
}
