//! Title segment — shows the focused window title, or a split view for multiple windows.

const std        = @import("std");
const defs       = @import("defs");
const xcb        = defs.xcb;
const drawing    = @import("drawing");
const workspaces = @import("workspaces");
const utils      = @import("utils");
const minimize   = @import("minimize");

var net_wm_name: ?u32 = null;
var utf8_string: ?u32 = null;

/// Lazily resolves title-related atoms. Safe to call on every draw after first load.
fn ensureAtoms(conn: *xcb.xcb_connection_t) void {
    net_wm_name = net_wm_name orelse utils.getAtom(conn, "_NET_WM_NAME") catch null;
    utf8_string = utf8_string orelse utils.getAtom(conn, "UTF8_STRING")  catch xcb.XCB_ATOM_STRING;
}

const WindowInfo = struct {
    window:    u32,
    x:         i16,
    y:         i16,
    title:     []const u8,
    minimized: bool,
};

const WindowGeometry = struct { x: i16, y: i16, width: u16, height: u16 };

/// Draws the title segment at `start_x`, returning `start_x + width`.
pub fn draw(
    dc:                   *drawing.DrawContext,
    config:               defs.BarConfig,
    height:               u16,
    start_x:              u16,
    width:                u16,
    wm:                   *defs.WM,
    cached_title:         *std.ArrayList(u8),
    cached_title_window:  *?u32,
    allocator:            std.mem.Allocator,
) !u16 {
    const ws_state     = workspaces.getState() orelse return start_x + width;
    const current_ws   = &ws_state.workspaces[ws_state.current];
    const window_count = current_ws.windows.count();

    if (window_count == 0) {
        dc.fillRect(start_x, 0, width, height, config.bg);
        return start_x + width;
    }

    const scaled_padding = config.scaledPadding();

    if (window_count == 1) {
        const single_win   = current_ws.windows.items()[0];
        const is_minimized = minimize.isMinimized(single_win);
        const is_focused   = wm.focused_window != null;

        const accent = if (is_minimized)
            config.getTitleMinimizedAccent()
        else if (is_focused)
            config.getTitleAccent()
        else
            config.bg;
        dc.fillRect(start_x, 0, width, height, accent);

        if (is_minimized) {
            // focused_window is null when minimized, so fetch the title directly.
            const title = getWindowTitle(wm.conn, single_win, allocator) catch null;
            defer if (title) |t| allocator.free(t);
            if (title) |t| {
                try dc.drawTextEllipsis(start_x + scaled_padding, dc.baselineY(height),
                    t, width -| scaled_padding * 2, config.fg);
            }
        } else {
            const title = try getFocusedWindowTitle(wm, cached_title, cached_title_window, allocator);
            if (title.len > 0) {
                try dc.drawTextEllipsis(start_x + scaled_padding, dc.baselineY(height),
                    title, width -| scaled_padding * 2,
                    if (is_focused) config.selected_fg else config.fg);
            }
        }
    } else {
        try drawSegmentedTitles(dc, config, height, start_x, width, wm, current_ws, allocator, scaled_padding);
    }

    return start_x + width;
}

/// Draws each window as an equal-width horizontal segment, sorted by on-screen position.
fn drawSegmentedTitles(
    dc:             *drawing.DrawContext,
    config:         defs.BarConfig,
    height:         u16,
    start_x:        u16,
    width:          u16,
    wm:             *defs.WM,
    workspace:      anytype,
    allocator:      std.mem.Allocator,
    scaled_padding: u16,
) !void {
    var window_infos = std.ArrayList(WindowInfo){};
    defer {
        for (window_infos.items) |info| {
            // Only free heap-allocated titles; empty string "" is a literal.
            if (info.title.len > 0) allocator.free(info.title);
        }
        window_infos.deinit(allocator);
    }

    for (workspace.windows.items()) |win| {
        const is_min   = minimize.isMinimized(win);
        // Minimized windows are off-screen; use sentinel geometry to sort them last.
        const geom: WindowGeometry = if (!is_min)
            getWindowGeometry(wm.conn, win) catch continue
        else
            .{ .x = std.math.maxInt(i16), .y = std.math.maxInt(i16), .width = 0, .height = 0 };
        const title = getWindowTitle(wm.conn, win, allocator) catch null;
        try window_infos.append(allocator, .{
            .window    = win,
            .x         = geom.x,
            .y         = geom.y,
            .title     = title orelse "",
            .minimized = is_min,
        });
    }

    if (window_infos.items.len == 0) return;

    std.mem.sort(WindowInfo, window_infos.items, {}, compareWindows);

    const num_windows:    u32 = @intCast(window_infos.items.len);
    const segment_width: u16 = @intCast(@divFloor(@as(u32, width), num_windows));
    if (segment_width == 0) return;

    for (window_infos.items, 0..) |info, i| {
        const segment_x       = start_x + @as(u16, @intCast(@as(u32, @intCast(i)) * segment_width));
        const is_focused_win  = wm.focused_window == info.window;

        // Colour priority: focused > minimized > unfocused.
        const accent = if (is_focused_win)  config.getTitleAccent()
            else if (info.minimized)         config.getTitleMinimizedAccent()
            else                             config.getTitleUnfocusedAccent();

        dc.fillRect(segment_x, 0, segment_width, height, accent);

        if (info.title.len > 0 and segment_width > scaled_padding * 2) {
            try dc.drawTextEllipsis(
                segment_x + scaled_padding,
                dc.baselineY(height),
                info.title,
                segment_width -| scaled_padding * 2,
                if (is_focused_win) config.selected_fg else config.fg,
            );
        }
    }
}

