//! Event system with compile-time dispatch table for zero-overhead routing.

const std = @import("std");
const defs = @import("defs");
const xcb = defs.xcb;
const WM = defs.WM;

const window = @import("window");
const input = @import("input");
const tiling = @import("tiling");
const workspaces = @import("workspaces");
const bar = @import("bar");

const HandlerFn = *const fn (*anyopaque, *WM) void;

const EventHandlers = struct {
    map_request: HandlerFn,
    configure_request: HandlerFn,
    destroy_notify: HandlerFn,
    enter_notify: HandlerFn,
    key_press: HandlerFn,
    button_press: HandlerFn,
    button_release: HandlerFn,
    motion_notify: HandlerFn,
    expose: HandlerFn,
    property_notify: HandlerFn,
};

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

fn handleButtonPressWithBar(event: *const xcb.xcb_button_press_event_t, wm: *WM) void {
    bar.handleButtonPress(event, wm);
    input.handleButtonPress(event, wm);
}

fn handleExposeEvent(event: *const xcb.xcb_expose_event_t, wm: *WM) void {
    bar.handleExpose(event, wm);
}

fn handlePropertyNotify(event: *const xcb.xcb_property_notify_event_t, wm: *WM) void {
    bar.handlePropertyNotify(event, wm);
}

const handlers = blk: {
    break :blk EventHandlers{
        .map_request = wrapHandler(xcb.xcb_map_request_event_t, window.handleMapRequest),
        .configure_request = wrapHandler(xcb.xcb_configure_request_event_t, window.handleConfigureRequest),
        .destroy_notify = wrapHandler(xcb.xcb_destroy_notify_event_t, window.handleDestroyNotify),
        .enter_notify = wrapHandler(xcb.xcb_enter_notify_event_t, window.handleEnterNotify),
        .key_press = wrapHandler(xcb.xcb_key_press_event_t, input.handleKeyPress),
        .button_press = wrapHandler(xcb.xcb_button_press_event_t, handleButtonPressWithBar),
        .button_release = wrapHandler(xcb.xcb_button_release_event_t, input.handleButtonRelease),
        .motion_notify = wrapHandler(xcb.xcb_motion_notify_event_t, input.handleMotionNotify),
        .expose = wrapHandler(xcb.xcb_expose_event_t, handleExposeEvent),
        .property_notify = wrapHandler(xcb.xcb_property_notify_event_t, handlePropertyNotify),
    };
};

const MAX_EVENT_TYPE = 35;

const handler_table = blk: {
    var table: [MAX_EVENT_TYPE + 1]?HandlerFn = [_]?HandlerFn{null} ** (MAX_EVENT_TYPE + 1);
    table[xcb.XCB_MAP_REQUEST] = handlers.map_request;
    table[xcb.XCB_CONFIGURE_REQUEST] = handlers.configure_request;
    table[xcb.XCB_DESTROY_NOTIFY] = handlers.destroy_notify;
    table[xcb.XCB_ENTER_NOTIFY] = handlers.enter_notify;
    table[xcb.XCB_KEY_PRESS] = handlers.key_press;
    table[xcb.XCB_BUTTON_PRESS] = handlers.button_press;
    table[xcb.XCB_BUTTON_RELEASE] = handlers.button_release;
    table[xcb.XCB_MOTION_NOTIFY] = handlers.motion_notify;
    table[xcb.XCB_EXPOSE] = handlers.expose;
    table[xcb.XCB_PROPERTY_NOTIFY] = handlers.property_notify;
    break :blk table;
};

pub inline fn dispatch(event_type: u8, event: *anyopaque, wm: *WM) void {
    const normalized = event_type & 0x7F;
    if (normalized <= MAX_EVENT_TYPE) {
        if (handler_table[normalized]) |handler| {
            handler(event, wm);
        }
    }
}

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
