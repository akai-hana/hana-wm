//! Core utilities — X11 geometry helpers, atom caching, WM_TAKE_FOCUS support.

const std  = @import("std");
const defs = @import("defs");
const xcb  = defs.xcb;
const debug = @import("debug");

// Internal constants (not part of the public API)
const MAX_PROPERTY_LENGTH: u32  = 256;
const PROPERTY_NO_DELETE:  u8   = 0;
const PROPERTY_MAX_VALUE:  usize = 1024;

pub inline fn flush(conn: *xcb.xcb_connection_t) void {
    _ = xcb.xcb_flush(conn);
}

pub inline fn configureBorder(conn: *xcb.xcb_connection_t, win: u32, width: u16, color: u32) void {
    _ = xcb.xcb_configure_window(conn, win, xcb.XCB_CONFIG_WINDOW_BORDER_WIDTH, &[_]u32{width});
    _ = xcb.xcb_change_window_attributes(conn, win, xcb.XCB_CW_BORDER_PIXEL, &[_]u32{color});
}

pub const Rect = struct {
    x:      i16,
    y:      i16,
    width:  u16,
    height: u16,

    pub inline fn fromXcb(geom: *const xcb.xcb_get_geometry_reply_t) Rect {
        return .{ .x = geom.x, .y = geom.y, .width = geom.width, .height = geom.height };
    }

    pub inline fn isValid(self: Rect) bool {
        return self.width >= defs.MIN_WINDOW_DIM and self.height >= defs.MIN_WINDOW_DIM;
    }
};

pub const Margins = struct {
    gap:    u16,
    border: u16,

    pub inline fn total(self: Margins) u16 {
        return 2 * self.gap + 2 * self.border;
    }
};

