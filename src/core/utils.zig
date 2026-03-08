//! hana core utilities
//!
//! Includes X11 geometry helpers, atom caching, ICCCM input model caching, and process lifecycle signals.

// Zig stdlib
const std = @import("std");

// core/
const constants = @import("constants");

// config/
const defs    = @import("defs");
    const xcb = defs.xcb;

// debug/
const debug = @import("debug");

const MAX_PROPERTY_LENGTH:   u32   = 256;
const PROPERTY_NO_DELETE:    u8    = 0;
const WM_HINTS_INPUT_FLAG:   u32   = 1 << 0;
const WM_HINTS_FLAGS_FIELD:  usize = 0;
const WM_HINTS_INPUT_FIELD:  usize = 1;
const WM_HINTS_LONG_LENGTH:  u32   = 9; // flags + 8 fields

// Process lifecycle signals
//
// Module-level atomics rather than WM struct fields, because they are process control state, not window-manager state.
// Signal handlers and keybind actions write here; the main event loop reads here.

/// Set to false by SIGTERM/SIGINT to break the main event loop.
pub var running = std.atomic.Value(bool).init(true);

/// Set to true by SIGHUP or the `reload_config` keybinding.
/// Consumed by `maybeReload` in the main event loop. //TODO: does this refer to main.zig or event.zig?
pub var should_reload = std.atomic.Value(bool).init(false);

/// Signals the main event loop to exit cleanly.
pub inline fn quit() void { running.store(false, .release); }

/// Signals the main event loop to reload the user config.
pub inline fn reload() void { should_reload.store(true, .release); }

/// Atomically consumes the reload flag.
/// Returns true exactly once per request, whichever call path checks first wins.
pub inline fn consumeReload() bool {
    return should_reload.swap(false, .acq_rel);
}

// Geometry operations

/// Sets the border width and border colour of `win` in a single logical operation.
pub inline fn configureBorder(conn: *xcb.xcb_connection_t, win: u32, width: u16, color: u32) void {
    _ = xcb.xcb_configure_window(conn, win, xcb.XCB_CONFIG_WINDOW_BORDER_WIDTH, &[_]u32{width});
    _ = xcb.xcb_change_window_attributes(conn, win, xcb.XCB_CW_BORDER_PIXEL, &[_]u32{color});
}

/// Position and dimensions of a managed window, relative to the root window (the total display area).
pub const Rect = extern struct {
    x:      i16,
    y:      i16,
    width:  u16,
    height: u16,

    pub inline fn fromXcb(geom: *const xcb.xcb_get_geometry_reply_t) Rect {
        return .{ .x = geom.x, .y = geom.y, .width = geom.width, .height = geom.height };
    }

    pub inline fn isValid(self: Rect) bool {
        return self.width >= constants.MIN_WINDOW_DIM and self.height >= constants.MIN_WINDOW_DIM;
    }
};

/// Gap and border widths applied around a tiled window.
pub const Margins = struct {
    gap:    u16,
    border: u16,

    /// Returns the total space consumed on one axis (gap + border on each side).
    pub inline fn total(self: Margins) u16 { return self.gap + 2 * self.border; }
};

/// Four-field variant. //TODO: four-field variant? variant of what? what even is four-field? what does this function do? it's not clear at all with the current comment's description; it isn't human readable for a person who's reading it on the surface to immediately know what this does.
///
/// Sets x, y, width, and height only; border_width is unchanged.
/// Use configureWindowGeom when border_width must move atomically.
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

/// Five-field variant that also sets border_width atomically with geometry,
/// preventing a one-frame flash on fullscreen enter/exit and workspace switch. //TODO: see previous TODO, also applies here.
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

/// Queries the current geometry of `win`.
/// Returns null if the window does not exist or is not yet mapped.
pub fn getGeometry(conn: *xcb.xcb_connection_t, win: u32) ?Rect {
    const reply = xcb.xcb_get_geometry_reply(conn, xcb.xcb_get_geometry(conn, win), null) orelse return null;
    defer std.c.free(reply);
    return Rect.fromXcb(reply);
}

/// Strips lock-key and pointer-button bits from a raw event modifier state,
/// leaving only the modifier bits the WM uses for keybinding matching.
pub inline fn normalizeModifiers(state: u16) u16 {
    return state & constants.MOD_MASK_RELEVANT;
}

/// Returns the default floating window position
/// (one quarter of the screen in from the top-left).
pub inline fn floatDefaultPos(wm: *const defs.WM) struct { x: u32, y: u32 } {
    return .{
        .x = @intCast(wm.screen.width_in_pixels  / 4),
        .y = @intCast(wm.screen.height_in_pixels / 4),
    };
}

