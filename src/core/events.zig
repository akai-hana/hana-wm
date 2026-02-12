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

// FIX: Corrected button press handler to avoid double focus setting
// Previously called both window.handleButtonPress AND input.handleButtonPress,
// which would set focus to different windows (event.event vs event.child)
// causing Firefox to lose focus when clicked
fn handleButtonPressCombined(event: *anyopaque, wm: *defs.WM) void {
    const ev: *const xcb.xcb_button_press_event_t = @ptrCast(@alignCast(event));
    
    // FIX: Only call window.handleButtonPress for click-to-focus
    // This handles the button grab/ungrab and focus correctly
    window.handleButtonPress(ev, wm);
    
    // Now check if this is a Super+Button drag operation
    // Only handle drag if event.child exists (not clicking on root/bar)
    if (ev.child != 0) {
        const has_super = (ev.state & defs.MOD_SUPER) != 0;
        if (has_super and (ev.detail == 1 or ev.detail == 3)) {
            drag.startDrag(wm, ev.child, ev.detail, ev.root_x, ev.root_y);
        }
    }
}

// OPTIMIZATION: Compile-time event dispatch table with minimal size
// Size is based on highest X11 event type we handle (XCB_PROPERTY_NOTIFY = 28)
// We use 36 to safely cover all event types with some margin
const dispatch_table = blk: {
    var table = [_]?EventHandler{null} ** constants.Sizes.EVENT_DISPATCH_TABLE;
    table[xcb.XCB_KEY_PRESS] = @ptrCast(&input.handleKeyPress);
    table[xcb.XCB_BUTTON_PRESS] = @ptrCast(&handleButtonPressCombined);
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
    workspaces.init(wm);
    tiling.init(wm);
}

pub fn deinitModules(wm: *defs.WM) void {
    tiling.deinit(wm);
    workspaces.deinit(wm);
    input.deinit(wm);
}
