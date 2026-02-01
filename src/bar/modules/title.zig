///! Title segment

const std = @import("std");
const defs = @import("defs");
const xcb = defs.xcb;
const drawing = @import("drawing");
const workspaces = @import("workspaces");
const utils = @import("utils");

var cached_net_wm_name: ?u32 = null;
var cached_utf8_string: ?u32 = null;

pub fn draw(dc: *drawing.DrawContext, config: defs.BarConfig, height: u16, start_x: u16, width: u16,
    wm: *defs.WM, cached_title: *std.ArrayList(u8), cached_title_window: *?u32, allocator: std.mem.Allocator) !u16 {
    const ws_state = workspaces.getState() orelse return start_x + width;
    const has_windows = ws_state.workspaces[ws_state.current].windows.items.len > 0;
    const is_focused = has_windows and wm.focused_window != null;
    
    dc.fillRect(start_x, 0, width, height,
        if (is_focused and config.title_accent) config.getTitleAccent() else config.bg);

    if (has_windows) {
        const title = try getFocusedWindowTitle(wm, cached_title, cached_title_window, allocator);
        if (title.len > 0) try dc.drawTextEllipsis(start_x + config.padding, dc.baselineY(height),
            title, width - config.padding * 2,
            if (is_focused and config.title_accent) config.selected_fg else config.fg);
    }
    return start_x + width;
}

fn fetchProperty(conn: *xcb.xcb_connection_t, win: u32, atom: u32, atom_type: u32,
    cached_title: *std.ArrayList(u8), cached_title_window: *?u32, allocator: std.mem.Allocator) ![]const u8 {
    const reply = xcb.xcb_get_property_reply(conn,
        xcb.xcb_get_property(conn, 0, win, atom, atom_type, 0, 256), null) orelse return "";
    defer std.c.free(reply);
    if (reply.*.format != 8 or reply.*.value_len == 0) return "";

    cached_title.clearRetainingCapacity();
    try cached_title.appendSlice(allocator,
        @as([*]const u8, @ptrCast(xcb.xcb_get_property_value(reply)))[0..@intCast(reply.*.value_len)]);
    cached_title_window.* = win;
    return cached_title.items;
}

fn getFocusedWindowTitle(wm: *defs.WM, cached_title: *std.ArrayList(u8),
    cached_title_window: *?u32, allocator: std.mem.Allocator) ![]const u8 {
    const win = wm.focused_window orelse {
        cached_title_window.* = null;
        return "";
    };
    if (cached_title_window.* == win and cached_title.items.len > 0) return cached_title.items;

    if (cached_net_wm_name == null) cached_net_wm_name = utils.getAtom(wm.conn, "_NET_WM_NAME") catch null;
    if (cached_utf8_string == null) cached_utf8_string = utils.getAtom(wm.conn, "UTF8_STRING") catch xcb.XCB_ATOM_STRING;

    if (cached_net_wm_name) |net_wm_name| {
        const title = try fetchProperty(wm.conn, win, net_wm_name,
            cached_utf8_string orelse xcb.XCB_ATOM_STRING, cached_title, cached_title_window, allocator);
        if (title.len > 0) return title;
    }
    return try fetchProperty(wm.conn, win, xcb.XCB_ATOM_WM_NAME, xcb.XCB_ATOM_STRING,
        cached_title, cached_title_window, allocator);
}
