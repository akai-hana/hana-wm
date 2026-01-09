// Main WM code loop
const std = @import("std");
const posix = std.posix; // posix signals handler

// core/
const config = @import("config");
const error_handling = @import("error");
const defs = @import("defs");
// modules/
const window_module = @import("window");
const input_module = @import("input");

// Use xcb from defs to avoid type conflicts
const xcb = defs.xcb;
const WM = defs.WM;

// Global WM instance for signal handling
var global_wm: ?*WM = null;
var should_reload_config: bool = false;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // 1. Connect to X11
    const conn = try error_handling.connectToX11();
    defer xcb.xcb_disconnect(@ptrCast(conn));

    // 2. Get screen
    const screen = try error_handling.getX11Screen(conn);
    const root = screen.*.root;

    // 3. Try to become window manager
    const event_mask = xcb.XCB_EVENT_MASK_SUBSTRUCTURE_REDIRECT |
        xcb.XCB_EVENT_MASK_SUBSTRUCTURE_NOTIFY |
        xcb.XCB_EVENT_MASK_STRUCTURE_NOTIFY |
        xcb.XCB_EVENT_MASK_PROPERTY_CHANGE |
        xcb.XCB_EVENT_MASK_KEY_PRESS |
        xcb.XCB_EVENT_MASK_KEY_RELEASE |
        xcb.XCB_EVENT_MASK_BUTTON_PRESS |
        xcb.XCB_EVENT_MASK_BUTTON_RELEASE;

    try error_handling.becomeWindowManager(conn, root, event_mask);
    std.debug.print("hana window manager started\n", .{});

    // 4. Load config
    const user_config = try config.loadConfig(allocator, "config.toml");

    // 5. Initialize WM
    var wm = WM{
        .allocator = allocator,
        .conn = conn,
        .screen = screen,
        .root = root,
        .config = user_config,
        .windows = .{},
        .focused_window = null,
    };
    defer wm.deinit();

    // Set global WM for signal handler
    global_wm = &wm;

    // Setup signal handler for config reload (SIGHUP)
    const sig_handler = struct {
        fn handler(_: posix.SIG) callconv(.c) void {
            should_reload_config = true;
        }
    }.handler;

    var sa = posix.Sigaction{
        .handler = .{ .handler = sig_handler },
        .mask = std.mem.zeroes(posix.sigset_t),
        .flags = 0,
    };
    posix.sigaction(posix.SIG.HUP, &sa, null);

    // 6. Initialize modules
    var modules = [_]defs.Module{
        window_module.createModule(),
        input_module.createModule(),
    };

    defer {
        for (&modules) |*module| {
            if (module.deinit_fn) |deinit_fn| {
                deinit_fn(&wm);
            }
        }
    }

    for (&modules) |*module| {
        module.init_fn(&wm);
    }

    // Grab keybindings
    try grabKeybindings(&wm);

    // 7. Build event dispatch lookup table (O(1) event routing)
    var event_dispatch = std.AutoHashMap(u8, std.ArrayList(*defs.Module)).init(allocator);
    defer {
        var iter = event_dispatch.valueIterator();
        while (iter.next()) |list| {
            list.deinit(allocator);
        }
        event_dispatch.deinit();
    }

    for (&modules) |*module| {
        for (module.event_types) |event_type| {
            const entry = try event_dispatch.getOrPut(event_type);
            if (!entry.found_existing) {
                entry.value_ptr.* = .{};
            }
            try entry.value_ptr.append(allocator, module);
        }
    }

    // 8. Main event loop
    _ = xcb.xcb_flush(conn);
    while (true) {
        // Check for config reload signal
        if (should_reload_config) {
            try reloadConfig(&wm);
            should_reload_config = false;
        }

        const event = xcb.xcb_wait_for_event(conn);
        if (event == null) break;
        defer std.c.free(event);

        const event_type = @as(*u8, @ptrCast(event)).*;
        const response_type = event_type & ~defs.X11_SYNTHETIC_EVENT_FLAG;

        // O(1) dispatch - only call modules that handle this event
        if (event_dispatch.get(response_type)) |module_list| {
            for (module_list.items) |module| {
                module.handle_fn(event_type, event, &wm);
            }
        }

        _ = xcb.xcb_flush(conn);
    }
}

/// Grab all configured keybindings
fn grabKeybindings(wm: *WM) !void {
    // Ungrab all keys first
    _ = xcb.xcb_ungrab_key(wm.conn, xcb.XCB_GRAB_ANY, wm.root, xcb.XCB_MOD_MASK_ANY);

    // Grab each configured keybinding
    for (wm.config.keybindings.items) |keybind| {
        const cookie = xcb.xcb_grab_key_checked(
            wm.conn,
            0, // don't use owner_events
            wm.root,
            @intCast(keybind.modifiers),
            keybind.keycode,
            xcb.XCB_GRAB_MODE_ASYNC,
            xcb.XCB_GRAB_MODE_ASYNC,
        );

        if (xcb.xcb_request_check(wm.conn, cookie)) |err| {
            std.debug.print("Warning: Failed to grab key (mod={x} key={}): error code {}\n", .{ keybind.modifiers, keybind.keycode, err.*.error_code });
            std.c.free(err);
        }
    }

    std.debug.print("Grabbed {} keybindings\n", .{wm.config.keybindings.items.len});
}

/// Reload configuration file and reapply settings
fn reloadConfig(wm: *WM) !void {
    std.debug.print("Reloading configuration...\n", .{});

    // Load new config
    const new_config = config.loadConfig(wm.allocator, "config.toml") catch |err| {
        std.debug.print("Failed to reload config: {}\n", .{err});
        return;
    };

    // Clean up old config
    wm.config.deinit(wm.allocator);

    // Apply new config
    wm.config = new_config;

    // Regrab keybindings
    try grabKeybindings(wm);

    // Reapply borders to existing windows
    for (wm.windows.items) |win| {
        const is_focused = if (wm.focused_window) |fid| fid == win.id else false;
        const border_color = if (is_focused) wm.config.border_focused else wm.config.border_unfocused;
        try applyWindowBorder(wm, win.id, border_color);
    }

    std.debug.print("Configuration reloaded successfully\n", .{});
}

/// Apply border to window with error checking
fn applyWindowBorder(wm: *WM, window: u32, color: u24) !void {
    const border_mask = xcb.XCB_CONFIG_WINDOW_BORDER_WIDTH;
    const border_values = [_]u32{wm.config.border_width};
    const border_cookie = xcb.xcb_configure_window_checked(wm.conn, window, border_mask, &border_values);
    if (xcb.xcb_request_check(wm.conn, border_cookie)) |err| {
        std.debug.print("Failed to set border width for window {}: error code {}\n", .{ window, err.*.error_code });
        std.c.free(err);
        return error.XCBConfigureFailed;
    }

    const color_mask = xcb.XCB_CW_BORDER_PIXEL;
    const color_values = [_]u32{color};
    const color_cookie = xcb.xcb_change_window_attributes_checked(wm.conn, window, color_mask, &color_values);
    if (xcb.xcb_request_check(wm.conn, color_cookie)) |err| {
        std.debug.print("Failed to set border color for window {}: error code {}\n", .{ window, err.*.error_code });
        std.c.free(err);
        return error.XCBConfigureFailed;
    }
}
