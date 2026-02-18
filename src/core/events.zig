// X event dispatch

const defs       = @import("defs");
const xcb        = defs.xcb;
const constants  = @import("constants");
const input      = @import("input");
const window     = @import("window");
const tiling     = @import("tiling");
const workspaces = @import("workspaces");
const bar        = @import("bar");

const EventHandler = *const fn (event: *anyopaque, wm: *defs.WM) void;

// PropertyNotify dispatcher - fans out to both bar (title) and window (WM_PROTOCOLS cache)
fn handlePropertyNotify(event: *anyopaque, wm: *defs.WM) void {
    const e: *xcb.xcb_property_notify_event_t = @ptrCast(@alignCast(event));
    bar.handlePropertyNotify(e, wm);
    window.handlePropertyNotify(e, wm);
}

// Comptime dispatch table for XCB O(1) event routing
const dispatch_table = blk: {
    var table = [_]?EventHandler{null} ** constants.Sizes.EVENT_DISPATCH_TABLE;
    table[xcb.XCB_KEY_PRESS]         = @ptrCast(&input.handleKeyPress);
    table[xcb.XCB_BUTTON_PRESS]      = @ptrCast(&input.handleButtonPress);
    table[xcb.XCB_BUTTON_RELEASE]    = @ptrCast(&input.handleButtonRelease);
    table[xcb.XCB_MOTION_NOTIFY]     = @ptrCast(&input.handleMotionNotify);
    table[xcb.XCB_ENTER_NOTIFY]      = @ptrCast(&window.handleEnterNotify);
    table[xcb.XCB_LEAVE_NOTIFY]      = @ptrCast(&window.handleLeaveNotify);
    table[xcb.XCB_MAP_REQUEST]       = @ptrCast(&window.handleMapRequest);
    table[xcb.XCB_CONFIGURE_REQUEST] = @ptrCast(&window.handleConfigureRequest);
    table[xcb.XCB_UNMAP_NOTIFY]      = @ptrCast(&window.handleUnmapNotify);
    table[xcb.XCB_DESTROY_NOTIFY]    = @ptrCast(&window.handleDestroyNotify);
    table[xcb.XCB_EXPOSE]            = @ptrCast(&bar.handleExpose);
    table[xcb.XCB_PROPERTY_NOTIFY]   = @ptrCast(&handlePropertyNotify);
    break :blk table;
};

// Event dispatcher to handlers
pub inline fn dispatch(event_type: u8, event: *anyopaque, wm: *defs.WM) void {
    const idx = event_type & 0x7F;
    if (idx < dispatch_table.len) {
        if (dispatch_table[idx]) |handler| handler(event, wm);
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
