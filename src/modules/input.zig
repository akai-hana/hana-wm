// Input handling - captures keyboard and mouse events

const std = @import("std");
const defs = @import("defs");

const c = @cImport({
    @cInclude("unistd.h");
});

// Use xcb from defs to avoid type conflicts
const xcb = defs.xcb;

const WM = defs.WM;
const Module = defs.Module;

// Events this module handles
const HANDLED_EVENTS = [_]u8{
    xcb.XCB_KEY_PRESS,
    xcb.XCB_KEY_RELEASE,
    xcb.XCB_BUTTON_PRESS,
    xcb.XCB_BUTTON_RELEASE,
    xcb.XCB_MOTION_NOTIFY,
};

fn init(_: *WM) void {
    std.debug.print("[input] Module initialized\n", .{});
}

fn handleEvent(event_type: u8, event: *anyopaque, wm: *WM) void {
    const response_type = event_type & ~defs.X11_SYNTHETIC_EVENT_FLAG;

    switch (response_type) {
        xcb.XCB_KEY_PRESS => {
            const ev = @as(*const xcb.xcb_key_press_event_t, @alignCast(@ptrCast(event)));
            handleKeyPress(ev, wm);
        },

        xcb.XCB_KEY_RELEASE => {
            const ev = @as(*const xcb.xcb_key_release_event_t, @alignCast(@ptrCast(event)));
            handleKeyRelease(ev);
        },

        xcb.XCB_BUTTON_PRESS => {
            const ev = @as(*const xcb.xcb_button_press_event_t, @alignCast(@ptrCast(event)));
            handleButtonPress(ev);
        },

        xcb.XCB_BUTTON_RELEASE => {
            const ev = @as(*const xcb.xcb_button_release_event_t, @alignCast(@ptrCast(event)));
            handleButtonRelease(ev);
        },

        xcb.XCB_MOTION_NOTIFY => {
            const ev = @as(*const xcb.xcb_motion_notify_event_t, @alignCast(@ptrCast(event)));
            handleMotion(ev);
        },

        else => {},
    }
}

fn handleKeyPress(event: *const xcb.xcb_key_press_event_t, wm: *WM) void {
    const keycode = event.detail;
    const modifiers: u16 = @intCast(event.state);

    // Check if this matches any keybinding
    for (wm.config.keybindings.items) |keybind| {
        if (keybind.matches(modifiers, keycode)) {
            std.debug.print("[input] Keybinding matched: mod=0x{x} key={}\n", .{ modifiers, keycode });
            executeAction(&keybind.action, wm) catch |err| {
                std.debug.print("[input] Failed to execute action: {}\n", .{err});
            };
            return;
        }
    }

    std.debug.print("[input] Unbound key press: keycode={} modifiers=0x{x}\n", .{ keycode, modifiers });
}

fn executeAction(action: *const defs.Action, wm: *WM) !void {
    switch (action.*) {
        .exec => |cmd| {
            std.debug.print("[input] Executing command: {s}\n", .{cmd});

            // Fork and exec
            const pid = c.fork();
            if (pid == 0) {
                // Child process
                const cmd_z = try wm.allocator.dupeZ(u8, cmd);
                defer wm.allocator.free(cmd_z);

                const argv = [_:null]?[*:0]const u8{ "/bin/sh", "-c", cmd_z.ptr, null };
                _ = c.execvp("/bin/sh", @ptrCast(&argv));
                std.process.exit(1);
            }
        },
        .close_window => {
            if (wm.focused_window) |win_id| {
                std.debug.print("[input] Closing window {}\n", .{win_id});
                _ = xcb.xcb_destroy_window(wm.conn, win_id);
            }
        },
        .reload_config => {
            std.debug.print("[input] Reload config action triggered\n", .{});
            // Signal will be handled in main loop
        },
        .focus_next, .focus_prev => {
            std.debug.print("[input] Focus navigation not yet implemented\n", .{});
        },
    }
}

fn handleKeyRelease(event: *const xcb.xcb_key_release_event_t) void {
    const keycode = event.detail;
    std.debug.print("[input] Key release: keycode={}\n", .{keycode});

    // TODO: Handle held key releases
}

fn handleButtonPress(event: *const xcb.xcb_button_press_event_t) void {
    const button = event.detail;
    const x = event.event_x;
    const y = event.event_y;
    const window = event.child;

    const button_name: []const u8 = switch (button) {
        1 => "left",
        2 => "middle",
        3 => "right",
        4 => "scroll up",
        5 => "scroll down",
        else => "unknown",
    };

    std.debug.print("[input] Mouse {s} click at ({}, {}) window={}\n", .{ button_name, x, y, window });

    // TODO: Focus window on click, initiate window moving/resizing
}

fn handleButtonRelease(event: *const xcb.xcb_button_release_event_t) void {
    const button = event.detail;
    std.debug.print("[input] Mouse button {} released\n", .{button});

    // TODO: End drag/resize operations
}

fn handleMotion(event: *const xcb.xcb_motion_notify_event_t) void {
    // Motion events fire very frequently (dozens per second during mouse movement)
    // Only process if we're actually dragging/resizing a window
    _ = event;

    // TODO: Implement motion event throttling or only process when dragging
    // For now, we silently ignore to avoid spam
}

pub fn createModule() Module {
    return Module{
        .name = "input",
        .event_types = &HANDLED_EVENTS,
        .init_fn = init,
        .handle_fn = handleEvent,
    };
}
