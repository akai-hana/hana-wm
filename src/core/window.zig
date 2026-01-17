//! Window event handling module.
//!
//! Handles core X11 window events:
//! - Map requests (window wants to be displayed)
//! - Configure requests (window wants to resize/move)
//! - Destroy notifications (window closed)
//! - Enter notifications (mouse enters window - focus follows mouse)

const std = @import("std");
const defs = @import("defs");
const log = @import("logging");
const tiling = @import("tiling");
const xcb = defs.xcb;
const WM = defs.WM;

pub const EVENT_TYPES = [_]u8{
    xcb.XCB_MAP_REQUEST,
    xcb.XCB_CONFIGURE_REQUEST,
    xcb.XCB_DESTROY_NOTIFY,
    xcb.XCB_ENTER_NOTIFY,
};

pub fn init(_: *WM) void {
    log.debugWindowModuleInit();
}

pub fn deinit(_: *WM) void {}

pub fn handleEvent(event_type: u8, event: *anyopaque, wm: *WM) void {
    switch (event_type & 0x7F) {
        xcb.XCB_MAP_REQUEST => handleMapRequest(event, wm),
        xcb.XCB_CONFIGURE_REQUEST => handleConfigureRequest(event, wm),
        xcb.XCB_ENTER_NOTIFY => handleEnterNotify(event, wm),
        xcb.XCB_DESTROY_NOTIFY => handleDestroyNotify(event, wm),
        else => {},
    }
}

/// Handle window map requests - make window visible
fn handleMapRequest(event: *anyopaque, wm: *WM) void {
    const e: *const xcb.xcb_map_request_event_t = @ptrCast(@alignCast(event));
    log.debugWindowMapRequest(e.window);
    _ = xcb.xcb_map_window(wm.conn, e.window);
}

/// Handle window configure requests - resize/move floating windows
fn handleConfigureRequest(event: *anyopaque, wm: *WM) void {
    const e: *const xcb.xcb_configure_request_event_t = @ptrCast(@alignCast(event));
    log.debugWindowConfigure(e.window, e.width, e.height, e.x, e.y);

    // Let tiling module handle tiled windows, we only handle floating
    if (wm.config.tiling.enabled and tiling.isWindowTiled(e.window)) return;

    // Apply requested configuration for floating windows
    _ = xcb.xcb_configure_window(wm.conn, e.window, e.value_mask, &[_]u32{
        @intCast(e.x),
        @intCast(e.y),
        @intCast(e.width),
        @intCast(e.height),
        @intCast(e.border_width),
    });
}

/// Handle mouse entering window - focus follows mouse
fn handleEnterNotify(event: *anyopaque, wm: *WM) void {
    const e: *const xcb.xcb_enter_notify_event_t = @ptrCast(@alignCast(event));
    
    // Ignore root window and null windows
    if (e.event == wm.root or e.event == 0) return;

    // Focus and raise window
    _ = xcb.xcb_set_input_focus(wm.conn, xcb.XCB_INPUT_FOCUS_POINTER_ROOT, e.event, xcb.XCB_CURRENT_TIME);
    _ = xcb.xcb_configure_window(wm.conn, e.event, xcb.XCB_CONFIG_WINDOW_STACK_MODE, &[_]u32{xcb.XCB_STACK_MODE_ABOVE});

    const old_focus = wm.focused_window;
    wm.focused_window = e.event;

    log.debugWindowFocusChanged(e.event);

    // Update tiling borders if focus changed
    if (old_focus != e.event) {
        tiling.updateWindowFocus(wm, e.event);
    }
}

/// Handle window destruction - clean up and refocus
fn handleDestroyNotify(event: *anyopaque, wm: *WM) void {
    const e: *const xcb.xcb_destroy_notify_event_t = @ptrCast(@alignCast(event));
    log.debugWindowDestroyed(e.window);

    const was_focused = wm.focused_window == e.window;
    wm.removeWindow(e.window);

    // If we just destroyed the focused window, focus another one
    if (was_focused) {
        wm.focused_window = null;
        
        // Try to focus any remaining window
        var iter = wm.windows.keyIterator();
        if (iter.next()) |window_id| {
            _ = xcb.xcb_set_input_focus(wm.conn, xcb.XCB_INPUT_FOCUS_POINTER_ROOT, window_id.*, xcb.XCB_CURRENT_TIME);
            wm.focused_window = window_id.*;
        }
    }
}
