// Main event loop - clean and minimal

// Imports
const std     = @import("std");
const posix   = std.posix;
const builtin = @import("builtin");

const config         = @import("config");
const defs           = @import("defs");
const xkbcommon      = @import("xkbcommon");
const window         = @import("window");
const input          = @import("input");
const tiling         = @import("tiling");
const error_handling = @import("error_handling");
const logging        = @import("logging");

const xcb = defs.xcb;
const WM  = defs.WM;

// Centralized module registration
// This "converts" the raw files into Module structs automatically
const modules = [_]defs.Module{
    defs.generateModule(window),
    defs.generateModule(input),
    defs.generateModule(tiling),
};

// Config
var should_reload_config: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);

const WM_EVENT_MASK = xcb.XCB_EVENT_MASK_SUBSTRUCTURE_REDIRECT |
    xcb.XCB_EVENT_MASK_SUBSTRUCTURE_NOTIFY |
    xcb.XCB_EVENT_MASK_KEY_PRESS;

fn setupRootCursor(conn: *xcb.xcb_connection_t, screen: *xcb.xcb_screen_t) void {
    const cursor_font = xcb.xcb_generate_id(conn);
    _ = xcb.xcb_open_font(conn, cursor_font, 6, "cursor");

    const cursor_id = xcb.xcb_generate_id(conn);
    _ = xcb.xcb_create_glyph_cursor(conn, cursor_id, cursor_font, cursor_font,
        68, 69, 0, 0, 0, 65535, 65535, 65535);

    _ = xcb.xcb_change_window_attributes(conn, screen.*.root, xcb.XCB_CW_CURSOR, &[_]u32{cursor_id});
    _ = xcb.xcb_close_font(conn, cursor_font);
}

fn setupSignalHandler() void {
    const handler = struct {
        fn h(_: posix.SIG) callconv(.c) void {
            should_reload_config.store(true, .release);
        }
    }.h;

    var sa = posix.Sigaction{
        .handler = .{ .handler = handler },
        .mask = std.mem.zeroes(posix.sigset_t),
        .flags = posix.SA.RESTART,
    };
    posix.sigaction(posix.SIG.HUP, &sa, null);
}

pub fn main() !void {
    const conn = try error_handling.connectToX11();
    defer xcb.xcb_disconnect(@ptrCast(conn));

    const screen = try error_handling.getX11Screen(conn);
    const root = screen.*.root;

    try error_handling.becomeWindowManager(conn, root, WM_EVENT_MASK);
    setupRootCursor(conn, screen);
    input.setupGrabs(conn, root);
    logging.debugWMStarted();

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = if (builtin.mode == .Debug) gpa.allocator() else std.heap.c_allocator;

    const xkb_state = try allocator.create(xkbcommon.XkbState);
    defer allocator.destroy(xkb_state);
    xkb_state.* = try xkbcommon.XkbState.init(conn);
    defer xkb_state.deinit();

    var user_config = try config.loadConfig(allocator, "config.toml");
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
    };
    defer wm.deinit();

    setupSignalHandler();

    inline for (modules) |m| m.init_fn(&wm);
    
    defer {
        comptime var i = modules.len;
        inline while (i > 0) {
            i -= 1;
            if (modules[i].deinit_fn) |deinit| deinit(&wm);
        }
    }

    try grabKeybindings(&wm);
    _ = xcb.xcb_flush(conn);

    // Event loop
    while (true) {
        _ = xcb.xcb_flush(conn);

        if (should_reload_config.swap(false, .acq_rel)) {
            handleConfigReload(&wm) catch |err| {
                std.log.err("Config reload failed: {}", .{err});
            };
        }

        const event = xcb.xcb_wait_for_event(conn) orelse break;
        defer std.c.free(event);

        const response_type = @as(*u8, @ptrCast(event)).* & 0x7F;

        // AUTOMATED ROUTING:
        // This replaces the entire switch (response_type) block
        inline for (modules) |m| {
            if (std.mem.indexOfScalar(u8, m.event_types, response_type)) |_| {
                m.handle_fn(response_type, event, &wm);
            }
        }
    }
}

fn grabKeybindings(wm: *WM) !void {
    _ = xcb.xcb_ungrab_key(wm.conn, xcb.XCB_GRAB_ANY, wm.root, xcb.XCB_MOD_MASK_ANY);

    for (wm.config.keybindings.items) |keybind| {
        const keycode = keybind.keycode orelse continue;
        // Grab with all combinations of lock modifiers (Caps/Num Lock)
        for ([_]u16{ 0, defs.MOD_LOCK, defs.MOD_2, defs.MOD_LOCK | defs.MOD_2 }) |lock| {
            _ = xcb.xcb_grab_key(wm.conn, 0, wm.root,
                @intCast(keybind.modifiers | lock), keycode,
                xcb.XCB_GRAB_MODE_ASYNC, xcb.XCB_GRAB_MODE_ASYNC);
        }
    }
    _ = xcb.xcb_flush(wm.conn);
    logging.debugKeybindingsGrabbed(wm.config.keybindings.items.len);
}

fn handleConfigReload(wm: *WM) !void {
    logging.debugConfigReloading();
    
    var new_config = try config.loadConfig(wm.allocator, "config.toml");
    errdefer new_config.deinit(wm.allocator);

    config.resolveKeybindings(new_config.keybindings.items, @ptrCast(@alignCast(wm.xkb_state)));
    wm.config.deinit(wm.allocator);
    wm.config = new_config;

    try grabKeybindings(wm);
    logging.debugConfigReloaded();
}
