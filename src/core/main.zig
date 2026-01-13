// Main event loop

// Imports
const std     = @import("std");
const posix   = std.posix;
const builtin = @import("builtin");

// src/core/
const config         = @import("config");
const defs           = @import("defs");
const xkbcommon      = @import("xkbcommon");
const window_module = @import("window");
const input_module  = @import("input");

// src/debug/
const error_handling = @import("error_handling");
const logging        = @import("logging");

// Convenience renames inherited from central defs import
const xcb = defs.xcb;
const WM  = defs.WM;

// src/modules/

// Constants
const XCB_CURSOR_LEFT_PTR: u16 = 68;
const MAX_EVENT_TYPE: comptime_int = 36;

// Signal flag for config reload (atomic for thread-safety)
var should_reload_config: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);

// Pre-computed event mask constant (compile-time)
const WM_EVENT_MASK = xcb.XCB_EVENT_MASK_SUBSTRUCTURE_REDIRECT |
    xcb.XCB_EVENT_MASK_SUBSTRUCTURE_NOTIFY |
    xcb.XCB_EVENT_MASK_STRUCTURE_NOTIFY |
    xcb.XCB_EVENT_MASK_PROPERTY_CHANGE |
    xcb.XCB_EVENT_MASK_KEY_PRESS |
    xcb.XCB_EVENT_MASK_KEY_RELEASE;

// Cursor setup
fn setupRootCursor(conn: *xcb.xcb_connection_t, screen: *xcb.xcb_screen_t) !void {
    const cursor_font = xcb.xcb_generate_id(conn);
    const font_name = "cursor";
    
    // Use checked calls only in debug mode
    if (builtin.mode == .Debug) {
        const cookie = xcb.xcb_open_font_checked(
            conn,
            cursor_font,
            @intCast(font_name.len),
            font_name.ptr,
        );
        
        if (xcb.xcb_request_check(conn, cookie) != null) {
            logging.debugCursorSetupFailed();
            return error.CursorSetupFailed;
        }
    } else {
        _ = xcb.xcb_open_font(
            conn,
            cursor_font,
            @intCast(font_name.len),
            font_name.ptr,
        );
    }

    const cursor_id = xcb.xcb_generate_id(conn);
    _ = xcb.xcb_create_glyph_cursor(
        conn,
        cursor_id,
        cursor_font,
        cursor_font,
        XCB_CURSOR_LEFT_PTR,
        XCB_CURSOR_LEFT_PTR + 1,
        0, 0, 0,
        65535, 65535, 65535,
    );

    const mask: u32 = xcb.XCB_CW_CURSOR;
    const values = [_]u32{cursor_id};
    _ = xcb.xcb_change_window_attributes(
        conn,
        screen.*.root,
        mask,
        &values,
    );

    _ = xcb.xcb_close_font(conn, cursor_font);

    // No flush here; batched with other operations
}

/// Resolve keysyms to keycodes for all keybindings
fn resolveKeybindings(keybindings: anytype, xkb_state: *xkbcommon.XkbState) void {
    for (keybindings) |*keybind| {
        keybind.keycode = xkb_state.keysymToKeycode(keybind.keysym);
        if (keybind.keycode == null) {
            std.log.warn("Could not find keycode for keysym 0x{x}", .{keybind.keysym});
        }
    }
}

/// Setup signal handler for SIGHUP (config reload)
fn setupSignalHandler() void {
    const sig_handler = struct {
        fn handler(_: posix.SIG) callconv(.c) void {
            should_reload_config.store(true, .release);
        }
    }.handler;

    var sa = posix.Sigaction{
        .handler = .{ .handler = sig_handler },
        .mask = std.mem.zeroes(posix.sigset_t),
        .flags = posix.SA.RESTART, // Auto-restart interrupted syscalls
    };
    posix.sigaction(posix.SIG.HUP, &sa, null);
}

