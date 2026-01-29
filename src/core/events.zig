//! Event dispatch

const std  = @import("std");
const defs = @import("defs");
const xcb  = defs.xcb;
const WM   = defs.WM;

const window = @import("window");
const input  = @import("input");
const bar    = @import("bar");
const utils  = @import("utils");
const tiling = @import("tiling");

const EventHandler = *const fn (event: *anyopaque, wm: *WM) void;

const dispatch_table = blk: {
    var table: [36]?EventHandler = [_]?EventHandler{null} ** 36;

    table[xcb.XCB_KEY_PRESS]         = @ptrCast(&handleKeyPress);
    table[xcb.XCB_BUTTON_PRESS]      = @ptrCast(&handleButtonPress);
    table[xcb.XCB_BUTTON_RELEASE]    = @ptrCast(&handleButtonRelease);
    table[xcb.XCB_MOTION_NOTIFY]     = @ptrCast(&handleMotionNotify);
    table[xcb.XCB_ENTER_NOTIFY]      = @ptrCast(&handleEnterNotify);
    table[xcb.XCB_MAP_REQUEST]       = @ptrCast(&handleMapRequest);
    table[xcb.XCB_CONFIGURE_REQUEST] = @ptrCast(&handleConfigureRequest);
    table[xcb.XCB_DESTROY_NOTIFY]    = @ptrCast(&handleDestroyNotify);
    table[xcb.XCB_EXPOSE]            = @ptrCast(&handleExpose);
    table[xcb.XCB_PROPERTY_NOTIFY]   = @ptrCast(&handlePropertyNotify);

    break :blk table;
};

pub inline fn dispatch(event_type: u8, event: *anyopaque, wm: *WM) void {
    const type_index = event_type & 0x7f;
    if (type_index < dispatch_table.len) {
        if (dispatch_table[type_index]) |handler| {
            handler(event, wm);
        }
    }
}

pub fn initModules(wm: *WM) void {
    input.init(wm);
    window.init(wm);
    @import("workspaces").init(wm);
    @import("tiling").init(wm);
}

pub fn deinitModules(wm: *WM) void {
    @import("tiling").deinit(wm);
    @import("workspaces").deinit(wm);
    window.deinit(wm);
    input.deinit(wm);
}

fn handleKeyPress(event: *xcb.xcb_key_press_event_t, wm: *WM) void {
    input.handleKeyPress(event, wm);
}

fn handleButtonPress(event: *xcb.xcb_button_press_event_t, wm: *WM) void {
    input.handleButtonPress(event, wm);
}

fn handleButtonRelease(event: *xcb.xcb_button_release_event_t, wm: *WM) void {
    input.handleButtonRelease(event, wm);
}

fn handleMotionNotify(event: *xcb.xcb_motion_notify_event_t, wm: *WM) void {
    input.handleMotionNotify(event, wm);
}

fn handleEnterNotify(event: *xcb.xcb_enter_notify_event_t, wm: *WM) void {
    window.handleEnterNotify(event, wm);
}

fn handleMapRequest(event: *xcb.xcb_map_request_event_t, wm: *WM) void {
    window.handleMapRequest(event, wm);
}

fn handleConfigureRequest(event: *xcb.xcb_configure_request_event_t, wm: *WM) void {
    window.handleConfigureRequest(event, wm);
}

fn handleDestroyNotify(event: *xcb.xcb_destroy_notify_event_t, wm: *WM) void {
    window.handleDestroyNotify(event, wm);
}

fn handleExpose(event: *xcb.xcb_expose_event_t, wm: *WM) void {
    bar.handleExpose(event, wm);
}

fn handlePropertyNotify(event: *xcb.xcb_property_notify_event_t, wm: *WM) void {
    bar.handlePropertyNotify(event, wm);
}