pub fn configureWindow(conn: *xcb.xcb_connection_t, win: u32, rect: Rect) void {
    _ = xcb.xcb_configure_window(
        conn, win,
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

// Atom cache

const AtomCache = struct {
    wm_protocols:  u32,
    wm_delete:     u32,
    wm_take_focus: u32,
    net_wm_name:   u32,
    utf8_string:   u32,
};

var atom_cache: ?AtomCache = null;

pub fn initAtomCache(conn: *xcb.xcb_connection_t) !void {
    atom_cache = .{
        .wm_protocols  = try getAtom(conn, "WM_PROTOCOLS"),
        .wm_delete     = try getAtom(conn, "WM_DELETE_WINDOW"),
        .wm_take_focus = try getAtom(conn, "WM_TAKE_FOCUS"),
        .net_wm_name   = try getAtom(conn, "_NET_WM_NAME"),
        .utf8_string   = try getAtom(conn, "UTF8_STRING"),
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
    // Map atom name to its cached field.  Using an enum + stringToEnum keeps
    // this exhaustive and avoids a chain of string comparisons.
    const AtomName = enum {
        @"WM_PROTOCOLS", @"WM_DELETE_WINDOW", @"WM_TAKE_FOCUS",
        @"_NET_WM_NAME", @"UTF8_STRING",
    };
    return switch (std.meta.stringToEnum(AtomName, name) orelse return error.AtomNotInCache) {
        .@"WM_PROTOCOLS"    => cache.wm_protocols,
        .@"WM_DELETE_WINDOW"=> cache.wm_delete,
        .@"WM_TAKE_FOCUS"   => cache.wm_take_focus,
        .@"_NET_WM_NAME"    => cache.net_wm_name,
        .@"UTF8_STRING"     => cache.utf8_string,
    };
}

// Property helpers ─────────────────────────────────────────────────────────

pub fn fetchPropertyToBuffer(
    conn:      *xcb.xcb_connection_t,
    window:    u32,
    atom:      u32,
    atom_type: u32,
    buffer:    *std.ArrayList(u8),
    allocator: std.mem.Allocator,
) ![]const u8 {
    const reply = xcb.xcb_get_property_reply(conn,
        xcb.xcb_get_property(conn, PROPERTY_NO_DELETE, window, atom, atom_type, 0, MAX_PROPERTY_LENGTH),
        null,
    ) orelse return "";
    defer std.c.free(reply);
    if (reply.*.format != 8 or reply.*.value_len == 0) return "";

    buffer.clearRetainingCapacity();
    const actual_len = @min(@as(usize, @intCast(reply.*.value_len)), PROPERTY_MAX_VALUE);
    const value_ptr: [*]const u8 = @ptrCast(xcb.xcb_get_property_value(reply));
    try buffer.appendSlice(allocator, value_ptr[0..actual_len]);
    return buffer.items;
}

// WM_TAKE_FOCUS caching ────────────────────────────────────────────────────

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

pub fn cacheWMTakeFocus(conn: *xcb.xcb_connection_t, win: u32) void {
    if (wm_take_focus_cache) |*cache| {
        cache.put(win, queryWMTakeFocusSupport(conn, win)) catch {};
    }
}

pub fn uncacheWMTakeFocus(win: u32) void {
    if (wm_take_focus_cache) |*cache| _ = cache.remove(win);
}

pub fn supportsWMTakeFocusCached(conn: *xcb.xcb_connection_t, win: u32) bool {
    if (wm_take_focus_cache) |*cache| {
        if (cache.get(win)) |cached| return cached;
    }
    const supports = queryWMTakeFocusSupport(conn, win);
    if (wm_take_focus_cache) |*cache| cache.put(win, supports) catch {};
    return supports;
}

// WM_CLASS──

pub const WMClass = struct {
    instance: []const u8,
    class:    []const u8,

    pub fn deinit(self: WMClass, allocator: std.mem.Allocator) void {
        allocator.free(self.instance);
        allocator.free(self.class);
    }
};

pub fn getWMClass(conn: *xcb.xcb_connection_t, win: u32, allocator: std.mem.Allocator) ?WMClass {
    const class_atom = getAtom(conn, "WM_CLASS") catch return null;
    const reply = xcb.xcb_get_property_reply(conn,
        xcb.xcb_get_property(conn, 0, win, class_atom, xcb.XCB_ATOM_STRING, 0, MAX_PROPERTY_LENGTH), null,
    ) orelse return null;
    defer std.c.free(reply);
    if (reply.*.format != 8 or reply.*.value_len == 0) return null;

    const data: [*]const u8 = @ptrCast(xcb.xcb_get_property_value(reply));
    const len: usize = @intCast(reply.*.value_len);

    const sep = std.mem.indexOfScalar(u8, data[0..len], 0) orelse return null;
    const class_start = sep + 1;
    if (class_start >= len) return null;

    const instance = allocator.dupe(u8, data[0..sep]) catch return null;
    const class    = allocator.dupe(u8, data[class_start..len]) catch {
        allocator.free(instance);
        return null;
    };
    return .{ .instance = instance, .class = class };
}

// Private helpers ──────────────────────────────────────────────────────────

fn queryWMTakeFocusSupport(conn: *xcb.xcb_connection_t, win: u32) bool {
    const protocols_atom  = getAtomCached("WM_PROTOCOLS")  catch return false;
    const reply = xcb.xcb_get_property_reply(conn,
        xcb.xcb_get_property(conn, 0, win, protocols_atom, xcb.XCB_ATOM_ATOM, 0, MAX_PROPERTY_LENGTH), null,
    ) orelse return false;
    defer std.c.free(reply);
    if (reply.*.format != 32 or reply.*.value_len == 0) return false;

    const take_focus_atom = getAtomCached("WM_TAKE_FOCUS") catch return false;
    const atoms: [*]const u32 = @ptrCast(@alignCast(xcb.xcb_get_property_value(reply)));
    for (atoms[0..@intCast(reply.*.value_len)]) |atom| {
        if (atom == take_focus_atom) return true;
    }
    return false;
}

pub fn sendWMTakeFocus(conn: *xcb.xcb_connection_t, win: u32) void {
    const protocols_atom  = getAtomCached("WM_PROTOCOLS")  catch return;
    const take_focus_atom = getAtomCached("WM_TAKE_FOCUS") catch return;

    var event = std.mem.zeroes(xcb.xcb_client_message_event_t);
    event.response_type  = xcb.XCB_CLIENT_MESSAGE;
    event.window         = win;
    event.type           = protocols_atom;
    event.format         = 32;
    event.data.data32[0] = take_focus_atom;
    event.data.data32[1] = xcb.XCB_CURRENT_TIME;

    _ = xcb.xcb_send_event(conn, 0, win, xcb.XCB_EVENT_MASK_NO_EVENT, @ptrCast(&event));
}

// WM_HINTS input checking ──────────────────────────────────────────────────

pub const InputModel = enum {
    no_input,        // input=False, no WM_TAKE_FOCUS - window doesn't want focus
    passive,         // input=True,  no WM_TAKE_FOCUS - set focus via XSetInputFocus
    locally_active,  // input=True,  WM_TAKE_FOCUS    - set focus + send protocol
    globally_active, // input=False, WM_TAKE_FOCUS    - only send protocol
};

/// Query WM_HINTS to determine if window accepts input via XSetInputFocus.
/// Returns true if input field is absent (assume True) or explicitly True.
fn queryWMHintsInput(conn: *xcb.xcb_connection_t, win: u32) bool {
    const reply = xcb.xcb_get_property_reply(conn,
        xcb.xcb_get_property(conn, 0, win, xcb.XCB_ATOM_WM_HINTS, xcb.XCB_ATOM_WM_HINTS, 0, 9),
        null,
    ) orelse return true; // Default to true if WM_HINTS absent
    defer std.c.free(reply);
    
    if (reply.*.format != 32 or reply.*.value_len < 1) return true;
    
    const hints: [*]const u32 = @ptrCast(@alignCast(xcb.xcb_get_property_value(reply)));
    const flags = hints[0];
    const INPUT_HINT_FLAG: u32 = (1 << 0);
    
    // If InputHint flag is set, check the input field (hints[1])
    if ((flags & INPUT_HINT_FLAG) != 0 and reply.*.value_len >= 2) {
        return hints[1] != 0;
    }
    
    // InputHint not set - assume window accepts input
    return true;
}

/// Determine the ICCCM input model for a window.
pub fn getInputModel(conn: *xcb.xcb_connection_t, win: u32) InputModel {
    const accepts_input = queryWMHintsInput(conn, win);
    const supports_take_focus = supportsWMTakeFocusCached(conn, win);
    
    if (supports_take_focus) {
        return if (accepts_input) .locally_active else .globally_active;
    } else {
        return if (accepts_input) .passive else .no_input;
    }
}

// Child window resolution ──────────────────────────────────────────────────

/// Find the top-level window that the WM manages, starting from a potentially
/// child window. Electron apps and other toolkits often use child windows for
/// rendering, but the WM only manages the top-level parent.
pub fn findManagedWindow(conn: *xcb.xcb_connection_t, win: u32, wm: anytype) u32 {
    var current = win;
    var depth: u8 = 0;
    const MAX_DEPTH = 10; // Prevent infinite loops
    
    while (depth < MAX_DEPTH) : (depth += 1) {
        // If this window is managed by the WM, we're done
        if (wm.hasWindow(current)) return current;
        
        // Query parent window
        const tree_reply = xcb.xcb_query_tree_reply(
            conn,
            xcb.xcb_query_tree(conn, current),
            null,
        ) orelse return win; // Failed to query - return original
        defer std.c.free(tree_reply);
        
        const parent = tree_reply.*.parent;
        const root = tree_reply.*.root;
        
        // If parent is root, we've gone too far
        if (parent == root or parent == 0) return win;
        
        current = parent;
    }
    
    return win; // Exceeded max depth - return original
}
