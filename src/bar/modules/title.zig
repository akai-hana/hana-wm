///! Title segment - Dynamic N-way split for any number of windows

const std = @import("std");
const defs = @import("defs");
const xcb = defs.xcb;
const drawing = @import("drawing");
const workspaces = @import("workspaces");
const utils = @import("utils");

var net_wm_name: ?u32 = null;
var utf8_string: ?u32 = null;

const WindowInfo = struct {
    window: u32,
    x: i16,
    y: i16,
    title: []const u8,
};

pub fn draw(dc: *drawing.DrawContext, config: defs.BarConfig, height: u16, start_x: u16, width: u16,
    wm: *defs.WM, cached_title: *std.ArrayList(u8), cached_title_window: *?u32, allocator: std.mem.Allocator) !u16 {
    const ws_state = workspaces.getState() orelse return start_x + width;
    const current_ws = &ws_state.workspaces[ws_state.current];
    const window_count = current_ws.windows.count();
    
    if (window_count == 0) {
        // No windows - draw empty background
        dc.fillRect(start_x, 0, width, height, config.bg);
        return start_x + width;
    }
    
    const is_focused = wm.focused_window != null;
    const scaled_padding = config.scaledPadding();
    
    if (window_count == 1) {
        // Single window - use original single-title display with caching
        const accent = if (is_focused) config.getTitleAccent() else config.bg;
        dc.fillRect(start_x, 0, width, height, accent);
        
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
    } else {
        // Multiple windows - use N-way segmented display
        try drawSegmentedTitles(dc, config, height, start_x, width, wm, current_ws, allocator, scaled_padding);
    }
    
    return start_x + width;
}

fn drawSegmentedTitles(
    dc: *drawing.DrawContext,
    config: defs.BarConfig,
    height: u16,
    start_x: u16,
    width: u16,
    wm: *defs.WM,
    workspace: anytype,
    allocator: std.mem.Allocator,
    scaled_padding: u16,
) !void {
    // Get all windows with their positions
    var window_infos: std.ArrayList(WindowInfo) = .{};
    defer {
        // Free allocated title strings
        for (window_infos.items) |info| {
            allocator.free(info.title);
        }
        window_infos.deinit(allocator);
    }
    
    const windows = workspace.windows.items();
    for (windows) |win| {
        const geom = getWindowGeometry(wm.conn, win) catch continue; // Skip windows we can't query
        const title = getWindowTitleDirect(wm.conn, win, allocator) catch "";
        try window_infos.append(allocator, .{
            .window = win,
            .x = geom.x,
            .y = geom.y,
            .title = title,
        });
    }
    
    if (window_infos.items.len == 0) return; // Safety check
    
    // Sort windows by position (leftmost, then topmost, then oldest)
    std.mem.sort(WindowInfo, window_infos.items, {}, compareWindows);
    
    // Calculate segment width for each window
    const num_windows: u32 = @intCast(window_infos.items.len);
    const segment_width: u16 = @intCast(@divFloor(@as(u32, width), num_windows));
    
    // Ensure segment width is at least 1 pixel
    if (segment_width == 0) return;
    
    // Draw each window's segment
    for (window_infos.items, 0..) |info, i| {
        const i_u32: u32 = @intCast(i);
        const segment_x = start_x + @as(u16, @intCast(i_u32 * @as(u32, segment_width)));
        const is_focused_window = wm.focused_window == info.window;
        
        // Simple color logic: focused uses accent, unfocused uses unfocused accent
        const accent = if (is_focused_window) 
            config.getTitleAccent()
            else config.getTitleUnfocusedAccent();
        
        // Draw segment background
        dc.fillRect(segment_x, 0, segment_width, height, accent);
        
        // Draw window title if available and segment is wide enough
        if (info.title.len > 0 and segment_width > scaled_padding * 2) {
            const text_color = if (is_focused_window) config.selected_fg else config.fg;
            try dc.drawTextEllipsis(
                segment_x + scaled_padding,
                dc.baselineY(height),
                info.title,
                segment_width -| scaled_padding * 2,
                text_color
            );
        }
    }
}

fn compareWindows(_: void, a: WindowInfo, b: WindowInfo) bool {
    // Sort by x position (leftmost first)
    if (a.x != b.x) return a.x < b.x;
    // If same x, sort by y position (topmost first)
    if (a.y != b.y) return a.y < b.y;
    // If same position, keep stable order (first created appears first)
    return a.window < b.window;
}

const WindowGeometry = struct {
    x: i16,
    y: i16,
    width: u16,
    height: u16,
};

fn getWindowGeometry(conn: *xcb.xcb_connection_t, window: u32) !WindowGeometry {
    const cookie = xcb.xcb_get_geometry(conn, window);
    const reply = xcb.xcb_get_geometry_reply(conn, cookie, null) orelse return error.GeometryQueryFailed;
    defer std.c.free(reply);
    
    return WindowGeometry{
        .x = reply.*.x,
        .y = reply.*.y,
        .width = reply.*.width,
        .height = reply.*.height,
    };
}

fn getWindowTitleDirect(conn: *xcb.xcb_connection_t, window: u32, allocator: std.mem.Allocator) ![]const u8 {
    // Lazy load atoms
    net_wm_name = net_wm_name orelse utils.getAtom(conn, "_NET_WM_NAME") catch null;
    utf8_string = utf8_string orelse utils.getAtom(conn, "UTF8_STRING") catch xcb.XCB_ATOM_STRING;
    
    // Try _NET_WM_NAME first (modern UTF-8 property)
    if (net_wm_name) |atom| {
        if (try fetchPropertyDirect(conn, window, atom, utf8_string.?, allocator)) |title| {
            return title;
        }
    }
    
    // Fallback to legacy XCB_ATOM_WM_NAME
    if (try fetchPropertyDirect(conn, window, xcb.XCB_ATOM_WM_NAME, xcb.XCB_ATOM_STRING, allocator)) |title| {
        return title;
    }
    
    return try allocator.dupe(u8, ""); // Return empty string, not slice literal
}

fn fetchPropertyDirect(conn: *xcb.xcb_connection_t, win: u32, atom: u32, atom_type: u32, allocator: std.mem.Allocator) !?[]const u8 {
    const cookie = xcb.xcb_get_property(conn, 0, win, atom, atom_type, 0, 8192);
    const reply = xcb.xcb_get_property_reply(conn, cookie, null) orelse return null;
    defer std.c.free(reply);
    
    const len = xcb.xcb_get_property_value_length(reply);
    if (len <= 0) return null;
    
    const value: [*]const u8 = @ptrCast(xcb.xcb_get_property_value(reply));
    const slice = value[0..@intCast(len)];
    
    // Allocate and copy the title string
    const result = try allocator.dupe(u8, slice);
    return result;
}

// Original functions for single-window mode caching
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
