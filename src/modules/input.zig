// Input handling - captures keyboard and mouse events

const std = @import("std");
const defs = @import("defs");
const xkbcommon = @import("xkbcommon");
const builtin = @import("builtin");

const c = @cImport({
    @cInclude("unistd.h");
});

// Use xcb from defs to avoid type conflicts
const xcb = defs.xcb;

const WM = defs.WM;
const Module = defs.Module;

// Toggle debug logging (set to false for production)
const ENABLE_INPUT_DEBUG = false;

// Events this module handles
pub const EVENT_TYPES = [_]u8{
    xcb.XCB_KEY_PRESS,
    xcb.XCB_KEY_RELEASE,
    xcb.XCB_BUTTON_PRESS,
    xcb.XCB_BUTTON_RELEASE,
    xcb.XCB_MOTION_NOTIFY,
};

pub fn init(_: *WM) void {
    if (builtin.mode == .Debug) {
        std.debug.print("[input] Module initialized\n", .{});
    }
}

pub const deinit = defs.defaultModuleDeinit;

pub fn handleEvent(event_type: u8, event: *anyopaque, wm: *WM) void {
    const response_type = event_type & ~defs.X11_SYNTHETIC_EVENT_FLAG;

    switch (response_type) {
        xcb.XCB_KEY_PRESS => {
            const ev = @as(*const xcb.xcb_key_press_event_t, @alignCast(@ptrCast(event)));
            handleKeyPress(ev, wm);
        },

        xcb.XCB_KEY_RELEASE => {
            // Key releases are high-frequency and rarely useful
            // Uncomment if you need key release handling
            // const ev = @as(*const xcb.xcb_key_release_event_t, @alignCast(@ptrCast(event)));
            // handleKeyRelease(ev, wm);
        },

        xcb.XCB_BUTTON_PRESS => {
            const ev = @as(*const xcb.xcb_button_press_event_t, @alignCast(@ptrCast(event)));
            handleButtonPress(ev, wm);
        },

        xcb.XCB_BUTTON_RELEASE => {
            const ev = @as(*const xcb.xcb_button_release_event_t, @alignCast(@ptrCast(event)));
            handleButtonRelease(ev, wm);
        },

        xcb.XCB_MOTION_NOTIFY => {
            const ev = @as(*const xcb.xcb_motion_notify_event_t, @alignCast(@ptrCast(event)));
            handleMotion(ev, wm);
        },

        else => {},
    }
}

fn handleKeyPress(event: *const xcb.xcb_key_press_event_t, wm: *WM) void {
    const keycode = event.detail;
    const modifiers: u16 = @intCast(event.state);

    // Get XKB state and convert keycode to keysym
    const xkb_ptr: *xkbcommon.XkbState = @ptrCast(@alignCast(wm.xkb_state.?));
    const keysym = xkb_ptr.keycodeToKeysym(keycode);

    // TODO: Optimize with HashMap for O(1) lookup
    // Current O(n) scan is acceptable for <50 keybindings
    // For more keybindings, add to WM struct:
    //   keybind_map: std.AutoHashMap(u64, *defs.Keybind)
    // Then use: wm.keybind_map.get((@as(u64, modifiers) << 32) | keysym)
    for (wm.config.keybindings.items) |keybind| {
        if (keybind.matches(modifiers, keysym)) {
            if (ENABLE_INPUT_DEBUG and builtin.mode == .Debug) {
                std.debug.print("[input] Keybinding matched: mod=0x{x} keysym=0x{x}\n", 
                    .{ modifiers, keysym });
            }
            executeAction(&keybind.action, wm) catch |err| {
                std.log.err("Failed to execute keybinding action: {}", .{err});
            };
            return;
        }
    }

    // Only log unbound keys in debug mode if explicitly enabled
    if (ENABLE_INPUT_DEBUG and builtin.mode == .Debug) {
        std.debug.print("[input] Unbound key: keycode={} keysym=0x{x} mod=0x{x}\n", 
            .{ keycode, keysym, modifiers });
    }
}

fn executeAction(action: *const defs.Action, wm: *WM) !void {
    switch (action.*) {
        .exec => |cmd| {
            if (ENABLE_INPUT_DEBUG and builtin.mode == .Debug) {
                std.debug.print("[input] Executing: {s}\n", .{cmd});
            }

            // Fork and exec using C functions
            const pid = c.fork();
            if (pid == 0) {
                // Child process
                const cmd_z = try wm.allocator.dupeZ(u8, cmd);
                defer wm.allocator.free(cmd_z);

                const argv = [_:null]?[*:0]const u8{ "/bin/sh", "-c", cmd_z.ptr, null };
                _ = c.execvp("/bin/sh", @ptrCast(&argv));
                
                // If exec fails, exit
                std.log.err("Failed to exec: {s}", .{cmd});
                std.process.exit(1);
            } else if (pid < 0) {
                std.log.err("Fork failed for command: {s}", .{cmd});
            }
        },
        .close_window => {
            if (wm.focused_window) |win_id| {
                if (ENABLE_INPUT_DEBUG and builtin.mode == .Debug) {
                    std.debug.print("[input] Closing window {}\n", .{win_id});
                }
                _ = xcb.xcb_destroy_window(wm.conn, win_id);
                _ = xcb.xcb_flush(wm.conn);
            }
        },
        .reload_config => {
            if (builtin.mode == .Debug) {
                std.debug.print("[input] Config reload triggered\n", .{});
            }
            // Signal will be handled in main loop
        },
        .focus_next, .focus_prev => {
            if (ENABLE_INPUT_DEBUG and builtin.mode == .Debug) {
                std.debug.print("[input] Focus navigation not yet implemented\n", .{});
            }
        },
    }
}

