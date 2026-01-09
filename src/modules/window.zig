// Window management
// This is the minimum code needed to make windows appear inside the WM.

// It handles the following events:
// - When an app wants to create a window (`MAP_REQUEST`)
// - When a window is closed (`DESTROY_NOTIFY`)
// - When mouse enters a window (`ENTER_NOTIFY`)
// - When a window gains focus (`FOCUS_IN`)

const std = @import("std");
const defs = @import("defs");

// Use xcb from defs to avoid type conflicts
const xcb = defs.xcb;

const WM = defs.WM;
const Module = defs.Module;

// Events this module handles
const HANDLED_EVENTS = [_]u8{
    xcb.XCB_MAP_REQUEST,
    xcb.XCB_DESTROY_NOTIFY,
    xcb.XCB_ENTER_NOTIFY,
    xcb.XCB_FOCUS_IN,
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
            const ev = @as(*xcb.xcb_destroy_notify_event_t, @alignCast(@ptrCast(event)));
            handleDestroyNotify(ev, wm);
        },
        xcb.XCB_ENTER_NOTIFY => {
            const ev = @as(*xcb.xcb_enter_notify_event_t, @alignCast(@ptrCast(event)));
            handleEnterNotify(ev, wm);
        },
        xcb.XCB_FOCUS_IN => {
            const ev = @as(*xcb.xcb_focus_in_event_t, @alignCast(@ptrCast(event)));
            handleFocusIn(ev, wm);
        },
        else => {},
    }
}

fn handleMapRequest(event: *const xcb.xcb_map_request_event_t, wm: *WM) void {
    const window = event.window;

    std.debug.print("[window] Map request for window {x}\n", .{window});

    // Query window geometry
    const geom_cookie = xcb.xcb_get_geometry(wm.conn, window);
    const geom_reply = xcb.xcb_get_geometry_reply(wm.conn, geom_cookie, null);
    defer if (geom_reply != null) std.c.free(geom_reply);

    var win = defs.Window{
        .id = window,
        .x = if (geom_reply) |g| g.*.x else 0,
        .y = if (geom_reply) |g| g.*.y else 0,
        .width = if (geom_reply) |g| g.*.width else 800,
        .height = if (geom_reply) |g| g.*.height else 600,
        .is_focused = false,
        .properties = .{},
    };

    // Query window properties
    win.properties = queryWindowProperties(wm, window) catch .{};

    // Add to window list
    wm.windows.append(wm.allocator, win) catch |err| {
        std.debug.print("[window] Failed to track window: {}\n", .{err});
    };

    // Configure event mask to receive enter/focus events
    const event_mask = xcb.XCB_EVENT_MASK_ENTER_WINDOW | xcb.XCB_EVENT_MASK_FOCUS_CHANGE;
    const mask = xcb.XCB_CW_EVENT_MASK;
    const values = [_]u32{event_mask};
    const attr_cookie = xcb.xcb_change_window_attributes_checked(wm.conn, window, mask, &values);
    if (xcb.xcb_request_check(wm.conn, attr_cookie)) |err| {
        std.debug.print("[window] Failed to set event mask: error code {}\n", .{err.*.error_code});
        std.c.free(err);
    }

    // Set border width
    const border_mask = xcb.XCB_CONFIG_WINDOW_BORDER_WIDTH;
    const border_values = [_]u32{wm.config.border_width};
    const border_cookie = xcb.xcb_configure_window_checked(wm.conn, window, border_mask, &border_values);
    if (xcb.xcb_request_check(wm.conn, border_cookie)) |err| {
        std.debug.print("[window] Failed to set border width: error code {}\n", .{err.*.error_code});
        std.c.free(err);
    }

    // Set border color (unfocused initially)
    const color_mask = xcb.XCB_CW_BORDER_PIXEL;
    const color_values = [_]u32{wm.config.border_unfocused};
    const color_cookie = xcb.xcb_change_window_attributes_checked(wm.conn, window, color_mask, &color_values);
    if (xcb.xcb_request_check(wm.conn, color_cookie)) |err| {
        std.debug.print("[window] Failed to set border color: error code {}\n", .{err.*.error_code});
        std.c.free(err);
    }

    // Map the window (make it visible)
    const map_cookie = xcb.xcb_map_window_checked(wm.conn, window);
    if (xcb.xcb_request_check(wm.conn, map_cookie)) |err| {
        std.debug.print("[window] Failed to map window: error code {}\n", .{err.*.error_code});
        std.c.free(err);
    }
}

