// Window management
// This is the minimum code needed to make windows appear inside the WM.

// It handles the following events:
// - When an app wants to create a window (`MAP_REQUEST`)
// - When a window is closed (`DESTROY_NOTIFY`)

const std = @import("std");
const defs = @import("defs");

const xcb = @cImport({
    @cInclude("xcb/xcb.h");
});

const WM = defs.WM;
const Module = defs.Module;

// Events this module handles
const HANDLED_EVENTS = [_]u8{
    xcb.XCB_MAP_REQUEST,
    xcb.XCB_DESTROY_NOTIFY,
};

fn init(_: *WM) void {
    std.debug.print("[window] Module initialized\n", .{});
}

fn handleEvent(event_type: u8, event: *anyopaque, wm: *WM) void {
    const response_type = event_type & ~defs.X11_SYNTHETIC_EVENT_FLAG;

    switch (response_type) {
        xcb.XCB_MAP_REQUEST => {
            const ev = @as(*xcb.xcb_map_request_event_t, @alignCast(@ptrCast(event)));
            handleMapRequest(ev, wm);
        },
        xcb.XCB_DESTROY_NOTIFY => {
            std.debug.print("[window] Window destroyed\n", .{});
            // TODO: Future cleanup logic here
        },
        else => {},
    }
}

fn handleMapRequest(event: *xcb.xcb_map_request_event_t, wm: *WM) void {
    const window = event.window;

    std.debug.print("[window] Map request for window {}\n", .{window});

    // Set border width
    const border_mask = xcb.XCB_CONFIG_WINDOW_BORDER_WIDTH;
    const border_values = [_]u32{wm.config.border_width};
    _ = xcb.xcb_configure_window(wm.conn, window, border_mask, &border_values);

    // Set border color
    const color_mask = xcb.XCB_CW_BORDER_PIXEL;
    const color_values = [_]u32{wm.config.border_color};
    _ = xcb.xcb_change_window_attributes(wm.conn, window, color_mask, &color_values);

    // Map the window (make it visible)
    _ = xcb.xcb_map_window(wm.conn, window);
}

pub fn createModule() Module {
    return Module{
        .name = "window",
        .events = &HANDLED_EVENTS,
        .init_fn = init,
        .handle_fn = handleEvent,
    };
}
