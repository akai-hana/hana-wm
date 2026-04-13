
//! Window lifecycle
//! Handles window mapping/unmapping/destroy, configure, enter/button events, and per-window property caching.

const std   = @import("std");
const build = @import("build_options");

const core      = @import("core");
const xcb       = core.xcb;
const utils     = @import("utils");
const constants = @import("constants");
const debug     = @import("debug");

const tracking = @import("tracking");
const focus    = @import("focus");

const fullscreen = if (build.has_fullscreen) @import("fullscreen") else struct {};
const minimize   = if (build.has_minimize)   @import("minimize")   else struct {};
const workspaces = if (build.has_workspaces) @import("workspaces") else struct {
    pub const State     = struct {};
    pub const Workspace = struct {};
    pub fn getState() ?*State { return null; }
    pub fn getCurrentWorkspaceObject() ?*Workspace { return null; }
};

const tiling  = if (build.has_tiling) @import("tiling") else struct {};
const layouts = if (build.has_tiling) @import("layouts") else struct {
    pub const CacheMap = struct {};
};

const drag = @import("drag");

const bar = if (build.has_bar) @import("bar") else struct {
    pub fn isBarWindow(_: u32) bool { return false; }
    pub fn redrawInsideGrab() void {}
    pub fn scheduleRedraw() void {}
    pub fn setBarState(_: anytype) void {}
};

const WsWorkspace = workspaces.Workspace;
inline fn moveWindowToWs(win: u32, ws: u8) !void {
    if (build.has_workspaces) try workspaces.moveWindowTo(win, ws)
    else try tracking.registerWindow(win, 0);
}
inline fn wsRemoveWindow(win: u32) void {
    if (build.has_workspaces) workspaces.removeWindow(win)
    else tracking.removeWindow(win);
}

const scale = if (build.has_scale) @import("scale") else utils.scale_fallback;


// XSizeHints flags (ICCCM §4.1.2.3)
const XSizeHintsFlags = struct {
    const p_min_size:   u32 = 0x10;
    const p_resize_inc: u32 = 0x40;
    const p_base_size:  u32 = 0x100;
};

// WM_HINTS constants (ICCCM §4.1.2.4)
const WM_HINTS_INPUT_FLAG:  u32   = 1 << 0;
const WM_HINTS_FLAGS_FIELD: usize = 0;
const WM_HINTS_INPUT_FIELD: usize = 1;
const WM_HINTS_LONG_LENGTH: u32   = 9; // flags + 8 fields

const MAX_PROPERTY_LENGTH = constants.PROPERTY_MAX_LENGTH;
const PROPERTY_NO_DELETE  = constants.PROPERTY_NO_DELETE;

/// Minimum window dimension; windows thinner or shorter than this are considered invalid.
const MIN_WINDOW_DIM = constants.MIN_WINDOW_DIM;
/// Maximum depth when walking the X11 window tree in findManagedWindow.
const MAX_WINDOW_TREE_DEPTH = constants.MAX_WINDOW_TREE_DEPTH;

// ---------------------------------------------------------------------------
// Spawn queue
// ---------------------------------------------------------------------------
//
// Tracks pending (workspace, pid) assignments for newly-mapped windows.
// Lives here (window.zig) because it is exclusively accessed by this module.
//
// Implemented as a module-level std.ArrayListUnmanaged so there is one logical
// allocation rather than two (the old design heap-allocated a SpawnQueue node
// that itself heap-allocated its backing slice, plus stored a redundant alloc
// field).  The allocator is stored once at module level (g_alloc) and used for
// both the spawn queue and any other window-module lifetime allocations.
//
// The list is capped at SPAWN_QUEUE_CAP entries.  Exceeding the cap logs an
// error and drops the entry; it never terminates the process.

const SpawnEntry = struct {
    workspace: u8,
    /// _NET_WM_PID of the grandchild; 0 for daemon-mode terminals.
    pid: u32,
};

const SPAWN_QUEUE_CAP: usize = 64;

/// Module allocator, set in init() and used for the spawn queue and any other
/// window-module lifetime allocations.  Null before the first init() call.
var g_alloc: ?std.mem.Allocator = null;

var g_spawn_queue: std.ArrayListUnmanaged(SpawnEntry) = .empty;

var spawn_cursor: struct { x: i16 = 0, y: i16 = 0 } = .{};

// Workspace-rule fast-lookup map
//
// Rebuilt from core.config.workspaces.rules at init() and after every config
// reload.  Maps a WM_CLASS name (class or instance component) to the target
// workspace index (0-based), so `findWorkspaceRuleByClass` can do an O(1)
// hash lookup instead of an O(R) linear scan on every MapRequest.
//
// Keys borrow slices from the config's allocations and are valid until the
// next rebuild (triggered by a config reload via `rebuildRulesMap`).
// Because rebuilding always happens *after* the new config is committed to
// core.config, the borrowed slices are always live.

var g_rules_map: std.StringHashMapUnmanaged(u8) = .{};

// Module-level atom cache
//
// The atoms used on every MapRequest are resolved once into plain u32 fields,
// turning per-event hash probes into direct field reads.  Atoms that cannot be
// interned remain 0; property cookies sent with atom 0 return an empty reply,
// which existing null-reply guards handle correctly.

var atoms: struct {
    wm_protocols:            u32 = 0,
    wm_class:                u32 = 0,
    net_wm_pid:              u32 = 0,
    net_wm_state:            u32 = 0,
    net_wm_state_fullscreen: u32 = 0,
} = .{};

// Geometry cache
//
// Stores last-known window geometry for workspace-switch and minimize/restore.
// When tiling is present, all operations delegate to tiling's own cache so
// there is exactly one source of truth.  When tiling is absent, this module
// owns the cache directly.

var g_geom_cache: layouts.CacheMap = .{};

/// Set by grab-flush paths that already called updateWorkspaceBorders() inside
/// their server grab, so the event loop can skip the redundant second sweep.
/// Reset unconditionally by updateWorkspaceBordersIfNeeded() at the end of each
/// event batch.
var borders_flushed_this_batch: bool = false;

/// Save `rect` as the last-known geometry for `win`.
pub fn saveWindowGeom(win: u32, rect: utils.Rect) void {
    if (build.has_tiling) {
        tiling.saveWindowGeom(win, rect);
    } else {
        g_geom_cache.getOrPut(win).value_ptr.rect = rect;
    }
}

/// Return the last-known geometry for `win`, or null if none is cached.
pub fn getWindowGeom(win: u32) ?utils.Rect {
    if (build.has_tiling) {
        return tiling.getWindowGeom(win);
    } else {
        const wd = g_geom_cache.get(win) orelse return null;
        if (!wd.hasValidRect()) return null;
        return wd.rect;
    }
}

// ---------------------------------------------------------------------------
// Geometry helpers
// ---------------------------------------------------------------------------

/// Screen-space position of a window's top-left corner.
pub const Pos = struct { x: u32, y: u32 };

/// Returns the default floating window position
/// (one quarter of the screen in from the top-left).
pub inline fn floatDefaultPos() Pos {
    return .{
        .x = @intCast(core.screen.width_in_pixels  / 4),
        .y = @intCast(core.screen.height_in_pixels / 4),
    };
}

/// Restore `win` to its saved geometry, or move it to the float default
/// position when no geometry has been saved.  Only X/Y are updated in the
/// fallback case — the window keeps whatever size the server already knows.
///
/// This is the shared implementation of the "restore floating window"
/// pattern that appears in minimize, workspaces, and fullscreen modules.
pub fn restoreFloatGeom(win: u32) void {
    if (getWindowGeom(win)) |rect| {
        utils.configureWindow(core.conn, win, rect);
    } else {
        const pos = floatDefaultPos();
        _ = xcb.xcb_configure_window(core.conn, win,
            xcb.XCB_CONFIG_WINDOW_X | xcb.XCB_CONFIG_WINDOW_Y,
            &[_]u32{ pos.x, pos.y });
    }
}

