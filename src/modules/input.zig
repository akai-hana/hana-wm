// input.zig - Handles keyboard and mouse input
// This module captures key presses, mouse clicks, and mouse movement

const std = @import("std");
const defs = @import("defs");

const xcb = @cImport({
    @cInclude("xcb/xcb.h");
});

const WM = defs.WM;
const Module = defs.Module;

// Called once when the window manager starts
// Subscribes to keyboard and mouse events on the root window
fn init(wm: *WM) void {
    std.debug.print("[input] Module initialized\n", .{});
    
    // Subscribe to keyboard and mouse events on root window
    const mask = xcb.XCB_CW_EVENT_MASK;
    const values = [_]u32{
        xcb.XCB_EVENT_MASK_KEY_PRESS |           // Keyboard key down
        xcb.XCB_EVENT_MASK_KEY_RELEASE |         // Keyboard key up
        xcb.XCB_EVENT_MASK_BUTTON_PRESS |        // Mouse button down
        xcb.XCB_EVENT_MASK_BUTTON_RELEASE |      // Mouse button up
        xcb.XCB_EVENT_MASK_POINTER_MOTION |      // Mouse movement
        xcb.XCB_EVENT_MASK_SUBSTRUCTURE_REDIRECT | // For WM control
        xcb.XCB_EVENT_MASK_SUBSTRUCTURE_NOTIFY,    // For WM notifications
    };
    
    _ = xcb.xcb_change_window_attributes(wm.conn, wm.root, mask, &values);
}

// Called every time an X11 event happens
// Routes keyboard and mouse events to their handlers
fn handleEvent(event_type: u8, event: *anyopaque, wm: *WM) void {
    const response_type = event_type & ~@as(u8, 0x80);

    switch (response_type) {
        // Keyboard: Key pressed down
        xcb.XCB_KEY_PRESS => {
            const ev = @as(*xcb.xcb_key_press_event_t, @alignCast(@ptrCast(event)));
            handleKeyPress(ev, wm);
        },
        
        // Keyboard: Key released
        xcb.XCB_KEY_RELEASE => {
            const ev = @as(*xcb.xcb_key_release_event_t, @alignCast(@ptrCast(event)));
            handleKeyRelease(ev, wm);
        },
        
        // Mouse: Button clicked (left, right, middle, scroll)
        xcb.XCB_BUTTON_PRESS => {
            const ev = @as(*xcb.xcb_button_press_event_t, @alignCast(@ptrCast(event)));
            handleButtonPress(ev, wm);
        },
        
        // Mouse: Button released
        xcb.XCB_BUTTON_RELEASE => {
            const ev = @as(*xcb.xcb_button_release_event_t, @alignCast(@ptrCast(event)));
            handleButtonRelease(ev, wm);
        },
        
        // Mouse: Movement
        xcb.XCB_MOTION_NOTIFY => {
            const ev = @as(*xcb.xcb_motion_notify_event_t, @alignCast(@ptrCast(event)));
            handleMotion(ev, wm);
        },
        
        else => {},
    }
}

// Handles when a keyboard key is pressed
fn handleKeyPress(event: *xcb.xcb_key_press_event_t, wm: *WM) void {
    _ = wm;
    
    const keycode = event.detail;
    const modifiers = event.state;
    
    std.debug.print("[input] Key press: keycode={} modifiers=0x{x}\n", .{ keycode, modifiers });
    
    // TODO: Map keycodes to actions (close window, launch app, etc.)
    // Example keybindings will go here:
    // if (modifiers & MOD4 and keycode == KEY_RETURN) launch_terminal();
}

// Handles when a keyboard key is released
fn handleKeyRelease(event: *xcb.xcb_key_release_event_t, wm: *WM) void {
    _ = wm;
    
    const keycode = event.detail;
    std.debug.print("[input] Key release: keycode={}\n", .{keycode});
}

// Handles when a mouse button is clicked
// Button IDs: 1=left, 2=middle, 3=right, 4=scroll up, 5=scroll down
fn handleButtonPress(event: *xcb.xcb_button_press_event_t, wm: *WM) void {
    _ = wm;
    
    const button = event.detail;
    const x = event.event_x;
    const y = event.event_y;
    const window = event.child; // Window under cursor (0 if root)
    
    const button_name = switch (button) {
        1 => "left",
        2 => "middle",
        3 => "right",
        4 => "scroll up",
        5 => "scroll down",
        else => "unknown",
    };
    
    std.debug.print("[input] Mouse {s} click at ({}, {}) window={}\n", .{ button_name, x, y, window });
    
    // TODO: Implement mouse actions:
    // - Left click: focus window
    // - Right click: context menu
    // - Middle click: close window
    // - Mod + left drag: move window
    // - Mod + right drag: resize window
}

// Handles when a mouse button is released
fn handleButtonRelease(event: *xcb.xcb_button_release_event_t, wm: *WM) void {
    _ = wm;
    
    const button = event.detail;
    std.debug.print("[input] Mouse button {} released\n", .{button});
    
    // TODO: End drag operations here (stop moving/resizing window)
}

// Handles when the mouse moves
fn handleMotion(event: *xcb.xcb_motion_notify_event_t, wm: *WM) void {
    _ = wm;
    
    const x = event.event_x;
    const y = event.event_y;
    
    // Note: This fires A LOT - only log if you need to debug
    // std.debug.print("[input] Mouse moved to ({}, {})\n", .{ x, y });
    _ = x;
    _ = y;
    
    // TODO: Handle window dragging/resizing if in progress
}

// Creates the module that main.zig will load
pub fn createModule() Module {
    return Module{
        .name = "input",
        .init_fn = init,
        .handle_fn = handleEvent,
    };
}