// Atom cache
//
// Field names match X11 atom strings exactly so getAtomCached can resolve them with a single @field call:
// No switch, no redundant enum, no second place to add entries when a new atom is needed.
const AtomCache = struct {
    @"WM_PROTOCOLS":             u32,
    @"WM_DELETE_WINDOW":         u32,
    @"WM_TAKE_FOCUS":            u32,
    @"_NET_WM_NAME":             u32,
    @"UTF8_STRING":              u32,
    @"WM_CLASS":                 u32,
    // Bar window property atoms
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

/// Interns all atoms in a single round-trip batch.
/// Atom names are derived from `AtomCache` field names at comptime, so adding a field is the only change required:
/// No parallel array to maintain, and no index-order mismatch risk.
pub fn initAtomCache(conn: *xcb.xcb_connection_t) !void {
    const fields = std.meta.fields(AtomCache);
    var cookies: [fields.len]xcb.xcb_intern_atom_cookie_t = undefined;

    inline for (fields, 0..) |f, i|
        cookies[i] = xcb.xcb_intern_atom(conn, 0, @intCast(f.name.len), f.name.ptr);

    var cache: AtomCache = undefined;
    inline for (fields, 0..) |f, i| {
        const reply = xcb.xcb_intern_atom_reply(conn, cookies[i], null) orelse {
            for (i + 1..fields.len) |j| xcb.xcb_discard_reply(conn, cookies[j].sequence);
            return error.AtomFailed;
        };
        defer std.c.free(reply);
        @field(cache, f.name) = reply.*.atom;
    }
    atom_cache = cache;
}

/// Interns a single atom by name, always making a server round-trip.
/// Prefer `getAtomCached` for atoms known at compile time.
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

/// Looks up a cached atom by name.
/// Unknown names produce a compile error rather than a silent runtime failure.
pub inline fn getAtomCached(comptime name: []const u8) error{AtomCacheNotInitialized}!u32 {
    comptime if (!@hasField(AtomCache, name)) @compileError("atom not in cache: " ++ name);
    const cache = atom_cache orelse return error.AtomCacheNotInitialized;
    return @field(cache, name);
}

// Property helpers

/// TODO: missing brief one-line of function.
///
/// Fetches an 8-bit X11 window property into a caller-supplied reuse buffer.
/// Returns a slice into `buffer.items` on success, or null if the property is absent, empty, or not 8-bit encoded.
/// The buffer is cleared before each use, so the caller can allocate it once and pass it across repeated calls.
pub fn fetchPropertyToBuffer(
    conn:      *xcb.xcb_connection_t,
    window:    u32,
    atom:      u32,
    atom_type: u32,
    buffer:    *std.ArrayListUnmanaged(u8),
    allocator: std.mem.Allocator,
) !?[]const u8 {
    const reply = xcb.xcb_get_property_reply(conn,
        xcb.xcb_get_property(conn, PROPERTY_NO_DELETE, window, atom, atom_type, 0, MAX_PROPERTY_LENGTH),
        null,
    ) orelse return null;
    defer std.c.free(reply);
    if (reply.*.format != 8 or reply.*.value_len == 0) return null;

    buffer.clearRetainingCapacity();
    const value_ptr: [*]const u8 = @ptrCast(xcb.xcb_get_property_value(reply));
    try buffer.appendSlice(allocator, value_ptr[0..@intCast(reply.*.value_len)]);
    return buffer.items;
} //TODO: the code here seems really tight. no spacing whatsoever except one blank line. it's also really verbose at first sight, i'd love it if it were more readable and understandable when skimming through this utils.zig file on a surface level.

// Window focus property cache
//
// Keyed by window ID; populated at map time via `populateFocusCacheFromCookies`.
// Invalidated on WM_PROTOCOLS/WM_HINTS `PropertyNotify` and on window destruction.
// Keeps the `setFocus` hot path and close-window path free of blocking X11 round-trips
// for all windows that were seen at map time.
//
// `InputModel` (focus routing) and `wm_delete` (close protocol) are both derived from
// WM_PROTOCOLS, so they are populated together in a single scan.

/// The four ICCCM focus delivery modes (§4.1.7), determined by the combination of
/// WM_HINTS.input and WM_TAKE_FOCUS presence in WM_PROTOCOLS.
pub const InputModel = enum {
    no_input,        // input=False, no WM_TAKE_FOCUS: window doesn't want focus
    passive,         // input=True,  no WM_TAKE_FOCUS: set focus via `XSetInputFocus`
    locally_active,  // input=True,  WM_TAKE_FOCUS:    set focus + send protocol
    globally_active, // input=False, WM_TAKE_FOCUS:    only send protocol
};

/// Per-window focus properties derived from WM_PROTOCOLS and WM_HINTS,
/// stored together since both are populated in a single WM_PROTOCOLS scan.
const CachedProps = struct {
    model:     InputModel,
    wm_delete: bool,
};

var input_model_cache: ?std.AutoHashMap(u32, CachedProps) = null;

/// Initializes the per-window focus property cache.
pub fn initInputModelCache(allocator: std.mem.Allocator) void {
    input_model_cache = std.AutoHashMap(u32, CachedProps).init(allocator);
}

/// Cleans up the per-window focus property cache.
pub fn deinitInputModelCache() void {
    if (input_model_cache) |*cache| { //TODO: what "if (input_model_cache) |*cache|" does is unclear to me just from reading the code.
        cache.deinit();
        input_model_cache = null;
    }
}

/// Consumes pre-fired WM_PROTOCOLS and WM_HINTS cookies and stores the result.
///
/// The caller fires the cookies immediately after xcb_map_window
/// so the server processes property requests in parallel with the map.
pub fn populateFocusCacheFromCookies(
    conn: *xcb.xcb_connection_t,
    win:  u32,

    protocols_cookie: xcb.xcb_get_property_cookie_t,
    hints_cookie:     xcb.xcb_get_property_cookie_t,
) void {
    // Resolve both atoms before consuming either cookie single cleanup path.
    const atoms = blk: {
        const take_focus_atom = getAtomCached("WM_TAKE_FOCUS")    catch break :blk null; //TODO: why "catch break :blk null"?
        const wm_delete_atom  = getAtomCached("WM_DELETE_WINDOW") catch break :blk null;

        break :blk .{ .take_focus = take_focus_atom, .wm_delete = wm_delete_atom };
    } orelse {
        xcb.xcb_discard_reply(conn, protocols_cookie.sequence);
        xcb.xcb_discard_reply(conn, hints_cookie.sequence);

        return;
    };

    // Scan WM_PROTOCOLS once for both atoms (no second round-trip)
    var take_focus = false;
    var wm_delete  = false;

    if (xcb.xcb_get_property_reply(conn, protocols_cookie, null)) |r| {
        defer std.c.free(r);

        if (r.*.format == 32 and r.*.value_len > 0) {
            const protocol_atoms: [*]const u32 = @ptrCast(@alignCast(xcb.xcb_get_property_value(r))); //VERBOSE (what does this even do?)

            for (protocol_atoms[0..@intCast(r.*.value_len)]) |atom| { //VERBOSE
                if (atom == atoms.take_focus) take_focus = true;
                if (atom == atoms.wm_delete)  wm_delete  = true;
                if (take_focus and wm_delete) break;
            }
        }
    }

    var accepts_input = true;

    //TODO: comment?
    if (xcb.xcb_get_property_reply(conn, hints_cookie, null)) |r| {
        defer std.c.free(r);

        if (r.*.format == 32 and r.*.value_len >= 1) {
            const hints: [*]const u32 = @ptrCast(@alignCast(xcb.xcb_get_property_value(r)));

            if ((hints[WM_HINTS_FLAGS_FIELD] & WM_HINTS_INPUT_FLAG) != 0 and r.*.value_len > WM_HINTS_INPUT_FIELD) { //VERBOSE
                accepts_input = hints[WM_HINTS_INPUT_FIELD] != 0;
            }
        }
    }

    if (input_model_cache) |*c| c.put(win, .{
        .model     = inputModelFrom(take_focus, accepts_input),
        .wm_delete = wm_delete,
        // Swallowing the OOM error is intentional: a cache miss just means
        // the next lookup falls back to a live query, which is always safe.
    }) catch {};
}

/// Recomputes and caches the focus properties after a WM_PROTOCOLS or WM_HINTS PropertyNotify — two round-trips, called only on rare property change events.
pub fn recacheInputModel(conn: *xcb.xcb_connection_t, win: u32) void {
    _ = queryAndCacheProps(conn, win);
}

/// Removes `win` from the focus property cache — called on window destruction
/// to prevent stale entries from accumulating over the session.
pub inline fn uncacheWindowFocusProps(win: u32) void {
    if (input_model_cache) |*c| _ = c.remove(win);
}

/// Returns the cached focus properties for `win`, or null on a cache miss.
inline fn getCachedProps(win: u32) ?CachedProps {
    return if (input_model_cache) |*c| c.get(win) else null;
}

/// Runs both WM_PROTOCOLS and WM_HINTS queries, stores the result, and returns it.
/// Used by cache-miss paths so the populate logic lives in exactly one place.
fn queryAndCacheProps(conn: *xcb.xcb_connection_t, win: u32) CachedProps {
    const protocols_props = queryWMProtocolsProps(conn, win);
    const props = CachedProps{
        .model     = inputModelFrom(protocols_props.take_focus, queryWMHintsAcceptsInput(conn, win)),
        .wm_delete = protocols_props.wm_delete,
    };
    // Swallowing the OOM error is intentional: a cache miss just means
    // the next lookup falls back to a live query, which is always safe.
    if (input_model_cache) |*c| c.put(win, props) catch {};
    return props;
}

/// Returns the cached InputModel, falling back to a live query on miss.
/// On the hover-focus hot path this should always be a cache hit.
pub fn getInputModelCached(conn: *xcb.xcb_connection_t, win: u32) InputModel {
    if (getCachedProps(win)) |props| return props.model;
    return queryAndCacheProps(conn, win).model;
}

/// Returns true if `win` declared WM_DELETE_WINDOW support at map time.
/// Falls back to a live query only on a genuine cache miss (extremely rare).
pub fn supportsWMDeleteCached(conn: *xcb.xcb_connection_t, win: u32) bool {
    if (getCachedProps(win)) |props| return props.wm_delete;
    return queryWMProtocolsProps(conn, win).wm_delete;
}

/// Sends a WM_TAKE_FOCUS client message (ICCCM §4.1.7).
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

/// The two components of the X11 WM_CLASS property (ICCCM §4.1.2.5).
/// Both slices are heap-allocated and must be freed via deinit.
pub const WMClass = struct {
    instance: []const u8,
    class:    []const u8,

    pub fn deinit(self: WMClass, allocator: std.mem.Allocator) void {
        allocator.free(self.instance);
        allocator.free(self.class);
    }
};

/// Reads and parses the WM_CLASS property for `win`. The raw value is two
/// null-terminated strings concatenated: instance name then class name.
/// Returns null if the property is absent, malformed, or allocation fails.
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
    if (sep + 1 >= len) return null; // no class string follows the null separator

    const instance = allocator.dupe(u8, data[0..sep]) catch return null;
    const class_str = std.mem.trimRight(u8, data[sep + 1..len], "\x00");
    const class     = allocator.dupe(u8, class_str) catch {
        allocator.free(instance);
        return null;
    };
    return .{ .instance = instance, .class = class };
}

