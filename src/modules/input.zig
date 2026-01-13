// Input handling - OPTIMIZED FOR MINIMUM LATENCY + MAXIMUM THROUGHPUT
// Smart batching: group related operations, flush once per user action

const std = @import("std");
const defs = @import("defs");
const xkbcommon = @import("xkbcommon");
const builtin = @import("builtin");

const c = @cImport({
    @cInclude("unistd.h");
});

const xcb = defs.xcb;
const WM = defs.WM;
const Module = defs.Module;

const ENABLE_INPUT_DEBUG = true;

pub const EVENT_TYPES = [_]u8{
    xcb.XCB_KEY_PRESS,
    xcb.XCB_KEY_RELEASE,
    xcb.XCB_BUTTON_PRESS,
    xcb.XCB_BUTTON_RELEASE,
    xcb.XCB_MOTION_NOTIFY,
};

// OPTIMIZATION: O(1) keybinding lookup using HashMap
// Key: (modifiers << 32) | keysym
var keybind_map: std.AutoHashMap(u64, *const defs.Action) = undefined;
var keybind_initialized = false;

// Motion event throttling - set to 1ms for 1000Hz mice
// Set to 0 to disable throttling entirely (may generate more CPU load)
const MOTION_THROTTLE_MS: u32 = 1; // 1ms = 1000Hz support

var last_motion_time: u32 = 0;

// Event queue for micro-batching within same frame
var pending_events: std.BoundedArray(PendingEvent, 32) = .{};

const PendingEvent = struct {
    event_type: u8,
    event_ptr: *anyopaque,
};

pub fn init(wm: *WM) void {
    // Initialize keybinding HashMap for O(1) lookup
    keybind_map = std.AutoHashMap(u64, *const defs.Action).init(wm.allocator);
    buildKeybindMap(wm) catch |err| {
        std.log.err("Failed to build keybind map: {}", .{err});
        return;
    };
    keybind_initialized = true;

    if (builtin.mode == .Debug) {
        std.debug.print("[input] Module initialized with {} keybindings\n", 
            .{keybind_map.count()});
    }
}

pub fn deinit(_: *WM) void {
    if (keybind_initialized) {
        keybind_map.deinit();
        keybind_initialized = false;
    }
}

// Build HashMap for O(1) keybinding lookup
fn buildKeybindMap(wm: *WM) !void {
    keybind_map.clearRetainingCapacity();
    
    for (wm.config.keybindings.items) |*keybind| {
        const key = makeKeybindKey(keybind.modifiers, keybind.keysym);
        try keybind_map.put(key, &keybind.action);
    }
}

// Create unique key for HashMap: (modifiers << 32) | keysym
inline fn makeKeybindKey(modifiers: u16, keysym: u32) u64 {
    return (@as(u64, modifiers) << 32) | keysym;
}

