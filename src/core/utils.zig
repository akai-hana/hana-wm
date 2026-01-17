//! Core utilities - unified XCB operations, geometry, and common functions
const std = @import("std");
const xcb = @import("defs").xcb;

// CONSTANTS

pub const MIN_WINDOW_DIM: u16 = 50;
pub const MAX_WINDOW_DIM: u16 = 65535;

// GEOMETRY

pub const Rect = struct {
    x: i16,
    y: i16,
    width: u16,
    height: u16,

    pub fn fromXcb(geom: *const xcb.xcb_get_geometry_reply_t) Rect {
        return .{
            .x = geom.x,
            .y = geom.y,
            .width = geom.width,
            .height = geom.height,
        };
    }

    pub fn clamp(self: Rect) Rect {
        return .{
            .x = self.x,
            .y = self.y,
            .width = std.math.clamp(self.width, MIN_WINDOW_DIM, MAX_WINDOW_DIM),
            .height = std.math.clamp(self.height, MIN_WINDOW_DIM, MAX_WINDOW_DIM),
        };
    }
};

pub const Margins = struct {
    gap: u16,
    border: u16,

    pub fn total(self: Margins) u16 {
        return 2 * self.gap + 2 * self.border;
    }

    pub fn innerRect(self: Margins, outer_w: u16, outer_h: u16) Rect {
        const margin = self.total();
        return .{
            .x = @intCast(self.gap),
            .y = @intCast(self.gap),
            .width = if (outer_w > margin) outer_w - margin else MIN_WINDOW_DIM,
            .height = if (outer_h > margin) outer_h - margin else MIN_WINDOW_DIM,
        };
    }
};

pub fn calcGridDims(n: usize) struct { cols: u16, rows: u16 } {
    if (n == 0) return .{ .cols = 1, .rows = 1 };
    const cols = @as(u16, @intFromFloat(@ceil(@sqrt(@as(f32, @floatFromInt(n))))));
    return .{ .cols = cols, .rows = @intCast((n + cols - 1) / cols) };
}

pub fn calcColumnLayout(
    total_h: u16,
    count: u16,
    margins: Margins,
) struct { item_h: u16, spacing: u16 } {
    if (count == 0) return .{ .item_h = 0, .spacing = 0 };

    // CRITICAL FIX: For n windows, we need (n+1) gaps: top, bottom, and (n-1) in between
    const gaps = @as(u32, margins.gap) * (count + 1);
    const borders = @as(u32, margins.border) * 2 * count;
    const overhead = gaps + borders;

    const available = if (total_h > overhead)
        @as(u32, total_h) - overhead
    else
        @as(u32, count) * MIN_WINDOW_DIM;

    const item_h = @max(MIN_WINDOW_DIM, @as(u16, @intCast(available / count)));
    return .{
        .item_h = item_h,
        .spacing = item_h + 2 * margins.border + margins.gap,
    };
}

// XCB OPERATIONS

pub const WindowAttrs = struct {
    x: ?i16 = null,
    y: ?i16 = null,
    width: ?u16 = null,
    height: ?u16 = null,
    border_width: ?u16 = null,
    border_color: ?u32 = null,
    stack_mode: ?u32 = null,
    event_mask: ?u32 = null,

    pub fn configure(self: WindowAttrs, conn: *xcb.xcb_connection_t, win: u32) void {
        var mask: u16 = 0;
        var values: [5]u32 = undefined;
        var idx: usize = 0;

        // CRITICAL FIX: Manually handle each field instead of using comptime string manipulation
        if (self.x) |val| {
            mask |= xcb.XCB_CONFIG_WINDOW_X;
            values[idx] = @bitCast(@as(i32, val));
            idx += 1;
        }
        if (self.y) |val| {
            mask |= xcb.XCB_CONFIG_WINDOW_Y;
            values[idx] = @bitCast(@as(i32, val));
            idx += 1;
        }
        if (self.width) |val| {
            mask |= xcb.XCB_CONFIG_WINDOW_WIDTH;
            values[idx] = val;
            idx += 1;
        }
        if (self.height) |val| {
            mask |= xcb.XCB_CONFIG_WINDOW_HEIGHT;
            values[idx] = val;
            idx += 1;
        }
        if (self.border_width) |val| {
            mask |= xcb.XCB_CONFIG_WINDOW_BORDER_WIDTH;
            values[idx] = val;
            idx += 1;
        }

        if (self.stack_mode) |sm| {
            mask |= xcb.XCB_CONFIG_WINDOW_STACK_MODE;
            values[idx] = sm;
        }

        if (mask != 0) _ = xcb.xcb_configure_window(conn, win, mask, &values);
        if (self.border_color) |bc| {
            _ = xcb.xcb_change_window_attributes(conn, win, xcb.XCB_CW_BORDER_PIXEL, &[_]u32{bc});
        }
        if (self.event_mask) |em| {
            _ = xcb.xcb_change_window_attributes(conn, win, xcb.XCB_CW_EVENT_MASK, &[_]u32{em});
        }
    }
};

