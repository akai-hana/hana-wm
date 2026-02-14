///! Title segment

const std = @import("std");
const defs = @import("defs");
const xcb = defs.xcb;
const drawing = @import("drawing");
const workspaces = @import("workspaces");
const utils = @import("utils");

var net_wm_name: ?u32 = null;
var utf8_string: ?u32 = null;

pub fn draw(dc: *drawing.DrawContext, config: defs.BarConfig, height: u16, start_x: u16, width: u16,
    wm: *defs.WM, cached_title: *std.ArrayList(u8), cached_title_window: *?u32, allocator: std.mem.Allocator) !u16 {
    const ws_state = workspaces.getState() orelse return start_x + width;
    
    // FIXED: Use count() method instead of .list.items.len
    const has_windows = ws_state.workspaces[ws_state.current].windows.count() > 0;
    const is_focused = has_windows and wm.focused_window != null;
    const scaled_padding = config.scaledPadding();
    
    dc.fillRect(start_x, 0, width, height,
        if (is_focused) config.getTitleAccent() else config.bg);

    if (has_windows) {
        const title = try getFocusedWindowTitle(wm, cached_title, cached_title_window, allocator);
        if (title.len > 0) {
            try dc.drawTextEllipsis(
                start_x + scaled_padding, 
                dc.baselineY(height),
                title, 
                width -| scaled_padding * 2,
                if (is_focused) config.selected_fg else config.fg
            );
        }
    }
    return start_x + width;
}

fn fetchProperty(conn: *xcb.xcb_connection_t, win: u32, atom: u32, atom_type: u32,
    cached_title: *std.ArrayList(u8), cached_title_window: *?u32, allocator: std.mem.Allocator) ![]const u8 {
    const text = try utils.fetchPropertyToBuffer(conn, win, atom, atom_type, cached_title, allocator);
    if (text.len > 0) cached_title_window.* = win;
    return text;
}

fn getFocusedWindowTitle(wm: *defs.WM, cached_title: *std.ArrayList(u8),
    cached_title_window: *?u32, allocator: std.mem.Allocator) ![]const u8 {
    const win = wm.focused_window orelse {
        cached_title_window.* = null;
        return "";
    };
    
    if (cached_title_window.* == win and cached_title.items.len > 0) return cached_title.items;

    // Lazy load atoms
    net_wm_name = net_wm_name orelse utils.getAtom(wm.conn, "_NET_WM_NAME") catch null;
    utf8_string = utf8_string orelse utils.getAtom(wm.conn, "UTF8_STRING") catch xcb.XCB_ATOM_STRING;

    // Try _NET_WM_NAME first (modern UTF-8 property)
    if (net_wm_name) |atom| {
        const title = try fetchProperty(wm.conn, win, atom, utf8_string.?, 
            cached_title, cached_title_window, allocator);
        if (title.len > 0) return title;
    }
    
    // Fallback to legacy XCB_ATOM_WM_NAME
    return try fetchProperty(wm.conn, win, xcb.XCB_ATOM_WM_NAME, xcb.XCB_ATOM_STRING,
        cached_title, cached_title_window, allocator);
}
