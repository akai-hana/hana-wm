// Window management - ABSOLUTELY MINIMAL (less than TinyWM!)

const std     = @import("std");
const defs    = @import("defs");
const builtin = @import("builtin");
const xcb     = defs.xcb;
const WM      = defs.WM;
const Module  = defs.Module;

// Only handle the absolute minimum events
pub const EVENT_TYPES = [_]u8{
    xcb.XCB_MAP_REQUEST,
    xcb.XCB_CONFIGURE_REQUEST,
    xcb.XCB_DESTROY_NOTIFY,
    // NO ENTER_NOTIFY - let's not touch focus at all!
    // NO FOCUS_IN - games manage their own focus
};

pub fn init(_: *WM) void {
    if (builtin.mode == .Debug) {
        std.debug.print("[window] Module initialized\n", .{});
    }
}

pub const deinit = defs.defaultModuleDeinit;

pub fn handleEvent(event_type: u8, event: *anyopaque, wm: *WM) void {
    const response_type = event_type & ~defs.X11_SYNTHETIC_EVENT_FLAG;

    switch (response_type) {
        xcb.XCB_MAP_REQUEST => {
            const ev = @as(*xcb.xcb_map_request_event_t, @alignCast(@ptrCast(event)));
            handleMapRequest(ev, wm);
        },
        xcb.XCB_CONFIGURE_REQUEST => {
            const ev = @as(*xcb.xcb_configure_request_event_t, @alignCast(@ptrCast(event)));
            handleConfigureRequest(ev, wm);
        },
        xcb.XCB_DESTROY_NOTIFY => {
            const ev = @as(*xcb.xcb_destroy_notify_event_t, @alignCast(@ptrCast(event)));
            handleDestroyNotify(ev, wm);
        },
        else => {},
    }
}

fn handleMapRequest(event: *const xcb.xcb_map_request_event_t, wm: *WM) void {
    const window = event.window;

    if (builtin.mode == .Debug) {
        std.debug.print("[window] Map request for window {x}\n", .{window});
    }

    // Just map the window - NOTHING ELSE!
    // Don't select events, don't set attributes, don't track it
    _ = xcb.xcb_map_window(wm.conn, window);
    _ = xcb.xcb_flush(wm.conn);

    if (builtin.mode == .Debug) {
        std.debug.print("[window] Mapped window {x}\n", .{window});
    }
}

fn handleConfigureRequest(event: *const xcb.xcb_configure_request_event_t, wm: *WM) void {
    const window = event.window;

    // Just grant the configure request as-is
    const values = [_]u32{
        @intCast(event.x),
        @intCast(event.y),
        @intCast(event.width),
        @intCast(event.height),
        @intCast(event.border_width),
    };

    _ = xcb.xcb_configure_window(
        wm.conn,
        window,
        event.value_mask,
        &values
    );

    if (builtin.mode == .Debug) {
        std.debug.print("[window] Configure: window {x} -> {}x{} at ({},{})\n",
            .{window, event.width, event.height, event.x, event.y});
    }
}

fn handleDestroyNotify(event: *const xcb.xcb_destroy_notify_event_t, wm: *WM) void {
    if (builtin.mode == .Debug) {
        std.debug.print("[window] Window {x} destroyed\n", .{event.window});
    }

    // If we were tracking this window, stop
    _ = wm.windows.remove(event.window);

    if (wm.focused_window) |fid| {
        if (fid == event.window) {
            wm.focused_window = null;
        }
    }
}

pub fn createModule() Module {
    return Module{
        .name = "window",
        .event_types = &EVENT_TYPES,
        .init_fn = init,
        .handle_fn = handleEvent,
    };
}
