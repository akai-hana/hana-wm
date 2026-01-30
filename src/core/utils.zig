//! Core utilities - Focus moved to focus.zig for better API

const std = @import("std");
const defs = @import("defs");
const xcb = defs.xcb;

// XCB utilities

pub fn flush(conn: *xcb.xcb_connection_t) void {
    _ = xcb.xcb_flush(conn);
}

pub fn setBorder(conn: *xcb.xcb_connection_t, win: u32, color: u32) void {
    _ = xcb.xcb_change_window_attributes(conn, win, xcb.XCB_CW_BORDER_PIXEL, &[_]u32{color});
}

pub fn setBorderWidth(conn: *xcb.xcb_connection_t, win: u32, width: u16) void {
    _ = xcb.xcb_configure_window(conn, win, xcb.XCB_CONFIG_WINDOW_BORDER_WIDTH, &[_]u32{width});
}

pub fn configureBorder(conn: *xcb.xcb_connection_t, win: u32, width: u16, color: u32) void {
    setBorderWidth(conn, win, width);
    setBorder(conn, win, color);
}

// Geometry utilities

pub const Rect = struct {
    x: i16,
    y: i16,
    width: u16,
    height: u16,

    pub fn fromXcb(geom: *const xcb.xcb_get_geometry_reply_t) Rect {
        return .{ .x = geom.x, .y = geom.y, .width = geom.width, .height = geom.height };
    }

    pub fn clamp(self: Rect) Rect {
        return .{
            .x      = self.x,
            .y      = self.y,
            .width  = std.math.clamp(self.width, defs.MIN_WINDOW_DIM, defs.MAX_WINDOW_DIM),
            .height = std.math.clamp(self.height, defs.MIN_WINDOW_DIM, defs.MAX_WINDOW_DIM),
        };
    }

    pub fn isValid(self: Rect) bool {
        return self.width >= defs.MIN_WINDOW_DIM and self.width <= defs.MAX_WINDOW_DIM and
            self.height >= defs.MIN_WINDOW_DIM and self.height <= defs.MAX_WINDOW_DIM;
    }
};

pub const Margins = struct {
    gap: u16,
    border: u16,

    pub fn total(self: Margins) u16 {
        return 2 * self.gap + 2 * self.border;
    }
};

pub fn configureWindow(conn: *xcb.xcb_connection_t, win: u32, rect: Rect) void {
    const r = rect.clamp();
    const values = [_]u32{
        @bitCast(@as(i32, r.x)),
        @bitCast(@as(i32, r.y)),
        r.width,
        r.height,
    };
    _ = xcb.xcb_configure_window(conn, win,
        xcb.XCB_CONFIG_WINDOW_X | xcb.XCB_CONFIG_WINDOW_Y |
            xcb.XCB_CONFIG_WINDOW_WIDTH | xcb.XCB_CONFIG_WINDOW_HEIGHT,
        &values);
}

pub fn getGeometry(conn: *xcb.xcb_connection_t, win: u32) ?Rect {
    const cookie = xcb.xcb_get_geometry(conn, win);
    const reply = xcb.xcb_get_geometry_reply(conn, cookie, null) orelse return null;
    defer std.c.free(reply);
    return Rect.fromXcb(reply);
}

// Modifier utilities

pub fn normalizeModifiers(state: u16) u16 {
    return state & defs.MOD_MASK_RELEVANT;
}

// Atom cache - pre-populated at startup for performance

const AtomCache = struct {
    wm_protocols: u32,
    wm_delete: u32,
    net_wm_name: u32,
    utf8_string: u32,
};

var atom_cache: ?AtomCache = null;

pub fn initAtomCache(conn: *xcb.xcb_connection_t) !void {
    const wm_protocols = try getAtom(conn, "WM_PROTOCOLS");
    const wm_delete = try getAtom(conn, "WM_DELETE_WINDOW");
    const net_wm_name = try getAtom(conn, "_NET_WM_NAME");
    const utf8_string = try getAtom(conn, "UTF8_STRING");

    atom_cache = AtomCache{
        .wm_protocols = wm_protocols,
        .wm_delete = wm_delete,
        .net_wm_name = net_wm_name,
        .utf8_string = utf8_string,
    };
}

pub fn getAtom(conn: *xcb.xcb_connection_t, name: []const u8) !u32 {
    const cookie = xcb.xcb_intern_atom(conn, 0, @intCast(name.len), name.ptr);
    const reply = xcb.xcb_intern_atom_reply(conn, cookie, null) orelse return error.AtomFailed;
    defer std.c.free(reply);
    return reply.*.atom;
}

pub fn getAtomCached(comptime name: []const u8) !u32 {
    const cache = atom_cache orelse return error.AtomCacheNotInitialized;
    
    return switch (comptime std.meta.stringToEnum(enum { 
        WM_PROTOCOLS, 
        WM_DELETE_WINDOW, 
        _NET_WM_NAME, 
        UTF8_STRING 
    }, name) orelse @compileError("Atom not in cache: " ++ name)) {
        .WM_PROTOCOLS => cache.wm_protocols,
        .WM_DELETE_WINDOW => cache.wm_delete,
        ._NET_WM_NAME => cache.net_wm_name,
        .UTF8_STRING => cache.utf8_string,
    };
}

// Window property utilities

pub const WMClass = struct {
    instance: []const u8,
    class: []const u8,

    pub fn deinit(self: WMClass, allocator: std.mem.Allocator) void {
        allocator.free(self.instance);
        allocator.free(self.class);
    }
};

pub fn getWMClass(conn: *xcb.xcb_connection_t, win: u32, allocator: std.mem.Allocator) ?WMClass {
    const cookie = xcb.xcb_get_property(
        conn,
        0,
        win,
        xcb.XCB_ATOM_WM_CLASS,
        xcb.XCB_ATOM_STRING,
        0,
        256,
    );

    const reply = xcb.xcb_get_property_reply(conn, cookie, null) orelse return null;
    defer std.c.free(reply);

    if (reply.*.format != 8 or reply.*.value_len == 0) return null;

    const data: [*]const u8 = @ptrCast(xcb.xcb_get_property_value(reply));
    const len: usize = @intCast(reply.*.value_len);

    var instance_end: usize = 0;
    while (instance_end < len and data[instance_end] != 0) : (instance_end += 1) {}

    if (instance_end >= len) return null;

    const instance = allocator.dupe(u8, data[0..instance_end]) catch return null;
    errdefer allocator.free(instance);

    const class_start = instance_end + 1;
    var class_end = class_start;
    while (class_end < len and data[class_end] != 0) : (class_end += 1) {}

    if (class_start >= len) {
        allocator.free(instance);
        return null;
    }

    const class = allocator.dupe(u8, data[class_start..class_end]) catch {
        allocator.free(instance);
        return null;
    };

    return WMClass{
        .instance = instance,
        .class    = class,
    };
}
