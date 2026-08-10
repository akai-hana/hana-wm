//! Window lifecycle
//! Manages window creation, destruction, configuration, and event handling for all managed windows.

const std = @import("std");

const core = @import("core");
const xcb = core.xcb;
const utils = @import("utils");
const constants = @import("constants");
const debug = @import("debug");
const tracking = @import("tracking");
const focus = @import("focus");
const fullscreen = @import("fullscreen");
const minimize = @import("minimize");
const workspaces = @import("workspaces");
const tiling = @import("tiling");
const drag = @import("drag");
const bar = @import("bar");
const scale = @import("scale");

// XSizeHints flags (ICCCM §4.1.2.3)
const XSizeHintsFlags = struct {
    const p_max_size: u32 = 0x20;
    const p_resize_inc: u32 = 0x40;
    const p_aspect: u32 = 0x80;
};

// WM_HINTS constants (ICCCM §4.1.2.4)
const WM_HINTS_INPUT_FLAG: u32 = 1 << 0;
const WM_HINTS_FLAGS_FIELD: usize = 0;
const WM_HINTS_INPUT_FIELD: usize = 1;
const WM_HINTS_LONG_LENGTH: u32 = 9; // flags + 8 fields
const WM_NORMAL_HINTS_LONG_LENGTH: u32 = 18; // flags + 17 fields (up to base_size/win_gravity)

const MAX_PROPERTY_LENGTH = constants.PROPERTY_MAX_LENGTH;
const PROPERTY_NO_DELETE = constants.PROPERTY_NO_DELETE;

/// Maximum depth when walking the X11 window tree in findManagedWindow.
const MAX_WINDOW_TREE_DEPTH = constants.MAX_WINDOW_TREE_DEPTH;

// Spawn queue: pending (workspace, pid) assignments for newly-mapped windows,
// consumed by resolveTargetWorkspace. Capped at SPAWN_QUEUE_CAP; overflow logs
// and drops the entry rather than growing unbounded.

const SpawnEntry = struct {
    workspace: u8,
    /// _NET_WM_PID of the grandchild; 0 for daemon-mode terminals.
    pid: u32,
};

// Related to, but intentionally distinct from, constants.Limits.MAX_TILED_WINDOWS
// — this bounds pending spawns awaiting their first-map, not the tiled-window pool.
const SPAWN_QUEUE_CAP: usize = 64;

// Module state
//
// All mutable window-module state is grouped into a single State struct,
// mirroring the pattern focus.zig uses (see the comment above its own State
// struct for the full rationale): init() and deinit() can each reset
// everything in one assignment, there is one obvious encapsulation boundary,
// and a deinit()+init() cycle can no longer leave an individual field
// (e.g. a stale cursor position or a batch flag) un-reset by accident.
//
// There is still exactly one window-module context per process (the single
// module-level `state` variable below) — this is for reset discipline, not
// multi-context support.
const State = struct {
    /// Module allocator, set in init() and used for the spawn queue and any
    /// other window-module lifetime allocations.  Null before the first
    /// init() call.
    alloc: ?std.mem.Allocator = null,

    spawn_queue: std.ArrayListUnmanaged(SpawnEntry) = .empty,

    spawn_cursor: struct { x: i16 = 0, y: i16 = 0 } = .{},

    // Workspace-rule fast-lookup map: WM_CLASS name -> target workspace,
    // rebuilt by buildRulesMap() from config.workspaces.rules at init and on
    // every config reload. O(1) lookup instead of a linear scan per
    // MapRequest.
    //
    // Keys borrow slices from the config, so they stay valid until the next
    // reload rebuilds the map — reloads always commit the new config first.
    rules_map: std.StringHashMapUnmanaged(u8) = .{},

    // Atoms used on every MapRequest, resolved once into plain u32 fields
    // instead of hash-probed per event. An atom that fails to intern stays
    // 0; a property request with atom 0 just comes back empty, which the
    // reply guards below already handle.
    atoms: struct {
        wm_protocols: u32 = 0,
        wm_class: u32 = 0,
        net_wm_pid: u32 = 0,
        net_wm_state: u32 = 0,
        net_wm_state_fullscreen: u32 = 0,
    } = .{},

    // ICCCM focus-property cache (see the section comment further below for
    // what accepts_input/wm_delete mean and why WM_TAKE_FOCUS isn't cached).
    cache_slots: utils.BoundedList(CacheSlot, MAX_WINDOW_CACHE) = .{},
    cache_ready: bool = false,

    // child XID -> managed toplevel XID, for previously resolved Electron/Qt
    // child windows (see the "Child window resolution" section below).
    child_cache: utils.BoundedList(ChildEntry, CHILD_CACHE_CAP) = .{},

    /// True when a grab-flush path already called updateFloatingWindowBorders()
    /// inside its own server grab this batch, so the event loop can skip the
    /// redundant second sweep. Reset unconditionally at the end of each batch.
    borders_flushed_this_batch: bool = false,
};

var state: State = .{};

// Geometry cache: last-known window geometry for workspace-switch and
// minimize/restore. Owned by tiling.zig, the single source of truth for both
// tiled and floating windows.

/// Save `rect` as the last-known geometry for `win`. Delegates to tiling,
/// which owns the one geometry cache shared by tiled and floating windows alike.
pub fn saveWindowGeom(win: u32, rect: utils.Rect) void {
    tiling.saveWindowGeom(win, rect);
}

// Geometry helpers

/// Screen-space position of a window's top-left corner.
/// X11 coordinates are signed (windows may be partially off-screen or on a
/// monitor to the left/above the primary), so both fields use i16 to match
/// the XCB wire type for X/Y configure values.
const Pos = struct { x: i16, y: i16 };

/// Returns the default floating window position
/// (one quarter of the screen in from the top-left).
pub inline fn floatDefaultPos() Pos {
    const screen = core.getState().screen;
    return .{
        .x = @intCast(@min(screen.width_in_pixels / 4, std.math.maxInt(i16))),
        .y = @intCast(@min(screen.height_in_pixels / 4, std.math.maxInt(i16))),
    };
}

/// Restore `win` to its saved geometry, or move it to the float default
/// position when no geometry has been saved.  Only X/Y are updated in the
/// fallback case — the window keeps whatever size the server already knows.
///
/// This is the shared implementation of the "restore floating window"
/// pattern that appears in minimize, workspaces, and fullscreen modules.
pub fn restoreFloatGeom(win: u32) void {
    const conn = core.getState().conn;
    if (tiling.getWindowGeom(win)) |rect| {
        utils.configureWindow(conn, win, rect);
    } else {
        moveFloatToDefaultPos(win);
    }
}

/// Moves, resizes, and sets border_width atomically,
/// preventing a one-frame flash on fullscreen enter/exit or workspace switch.
pub inline fn configureWindowGeom(conn: *xcb.xcb_connection_t, win: u32, geom: core.WindowGeometry) void {
    _ = xcb.xcb_configure_window(
        conn,
        win,
        xcb.XCB_CONFIG_WINDOW_X | xcb.XCB_CONFIG_WINDOW_Y |
            xcb.XCB_CONFIG_WINDOW_WIDTH | xcb.XCB_CONFIG_WINDOW_HEIGHT |
            xcb.XCB_CONFIG_WINDOW_BORDER_WIDTH,
        &[_]u32{
            utils.toXcbCoord(geom.x),
            utils.toXcbCoord(geom.y),
            geom.width,
            geom.height,
            geom.border_width,
        },
    );
}

/// Moves `win` to the default floating position (used when no saved geometry exists).
/// Shared by restoreFloatGeom and fullscreen.restoreFloatingWindows.
pub fn moveFloatToDefaultPos(win: u32) void {
    const conn = core.getState().conn;
    const pos = floatDefaultPos();
    _ = xcb.xcb_configure_window(conn, win, xcb.XCB_CONFIG_WINDOW_X | xcb.XCB_CONFIG_WINDOW_Y, &[_]u32{ utils.toXcbCoord(pos.x), utils.toXcbCoord(pos.y) });
}

/// Queries the current geometry of `win`.
/// Returns null if the window does not exist or is not yet mapped.
pub fn getGeometry(conn: *xcb.xcb_connection_t, win: u32) ?utils.Rect {
    const reply = xcb.xcb_get_geometry_reply(conn, xcb.xcb_get_geometry(conn, win), null) orelse return null;
    defer std.c.free(reply);
    return utils.Rect.fromXcb(reply);
}

