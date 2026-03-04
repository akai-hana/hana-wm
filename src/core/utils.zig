//! Core utilities — X11 geometry helpers, atom caching, InputModel caching,
//! and process lifecycle signals.

const std  = @import("std");
const defs = @import("defs");
const xcb  = defs.xcb;
const debug     = @import("debug");
const constants = @import("constants");

const MAX_PROPERTY_LENGTH:  u32 = 256; // long-words requested from the X server
const PROPERTY_NO_DELETE:   u8  = 0;
const INPUT_HINT_FLAG:      u32 = 1 << 0; // WM_HINTS flags field bit 0
const WM_HINTS_LONG_LENGTH: u32 = 9;      // flags + 8 fields (input, initial_state, icon_pixmap, icon_window, icon_x, icon_y, icon_mask, window_group)

// Process lifecycle signals
//
// Module-level atomics rather than WM struct fields because they are process
// control state, not window-manager state.  Keeping them here removes pointer
// indirections from every consumer and makes the dependency explicit: signal
// handlers and keybind actions write here; the main event loop reads here.

/// Set to false by SIGTERM / SIGINT to break the main event loop.
pub var running = std.atomic.Value(bool).init(true);

/// Set to true by SIGHUP or the reload_config keybinding; consumed (swapped
/// to false) by maybeReload in the main event loop.
pub var should_reload = std.atomic.Value(bool).init(false);

pub inline fn quit() void {
    running.store(false, .release);
}

pub inline fn reload() void {
    should_reload.store(true, .release);
}

/// Atomically consume the reload flag.  Returns true exactly once per
/// request — whichever call path checks first wins; the second is a no-op.
pub inline fn consumeReload() bool {
    return should_reload.swap(false, .acq_rel);
}

// Geometry

pub inline fn configureBorder(conn: *xcb.xcb_connection_t, win: u32, width: u16, color: u32) void {
    _ = xcb.xcb_configure_window(conn, win, xcb.XCB_CONFIG_WINDOW_BORDER_WIDTH, &[_]u32{width});
    _ = xcb.xcb_change_window_attributes(conn, win, xcb.XCB_CW_BORDER_PIXEL, &[_]u32{color});
}

// `extern struct` gives Rect a defined C-compatible layout (fields packed in
// declaration order with natural alignment).  All four fields are i16/u16 —
// identical alignment and size — so the compiler inserts no padding and the
// struct is exactly 8 bytes.  The explicit layout enables the single-u64
// comparison in rectsEqual (layouts.zig) and is a no-op for all other callers.
pub const Rect = extern struct {
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
        return 2 * (self.gap + self.border);
    }
};