const BUTTON_NAMES = [_][]const u8{
    "unknown", "left", "middle", "right", "scroll up", "scroll down"
};

fn handleButtonPress(event: *const xcb.xcb_button_press_event_t, wm: *WM) void {
    const button = event.detail;
    const window = event.child;

    if (ENABLE_INPUT_DEBUG and builtin.mode == .Debug) {
        const button_name = if (button >= 1 and button <= 5)
            BUTTON_NAMES[button]
        else
            BUTTON_NAMES[0];
        std.debug.print("[input] Mouse {s} click at ({}, {}) window={}\n", 
            .{ button_name, event.event_x, event.event_y, window });
    }

    // Handle window focus and raising
    if (window != 0) {
        // Focus the clicked window
        wm.focused_window = window;
        _ = xcb.xcb_set_input_focus(
            wm.conn,
            xcb.XCB_INPUT_FOCUS_POINTER_ROOT,
            window,
            xcb.XCB_CURRENT_TIME,
        );

        // Raise the window to the top of the stack
        const values = [_]u32{xcb.XCB_STACK_MODE_ABOVE};
        _ = xcb.xcb_configure_window(
            wm.conn,
            window,
            xcb.XCB_CONFIG_WINDOW_STACK_MODE,
            &values,
        );

        // CRITICAL: Replay the pointer event so the application receives it
        _ = xcb.xcb_allow_events(wm.conn, xcb.XCB_ALLOW_REPLAY_POINTER, event.time);
        
        // Flush immediately - user expects instant visual feedback
        _ = xcb.xcb_flush(wm.conn);

        // TODO: Check for Mod+Button1 to initiate window move
        // TODO: Check for Mod+Button3 to initiate window resize
    } else {
        // Clicked on root window - just replay event
        _ = xcb.xcb_allow_events(wm.conn, xcb.XCB_ALLOW_REPLAY_POINTER, event.time);
    }
}

fn handleButtonRelease(event: *const xcb.xcb_button_release_event_t, wm: *WM) void {
    if (ENABLE_INPUT_DEBUG and builtin.mode == .Debug) {
        std.debug.print("[input] Mouse button {} released\n", .{event.detail});
    }

    // TODO: End window drag/resize operations here
    _ = xcb.xcb_allow_events(wm.conn, xcb.XCB_ALLOW_ASYNC_POINTER, event.time);
    
    // Flush to ensure drag/resize completes immediately
    _ = xcb.xcb_flush(wm.conn);
}

fn handleMotion(event: *const xcb.xcb_motion_notify_event_t, wm: *WM) void {
    // TODO: Add drag state tracking to WM struct:
    //   - is_dragging: bool
    //   - drag_window: xcb_window_t
    //   - drag_start_x/y: i16
    //   - window_start_x/y: i16
    
    const is_dragging = false; // Replace with: wm.drag_state.is_dragging
    
    if (!is_dragging) {
        // Not dragging - just acknowledge without flushing
        // This eliminates hundreds of round-trips per second
        _ = xcb.xcb_allow_events(wm.conn, xcb.XCB_ALLOW_ASYNC_POINTER, event.time);
        return;
    }
    
    // Dragging - update window position
    // TODO: Calculate new window position and update
    // const dx = event.root_x - wm.drag_state.start_x;
    // const dy = event.root_y - wm.drag_state.start_y;
    // _ = xcb.xcb_configure_window(...);
    
    if (ENABLE_INPUT_DEBUG and builtin.mode == .Debug) {
        std.debug.print("[input] Drag motion: ({}, {})\n", .{ event.root_x, event.root_y });
    }
    
    _ = xcb.xcb_allow_events(wm.conn, xcb.XCB_ALLOW_ASYNC_POINTER, event.time);
    
    // Flush for smooth dragging feedback
    _ = xcb.xcb_flush(wm.conn);
}

pub fn createModule() Module {
    return Module{
        .name = "input",
        .event_types = &EVENT_TYPES,
        .init_fn = init,
        .handle_fn = handleEvent,
    };
}