// ICCCM focus property cache
//
// Keyed by window ID; populated at map time via `populateFocusCacheFromCookies`,
// invalidated on WM_PROTOCOLS/WM_HINTS PropertyNotify and on destruction.
// Caches only half of the ICCCM focus-delivery split:
//   accepts_input — WM_HINTS.input, mirrors dwm's `c->neverfocus`.
//   wm_delete     — WM_DELETE_WINDOW support, for the close-window path.
//
// WM_TAKE_FOCUS is deliberately NOT cached (see getInputModel below): caching
// it would risk missing the invalidating PropertyNotify if WM_PROTOCOLS was
// set before our event mask was in place, wedging a window at a stale
// `passive` verdict for life. A value that's never cached can't go stale.

/// The four ICCCM focus delivery modes (§4.1.7), determined by the combination of
/// WM_HINTS.input and WM_TAKE_FOCUS presence in WM_PROTOCOLS.
const InputModel = enum {
    no_input, // input=False, no WM_TAKE_FOCUS: window doesn't want focus
    passive, // input=True,  no WM_TAKE_FOCUS: set focus via `XSetInputFocus`
    locally_active, // input=True,  WM_TAKE_FOCUS:    set focus + send protocol
    globally_active, // input=False, WM_TAKE_FOCUS:    only send protocol
};

/// Per-window properties cached from WM_HINTS and WM_PROTOCOLS.
///
/// `accepts_input` (WM_HINTS.input) and `wm_delete` (WM_DELETE_WINDOW support)
/// are cached because both are cheap to keep in sync via PropertyNotify and
/// rarely change post-map. WM_TAKE_FOCUS support is intentionally excluded —
/// see the section comment above and getInputModel() below.
const CachedProps = struct {
    accepts_input: bool,
    wm_delete: bool,
};

// At realistic window counts (≤100 typical, ≤300 extreme) a linear scan
// over u32 IDs in a flat array is cache-local and allocation-free. Windows
// beyond MAX_WINDOW_CACHE still work — they just fall through to the live
// X11 query path.
const MAX_WINDOW_CACHE: usize = 512;

const CacheSlot = struct {
    id: u32,
    props: CachedProps,
};

fn matchCacheSlotId(win: u32, slot: CacheSlot) bool {
    return slot.id == win;
}

/// Enables (ready=true) or disables (ready=false) the per-window focus
/// property cache, clearing any entries. Shared by init and deinit so the
/// two paths cannot drift apart. No allocator required — the backing store
/// is a module-level static array.
fn setInputModelCacheReady(ready: bool) void {
    state.cache_slots.clear();
    state.cache_ready = ready;
}

/// Consumes WM_PROTOCOLS and WM_HINTS cookies and stores the result.
/// Called from handleMapRequest, which fires both cookies synchronously
/// (one right before this call) since MapRequest is a one-time event per
/// window, not a hot path worth pipelining.
///
/// The WM_PROTOCOLS reply is still scanned for WM_TAKE_FOCUS here (via
/// `focus_atoms.take_focus`, folded into the same single-pass scan as
/// WM_DELETE_WINDOW) but that half of the result is discarded rather than
/// cached — see getInputModel() for why.
fn populateFocusCacheFromCookies(
    conn: *xcb.xcb_connection_t,
    win: u32,
    protocols_cookie: xcb.xcb_get_property_cookie_t,
    hints_cookie: xcb.xcb_get_property_cookie_t,
) void {
    // Resolve both atoms upfront so a failure on either can discard both cookies
    // together along a single cleanup path.
    const focus_atoms = resolveFocusAtoms() orelse {
        xcb.xcb_discard_reply(conn, protocols_cookie.sequence);
        xcb.xcb_discard_reply(conn, hints_cookie.sequence);
        return;
    };

    // Scan WM_PROTOCOLS once for both atoms (no second round-trip); only
    // .wm_delete gets cached below.
    const protocols_result = protocols: {
        const r = xcb.xcb_get_property_reply(conn, protocols_cookie, null) orelse break :protocols WMProtocolsProps{};
        defer std.c.free(r);
        if (r.*.format != 32 or r.*.value_len == 0) break :protocols WMProtocolsProps{};
        const raw: [*]const u32 = @ptrCast(@alignCast(xcb.xcb_get_property_value(r)));
        break :protocols scanProtocolAtoms(raw[0..@intCast(r.*.value_len)], focus_atoms.take_focus, focus_atoms.wm_delete);
    };

    putCachedProps(win, .{
        .accepts_input = extractWMHintsInput(conn, hints_cookie),
        .wm_delete = protocols_result.wm_delete,
    });
}

/// Resolves WM_TAKE_FOCUS and WM_DELETE_WINDOW atoms from cache.
/// Returns null if either atom is not cached (should not happen after initAtomCache).
inline fn resolveFocusAtoms() ?struct { take_focus: u32, wm_delete: u32 } {
    const take_focus = utils.getAtomCached("WM_TAKE_FOCUS") catch return null;
    const wm_delete = utils.getAtomCached("WM_DELETE_WINDOW") catch return null;
    return .{ .take_focus = take_focus, .wm_delete = wm_delete };
}

/// Shared WM_HINTS input-field parser used by both the cookie path and the
/// live-query path.  Accepts the already-decoded property data slice so the
/// two callers can each handle their own reply lifetime.
///
/// Returns true when the input flag is unset, the field is absent, or the
/// field is explicitly set to True — matching ICCCM §4.1.2.4 defaults.
inline fn parseWMHintsInputFromData(hints: [*]const u32, value_len: u32) bool {
    const input_flag_set = (hints[WM_HINTS_FLAGS_FIELD] & WM_HINTS_INPUT_FLAG) != 0;
    const has_input_field = value_len > @as(u32, WM_HINTS_INPUT_FIELD);
    if (!input_flag_set or !has_input_field) return true;
    return hints[WM_HINTS_INPUT_FIELD] != 0;
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
    return parseWMHintsInputFromData(hints, r.*.value_len);
}

/// Removes `win` from the focus property cache — called on window destruction
/// to prevent stale entries from accumulating over the session.
/// Swap-remove keeps the live region dense so subsequent scans stay short.
fn uncacheWindowFocusProps(win: u32) void {
    if (!state.cache_ready) return;
    if (state.cache_slots.indexOf(win, matchCacheSlotId)) |i| state.cache_slots.swapRemove(i);
}

/// Returns the cached focus properties for `win`, or null on a cache miss.
inline fn getCachedProps(win: u32) ?CachedProps {
    if (!state.cache_ready) return null;
    const i = state.cache_slots.indexOf(win, matchCacheSlotId) orelse return null;
    return state.cache_slots.items[i].props;
}

/// Inserts or updates the cache entry for `win`.
/// Updates in place when the entry already exists (single write path, no branching).
/// Silently drops the entry when the cache is full — the live-query fallback is always correct.
fn putCachedProps(win: u32, props: CachedProps) void {
    if (!state.cache_ready) return;
    if (state.cache_slots.indexOf(win, matchCacheSlotId)) |i| {
        state.cache_slots.items[i].props = props;
        return;
    }
    if (!state.cache_slots.append(.{ .id = win, .props = props })) {
        debug.warn("Focus cache full, falling back to live queries", .{});
    }
}

/// Runs both WM_PROTOCOLS and WM_HINTS queries, stores the result (accepts_input
/// + wm_delete only — see CachedProps), and returns it.
/// Used by cache-miss paths so the populate logic lives in exactly one place.
/// Cache misses are expected to be extremely rare (every window is populated
/// at map time), so the fact that this issues its own WM_PROTOCOLS round trip
/// even though getInputModel() below will immediately issue another one for
/// the live take_focus check is not worth optimizing away.
fn queryAndCacheProps(conn: *xcb.xcb_connection_t, win: u32) CachedProps {
    const props = CachedProps{
        .accepts_input = queryWMHintsAcceptsInput(conn, win),
        .wm_delete = queryWMProtocolsProps(conn, win).wm_delete,
    };
    putCachedProps(win, props);
    return props;
}

