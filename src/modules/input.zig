// Input handling - captures keyboard and mouse events

const std = @import("std");
const defs = @import("defs");

const xcb = @cImport({
    @cInclude("xcb/xcb.h");
});

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
            const ev = @as(*xcb.xcb_key_press_event_t, @alignCast(@ptrCast(event)));
            handleKeyPress(ev);
        },

        xcb.XCB_KEY_RELEASE => {
            const ev = @as(*xcb.xcb_key_release_event_t, @alignCast(@ptrCast(event)));
            handleKeyRelease(ev);
        },

        xcb.XCB_BUTTON_PRESS => {
            const ev = @as(*xcb.xcb_button_press_event_t, @alignCast(@ptrCast(event)));
            handleButtonPress(ev);
        },

        xcb.XCB_BUTTON_RELEASE => {
            const ev = @as(*xcb.xcb_button_release_event_t, @alignCast(@ptrCast(event)));
            handleButtonRelease(ev);
        },

        xcb.XCB_MOTION_NOTIFY => {
            const ev = @as(*xcb.xcb_motion_notify_event_t, @alignCast(@ptrCast(event)));
            handleMotion(ev);
        },

        else => {},
    }

    _ = wm;
}

fn handleKeyPress(event: *xcb.xcb_key_press_event_t) void {
    const keycode = event.detail;
    const modifiers = event.state;

    std.debug.print("[input] Key press: keycode={} modifiers=0x{x}\n", .{ keycode, modifiers });

    // TODO: Map keycodes to actions
}

fn handleKeyRelease(event: *xcb.xcb_key_release_event_t) void {
    const keycode = event.detail;
    std.debug.print("[input] Key release: keycode={}\n", .{keycode});
}

fn handleButtonPress(event: *xcb.xcb_button_press_event_t) void {
    const button = event.detail;
    const x = event.event_x;
    const y = event.event_y;
    const window = event.child;

    const button_name = switch (button) {
        1 => "left",
        2 => "middle",
        3 => "right",
        4 => "scroll up",
        5 => "scroll down",
        else => "unknown",
    };

    std.debug.print("[input] Mouse {s} click at ({}, {}) window={}\n", .{ button_name, x, y, window });

    // TODO: Focus window on click, window moving/resizing
}

fn handleButtonRelease(event: *xcb.xcb_button_release_event_t) void {
    const button = event.detail;
    std.debug.print("[input] Mouse button {} released\n", .{button});

    // TODO: End drag operations
}

fn handleMotion(event: *xcb.xcb_motion_notify_event_t) void {
    // Note: This fires A LOT - only log if debugging
    _ = event;

    // TODO: Handle window dragging/resizing
}

pub fn createModule() Module {
    return Module{
        .name = "input",
        .events = &HANDLED_EVENTS,
        .init_fn = init,
        .handle_fn = handleEvent,
    };
}
