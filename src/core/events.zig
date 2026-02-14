// X events handling

const std = @import("std");
const defs = @import("defs");
const xcb = defs.xcb;
const constants = @import("constants");

const window = @import("window");
const input = @import("input");
const bar = @import("bar");
const tiling = @import("tiling");
const focus = @import("focus");
const drag = @import("drag");
const workspaces = @import("workspaces");

const EventHandler = *const fn (event: *anyopaque, wm: *defs.WM) void;

// Unified button press handler for click-to-focus and drag operations
fn handleButtonPressCombined(event: *anyopaque, wm: *defs.WM) void {
    const ev: *const xcb.xcb_button_press_event_t = @ptrCast(@alignCast(event));
    
    // Handle click-to-focus
    window.handleButtonPress(ev, wm);
    
    // Check for Super+Button drag operation
    if (ev.child != 0) {
        const has_super = (ev.state & defs.MOD_SUPER) != 0;
        if (has_super and (ev.detail == 1 or ev.detail == 3)) {
            drag.startDrag(wm, ev.child, ev.detail, ev.root_x, ev.root_y);
        }
    }
}

// Compile-time event dispatch table
const dispatch_table = blk: {
    var table = [_]?EventHandler{null} ** constants.Sizes.EVENT_DISPATCH_TABLE;
    table[xcb.XCB_KEY_PRESS] = @ptrCast(&input.handleKeyPress);
    table[xcb.XCB_BUTTON_PRESS] = @ptrCast(&handleButtonPressCombined);
    table[xcb.XCB_BUTTON_RELEASE] = @ptrCast(&input.handleButtonRelease);
    table[xcb.XCB_MOTION_NOTIFY] = @ptrCast(&input.handleMotionNotify);
    table[xcb.XCB_ENTER_NOTIFY] = @ptrCast(&window.handleEnterNotify);
    table[xcb.XCB_MAP_REQUEST] = @ptrCast(&window.handleMapRequest);
    table[xcb.XCB_CONFIGURE_REQUEST] = @ptrCast(&window.handleConfigureRequest);
    table[xcb.XCB_UNMAP_NOTIFY] = @ptrCast(&window.handleUnmapNotify);
    table[xcb.XCB_DESTROY_NOTIFY] = @ptrCast(&window.handleDestroyNotify);
    table[xcb.XCB_EXPOSE] = @ptrCast(&bar.handleExpose);
    table[xcb.XCB_PROPERTY_NOTIFY] = @ptrCast(&bar.handlePropertyNotify);
    break :blk table;
};

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
    workspaces.init(wm);
    tiling.init(wm);
}

pub fn deinitModules(wm: *defs.WM) void {
    tiling.deinit(wm);
    workspaces.deinit(wm);
    input.deinit(wm);
}
