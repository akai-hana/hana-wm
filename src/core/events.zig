//! Optimized event system with comptime dispatch and minimal overhead
const std = @import("std");
const defs = @import("defs");
const xcb = defs.xcb;
const WM = defs.WM;

// Forward declare handlers
const window = @import("window");
const input = @import("input");
const tiling = @import("tiling");
const workspaces = @import("workspaces");

// ============================================================================
// EVENT HANDLER FUNCTION TYPE
// ============================================================================

const HandlerFn = *const fn (*anyopaque, *WM) void;

// ============================================================================
// COMPTIME EVENT DISPATCH TABLE
// ============================================================================

const EventHandlers = struct {
    // Core window events
    map_request: HandlerFn,
    configure_request: HandlerFn,
    destroy_notify: HandlerFn,
    enter_notify: HandlerFn,

    // Input events
    key_press: HandlerFn,
    button_press: HandlerFn,
    button_release: HandlerFn,
    motion_notify: HandlerFn,
};

fn makeHandlers() EventHandlers {
    return .{
        .map_request = wrapHandler(xcb.xcb_map_request_event_t, window.handleMapRequest),
        .configure_request = wrapHandler(xcb.xcb_configure_request_event_t, window.handleConfigureRequest),
        .destroy_notify = wrapHandler(xcb.xcb_destroy_notify_event_t, window.handleDestroyNotify),
        .enter_notify = wrapHandler(xcb.xcb_enter_notify_event_t, window.handleEnterNotify),
        .key_press = wrapHandler(xcb.xcb_key_press_event_t, input.handleKeyPress),
        .button_press = wrapHandler(xcb.xcb_button_press_event_t, input.handleButtonPress),
        .button_release = wrapHandler(xcb.xcb_button_release_event_t, input.handleButtonRelease),
        .motion_notify = wrapHandler(xcb.xcb_motion_notify_event_t, input.handleMotionNotify),
    };
}

fn wrapHandler(
    comptime EventType: type,
    comptime handler: fn (*const EventType, *WM) void,
) HandlerFn {
    return struct {
        fn wrapped(event: *anyopaque, wm: *WM) void {
            handler(@ptrCast(@alignCast(event)), wm);
        }
    }.wrapped;
}

const handlers = makeHandlers();

// ============================================================================
// FAST EVENT DISPATCH - O(1) with comptime jump table
// ============================================================================

pub fn dispatch(event_type: u8, event: *anyopaque, wm: *WM) void {
    const normalized_type = event_type & 0x7F;

    // Comptime-generated jump table - compiler optimizes to switch
    inline for (comptime std.enums.values(xcb.XcbEventType)) |evt_type| {
        if (normalized_type == @intFromEnum(evt_type)) {
            switch (evt_type) {
                .map_request => handlers.map_request(event, wm),
                .configure_request => handlers.configure_request(event, wm),
                .destroy_notify => handlers.destroy_notify(event, wm),
                .enter_notify => handlers.enter_notify(event, wm),
                .key_press => handlers.key_press(event, wm),
                .button_press => handlers.button_press(event, wm),
                .button_release => handlers.button_release(event, wm),
                .motion_notify => handlers.motion_notify(event, wm),
            }
            return;
        }
    }
}

// Helper enum for cleaner code
const XcbEventType = enum(u8) {
    map_request = xcb.XCB_MAP_REQUEST,
    configure_request = xcb.XCB_CONFIGURE_REQUEST,
    destroy_notify = xcb.XCB_DESTROY_NOTIFY,
    enter_notify = xcb.XCB_ENTER_NOTIFY,
    key_press = xcb.XCB_KEY_PRESS,
    button_press = xcb.XCB_BUTTON_PRESS,
    button_release = xcb.XCB_BUTTON_RELEASE,
    motion_notify = xcb.XCB_MOTION_NOTIFY,
};

// Alternative: Direct array lookup for even better performance
const MAX_EVENT_TYPE = 35; // XCB's highest event type
var handler_table: [MAX_EVENT_TYPE + 1]?HandlerFn = init: {
    var table: [MAX_EVENT_TYPE + 1]?HandlerFn = [_]?HandlerFn{null} ** (MAX_EVENT_TYPE + 1);
    table[xcb.XCB_MAP_REQUEST] = handlers.map_request;
    table[xcb.XCB_CONFIGURE_REQUEST] = handlers.configure_request;
    table[xcb.XCB_DESTROY_NOTIFY] = handlers.destroy_notify;
    table[xcb.XCB_ENTER_NOTIFY] = handlers.enter_notify;
    table[xcb.XCB_KEY_PRESS] = handlers.key_press;
    table[xcb.XCB_BUTTON_PRESS] = handlers.button_press;
    table[xcb.XCB_BUTTON_RELEASE] = handlers.button_release;
    table[xcb.XCB_MOTION_NOTIFY] = handlers.motion_notify;
    break :init table;
};

pub fn dispatchFast(event_type: u8, event: *anyopaque, wm: *WM) void {
    const normalized = event_type & 0x7F;
    if (normalized <= MAX_EVENT_TYPE) {
        if (handler_table[normalized]) |handler| {
            handler(event, wm);
        }
    }
}

// ============================================================================
// MODULE INITIALIZATION - Simplified
// ============================================================================

pub fn initModules(wm: *WM) void {
    workspaces.init(wm);
    window.init(wm);
    input.init(wm);
    tiling.init(wm);
}

pub fn deinitModules(wm: *WM) void {
    tiling.deinit(wm);
    input.deinit(wm);
    window.deinit(wm);
    workspaces.deinit(wm);
}