/// Resolves the ICCCM §4.1.7 focus-delivery model for `win`: accepts_input
/// comes from the cache above (live query on a miss); supports_take_focus is
/// always queried live, on every call — see the "ICCCM focus property cache"
/// note for why. Focus changes are human-triggered and infrequent, so the
/// extra round trip is not perceptible.
pub fn getInputModel(conn: *xcb.xcb_connection_t, win: u32) InputModel {
    const accepts_input = if (getCachedProps(win)) |props|
        props.accepts_input
    else
        queryAndCacheProps(conn, win).accepts_input;

    const supports_take_focus = queryWMProtocolsProps(conn, win).take_focus;

    return inputModelFrom(supports_take_focus, accepts_input);
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
    win: u32,
) ?xcb.xcb_get_property_cookie_t {
    const protocols_atom = utils.getAtomCached("WM_PROTOCOLS") catch return null;
    return xcb.xcb_get_property(conn, PROPERTY_NO_DELETE, win, protocols_atom, xcb.XCB_ATOM_ATOM, 0, MAX_PROPERTY_LENGTH);
}

/// Extract a slice of atom values from a WM_PROTOCOLS get_property reply.
/// Both sendWMTakeFocusWithCookie and sendWMTakeFocus use the identical three-line
/// extraction; centralising it here removes the duplication.
inline fn protoListFromReply(r: *xcb.xcb_get_property_reply_t) []const u32 {
    const p: [*]const u32 = @ptrCast(@alignCast(xcb.xcb_get_property_value(r)));
    return p[0..@intCast(r.*.value_len)];
}

/// Shared implementation: scans `proto_list` for `take_focus_atom` and, when
/// found, sends a WM_TAKE_FOCUS ClientMessage to `win`.
/// Called by both `sendWMTakeFocusWithCookie` (pre-fired cookie path) and
/// `sendWMTakeFocus` (live round-trip path) to keep the send logic in one place.
fn dispatchTakeFocusMessage(
    conn: *xcb.xcb_connection_t,
    win: u32,
    time: u32,
    protocols_atom: u32,
    take_focus_atom: u32,
    proto_list: []const u32,
) void {
    for (proto_list) |atom| {
        if (atom == take_focus_atom) break;
    } else return; // window does not advertise WM_TAKE_FOCUS

    var event = std.mem.zeroes(xcb.xcb_client_message_event_t);
    event.response_type = xcb.XCB_CLIENT_MESSAGE;
    event.window = win;
    event.type = protocols_atom;
    event.format = 32;
    event.data.data32[0] = take_focus_atom;
    event.data.data32[1] = time;

    _ = xcb.xcb_send_event(conn, 0, win, xcb.XCB_EVENT_MASK_NO_EVENT, @ptrCast(&event));
}

/// Shared WM_TAKE_FOCUS dispatch from an already-drained WM_PROTOCOLS reply.
/// Guarded by the caller owning `reply`'s memory (freed after this returns).
inline fn dispatchTakeFocusFromReply(
    conn: *xcb.xcb_connection_t,
    win: u32,
    time: u32,
    protocols_atom: u32,
    take_focus_atom: u32,
    reply: *xcb.xcb_get_property_reply_t,
) void {
    if (reply.*.format != 32 or reply.*.value_len == 0) return;
    dispatchTakeFocusMessage(conn, win, time, protocols_atom, take_focus_atom, protoListFromReply(reply));
}

/// Like sendWMTakeFocus but drains an already-fired WM_PROTOCOLS cookie instead
/// of issuing a new round-trip.  The X server has been processing the property
/// request since before commitFocusTransition ran its bookkeeping, so by the time
/// this function is called the reply is typically already in the XCB receive buffer.
pub fn sendWMTakeFocusWithCookie(
    conn: *xcb.xcb_connection_t,
    win: u32,
    time: u32,
    cookie: xcb.xcb_get_property_cookie_t,
) void {
    const protocols_atom = utils.getAtomCached("WM_PROTOCOLS") catch {
        xcb.xcb_discard_reply(conn, cookie.sequence);
        return;
    };
    const take_focus_atom = utils.getAtomCached("WM_TAKE_FOCUS") catch {
        xcb.xcb_discard_reply(conn, cookie.sequence);
        return;
    };

    const proto_reply = xcb.xcb_get_property_reply(conn, cookie, null) orelse return;
    defer std.c.free(proto_reply);
    dispatchTakeFocusFromReply(conn, win, time, protocols_atom, take_focus_atom, proto_reply);
}

/// Sends a WM_TAKE_FOCUS client message (ICCCM §4.1.7) iff `win` advertises
/// WM_TAKE_FOCUS in WM_PROTOCOLS. Checked live on every call, matching dwm's
/// sendevent() — see the "ICCCM focus property cache" note above for why this
/// one flag is never cached (Electron/GTK apps can set WM_PROTOCOLS before we
/// subscribe to PropertyNotify, permanently staling a cached value).
///
/// Hot paths (setFocus) use fireTakeFocusCookie / sendWMTakeFocusWithCookie to
/// pipeline the round trip; this is the fallback for callers that don't
/// pre-fire the cookie (drainPendingConfirm).
pub fn sendWMTakeFocus(conn: *xcb.xcb_connection_t, win: u32, time: u32) void {
    const protocols_atom = utils.getAtomCached("WM_PROTOCOLS") catch return;
    const take_focus_atom = utils.getAtomCached("WM_TAKE_FOCUS") catch return;

    const proto_reply = xcb.xcb_get_property_reply(
        conn,
        xcb.xcb_get_property(conn, PROPERTY_NO_DELETE, win, protocols_atom, xcb.XCB_ATOM_ATOM, 0, MAX_PROPERTY_LENGTH),
        null,
    ) orelse return;
    defer std.c.free(proto_reply);
    dispatchTakeFocusFromReply(conn, win, time, protocols_atom, take_focus_atom, proto_reply);
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
        if (atom == wm_delete_atom) props.wm_delete = true;
        if (props.take_focus and props.wm_delete) break;
    }
    return props;
}

/// Scans WM_PROTOCOLS once and returns all flags the WM cares about.
fn queryWMProtocolsProps(conn: *xcb.xcb_connection_t, win: u32) WMProtocolsProps {
    const protocols_atom = utils.getAtomCached("WM_PROTOCOLS") catch return .{};
    const take_focus_atom = utils.getAtomCached("WM_TAKE_FOCUS") catch return .{};
    const wm_delete_atom = utils.getAtomCached("WM_DELETE_WINDOW") catch return .{};

    const reply = xcb.xcb_get_property_reply(
        conn,
        xcb.xcb_get_property(conn, PROPERTY_NO_DELETE, win, protocols_atom, xcb.XCB_ATOM_ATOM, 0, MAX_PROPERTY_LENGTH),
        null,
    ) orelse return .{};
    defer std.c.free(reply);
    if (reply.*.format != 32 or reply.*.value_len == 0) return .{};

    const raw: [*]const u32 = @ptrCast(@alignCast(xcb.xcb_get_property_value(reply)));
    return scanProtocolAtoms(raw[0..@intCast(reply.*.value_len)], take_focus_atom, wm_delete_atom);
}

/// Queries the WM_HINTS input field. Returns true when absent (assume True) or explicitly True.
fn queryWMHintsAcceptsInput(conn: *xcb.xcb_connection_t, win: u32) bool {
    return extractWMHintsInput(conn, xcb.xcb_get_property(
        conn,
        PROPERTY_NO_DELETE,
        win,
        xcb.XCB_ATOM_WM_HINTS,
        xcb.XCB_ATOM_WM_HINTS,
        0,
        WM_HINTS_LONG_LENGTH,
    ));
}

// Child window resolution
//
// Electron/Qt/GTK toolkits render into child windows beneath their managed
// toplevel, so ButtonPress/EnterNotify often land on a child, not the window
// we manage. findManagedWindow walks the X11 tree upward (xcb_query_tree) to
// find the managed ancestor — each step is a blocking round-trip, so without
// caching, every hover over a nested Electron window pays 2-3 round-trips.
//
// state.child_cache maps child XID -> managed toplevel XID for previously resolved
// children, so repeat hovers cost zero XCB calls. Entries are evicted when
// their toplevel is unmanaged (evictChildCache, called from unmanageWindow).
// A fixed flat array is enough: Electron nests at most 3-5 children per app,
// so even five open Electron windows fit in ~25 entries.