fn handleDestroyNotify(event: *const xcb.xcb_destroy_notify_event_t, wm: *WM) void {
    std.debug.print("[window] Window {x} destroyed\n", .{event.window});

    // Remove from window list
    var i: usize = 0;
    while (i < wm.windows.items.len) {
        if (wm.windows.items[i].id == event.window) {
            var removed = wm.windows.swapRemove(i);
            removed.properties.deinit(wm.allocator);
            break;
        }
        i += 1;
    }

    // Clear focus if this was the focused window
    if (wm.focused_window) |fid| {
        if (fid == event.window) {
            wm.focused_window = null;
        }
    }
}

fn handleEnterNotify(event: *const xcb.xcb_enter_notify_event_t, wm: *WM) void {
    const window = event.event;
    if (window == wm.root) return;

    focusWindow(wm, window);
}

fn handleFocusIn(event: *const xcb.xcb_focus_in_event_t, wm: *WM) void {
    const window = event.event;
    if (window == wm.root) return;

    std.debug.print("[window] Focus in: {x}\n", .{window});
}

fn focusWindow(wm: *WM, window: u32) void {
    // Update focused state in window list
    for (wm.windows.items) |*win| {
        const was_focused = win.is_focused;
        win.is_focused = (win.id == window);

        // Update border color
        if (was_focused != win.is_focused) {
            const color = if (win.is_focused) wm.config.border_focused else wm.config.border_unfocused;
            const color_mask = xcb.XCB_CW_BORDER_PIXEL;
            const color_values = [_]u32{color};
            _ = xcb.xcb_change_window_attributes(wm.conn, win.id, color_mask, &color_values);
        }
    }

    wm.focused_window = window;
    _ = xcb.xcb_set_input_focus(wm.conn, xcb.XCB_INPUT_FOCUS_POINTER_ROOT, window, xcb.XCB_CURRENT_TIME);
}

fn queryWindowProperties(wm: *WM, window: u32) !defs.WindowProperties {
    var props = defs.WindowProperties{};

    // Query WM_NAME
    const name_atom = getAtom(wm, "WM_NAME");
    const name_cookie = xcb.xcb_get_property(wm.conn, 0, window, name_atom, xcb.XCB_GET_PROPERTY_TYPE_ANY, 0, 1024);
    const name_reply = xcb.xcb_get_property_reply(wm.conn, name_cookie, null);
    if (name_reply) |reply| {
        defer std.c.free(reply);
        const len = xcb.xcb_get_property_value_length(reply);
        if (len > 0) {
            const value: [*]const u8 = @ptrCast(xcb.xcb_get_property_value(reply));
            props.name = try wm.allocator.dupe(u8, value[0..@intCast(len)]);
        }
    }

    // Query WM_CLASS
    const class_atom = getAtom(wm, "WM_CLASS");
    const class_cookie = xcb.xcb_get_property(wm.conn, 0, window, class_atom, xcb.XCB_GET_PROPERTY_TYPE_ANY, 0, 1024);
    const class_reply = xcb.xcb_get_property_reply(wm.conn, class_cookie, null);
    if (class_reply) |reply| {
        defer std.c.free(reply);
        const len = xcb.xcb_get_property_value_length(reply);
        if (len > 0) {
            const value: [*]const u8 = @ptrCast(xcb.xcb_get_property_value(reply));
            props.class = try wm.allocator.dupe(u8, value[0..@intCast(len)]);
        }
    }

    return props;
}

fn getAtom(wm: *WM, name: []const u8) u32 {
    const cookie = xcb.xcb_intern_atom(wm.conn, 0, @intCast(name.len), name.ptr);
    const reply = xcb.xcb_intern_atom_reply(wm.conn, cookie, null);
    if (reply) |r| {
        defer std.c.free(r);
        return r.*.atom;
    }
    return 0;
}

pub fn createModule() Module {
    return Module{
        .name = "window",
        .event_types = &HANDLED_EVENTS,
        .init_fn = init,
        .handle_fn = handleEvent,
    };
}
