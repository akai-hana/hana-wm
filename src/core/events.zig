// X events handling

const std = @import("std");
const defs = @import("defs");
const xcb = defs.xcb;

const window = @import("window");
const input = @import("input");
const bar = @import("bar");
const tiling = @import("tiling");

const EventHandler = *const fn (event: *anyopaque, wm: *defs.WM) void;

// OPTIMIZATION: Compile-time event dispatch table with minimal size
const dispatch_table = blk: {
    var table = [_]?EventHandler{null} ** 36;
    table[xcb.XCB_KEY_PRESS] = @ptrCast(&input.handleKeyPress);
    table[xcb.XCB_BUTTON_PRESS] = @ptrCast(&input.handleButtonPress);
    table[xcb.XCB_BUTTON_RELEASE] = @ptrCast(&input.handleButtonRelease);
    table[xcb.XCB_MOTION_NOTIFY] = @ptrCast(&input.handleMotionNotify);
    table[xcb.XCB_ENTER_NOTIFY] = @ptrCast(&window.handleEnterNotify);
    table[xcb.XCB_MAP_REQUEST] = @ptrCast(&window.handleMapRequest);
    table[xcb.XCB_CONFIGURE_REQUEST] = @ptrCast(&window.handleConfigureRequest);
    table[xcb.XCB_DESTROY_NOTIFY] = @ptrCast(&window.handleDestroyNotify);
    table[xcb.XCB_EXPOSE] = @ptrCast(&bar.handleExpose);
    table[xcb.XCB_PROPERTY_NOTIFY] = @ptrCast(&bar.handlePropertyNotify);
    break :blk table;
};

// OPTIMIZATION: Inline dispatch for minimal overhead
pub inline fn dispatch(event_type: u8, event: *anyopaque, wm: *defs.WM) void {
    const idx = event_type & 0x7f;
    if (idx < dispatch_table.len) {
        if (dispatch_table[idx]) |handler| {
            handler(event, wm);
        }
    }
}

pub fn initModules(wm: *defs.WM) void {
    input.init(wm);
    @import("workspaces").init(wm);
    tiling.init(wm);
}

pub fn deinitModules(wm: *defs.WM) void {
    tiling.deinit(wm);
    @import("workspaces").deinit(wm);
    input.deinit(wm);
}
