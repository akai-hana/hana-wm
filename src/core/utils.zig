//! # Core Utilities Module
//!
//! Provides common utility functions for X11 operations, geometry manipulation,
//! and window property queries.

const std = @import("std");
const defs = @import("defs");
const xcb = defs.xcb;
const debug = @import("debug");

const MAX_PROPERTY_LENGTH: u32 = 256;

/// Maximum length to read from XCB property values (in bytes)
pub const XCB_PROPERTY_MAX_VALUE_LENGTH: usize = 1024;

/// Flag for xcb_get_property - do not delete the property after reading
pub const XCB_PROPERTY_NO_DELETE: u8 = 0;

pub inline fn flush(conn: *xcb.xcb_connection_t) void {
    _ = xcb.xcb_flush(conn);
}

pub inline fn configureBorder(conn: *xcb.xcb_connection_t, win: u32, width: u16, color: u32) void {
    _ = xcb.xcb_configure_window(conn, win, xcb.XCB_CONFIG_WINDOW_BORDER_WIDTH, &[_]u32{width});
    _ = xcb.xcb_change_window_attributes(conn, win, xcb.XCB_CW_BORDER_PIXEL, &[_]u32{color});
}

pub const Rect = struct {
    x: i16,
    y: i16,
    width: u16,
    height: u16,

    pub inline fn fromXcb(geom: *const xcb.xcb_get_geometry_reply_t) Rect {
        return .{ .x = geom.x, .y = geom.y, .width = geom.width, .height = geom.height };
    }

    pub inline fn isValid(self: Rect) bool {
        return self.width >= defs.MIN_WINDOW_DIM and self.height >= defs.MIN_WINDOW_DIM;
    }
};

pub const Margins = struct {
    gap: u16,
    border: u16,
    
    pub inline fn total(self: Margins) u16 {
        return 2 * self.gap + 2 * self.border;
    }
};

pub fn configureWindow(conn: *xcb.xcb_connection_t, win: u32, rect: Rect) void {
    _ = xcb.xcb_configure_window(
        conn,
        win,
        xcb.XCB_CONFIG_WINDOW_X | xcb.XCB_CONFIG_WINDOW_Y |
            xcb.XCB_CONFIG_WINDOW_WIDTH | xcb.XCB_CONFIG_WINDOW_HEIGHT,
        &[_]u32{
            @bitCast(@as(i32, rect.x)),
            @bitCast(@as(i32, rect.y)),
            rect.width,
            rect.height,
        },
    );
}

pub fn getGeometry(conn: *xcb.xcb_connection_t, win: u32) ?Rect {
    const reply = xcb.xcb_get_geometry_reply(conn, xcb.xcb_get_geometry(conn, win), null) orelse return null;
    defer std.c.free(reply);
    return Rect.fromXcb(reply);
}

pub inline fn normalizeModifiers(state: u16) u16 {
    return state & defs.MOD_MASK_RELEVANT;
}

/// Batched XCB operations for improved performance
pub const BatchOps = struct {
    cookies: std.ArrayListUnmanaged(xcb.xcb_void_cookie_t),
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator) BatchOps {
        return .{
            .cookies = .{},
            .allocator = allocator,
        };
    }
    
    pub fn deinit(self: *BatchOps) void {
        self.cookies.deinit(self.allocator);
    }
    
    /// Configure window geometry (position and size)
    pub fn configureWindow(
        self: *BatchOps,
        conn: *xcb.xcb_connection_t,
        win: u32,
        rect: Rect,
    ) !void {
        try self.cookies.append(self.allocator,
            xcb.xcb_configure_window_checked(
                conn, win,
                xcb.XCB_CONFIG_WINDOW_X | xcb.XCB_CONFIG_WINDOW_Y |
                xcb.XCB_CONFIG_WINDOW_WIDTH | xcb.XCB_CONFIG_WINDOW_HEIGHT,
                &[_]u32{
                    @bitCast(@as(i32, rect.x)),
                    @bitCast(@as(i32, rect.y)),
                    rect.width,
                    rect.height,
                }));
    }
    
    /// Configure border width and color
    pub fn configureBorder(
        self: *BatchOps,
        conn: *xcb.xcb_connection_t,
        win: u32,
        width: u16,
        color: u32,
    ) !void {
        try self.cookies.ensureUnusedCapacity(self.allocator, 2);
        
        self.cookies.appendAssumeCapacity(
            xcb.xcb_configure_window_checked(
                conn, win, 
                xcb.XCB_CONFIG_WINDOW_BORDER_WIDTH, 
                &[_]u32{width}));
        
        self.cookies.appendAssumeCapacity(
            xcb.xcb_change_window_attributes_checked(
                conn, win, 
                xcb.XCB_CW_BORDER_PIXEL, 
                &[_]u32{color}));
    }
    
    /// Flush all batched operations and check for errors
    pub fn flush(self: *BatchOps, conn: *xcb.xcb_connection_t) bool {
        var had_errors = false;
        for (self.cookies.items) |cookie| {
            if (xcb.xcb_request_check(conn, cookie)) |err| {
                std.c.free(err);
                had_errors = true;
            }
        }
        self.cookies.clearRetainingCapacity();
        return !had_errors;
    }
    
    /// Clear all pending operations without checking
    pub fn clear(self: *BatchOps) void {
        self.cookies.clearRetainingCapacity();
    }
};

