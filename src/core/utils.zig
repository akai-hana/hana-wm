//! Core utilities — X11 geometry helpers, atom caching, InputModel caching.

const std  = @import("std");
const defs = @import("defs");
const xcb  = defs.xcb;
const debug = @import("debug");

const MAX_PROPERTY_LENGTH: u32 = 256; // long-words requested from the X server
const PROPERTY_NO_DELETE:  u8  = 0;
const INPUT_HINT_FLAG:     u32 = 1 << 0; // WM_HINTS flags field bit 0

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
    const names = [_][]const u8{
        "WM_PROTOCOLS", "WM_DELETE_WINDOW", "WM_TAKE_FOCUS",
        "_NET_WM_NAME",  "UTF8_STRING",      "WM_CLASS",
    };
    var cookies: [names.len]xcb.xcb_intern_atom_cookie_t = undefined;
    for (&cookies, names) |*c, name|
        c.* = xcb.xcb_intern_atom(conn, 0, @intCast(name.len), name.ptr);

    var values: [names.len]u32 = undefined;
    for (&values, cookies) |*v, cookie| {
        const r = xcb.xcb_intern_atom_reply(conn, cookie, null) orelse return error.AtomFailed;
        defer std.c.free(r);
        v.* = r.*.atom;
    }

    atom_cache = .{
        .wm_protocols  = values[0],
        .wm_delete     = values[1],
        .wm_take_focus = values[2],
        .net_wm_name   = values[3],
        .utf8_string   = values[4],
        .wm_class      = values[5],
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

// Property helpers

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

// InputModel cache
//
// Keyed by window ID; populated at map time via populateFocusCacheFromCookies.
// Invalidated on WM_PROTOCOLS / WM_HINTS PropertyNotify and on window destruction.
// Keeps the setFocus hot path free of blocking X11 round-trips for seen windows.
//
// A previous design also maintained a wm_take_focus_cache so that a WM_HINTS
// PropertyNotify could recompute InputModel without re-querying WM_PROTOCOLS.
// That saves one round-trip on an event that is effectively never seen in
// practice, at the cost of a second HashMap, a second init/deinit pair, and
// tangled invalidation logic across six functions. The intermediate cache has
// been removed; both properties are queried when the model needs recomputation.

pub const InputModel = enum {
    no_input,        // input=False, no WM_TAKE_FOCUS — window doesn't want focus
    passive,         // input=True,  no WM_TAKE_FOCUS — set focus via XSetInputFocus
    locally_active,  // input=True,  WM_TAKE_FOCUS    — set focus + send protocol
    globally_active, // input=False, WM_TAKE_FOCUS    — only send protocol
};

var input_model_cache: ?std.AutoHashMap(u32, InputModel) = null;

pub fn initInputModelCache(allocator: std.mem.Allocator) void {
    input_model_cache = std.AutoHashMap(u32, InputModel).init(allocator);
}

pub fn deinitInputModelCache() void {
    if (input_model_cache) |*cache| {
        cache.deinit();
        input_model_cache = null;
    }
}

/// Consume pre-fired WM_PROTOCOLS and WM_HINTS cookies and store the resulting
/// InputModel.  The caller fires the cookies before calling this — typically
/// right after xcb_map_window + flush so the server processes the property
/// requests in parallel with the map.
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
            if ((hints[0] & INPUT_HINT_FLAG) != 0 and r.*.value_len >= 2) {
                accepts = hints[1] != 0;
            }
        }
    }

    storeInputModel(win, inputModelFrom(supports, accepts));
}

/// Recompute and cache the InputModel after a WM_PROTOCOLS or WM_HINTS change.
/// Two round-trips; called only on rare PropertyNotify events.
pub fn recacheInputModel(conn: *xcb.xcb_connection_t, win: u32) void {
    storeInputModel(win, inputModelFrom(
        queryWMTakeFocusSupport(conn, win),
        queryWMHintsInput(conn, win),
    ));
}

pub fn uncacheWindowFocusProps(win: u32) void {
    if (input_model_cache) |*c| _ = c.remove(win);
}

