// Main WM code loop

const std = @import("std");

// hana version
const VERSION = "0.1.1";

// core/
const config = @import("config.zig");
const defs = @import("defs");

// modules/
const window_module = @import("window");
const input_module = @import("input");

const xcb = @cImport({
    @cInclude("xcb/xcb.h");
});

const WM = defs.WM;
const Config = defs.Config;

fn defaultConfig() Config {
    return Config{
        .border_width = 2,
        .border_color = 0xff0000,
    };
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Connect to X11
    const conn = xcb.xcb_connect(null, null);
    if (xcb.xcb_connection_has_error(conn) != 0) {
        std.debug.print("Failed to connect to X11 display server\n", .{});
        return error.X11ConnectionFailed;
    }
    defer xcb.xcb_disconnect(conn);

    // Get screen
    const setup = xcb.xcb_get_setup(conn);
    const screen_iter = xcb.xcb_setup_roots_iterator(setup);
    const screen = screen_iter.data;
    if (screen == null) {
        std.debug.print("Failed to get X11 screen\n", .{});
        return error.X11ScreenFailed;
    }
    const root = screen.*.root;

    // Try to become window manager
    const mask = xcb.XCB_CW_EVENT_MASK;
    const values = [_]u32{
        xcb.XCB_EVENT_MASK_SUBSTRUCTURE_REDIRECT |
            xcb.XCB_EVENT_MASK_SUBSTRUCTURE_NOTIFY |
            xcb.XCB_EVENT_MASK_STRUCTURE_NOTIFY |
            xcb.XCB_EVENT_MASK_PROPERTY_CHANGE |
            xcb.XCB_EVENT_MASK_KEY_PRESS |
            xcb.XCB_EVENT_MASK_KEY_RELEASE |
            xcb.XCB_EVENT_MASK_BUTTON_PRESS |
            xcb.XCB_EVENT_MASK_BUTTON_RELEASE,
        };

    const cookie = xcb.xcb_change_window_attributes_checked(conn, root, mask, &values);
    const err = xcb.xcb_request_check(conn, cookie);
    if (err != null) {
        std.debug.print("Another window manager is already running\n", .{});
        return error.AnotherWMRunning;
    }

    std.debug.print("hana window manager v{s} started\n", .{VERSION});

    // Load config
    const user_config = config.loadConfig(allocator, "config.toml") catch blk: {
        std.debug.print("Failed to load config, using defaults\n", .{});
        break :blk defaultConfig();
    };

    // Initialize WM
    var wm = WM{
        .conn = conn,
        .screen = screen,
        .root = root,
        .config = user_config,
        .allocator = allocator,
    };

    // Initialize modules
    var modules = std.ArrayList(defs.Module).init(allocator);
    defer modules.deinit();

    try modules.append(window_module.createModule());
    try modules.append(input_module.createModule());

    for (modules.items) |*module| {
        module.init(&wm);
    }

    // Main event loop
    _ = xcb.xcb_flush(conn);

    while (true) {
        const event = xcb.xcb_wait_for_event(conn);
        if (event == null) break;
        defer std.c.free(event);

        const event_type = @as(*u8, @ptrCast(event)).*;
        const response_type = event_type & ~defs.X11_SYNTHETIC_EVENT_FLAG;

        // Dispatch to modules (only call modules that handle this event, for optimization purposes)
        for (modules.items) |*module| {
            // Check if this module handles this event type
            var handles = false;
            for (module.events) |ev| {
                if (ev == response_type) {
                    handles = true;
                    break;
                }
            }
            if (!handles) continue;

            module.handleEvent(event_type, event, &wm);
        }

        _ = xcb.xcb_flush(conn);
    }
}