/// Comparator: non-minimized before minimized; then left-to-right, top-to-bottom.
fn compareWindows(_: void, a: WindowInfo, b: WindowInfo) bool {
    if (a.minimized != b.minimized) return !a.minimized;
    if (a.x != b.x) return a.x < b.x;
    if (a.y != b.y) return a.y < b.y;
    return a.window < b.window;
}

/// Fetches the geometry of `window` from the X server.
fn getWindowGeometry(conn: *xcb.xcb_connection_t, window: u32) !WindowGeometry {
    const cookie = xcb.xcb_get_geometry(conn, window);
    const reply  = xcb.xcb_get_geometry_reply(conn, cookie, null) orelse return error.GeometryQueryFailed;
    defer std.c.free(reply);
    return .{ .x = reply.*.x, .y = reply.*.y, .width = reply.*.width, .height = reply.*.height };
}

/// Fetches a string property from `win`, allocating the result. Returns null when absent.
fn fetchProperty(conn: *xcb.xcb_connection_t, win: u32, atom: u32, atom_type: u32, allocator: std.mem.Allocator) !?[]const u8 {
    const cookie = xcb.xcb_get_property(conn, 0, win, atom, atom_type, 0, 8192);
    const reply  = xcb.xcb_get_property_reply(conn, cookie, null) orelse return null;
    defer std.c.free(reply);
    const len = xcb.xcb_get_property_value_length(reply);
    if (len <= 0) return null;
    const value: [*]const u8 = @ptrCast(xcb.xcb_get_property_value(reply));
    return try allocator.dupe(u8, value[0..@intCast(len)]);
}

/// Fetches `_NET_WM_NAME` (UTF-8), falling back to `WM_NAME` (Latin-1).
/// Returns null when neither property is set.
fn getWindowTitle(conn: *xcb.xcb_connection_t, window: u32, allocator: std.mem.Allocator) !?[]const u8 {
    ensureAtoms(conn);
    if (net_wm_name) |atom| {
        if (try fetchProperty(conn, window, atom, utf8_string.?, allocator)) |t| return t;
    }
    return try fetchProperty(conn, window, xcb.XCB_ATOM_WM_NAME, xcb.XCB_ATOM_STRING, allocator);
}

/// Returns the title of the focused window, using a cached ArrayList buffer to avoid
/// redundant X round-trips. Returns "" when no window is focused.
fn getFocusedWindowTitle(
    wm:                  *defs.WM,
    cached_title:        *std.ArrayList(u8),
    cached_title_window: *?u32,
    allocator:           std.mem.Allocator,
) ![]const u8 {
    const win = wm.focused_window orelse {
        cached_title_window.* = null;
        return "";
    };

    if (cached_title_window.* == win and cached_title.items.len > 0) return cached_title.items;

    ensureAtoms(wm.conn);

    if (net_wm_name) |atom| {
        const title = try utils.fetchPropertyToBuffer(wm.conn, win, atom, utf8_string.?, cached_title, allocator);
        if (title.len > 0) { cached_title_window.* = win; return title; }
    }

    const title = try utils.fetchPropertyToBuffer(wm.conn, win, xcb.XCB_ATOM_WM_NAME, xcb.XCB_ATOM_STRING, cached_title, allocator);
    if (title.len > 0) cached_title_window.* = win;
    return title;
}