const AtomCache = struct {
    wm_protocols: u32,
    wm_delete: u32,
    wm_take_focus: u32,
    net_wm_name: u32,
    utf8_string: u32,
};

var atom_cache: ?AtomCache = null;

pub fn initAtomCache(conn: *xcb.xcb_connection_t) !void {
    atom_cache = AtomCache{
        .wm_protocols = try getAtom(conn, "WM_PROTOCOLS"),
        .wm_delete = try getAtom(conn, "WM_DELETE_WINDOW"),
        .wm_take_focus = try getAtom(conn, "WM_TAKE_FOCUS"),
        .net_wm_name = try getAtom(conn, "_NET_WM_NAME"),
        .utf8_string = try getAtom(conn, "UTF8_STRING"),
    };
}

pub fn getAtom(conn: *xcb.xcb_connection_t, name: []const u8) !u32 {
    const reply = xcb.xcb_intern_atom_reply(
        conn,
        xcb.xcb_intern_atom(conn, 0, @intCast(name.len), name.ptr),
        null,
    ) orelse {
        debug.err("Failed to intern atom: {s}", .{name});
        return error.AtomFailed;
    };
    defer std.c.free(reply);
    return reply.*.atom;
}

pub fn getAtomCached(name: []const u8) !u32 {
    const cache = atom_cache orelse return error.AtomCacheNotInitialized;
    
    if (std.mem.eql(u8, name, "WM_PROTOCOLS")) return cache.wm_protocols;
    if (std.mem.eql(u8, name, "WM_DELETE_WINDOW")) return cache.wm_delete;
    if (std.mem.eql(u8, name, "WM_TAKE_FOCUS")) return cache.wm_take_focus;
    if (std.mem.eql(u8, name, "_NET_WM_NAME")) return cache.net_wm_name;
    if (std.mem.eql(u8, name, "UTF8_STRING")) return cache.utf8_string;
    
    return error.AtomNotInCache;
}

/// Fetch an XCB property and write its value to an ArrayList buffer
pub fn fetchPropertyToBuffer(
    conn: *xcb.xcb_connection_t,
    window: u32,
    atom: u32,
    atom_type: u32,
    buffer: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
) ![]const u8 {
    const reply = xcb.xcb_get_property_reply(conn,
        xcb.xcb_get_property(conn, XCB_PROPERTY_NO_DELETE, window, atom, atom_type, 0, MAX_PROPERTY_LENGTH),
        null
    ) orelse return "";
    defer std.c.free(reply);
    
    if (reply.*.format != 8 or reply.*.value_len == 0) return "";
    
    buffer.clearRetainingCapacity();
    const actual_len = @min(@as(usize, @intCast(reply.*.value_len)), XCB_PROPERTY_MAX_VALUE_LENGTH);
    const value_ptr: [*]const u8 = @ptrCast(xcb.xcb_get_property_value(reply));
    try buffer.appendSlice(allocator, value_ptr[0..actual_len]);
    
    return buffer.items;
}

// WM_TAKE_FOCUS caching for ~50µs speedup per focus
var wm_take_focus_cache: ?std.AutoHashMap(u32, bool) = null;

pub fn initWMTakeFocusCache(allocator: std.mem.Allocator) void {
    wm_take_focus_cache = std.AutoHashMap(u32, bool).init(allocator);
}

pub fn deinitWMTakeFocusCache() void {
    if (wm_take_focus_cache) |*cache| {
        cache.deinit();
        wm_take_focus_cache = null;
    }
}

