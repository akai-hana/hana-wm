//! Event dispatch

const std  = @import("std");
const defs = @import("defs");
const xcb  = defs.xcb;
const WM   = defs.WM;

const window = @import("window");
const input  = @import("input");
const bar    = @import("bar");
const tiling = @import("tiling");

// Maximum XCB event type (XCB_GE_GENERIC is 35)
const MAX_XCB_EVENT_TYPE = 36;

const EventHandler = *const fn (event: *anyopaque, wm: *WM) void;

const dispatch_table = blk: {
    var table: [MAX_XCB_EVENT_TYPE]?EventHandler = [_]?EventHandler{null} ** MAX_XCB_EVENT_TYPE;

    table[xcb.XCB_KEY_PRESS]         = @ptrCast(&input.handleKeyPress);
    table[xcb.XCB_BUTTON_PRESS]      = @ptrCast(&input.handleButtonPress);
    table[xcb.XCB_BUTTON_RELEASE]    = @ptrCast(&input.handleButtonRelease);
    table[xcb.XCB_MOTION_NOTIFY]     = @ptrCast(&input.handleMotionNotify);
    table[xcb.XCB_ENTER_NOTIFY]      = @ptrCast(&window.handleEnterNotify);
    table[xcb.XCB_MAP_REQUEST]       = @ptrCast(&window.handleMapRequest);
    table[xcb.XCB_CONFIGURE_REQUEST] = @ptrCast(&window.handleConfigureRequest);
    table[xcb.XCB_DESTROY_NOTIFY]    = @ptrCast(&window.handleDestroyNotify);
    table[xcb.XCB_EXPOSE]            = @ptrCast(&bar.handleExpose);
    table[xcb.XCB_PROPERTY_NOTIFY]   = @ptrCast(&bar.handlePropertyNotify);

    break :blk table;
};

pub fn dispatch(event_type: u8, event: *anyopaque, wm: *WM) void {
    const type_index = event_type & 0x7f;
    if (type_index < dispatch_table.len) {
        if (dispatch_table[type_index]) |handler| {
            handler(event, wm);
        }
    }
}

pub fn initModules(wm: *WM) void {
    input.init(wm);
    @import("workspaces").init(wm);
    tiling.init(wm);
}

pub fn deinitModules(wm: *WM) void {
    tiling.deinit(wm);
    @import("workspaces").deinit(wm);
    input.deinit(wm);
}