// Private helpers

/// Maps the two ICCCM boolean focus properties to the four InputModel variants.
/// See ICCCM §4.1.7: the matrix of (accepts_input × supports_take_focus)
/// determines which focus delivery mechanism the WM must use.
inline fn inputModelFrom(supports_take_focus: bool, accepts_input: bool) InputModel {
    return if (supports_take_focus)
        (if (accepts_input) .locally_active else .globally_active)
    else
        (if (accepts_input) .passive else .no_input);
}

/// Flags extracted from a single WM_PROTOCOLS scan.
const WMProtocolsProps = struct { take_focus: bool = false, wm_delete: bool = false };

/// Scans WM_PROTOCOLS once and returns all flags the WM cares about.
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

/// Queries the WM_HINTS input field. Returns true when absent (assume True) or explicitly True.
fn queryWMHintsAcceptsInput(conn: *xcb.xcb_connection_t, win: u32) bool {
    const reply = xcb.xcb_get_property_reply(conn,
        xcb.xcb_get_property(conn, PROPERTY_NO_DELETE, win, xcb.XCB_ATOM_WM_HINTS, xcb.XCB_ATOM_WM_HINTS, 0, WM_HINTS_LONG_LENGTH),
        null,
    ) orelse return true;
    defer std.c.free(reply);

    if (reply.*.format != 32 or reply.*.value_len < 1) return true;

    const hints: [*]const u32 = @ptrCast(@alignCast(xcb.xcb_get_property_value(reply)));
    if ((hints[WM_HINTS_FLAGS_FIELD] & WM_HINTS_INPUT_FLAG) != 0 and reply.*.value_len > WM_HINTS_INPUT_FIELD) {
        return hints[WM_HINTS_INPUT_FIELD] != 0;
    }
    return true;
}

// Child window resolution

/// Walks up the X11 window tree from `win` to find the top-level window the WM
/// manages. Electron apps and other toolkits often use child windows for
/// rendering, so button events may arrive on a child rather than the managed parent.
pub fn findManagedWindow(conn: *xcb.xcb_connection_t, win: u32, is_managed: *const fn (u32) bool) u32 {
    var current = win;
    for (0..constants.MAX_WINDOW_TREE_DEPTH) |_| {
        if (is_managed(current)) return current;

        const tree_reply = xcb.xcb_query_tree_reply(
            conn, xcb.xcb_query_tree(conn, current), null,
        ) orelse return win;
        defer std.c.free(tree_reply);

        if (tree_reply.*.parent == tree_reply.*.root or tree_reply.*.parent == 0) return win;
        current = tree_reply.*.parent;
    }
    return win;
}