pub fn configureWindow(conn: *xcb.xcb_connection_t, win: u32, rect: Rect) void {
    const r = rect.clamp();
    const attrs = WindowAttrs{
        .x = r.x,
        .y = r.y,
        .width = r.width,
        .height = r.height,
    };
    attrs.configure(conn, win);
    
    // CRITICAL: Check for connection errors after configure
    const err_code = xcb.xcb_connection_has_error(conn);
    if (err_code != 0) {
        std.log.err("[XCB] Connection error {} during configure", .{err_code});
    }
}

pub fn getGeometry(conn: *xcb.xcb_connection_t, win: u32) ?Rect {
    const cookie = xcb.xcb_get_geometry(conn, win);
    const reply = xcb.xcb_get_geometry_reply(conn, cookie, null) orelse return null;
    defer std.c.free(reply);
    return Rect.fromXcb(reply);
}

pub fn isWindowMapped(conn: *xcb.xcb_connection_t, win: u32) bool {
    const cookie = xcb.xcb_get_window_attributes(conn, win);
    const attrs = xcb.xcb_get_window_attributes_reply(conn, cookie, null) orelse return false;
    defer std.c.free(attrs);
    return attrs.*.map_state == xcb.XCB_MAP_STATE_VIEWABLE;
}

pub fn isWindowValid(conn: *xcb.xcb_connection_t, win: u32) bool {
    const cookie = xcb.xcb_get_window_attributes(conn, win);
    const attrs = xcb.xcb_get_window_attributes_reply(conn, cookie, null) orelse return false;
    defer std.c.free(attrs);
    return true;
}

pub fn batchMap(conn: *xcb.xcb_connection_t, windows: []const u32) void {
    for (windows) |win| _ = xcb.xcb_map_window(conn, win);
}

pub fn batchUnmap(conn: *xcb.xcb_connection_t, windows: []const u32) void {
    for (windows) |win| _ = xcb.xcb_unmap_window(conn, win);
}

pub inline fn flush(conn: *xcb.xcb_connection_t) void {
    _ = xcb.xcb_flush(conn);
}

// WINDOW PROPERTIES

pub const WMClass = struct {
    instance: []const u8,
    class: []const u8,

    pub fn deinit(self: WMClass, allocator: std.mem.Allocator) void {
        allocator.free(self.instance);
        allocator.free(self.class);
    }
};

pub fn getWMClass(
    conn: *xcb.xcb_connection_t,
    win: u32,
    allocator: std.mem.Allocator,
) ?WMClass {
    const wm_class_atom = blk: {
        const cookie = xcb.xcb_intern_atom(conn, 0, 8, "WM_CLASS");
        const reply = xcb.xcb_intern_atom_reply(conn, cookie, null) orelse return null;
        defer std.c.free(reply);
        break :blk reply.*.atom;
    };

    const cookie = xcb.xcb_get_property(conn, 0, win, wm_class_atom, xcb.XCB_ATOM_STRING, 0, 256);
    const reply = xcb.xcb_get_property_reply(conn, cookie, null) orelse return null;
    defer std.c.free(reply);

    // CRITICAL FIX: Add dereference operator for C pointer
    if (reply.*.value_len == 0) return null;

    const data: [*]const u8 = @ptrCast(xcb.xcb_get_property_value(reply));
    const len: usize = @intCast(xcb.xcb_get_property_value_length(reply));

    var instance_len: usize = 0;
    while (instance_len < len and data[instance_len] != 0) : (instance_len += 1) {}
    if (instance_len >= len) return null;

    const class_start = instance_len + 1;
    if (class_start >= len) return null;

    var class_len: usize = 0;
    while (class_start + class_len < len and data[class_start + class_len] != 0) : (class_len += 1) {}

    return WMClass{
        .instance = allocator.dupe(u8, data[0..instance_len]) catch return null,
        .class = allocator.dupe(u8, data[class_start .. class_start + class_len]) catch return null,
    };
}

// HELPERS

pub inline fn clampU16(val: anytype, min: u16, max: u16) u16 {
    return @min(max, @max(min, @as(u16, @intCast(val))));
}

pub inline fn normalizeModifiers(state: u16) u16 {
    return @intCast(state & @import("defs").MOD_MASK_RELEVANT);
}