/// Cache WM_TAKE_FOCUS support for a window (call on MapRequest)
pub fn cacheWMTakeFocus(conn: *xcb.xcb_connection_t, win: u32) void {
    if (wm_take_focus_cache) |*cache| {
        const supports = queryWMTakeFocusSupport(conn, win);
        cache.put(win, supports) catch {};
    }
}

/// Remove cached WM_TAKE_FOCUS support (call on DestroyNotify)
pub fn uncacheWMTakeFocus(win: u32) void {
    if (wm_take_focus_cache) |*cache| {
        _ = cache.remove(win);
    }
}

/// Check if window supports WM_TAKE_FOCUS (cached version for performance)
pub fn supportsWMTakeFocusCached(conn: *xcb.xcb_connection_t, win: u32) bool {
    if (wm_take_focus_cache) |*cache| {
        if (cache.get(win)) |cached| return cached;
    }
    
    const supports = queryWMTakeFocusSupport(conn, win);
    
    if (wm_take_focus_cache) |*cache| {
        cache.put(win, supports) catch {};
    }
    
    return supports;
}

pub const WMClass = struct {
    instance: []const u8,
    class: []const u8,
    
    pub fn deinit(self: WMClass, allocator: std.mem.Allocator) void {
        allocator.free(self.instance);
        allocator.free(self.class);
    }
};

pub fn getWMClass(conn: *xcb.xcb_connection_t, win: u32, allocator: std.mem.Allocator) ?WMClass {
    const class_atom = getAtom(conn, "WM_CLASS") catch return null;
    
    const reply = xcb.xcb_get_property_reply(conn,
        xcb.xcb_get_property(conn, 0, win, class_atom, xcb.XCB_ATOM_STRING, 0, MAX_PROPERTY_LENGTH), null) orelse return null;
    defer std.c.free(reply);
    
    if (reply.*.format != 8 or reply.*.value_len == 0) return null;
    
    const data: [*]const u8 = @ptrCast(xcb.xcb_get_property_value(reply));
    const len: usize = @intCast(reply.*.value_len);
    
    var null_idx: ?usize = null;
    for (data[0..len], 0..) |byte, i| {
        if (byte == 0) {
            null_idx = i;
            break;
        }
    }
    
    if (null_idx == null) return null;
    const sep = null_idx.?;
    
    const instance = allocator.dupe(u8, data[0..sep]) catch return null;
    errdefer allocator.free(instance);
    
    const class_start = sep + 1;
    if (class_start >= len) {
        allocator.free(instance);
        return null;
    }
    
    const class = allocator.dupe(u8, data[class_start..len]) catch {
        allocator.free(instance);
        return null;
    };
    
    return .{ .instance = instance, .class = class };
}

fn queryWMTakeFocusSupport(conn: *xcb.xcb_connection_t, win: u32) bool {
    const protocols_atom = getAtomCached("WM_PROTOCOLS") catch return false;
    
    const reply = xcb.xcb_get_property_reply(conn,
        xcb.xcb_get_property(conn, 0, win, protocols_atom, xcb.XCB_ATOM_ATOM, 0, MAX_PROPERTY_LENGTH), null) orelse return false;
    defer std.c.free(reply);
    
    if (reply.*.format != 32 or reply.*.value_len == 0) return false;
    
    const take_focus_atom = getAtomCached("WM_TAKE_FOCUS") catch return false;
    const atoms: [*]const u32 = @ptrCast(@alignCast(xcb.xcb_get_property_value(reply)));
    const len: usize = @intCast(reply.*.value_len);
    
    for (atoms[0..len]) |atom| {
        if (atom == take_focus_atom) return true;
    }
    
    return false;
}

pub fn sendWMTakeFocus(conn: *xcb.xcb_connection_t, win: u32) void {
    const protocols_atom = getAtomCached("WM_PROTOCOLS") catch return;
    const take_focus_atom = getAtomCached("WM_TAKE_FOCUS") catch return;
    
    var event: xcb.xcb_client_message_event_t = std.mem.zeroes(xcb.xcb_client_message_event_t);
    event.response_type = xcb.XCB_CLIENT_MESSAGE;
    event.window = win;
    event.type = protocols_atom;
    event.format = 32;
    event.data.data32[0] = take_focus_atom;
    event.data.data32[1] = xcb.XCB_CURRENT_TIME;
    
    _ = xcb.xcb_send_event(conn, 0, win, xcb.XCB_EVENT_MASK_NO_EVENT, @ptrCast(&event));
}
