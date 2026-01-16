// Window management - absolutely minimal

const std = @import("std");
const defs = @import("defs");
const log = @import("logging");
const tiling = @import("tiling");
const xcb = defs.xcb;
const WM = defs.WM;
const Module = defs.Module;

pub const EVENT_TYPES = [_]u8{
    xcb.XCB_MAP_REQUEST,
    xcb.XCB_CONFIGURE_REQUEST,
    xcb.XCB_DESTROY_NOTIFY,
    xcb.XCB_ENTER_NOTIFY,
    xcb.XCB_LEAVE_NOTIFY,  // Track when mouse leaves windows
};

// Track windows that should be ignored for focus (to prevent focus stealing)
var ignored_for_focus: std.AutoHashMap(u32, void) = undefined;
var ignored_initialized = false;

pub fn init(wm: *WM) void {
    ignored_for_focus = std.AutoHashMap(u32, void).init(wm.allocator);
    ignored_initialized = true;
    log.debugWindowModuleInit();
}

pub fn deinit(_: *WM) void {
    if (ignored_initialized) {
        ignored_for_focus.deinit();
        ignored_initialized = false;
    }
}

pub fn handleEvent(event_type: u8, event: *anyopaque, wm: *WM) void {
    switch (event_type & 0x7F) {
        xcb.XCB_MAP_REQUEST => handleMapRequest(@ptrCast(@alignCast(event)), wm),
        xcb.XCB_CONFIGURE_REQUEST => handleConfigureRequest(@ptrCast(@alignCast(event)), wm),
        xcb.XCB_DESTROY_NOTIFY => handleDestroyNotify(@ptrCast(@alignCast(event)), wm),
        xcb.XCB_ENTER_NOTIFY => handleEnterNotify(@ptrCast(@alignCast(event)), wm),
        xcb.XCB_LEAVE_NOTIFY => handleLeaveNotify(@ptrCast(@alignCast(event)), wm),
        else => {},
    }
}

pub fn ignoreWindowForFocus(window: u32) void {
    if (ignored_initialized) {
        ignored_for_focus.put(window, {}) catch {};
    }
}

fn handleMapRequest(event: *const xcb.xcb_map_request_event_t, wm: *WM) void {
    log.debugWindowMapRequest(event.window);

    _ = xcb.xcb_map_window(wm.conn, event.window);
    _ = xcb.xcb_flush(wm.conn);
}

fn handleConfigureRequest(event: *const xcb.xcb_configure_request_event_t, wm: *WM) void {
    log.debugWindowConfigure(event.window, event.width, event.height, event.x, event.y);

    _ = xcb.xcb_configure_window(wm.conn, event.window, event.value_mask, &[_]u32{
        @intCast(event.x),
        @intCast(event.y),
        @intCast(event.width),
        @intCast(event.height),
        @intCast(event.border_width),
    });
}

fn handleEnterNotify(event: *const xcb.xcb_enter_notify_event_t, wm: *WM) void {
    // Ignore root window and invalid windows
    if (event.event == wm.root or event.event == 0) return;
    
    // Check if this window should be ignored for focus
    if (ignored_for_focus.contains(event.event)) {
        return;  // Don't focus this window yet
    }
    
    // Normal focus behavior
    setWindowFocus(wm, event.event);
}

fn handleLeaveNotify(event: *const xcb.xcb_leave_notify_event_t, _: *WM) void {
    // When mouse leaves a window, remove it from the ignored list
    // so it can gain focus when mouse enters it again
    _ = ignored_for_focus.remove(event.event);
}

fn handleDestroyNotify(event: *const xcb.xcb_destroy_notify_event_t, wm: *WM) void {
    log.debugWindowDestroyed(event.window);

    // Clean up ignored list
    _ = ignored_for_focus.remove(event.window);
    
    const was_focused = wm.focused_window == event.window;
    
    wm.removeWindow(event.window);
    if (wm.focused_window == event.window) {
        wm.focused_window = null;
    }
    
    // If the destroyed window was focused, try to focus another window
    if (was_focused) {
        focusNextAvailableWindow(wm);
    }
}

fn focusNextAvailableWindow(wm: *WM) void {
    // Try to focus any remaining window
    var iter = wm.windows.keyIterator();
    if (iter.next()) |window_id| {
        setWindowFocus(wm, window_id.*);
    }
}

fn setWindowFocus(wm: *WM, window: u32) void {
    // Set X11 input focus
    _ = xcb.xcb_set_input_focus(
        wm.conn,
        xcb.XCB_INPUT_FOCUS_POINTER_ROOT,
        window,
        xcb.XCB_CURRENT_TIME
    );

    // Raise window to top
    _ = xcb.xcb_configure_window(
        wm.conn,
        window,
        xcb.XCB_CONFIG_WINDOW_STACK_MODE,
        &[_]u32{xcb.XCB_STACK_MODE_ABOVE}
    );

    // Update WM state BEFORE notifying tiling module
    const old_focus = wm.focused_window;
    wm.focused_window = window;

    log.debugWindowFocusChanged(window);

    // Notify tiling module about focus change
    if (old_focus != window) {
        tiling.updateWindowFocus(wm, window);
    }

    _ = xcb.xcb_flush(wm.conn);
}