pub fn main() !void {
    // Connect to X11
    const conn = try error_handling.connectToX11();
    defer xcb.xcb_disconnect(@ptrCast(conn));

    const screen = try error_handling.getX11Screen(conn);
    const root = screen.*.root;

    // Become window manager
    try error_handling.becomeWindowManager(conn, root, WM_EVENT_MASK);
    
    try setupRootCursor(conn, screen);

    logging.debugWMStarted();

    // GPA for runtime allocations
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = if (builtin.mode == .Debug) 
        gpa.allocator() 
    else 
        std.heap.c_allocator;

    // Initialize XKB state
    const xkb_state = try allocator.create(xkbcommon.XkbState);
    errdefer allocator.destroy(xkb_state);
    xkb_state.* = try xkbcommon.XkbState.init(conn);
    errdefer xkb_state.deinit();

    // Load config
    var user_config = try config.loadConfig(allocator, "config.toml");
    resolveKeybindings(user_config.keybindings.items, xkb_state);

    // Initialize WM
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

    // Setup signal handler
    setupSignalHandler();

    // Initialize modules
    window_module.init(&wm);
    input_module.init(&wm);
    
    defer {
        window_module.deinit(&wm);
        input_module.deinit(&wm);
    }

    // Grab keybindings
    try grabKeybindings(&wm);

    // Build dispatch table at comptime
    const event_handlers = comptime buildEventHandlerTable();

    // Single flush after all initialization
    _ = xcb.xcb_flush(conn);

    // Event buffer for batch processing (reduce allocations)
    var event_buffer: [32]?*anyopaque = undefined;
    var event_count: usize = 0;
    
    // Main event loop - CRITICAL HOT PATH
    while (true) {
        // Check config reload (cold path - branch predictor friendly)
        if (should_reload_config.load(.acquire)) {
            should_reload_config.store(false, .release);
            handleConfigReload(&wm) catch |err| {
                std.log.err("Config reload failed: {}", .{err});
            };
        }

        // Try to batch multiple events (reduces context switches)
        event_count = 0;
        while (event_count < event_buffer.len) : (event_count += 1) {
            event_buffer[event_count] = xcb.xcb_poll_for_event(conn);
            if (event_buffer[event_count] == null) break;
        }

        // If no events were ready, wait for one
        if (event_count == 0) {
            const event = xcb.xcb_wait_for_event(conn) orelse break;
            event_buffer[0] = event;
            event_count = 1;
        }

        // Process all buffered events
        for (event_buffer[0..event_count]) |maybe_event| {
            const event = maybe_event orelse continue;
            defer std.c.free(event);

            // Fast event dispatch - hot path optimization
            const event_type = @as(*u8, @ptrCast(event)).*;
            const response_type = event_type & ~defs.X11_SYNTHETIC_EVENT_FLAG;

            // Bounds check will be optimized out by compiler due to comptime MAX_EVENT_TYPE
            if (response_type < MAX_EVENT_TYPE) {
                const handler = event_handlers[response_type];
                
                // Inline dispatch - zero function call overhead
                if (handler.window) {
                    window_module.handleEvent(event_type, event, &wm);
                }
                
                if (handler.input) {
                    input_module.handleEvent(event_type, event, &wm);
                }
            }
        }
    }
}

/// Build the event dispatch table at comptime
fn buildEventHandlerTable() [MAX_EVENT_TYPE]EventHandlers {
    var handlers = [_]EventHandlers{.{ .window = false, .input = false }} ** MAX_EVENT_TYPE;
    
    for (window_module.EVENT_TYPES) |event_type| {
        if (event_type < MAX_EVENT_TYPE) {
            handlers[event_type].window = true;
        }
    }
    
    for (input_module.EVENT_TYPES) |event_type| {
        if (event_type < MAX_EVENT_TYPE) {
            handlers[event_type].input = true;
        }
    }
    
    return handlers;
}

// Compact handler flags (fits in single byte)
const EventHandlers = packed struct {
    window: bool,
    input: bool,
};

/// Grab keybindings - optimized batch operation
fn grabKeybindings(wm: *WM) !void {
    _ = xcb.xcb_ungrab_key(wm.conn, xcb.XCB_GRAB_ANY, wm.root, xcb.XCB_MOD_MASK_ANY);

    var grabbed: usize = 0;

    // Batch all grab requests
    for (wm.config.keybindings.items) |keybind| {
        const keycode = keybind.keycode orelse continue;
        
        _ = xcb.xcb_grab_key(
            wm.conn,
            0,
            wm.root,
            @intCast(keybind.modifiers),
            keycode,
            xcb.XCB_GRAB_MODE_ASYNC,
            xcb.XCB_GRAB_MODE_ASYNC,
        );
        grabbed += 1;
    }

    // Single flush
    _ = xcb.xcb_flush(wm.conn);

    logging.debugKeybindingsGrabbed(grabbed);
}

/// Config reload handler
fn handleConfigReload(wm: *WM) !void {
    logging.debugConfigReloading();

    var new_config = try config.loadConfig(wm.allocator, "config.toml");
    errdefer new_config.deinit(wm.allocator);

    const xkb_state: *xkbcommon.XkbState = @ptrCast(@alignCast(wm.xkb_state));
    resolveKeybindings(new_config.keybindings.items, xkb_state);

    wm.config.deinit(wm.allocator);
    wm.config = new_config;
    
    try grabKeybindings(wm);

    logging.debugConfigReloaded();
}