pub fn handleEvent(event_type: u8, event: *anyopaque, wm: *WM) void {
    const response_type = event_type & ~defs.X11_SYNTHETIC_EVENT_FLAG;

    switch (response_type) {
        xcb.XCB_KEY_PRESS => {
            const ev = @as(*const xcb.xcb_key_press_event_t, @alignCast(@ptrCast(event)));
            handleKeyPress(ev, wm);
        },

        xcb.XCB_KEY_RELEASE => {
            // Key releases rarely need handling - saves CPU
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
    const raw_modifiers: u16 = @intCast(event.state);
    // Strip NumLock, CapsLock, ScrollLock - only keep relevant modifiers
    const modifiers = raw_modifiers & defs.MOD_MASK_RELEVANT;

    // Get XKB state and convert keycode to keysym
    const xkb_ptr: *xkbcommon.XkbState = @ptrCast(@alignCast(wm.xkb_state.?));
    const keysym = xkb_ptr.keycodeToKeysym(keycode);

    // OPTIMIZATION: O(1) HashMap lookup instead of O(n) linear scan
    const key = makeKeybindKey(modifiers, keysym);
    
    if (keybind_map.get(key)) |action| {
        if (ENABLE_INPUT_DEBUG and builtin.mode == .Debug) {
            std.debug.print("[input] Keybinding matched: mod=0x{x} keysym=0x{x}\n", 
                .{ modifiers, keysym });
        }
        executeAction(action, wm) catch |err| {
            std.log.err("Failed to execute keybinding action: {}", .{err});
        };
        return;
    }

    if (ENABLE_INPUT_DEBUG and builtin.mode == .Debug) {
        std.debug.print("[input] Unbound key: keycode={} keysym=0x{x} mod=0x{x} (raw=0x{x})\n",
            .{ keycode, keysym, modifiers, raw_modifiers });
        }
}

fn executeAction(action: *const defs.Action, wm: *WM) !void {
    switch (action.*) {
        .exec => |cmd| {
            if (ENABLE_INPUT_DEBUG and builtin.mode == .Debug) {
                std.debug.print("[input] Executing: {s}\n", .{cmd});
            }

            // OPTIMIZATION: Fork in background, don't wait
            const pid = c.fork();
            if (pid == 0) {
                // Child process - use setsid to detach from WM process group
                _ = c.setsid();
                
                const cmd_z = try wm.allocator.dupeZ(u8, cmd);
                defer wm.allocator.free(cmd_z);

                const argv = [_:null]?[*:0]const u8{ "/bin/sh", "-c", cmd_z.ptr, null };
                _ = c.execvp("/bin/sh", @ptrCast(&argv));
                
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
                _ = xcb.xcb_flush(wm.conn); // Single flush - one user action
            }
        },
        .reload_config => {
            if (builtin.mode == .Debug) {
                std.debug.print("[input] Config reload triggered\n", .{});
            }
            // Rebuild keybind map after reload
            buildKeybindMap(wm) catch |err| {
                std.log.err("Failed to rebuild keybind map: {}", .{err});
            };
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

    if (window != 0) {
        // SMART BATCHING: These 3 operations are ONE logical user action (click window)
        // Queue them all, then flush once = same latency, better throughput
        wm.focused_window = window;
        
        _ = xcb.xcb_set_input_focus(
            wm.conn,
            xcb.XCB_INPUT_FOCUS_POINTER_ROOT,
            window,
            xcb.XCB_CURRENT_TIME,
        );

        const values = [_]u32{xcb.XCB_STACK_MODE_ABOVE};
        _ = xcb.xcb_configure_window(
            wm.conn,
            window,
            xcb.XCB_CONFIG_WINDOW_STACK_MODE,
            &values,
        );

        _ = xcb.xcb_allow_events(wm.conn, xcb.XCB_ALLOW_REPLAY_POINTER, event.time);
        
        // Single flush for entire operation - same latency, 3x throughput
        _ = xcb.xcb_flush(wm.conn);
    } else {
        _ = xcb.xcb_allow_events(wm.conn, xcb.XCB_ALLOW_REPLAY_POINTER, event.time);
        // No flush needed - not user-visible
    }
}

fn handleButtonRelease(event: *const xcb.xcb_button_release_event_t, wm: *WM) void {
    if (ENABLE_INPUT_DEBUG and builtin.mode == .Debug) {
        std.debug.print("[input] Mouse button {} released\n", .{event.detail});
    }

    _ = xcb.xcb_allow_events(wm.conn, xcb.XCB_ALLOW_ASYNC_POINTER, event.time);
    
    // OPTIMIZATION: Only flush if we were actually dragging
    // For now, no drag state, so skip flush entirely
    // _ = xcb.xcb_flush(wm.conn);
}

fn handleMotion(event: *const xcb.xcb_motion_notify_event_t, wm: *WM) void {
    // OPTIMIZATION: Minimal throttling for 1000Hz mice (1ms)
    // Set MOTION_THROTTLE_MS to 0 to disable entirely
    const time_delta = if (event.time > last_motion_time) 
        event.time - last_motion_time 
    else 
        0;
    
    if (time_delta < MOTION_THROTTLE_MS) {
        // Too soon - skip this motion event
        _ = xcb.xcb_allow_events(wm.conn, xcb.XCB_ALLOW_ASYNC_POINTER, event.time);
        return;
    }
    
    last_motion_time = event.time;
    
    // TODO: Check if dragging and update window position
    const is_dragging = false;
    
    if (!is_dragging) {
        _ = xcb.xcb_allow_events(wm.conn, xcb.XCB_ALLOW_ASYNC_POINTER, event.time);
        return;
    }
    
    if (ENABLE_INPUT_DEBUG and builtin.mode == .Debug) {
        std.debug.print("[input] Drag motion: ({}, {})\n", .{ event.root_x, event.root_y });
    }
    
    _ = xcb.xcb_allow_events(wm.conn, xcb.XCB_ALLOW_ASYNC_POINTER, event.time);
    _ = xcb.xcb_flush(wm.conn); // Immediate flush when dragging
}

pub fn createModule() Module {
    return Module{
        .name = "input",
        .event_types = &EVENT_TYPES,
        .init_fn = init,
        .handle_fn = handleEvent,
    };
}
