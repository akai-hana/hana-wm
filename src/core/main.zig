// Main WM code loop

const std = @import("std");

// core/
const config = @import("config.zig");
const defs   = @import("defs");

// modules/
const basic_module = @import("basic"); // Basic window management
const input_module = @import("input"); // Mice input management (mouse/kb)

const xcb = @cImport({
    @cInclude("xcb/xcb.h");
});

const WM = defs.WM;
const Config = defs.Config;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Connect to X11
    const conn = xcb.xcb_connect(null, null);
    if (xcb.xcb_connection_has_error(conn) != 0) {
        std.debug.print("Cannot connect to X11\n", .{});
        return error.X11ConnectionFailed;
    }
    defer xcb.xcb_disconnect(conn);

    // Get screen
    const setup = xcb.xcb_get_setup(conn);
    const screen_iter = xcb.xcb_setup_roots_iterator(setup);
    const screen = screen_iter.data;
    const root = screen.*.root;

    // 3. Try to become window manager
    const mask = xcb.XCB_CW_EVENT_MASK;
    const values = [_]u32{
        xcb.XCB_EVENT_MASK_SUBSTRUCTURE_REDIRECT |
            xcb.XCB_EVENT_MASK_SUBSTRUCTURE_NOTIFY |
            xcb.XCB_EVENT_MASK_STRUCTURE_NOTIFY |
            xcb.XCB_EVENT_MASK_PROPERTY_CHANGE,
        };

    const cookie = xcb.xcb_change_window_attributes_checked(conn, root, mask, &values);
    const err = xcb.xcb_request_check(conn, cookie);
    if (err != null) {
        std.debug.print("Another window manager is already running\n", .{});
        return error.AnotherWMRunning;
    }

    std.debug.print("hana window manager started\n", .{});

    // Load config
    const cfg = config.loadConfig(allocator, "config.toml") catch defaults: {
        std.debug.print("Failed to load config, using defaults\n", .{});
        break :defaults Config{
            .border_width = 2,
            .border_color = 0xff0000,
        };
    };

    // Initialize WM
    var wm = WM{
        // Fix: Unwrap 'conn' or return an error if it's null
        .conn = conn orelse return error.X11ConnectionFailed, 
        .screen = screen,
        .root = root,
        .config = cfg,
        .allocator = allocator,
    };

    // Initialize modules
    var modules = std.ArrayList(defs.Module).init(allocator);
    defer modules.deinit();

    // Module appending
    try modules.append(basic_module.createModule());
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

        // Dispatch to modules
        for (modules.items) |*module| {
            module.handleEvent(event_type, event, &wm);
        }

        _ = xcb.xcb_flush(conn);
    }
}
