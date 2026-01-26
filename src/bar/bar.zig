//! Status bar implementation - Event-based

const std = @import("std");
const defs = @import("defs");
const xcb = defs.xcb;
const WM = defs.WM;
const utils = @import("utils");
const drawing = @import("drawing");
const state_mod = @import("state");
const render = @import("render");

const BarState = state_mod.BarState;

var bar_state: ?*BarState = null;

pub fn init(wm: *WM) !void {
    if (!wm.config.bar.show) return error.BarDisabled;

    const screen = wm.screen;
    const width = screen.width_in_pixels;
    const height = wm.config.bar.height;

    const window = xcb.xcb_generate_id(wm.conn);

    const values = [_]u32{
        wm.config.bar.bg,
        xcb.XCB_EVENT_MASK_EXPOSURE | xcb.XCB_EVENT_MASK_BUTTON_PRESS,
    };

    _ = xcb.xcb_create_window(
        wm.conn,
        xcb.XCB_COPY_FROM_PARENT,
        window,
        screen.root,
        0,
        0,
        width,
        height,
        0,
        xcb.XCB_WINDOW_CLASS_INPUT_OUTPUT,
        screen.root_visual,
        xcb.XCB_CW_BACK_PIXEL | xcb.XCB_CW_EVENT_MASK,
        &values,
    );

    try setWindowProperties(wm.conn, window, height);

    _ = xcb.xcb_map_window(wm.conn, window);

    const dc = try drawing.DrawContext.init(wm.allocator, wm.conn, screen, window, width, height);
    errdefer dc.deinit();

    const font_str = if (wm.config.bar.font_size > 0)
        try std.fmt.allocPrint(wm.allocator, "{s}:size={}", .{ wm.config.bar.font, wm.config.bar.font_size })
    else
        wm.config.bar.font;
    defer if (wm.config.bar.font_size > 0) wm.allocator.free(font_str);

    dc.loadFont(font_str) catch |err| {
        std.log.err("[bar] Failed to load font '{s}': {}", .{ font_str, err });
        return err;
    };

    const state = try BarState.init(wm.allocator, window, width, height, dc, wm.config.bar);
    errdefer state.deinit();

    try render.draw(state, wm);

    bar_state = state;
}

pub fn deinit() void {
    if (bar_state) |state| {
        const conn = state.dc.conn;
        const window = state.window;

        state.dc.deinit();
        state.deinit();

        _ = xcb.xcb_destroy_window(@ptrCast(conn), window);

        bar_state = null;
    }
}

fn setWindowProperties(conn: *xcb.xcb_connection_t, window: u32, height: u16) !void {
    const wm_name = "hana-bar";
    _ = xcb.xcb_change_property(
        conn,
        xcb.XCB_PROP_MODE_REPLACE,
        window,
        xcb.XCB_ATOM_WM_NAME,
        xcb.XCB_ATOM_STRING,
        8,
        @intCast(wm_name.len),
        wm_name.ptr,
    );

    const wm_class = "hana-bar\x00hana-bar\x00";
    _ = xcb.xcb_change_property(
        conn,
        xcb.XCB_PROP_MODE_REPLACE,
        window,
        xcb.XCB_ATOM_WM_CLASS,
        xcb.XCB_ATOM_STRING,
        8,
        @intCast(wm_class.len),
        wm_class.ptr,
    );

    const net_wm_window_type = try getAtom(conn, "_NET_WM_WINDOW_TYPE");
    const net_wm_window_type_dock = try getAtom(conn, "_NET_WM_WINDOW_TYPE_DOCK");
    _ = xcb.xcb_change_property(
        conn,
        xcb.XCB_PROP_MODE_REPLACE,
        window,
        net_wm_window_type,
        xcb.XCB_ATOM_ATOM,
        32,
        1,
        &net_wm_window_type_dock,
    );

    const net_wm_state = try getAtom(conn, "_NET_WM_STATE");
    const net_wm_state_above = try getAtom(conn, "_NET_WM_STATE_ABOVE");
    const net_wm_state_sticky = try getAtom(conn, "_NET_WM_STATE_STICKY");
    const states = [_]u32{ net_wm_state_above, net_wm_state_sticky };
    _ = xcb.xcb_change_property(
        conn,
        xcb.XCB_PROP_MODE_REPLACE,
        window,
        net_wm_state,
        xcb.XCB_ATOM_ATOM,
        32,
        2,
        &states,
    );

    const net_wm_strut_partial = try getAtom(conn, "_NET_WM_STRUT_PARTIAL");
    const strut = [_]u32{ 0, 0, height, 0, 0, 0, 0, 0, 0, 0, 0, 0 };
    _ = xcb.xcb_change_property(
        conn,
        xcb.XCB_PROP_MODE_REPLACE,
        window,
        net_wm_strut_partial,
        xcb.XCB_ATOM_CARDINAL,
        32,
        12,
        &strut,
    );
}

