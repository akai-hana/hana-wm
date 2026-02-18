//! Core utilities — X11 geometry helpers, atom caching, WM_TAKE_FOCUS support.

const std  = @import("std");
const defs = @import("defs");
const xcb  = defs.xcb;
const debug = @import("debug");

const MAX_PROPERTY_LENGTH: u32 = 256; // long-words requested from the X server
const PROPERTY_NO_DELETE:  u8  = 0;

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
    wm_class:      u32,
};

var atom_cache: ?AtomCache = null;

pub fn initAtomCache(conn: *xcb.xcb_connection_t) !void {
    // Fire all intern_atom requests before waiting for any reply — one round-trip
    // instead of six sequential ones.
    const c_protocols  = xcb.xcb_intern_atom(conn, 0, 12, "WM_PROTOCOLS");
    const c_delete     = xcb.xcb_intern_atom(conn, 0, 16, "WM_DELETE_WINDOW");
    const c_take_focus = xcb.xcb_intern_atom(conn, 0, 13, "WM_TAKE_FOCUS");
    const c_net_name   = xcb.xcb_intern_atom(conn, 0, 12, "_NET_WM_NAME");
    const c_utf8       = xcb.xcb_intern_atom(conn, 0, 11, "UTF8_STRING");
    const c_class      = xcb.xcb_intern_atom(conn, 0, 8,  "WM_CLASS");

    const r_protocols  = xcb.xcb_intern_atom_reply(conn, c_protocols,  null) orelse return error.AtomFailed;
    defer std.c.free(r_protocols);
    const r_delete     = xcb.xcb_intern_atom_reply(conn, c_delete,     null) orelse return error.AtomFailed;
    defer std.c.free(r_delete);
    const r_take_focus = xcb.xcb_intern_atom_reply(conn, c_take_focus, null) orelse return error.AtomFailed;
    defer std.c.free(r_take_focus);
    const r_net_name   = xcb.xcb_intern_atom_reply(conn, c_net_name,   null) orelse return error.AtomFailed;
    defer std.c.free(r_net_name);
    const r_utf8       = xcb.xcb_intern_atom_reply(conn, c_utf8,       null) orelse return error.AtomFailed;
    defer std.c.free(r_utf8);
    const r_class      = xcb.xcb_intern_atom_reply(conn, c_class,      null) orelse return error.AtomFailed;
    defer std.c.free(r_class);

    atom_cache = .{
        .wm_protocols  = r_protocols.*.atom,
        .wm_delete     = r_delete.*.atom,
        .wm_take_focus = r_take_focus.*.atom,
        .net_wm_name   = r_net_name.*.atom,
        .utf8_string   = r_utf8.*.atom,
        .wm_class      = r_class.*.atom,
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

pub fn getAtomCached(comptime name: []const u8) error{AtomCacheNotInitialized}!u32 {
    const cache = atom_cache orelse return error.AtomCacheNotInitialized;
    // All callers pass string literals; the switch resolves at compile time.
    // An unknown name produces a build error rather than a silent runtime failure.
    const AtomName = enum {
        @"WM_PROTOCOLS", @"WM_DELETE_WINDOW", @"WM_TAKE_FOCUS",
        @"_NET_WM_NAME", @"UTF8_STRING", @"WM_CLASS",
    };
    const field = comptime (std.meta.stringToEnum(AtomName, name) orelse
        @compileError("atom not in cache: " ++ name));
    return switch (field) {
        .@"WM_PROTOCOLS"     => cache.wm_protocols,
        .@"WM_DELETE_WINDOW" => cache.wm_delete,
        .@"WM_TAKE_FOCUS"    => cache.wm_take_focus,
        .@"_NET_WM_NAME"     => cache.net_wm_name,
        .@"UTF8_STRING"      => cache.utf8_string,
        .@"WM_CLASS"         => cache.wm_class,
    };
}

// Property helpers ─────────────────────────────────────────────────────────

pub fn fetchPropertyToBuffer(
    conn:      *xcb.xcb_connection_t,
    window:    u32,
    atom:      u32,
    atom_type: u32,
    buffer:    *std.ArrayListUnmanaged(u8),
    allocator: std.mem.Allocator,
) ![]const u8 {
    const reply = xcb.xcb_get_property_reply(conn,
        xcb.xcb_get_property(conn, PROPERTY_NO_DELETE, window, atom, atom_type, 0, MAX_PROPERTY_LENGTH),
        null,
    ) orelse return "";
    defer std.c.free(reply);
    if (reply.*.format != 8 or reply.*.value_len == 0) return "";

    // value_len is already bounded by MAX_PROPERTY_LENGTH from the request.
    buffer.clearRetainingCapacity();
    const value_ptr: [*]const u8 = @ptrCast(xcb.xcb_get_property_value(reply));
    try buffer.appendSlice(allocator, value_ptr[0..@intCast(reply.*.value_len)]);
    return buffer.items;
}

// WM_TAKE_FOCUS + InputModel caching ──────────────────────────────────────
//
// Both caches are keyed by window ID and populated at map time.  They are
// invalidated on the relevant PropertyNotify atoms (WM_PROTOCOLS, WM_HINTS)
// and cleared on window destruction.  This keeps setFocus's hot path free
// of blocking X11 round-trips for windows we've already seen.

var wm_take_focus_cache: ?std.AutoHashMap(u32, bool)            = null;
var input_model_cache:   ?std.AutoHashMap(u32, InputModel)      = null;

pub fn initWMTakeFocusCache(allocator: std.mem.Allocator) void {
    wm_take_focus_cache = std.AutoHashMap(u32, bool).init(allocator);
}

pub fn deinitWMTakeFocusCache() void {
    if (wm_take_focus_cache) |*cache| {
        cache.deinit();
        wm_take_focus_cache = null;
    }
}

pub fn initInputModelCache(allocator: std.mem.Allocator) void {
    input_model_cache = std.AutoHashMap(u32, InputModel).init(allocator);
}

pub fn deinitInputModelCache() void {
    if (input_model_cache) |*cache| {
        cache.deinit();
        input_model_cache = null;
    }
}

/// Collect pre-fired WM_PROTOCOLS and WM_HINTS cookies and populate both
/// focus caches.  The caller is responsible for having fired the cookies
/// before calling this — typically after xcb_map_window + flush, so the
/// server processes the property requests in parallel with the map.
pub fn populateFocusCacheFromCookies(
    conn: *xcb.xcb_connection_t,
    win:  u32,
    c_protocols: xcb.xcb_get_property_cookie_t,
    c_hints:     xcb.xcb_get_property_cookie_t,
) void {
    const take_focus_atom = getAtomCached("WM_TAKE_FOCUS") catch return;
    var supports = false;
    if (xcb.xcb_get_property_reply(conn, c_protocols, null)) |r| {
        defer std.c.free(r);
        if (r.*.format == 32 and r.*.value_len > 0) {
            const atoms: [*]const u32 = @ptrCast(@alignCast(xcb.xcb_get_property_value(r)));
            for (atoms[0..@intCast(r.*.value_len)]) |atom| {
                if (atom == take_focus_atom) { supports = true; break; }
            }
        }
    }

    var accepts = true;
    if (xcb.xcb_get_property_reply(conn, c_hints, null)) |r| {
        defer std.c.free(r);
        if (r.*.format == 32 and r.*.value_len >= 1) {
            const hints: [*]const u32 = @ptrCast(@alignCast(xcb.xcb_get_property_value(r)));
            const INPUT_HINT_FLAG: u32 = 1 << 0;
            if ((hints[0] & INPUT_HINT_FLAG) != 0 and r.*.value_len >= 2) {
                accepts = hints[1] != 0;
            }
        }
    }

    if (wm_take_focus_cache) |*c| c.put(win, supports) catch {};
    const model: InputModel = if (supports)
        (if (accepts) .locally_active else .globally_active)
    else
        (if (accepts) .passive else .no_input);
    if (input_model_cache) |*c| c.put(win, model) catch {};
}

/// Invalidate the WM_TAKE_FOCUS entry and recompute InputModel.
/// Call when WM_PROTOCOLS changes (Electron sets it after mapping).
pub fn recacheTakeFocus(conn: *xcb.xcb_connection_t, win: u32) void {
    const supports = queryWMTakeFocusSupport(conn, win);
    if (wm_take_focus_cache) |*c| c.put(win, supports) catch {};
    recacheInputModel(conn, win);
}

/// Invalidate the WM_HINTS input field and recompute InputModel.
/// Call when WM_HINTS changes.
pub fn recacheHintsInput(conn: *xcb.xcb_connection_t, win: u32) void {
    recacheInputModel(conn, win);
}

fn recacheInputModel(conn: *xcb.xcb_connection_t, win: u32) void {
    const supports = if (wm_take_focus_cache) |*c| (c.get(win) orelse queryWMTakeFocusSupport(conn, win)) else queryWMTakeFocusSupport(conn, win);
    const accepts  = queryWMHintsInput(conn, win);
    const model: InputModel = if (supports)
        (if (accepts) .locally_active else .globally_active)
    else
        (if (accepts) .passive else .no_input);
    if (input_model_cache) |*c| c.put(win, model) catch {};
}

pub fn uncacheWindowFocusProps(win: u32) void {
    if (wm_take_focus_cache) |*c| _ = c.remove(win);
    if (input_model_cache)   |*c| _ = c.remove(win);
}

/// Return the cached InputModel, falling back to a live query if not cached.
/// For the hover focus hot path this should always be a cache hit.
pub fn getInputModelCached(conn: *xcb.xcb_connection_t, win: u32) InputModel {
    if (input_model_cache) |*c| {
        if (c.get(win)) |model| return model;
    }
    return getInputModel(conn, win);
}

fn supportsWMTakeFocusCached(conn: *xcb.xcb_connection_t, win: u32) bool {
    if (wm_take_focus_cache) |*cache| {
        if (cache.get(win)) |cached| return cached;
    }
    const supports = queryWMTakeFocusSupport(conn, win);
    if (wm_take_focus_cache) |*cache| cache.put(win, supports) catch {};
    return supports;
}

// WM_CLASS ─────────────────────────────────────────────────────────────────

pub const WMClass = struct {
    instance: []const u8,
    class:    []const u8,

    pub fn deinit(self: WMClass, allocator: std.mem.Allocator) void {
        allocator.free(self.instance);
        allocator.free(self.class);
    }
};

pub fn getWMClass(conn: *xcb.xcb_connection_t, win: u32, allocator: std.mem.Allocator) ?WMClass {
    const class_atom = getAtomCached("WM_CLASS") catch return null;
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

/// Send a WM_TAKE_FOCUS client message (ICCCM §4.1.7).
/// `time` must be the timestamp of the triggering event — globally_active
/// windows (e.g. Electron/Chromium) validate this and silently ignore the
/// message when it is XCB_CURRENT_TIME (0).
pub fn sendWMTakeFocus(conn: *xcb.xcb_connection_t, win: u32, time: u32) void {
    const protocols_atom  = getAtomCached("WM_PROTOCOLS")  catch return;
    const take_focus_atom = getAtomCached("WM_TAKE_FOCUS") catch return;

    var event = std.mem.zeroes(xcb.xcb_client_message_event_t);
    event.response_type  = xcb.XCB_CLIENT_MESSAGE;
    event.window         = win;
    event.type           = protocols_atom;
    event.format         = 32;
    event.data.data32[0] = take_focus_atom;
    event.data.data32[1] = time;

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