pub inline fn configureWindow(conn: *xcb.xcb_connection_t, win: u32, rect: Rect) void {
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

/// Five-field variant of configureWindow that also sets border_width.
/// Used by fullscreen enter/exit and workspace switching where the border
/// must be set atomically with the geometry to avoid a one-frame flash.
pub inline fn configureWindowGeom(conn: *xcb.xcb_connection_t, win: u32, geom: defs.WindowGeometry) void {
    _ = xcb.xcb_configure_window(
        conn, win,
        xcb.XCB_CONFIG_WINDOW_X     | xcb.XCB_CONFIG_WINDOW_Y     |
        xcb.XCB_CONFIG_WINDOW_WIDTH | xcb.XCB_CONFIG_WINDOW_HEIGHT |
        xcb.XCB_CONFIG_WINDOW_BORDER_WIDTH,
        &[_]u32{
            @bitCast(@as(i32, geom.x)),
            @bitCast(@as(i32, geom.y)),
            geom.width,
            geom.height,
            geom.border_width,
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

/// Default floating window position: one quarter of the screen in from the top-left.
/// Shared by workspaces, minimize, and fullscreen — single definition, zero duplication.
pub inline fn floatDefaultPos(wm: *const defs.WM) struct { x: u32, y: u32 } {
    return .{
        .x = @intCast(wm.screen.width_in_pixels  / 4),
        .y = @intCast(wm.screen.height_in_pixels / 4),
    };
}

// Atom cache

// Field names match the X11 atom strings exactly so getAtomCached can resolve
// them with a single @field call — no switch, no redundant enum, no second
// place to add entries when a new atom is needed.
const AtomCache = struct {
    @"WM_PROTOCOLS":             u32,
    @"WM_DELETE_WINDOW":         u32,
    @"WM_TAKE_FOCUS":            u32,
    @"_NET_WM_NAME":             u32,
    @"UTF8_STRING":              u32,
    @"WM_CLASS":                 u32,
    // Bar window property atoms — used by bar.setWindowProperties on every init/reload.
    // Batched here so setWindowProperties pays zero X round-trips rather than 10 serial ones.
    @"_NET_WM_STRUT_PARTIAL":    u32,
    @"_NET_WM_WINDOW_TYPE":      u32,
    @"_NET_WM_WINDOW_TYPE_DOCK": u32,
    @"_NET_WM_STATE":            u32,
    @"_NET_WM_STATE_ABOVE":      u32,
    @"_NET_WM_STATE_STICKY":     u32,
    @"_NET_WM_ALLOWED_ACTIONS":  u32,
    @"_NET_WM_ACTION_CLOSE":     u32,
    @"_NET_WM_ACTION_ABOVE":     u32,
    @"_NET_WM_ACTION_STICK":     u32,
    @"_NET_WM_PID":              u32,
};

var atom_cache: ?AtomCache = null;

/// Intern all atoms in a single round-trip batch.
/// Atom names are derived directly from AtomCache field names at comptime,
/// so adding a field to AtomCache is the only change required — no parallel
/// array to maintain and no risk of index-order mismatch.
pub fn initAtomCache(conn: *xcb.xcb_connection_t) !void {
    const fields = std.meta.fields(AtomCache);
    var cookies: [fields.len]xcb.xcb_intern_atom_cookie_t = undefined;

    // Fire all requests before waiting for any reply — one round-trip total.
    inline for (fields, 0..) |f, i|
        cookies[i] = xcb.xcb_intern_atom(conn, 0, @intCast(f.name.len), f.name.ptr);

    var cache: AtomCache = undefined;
    inline for (fields, 0..) |f, i| {
        // xcb_intern_atom_reply always consumes cookie i, so only discard i+1 onward.
        const r = xcb.xcb_intern_atom_reply(conn, cookies[i], null) orelse {
            for (i + 1..fields.len) |j| xcb.xcb_discard_reply(conn, cookies[j].sequence);
            return error.AtomFailed;
        };
        defer std.c.free(r);
        @field(cache, f.name) = r.*.atom;
    }
    atom_cache = cache;
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

pub inline fn getAtomCached(comptime name: []const u8) error{AtomCacheNotInitialized}!u32 {
    // Unknown names produce a build error rather than a silent runtime failure.
    comptime if (!@hasField(AtomCache, name)) @compileError("atom not in cache: " ++ name);
    const cache = atom_cache orelse return error.AtomCacheNotInitialized;
    return @field(cache, name);
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

// Window focus property cache
//
// Keyed by window ID; populated at map time via populateFocusCacheFromCookies.
// Invalidated on WM_PROTOCOLS / WM_HINTS PropertyNotify and on window destruction.
// Keeps the setFocus hot path and close-window path free of blocking X11
// round-trips for all windows that were seen at map time.
//
// Both InputModel (focus routing) and wm_delete (close protocol support) are
// derived from WM_PROTOCOLS, so they are populated together in a single scan.

pub const InputModel = enum {
    no_input,        // input=False, no WM_TAKE_FOCUS — window doesn't want focus
    passive,         // input=True,  no WM_TAKE_FOCUS — set focus via XSetInputFocus
    locally_active,  // input=True,  WM_TAKE_FOCUS    — set focus + send protocol
    globally_active, // input=False, WM_TAKE_FOCUS    — only send protocol
};

/// Combined per-window property cache entry.  Both fields are populated from
/// a single WM_PROTOCOLS scan at map time, so there is no extra cost over
/// caching InputModel alone.
const CachedProps = struct {
    model:     InputModel,
    wm_delete: bool,
};

var input_model_cache: ?std.AutoHashMap(u32, CachedProps) = null;

pub fn initInputModelCache(allocator: std.mem.Allocator) void {
    input_model_cache = std.AutoHashMap(u32, CachedProps).init(allocator);
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
    // Resolve both atoms before consuming either cookie — single cleanup path.
    const atoms = blk: {
        const tf = getAtomCached("WM_TAKE_FOCUS")    catch break :blk null;
        const wd = getAtomCached("WM_DELETE_WINDOW") catch break :blk null;
        break :blk .{ .take_focus = tf, .wm_delete = wd };
    } orelse {
        xcb.xcb_discard_reply(conn, c_protocols.sequence);
        xcb.xcb_discard_reply(conn, c_hints.sequence);
        return;
    };

    // Scan WM_PROTOCOLS once for both atoms — no second round-trip.
    var take_focus = false;
    var wm_delete  = false;
    if (xcb.xcb_get_property_reply(conn, c_protocols, null)) |r| {
        defer std.c.free(r);
        if (r.*.format == 32 and r.*.value_len > 0) {
            const protocol_atoms: [*]const u32 = @ptrCast(@alignCast(xcb.xcb_get_property_value(r)));
            for (protocol_atoms[0..@intCast(r.*.value_len)]) |atom| {
                if (atom == atoms.take_focus) take_focus = true;
                if (atom == atoms.wm_delete)  wm_delete  = true;
                if (take_focus and wm_delete) break;
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

    storeCachedProps(win, .{
        .model     = inputModelFrom(take_focus, accepts),
        .wm_delete = wm_delete,
    });
}

/// Recompute and cache the focus properties after a WM_PROTOCOLS or WM_HINTS
/// change.  Two round-trips (WM_PROTOCOLS + WM_HINTS); called only on rare
/// PropertyNotify events so latency is not a concern.
pub fn recacheInputModel(conn: *xcb.xcb_connection_t, win: u32) void {
    const proto = queryWMProtocolsProps(conn, win);
    storeCachedProps(win, .{
        .model     = inputModelFrom(proto.take_focus, queryWMHintsInput(conn, win)),
        .wm_delete = proto.wm_delete,
    });
}

pub inline fn uncacheWindowFocusProps(win: u32) void {
    if (input_model_cache) |*c| _ = c.remove(win);
}

/// Return the cached InputModel, falling back to a live query if not cached.
/// For the hover focus hot path this should always be a cache hit.
pub fn getInputModelCached(conn: *xcb.xcb_connection_t, win: u32) InputModel {
    if (input_model_cache) |*c| {
        if (c.get(win)) |props| return props.model;
    }
    // Cache miss — query all protocol props in one scan and cache everything.
    const proto = queryWMProtocolsProps(conn, win);
    const props = CachedProps{
        .model     = inputModelFrom(proto.take_focus, queryWMHintsInput(conn, win)),
        .wm_delete = proto.wm_delete,
    };
    storeCachedProps(win, props);
    return props.model;
}

/// Return true if `win` declared WM_DELETE_WINDOW support at map time.
/// Eliminates the blocking WM_PROTOCOLS round-trip in closeWindow — the same
/// property was already scanned at map time and the result cached.
/// Falls back to a live query only on a genuine cache miss (extremely rare).
pub fn supportsWMDeleteCached(conn: *xcb.xcb_connection_t, win: u32) bool {
    if (input_model_cache) |*c| {
        if (c.get(win)) |props| return props.wm_delete;
    }
    // Cache miss: query WM_PROTOCOLS live.  No point caching without the
    // WM_HINTS result too; closeWindow is called at most once per window.
    return queryWMProtocolsProps(conn, win).wm_delete;
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
    const class_str = std.mem.trimRight(u8, data[sep + 1..len], "\x00");
    const class     = allocator.dupe(u8, class_str) catch {
        allocator.free(instance);
        return null;
    };
    return .{ .instance = instance, .class = class };
}

// Private helpers

inline fn inputModelFrom(supports_take_focus: bool, accepts_input: bool) InputModel {
    return if (supports_take_focus)
        (if (accepts_input) .locally_active else .globally_active)
    else
        (if (accepts_input) .passive else .no_input);
}

inline fn storeCachedProps(win: u32, props: CachedProps) void {
    if (input_model_cache) |*c| c.put(win, props) catch {};
}

const WMProtocolsProps = struct { take_focus: bool = false, wm_delete: bool = false };

/// Scan WM_PROTOCOLS once and return all flags the WM cares about.
/// One round-trip per call; results are always cached by callers.
fn queryWMProtocolsProps(conn: *xcb.xcb_connection_t, win: u32) WMProtocolsProps {
    const protocols_atom = getAtomCached("WM_PROTOCOLS") catch return .{};
    const reply = xcb.xcb_get_property_reply(conn,
        xcb.xcb_get_property(conn, PROPERTY_NO_DELETE, win, protocols_atom, xcb.XCB_ATOM_ATOM, 0, MAX_PROPERTY_LENGTH), null,
    ) orelse return .{};
    defer std.c.free(reply);
    if (reply.*.format != 32 or reply.*.value_len == 0) return .{};

    const take_focus_atom = getAtomCached("WM_TAKE_FOCUS")    catch return .{};
    const wm_delete_atom  = getAtomCached("WM_DELETE_WINDOW") catch return .{};

    var props: WMProtocolsProps = .{};
    const atoms: [*]const u32 = @ptrCast(@alignCast(xcb.xcb_get_property_value(reply)));
    for (atoms[0..@intCast(reply.*.value_len)]) |atom| {
        if (atom == take_focus_atom) props.take_focus = true;
        if (atom == wm_delete_atom)  props.wm_delete  = true;
        if (props.take_focus and props.wm_delete) break;
    }
    return props;
}

/// Query WM_HINTS to determine if window accepts input via XSetInputFocus.
/// Returns true if the input field is absent (assume True) or explicitly True.
fn queryWMHintsInput(conn: *xcb.xcb_connection_t, win: u32) bool {
    const reply = xcb.xcb_get_property_reply(conn,
        xcb.xcb_get_property(conn, PROPERTY_NO_DELETE, win, xcb.XCB_ATOM_WM_HINTS, xcb.XCB_ATOM_WM_HINTS, 0, WM_HINTS_LONG_LENGTH),
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
pub fn findManagedWindow(conn: *xcb.xcb_connection_t, win: u32, isManaged: *const fn (u32) bool) u32 {
    var current = win;
    for (0..constants.MAX_WINDOW_TREE_DEPTH) |_| {
        if (isManaged(current)) return current;

        const tree_reply = xcb.xcb_query_tree_reply(
            conn, xcb.xcb_query_tree(conn, current), null,
        ) orelse return win;
        defer std.c.free(tree_reply);

        if (tree_reply.*.parent == tree_reply.*.root or tree_reply.*.parent == 0) return win;
        current = tree_reply.*.parent;
    }
    return win;
}