fn getAtom(conn: *xcb.xcb_connection_t, name: []const u8) !u32 {
    const cookie = xcb.xcb_intern_atom(conn, 0, @intCast(name.len), name.ptr);
    const reply = xcb.xcb_intern_atom_reply(conn, cookie, null) orelse return error.AtomFailed;
    defer std.c.free(reply);
    return reply.*.atom;
}

pub fn getBar() ?*BarState {
    if (bar_state) |state| {
        if (state.isAlive()) {
            return state;
        }
    }
    return null;
}

/// Check if a window is the bar window
pub fn isBarWindow(win: u32) bool {
    if (bar_state) |state| {
        return state.window == win;
    }
    return false;
}

/// Update bar immediately (called on property changes or workspace switches)
pub fn update(wm: *WM) !void {
    if (getBar()) |state| {
        state.invalidateTitleCache();
        try render.draw(state, wm);
    }
}

/// Handle expose events (redraw when necessary)
pub fn handleExpose(event: *const xcb.xcb_expose_event_t, wm: *WM) void {
    if (getBar()) |state| {
        if (event.window == state.window) {
            // Only redraw if this is the last expose event in the sequence
            if (event.count == 0) {
                render.draw(state, wm) catch |err| {
                    if (err == error.BarNotAlive or err == error.RenderFormatQueryFailed) {
                        std.log.warn("[bar] Bar is no longer alive during expose, shutting down", .{});
                        deinit();
                        return;
                    }
                    std.log.err("[bar] Failed to handle expose: {}", .{err});
                };
            }
        }
    }
}

/// Handle property notify events (update status text when root WM_NAME changes)
pub fn handlePropertyNotify(event: *const xcb.xcb_property_notify_event_t, wm: *WM) void {
    if (getBar()) |state| {
        // Check if this is a root window WM_NAME property change
        if (event.window == wm.root and event.atom == xcb.XCB_ATOM_WM_NAME) {
            render.updateStatus(state, wm) catch |err| {
                std.log.err("[bar] Failed to update status: {}", .{err});
            };
            render.draw(state, wm) catch |err| {
                std.log.err("[bar] Failed to draw after status update: {}", .{err});
            };
        }
    }
}

pub fn handleButtonPress(event: *const xcb.xcb_button_press_event_t, wm: *WM) void {
    if (getBar()) |state| {
        if (event.event == state.window) {
            handleClick(state, wm, event.event_x);
        }
    }
}

fn handleClick(state: *BarState, wm: *WM, x: i16) void {
    _ = state;
    if (x < 0) return;

    const workspaces = @import("workspaces");
    const ws_state = workspaces.getState() orelse return;
    const ws_width: u16 = 30;
    const ws_count: u16 = @intCast(ws_state.workspaces.len);
    const total_ws_width = ws_width * ws_count;

    if (x < total_ws_width) {
        const clicked_ws: usize = @intCast(@divFloor(x, ws_width));
        if (clicked_ws < ws_state.workspaces.len) {
            workspaces.switchTo(wm, clicked_ws);
        }
    }
}

pub fn getHeight() u16 {
    if (getBar()) |state| {
        return state.height;
    }
    return 0;
}