/// Moves, resizes, and sets border_width atomically,
/// preventing a one-frame flash on fullscreen enter/exit or workspace switch.
pub inline fn configureWindowGeom(conn: *xcb.xcb_connection_t, win: u32, geom: core.WindowGeometry) void {
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
pub fn getGeometry(conn: *xcb.xcb_connection_t, win: u32) ?utils.Rect {
    const reply = xcb.xcb_get_geometry_reply(conn, xcb.xcb_get_geometry(conn, win), null) orelse return null;
    defer std.c.free(reply);
    return utils.Rect.fromXcb(reply);
}

// ---------------------------------------------------------------------------
// ICCCM focus property cache
//
// Keyed by window ID; populated at map time via `populateFocusCacheFromCookies`.
// Invalidated on WM_PROTOCOLS/WM_HINTS `PropertyNotify` and on window destruction.
// Keeps the `setFocus` hot path and close-window path free of blocking X11 round-trips
// for all windows that were seen at map time.
//
// `InputModel` (focus routing) and `wm_delete` (close protocol) are both derived from
// WM_PROTOCOLS, so they are populated together in a single scan.
// See the flat-array implementation below for rationale over AutoHashMap.
// ---------------------------------------------------------------------------

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

// Flat-array window focus property cache.
//
// At realistic open-window counts (≤100 in any real session, ≤300 in the most
// extreme case) a linear scan over 32-bit IDs beats a hash table: cache-local,
// branch-predictor-friendly, zero heap allocation, one initialization path, one
// teardown path, and no OOM error surface at all.
//
// Windows beyond MAX_WINDOW_CACHE still work correctly — they fall through to
// the live X11 query path, which is always the safe fallback.
const MAX_WINDOW_CACHE: usize = 512;

const CacheSlot = struct {
    id:    u32,
    props: CachedProps,
};

var cache_slots: [MAX_WINDOW_CACHE]CacheSlot = undefined;
var cache_len:   usize = 0;
var cache_ready: bool  = false;

/// Initializes the per-window focus property cache.
/// No allocator required — the backing store is a module-level static array.
pub fn initInputModelCache() void {
    cache_len   = 0;
    cache_ready = true;
}

/// Cleans up the per-window focus property cache.
pub fn deinitInputModelCache() void {
    cache_len   = 0;
    cache_ready = false;
}

/// Consumes pre-fired WM_PROTOCOLS and WM_HINTS cookies and stores the result.
/// The caller fires the cookies immediately after xcb_map_window so the server
/// processes property requests in parallel with the map.
pub fn populateFocusCacheFromCookies(
    conn: *xcb.xcb_connection_t,
    win:  u32,
    protocols_cookie: xcb.xcb_get_property_cookie_t,
    hints_cookie:     xcb.xcb_get_property_cookie_t,
) void {
    // Resolve both atoms upfront so a failure on either can discard both cookies
    // together along a single cleanup path.
    const focus_atoms = resolveFocusAtoms() orelse {
        xcb.xcb_discard_reply(conn, protocols_cookie.sequence);
        xcb.xcb_discard_reply(conn, hints_cookie.sequence);
        return;
    };

    // Scan WM_PROTOCOLS once for both atoms (no second round-trip).
    var take_focus = false;
    var wm_delete  = false;

    protocols: {
        const r = xcb.xcb_get_property_reply(conn, protocols_cookie, null) orelse break :protocols;
        defer std.c.free(r);
        if (r.*.format != 32 or r.*.value_len == 0) break :protocols;
        const raw: [*]const u32 = @ptrCast(@alignCast(xcb.xcb_get_property_value(r)));
        const result = scanProtocolAtoms(raw[0..@intCast(r.*.value_len)], focus_atoms.take_focus, focus_atoms.wm_delete);
        take_focus = result.take_focus;
        wm_delete  = result.wm_delete;
    }

    const accepts_input = extractWMHintsInput(conn, hints_cookie);

    putCachedProps(win, .{
        .model     = inputModelFrom(take_focus, accepts_input),
        .wm_delete = wm_delete,
    });
}

/// Resolves WM_TAKE_FOCUS and WM_DELETE_WINDOW atoms from cache.
/// Returns null if either atom is not cached (should not happen after initAtomCache).
inline fn resolveFocusAtoms() ?struct { take_focus: u32, wm_delete: u32 } {
    const take_focus = utils.getAtomCached("WM_TAKE_FOCUS")    catch return null;
    const wm_delete  = utils.getAtomCached("WM_DELETE_WINDOW") catch return null;
    return .{ .take_focus = take_focus, .wm_delete = wm_delete };
}

/// Extracts the WM_HINTS input field from a pre-fired cookie reply.
/// Returns true when absent (assume True per ICCCM) or explicitly True.
fn extractWMHintsInput(
    conn: *xcb.xcb_connection_t,
    hints_cookie: xcb.xcb_get_property_cookie_t,
) bool {
    const r = xcb.xcb_get_property_reply(conn, hints_cookie, null) orelse return true;
    defer std.c.free(r);
    if (r.*.format != 32 or r.*.value_len < 1) return true;
    const hints: [*]const u32 = @ptrCast(@alignCast(xcb.xcb_get_property_value(r)));
    const input_flag_set  = (hints[WM_HINTS_FLAGS_FIELD] & WM_HINTS_INPUT_FLAG) != 0;
    const has_input_field = r.*.value_len > WM_HINTS_INPUT_FIELD;
    if (!input_flag_set or !has_input_field) return true;
    return hints[WM_HINTS_INPUT_FIELD] != 0;
}

/// Recomputes and caches the focus properties after a WM_PROTOCOLS or WM_HINTS
/// PropertyNotify. Two round-trips; called only on rare property change events.
pub fn recacheInputModel(conn: *xcb.xcb_connection_t, win: u32) void {
    _ = queryAndCacheProps(conn, win);
}

/// Removes `win` from the focus property cache — called on window destruction
/// to prevent stale entries from accumulating over the session.
/// Swap-remove keeps the live region dense so subsequent scans stay short.
pub inline fn uncacheWindowFocusProps(win: u32) void {
    if (!cache_ready) return;
    for (cache_slots[0..cache_len], 0..) |slot, i| {
        if (slot.id == win) {
            cache_len -= 1;
            cache_slots[i] = cache_slots[cache_len];
            return;
        }
    }
}

/// Returns the cached focus properties for `win`, or null on a cache miss.
inline fn getCachedProps(win: u32) ?CachedProps {
    if (!cache_ready) return null;
    for (cache_slots[0..cache_len]) |slot| {
        if (slot.id == win) return slot.props;
    }
    return null;
}

/// Inserts or updates the cache entry for `win`.
/// Updates in place when the entry already exists (single write path, no branching).
/// Silently drops the entry when the cache is full — the live-query fallback is always correct.
fn putCachedProps(win: u32, props: CachedProps) void {
    if (!cache_ready) return;
    for (cache_slots[0..cache_len]) |*slot| {
        if (slot.id == win) { slot.props = props; return; }
    }
    if (cache_len < MAX_WINDOW_CACHE) {
        cache_slots[cache_len] = .{ .id = win, .props = props };
        cache_len += 1;
    } else {
        debug.warn("Focus cache full, falling back to live queries", .{});
    }
}

/// Runs both WM_PROTOCOLS and WM_HINTS queries, stores the result, and returns it.
/// Used by cache-miss paths so the populate logic lives in exactly one place.
fn queryAndCacheProps(conn: *xcb.xcb_connection_t, win: u32) CachedProps {
    const protocols_props = queryWMProtocolsProps(conn, win);
    const props = CachedProps{
        .model     = inputModelFrom(protocols_props.take_focus, queryWMHintsAcceptsInput(conn, win)),
        .wm_delete = protocols_props.wm_delete,
    };
    putCachedProps(win, props);
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
    return queryAndCacheProps(conn, win).wm_delete;
}

/// Fires the WM_PROTOCOLS get_property request for `win` and returns the cookie
/// immediately, without blocking.  Used by focus.zig to overlap the round-trip
/// latency of the WM_TAKE_FOCUS check with local focus-transition bookkeeping.
/// Returns null when the WM_PROTOCOLS atom is not yet interned (should not happen
/// after startup but handled gracefully).
pub fn fireTakeFocusCookie(
    conn: *xcb.xcb_connection_t,
    win:  u32,
) ?xcb.xcb_get_property_cookie_t {
    const protocols_atom = utils.getAtomCached("WM_PROTOCOLS") catch return null;
    return xcb.xcb_get_property(conn, 0, win, protocols_atom,
        xcb.XCB_ATOM_ATOM, 0, MAX_PROPERTY_LENGTH);
}

/// Shared implementation: scans `proto_list` for `take_focus_atom` and, when
/// found, sends a WM_TAKE_FOCUS ClientMessage to `win`.
/// Called by both `sendWMTakeFocusWithCookie` (pre-fired cookie path) and
/// `sendWMTakeFocus` (live round-trip path) to keep the send logic in one place.
fn dispatchTakeFocusMessage(
    conn:             *xcb.xcb_connection_t,
    win:              u32,
    time:             u32,
    protocols_atom:   u32,
    take_focus_atom:  u32,
    proto_list:       []const u32,
) void {
    for (proto_list) |atom| {
        if (atom == take_focus_atom) break;
    } else return; // window does not advertise WM_TAKE_FOCUS

    var event = std.mem.zeroes(xcb.xcb_client_message_event_t);
    event.response_type  = xcb.XCB_CLIENT_MESSAGE;
    event.window         = win;
    event.type           = protocols_atom;
    event.format         = 32;
    event.data.data32[0] = take_focus_atom;
    event.data.data32[1] = time;

    _ = xcb.xcb_send_event(conn, 0, win, xcb.XCB_EVENT_MASK_NO_EVENT, @ptrCast(&event));
}

/// Like sendWMTakeFocus but drains an already-fired WM_PROTOCOLS cookie instead
/// of issuing a new round-trip.  The X server has been processing the property
/// request since before commitFocusTransition ran its bookkeeping, so by the time
/// this function is called the reply is typically already in the XCB receive buffer.
pub fn sendWMTakeFocusWithCookie(
    conn:   *xcb.xcb_connection_t,
    win:    u32,
    time:   u32,
    cookie: xcb.xcb_get_property_cookie_t,
) void {
    const protocols_atom  = utils.getAtomCached("WM_PROTOCOLS")  catch {
        xcb.xcb_discard_reply(conn, cookie.sequence);
        return;
    };
    const take_focus_atom = utils.getAtomCached("WM_TAKE_FOCUS") catch {
        xcb.xcb_discard_reply(conn, cookie.sequence);
        return;
    };

    const proto_reply = xcb.xcb_get_property_reply(conn, cookie, null) orelse return;
    defer std.c.free(proto_reply);
    if (proto_reply.*.format != 32 or proto_reply.*.value_len == 0) return;
    const proto_list: [*]const u32 = @ptrCast(@alignCast(xcb.xcb_get_property_value(proto_reply)));
    const len: usize = @intCast(proto_reply.*.value_len);

    dispatchTakeFocusMessage(conn, win, time, protocols_atom, take_focus_atom, proto_list[0..len]);
}

/// Sends a WM_TAKE_FOCUS client message (ICCCM §4.1.7) if and only if the
/// window actually advertises WM_TAKE_FOCUS support in its WM_PROTOCOLS.
///
/// The check is performed live against the X server on every call — matching
/// DWM's sendevent(c, wmatom[WMTakeFocus]) exactly:
///
///   int sendevent(Client *c, Atom proto) {
///       if (XGetWMProtocols(dpy, c->win, &protocols, &n)) {
///           while (!exists && n--)
///               exists = protocols[n] == proto;
///           XFree(protocols);
///       }
///       if (exists) { ... XSendEvent ... }
///   }
///
/// Why live instead of cached:
///   Electron (Discord, VS Code, Equibop, etc.) and many GTK/Qt apps set
///   WM_PROTOCOLS BEFORE or around the time they call XMapWindow.  The WM
///   reads WM_PROTOCOLS at MapRequest time and caches the result.  If Electron
///   sets WM_PROTOCOLS before the WM subscribes to PropertyNotify (i.e. before
///   the MapRequest fires and handleMapRequest sets the event mask), the
///   PropertyNotify is lost and the cache remains stale forever, recording the
///   window as `passive` even though it actually advertises WM_TAKE_FOCUS.
///
///   Without WM_TAKE_FOCUS the app's Electron/Chromium renderer widget never
///   activates its internal focus state (text caret, keyboard routing), even
///   though XSetInputFocus technically succeeds on the top-level window.  DWM
///   works around this by never trusting a cache — it re-reads WM_PROTOCOLS
///   on every call.  We do the same here.
///
///   Hot paths (setFocus) use fireTakeFocusCookie / sendWMTakeFocusWithCookie
///   to pipeline this round-trip.  This fallback is retained for callers that
///   do not pre-fire the cookie (syncPointerFocusBlocking, drainPendingConfirm).
pub fn sendWMTakeFocus(conn: *xcb.xcb_connection_t, win: u32, time: u32) void {
    const protocols_atom  = utils.getAtomCached("WM_PROTOCOLS")  catch return;
    const take_focus_atom = utils.getAtomCached("WM_TAKE_FOCUS") catch return;

    // Live WM_PROTOCOLS scan — same logic as DWM's sendevent.
    const proto_reply = xcb.xcb_get_property_reply(conn,
        xcb.xcb_get_property(conn, 0, win, protocols_atom, xcb.XCB_ATOM_ATOM, 0, MAX_PROPERTY_LENGTH),
        null,
    ) orelse return;
    defer std.c.free(proto_reply);
    if (proto_reply.*.format != 32 or proto_reply.*.value_len == 0) return;
    const proto_list: [*]const u32 = @ptrCast(@alignCast(xcb.xcb_get_property_value(proto_reply)));
    const len: usize = @intCast(proto_reply.*.value_len);

    dispatchTakeFocusMessage(conn, win, time, protocols_atom, take_focus_atom, proto_list[0..len]);
}

// Private ICCCM helpers

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

/// Scans a slice of protocol atoms and returns all WM_PROTOCOLS flags in one pass.
/// Shared by queryWMProtocolsProps (live query) and populateFocusCacheFromCookies (cookie path).
inline fn scanProtocolAtoms(protocol_atoms: []const u32, take_focus_atom: u32, wm_delete_atom: u32) WMProtocolsProps {
    var props: WMProtocolsProps = .{};
    for (protocol_atoms) |atom| {
        if (atom == take_focus_atom) props.take_focus = true;
        if (atom == wm_delete_atom)  props.wm_delete  = true;
        if (props.take_focus and props.wm_delete) break;
    }
    return props;
}

/// Scans WM_PROTOCOLS once and returns all flags the WM cares about.
fn queryWMProtocolsProps(conn: *xcb.xcb_connection_t, win: u32) WMProtocolsProps {
    const protocols_atom  = utils.getAtomCached("WM_PROTOCOLS")    catch return .{};
    const take_focus_atom = utils.getAtomCached("WM_TAKE_FOCUS")   catch return .{};
    const wm_delete_atom  = utils.getAtomCached("WM_DELETE_WINDOW") catch return .{};

    const reply = xcb.xcb_get_property_reply(conn,
        xcb.xcb_get_property(conn, PROPERTY_NO_DELETE, win, protocols_atom, xcb.XCB_ATOM_ATOM, 0, MAX_PROPERTY_LENGTH), null,
    ) orelse return .{};
    defer std.c.free(reply);
    if (reply.*.format != 32 or reply.*.value_len == 0) return .{};

    const raw: [*]const u32 = @ptrCast(@alignCast(xcb.xcb_get_property_value(reply)));
    return scanProtocolAtoms(raw[0..@intCast(reply.*.value_len)], take_focus_atom, wm_delete_atom);
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
    const input_flag_set  = (hints[WM_HINTS_FLAGS_FIELD] & WM_HINTS_INPUT_FLAG) != 0;
    const has_input_field = reply.*.value_len > WM_HINTS_INPUT_FIELD;
    if (!input_flag_set or !has_input_field) return true;
    return hints[WM_HINTS_INPUT_FIELD] != 0;
}

// ---------------------------------------------------------------------------
// WM_CLASS
// ---------------------------------------------------------------------------

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

// ---------------------------------------------------------------------------
// Child window resolution
// ---------------------------------------------------------------------------
//
// Electron, Qt, GTK, and similar toolkits create one or more child windows
// beneath their managed toplevel for rendering.  When a ButtonPress or
// EnterNotify arrives on such a child, `findManagedWindow` walks the X11
// window tree upward (via xcb_query_tree) to find the managed ancestor.
//
// Each xcb_query_tree call is a blocking round-trip.  For Electron apps that
// nest 2–3 child windows, the first hover over the window costs 2–3 round-
// trips.  Subsequent hovers over the same child paid the same cost again.
//
// Child-window cache:
//   Maps child XID → managed toplevel XID for previously resolved children.
//   On a cache hit, findManagedWindow returns immediately with zero XCB calls.
//   On a miss the tree walk runs as before, and the result is stored.
//   Entries are evicted when the managed toplevel is unmanaged (called from
//   unmanageWindow via evictChildCache).
//
// Implementation: fixed flat array with linear scan.  Electron creates at
// most 3–5 child windows per app; with 5 open Electron apps that's ≤25
// entries.  A linear scan over 25 × 8-byte pairs is ~200 bytes — two cache
// lines.  No allocator, no deinit, no error surface.

const CHILD_CACHE_CAP: usize = 64;

const ChildEntry = struct { child: u32, managed: u32 };

var child_cache: [CHILD_CACHE_CAP]ChildEntry = undefined;
var child_cache_len: usize = 0;

/// Record that `child` resolves to `managed` so future tree walks are skipped.
fn cacheChildWindow(child: u32, managed: u32) void {
    if (child == managed) return; // direct hit — not a child, nothing to cache
    for (child_cache[0..child_cache_len]) |*e| {
        if (e.child == child) { e.managed = managed; return; } // update in place
    }
    if (child_cache_len < CHILD_CACHE_CAP) {
        child_cache[child_cache_len] = .{ .child = child, .managed = managed };
        child_cache_len += 1;
    }
    // At cap: silently drop — the tree walk fallback is always correct.
}

/// Remove all entries whose managed toplevel is `managed_win`.
/// Called from unmanageWindow so stale child entries don't linger.
pub fn evictChildCache(managed_win: u32) void {
    var i: usize = 0;
    while (i < child_cache_len) {
        if (child_cache[i].managed == managed_win) {
            child_cache_len -= 1;
            child_cache[i] = child_cache[child_cache_len];
        } else {
            i += 1;
        }
    }
}

/// Walks up the X11 window tree from `win` to find the top-level window the WM
/// manages. Electron apps and other toolkits often use child windows for
/// rendering, so button events may arrive on a child rather than the managed parent.
///
/// Fast path: checks the child-window cache first. On a hit, returns the cached
/// managed ancestor with zero XCB calls — eliminating the 2–3 blocking
/// xcb_query_tree round-trips that previously fired on every hover over an
/// Electron/Qt child window.
pub fn findManagedWindow(conn: *xcb.xcb_connection_t, win: u32, is_managed: *const fn (u32) bool) u32 {
    // Fast path: direct managed window (most common case — no child involved).
    if (is_managed(win)) return win;

    // Fast path: child-window cache hit (common for Electron/Qt after first hover).
    for (child_cache[0..child_cache_len]) |e| {
        if (e.child == win) {
            // Validate: if the cached managed window was since unmanaged (race),
            // is_managed will return false and we fall through to the tree walk.
            if (is_managed(e.managed)) return e.managed;
            break; // stale entry — fall through to tree walk
        }
    }

    // Slow path: walk the X11 window tree. Each iteration is one blocking
    // round-trip. Electron typically nests 2–3 levels, so this runs 2–3 times
    // on the first hover over a new Electron window, then never again.
    var current = win;
    for (0..MAX_WINDOW_TREE_DEPTH) |_| {
        const tree_reply = xcb.xcb_query_tree_reply(
            conn, xcb.xcb_query_tree(conn, current), null,
        ) orelse return win;
        defer std.c.free(tree_reply);

        if (tree_reply.*.parent == tree_reply.*.root or tree_reply.*.parent == 0) return win;
        current = tree_reply.*.parent;
        if (is_managed(current)) {
            cacheChildWindow(win, current);
            return current;
        }
    }
    return win;
}

fn populateAtomCache() void {
    inline for (.{
        .{ .field = "wm_protocols",            .atom = "WM_PROTOCOLS"              },
        .{ .field = "wm_class",                .atom = "WM_CLASS"                  },
        .{ .field = "net_wm_pid",              .atom = "_NET_WM_PID"               },
        .{ .field = "net_wm_state",            .atom = "_NET_WM_STATE"             },
        .{ .field = "net_wm_state_fullscreen", .atom = "_NET_WM_STATE_FULLSCREEN"  },
    }) |e| @field(atoms, e.field) = utils.getAtomCached(e.atom) catch 0;
}

/// (Re)build the workspace-rule fast-lookup map from the current core.config.
/// Keys are borrowed slices pointing into the config's allocations and remain
/// valid until the next rebuild.  If a class name appears in multiple rules,
/// the first rule wins (consistent with the old linear scan).
fn buildRulesMap() void {
    const alloc = g_alloc orelse return;
    g_rules_map.clearRetainingCapacity();
    for (core.config.workspaces.rules.items) |rule| {
        // putNoClobber: first occurrence wins; ignore OOM (map stays usable,
        // the affected rule falls back to the O(n) scan path via null return).
        g_rules_map.putNoClobber(alloc, rule.class_name, rule.workspace) catch {};
    }
}

/// Rebuild the workspace-rule map after a config reload.
/// Must be called AFTER core.config has been swapped to the new config so
/// the borrowed key slices point into the new config's allocations.
pub fn rebuildRulesMap() void { buildRulesMap(); }

pub fn init(alloc: std.mem.Allocator) !void {
    g_alloc = alloc;
    tracking.init(alloc);
    focus.init(alloc);
    // tiling must precede workspaces: workspaces.init() calls tiling.getState().
    if (build.has_tiling)      tiling.init();
    if (build.has_fullscreen)  fullscreen.init();
    if (build.has_workspaces) try workspaces.init();
    if (build.has_minimize)    minimize.init();
    if (build.has_minimize or build.has_workspaces) {
        // Pre-allocate spawn queue capacity for the common case (a handful of
        // concurrent spawns).  Failure is non-fatal; the list grows on demand.
        g_spawn_queue.ensureTotalCapacity(alloc, 16) catch |err| {
            std.log.warn("window: spawn queue pre-allocation failed ({s}); will grow on demand", .{@errorName(err)});
        };
    }
    populateAtomCache();
    initInputModelCache();
    buildRulesMap();
}

pub fn deinit() void {
    // Teardown in reverse-init order.
    if (build.has_tiling)     tiling.deinit();
    if (build.has_fullscreen) fullscreen.deinit();
    if (build.has_workspaces) workspaces.deinit();
    if (build.has_minimize)   minimize.deinit();
    if (g_alloc) |a| {
        g_spawn_queue.deinit(a);
        g_spawn_queue = .empty;
        g_rules_map.deinit(a);
        g_rules_map = .{};
    }
    focus.deinit();
    tracking.deinit();
    deinitInputModelCache();
}

/// Returns true when tiling is both compiled in and enabled at runtime.
inline fn tilingActive() bool {
    if (!build.has_tiling) return false;
    return core.config.tiling.enabled;
}

// Window predicates

pub inline fn isValidManagedWindow(win: u32) bool {
    return win != 0 and
           win != core.root and
           !bar.isBarWindow(win) and
           tracking.isManaged(win);
}

pub inline fn isOnCurrentWorkspace(win: u32) bool {
    if (win == 0 or win == core.root or bar.isBarWindow(win)) return false;
    return tracking.isOnCurrentWorkspace(win);
}

// Button grab management is owned by focus.zig (a focus-protocol concern).
// Off-workspace windows that need initial grab setup call focus.initWindowGrabs.

// Workspace rule matching

/// Returns `target` if it is a valid workspace index, otherwise `fallback`.
inline fn clampToValidWorkspace(target: u8, fallback: u8) u8 {
    return if (target < tracking.getWorkspaceCount()) target else fallback;
}

/// Resolves a pre-fired WM_CLASS property cookie against workspace rules.
/// Parses the WM_CLASS reply inline (no allocation) then does two O(1) hash
/// lookups in g_rules_map — one for the class component and one for the
/// instance component.  The map is built at init() and after every config
/// reload, so no linear scan over the rules list happens at spawn time.
fn findWorkspaceRuleByClass(cookie: xcb.xcb_get_property_cookie_t) ?u8 {
    const reply = xcb.xcb_get_property_reply(core.conn, cookie, null) orelse return null;
    defer std.c.free(reply);
    if (reply.*.format != 8 or reply.*.value_len == 0) return null;

    const raw: [*]const u8 = @ptrCast(xcb.xcb_get_property_value(reply));
    const data = std.mem.trimEnd(u8, raw[0..reply.*.value_len], "\x00");

    const sep = std.mem.indexOfScalar(u8, data, 0) orelse return null;
    const class_start = sep + 1;
    if (class_start >= data.len) return null;

    const instance = data[0..sep];
    const class    = data[class_start..];

    // O(1) hash lookups — class component first, then instance.
    if (g_rules_map.get(class))    |ws| return ws;
    if (g_rules_map.get(instance)) |ws| return ws;
    return null;
}

// Workspace assignment

/// Phase 1 of workspace resolution: checks WM_CLASS against config rules.
fn findClassRuleWorkspace(cookie: xcb.xcb_get_property_cookie_t) ?u8 {
    if (core.config.workspaces.rules.items.len == 0 or atoms.wm_class == 0) {
        xcb.xcb_discard_reply(core.conn, cookie.sequence);
        return null;
    }
    return findWorkspaceRuleByClass(cookie);
}

/// Phase 2 of workspace resolution: matches the window against the spawn queue.
/// Tries exact PID match first; tracks the earliest daemon-mode (pid==0) entry
/// as a candidate; falls back to the oldest pending entry.
/// Returns null when the spawn queue was empty (c_net_wm_pid == null).
///
/// Logs a debug message on both fallback branches so heuristic routing is
/// visible in debug sessions.
fn findSpawnQueueWorkspace(
    c_net_wm_pid: ?xcb.xcb_get_property_cookie_t,
) ?u8 {
    const pid_cookie = c_net_wm_pid orelse return null;

    const win_pid: u32 = pid: {
        const pid_reply = xcb.xcb_get_property_reply(core.conn, pid_cookie, null)
            orelse break :pid 0;
        defer std.c.free(pid_reply);
        if (pid_reply.*.format != 32 or pid_reply.*.value_len < 1) break :pid 0;
        break :pid @as([*]const u32, @ptrCast(@alignCast(xcb.xcb_get_property_value(pid_reply))))[0];
    };

    const entries = g_spawn_queue.items;

    // Single pass: exact PID match takes priority; daemon-mode index is
    // recorded as a fallback candidate without a second scan.
    var daemon_idx: ?usize = null;
    for (entries, 0..) |e, i| {
        if (win_pid != 0 and e.pid == win_pid) {
            const ws = entries[i].workspace;
            _ = g_spawn_queue.swapRemove(i); // order has no semantic meaning
            return ws;
        }
        if (daemon_idx == null and e.pid == 0 and win_pid == 0) daemon_idx = i;
    }

    if (daemon_idx) |i| {
        std.log.debug("spawn: daemon-mode PID match at entry={d}, ws={d}", .{ i, g_spawn_queue.items[i].workspace });
        const ws = g_spawn_queue.items[i].workspace;
        _ = g_spawn_queue.swapRemove(i); // order has no semantic meaning
        return ws;
    }

    // Oldest-entry fallback — only safe when there is exactly one pending entry.
    // Common case: the app was launched via `sh -c "cmd"` and the window reports
    // a PID that is a grandchild of the tracked sh process (sh exec-optimised into
    // cmd, or cmd forked a subprocess for its UI).  With a single entry there is
    // no ambiguity: it must belong to this window.
    //
    // With multiple entries we cannot know which entry belongs to this window.
    // Consuming items[0] would mis-route the window to whatever workspace the
    // *oldest* pending spawn was registered on — which may be a completely
    // different workspace than where the user currently is (the classic symptom:
    // "window spawns on the workspace I was previously on").  Return null so
    // handleMapRequest falls back to current_ws instead.
    if (g_spawn_queue.items.len != 1) {
        std.log.debug(
            "spawn: no exact PID match for pid={d}, {d} entries pending — ambiguous, routing to current workspace",
            .{ win_pid, g_spawn_queue.items.len },
        );
        return null;
    }
    std.log.debug(
        "spawn: no exact PID match for pid={d}, sole entry ws={d} — using heuristic",
        .{ win_pid, g_spawn_queue.items[0].workspace },
    );
    const ws = g_spawn_queue.items[0].workspace;
    _ = g_spawn_queue.swapRemove(0); // order has no semantic meaning
    return ws;
}

/// Resolves the target workspace for a newly mapped window.
fn resolveTargetWorkspace(
    current_ws:    u8,
    c_wm_class:    xcb.xcb_get_property_cookie_t,
    c_net_wm_pid:  ?xcb.xcb_get_property_cookie_t,
) u8 {
    if (findClassRuleWorkspace(c_wm_class)) |target| {
        if (c_net_wm_pid) |pid_cookie|
            xcb.xcb_discard_reply(core.conn, pid_cookie.sequence);
        return clampToValidWorkspace(target, current_ws);
    }

    if (findSpawnQueueWorkspace(c_net_wm_pid)) |spawn_ws|
        return clampToValidWorkspace(spawn_ws, current_ws);

    return current_ws;
}

// Map request

pub fn registerSpawn(workspace: u8, pid: u32) void {
    const alloc = g_alloc orelse return;
    if (g_spawn_queue.items.len >= SPAWN_QUEUE_CAP) {
        debug.warn("registerSpawn: spawn queue full ({d} entries); entry dropped", .{SPAWN_QUEUE_CAP});
        return;
    }
    g_spawn_queue.append(alloc, .{ .workspace = workspace, .pid = pid }) catch |err| {
        debug.warn("registerSpawn: failed to queue spawn entry: {}", .{err});
    };
}

/// Drain a pre-fired xcb_query_pointer cookie and record the cursor position
/// for later spawn-crossing suppression checks.
fn snapshotSpawnCursor(ptr_cookie: xcb.xcb_query_pointer_cookie_t, suppress_reason: core.FocusSuppressReason) void {
    if (suppress_reason != .window_spawn) {
        xcb.xcb_discard_reply(core.conn, ptr_cookie.sequence);
        return;
    }
    const ptr = xcb.xcb_query_pointer_reply(core.conn, ptr_cookie, null) orelse return;
    defer std.c.free(ptr);
    spawn_cursor.x = ptr.*.root_x;
    spawn_cursor.y = ptr.*.root_y;
}

/// Cookies for all properties fired at the start of a MapRequest.
const PropertyCookies = struct {
    protocols:    xcb.xcb_get_property_cookie_t,
    hints:        xcb.xcb_get_property_cookie_t,
    normal_hints: xcb.xcb_get_property_cookie_t,
    wm_class:     xcb.xcb_get_property_cookie_t,
    net_wm_pid:   ?xcb.xcb_get_property_cookie_t,
};

/// Fires all property requests in a single batch before any blocking work.
fn firePropertyCookies(win: u32) PropertyCookies {
    return .{
        .protocols = xcb.xcb_get_property(
            core.conn, 0, win,
            atoms.wm_protocols,
            xcb.XCB_ATOM_ATOM, 0, 256,
        ),
        .hints = xcb.xcb_get_property(
            core.conn, 0, win,
            xcb.XCB_ATOM_WM_HINTS, xcb.XCB_ATOM_WM_HINTS, 0, 9,
        ),
        .normal_hints = xcb.xcb_get_property(
            core.conn, 0, win,
            xcb.XCB_ATOM_WM_NORMAL_HINTS, xcb.XCB_ATOM_ANY, 0, 18,
        ),
        .wm_class = xcb.xcb_get_property(
            core.conn, 0, win,
            atoms.wm_class,
            xcb.XCB_ATOM_STRING, 0, 256,
        ),
        // Only fired when the spawn queue is non-empty so the type system
        // enforces this cookie is never accessed on an idle queue.
        .net_wm_pid = blk: {
            if (g_spawn_queue.items.len == 0) break :blk null;
            break :blk xcb.xcb_get_property(
                core.conn, 0, win,
                atoms.net_wm_pid,
                xcb.XCB_ATOM_CARDINAL, 0, 1,
            );
        },
    };
}

/// Map a newly adopted window that is on the current workspace.
///
/// Runs inside a server grab: tiling registration + retile, geometry
/// configuration, map, focus, border sweep, and bar redraw all land in a
/// single atomic batch.
fn mapWindowToScreen(win: u32) void {
    const ptr_cookie = xcb.xcb_query_pointer(core.conn, core.root);

    _ = xcb.xcb_grab_server(core.conn);

    if (tilingActive()) {
        tiling.addWindow(win);
        tiling.retileCurrentWorkspace();
    } else {
        if (build.has_fullscreen) {
            if (fullscreen.hasAnyFullscreen()) {
                utils.pushWindowOffscreen(core.conn, win);
            }
        }
    }

    applyBorderWidth(win);
    _ = xcb.xcb_map_window(core.conn, win);

    focus.setFocus(win, .window_spawn);
    snapshotSpawnCursor(ptr_cookie, focus.getSuppressReason());

    // Use the post-retile border sweep: tiled-window borders were already
    // updated by configureWithHints during retileCurrentWorkspace above (via
    // the get_border_color callback), so only floating windows need sweeping
    // here.  updateWorkspaceBorders would re-send change_window_attributes
    // to every tiled window redundantly, doubling XCB traffic inside the grab.
    updateWorkspaceBordersPostRetile();
    bar.redrawInsideGrab();
    markBordersFlushed();

    // No xcb_flush here: the event-loop end-of-batch flush covers this.
    // Removing the extra flush eliminates one syscall per spawn.
    _ = xcb.xcb_ungrab_server(core.conn);
}

/// Register a newly adopted window that is on a non-current workspace.
fn registerWindowOffscreen(win: u32) void {
    if (tilingActive()) tiling.addWindow(win);

    applyBorder(win);
    focus.initWindowGrabs(win);

    // No xcb_flush here: the event-loop end-of-batch flush covers this.
    bar.scheduleRedraw();
}

fn discardPropertyCookies(cookies: PropertyCookies) void {
    xcb.xcb_discard_reply(core.conn, cookies.protocols.sequence);
    xcb.xcb_discard_reply(core.conn, cookies.hints.sequence);
    xcb.xcb_discard_reply(core.conn, cookies.normal_hints.sequence);
    xcb.xcb_discard_reply(core.conn, cookies.wm_class.sequence);
    if (cookies.net_wm_pid) |c| xcb.xcb_discard_reply(core.conn, c.sequence);
}

pub fn handleMapRequest(event: *const xcb.xcb_map_request_event_t) void {
    const win = event.window;

    // Guard against double-manage: a window can send multiple MapRequest events
    // (e.g. if it unmaps and remaps itself quickly while the WM is still
    // processing the first).  Without this guard, tiling.addWindow and
    // firePropertyCookies could fire twice for the same window.
    if (tracking.isManaged(win)) return;

    // getCurrentWorkspace() returns ?u8; the value is already bounded to [0,255]
    // by the u8 return type, so no further clamping is needed.
    const current_ws: u8 = tracking.getCurrentWorkspace() orelse 0;

    _ = xcb.xcb_change_window_attributes(
        core.conn, win, xcb.XCB_CW_EVENT_MASK, &[_]u32{constants.EventMasks.MANAGED_WINDOW},
    );

    const cookies   = firePropertyCookies(win);
    const target_ws = resolveTargetWorkspace(current_ws, cookies.wm_class, cookies.net_wm_pid);
    const on_current = target_ws == current_ws;

    moveWindowToWs(win, target_ws) catch |err| {
        debug.logError(err, win);
        discardPropertyCookies(cookies);
        _ = xcb.xcb_flush(core.conn);
        return;
    };

    parseSizeHintsIntoCache(win, cookies.normal_hints);

    populateFocusCacheFromCookies(core.conn, win, cookies.protocols, cookies.hints);

    if (on_current) mapWindowToScreen(win) else registerWindowOffscreen(win);
}

// Unmap / destroy

fn unmanageWindow(win: u32) void {
    const was_fullscreen = if (build.has_fullscreen) blk: {
        const fs_ws = fullscreen.workspaceFor(win);
        if (fs_ws) |ws| fullscreen.removeForWorkspace(ws);
        break :blk fs_ws != null;
    } else false;

    const was_focused = (focus.getFocused() == win);

    const window_workspace = tracking.getWorkspaceForWindow(win);
    const current_ws       = tracking.getCurrentWorkspace();

    uncacheWindowFocusProps(win);

    // Evict any child-window cache entries pointing at this managed toplevel.
    // Without this, a new window reusing the same XID could be mis-identified
    // as the old toplevel's child on the next hover event.
    evictChildCache(win);

    focus.removeFromHistory(win);

    const ptr_cookie: ?xcb.xcb_query_pointer_cookie_t =
        if (was_focused) xcb.xcb_query_pointer(core.conn, core.root) else null;

    _ = xcb.xcb_grab_server(core.conn);

    if (build.has_tiling) {
        // tiling.removeWindow now unconditionally evicts the combined cache entry
        // (geometry + border + size hints), so the separate evictSizeHints call
        // that previously existed here is no longer needed.
        tiling.removeWindow(win);
    }
    if (build.has_minimize) minimize.untrackWindow(win);
    wsRemoveWindow(win);

    if (was_fullscreen) bar.setBarState(.show_fullscreen);

    if (was_focused) {
        if (tilingActive()) tiling.retileIfDirty();
        focus.clearFocus();
        focusWindowUnderPointer(ptr_cookie.?);
    } else if (!was_fullscreen and tilingActive()) {
        if (window_workspace) |ws|
            if (current_ws == ws) tiling.retileIfDirty()
            else tiling.retileInactiveWorkspace(ws);
    }

    // Post-retile border sweep: tiled-window borders are already current after
    // retileIfDirty (handled by configureWithHints), so only float windows need
    // a sweep here.  The full updateWorkspaceBorders would re-send
    // change_window_attributes to every tiled window redundantly.
    updateWorkspaceBordersPostRetile();
    bar.redrawInsideGrab();
    markBordersFlushed();

    // No xcb_flush here: the event-loop end-of-batch flush covers this.
    _ = xcb.xcb_ungrab_server(core.conn);
}

pub fn handleUnmapNotify(event: *const xcb.xcb_unmap_notify_event_t) void {
    if (isValidManagedWindow(event.window)) unmanageWindow(event.window);
}

pub fn handleDestroyNotify(event: *const xcb.xcb_destroy_notify_event_t) void {
    if (isValidManagedWindow(event.window)) unmanageWindow(event.window);
}

/// Post-unmanage focus recovery.
fn focusWindowUnderPointer(ptr_cookie: xcb.xcb_query_pointer_cookie_t) void {
    const fallback: ?*const fn () void = if (build.has_minimize)
        minimize.focusMasterOrFirst
    else
        null;
    const reply = xcb.xcb_query_pointer_reply(core.conn, ptr_cookie, null) orelse {
        focus.focusBestAvailable(.tiling_operation, tracking.isOnCurrentWorkspaceAndVisible, fallback);
        return;
    };
    defer std.c.free(reply);
    const child = reply.*.child;
    if (tracking.isOnCurrentWorkspaceAndVisible(child)) {
        focus.setFocus(child, .mouse_enter);
        return;
    }
    focus.focusBestAvailable(.tiling_operation, tracking.isOnCurrentWorkspaceAndVisible, fallback);
}

// Configure request

const GEOMETRY_MASK: u16 =
    xcb.XCB_CONFIG_WINDOW_X | xcb.XCB_CONFIG_WINDOW_Y |
    xcb.XCB_CONFIG_WINDOW_WIDTH | xcb.XCB_CONFIG_WINDOW_HEIGHT |
    xcb.XCB_CONFIG_WINDOW_BORDER_WIDTH;

const WindowGeometry = struct {
    x:            i16,
    y:            i16,
    width:        u16,
    height:       u16,
    border_width: u16,
};

fn sendConfigureNotify(win: u32, geom: WindowGeometry) void {
    const ev = xcb.xcb_configure_notify_event_t{
        .response_type     = xcb.XCB_CONFIGURE_NOTIFY,
        .pad0              = 0,
        .sequence          = 0,
        .event             = win,
        .window            = win,
        .above_sibling     = xcb.XCB_NONE,
        .x                 = geom.x,
        .y                 = geom.y,
        .width             = geom.width,
        .height            = geom.height,
        .border_width      = geom.border_width,
        .override_redirect = 0,
        .pad1              = 0,
    };
    _ = xcb.xcb_send_event(core.conn, 0, win, xcb.XCB_EVENT_MASK_STRUCTURE_NOTIFY, @ptrCast(&ev));
}

/// Synthesize and send a ConfigureNotify event with the window's current geometry.
///
/// Three paths, in order of cost:
///
///   1. Tiling cache hit — zero round-trips.  The geometry for tiled windows is
///      always up-to-date in the tiling CacheMap after a retile pass.
///
///   2. Fullscreen fast path — zero round-trips.  Fullscreen geometry is fully
///      determined by the screen dimensions written in enterFullscreen:
///      (x=0, y=0, width=screen_width, height=screen_height, border_width=0).
///      The tiling cache for a fullscreen window is intentionally invalidated on
///      enter (so retile skips it), so path 1 misses and we arrive here.
///      Previously this fell through to the blocking xcb_get_geometry path,
///      costing one server round-trip per ConfigureRequest — a problem for
///      video players and screensavers that poll their size continuously.
///
///   3. True cache miss — one blocking xcb_get_geometry round-trip.  This should
///      only occur for floating windows that have never been retiled and are not
///      fullscreen.  It is a genuine fallback, not a hot path.
fn sendSyntheticConfigureNotify(win: u32) void {
    // Path 1: tiling cache — zero round-trips.
    if (build.has_tiling) {
        if (tiling.getWindowGeom(win)) |rect| {
            const border: u16 = if (tiling.getStateOpt()) |s| s.border_width else 0;
            sendConfigureNotify(win, .{
                .x = rect.x, .y = rect.y, .width = rect.width, .height = rect.height,
                .border_width = border,
            });
            return;
        }
    }

    // Path 2: fullscreen — geometry is always (0, 0, screen_w, screen_h, bw=0).
    // enterFullscreen writes exactly these values and invalidates the tiling
    // cache entry, so this window will always miss path 1 while fullscreen.
    if (build.has_fullscreen) {
        if (fullscreen.isFullscreen(win)) {
            sendConfigureNotify(win, .{
                .x            = 0,
                .y            = 0,
                .width        = @intCast(core.screen.width_in_pixels),
                .height       = @intCast(core.screen.height_in_pixels),
                .border_width = 0,
            });
            return;
        }
    }

    // Path 3: true cache miss — floating window, no retile yet. One blocking
    // round-trip.  Rare in practice; not a hot path.
    const reply = xcb.xcb_get_geometry_reply(
        core.conn, xcb.xcb_get_geometry(core.conn, win), null,
    ) orelse return;
    defer std.c.free(reply);
    sendConfigureNotify(win, .{
        .x = reply.*.x, .y = reply.*.y, .width = reply.*.width, .height = reply.*.height,
        .border_width = reply.*.border_width,
    });
}

pub fn handleConfigureRequest(event: *const xcb.xcb_configure_request_event_t) void {
    const win = event.window;

    // Fast exit: no geometry fields requested — nothing for the WM to act on.
    // Checked before the tiling/fullscreen predicates to avoid two hash probes
    // on stacking-order-only requests (e.g. from compositors or override-redirect
    // games) that carry no geometry mask bits.
    const mask = event.value_mask & GEOMETRY_MASK;
    if (mask == 0) return;

    const is_tiled = tilingActive() and tiling.isWindowActiveTiled(win);
    const is_fullscreen = if (build.has_fullscreen) fullscreen.isFullscreen(win) else false;
    if (is_tiled or is_fullscreen) {
        sendSyntheticConfigureNotify(win);
        return;
    }

    // Deny min-size ConfigureRequests from the window being drag-resized.
    // When the WM sizes a floating window below its WM_NORMAL_HINTS minimum,
    // the client fires a ConfigureRequest back with its minimum dimensions.
    // Honouring that request races with the next MotionNotify and causes
    // visible flicker.  Instead, echo the geometry the WM already applied so
    // the client settles without fighting the drag.
    if (drag.isResizingWindow(win)) {
        const last = drag.getDragLastRect();
        if (last.width != 0) {
            sendConfigureNotify(win, .{
                .x            = last.x,
                .y            = last.y,
                .width        = last.width,
                .height       = last.height,
                .border_width = 0,
            });
        } else {
            // No motion event has arrived yet in this drag — fall back to a
            // get_geometry round-trip so we echo an accurate current size.
            sendSyntheticConfigureNotify(win);
        }
        return;
    }

    const GeomField = struct { bit: u16, value: u32 };
    const geom_fields = [_]GeomField{
        .{ .bit = xcb.XCB_CONFIG_WINDOW_X,            .value = @bitCast(@as(i32, event.x)) },
        .{ .bit = xcb.XCB_CONFIG_WINDOW_Y,            .value = @bitCast(@as(i32, event.y)) },
        .{ .bit = xcb.XCB_CONFIG_WINDOW_WIDTH,        .value = event.width                 },
        .{ .bit = xcb.XCB_CONFIG_WINDOW_HEIGHT,       .value = event.height                },
        .{ .bit = xcb.XCB_CONFIG_WINDOW_BORDER_WIDTH, .value = event.border_width          },
    };
    var values: [5]u32 = undefined;
    var n: usize = 0;
    for (geom_fields) |f| {
        if (mask & f.bit != 0) { values[n] = f.value; n += 1; }
    }
    _ = xcb.xcb_configure_window(core.conn, win, mask, &values);
}

// Focus / crossing events

inline fn suppressSpawnCrossing(root_x: i16, root_y: i16) bool {
    if (focus.getSuppressReason() != .window_spawn) return false;
    if (root_x == spawn_cursor.x and root_y == spawn_cursor.y) return true;
    focus.setSuppressReason(.none);
    return false;
}

inline fn maybeFocusWindow(win: u32) void {
    if (!isOnCurrentWorkspace(win)) {
        debug.info("[MAYBE_FOCUS] 0x{x} -> not on current workspace", .{win});
        return;
    }
    if (build.has_minimize) {
        if (minimize.isMinimized(win)) {
            debug.info("[MAYBE_FOCUS] 0x{x} -> minimized", .{win});
            return;
        }
    }
    debug.info("[MAYBE_FOCUS] 0x{x} -> calling dwmFocus", .{win});
    focus.dwmFocus(win);
}

pub fn handleEnterNotify(event: *const xcb.xcb_enter_notify_event_t) void {
    focus.setLastEventTime(event.time);
    debug.info("[ENTER] win=0x{x} mode={} detail={} root_x={} root_y={}", .{
        event.event, event.mode, event.detail, event.root_x, event.root_y,
    });
    if (event.mode != xcb.XCB_NOTIFY_MODE_NORMAL or
        event.detail == xcb.XCB_NOTIFY_DETAIL_INFERIOR)
    {
        debug.info("[ENTER] -> filtered: mode={} detail={}", .{ event.mode, event.detail });
        return;
    }
    if (drag.isDragging()) {
        debug.info("[ENTER] -> filtered: dragging", .{});
        return;
    }
    if (suppressSpawnCrossing(event.root_x, event.root_y)) {
        debug.info("[ENTER] -> filtered: spawn crossing suppressed", .{});
        return;
    }
    if (focus.shouldSuppressEnterNotify()) {
        debug.info("[ENTER] -> filtered: focus suppressed for hover", .{});
        return;
    }
    const managed = findManagedWindow(core.conn, event.event, tracking.isManaged);
    debug.info("[ENTER] -> resolved managed=0x{x}", .{managed});
    maybeFocusWindow(managed);
}

pub fn handleLeaveNotify(event: *const xcb.xcb_leave_notify_event_t) void {
    focus.setLastEventTime(event.time);
    if (event.event != core.root) return;
    if (event.mode != xcb.XCB_NOTIFY_MODE_NORMAL) return;
    if (drag.isDragging()) return;
    if (suppressSpawnCrossing(event.root_x, event.root_y)) return;
    // When child is zero the pointer left to an area not covered by any window.
    if (event.child == 0) return;
    // Guard against unmanaged subwindows (e.g. embedded GTK widgets): LeaveNotify
    // on root with a non-zero child does not guarantee the child is a managed
    // toplevel.  Checking isManaged here avoids a spurious workspace-mask lookup
    // in maybeFocusWindow for every non-toplevel the pointer traverses, and is
    // consistent with how handleEnterNotify routes through findManagedWindow.
    if (!tracking.isManaged(event.child)) return;
    maybeFocusWindow(event.child);
}

// Property notify

pub fn handlePropertyNotify(event: *const xcb.xcb_property_notify_event_t) void {
    if (!isValidManagedWindow(event.window)) return;
    if (event.atom != atoms.wm_protocols and event.atom != xcb.XCB_ATOM_WM_HINTS) return;
    focus.invalidateInputModelCache(event.window);
}

// Size-hint parsing

/// Clamps a u32 to u16 range.
inline fn clampToU16(v: u32) u16 {
    return @intCast(@min(v, std.math.maxInt(u16)));
}

fn parseSizeHintsIntoCache(
    win:    u32,
    cookie: xcb.xcb_get_property_cookie_t,
) void {
    const reply = xcb.xcb_get_property_reply(core.conn, cookie, null) orelse return;
    defer std.c.free(reply);
    if (reply.*.format != 32 or reply.*.value_len < 5) return;

    const fields: [*]const u32 = @ptrCast(@alignCast(xcb.xcb_get_property_value(reply)));
    const field_count = reply.*.value_len;
    const flags       = fields[0];

    if (flags & (XSizeHintsFlags.p_min_size | XSizeHintsFlags.p_base_size | XSizeHintsFlags.p_resize_inc) == 0) return;

    // Single early-out: all three hint types require at most 18 fields (p_base_size
    // reads indices 15–16).  WM_NORMAL_HINTS replies almost always supply the full
    // struct; in the rare short-reply case we accept missing the lower-field hints
    // rather than paying three separate bounds checks on every MapRequest.
    // This reduces cyclomatic complexity from 5 to 3.
    if (field_count < 18) return;

    var min_width:  u16 = 0;
    var min_height: u16 = 0;

    if (flags & XSizeHintsFlags.p_min_size != 0) {
        min_width  = clampToU16(fields[5]);
        min_height = clampToU16(fields[6]);
    }

    // p_base_size overrides p_min_size when both are set (ICCCM §4.1.2.3).
    if (flags & XSizeHintsFlags.p_base_size != 0) {
        min_width  = clampToU16(fields[15]);
        min_height = clampToU16(fields[16]);
    }

    var inc_width:  u16 = 0;
    var inc_height: u16 = 0;
    if (flags & XSizeHintsFlags.p_resize_inc != 0) {
        inc_width  = clampToU16(fields[9]);
        inc_height = clampToU16(fields[10]);
    }

    if (build.has_tiling)
        tiling.cacheSizeHints(win, .{
            .min_width  = min_width,
            .min_height = min_height,
            .inc_width  = inc_width,
            .inc_height = inc_height,
        });
}

// Window borders

/// Returns the DPI-scaled border width.
pub inline fn getBorderWidth() u16 {
    if (build.has_tiling) {
        if (tiling.getStateOpt()) |s| return s.border_width;
    }
    return scale.scaleBorderWidth(
        core.config.tiling.border_width,
        core.screen.height_in_pixels,
    );
}

/// Returns the correct border color for `win`.
inline fn borderColor(win: u32) u32 {
    if (build.has_fullscreen) {
        if (fullscreen.isFullscreen(win)) return 0;
    }
    const cfg = &core.config.tiling;
    return if (focus.getFocused() == win) cfg.border_focused else cfg.border_unfocused;
}

/// Apply border width only to `win`.
pub fn applyBorderWidth(win: u32) void {
    const width = getBorderWidth();
    if (width > 0)
        _ = xcb.xcb_configure_window(core.conn, win,
            xcb.XCB_CONFIG_WINDOW_BORDER_WIDTH, &[_]u32{width});
}

/// Apply border width and color to `win`.
pub fn applyBorder(win: u32) void {
    applyBorderWidth(win);
    _ = xcb.xcb_change_window_attributes(core.conn, win,
        xcb.XCB_CW_BORDER_PIXEL, &[_]u32{borderColor(win)});
}

/// Refresh border colors for every window on the current workspace.
/// Shared implementation for workspace border sweeps.
///
/// When `skip_tiled` is true (post-retile path): tiled windows are skipped
/// because `configureWithHints` already updated their border color via the
/// `get_border_color` callback during the retile pass.  Only floating windows
/// need sweeping here.
///
/// When `skip_tiled` is false (end-of-batch path): all windows are visited.
/// Tiled windows are still deduped via the tiling CacheMap and only receive an
/// XCB call when the color has changed since the last send, so the common
/// steady-state (focused window unchanged) generates zero XCB traffic.
///
/// When tiling is absent or disabled there are no tiled windows to skip, so
/// both paths fall through to the full unconditional sweep.
fn updateWorkspaceBordersImpl(comptime skip_tiled: bool) void {
    if (!build.has_workspaces) return;
    const ws = workspaces.getCurrentWorkspaceObject() orelse return;
    for (ws.windows.items()) |win| {
        if (comptime build.has_tiling) {
            if (skip_tiled and core.config.tiling.enabled) {
                // Post-retile: tiled windows already updated by configureWithHints.
                if (tiling.isWindowTiled(win)) continue;
            }
        }
        const color = borderColor(win);
        // Dedup via the tiling CacheMap: skip the XCB call when color is unchanged.
        if (comptime build.has_tiling) {
            if (tiling.sendBorderColorIfChanged(win, color)) continue;
        }
        _ = xcb.xcb_change_window_attributes(core.conn, win,
            xcb.XCB_CW_BORDER_PIXEL, &[_]u32{color});
    }
}

/// Refresh border colors for every window on the current workspace.
/// Used by `updateWorkspaceBordersIfNeeded` (event-loop end-of-batch sweep)
/// and by `reloadBorders` (config reload, needs all windows).
///
/// Tiled windows are deduped via the tiling geometry cache, skipping
/// `xcb_change_window_attributes` entirely when the color has not changed
/// since the last send.  This eliminates one XCB request per tiled window per
/// event batch in the common steady-state (focused window unchanged): idle
/// typing, scrolling, or cursor movement inside a window no longer generates
/// any border protocol traffic.
///
/// Floating windows with no tiling cache entry are sent unconditionally (they
/// are typically few in number and do not benefit from tiling-cache dedup).
pub fn updateWorkspaceBorders() void {
    updateWorkspaceBordersImpl(false);
}

/// Refresh border colors for only the FLOATING (non-tiled) windows on the
/// current workspace.  Called inside grab-flush paths that just ran a full
/// retile: `configureWithHints` already updated all tiled-window borders via
/// the `get_border_color` callback during the retile, so re-sending them here
/// would be a no-op that costs one `xcb_change_window_attributes` per tiled
/// window per spawn/close inside the server grab.
///
/// Floating windows are not touched by the retile pass and must be swept here.
/// When tiling is absent or disabled, this falls back to the full sweep because
/// there are no tiled windows to skip.
fn updateWorkspaceBordersPostRetile() void {
    updateWorkspaceBordersImpl(true);
}

/// Mark that the current event batch already swept all workspace border colors
/// inside a server grab, so the event loop does not need to do it again.
pub fn markBordersFlushed() void { borders_flushed_this_batch = true; }

/// Event-loop entry point for the per-batch border sweep.
/// Calls updateWorkspaceBorders() only when no grab-flush path already did so,
/// then unconditionally resets the flag for the next batch.
///
/// CALLING CONTRACT: This function must be called exactly once per event batch,
/// at the end of the batch.  Calling it multiple times in a single batch will
/// cause redundant border sweeps: the flag is reset unconditionally after the
/// first call, so a second call will see the flag as false and sweep again.
/// Any upstream refactor that introduces a second call site in the same batch
/// must account for this behavior.
pub fn updateWorkspaceBordersIfNeeded() void {
    if (!borders_flushed_this_batch) updateWorkspaceBorders();
    borders_flushed_this_batch = false;
}

// ClientMessage — EWMH fullscreen requests from applications

pub fn handleClientMessage(event: *const xcb.xcb_client_message_event_t) void {
    if (event.format != 32) return;

    if (atoms.net_wm_state == 0 or event.type != atoms.net_wm_state) return;

    const fs_atom = atoms.net_wm_state_fullscreen;
    if (fs_atom == 0) return;
    const prop1   = event.data.data32[1];
    const prop2   = event.data.data32[2];
    if (prop1 != fs_atom and prop2 != fs_atom) return;

    const win = event.window;
    if (!isValidManagedWindow(win)) return;

    if (build.has_fullscreen) {
        const action = event.data.data32[0];
        const is_fs  = fullscreen.isFullscreen(win);
        const should_enter = switch (action) {
            1 => true,   // _NET_WM_STATE_ADD
            0 => false,  // _NET_WM_STATE_REMOVE
            2 => !is_fs, // _NET_WM_STATE_TOGGLE
            else => return,
        };
        if (should_enter and !is_fs) {
            fullscreen.enterFullscreen(win, null);
        } else if (!should_enter and is_fs) {
            fullscreen.toggle();
        }
    }
}

/// Push updated border width and colors to every managed window across all
/// workspaces. Called on config reload.
pub fn reloadBorders() void {
    if (!build.has_workspaces) return;
    const ws_state = workspaces.getState() orelse return;
    for (ws_state.workspaces) |*ws|
        for (ws.windows.items()) |win| applyBorder(win);
}
