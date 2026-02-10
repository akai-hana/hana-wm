//! # Core Utilities Module
//!
//! Provides common utility functions for X11 operations, geometry manipulation,
//! and window property queries.
//!
//! ## Dependencies:
//! - `defs`: Core WM types
//! - `xcb`: X11 bindings
//! - `debug`: Logging facilities
//!
//! ## Exports:
//! - `flush()`: Flush XCB connection
//! - `configureWindow()`: Set window geometry
//! - `getGeometry()`: Query window geometry
//! - `getAtom()`: Intern X11 atoms
//! - `getWindowProperty()`: Query window properties
//! - `normalizeModifiers()`: Normalize keyboard modifiers
//! - `Rect`: Rectangle geometry struct
//
// Core utilities (OPTIMIZED)

const std = @import("std");
const defs = @import("defs");
const xcb = defs.xcb;
const debug = @import("debug");

// Constants for X11 property queries
const MAX_PROPERTY_LENGTH: u32 = 256;

pub inline fn flush(conn: *xcb.xcb_connection_t) void {
    _ = xcb.xcb_flush(conn);
}

pub inline fn setBorder(conn: *xcb.xcb_connection_t, win: u32, color: u32) void {
    _ = xcb.xcb_change_window_attributes(conn, win, xcb.XCB_CW_BORDER_PIXEL, &[_]u32{color});
}

pub inline fn setBorderWidth(conn: *xcb.xcb_connection_t, win: u32, width: u16) void {
    _ = xcb.xcb_configure_window(conn, win, xcb.XCB_CONFIG_WINDOW_BORDER_WIDTH, &[_]u32{width});
}

// Note: This requires 2 XCB calls as border width and color use different APIs
pub inline fn configureBorder(conn: *xcb.xcb_connection_t, win: u32, width: u16, color: u32) void {
    setBorderWidth(conn, win, width);
    setBorder(conn, win, color);
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

/// Sets the geometry (position and size) of a window.
/// Note: Only configures window geometry, not other properties like border or attributes.
pub fn configureWindow(conn: *xcb.xcb_connection_t, win: u32, rect: Rect) void {
    _ = xcb.xcb_configure_window(
        conn,
        win,
        xcb.XCB_CONFIG_WINDOW_X | xcb.XCB_CONFIG_WINDOW_Y |
            xcb.XCB_CONFIG_WINDOW_WIDTH | xcb.XCB_CONFIG_WINDOW_HEIGHT,
        &[_]u32{
            // XCB expects unsigned values but uses bitcast for signed coordinates
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

pub fn getAtomCached(comptime name: []const u8) !u32 {
    const cache = atom_cache orelse return error.AtomCacheNotInitialized;
    return switch (comptime std.meta.stringToEnum(enum {
        WM_PROTOCOLS,
        WM_DELETE_WINDOW,
        WM_TAKE_FOCUS,
        _NET_WM_NAME,
        UTF8_STRING,
    }, name) orelse @compileError("Atom not in cache: " ++ name)) {
        .WM_PROTOCOLS => cache.wm_protocols,
        .WM_DELETE_WINDOW => cache.wm_delete,
        .WM_TAKE_FOCUS => cache.wm_take_focus,
        ._NET_WM_NAME => cache.net_wm_name,
        .UTF8_STRING => cache.utf8_string,
    };
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
    const reply = xcb.xcb_get_property_reply(conn,
        xcb.xcb_get_property(conn, 0, win, xcb.XCB_ATOM_WM_CLASS, xcb.XCB_ATOM_STRING, 0, MAX_PROPERTY_LENGTH), null) orelse return null;
    defer std.c.free(reply);
    
    if (reply.*.format != 8 or reply.*.value_len == 0) return null;

    const data: [*]const u8 = @ptrCast(xcb.xcb_get_property_value(reply));
    const len: usize = @intCast(reply.*.value_len);

    const instance_end = std.mem.indexOfScalar(u8, data[0..len], 0) orelse return null;
    const instance = allocator.dupe(u8, data[0..instance_end]) catch return null;
    errdefer allocator.free(instance);

    const class_start = instance_end + 1;
    if (class_start >= len) {
        allocator.free(instance);
        return null;
    }

    const class_end = if (std.mem.indexOfScalar(u8, data[class_start..len], 0)) |idx|
        class_start + idx
    else
        len;

    const class = allocator.dupe(u8, data[class_start..class_end]) catch {
        allocator.free(instance);
        return null;
    };

    return WMClass{ .instance = instance, .class = class };
}

// Check if window supports WM_TAKE_FOCUS protocol
pub fn supportsWMTakeFocus(conn: *xcb.xcb_connection_t, win: u32) bool {
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

// Send WM_TAKE_FOCUS client message to window
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