const CHILD_CACHE_CAP: usize = 64;

const ChildEntry = struct { child: u32, managed: u32 };

fn matchChildEntry(child: u32, e: ChildEntry) bool {
    return e.child == child;
}

/// Record that `child` resolves to `managed` so future tree walks are skipped.
fn cacheChildWindow(child: u32, managed: u32) void {
    if (child == managed) return; // direct hit — not a child, nothing to cache
    if (state.child_cache.indexOf(child, matchChildEntry)) |i| {
        state.child_cache.items[i].managed = managed; // update in place
        return;
    }
    // At cap, append silently drops — the tree walk fallback is always correct.
    _ = state.child_cache.append(.{ .child = child, .managed = managed });
}

/// Remove all entries whose managed toplevel is `managed_win`.
/// Called from unmanageWindow so stale child entries don't linger.
fn evictChildCache(managed_win: u32) void {
    var i: usize = 0;
    while (i < state.child_cache.len) {
        if (state.child_cache.items[i].managed == managed_win) {
            state.child_cache.swapRemove(i);
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
/// managed ancestor with zero XCB calls, avoiding the 2–3 blocking
/// xcb_query_tree round-trips that a full tree walk on every hover over an
/// Electron/Qt child window would otherwise cost.
pub fn findManagedWindow(conn: *xcb.xcb_connection_t, win: u32, is_managed: *const fn (u32) bool) u32 {
    // Fast path: direct managed window (most common case — no child involved).
    if (is_managed(win)) return win;

    // Fast path: child-window cache hit (common for Electron/Qt after first hover).
    if (state.child_cache.indexOf(win, matchChildEntry)) |i| {
        // Validate: if the cached managed window was since unmanaged (race),
        // is_managed will return false and we fall through to the tree walk.
        const managed = state.child_cache.items[i].managed;
        if (is_managed(managed)) return managed;
        // stale entry — fall through to tree walk
    }

    // Slow path: walk the X11 window tree. Each iteration is one blocking
    // round-trip. Electron typically nests 2–3 levels, so this runs 2–3 times
    // on the first hover over a new Electron window, then never again.
    var current = win;
    for (0..MAX_WINDOW_TREE_DEPTH) |_| {
        const tree_reply = xcb.xcb_query_tree_reply(
            conn,
            xcb.xcb_query_tree(conn, current),
            null,
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
        .{ .field = "wm_protocols", .atom = "WM_PROTOCOLS" },
        .{ .field = "wm_class", .atom = "WM_CLASS" },
        .{ .field = "net_wm_pid", .atom = "_NET_WM_PID" },
        .{ .field = "net_wm_state", .atom = "_NET_WM_STATE" },
        .{ .field = "net_wm_state_fullscreen", .atom = "_NET_WM_STATE_FULLSCREEN" },
    }) |e| @field(state.atoms, e.field) = utils.getAtomCached(e.atom) catch 0;
}

/// (Re)build the workspace-rule fast-lookup map from the current config.
/// Keys are borrowed slices pointing into the config's allocations and remain
/// valid until the next rebuild.  If a class name appears in multiple rules,
/// the first rule wins, matching the semantics of a plain linear scan through
/// the rule list.
pub fn buildRulesMap() void {
    const alloc = state.alloc orelse return;
    state.rules_map.clearRetainingCapacity();
    for (core.getState().config.workspaces.rules.items) |rule| {
        // putNoClobber: first occurrence wins.  On OOM the entry is silently
        // dropped — there is no linear-scan fallback.  The affected rule will
        // not fire; the window is routed to the current workspace instead.
        state.rules_map.putNoClobber(alloc, rule.class_name, rule.workspace) catch {};
    }
}

pub fn init(alloc: std.mem.Allocator) !void {
    // Reset every field to its zero value so that a deinit() + init() cycle
    // (session restart, test harness) starts from a clean slate rather than
    // carrying over whatever the previous cycle left behind.
    state = .{};
    state.alloc = alloc;
    tracking.init(alloc);
    focus.init();
    // tiling must precede workspaces: workspaces.init() calls tiling.getState().
    tiling.init();
    fullscreen.init();
    try workspaces.init();
    minimize.init();
    // Pre-allocate spawn queue capacity for the common case (a handful of
    // concurrent spawns).  Failure is non-fatal; the list grows on demand.
    state.spawn_queue.ensureTotalCapacity(alloc, 16) catch |err| {
        std.log.warn("window: spawn queue pre-allocation failed ({s}); will grow on demand", .{@errorName(err)});
    };
    populateAtomCache();
    setInputModelCacheReady(true);
    buildRulesMap();
}

pub fn deinit() void {
    // Teardown order: optional subsystems in approximate reverse-init order,
    // then InputModelCache (which must precede focus and tracking — see the
    // init-order note in the InputModelCache section above), then focus, then
    // tracking. This is NOT strict reverse-init order; the InputModelCache
    // dependency intentionally breaks strict symmetry.
    tiling.deinit();
    fullscreen.deinit();
    workspaces.deinit();
    minimize.deinit();
    // Free heap-backed state before the reset below wipes the struct — a
    // bare `state = .{}` would leak the spawn queue's and rules map's
    // backing memory rather than freeing it.
    if (state.alloc) |a| {
        state.spawn_queue.deinit(a);
        state.rules_map.deinit(a);
    }
    // InputModel cache must be torn down before focus and tracking, mirroring
    // the init order where setInputModelCacheReady(true) follows focus.init().
    // focus.deinit() and tracking.deinit() may sweep managed windows and
    // must not encounter a partially-valid cache.
    setInputModelCacheReady(false);
    focus.deinit();
    tracking.deinit();
    // Reset every remaining field (spawn_cursor, atoms, child_cache,
    // borders_flushed_this_batch, and the now-freed spawn_queue/rules_map/
    // alloc) to its zero value in one place, so nothing is left stale for
    // the next init() the way spawn_cursor and borders_flushed_this_batch
    // previously were.
    state = .{};
}

inline fn tilingActive() bool {
    return core.getState().config.tiling.enabled;
}

// Window predicates

/// True for the null window, the root, or the bar — never valid focus/manage targets.
pub inline fn isInvalidWindow(win: u32) bool {
    return win == 0 or win == core.getState().root or bar.isBarWindow(win);
}

pub inline fn isValidManagedWindow(win: u32) bool {
    return !isInvalidWindow(win) and tracking.isManaged(win);
}

inline fn isOnCurrentWorkspace(win: u32) bool {
    if (isInvalidWindow(win)) return false;
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
/// lookups in state.rules_map — one for the class component and one for the
/// instance component.  The map is built at init() and after every config
/// reload, so no linear scan over the rules list happens at spawn time.
fn findWorkspaceRuleByClass(cookie: xcb.xcb_get_property_cookie_t) ?u8 {
    const reply = xcb.xcb_get_property_reply(core.getState().conn, cookie, null) orelse return null;
    defer std.c.free(reply);
    if (reply.*.format != 8 or reply.*.value_len == 0) return null;

    const raw: [*]const u8 = @ptrCast(xcb.xcb_get_property_value(reply));
    const data = raw[0..reply.*.value_len];

    // WM_CLASS is two consecutive null-terminated strings: "instance\0class\0".
    // Do NOT trim trailing nulls from the whole buffer before splitting: doing
    // so turns "instance\0\0" (empty class) into "instance", which has no null
    // separator and causes an early return null — silently skipping the instance
    // lookup.  Instead, find the separator first, then trim each component.
    const sep = std.mem.indexOfScalar(u8, data, 0) orelse return null;
    const instance = data[0..sep];

    const class_start = sep + 1;
    // Extract the class component, stripping any trailing null padding.
    const class_raw = if (class_start < data.len) data[class_start..] else "";
    const class_end = std.mem.indexOfScalar(u8, class_raw, 0) orelse class_raw.len;
    const class = class_raw[0..class_end];

    // O(1) hash lookups — class first (when non-empty), then instance.
    if (class.len > 0) {
        if (state.rules_map.get(class)) |ws| return ws;
    }
    if (instance.len > 0) {
        if (state.rules_map.get(instance)) |ws| return ws;
    }
    return null;
}

// Workspace assignment

/// Phase 2 of workspace resolution: matches the window against the spawn queue.
/// Tries exact PID match first; tracks the earliest daemon-mode (pid==0) entry
/// as a candidate; falls back to the oldest pending entry.
/// The caller only fires `c_net_wm_pid` (and calls this function at all) when
/// the spawn queue is non-empty, so no empty-queue case is handled here.
///
/// Logs a debug message on both fallback branches so heuristic routing is
/// visible in debug sessions.
fn findSpawnQueueWorkspace(
    c_net_wm_pid: xcb.xcb_get_property_cookie_t,
) ?u8 {
    const win_pid: u32 = pid: {
        const pid_reply = xcb.xcb_get_property_reply(core.getState().conn, c_net_wm_pid, null) orelse break :pid 0;
        defer std.c.free(pid_reply);
        if (pid_reply.*.format != 32 or pid_reply.*.value_len < 1) break :pid 0;
        break :pid @as([*]const u32, @ptrCast(@alignCast(xcb.xcb_get_property_value(pid_reply))))[0];
    };

    const entries = state.spawn_queue.items;

    // Single pass: exact PID match only.
    //
    // Daemon-mode entries (pid == 0) and windows without _NET_WM_PID
    // (win_pid == 0) are intentionally NOT matched here.  Treating
    // "win_pid == 0" as a daemon-mode signal conflates two distinct cases:
    //
    //   • A terminal registered with pid=0 (knows it will fork a grandchild).
    //   • Any regular application that simply does not set _NET_WM_PID.
    //
    // The false-match risk is real: if a daemon-mode entry sits in the queue
    // and an unrelated app without _NET_WM_PID maps, it would silently consume
    // the daemon entry and route to the wrong workspace.  Both cases are
    // handled correctly by the single-entry oldest-entry fallback below.
    for (entries, 0..) |e, i| {
        if (win_pid != 0 and e.pid == win_pid) {
            _ = state.spawn_queue.swapRemove(i);
            return e.workspace;
        }
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
    if (state.spawn_queue.items.len != 1) {
        std.log.debug(
            "spawn: no exact PID match for pid={d}, {d} entries pending — ambiguous, routing to current workspace",
            .{ win_pid, state.spawn_queue.items.len },
        );
        return null;
    }
    std.log.debug(
        "spawn: no exact PID match for pid={d}, sole entry ws={d} — using heuristic",
        .{ win_pid, state.spawn_queue.items[0].workspace },
    );
    const ws = state.spawn_queue.items[0].workspace;
    _ = state.spawn_queue.swapRemove(0); // order has no semantic meaning
    return ws;
}

/// Resolves the target workspace for a newly mapped window. Queries are
/// fire-then-drain, not pipelined (see handleMapRequest below for why), and
/// WM_CLASS / _NET_WM_PID are only fired when actually needed (a rule set
/// exists; the spawn queue is non-empty) — so there's nothing to discard on
/// paths that skip them.
fn resolveTargetWorkspace(win: u32, current_ws: u8) u8 {
    const cs = core.getState();

    if (cs.config.workspaces.rules.items.len > 0 and state.atoms.wm_class != 0) {
        const c_wm_class = xcb.xcb_get_property(cs.conn, PROPERTY_NO_DELETE, win, state.atoms.wm_class, xcb.XCB_ATOM_STRING, 0, 256);
        if (findWorkspaceRuleByClass(c_wm_class)) |target|
            return clampToValidWorkspace(target, current_ws);
    }

    if (state.spawn_queue.items.len > 0) {
        const c_net_wm_pid = xcb.xcb_get_property(cs.conn, PROPERTY_NO_DELETE, win, state.atoms.net_wm_pid, xcb.XCB_ATOM_CARDINAL, 0, 1);
        if (findSpawnQueueWorkspace(c_net_wm_pid)) |spawn_ws|
            return clampToValidWorkspace(spawn_ws, current_ws);
    }

    return current_ws;
}

// Map request

pub fn registerSpawn(workspace: u8, pid: u32) void {
    const alloc = state.alloc orelse return;
    if (state.spawn_queue.items.len >= SPAWN_QUEUE_CAP) {
        debug.warn("registerSpawn: spawn queue full ({d} entries); entry dropped", .{SPAWN_QUEUE_CAP});
        return;
    }
    state.spawn_queue.append(alloc, .{ .workspace = workspace, .pid = pid }) catch |err| {
        debug.warn("registerSpawn: failed to queue spawn entry: {}", .{err});
    };
}

// Pointer snapshot for spawn-crossing suppression.
//
// mapWindowToScreen fires+drains xcb_query_pointer synchronously (MapRequest
// is once-per-window, so the round trip isn't perceptible). Don't reach for
// prefetch/caching here — that's for genuinely hot paths like dragging and
// retiling, where the savings actually matter.

/// Record the cursor position from a drained pointer reply for later
/// spawn-crossing suppression checks.  The caller owns the reply memory;
/// this function only reads from it.
///
/// When `ptr_reply` is null (pointer query failed), the suppression flag is
/// cleared rather than leaving `state.spawn_cursor` at its previous value, which
/// could be {0,0} on startup and cause false suppression for windows at the
/// screen origin.
fn snapshotSpawnCursorFromReply(ptr_reply: ?*xcb.xcb_query_pointer_reply_t, suppress_reason: core.FocusSuppressReason) void {
    if (suppress_reason != .window_spawn) return;
    const ptr = ptr_reply orelse {
        // Cannot snapshot a valid cursor position — disable suppression so
        // the stale state.spawn_cursor value does not block legitimate focus events.
        focus.setSuppressReason(.none);
        return;
    };
    state.spawn_cursor.x = ptr.*.root_x;
    state.spawn_cursor.y = ptr.*.root_y;
}

/// Map a newly adopted window that is on the current workspace.
///
/// The server grab is kept as narrow as possible:
///
///   Before the grab — no reply needed, so the compositor keeps compositing:
///     • tiling.addWindow + retileCurrentWorkspace: configure_window for every
///       managed window. Can take 5–20 ms on weak hardware; running it outside
///       the grab avoids a compositor stall on every spawn.
///     • xcb_query_pointer, fired and drained synchronously (see the pointer
///       snapshot comment above for why this isn't prefetched).
///
///   Inside the grab (atomic, compositor-locked):
///     • applyBorderWidth + xcb_map_window + setFocus + border sweep + bar —
///       must land in a single frame to avoid a flash of an unfocused or
///       unbordered window.
fn mapWindowToScreen(win: u32) void {
    const cs = core.getState();
    const conn = cs.conn;

    const ptr_reply = xcb.xcb_query_pointer_reply(conn, xcb.xcb_query_pointer(conn, cs.root), null);
    defer if (ptr_reply) |r| std.c.free(r);

    // ── Outside the grab: expensive layout work ─────────────────────────────
    //
    // Run tiling before the grab.  The configure_window calls issued by
    // retileCurrentWorkspace are pure fire-and-forget output; they do not
    // require the X server to be locked.  The compositor may composite
    // intermediate frames — a window may briefly appear at its old position —
    // but the grab below immediately follows and will issue the final correct
    // geometry atomically before the first MapNotify, so no incorrect frame
    // is ever displayed to the user.
    //
    // focus.setFocus(win, ...) below hasn't run yet at this point, so
    // focus.getFocused() would still report the previously-focused window.
    // Pass `win` explicitly as the pending focus target so focus-driven
    // layouts (e.g. monocle) treat the new window as focused immediately,
    // instead of lagging by one retile.
    if (tilingActive()) {
        tiling.addWindow(win);
        tiling.retileCurrentWorkspaceWithPendingFocus(win);
    } else {
        if (fullscreen.hasAnyFullscreen()) {
            // Leave it offscreen — restoreFloatGeom would immediately move it
            // back to a visible position (its cached geometry, or the default
            // floating position when uncached), undoing the push above.
            utils.pushWindowOffscreen(conn, win);
        } else {
            restoreFloatGeom(win);
        }
    }

    // ── Inside the grab: atomic map, focus, borders ─────────────────────────
    _ = xcb.xcb_grab_server(conn);

    applyBorderWidth(win);
    _ = xcb.xcb_map_window(conn, win);

    focus.setFocus(win, .window_spawn);
    // Re-check the suppress reason *after* setFocus, not before: setFocus is
    // what actually arms `.window_spawn` (via suppressionFor). Reading it
    // beforehand — when it's almost always `.none` — meant this snapshot
    // was skipped on virtually every spawn, leaving state.spawn_cursor
    // stale and spawn-crossing suppression unable to match.
    snapshotSpawnCursorFromReply(ptr_reply, focus.getSuppressReason());

    // Post-retile border sweep: tiled-window borders were already updated by
    // configureWithHints during retileCurrentWorkspace (via get_border_color),
    // so only floating windows need sweeping here.
    updateFloatingWindowBorders();
    bar.redrawInsideGrab();
    markBordersFlushed();

    // No xcb_flush here: the event-loop end-of-batch flush covers this.
    _ = xcb.xcb_ungrab_server(conn);
}

/// Register a newly adopted window that is on a non-current workspace.
fn registerWindowOffscreen(win: u32) void {
    if (tilingActive()) tiling.addWindow(win);

    applyBorder(win);
    focus.initWindowGrabs(win);

    // No xcb_flush here: the event-loop end-of-batch flush covers this.
    bar.scheduleRedraw();
}

/// Handles a MapRequest by querying the properties it needs one at a time:
/// fire the request, then immediately drain the reply, rather than batching
/// every cookie up front the way a hot path (dragging, retiling) would.
/// MapRequest happens once per window creation, so the extra round trips
/// aren't perceptible — and querying only once the window is confirmed to
/// belong on some workspace means there's nothing to discard on the
/// early-return error path below.
pub fn handleMapRequest(event: *const xcb.xcb_map_request_event_t) void {
    const win = event.window;
    const conn = core.getState().conn;

    // Guard against double-manage: a window can send multiple MapRequest events
    // (e.g. if it unmaps and remaps itself quickly while the WM is still
    // processing the first).  Without this guard, tiling.addWindow and the
    // property queries below could fire twice for the same window.
    if (tracking.isManaged(win)) return;

    // getCurrentWorkspace() returns ?u8; the value is already bounded to [0,255]
    // by the u8 return type, so no further clamping is needed.
    const current_ws: u8 = tracking.getCurrentWorkspace() orelse 0;

    _ = xcb.xcb_change_window_attributes(
        conn,
        win,
        xcb.XCB_CW_EVENT_MASK,
        &[_]u32{constants.EventMasks.MANAGED_WINDOW},
    );

    const target_ws = resolveTargetWorkspace(win, current_ws);
    const on_current = target_ws == current_ws;

    workspaces.moveWindowTo(win, target_ws) catch |err| {
        debug.logError(err, win);
        // Nothing has been fired yet beyond what resolveTargetWorkspace already
        // drained, so there is no cookie left to discard here.
        return;
    };

    const normal_hints_cookie = xcb.xcb_get_property(
        conn,
        PROPERTY_NO_DELETE,
        win,
        xcb.XCB_ATOM_WM_NORMAL_HINTS,
        xcb.XCB_ATOM_ANY,
        0,
        WM_NORMAL_HINTS_LONG_LENGTH,
    );
    parseSizeHintsIntoCache(win, normal_hints_cookie);

    const protocols_cookie = xcb.xcb_get_property(
        conn,
        PROPERTY_NO_DELETE,
        win,
        state.atoms.wm_protocols,
        xcb.XCB_ATOM_ATOM,
        0,
        MAX_PROPERTY_LENGTH,
    );
    const hints_cookie = xcb.xcb_get_property(
        conn,
        PROPERTY_NO_DELETE,
        win,
        xcb.XCB_ATOM_WM_HINTS,
        xcb.XCB_ATOM_WM_HINTS,
        0,
        WM_HINTS_LONG_LENGTH,
    );
    populateFocusCacheFromCookies(conn, win, protocols_cookie, hints_cookie);

    if (on_current) mapWindowToScreen(win) else registerWindowOffscreen(win);
}

// Unmap / destroy

fn unmanageWindow(win: u32) void {
    const cs = core.getState();
    const was_fullscreen = blk: {
        const fs_ws = fullscreen.workspaceFor(win);
        if (fs_ws) |ws| fullscreen.removeForWorkspace(ws);
        break :blk fs_ws != null;
    };

    const was_focused = (focus.getFocused() == win);

    const window_workspace = tracking.getWorkspaceForWindow(win);
    const current_ws = tracking.getCurrentWorkspace();

    uncacheWindowFocusProps(win);

    // Evict any child-window cache entries pointing at this managed toplevel.
    // Without this, a new window reusing the same XID could be mis-identified
    // as the old toplevel's child on the next hover event.
    evictChildCache(win);

    // Fire the pointer query and drain the reply *before* grabbing the
    // server.  Draining the reply inside the grab (e.g. from within
    // focusWindowUnderPointer via xcb_query_pointer_reply) would trigger an
    // implicit XCB output-buffer flush inside the grab — releasing all
    // queued configure_window / set_input_focus requests to the compositor
    // before xcb_ungrab_server.  Pre-draining here keeps the grab atomic.
    // The pointer position is at most microseconds staler.
    const ptr_reply: ?*xcb.xcb_query_pointer_reply_t = if (was_focused) blk: {
        const cookie = xcb.xcb_query_pointer(cs.conn, cs.root);
        break :blk xcb.xcb_query_pointer_reply(cs.conn, cookie, null);
    } else null;
    defer if (ptr_reply) |r| std.c.free(r);

    _ = xcb.xcb_grab_server(cs.conn);

    // tiling.removeWindow unconditionally evicts the combined cache entry
    // (geometry + border + size hints), so no separate evictSizeHints call
    // is needed here.
    tiling.removeWindow(win);
    minimize.untrackWindow(win);
    workspaces.removeWindow(win);

    if (was_fullscreen) bar.setBarState(.show_fullscreen);

    if (was_focused) {
        // Resolve the real post-close focus BEFORE retiling: tiling.removeWindow
        // above already dropped `win` from the workspace list, but
        // focus.getFocused() still returns it until clearFocus/setFocus runs.
        // A retile in between would read that stale, no-longer-present ID —
        // focus-driven layouts (monocle) fall back to an arbitrary window in
        // that case — and nothing retiles again once focus actually lands on
        // the right window below.
        focus.clearFocus();
        // Pass the pre-drained reply; no implicit flush inside the grab.
        focusWindowUnderPointer(ptr_reply);
        if (tilingActive()) tiling.retileIfDirty();
    } else if (!was_fullscreen and tilingActive()) {
        if (window_workspace) |ws|
            if (current_ws == ws) tiling.retileIfDirty() else tiling.retileInactiveWorkspace(ws);
    }

    // Post-retile border sweep: tiled-window borders are already current after
    // retileIfDirty (handled by configureWithHints), so only float windows need
    // a sweep here.  updateWorkspaceBorders() would re-send
    // change_window_attributes to every tiled window redundantly.
    updateFloatingWindowBorders();
    bar.redrawInsideGrab();
    markBordersFlushed();

    // No xcb_flush here: the event-loop end-of-batch flush covers this.
    _ = xcb.xcb_ungrab_server(cs.conn);
}

pub fn handleUnmapNotify(event: *const xcb.xcb_unmap_notify_event_t) void {
    if (isValidManagedWindow(event.window)) unmanageWindow(event.window);
}

pub fn handleDestroyNotify(event: *const xcb.xcb_destroy_notify_event_t) void {
    if (isValidManagedWindow(event.window)) unmanageWindow(event.window);
}

/// Post-unmanage focus recovery.
///
/// Uses .pointer_sync so the focus transition may raise a floating window
/// (the stacking order may have changed after the closed window was removed)
/// and arms the confirm/retry machinery for non-compliant clients.
/// This mirrors drainPointerSync's deferred-query semantics — both are
/// resolving a pointer-position query that was fired before the layout changed.
/// Accepts a pre-drained pointer reply (null if the query failed or window
/// was not focused).  The caller owns the memory and must free it; this
/// function only reads.  Accepting the reply instead of the cookie prevents
/// an implicit XCB output-buffer flush (xcb_query_pointer_reply) from
/// occurring inside the server grab in unmanageWindow.
fn focusWindowUnderPointer(ptr_reply: ?*xcb.xcb_query_pointer_reply_t) void {
    const fallback: ?*const fn () void = minimize.focusMasterOrFirst;

    // Scroll layout: windows can be off-screen, so the pointer is often not
    // over any managed window.  Bypass pointer-based focus entirely and use
    // the focus history recorded by tiling.updateWindowFocus instead.
    // takePrevFocusedForScroll is a no-op (returns null) in all other layouts.
    if (tiling.takePrevFocusedForScroll()) |prev| {
        if (tracking.isOnCurrentWorkspaceAndVisible(prev)) {
            focus.setFocus(prev, .tiling_operation);
            return;
        }
    }

    // reply memory is owned by the caller; no std.c.free here.
    // xcb_query_pointer's `child` may be a non-managed toolkit sub-window XID,
    // not the managed toplevel — resolve it via findManagedWindow (which checks
    // the child-window cache first).  child == 0 means the pointer is over no
    // window at all; skip the tree walk on XID 0 and fall through instead.
    if (ptr_reply) |reply| {
        if (reply.*.child != 0) {
            const child = findManagedWindow(core.getState().conn, reply.*.child, tracking.isManaged);
            if (tracking.isOnCurrentWorkspaceAndVisible(child)) {
                focus.setFocus(child, .pointer_sync);
                return;
            }
        }
    }
    focus.focusBestAvailable(.tiling_operation, tracking.isOnCurrentWorkspaceAndVisible, fallback);
}

// Configure request

const GEOMETRY_MASK: u16 =
    xcb.XCB_CONFIG_WINDOW_X | xcb.XCB_CONFIG_WINDOW_Y |
    xcb.XCB_CONFIG_WINDOW_WIDTH | xcb.XCB_CONFIG_WINDOW_HEIGHT |
    xcb.XCB_CONFIG_WINDOW_BORDER_WIDTH;

fn sendConfigureNotify(win: u32, geom: core.WindowGeometry) void {
    const ev = xcb.xcb_configure_notify_event_t{
        .response_type = xcb.XCB_CONFIGURE_NOTIFY,
        .pad0 = 0,
        .sequence = 0,
        .event = win,
        .window = win,
        .above_sibling = xcb.XCB_NONE,
        .x = geom.x,
        .y = geom.y,
        .width = geom.width,
        .height = geom.height,
        .border_width = geom.border_width,
        .override_redirect = 0,
        .pad1 = 0,
    };
    _ = xcb.xcb_send_event(core.getState().conn, 0, win, xcb.XCB_EVENT_MASK_STRUCTURE_NOTIFY, @ptrCast(&ev));
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
///      Handling it directly here avoids falling through to the blocking
///      xcb_get_geometry path, which would cost one server round-trip per
///      ConfigureRequest — a problem for video players and screensavers that
///      poll their size continuously.
///
///   3. True cache miss — one blocking xcb_get_geometry round-trip.  This should
///      only occur for floating windows that have never been retiled and are not
///      fullscreen.  It is a genuine fallback, not a hot path.
fn sendSyntheticConfigureNotify(win: u32) void {
    // Path 1: tiling cache — zero round-trips.
    if (tiling.getWindowGeom(win)) |rect| {
        const border: u16 = if (tiling.getStateOpt()) |s| s.config.border_width else 0;
        sendConfigureNotify(win, .{
            .x = rect.x,
            .y = rect.y,
            .width = rect.width,
            .height = rect.height,
            .border_width = border,
        });
        return;
    }

    // Path 2: fullscreen — geometry is always (0, 0, screen_w, screen_h, bw=0).
    // enterFullscreen writes exactly these values and invalidates the tiling
    // cache entry, so this window will always miss path 1 while fullscreen.
    if (fullscreen.isFullscreen(win)) {
        const screen = core.getState().screen;
        sendConfigureNotify(win, .{
            .x = 0,
            .y = 0,
            .width = @intCast(screen.width_in_pixels),
            .height = @intCast(screen.height_in_pixels),
            .border_width = 0,
        });
        return;
    }

    // Path 3: true cache miss — floating window, no retile yet. One blocking
    // round-trip.  Rare in practice; not a hot path.
    const conn = core.getState().conn;
    const reply = xcb.xcb_get_geometry_reply(
        conn,
        xcb.xcb_get_geometry(conn, win),
        null,
    ) orelse return;
    defer std.c.free(reply);
    sendConfigureNotify(win, .{
        .x = reply.*.x,
        .y = reply.*.y,
        .width = reply.*.width,
        .height = reply.*.height,
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
    const is_fullscreen = fullscreen.isFullscreen(win);
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
                .x = last.x,
                .y = last.y,
                .width = last.width,
                .height = last.height,
                .border_width = getBorderWidth(),
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
        .{ .bit = xcb.XCB_CONFIG_WINDOW_X, .value = utils.toXcbCoord(event.x) },
        .{ .bit = xcb.XCB_CONFIG_WINDOW_Y, .value = utils.toXcbCoord(event.y) },
        .{ .bit = xcb.XCB_CONFIG_WINDOW_WIDTH, .value = event.width },
        .{ .bit = xcb.XCB_CONFIG_WINDOW_HEIGHT, .value = event.height },
        .{ .bit = xcb.XCB_CONFIG_WINDOW_BORDER_WIDTH, .value = event.border_width },
    };
    var values: [5]u32 = undefined;
    var n: usize = 0;
    for (geom_fields) |f| {
        if (mask & f.bit != 0) {
            values[n] = f.value;
            n += 1;
        }
    }
    _ = xcb.xcb_configure_window(core.getState().conn, win, mask, &values);
}

// Focus / crossing events

inline fn suppressSpawnCrossing(root_x: i16, root_y: i16) bool {
    if (focus.getSuppressReason() != .window_spawn) return false;
    // Consume the suppression flag unconditionally: it is a one-shot guard that
    // only applies to the first crossing event after a spawn.  Clearing it
    // only when the cursor had moved would instead suppress all future
    // hover-focus events if the cursor stayed at the exact spawn pixel.
    focus.setSuppressReason(.none);
    return root_x == state.spawn_cursor.x and root_y == state.spawn_cursor.y;
}

/// Attempt to focus `win` via the hover (EnterNotify) path.
///
/// Guards against workspace membership and minimize state before calling
/// focus.setFocus(.mouse_enter).  The .mouse_enter reason is the direct
/// EnterNotify path: lightweight, no raise, no confirm.
inline fn maybeFocusWindow(win: u32) void {
    if (!isOnCurrentWorkspace(win)) {
        debug.info("[MAYBE_FOCUS] 0x{x} -> skipped: not on current workspace", .{win});
        return;
    }
    if (minimize.isMinimized(win)) {
        debug.info("[MAYBE_FOCUS] 0x{x} -> skipped: minimized", .{win});
        return;
    }
    debug.info("[MAYBE_FOCUS] 0x{x} -> setFocus(.mouse_enter)", .{win});
    focus.setFocus(win, .mouse_enter);
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
    const managed = findManagedWindow(core.getState().conn, event.event, tracking.isManaged);
    debug.info("[ENTER] -> resolved managed=0x{x}", .{managed});
    maybeFocusWindow(managed);
}

pub fn handleLeaveNotify(event: *const xcb.xcb_leave_notify_event_t) void {
    focus.setLastEventTime(event.time);
    if (event.event != core.getState().root) return;
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
    const conn = core.getState().conn;

    // WM_NORMAL_HINTS: refresh the size-hint cache so max-size, resize-
    // increment, and aspect-ratio constraints remain accurate for apps that
    // update these hints dynamically after map time (e.g. terminal emulators
    // adjusting their resize-increment grid when the font changes).
    if (event.atom == xcb.XCB_ATOM_WM_NORMAL_HINTS) {
        const cookie = xcb.xcb_get_property(
            conn,
            PROPERTY_NO_DELETE,
            event.window,
            xcb.XCB_ATOM_WM_NORMAL_HINTS,
            xcb.XCB_ATOM_ANY,
            0,
            WM_NORMAL_HINTS_LONG_LENGTH,
        );
        parseSizeHintsIntoCache(event.window, cookie);
        return;
    }

    if (event.atom != state.atoms.wm_protocols and event.atom != xcb.XCB_ATOM_WM_HINTS) return;
    // Re-query and store the updated focus properties in the window-level cache
    // (CacheSlot array).  Without this call the CacheSlot would stay stale
    // until the window is destroyed, and future getCachedProps hits would
    // return an outdated model.
    _ = queryAndCacheProps(conn, event.window);
}

// Size-hint parsing

/// Clamps a u32 to u16 range.
inline fn clampToU16(v: u32) u16 {
    return @intCast(@min(v, std.math.maxInt(u16)));
}

fn parseSizeHintsIntoCache(
    win: u32,
    cookie: xcb.xcb_get_property_cookie_t,
) void {
    const reply = xcb.xcb_get_property_reply(core.getState().conn, cookie, null) orelse return;
    defer std.c.free(reply);
    if (reply.*.format != 32 or reply.*.value_len < 5) return;

    const fields: [*]const u32 = @ptrCast(@alignCast(xcb.xcb_get_property_value(reply)));
    const field_count = reply.*.value_len;
    const flags = fields[0];

    // PMinSize and PBaseSize (min_width/min_height) are intentionally not
    // cached: applyHintsToRect skips min-size clamping for tiling because the
    // layout engine owns all dimensions.  All other ICCCM constraints are
    // forwarded so windows with max-size, resize-increment, or aspect-ratio
    // hints behave correctly.
    const want_max = flags & XSizeHintsFlags.p_max_size != 0;
    const want_inc = flags & XSizeHintsFlags.p_resize_inc != 0;
    const want_asp = flags & XSizeHintsFlags.p_aspect != 0;

    if (!want_max and !want_inc and !want_asp) return;

    var max_width: u16 = 0;
    var max_height: u16 = 0;
    var inc_width: u16 = 0;
    var inc_height: u16 = 0;
    var min_aspect: f32 = 0.0;
    var max_aspect: f32 = 0.0;

    // PMaxSize: fields[7] = max_width, fields[8] = max_height.
    if (want_max and field_count >= 9) {
        max_width = clampToU16(fields[7]);
        max_height = clampToU16(fields[8]);
    }

    // PResizeInc: fields[9] = width_inc, fields[10] = height_inc.
    if (want_inc and field_count >= 11) {
        inc_width = clampToU16(fields[9]);
        inc_height = clampToU16(fields[10]);
    }

    // PAspect: fields[11..14] = min_aspect.x/y, max_aspect.x/y.
    // dwm convention: min_aspect = y/x (lower bound on h/w),
    //                 max_aspect = x/y (upper bound on w/h).
    if (want_asp and field_count >= 15) {
        const min_x = fields[11];
        const min_y = fields[12];
        const max_x = fields[13];
        const max_y = fields[14];
        if (min_x > 0) min_aspect = @as(f32, @floatFromInt(min_y)) / @as(f32, @floatFromInt(min_x));
        if (max_y > 0) max_aspect = @as(f32, @floatFromInt(max_x)) / @as(f32, @floatFromInt(max_y));
    }

    tiling.cacheSizeHints(win, .{
        .max_width = max_width,
        .max_height = max_height,
        .inc_width = inc_width,
        .inc_height = inc_height,
        .min_aspect = min_aspect,
        .max_aspect = max_aspect,
    });
}

// Window borders

/// Returns the DPI-scaled border width.
pub inline fn getBorderWidth() u16 {
    if (tiling.getStateOpt()) |s| return s.config.border_width;
    const cs = core.getState();
    return scale.scaleBorderWidth(
        cs.config.tiling.border_width,
        cs.screen.height_in_pixels,
    );
}

/// Returns the correct border color for `win`.
inline fn borderColor(win: u32) u32 {
    if (fullscreen.isFullscreen(win)) return 0;
    const cfg = &core.getState().config.tiling;
    return if (focus.getFocused() == win) cfg.border_focused else cfg.border_unfocused;
}

/// Apply border width only to `win`.
fn applyBorderWidth(win: u32) void {
    const width = getBorderWidth();
    if (width > 0)
        _ = xcb.xcb_configure_window(core.getState().conn, win, xcb.XCB_CONFIG_WINDOW_BORDER_WIDTH, &[_]u32{width});
}

/// Apply border width and color to `win`.
pub fn applyBorder(win: u32) void {
    applyBorderWidth(win);
    _ = xcb.xcb_change_window_attributes(core.getState().conn, win, xcb.XCB_CW_BORDER_PIXEL, &[_]u32{borderColor(win)});
}

/// Refresh border colors for all windows on the current workspace.
/// Tiled windows are deduped via the tiling CacheMap, so the common
/// steady-state (focused window unchanged) generates zero XCB traffic.
/// Shared iteration loop for workspace border sweeps.
///
/// When `skip_tiled` is true (updateFloatingWindowBorders): skips tiled windows
/// because configureWithHints has already updated their borders via get_border_color.
///
/// When `skip_tiled` is false (updateWorkspaceBorders): applies tiling-aware
/// deduplication via sendBorderColorIfChanged to avoid redundant XCB requests.
fn sweepWorkspaceBorders(comptime skip_tiled: bool) void {
    const cur = tracking.getCurrentWorkspace() orelse return;
    const cur_bit = tracking.workspaceBit(cur);
    const conn = core.getState().conn;
    for (tracking.allWindows()) |entry| {
        const win = entry.win;
        if (entry.mask & cur_bit == 0) continue;
        const color = borderColor(win);
        if (comptime skip_tiled) {
            if (tilingActive() and tiling.isWindowTiled(win)) continue;
        } else {
            // Dedup via the tiling CacheMap: skip the XCB call when color is unchanged.
            if (tiling.sendBorderColorIfChanged(win, color)) continue;
        }
        _ = xcb.xcb_change_window_attributes(conn, win, xcb.XCB_CW_BORDER_PIXEL, &[_]u32{color});
    }
}

pub fn updateWorkspaceBorders() void {
    sweepWorkspaceBorders(false);
}

/// Refresh border colors for only the floating windows on the current workspace.
/// Called after a retile: `configureWithHints` already updated tiled-window
/// borders via the `get_border_color` callback, so re-sending them here would
/// be redundant.  When tiling is absent or disabled, falls back to a full sweep
/// because there are no tiled windows to skip.
pub fn updateFloatingWindowBorders() void {
    sweepWorkspaceBorders(true);
}

/// Mark that the current event batch already swept all workspace border colors
/// inside a server grab, so the event loop does not need to do it again.
pub fn markBordersFlushed() void {
    state.borders_flushed_this_batch = true;
}

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
    if (!state.borders_flushed_this_batch) updateWorkspaceBorders();
    state.borders_flushed_this_batch = false;
}

// ClientMessage — EWMH fullscreen requests from applications

pub fn handleClientMessage(event: *const xcb.xcb_client_message_event_t) void {
    if (event.format != 32) return;

    if (state.atoms.net_wm_state == 0 or event.type != state.atoms.net_wm_state) return;

    const fs_atom = state.atoms.net_wm_state_fullscreen;
    if (fs_atom == 0) return;
    const prop1 = event.data.data32[1];
    const prop2 = event.data.data32[2];
    if (prop1 != fs_atom and prop2 != fs_atom) return;

    const win = event.window;
    if (!isValidManagedWindow(win)) return;

    const action = event.data.data32[0];
    const is_fs = fullscreen.isFullscreen(win);
    const should_enter = switch (action) {
        1 => true, // _NET_WM_STATE_ADD
        0 => false, // _NET_WM_STATE_REMOVE
        2 => !is_fs, // _NET_WM_STATE_TOGGLE
        else => return,
    };
    if (should_enter and !is_fs) {
        fullscreen.enterFullscreen(win, null);
    } else if (!should_enter and is_fs) {
        // Use the window-specific exit path, not toggle(), which acts on
        // whatever the fullscreen module considers "current" rather than
        // on `win`.  This matters on multi-workspace setups where more
        // than one workspace can hold a fullscreen window.
        fullscreen.exitFullscreen(win);
    }
}

/// Push updated border width and colors to every managed window across all
/// workspaces. Called on config reload.
pub fn reloadBorders() void {
    for (tracking.allWindows()) |entry| applyBorder(entry.win);
}