/// Return the cached InputModel, falling back to a live query if not cached.
/// For the hover focus hot path this should always be a cache hit.
pub fn getInputModelCached(conn: *xcb.xcb_connection_t, win: u32) InputModel {
    if (input_model_cache) |*c| {
        if (c.get(win)) |model| return model;
    }
    // Cache miss — compute live and store for next time.
    const model = inputModelFrom(
        queryWMTakeFocusSupport(conn, win),
        queryWMHintsInput(conn, win),
    );
    storeInputModel(win, model);
    return model;
}

inline fn inputModelFrom(supports_take_focus: bool, accepts_input: bool) InputModel {
    return if (supports_take_focus)
        (if (accepts_input) .locally_active else .globally_active)
    else
        (if (accepts_input) .passive else .no_input);
}

inline fn storeInputModel(win: u32, model: InputModel) void {
    if (input_model_cache) |*c| c.put(win, model) catch {};
}

// WM_CLASS

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
        xcb.xcb_get_property(conn, PROPERTY_NO_DELETE, win, class_atom, xcb.XCB_ATOM_STRING, 0, MAX_PROPERTY_LENGTH), null,
    ) orelse return null;
    defer std.c.free(reply);
    if (reply.*.format != 8 or reply.*.value_len == 0) return null;

    const data: [*]const u8 = @ptrCast(xcb.xcb_get_property_value(reply));
    const len: usize = @intCast(reply.*.value_len);

    const sep = std.mem.indexOfScalar(u8, data[0..len], 0) orelse return null;
    if (sep + 1 >= len) return null;

    const instance = allocator.dupe(u8, data[0..sep]) catch return null;
    const class    = allocator.dupe(u8, data[sep + 1..len]) catch {
        allocator.free(instance);
        return null;
    };
    return .{ .instance = instance, .class = class };
}

// Private helpers

fn queryWMTakeFocusSupport(conn: *xcb.xcb_connection_t, win: u32) bool {
    const protocols_atom  = getAtomCached("WM_PROTOCOLS")  catch return false;
    const reply = xcb.xcb_get_property_reply(conn,
        xcb.xcb_get_property(conn, PROPERTY_NO_DELETE, win, protocols_atom, xcb.XCB_ATOM_ATOM, 0, MAX_PROPERTY_LENGTH), null,
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

/// Query WM_HINTS to determine if window accepts input via XSetInputFocus.
/// Returns true if the input field is absent (assume True) or explicitly True.
fn queryWMHintsInput(conn: *xcb.xcb_connection_t, win: u32) bool {
    const reply = xcb.xcb_get_property_reply(conn,
        xcb.xcb_get_property(conn, PROPERTY_NO_DELETE, win, xcb.XCB_ATOM_WM_HINTS, xcb.XCB_ATOM_WM_HINTS, 0, 9),
        null,
    ) orelse return true;
    defer std.c.free(reply);

    if (reply.*.format != 32 or reply.*.value_len < 1) return true;

    const hints: [*]const u32 = @ptrCast(@alignCast(xcb.xcb_get_property_value(reply)));
    if ((hints[0] & INPUT_HINT_FLAG) != 0 and reply.*.value_len >= 2) {
        return hints[1] != 0;
    }
    return true;
}

// Child window resolution

/// Find the top-level window that the WM manages, starting from a potentially
/// child window. Electron apps and other toolkits often use child windows for
/// rendering, but the WM only manages the top-level parent.
pub fn findManagedWindow(conn: *xcb.xcb_connection_t, win: u32, wm: anytype) u32 {
    var current = win;
    for (0..10) |_| {
        if (wm.hasWindow(current)) return current;

        const tree_reply = xcb.xcb_query_tree_reply(
            conn, xcb.xcb_query_tree(conn, current), null,
        ) orelse return win;
        defer std.c.free(tree_reply);

        if (tree_reply.*.parent == tree_reply.*.root or tree_reply.*.parent == 0) return win;
        current = tree_reply.*.parent;
    }
    return win;
}
