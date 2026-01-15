// Window management - absolutely minimal

const std     = @import("std");
const defs    = @import("defs");
const builtin = @import("builtin");
const logging = @import("logging");
const xcb     = defs.xcb;
const WM      = defs.WM;
const Module  = defs.Module;

pub const EVENT_TYPES = [_]u8{
    xcb.XCB_MAP_REQUEST,
    xcb.XCB_CONFIGURE_REQUEST,
    xcb.XCB_DESTROY_NOTIFY,
};

pub fn init(_: *WM) void {
    if (builtin.mode == .Debug) {
        std.debug.print("[window] Module initialized\n", .{});
    }
}

pub fn handleEvent(event_type: u8, event: *anyopaque, wm: *WM) void {
    switch (event_type & 0x7F) {
        xcb.XCB_MAP_REQUEST => handleMapRequest(@ptrCast(@alignCast(event)), wm),
        xcb.XCB_CONFIGURE_REQUEST => handleConfigureRequest(@ptrCast(@alignCast(event)), wm),
        xcb.XCB_DESTROY_NOTIFY => handleDestroyNotify(@ptrCast(@alignCast(event)), wm),
        else => {},
    }
}

fn handleMapRequest(event: *const xcb.xcb_map_request_event_t, wm: *WM) void {
    logging.debugWindowMapRequest(event.window);

    _ = xcb.xcb_map_window(wm.conn, event.window);
    _ = xcb.xcb_flush(wm.conn);
}

fn handleConfigureRequest(event: *const xcb.xcb_configure_request_event_t, wm: *WM) void {
    logging.debugWindowConfigure(event.window, event.width, event.height, event.x, event.y);

    _ = xcb.xcb_configure_window(wm.conn, event.window, event.value_mask, &[_]u32{
        @intCast(event.x),
        @intCast(event.y),
        @intCast(event.width),
        @intCast(event.height),
        @intCast(event.border_width),
    });
}

fn handleDestroyNotify(event: *const xcb.xcb_destroy_notify_event_t, wm: *WM) void {
    logging.debugWindowDestroyed(event.window);

    wm.removeWindow(event.window);
    if (wm.focused_window == event.window) wm.focused_window = null;
}
