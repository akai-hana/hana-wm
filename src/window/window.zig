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
const build_options = @import("build_options");
const bar = if (build_options.has_bar) @import("bar") else null;
const tiling = if (build_options.has_tiling) @import("tiling") else null;
const floating = if (build_options.has_floating) @import("floating") else null;
const borders = @import("borders");

// XSizeHints flags (ICCCM §4.1.2.3)
const p_max_size: u32 = 0x20;
const p_resize_inc: u32 = 0x40;
const p_aspect: u32 = 0x80;

// WM_HINTS constants (ICCCM §4.1.2.4)
const wm_hints_input_flag: u32 = 1 << 0;
const wm_hints_flags_field: usize = 0;
const wm_hints_input_field: usize = 1;
const wm_hints_long_length: u32 = 9; // flags + 8 fields
const wm_normal_hints_long_length: u32 = 18; // flags + 17 fields (up to base_size/win_gravity)

const max_property_length = constants.property_max_length;
const property_no_delete = constants.property_no_delete;

const max_window_tree_depth = constants.max_window_tree_depth;

// Spawn queue: pending (workspace, pid) assignments for newly-mapped windows,
// consumed by resolveTargetWorkspace. Capped at spawn_queue_cap; overflow logs
// and drops the entry rather than growing unbounded.

const SpawnEntry = struct {
    workspace: u8,
    /// _NET_WM_PID of the grandchild; 0 for daemon-mode terminals.
    pid: u32,
};

// Bounds pending spawns awaiting their first map, not the tiled-window pool.
const spawn_queue_cap: usize = 64;

// All mutable window-module state is grouped into a single State struct
// (mirroring the pattern focus.zig uses) so init()/deinit() each reset
// everything in one assignment, and a deinit()+init() cycle can't leave a
// stale field behind. Still exactly one context per process, this is for
// reset discipline, not multi-context support.
const State = struct {
    /// Module allocator, set in init(). Null before the first init() call.
    alloc: ?std.mem.Allocator = null,

    spawn_queue: std.ArrayListUnmanaged(SpawnEntry) = .empty,

    spawn_cursor: struct { x: i16 = 0, y: i16 = 0 } = .{},

    // Workspace-rule fast-lookup map: WM_CLASS name -> target workspace,
    // rebuilt from config.workspaces.rules at init and on every reload.
    // Keys borrow slices from the config, valid until the next rebuild.
    rules_map: std.StringHashMapUnmanaged(u8) = .{},

    // ICCCM focus-property cache (see the section comment below).
    cache_slots: utils.BoundedList(CacheSlot, max_window_cache) = .{},
    cache_ready: bool = false,

    // Child XID -> managed toplevel XID (see "Child window resolution").
    child_cache: utils.BoundedList(ChildEntry, child_cache_cap) = .{},

    // True when a grab-flush path already swept floating borders this batch,
    // so the event loop can skip the redundant second sweep. Reset at the
    // end of each batch.
    borders_flushed_this_batch: bool = false,
};

var state: ?State = null;

pub inline fn getState() *State {
    if (state) |*s| return s;
    @panic("window: getState() called before init()");
}

pub inline fn getStateOpt() ?*State {
    return if (state) |*s| s else null;
}

// Geometry cache: last-known window geometry for workspace-switch and
// minimize/restore. Owned by tiling.zig, the single source of truth for both
// tiled and floating windows.

/// Save `rect` as the last-known geometry for `win`. Delegates to tiling,
/// which owns the one geometry cache shared by tiled and floating windows alike.
pub fn saveWindowGeom(win: u32, rect: utils.Rect) void {
    if (build_options.has_tiling) tiling.saveWindowGeom(win, rect);
}

/// Screen-space position of a window's top-left corner.
/// X11 coordinates are signed (windows may be partially off-screen or on a
/// monitor to the left/above the primary), so both fields use i16 to match
/// the XCB wire type for X/Y configure values.
const Pos = struct { x: i16, y: i16 };

pub fn floatDefaultPos() Pos {
    const screen = core.getState().screen;
    return .{
        .x = @intCast(@min(screen.width_in_pixels / 4, std.math.maxInt(i16))),
        .y = @intCast(@min(screen.height_in_pixels / 4, std.math.maxInt(i16))),
    };
}

/// Restore `win` to its saved geometry, or move it to the float default
/// position when no geometry has been saved. Only X/Y are updated in the
/// fallback case; the window keeps whatever size the server already knows.
///
/// This is the shared implementation of the "restore floating window"
/// pattern that appears in minimize, workspaces, and fullscreen modules.
pub fn restoreFloatGeom(win: u32) void {
    const conn = core.getState().conn;
    if (if (build_options.has_tiling) tiling.getWindowGeom(win) else null) |rect| {
        utils.configureWindow(conn, win, rect);
    } else {
        moveFloatToDefaultPos(win);
    }
}

/// Moves, resizes, and sets border_width atomically,
/// preventing a one-frame flash on fullscreen enter/exit or workspace switch.
pub fn configureWindowGeom(conn: core.Connection, win: u32, geom: utils.Rect) void {
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

/// Flush border geometry for every floating window while the server grab is
/// held, then clear the pending-flush flag so the next loop tick doesn't
/// re-sweep. The bar is NOT redrawn here: redrawInsideGrab performed a full
/// bar render (captureStateIntoSlot + batchFetchWindowInfosInto + Pango draw)
/// for every window that mapped, causing O(N²) property queries and Pango
/// renders inside server grabs during rapid window opening. The bar's
/// post_batch hook (updateIfDirty) handles the redraw after the entire event
/// batch is processed. Callers must be inside a grab.
pub fn flushGrabBorders() void {
    updateFloatingWindowBorders();
    markBordersFlushed();
}

pub fn markBordersFlushed() void {
    state.?.borders_flushed_this_batch = true;
}

/// Shared by restoreFloatGeom and fullscreen.restoreFloatingWindows.
pub fn moveFloatToDefaultPos(win: u32) void {
    const conn = core.getState().conn;
    const pos = floatDefaultPos();
    _ = xcb.xcb_configure_window(conn, win, xcb.XCB_CONFIG_WINDOW_X | xcb.XCB_CONFIG_WINDOW_Y, &[_]u32{ utils.toXcbCoord(pos.x), utils.toXcbCoord(pos.y) });
}

/// Returns null if the window does not exist or is not yet mapped.
pub fn getGeometry(conn: core.Connection, win: u32) ?utils.Rect {
    const reply = xcb.xcb_get_geometry_reply(conn, xcb.xcb_get_geometry(conn, win), null) orelse return null;
    defer std.c.free(reply);
    return utils.Rect.fromXcb(reply);
}

// ICCCM focus property cache
//
// Keyed by window ID; populated at map time via `populateFocusCacheFromCookies`,
// invalidated on WM_PROTOCOLS/WM_HINTS PropertyNotify and on destruction.
// Caches only half of the ICCCM focus-delivery split:
//   accepts_input: WM_HINTS.input, mirrors dwm's `c->neverfocus`.
//   wm_delete     : WM_DELETE_WINDOW support, for the close-window path.
//
// WM_TAKE_FOCUS is deliberately NOT cached (see getInputModel below): caching
// it could miss the invalidating PropertyNotify if WM_PROTOCOLS was set before
// our event mask was in place, wedging a window at a stale verdict for life. A
// value that's never cached can't go stale.

/// The four ICCCM focus delivery modes (§4.1.7), determined by the combination of
/// WM_HINTS.input and WM_TAKE_FOCUS presence in WM_PROTOCOLS.
/// pub: focus.setFocusWithModel takes a pre-resolved model so grab-held
/// callers can hoist the live WM_PROTOCOLS query before the server grab.
pub const InputModel = enum {
    no_input, // input=False, no WM_TAKE_FOCUS: window doesn't want focus
    passive, // input=True,  no WM_TAKE_FOCUS: set focus via `XSetInputFocus`
    locally_active, // input=True,  WM_TAKE_FOCUS:    set focus + send protocol
    globally_active, // input=False, WM_TAKE_FOCUS:    only send protocol
};

/// Per-window properties cached from WM_HINTS and WM_PROTOCOLS.
///
/// `accepts_input` and `wm_delete` are cached because both are cheap to keep
/// in sync via PropertyNotify and rarely change post-map. WM_TAKE_FOCUS is
/// intentionally excluded, see the section comment above and getInputModel().
const CachedProps = struct {
    accepts_input: bool,
    wm_delete: bool,
};

// At realistic window counts (<=100 typical, <=300 extreme) a linear scan over
// u32 IDs in a flat array is cache-local and allocation-free. Windows beyond
// max_window_cache still work; they just fall through to the live X11 path.
const max_window_cache: usize = 512;

const CacheSlot = struct {
    id: u32,
    props: CachedProps,
};

/// Called from handleMapRequest, which fires both cookies synchronously.
/// MapRequest is a one-time event per window, not a hot path worth pipelining.
///
/// The WM_PROTOCOLS reply is still scanned for WM_TAKE_FOCUS here but that
/// half is discarded rather than cached, see getInputModel() for why.
fn populateFocusCacheFromCookies(
    conn: core.Connection,
    win: u32,
    protocols_cookie: xcb.xcb_get_property_cookie_t,
    hints_cookie: xcb.xcb_get_property_cookie_t,
) void {
    const take_focus_atom = utils.getAtomCached("WM_TAKE_FOCUS") catch {
        xcb.xcb_discard_reply(conn, protocols_cookie.sequence);
        xcb.xcb_discard_reply(conn, hints_cookie.sequence);
        return;
    };
    const wm_delete_atom = utils.getAtomCached("WM_DELETE_WINDOW") catch {
        xcb.xcb_discard_reply(conn, protocols_cookie.sequence);
        xcb.xcb_discard_reply(conn, hints_cookie.sequence);
        return;
    };

    // Scan WM_PROTOCOLS once for both atoms (no second round-trip); only
    // .wm_delete gets cached below.
    const protocols_result = protocols: {
        const r = xcb.xcb_get_property_reply(conn, protocols_cookie, null) orelse break :protocols WMProtocolsProps{};
        defer std.c.free(r);
        break :protocols protocolPropsFromReply(r, take_focus_atom, wm_delete_atom);
    };

    putCachedProps(win, .{
        .accepts_input = extractWMHintsInput(conn, hints_cookie),
        .wm_delete = protocols_result.wm_delete,
    });
}

/// Returns null when the WM_PROTOCOLS atom is not yet interned.
fn fireWMProtocolsQuery(
    conn: core.Connection,
    win: u32,
) ?xcb.xcb_get_property_cookie_t {
    const protocols_atom = utils.getAtomCached("WM_PROTOCOLS") catch return null;
    return xcb.xcb_get_property(conn, property_no_delete, win, protocols_atom, xcb.XCB_ATOM_ATOM, 0, max_property_length);
}

/// Drains the WM_HINTS cookie and returns the ICCCM input flag. Returns true
/// when absent, when the flag is unset, or when the field is explicitly True,
/// matching ICCCM §4.1.2.4 defaults.
inline fn extractWMHintsInput(
    conn: core.Connection,
    hints_cookie: xcb.xcb_get_property_cookie_t,
) bool {
    const r = xcb.xcb_get_property_reply(conn, hints_cookie, null) orelse return true;
    defer std.c.free(r);
    if (r.*.format != 32 or r.*.value_len < 1) return true;
    const hints = u32Values(r);
    const input_flag_set = (hints[wm_hints_flags_field] & wm_hints_input_flag) != 0;
    const has_input_field = r.*.value_len > @as(u32, wm_hints_input_field);
    if (!input_flag_set or !has_input_field) return true;
    return hints[wm_hints_input_field] != 0;
}

/// Silently drops the entry when the cache is full;
/// the live-query fallback is always correct.
fn putCachedProps(win: u32, props: CachedProps) void {
    if (!state.?.cache_ready) return;
    if (state.?.cache_slots.indexOfById(win)) |i| {
        state.?.cache_slots.items[i].props = props;
        return;
    }
    if (!state.?.cache_slots.append(.{ .id = win, .props = props })) {
        debug.warn("Focus cache full, falling back to live queries", .{});
    }
}

/// Returns cached props if available, otherwise performs a live query, caches
/// the result, and returns it. Used by cache-miss paths so the populate logic
/// lives in exactly one place.
fn getOrQueryCachedProps(conn: core.Connection, win: u32) CachedProps {
    if (state.?.cache_ready) {
        if (state.?.cache_slots.indexOfById(win)) |i| {
            return state.?.cache_slots.items[i].props;
        }
    }
    const props = CachedProps{
        .accepts_input = queryWMHintsAcceptsInput(conn, win),
        .wm_delete = queryWMProtocolsProps(conn, win).wm_delete,
    };
    putCachedProps(win, props);
    return props;
}

/// Resolves the ICCCM §4.1.7 focus-delivery model for `win`: accepts_input
/// comes from the cache above (live query on a miss); supports_take_focus is
/// always queried live, see the "ICCCM focus property cache" note for why.
/// Focus changes are human-triggered and infrequent, so the extra round trip
/// is not perceptible.
pub fn getInputModel(conn: core.Connection, win: u32) InputModel {
    const accepts_input = getOrQueryCachedProps(conn, win).accepts_input;

    const supports_take_focus = queryWMProtocolsProps(conn, win).take_focus;

    return inputModelFrom(supports_take_focus, accepts_input);
}

/// Falls back to a live query only on a genuine cache miss (extremely rare).
pub fn supportsWMDeleteCached(conn: core.Connection, win: u32) bool {
    return getOrQueryCachedProps(conn, win).wm_delete;
}

/// Used by focus.zig to overlap the round-trip latency of the WM_TAKE_FOCUS
/// check with local focus-transition bookkeeping.
/// Returns null when the WM_PROTOCOLS atom is not yet interned.
pub fn fireTakeFocusCookie(
    conn: core.Connection,
    win: u32,
) ?xcb.xcb_get_property_cookie_t {
    return fireWMProtocolsQuery(conn, win);
}

/// Called by both `sendWMTakeFocusWithCookie` (pre-fired cookie path) and
/// `sendWMTakeFocus` (live round-trip path) to keep the send logic in one place.
fn dispatchTakeFocusMessage(
    conn: core.Connection,
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

/// Shared body of sendWMTakeFocus and sendWMTakeFocusWithCookie: resolves the
/// WM_PROTOCOLS and WM_TAKE_FOCUS atoms, drains the WM_PROTOCOLS reply (from the
/// pre-fired `cookie` when present, else a fresh round-trip), and dispatches the
/// WM_TAKE_FOCUS ClientMessage iff `win` advertises the protocol (ICCCM §4.1.7).
/// When the cookie cannot be consumed (atom resolution fails), it is discarded
/// so the XCB queue drains.
fn dispatchTakeFocus(
    conn: core.Connection,
    win: u32,
    time: u32,
    cookie: ?xcb.xcb_get_property_cookie_t,
) void {
    const protocols_atom = utils.getAtomCached("WM_PROTOCOLS") catch {
        if (cookie) |c| xcb.xcb_discard_reply(conn, c.sequence);
        return;
    };
    const take_focus_atom = utils.getAtomCached("WM_TAKE_FOCUS") catch {
        if (cookie) |c| xcb.xcb_discard_reply(conn, c.sequence);
        return;
    };

    const proto_cookie = cookie orelse (fireWMProtocolsQuery(conn, win) orelse return);
    const proto_reply = xcb.xcb_get_property_reply(conn, proto_cookie, null) orelse return;
    defer std.c.free(proto_reply);
    if (proto_reply.*.format != 32 or proto_reply.*.value_len == 0) return;
    dispatchTakeFocusMessage(conn, win, time, protocols_atom, take_focus_atom, u32Values(proto_reply)[0..@intCast(proto_reply.*.value_len)]);
}

/// The X server has been processing the property request since before
/// commitFocusTransition ran its bookkeeping, so by the time this is called
/// the reply is typically already in the XCB receive buffer.
pub fn sendWMTakeFocusWithCookie(
    conn: core.Connection,
    win: u32,
    time: u32,
    cookie: xcb.xcb_get_property_cookie_t,
) void {
    dispatchTakeFocus(conn, win, time, cookie);
}

/// Sends a WM_TAKE_FOCUS client message (ICCCM §4.1.7) iff `win` advertises
/// WM_TAKE_FOCUS in WM_PROTOCOLS. Checked live on every call, matching dwm's
/// sendevent(), this one flag is never cached (see the "ICCCM focus property
/// cache" note: Electron/GTK apps can set WM_PROTOCOLS before we subscribe to
/// PropertyNotify, permanently staling a cached value).
///
/// Hot paths (setFocus) use fireTakeFocusCookie / sendWMTakeFocusWithCookie to
/// pipeline the round trip; this is the fallback for callers that don't
/// pre-fire the cookie (drainPendingConfirm).
pub fn sendWMTakeFocus(conn: core.Connection, win: u32, time: u32) void {
    dispatchTakeFocus(conn, win, time, null);
}

// Private ICCCM helpers

/// See ICCCM §4.1.7: the matrix of (accepts_input x supports_take_focus)
/// determines which focus delivery mechanism the WM must use.
inline fn inputModelFrom(supports_take_focus: bool, accepts_input: bool) InputModel {
    return if (supports_take_focus)
        (if (accepts_input) .locally_active else .globally_active)
    else
        (if (accepts_input) .passive else .no_input);
}

const WMProtocolsProps = struct { take_focus: bool = false, wm_delete: bool = false };

/// Shared by queryWMProtocolsProps (live query) and populateFocusCacheFromCookies
/// (cookie path).
inline fn scanProtocolAtoms(protocol_atoms: []const u32, take_focus_atom: u32, wm_delete_atom: u32) WMProtocolsProps {
    var props: WMProtocolsProps = .{};
    for (protocol_atoms) |atom| {
        if (atom == take_focus_atom) props.take_focus = true;
        if (atom == wm_delete_atom) props.wm_delete = true;
        if (props.take_focus and props.wm_delete) break;
    }
    return props;
}

/// Alignment-cast to the u32 value array of a format-32 get_property reply.
inline fn u32Values(r: *xcb.xcb_get_property_reply_t) [*]const u32 {
    return @ptrCast(@alignCast(xcb.xcb_get_property_value(r)));
}

/// Shared by queryWMProtocolsProps (live query) and populateFocusCacheFromCookies
/// (cookie path); the caller owns `reply`'s memory.
inline fn protocolPropsFromReply(
    reply: *xcb.xcb_get_property_reply_t,
    take_focus_atom: u32,
    wm_delete_atom: u32,
) WMProtocolsProps {
    if (reply.*.format != 32 or reply.*.value_len == 0) return .{};
    return scanProtocolAtoms(u32Values(reply)[0..@intCast(reply.*.value_len)], take_focus_atom, wm_delete_atom);
}

fn queryWMProtocolsProps(conn: core.Connection, win: u32) WMProtocolsProps {
    const protocols_atom = utils.getAtomCached("WM_PROTOCOLS") catch return .{};
    const take_focus_atom = utils.getAtomCached("WM_TAKE_FOCUS") catch return .{};
    const wm_delete_atom = utils.getAtomCached("WM_DELETE_WINDOW") catch return .{};

    const reply = xcb.xcb_get_property_reply(
        conn,
        xcb.xcb_get_property(conn, property_no_delete, win, protocols_atom, xcb.XCB_ATOM_ATOM, 0, max_property_length),
        null,
    ) orelse return .{};
    defer std.c.free(reply);
    return protocolPropsFromReply(reply, take_focus_atom, wm_delete_atom);
}

/// Returns true when absent (assume True per ICCCM) or explicitly True.
fn queryWMHintsAcceptsInput(conn: core.Connection, win: u32) bool {
    return extractWMHintsInput(conn, xcb.xcb_get_property(
        conn,
        property_no_delete,
        win,
        xcb.XCB_ATOM_WM_HINTS,
        xcb.XCB_ATOM_WM_HINTS,
        0,
        wm_hints_long_length,
    ));
}

// Child window resolution
//
// Electron/Qt/GTK toolkits render into child windows beneath their managed
// toplevel, so ButtonPress/EnterNotify often land on a child, not the window
// we manage. findManagedWindow walks the X11 tree upward (each step a blocking
// round-trip) to find the managed ancestor; state.child_cache maps child XID
// -> managed toplevel XID so repeat hovers cost zero XCB calls. Entries are
// evicted when their toplevel is unmanaged (evictChildCache). A fixed flat
// array is enough: Electron nests at most 3-5 children per app.

const child_cache_cap: usize = 64;

const ChildEntry = struct { id: u32, managed: u32 };

/// Record that `child` resolves to `managed` so future tree walks are skipped.
fn cacheChildWindow(child: u32, managed: u32) void {
    if (child == managed) return; // direct hit, not a child, nothing to cache
    if (state.?.child_cache.indexOfById(child)) |i| {
        state.?.child_cache.items[i].managed = managed; // update in place
        return;
    }
    // At cap, append silently drops, the tree walk fallback is always correct.
    _ = state.?.child_cache.append(.{ .id = child, .managed = managed });
}

/// Called from unmanageWindow so stale child entries don't linger.
fn evictChildCache(managed_win: u32) void {
    var i: usize = 0;
    while (i < state.?.child_cache.len) {
        if (state.?.child_cache.items[i].managed == managed_win) {
            state.?.child_cache.swapRemove(i);
        } else {
            i += 1;
        }
    }
}

/// Walks up the X11 window tree from `win` to find the managed toplevel.
///
/// Fast paths: direct managed window (most common), then the child-window
/// cache (common for Electron/Qt after the first hover, zero XCB calls).
/// Slow path: one blocking xcb_query_tree round-trip per level (2-3 for
/// Electron), only on the first hover over a new child window.
pub fn findManagedWindow(conn: core.Connection, win: u32, is_managed: *const fn (u32) bool) u32 {
    if (is_managed(win)) return win;

    // Cache hit; validate the cached toplevel is still managed (it may have
    // been unmanaged since the entry was written), else fall through.
    if (state.?.child_cache.indexOfById(win)) |i| {
        const managed = state.?.child_cache.items[i].managed;
        if (is_managed(managed)) return managed;
    }

    var current = win;
    for (0..max_window_tree_depth) |_| {
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

/// Keys are borrowed slices into the config's allocations, valid until the
/// next rebuild. If a class name appears in multiple rules, the first rule
/// wins, matching a plain linear scan through the rule list.
pub fn buildRulesMap() void {
    const alloc = state.?.alloc orelse return;
    state.?.rules_map.clearRetainingCapacity();
    for (core.getState().config.workspaces.rules.items) |rule| {
        // putNoClobber: first occurrence wins. On OOM the entry is silently
        // dropped, the window is routed to the current workspace instead.
        state.?.rules_map.putNoClobber(alloc, rule.class_name, rule.workspace) catch {};
    }
}

pub fn init(alloc: std.mem.Allocator) !void {
    // Reset every field to its zero value so that a deinit() + init() cycle
    // (session restart, test harness) starts from a clean slate rather than
    // carrying over whatever the previous cycle left behind.
    state = .{};
    state.?.alloc = alloc;
    tracking.init(alloc);
    focus.init();
    // tiling must precede workspaces: workspaces.init() calls tiling.getState().
    if (build_options.has_tiling) tiling.init();
    fullscreen.init();
    try workspaces.init();
    minimize.init();
    // Pre-allocate spawn queue capacity for the common case (a handful of
    // concurrent spawns). Failure is non-fatal; the list grows on demand.
    state.?.spawn_queue.ensureTotalCapacity(alloc, 16) catch |err| {
        std.log.warn("window: spawn queue pre-allocation failed ({s}); will grow on demand", .{@errorName(err)});
    };
    state.?.cache_slots.clear();
    state.?.cache_ready = true;
    buildRulesMap();
}

pub fn deinit() void {
    // Teardown order: heap-backed state freed before the struct reset below,
    // then InputModelCache torn down before focus and tracking (they may sweep
    // managed windows and must not encounter a partially-valid cache), then
    // the remaining subsystems in reverse-init order.
    if (build_options.has_tiling) tiling.deinit();
    fullscreen.deinit();
    workspaces.deinit();
    minimize.deinit();
    // Free heap-backed state before the reset below wipes the struct: a
    // bare `state = .{}` would leak the spawn queue's and rules map's
    // backing memory rather than freeing it.
    if (state.?.alloc) |a| {
        state.?.spawn_queue.deinit(a);
        state.?.rules_map.deinit(a);
    }
    // InputModel cache must be torn down before focus and tracking, mirroring
    // the init order where the cache clear + ready=true follows focus.init().
    // focus.deinit() and tracking.deinit() may sweep managed windows and
    // must not encounter a partially-valid cache.
    state.?.cache_slots.clear();
    state.?.cache_ready = false;
    focus.deinit();
    tracking.deinit();
    // Reset every remaining field (spawn_cursor, child_cache,
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

/// True for the null window, the root, or the bar, never valid focus/manage targets.
pub inline fn isInvalidWindow(win: u32) bool {
    return win == 0 or win == core.getState().root or (build_options.has_bar and bar.isBarWindow(win));
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

inline fn clampToValidWorkspace(target: u8, fallback: core.WorkspaceId) core.WorkspaceId {
    return if (target < tracking.getWorkspaceCount()) core.WorkspaceId.fromIndex(target) else fallback;
}

/// Resolves a pre-fired WM_CLASS property cookie against workspace rules.
/// Parses the WM_CLASS reply inline (no allocation), then does two O(1) hash
/// lookups in state.rules_map (class, then instance). The map is built at
/// init() and after every config reload, so no linear rule scan runs at
/// spawn time.
fn findWorkspaceRuleByClass(cookie: xcb.xcb_get_property_cookie_t) ?u8 {
    const reply = xcb.xcb_get_property_reply(core.getState().conn, cookie, null) orelse return null;
    defer std.c.free(reply);
    if (reply.*.format != 8 or reply.*.value_len == 0) return null;

    const raw: [*]const u8 = @ptrCast(xcb.xcb_get_property_value(reply));
    const data = raw[0..reply.*.value_len];

    // WM_CLASS is two consecutive null-terminated strings: "instance\0class\0".
    // Trim trailing nulls per component, not on the whole buffer: trimming the
    // whole buffer first turns "instance\0\0" (empty class) into "instance"
    // with no separator, silently skipping the instance lookup.
    const sep = std.mem.indexOfScalar(u8, data, 0) orelse return null;
    const instance = data[0..sep];

    const class_start = sep + 1;
    const class_raw = if (class_start < data.len) data[class_start..] else "";
    const class_end = std.mem.indexOfScalar(u8, class_raw, 0) orelse class_raw.len;
    const class = class_raw[0..class_end];

    // O(1) hash lookups: class first (when non-empty), then instance.
    if (class.len > 0) {
        if (state.?.rules_map.get(class)) |ws| return ws;
    }
    if (instance.len > 0) {
        if (state.?.rules_map.get(instance)) |ws| return ws;
    }
    return null;
}

/// Tries an exact PID match first, then falls back to the sole-pending-entry
/// heuristic. The caller only fires `c_net_wm_pid` when the queue is non-empty,
/// so no empty-queue case is handled here.
fn findSpawnQueueWorkspace(
    c_net_wm_pid: xcb.xcb_get_property_cookie_t,
) ?u8 {
    const win_pid: u32 = pid: {
        const pid_reply = xcb.xcb_get_property_reply(core.getState().conn, c_net_wm_pid, null) orelse break :pid 0;
        defer std.c.free(pid_reply);
        if (pid_reply.*.format != 32 or pid_reply.*.value_len < 1) break :pid 0;
        break :pid u32Values(pid_reply)[0];
    };

    // Exact PID match only. Daemon-mode entries (pid == 0) are intentionally
    // NOT matched against windows without _NET_WM_PID (win_pid == 0): that
    // would conflate "terminal that will fork a grandchild" with "app that
    // simply doesn't set _NET_WM_PID", letting an unrelated app silently
    // consume the daemon entry and route to the wrong workspace.
    for (state.?.spawn_queue.items, 0..) |e, i| {
        if (win_pid != 0 and e.pid == win_pid) {
            _ = state.?.spawn_queue.swapRemove(i);
            return e.workspace;
        }
    }

    // Sole-entry fallback: with exactly one pending entry there's no ambiguity
    // (the app was launched via `sh -c "cmd"` and reports a grandchild PID).
    // With multiple entries we can't know which one this window belongs to;
    // consuming items[0] would mis-route it to the oldest pending spawn's
    // workspace, so return null and let handleMapRequest fall back to current_ws.
    if (state.?.spawn_queue.items.len != 1) {
        std.log.debug(
            "spawn: no exact PID match for pid={d}, {d} entries pending; ambiguous, routing to current workspace",
            .{ win_pid, state.?.spawn_queue.items.len },
        );
        return null;
    }
    std.log.debug(
        "spawn: no exact PID match for pid={d}, sole entry ws={d}, using heuristic",
        .{ win_pid, state.?.spawn_queue.items[0].workspace },
    );
    const ws = state.?.spawn_queue.items[0].workspace;
    _ = state.?.spawn_queue.swapRemove(0); // order has no semantic meaning
    return ws;
}

/// Queries are fire-then-drain, not pipelined (see handleMapRequest below for
/// why), and WM_CLASS / _NET_WM_PID are only fired when actually needed, so
/// there's nothing to discard on paths that skip them.
fn resolveTargetWorkspace(win: u32, current_ws: core.WorkspaceId) core.WorkspaceId {
    const cs = core.getState();

    // Pipeline: fire both property requests before draining either reply.
    // The server processes them in parallel while we check conditions below.
    var c_wm_class: ?xcb.xcb_get_property_cookie_t = null;
    if (cs.config.workspaces.rules.items.len > 0 and utils.getAtomOrZero("WM_CLASS") != 0) {
        c_wm_class = xcb.xcb_get_property(cs.conn, property_no_delete, win, utils.getAtomOrZero("WM_CLASS"), xcb.XCB_ATOM_STRING, 0, constants.property_max_length);
    }

    var c_net_wm_pid: ?xcb.xcb_get_property_cookie_t = null;
    if (state.?.spawn_queue.items.len > 0) {
        c_net_wm_pid = xcb.xcb_get_property(cs.conn, property_no_delete, win, utils.getAtomOrZero("_NET_WM_PID"), xcb.XCB_ATOM_CARDINAL, 0, 1);
    }

    // Drain replies: WM_CLASS first, then _NET_WM_PID.
    if (c_wm_class) |cookie| {
        if (findWorkspaceRuleByClass(cookie)) |target|
            return clampToValidWorkspace(target, current_ws);
    }

    if (c_net_wm_pid) |cookie| {
        if (findSpawnQueueWorkspace(cookie)) |spawn_ws|
            return clampToValidWorkspace(spawn_ws, current_ws);
    }

    return current_ws;
}

pub fn registerSpawn(workspace: core.WorkspaceId, pid: u32) void {
    const alloc = state.?.alloc orelse return;
    if (state.?.spawn_queue.items.len >= spawn_queue_cap) {
        debug.warn("registerSpawn: spawn queue full ({d} entries); entry dropped", .{spawn_queue_cap});
        return;
    }
    state.?.spawn_queue.append(alloc, .{ .workspace = workspace.index, .pid = pid }) catch |err| {
        debug.warn("registerSpawn: failed to queue spawn entry: {}", .{err});
    };
}

// Pointer snapshot for spawn-crossing suppression.
//
// mapWindowToScreen fires+drains xcb_query_pointer synchronously (MapRequest
// is once-per-window, so the round trip isn't perceptible). Don't reach for
// prefetch/caching here, that's for genuinely hot paths like dragging and
// retiling.

/// Record the cursor position from a drained pointer reply for later
/// spawn-crossing suppression checks. The caller owns the reply memory;
/// this function only reads from it.
///
/// When `ptr_reply` is null, the suppression flag is cleared rather than
/// leaving `state.spawn_cursor` at its previous value (which could be {0,0}
/// on startup and cause false suppression for windows at the screen origin).
fn snapshotSpawnCursorFromReply(ptr_reply: ?*xcb.xcb_query_pointer_reply_t, suppress_reason: core.FocusSuppressReason) void {
    if (suppress_reason != .window_spawn) return;
    const ptr = ptr_reply orelse {
        // No valid cursor position: disable suppression so the stale
        // state.spawn_cursor cannot block legitimate focus events.
        focus.setSuppressReason(.none);
        return;
    };
    state.?.spawn_cursor.x = ptr.*.root_x;
    state.?.spawn_cursor.y = ptr.*.root_y;
}

/// Map a newly adopted window that is on the current workspace.
///
/// The server grab is kept as narrow as possible:
///
///   Before the grab: no reply needed, so the compositor keeps compositing:
///   - tiling.addWindow + retileCurrentWorkspace: configure_window for every
///     managed window. Can take 5-20 ms on weak hardware; running it outside
///     the grab avoids a compositor stall on every spawn.
///   - xcb_query_pointer, fired and drained synchronously.
///
///   Inside the grab (atomic, compositor-locked):
///   - applyBorderWidth + xcb_map_window + setFocus + border sweep + bar --
///     must land in a single frame to avoid a flash of an unfocused or
///     unbordered window.
fn mapWindowToScreen(win: u32) void {
    const cs = core.getState();
    const conn = cs.conn;

    const ptr_reply = xcb.xcb_query_pointer_reply(conn, xcb.xcb_query_pointer(conn, cs.root), null);
    defer if (ptr_reply) |r| std.c.free(r);

    // -- Outside the grab: expensive layout work -----------------------------
    //
    // The configure_window calls from retile are pure fire-and-forget output;
    // the compositor may composite an intermediate frame (a window briefly at
    // its old position), but the grab below immediately issues the final
    // geometry atomically before the first MapNotify, so no incorrect frame is
    // ever displayed.
    //
    // focus.setFocus(win, ...) hasn't run yet, so focus.getFocused() still
    // reports the previously-focused window. Pass `win` as the pending focus
    // target so focus-driven layouts (e.g. monocle) treat the new window as
    // focused immediately instead of lagging by one retile.
    if (tilingActive()) {
        if (build_options.has_tiling) tiling.addWindow(win);
        if (build_options.has_tiling) tiling.retileCurrentWorkspaceWithOpts(.{ .focus_override = win });
    } else {
        if (fullscreen.hasAnyFullscreen()) {
            // Leave it offscreen, restoreFloatGeom would immediately move it
            // back to a visible position, undoing the push above.
            utils.pushWindowOffscreen(conn, win);
        } else {
            restoreFloatGeom(win);
        }
    }

    // -- Inside the grab: atomic map, focus, borders -------------------------
    //
    // Resolve the input model BEFORE the grab: getInputModel's blocking
    // WM_PROTOCOLS reply wait would implicitly flush the queued retile batch
    // to the compositor mid-grab (same hazard the pre-drained pointer query
    // avoids). setFocusWithModel re-applies setFocus's own short-circuits.
    const spawn_input_model = getInputModel(conn, win);
    utils.grabServer(conn);

    applyBorderWidth(win);
    _ = xcb.xcb_map_window(conn, win);

    focus.setFocusWithModel(win, .window_spawn, spawn_input_model);
    // Re-check the suppress reason *after* setFocus: setFocus is what arms
    // .window_spawn (via suppressionFor), so reading it before, when it's
    // almost always .none, would skip this snapshot on virtually every spawn.
    snapshotSpawnCursorFromReply(ptr_reply, focus.getSuppressReason());

    // Tiled-window borders were already updated by configureWithHints during
    // the retile, so only floating windows need sweeping here.
    flushGrabBorders();

    // No xcb_flush here: the event-loop end-of-batch flush covers this.
    utils.ungrabServer(conn);
}

fn registerWindowOffscreen(win: u32) void {
    if (tilingActive()) if (build_options.has_tiling) tiling.addWindow(win);

    applyBorder(win);
    focus.initWindowGrabs(win);

    // No xcb_flush here: the event-loop end-of-batch flush covers this.
    if (build_options.has_bar) bar.scheduleRedraw();
}

/// Handles a MapRequest by querying the properties it needs one at a time:
/// fire the request, then immediately drain the reply, rather than batching
/// every cookie up front the way a hot path (dragging, retiling) would.
/// MapRequest happens once per window creation, so the extra round trips
/// aren't perceptible, and querying only once the window is confirmed to
/// belong on some workspace means there's nothing to discard on the
/// early-return error path below.
pub fn handleMapRequest(event: *const xcb.xcb_map_request_event_t) void {
    const win = event.window;
    const conn = core.getState().conn;

    // Double-manage guard: a window can send multiple MapRequest events (e.g.
    // an unmap+remap race while the first is still processing); without it,
    // tiling.addWindow and the property queries below would fire twice.
    if (tracking.isManaged(win)) return;

    // getCurrentWorkspace() returns ?u8; the value is already bounded to [0,255]
    // by the u8 return type, so no further clamping is needed.
    const current_ws = core.WorkspaceId.fromIndex(tracking.getCurrentWorkspace() orelse 0);

    _ = xcb.xcb_change_window_attributes(
        conn,
        win,
        xcb.XCB_CW_EVENT_MASK,
        &[_]u32{constants.EventMasks.managed_window},
    );

    const target_ws = resolveTargetWorkspace(win, current_ws);
    const on_current = target_ws.eql(current_ws);

    workspaces.moveWindowTo(win, target_ws) catch |err| {
        debug.logError(err, win);
        // Nothing has been fired yet beyond what resolveTargetWorkspace already
        // drained, so there is no cookie left to discard here.
        return;
    };

    refreshSizeHints(win);

    // WM_PROTOCOLS is interned at startup; the atom-0 fallback keeps the
    // dual-cookie discard in populateFocusCacheFromCookies symmetric if not.
    const protocols_cookie = fireWMProtocolsQuery(conn, win) orelse
        xcb.xcb_get_property(conn, property_no_delete, win, 0, xcb.XCB_ATOM_ATOM, 0, max_property_length);
    const hints_cookie = xcb.xcb_get_property(
        conn,
        property_no_delete,
        win,
        xcb.XCB_ATOM_WM_HINTS,
        xcb.XCB_ATOM_WM_HINTS,
        0,
        wm_hints_long_length,
    );
    populateFocusCacheFromCookies(conn, win, protocols_cookie, hints_cookie);

    if (on_current) mapWindowToScreen(win) else registerWindowOffscreen(win);
}

const PreGrabState = struct {
    ptr_reply: ?*xcb.xcb_query_pointer_reply_t,
    target: ?DestroyFocusTarget,
    model: ?InputModel,
};

fn resolvePreGrabState(was_focused: bool, conn: core.Connection) PreGrabState {
    if (!was_focused) return .{ .ptr_reply = null, .target = null, .model = null };

    const ptr_reply = xcb.xcb_query_pointer_reply(
        conn,
        xcb.xcb_query_pointer(conn, core.getState().root),
        null,
    );

    const target = resolveDestroyFocusTarget(ptr_reply);
    const model: ?InputModel = if (target) |t| blk: {
        if (t.reason == .pointer_sync and !focus.isWindowMapped(conn, t.win)) break :blk null;
        break :blk getInputModel(conn, t.win);
    } else null;

    return .{ .ptr_reply = ptr_reply, .target = target, .model = model };
}

fn unmanageWindow(win: u32) void {
    const cs = core.getState();
    const fs_ws = fullscreen.workspaceFor(win);
    if (fs_ws) |ws| fullscreen.removeForWorkspace(ws);
    const was_fullscreen = fs_ws != null;

    const was_focused = (focus.getFocused() == win);

    const window_workspace = tracking.getWorkspaceForWindow(win);
    const current_ws = tracking.getCurrentWorkspace();

    if (state.?.cache_ready) {
        if (state.?.cache_slots.indexOfById(win)) |i| state.?.cache_slots.swapRemove(i);
    }

    // Evict child-cache entries pointing at this toplevel, so a new window
    // reusing the same XID can't be mis-identified as its child on the next
    // hover.
    evictChildCache(win);

    // -- Local bookkeeping, before the grab ---------------------------------
    // tiling.removeWindow unconditionally evicts the combined cache entry
    // (geometry + border + size hints). All three removes are pure local
    // bookkeeping (no X requests), so they run pre-grab, letting the
    // post-close focus target be resolved against win-free tracking state,
    // with its input model queried BEFORE the grab.
    if (build_options.has_tiling) tiling.removeWindow(win);
    minimize.untrackWindow(win);
    workspaces.removeWindow(win);

    const pre_grab = resolvePreGrabState(was_focused, cs.conn);
    defer if (pre_grab.ptr_reply) |r| std.c.free(r);

    utils.grabServer(cs.conn);

    if (was_fullscreen) if (build_options.has_bar) bar.setBarState(.show_fullscreen);

    if (was_focused) {
        // Resolve the real post-close focus BEFORE retiling: tiling.removeWindow
        // already dropped `win` from the workspace list, but focus.getFocused()
        // still returns it until clearFocus/setFocus runs. A retile in between
        // would read that stale ID, focus-driven layouts (monocle) fall back
        // to an arbitrary window, and nothing retiles again once focus lands.
        focus.clearFocus();
        // pre_grab.target is null only when the liveness guard failed above;
        // in that case skip focus, matching setFocus's early return.
        if (pre_grab.target) |t| {
            if (pre_grab.model) |model| {
                focus.setFocusWithModel(t.win, t.reason, model);
            }
        }
        if (tilingActive()) if (build_options.has_tiling) tiling.retileIfDirty();
    } else if (!was_fullscreen and tilingActive() and build_options.has_tiling) {
        if (window_workspace) |ws| if (current_ws == ws)
            tiling.retileIfDirty()
        else
            tiling.retileInactiveWorkspace(core.WorkspaceId.fromIndex(ws));
    }

    // Tiled-window borders are already current after retileIfDirty (handled by
    // configureWithHints), so only float windows need a sweep here.
    flushGrabBorders();

    // No xcb_flush here: the event-loop end-of-batch flush covers this.
    utils.ungrabServer(cs.conn);
}

pub fn handleUnmapNotify(event: *const xcb.xcb_unmap_notify_event_t) void {
    if (isValidManagedWindow(event.window)) unmanageWindow(event.window);
}

pub fn handleDestroyNotify(event: *const xcb.xcb_destroy_notify_event_t) void {
    if (build_options.has_floating) floating.cancelDragForWindow(event.window);
    if (isValidManagedWindow(event.window)) unmanageWindow(event.window);
}

/// Post-unmanage focus target resolution: PURE, no side effects.
///
/// Resolves where focus should land after the focused window closes: the
/// scroll-layout MRU prev, else the window under the pointer, else the first
/// visible window on the current workspace. Returns null when nothing should
/// receive focus (unmanageWindow falls back to clearFocus).
///
/// The caller applies the result via focus.setFocusWithModel with a
/// pre-resolved input model, so the model's blocking WM_PROTOCOLS reply wait
/// happens BEFORE the server grab rather than inside it.
///
/// `.pointer_sync` (the pointer-child case) may raise a floating window and
/// arms the confirm/retry machinery for non-compliant clients. Accepts a
/// pre-drained pointer reply (null if the query failed or window was not
/// focused); the caller owns its memory, accepting the reply instead of the
/// cookie prevents an implicit XCB output-buffer flush inside the grab.
fn resolveDestroyFocusTarget(ptr_reply: ?*xcb.xcb_query_pointer_reply_t) ?DestroyFocusTarget {
    // Scroll layout: windows can be off-screen, so the pointer is often not
    // over any managed window. Bypass pointer-based focus entirely and use the
    // focus history recorded by tiling.updateWindowFocus.
    // takePrevFocusedForScroll is a no-op (returns null) in all other layouts.
    if ((if (build_options.has_tiling) tiling.takePrevFocusedForScroll() else null)) |prev| {
        if (tracking.isOnCurrentWorkspaceAndVisible(prev)) {
            return .{ .win = prev, .reason = .tiling_operation };
        }
    }

    // xcb_query_pointer's `child` may be a non-managed toolkit sub-window, not
    // the managed toplevel: resolve it via findManagedWindow. child == 0
    // means the pointer is over no window; skip the tree walk and fall through.
    if (ptr_reply) |reply| {
        if (reply.*.child != 0) {
            const child = findManagedWindow(core.getState().conn, reply.*.child, tracking.isManaged);
            if (tracking.isOnCurrentWorkspaceAndVisible(child)) {
                return .{ .win = child, .reason = .pointer_sync };
            }
        }
    }
    if (focus.findBestAvailable(tracking.isOnCurrentWorkspaceAndVisible)) |win| {
        return .{ .win = win, .reason = .tiling_operation };
    }
    return null;
}

const DestroyFocusTarget = struct {
    win: u32,
    reason: focus.Reason,
};

const geometry_mask: u16 =
    xcb.XCB_CONFIG_WINDOW_X | xcb.XCB_CONFIG_WINDOW_Y |
    xcb.XCB_CONFIG_WINDOW_WIDTH | xcb.XCB_CONFIG_WINDOW_HEIGHT |
    xcb.XCB_CONFIG_WINDOW_BORDER_WIDTH;

fn sendConfigureNotify(win: u32, geom: utils.Rect) void {
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

pub fn geometryFromXcbReply(reply: *xcb.xcb_get_geometry_reply_t) utils.Rect {
    return .{
        .x = reply.*.x,
        .y = reply.*.y,
        .width = reply.*.width,
        .height = reply.*.height,
        .border_width = reply.*.border_width,
    };
}

/// Resolve the window's current geometry, cheapest source first:
///
///   1. Tiling cache: zero round-trips (always current after a retile).
///   2. Fullscreen: geometry is fixed at (0, 0, screen_w, screen_h, bw=0);
///      enterFullscreen writes exactly this and invalidates the tiling cache
///      entry so the window misses path 1 while fullscreen. Handling it here
///      avoids a blocking xcb_get_geometry per ConfigureRequest, which matters
///      for video players that poll their size continuously.
///   3. True cache miss: one blocking xcb_get_geometry. Floating windows
///      never retiled; a fallback, not a hot path.
///
/// Returns null when even the fallback fails (window gone).
fn resolveConfigureGeometry(win: u32) ?utils.Rect {
    if (if (build_options.has_tiling) tiling.getWindowGeom(win) else null) |rect| {
        const border: u16 = (if (build_options.has_tiling) tiling.getBorderWidth() else 0);
        return .{ .x = rect.x, .y = rect.y, .width = rect.width, .height = rect.height, .border_width = border };
    }

    if (fullscreen.isFullscreen(win)) {
        const screen = core.getState().screen;
        return .{
            .x = 0,
            .y = 0,
            .width = @intCast(screen.width_in_pixels),
            .height = @intCast(screen.height_in_pixels),
            .border_width = 0,
        };
    }

    const conn = core.getState().conn;
    const reply = xcb.xcb_get_geometry_reply(
        conn,
        xcb.xcb_get_geometry(conn, win),
        null,
    ) orelse return null;
    defer std.c.free(reply);
    return geometryFromXcbReply(reply);
}

fn sendSyntheticConfigureNotify(win: u32) void {
    const geom = resolveConfigureGeometry(win) orelse return;
    sendConfigureNotify(win, geom);
}

pub fn handleConfigureRequest(event: *const xcb.xcb_configure_request_event_t) void {
    const win = event.window;

    // Fast exit: no geometry fields requested, nothing for the WM to act on.
    // Checked before the tiling/fullscreen predicates to skip two hash probes
    // on stacking-order-only requests (compositors, override-redirect games).
    const mask = event.value_mask & geometry_mask;
    if (mask == 0) return;

    const is_tiled = tilingActive() and build_options.has_tiling and tiling.isWindowActiveTiled(win);
    const is_fullscreen = fullscreen.isFullscreen(win);
    if (is_tiled or is_fullscreen) {
        sendSyntheticConfigureNotify(win);
        return;
    }

    // Deny min-size ConfigureRequests from the window being drag-resized. When
    // the WM sizes a floating window below its WM_NORMAL_HINTS minimum, the
    // client fires a ConfigureRequest back with its minimum dimensions;
    // honouring it races the next MotionNotify and causes visible flicker.
    // Echo the geometry the WM already applied so the client settles without
    // fighting the drag.
    if (build_options.has_floating and floating.isResizingWindow(win)) {
        const last = floating.getDragLastRect();
        if (last.width != 0) {
            sendConfigureNotify(win, .{ .x = last.x, .y = last.y, .width = last.width, .height = last.height, .border_width = getBorderWidth() });
        } else {
            // No motion event yet in this drag, get_geometry round-trip so we
            // echo an accurate current size.
            sendSyntheticConfigureNotify(win);
        }
        return;
    }

    var values: [5]u32 = undefined;
    var n: usize = 0;
    if (mask & xcb.XCB_CONFIG_WINDOW_X != 0) { values[n] = utils.toXcbCoord(event.x); n += 1; }
    if (mask & xcb.XCB_CONFIG_WINDOW_Y != 0) { values[n] = utils.toXcbCoord(event.y); n += 1; }
    if (mask & xcb.XCB_CONFIG_WINDOW_WIDTH != 0) { values[n] = event.width; n += 1; }
    if (mask & xcb.XCB_CONFIG_WINDOW_HEIGHT != 0) { values[n] = event.height; n += 1; }
    if (mask & xcb.XCB_CONFIG_WINDOW_BORDER_WIDTH != 0) { values[n] = event.border_width; n += 1; }
    _ = xcb.xcb_configure_window(core.getState().conn, win, mask, &values);
}

inline fn suppressSpawnCrossing(root_x: i16, root_y: i16) bool {
    if (focus.getSuppressReason() != .window_spawn) return false;
    // Consume the suppression flag unconditionally: it is a one-shot guard that
    // only applies to the first crossing event after a spawn. Clearing it
    // only when the cursor had moved would instead suppress all future
    // hover-focus events if the cursor stayed at the exact spawn pixel.
    focus.setSuppressReason(.none);
    return root_x == state.?.spawn_cursor.x and root_y == state.?.spawn_cursor.y;
}

/// Attempt to focus `win` via the hover (EnterNotify) path.
///
/// Guards against workspace membership and minimize state before calling
/// focus.setFocus(.mouse_enter). The .mouse_enter reason is the direct
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
    debugLogEnterNotify(event);
    if (event.mode != xcb.XCB_NOTIFY_MODE_NORMAL or
        event.detail == xcb.XCB_NOTIFY_DETAIL_INFERIOR)
        return;
    if (build_options.has_floating and floating.isDragging()) return;
    if (suppressSpawnCrossing(event.root_x, event.root_y)) return;
    if (focus.shouldSuppressEnterNotify()) return;
    maybeFocusWindow(findManagedWindow(core.getState().conn, event.event, tracking.isManaged));
}

fn debugLogEnterNotify(event: *const xcb.xcb_enter_notify_event_t) void {
    debug.info("[ENTER] win=0x{x} mode={} detail={} root_x={} root_y={}", .{
        event.event, event.mode, event.detail, event.root_x, event.root_y,
    });
}

pub fn handleLeaveNotify(event: *const xcb.xcb_leave_notify_event_t) void {
    focus.setLastEventTime(event.time);
    if (event.event != core.getState().root) return;
    if (event.mode != xcb.XCB_NOTIFY_MODE_NORMAL) return;
    if (build_options.has_floating and floating.isDragging()) return;
    if (suppressSpawnCrossing(event.root_x, event.root_y)) return;
    // When child is zero the pointer left to an area not covered by any window.
    if (event.child == 0) return;
    // Guard against unmanaged subwindows (e.g. embedded GTK widgets): a root
    // LeaveNotify with non-zero child doesn't guarantee a managed toplevel.
    // This avoids a spurious workspace lookup for every non-toplevel the
    // pointer traverses, consistent with handleEnterNotify's findManagedWindow.
    if (!tracking.isManaged(event.child)) return;
    maybeFocusWindow(event.child);
}

pub fn handlePropertyNotify(event: *const xcb.xcb_property_notify_event_t) void {
    if (!isValidManagedWindow(event.window)) return;
    const conn = core.getState().conn;

    // WM_NORMAL_HINTS: refresh the size-hint cache so max-size, resize-
    // increment, and aspect-ratio constraints stay accurate for apps that
    // update hints after map time (e.g. terminal emulators adjusting their
    // increment grid when the font changes).
    if (event.atom == xcb.XCB_ATOM_WM_NORMAL_HINTS) {
        refreshSizeHints(event.window);
        return;
    }

    if (event.atom == utils.getAtomOrZero("WM_PROTOCOLS")) {
        // Only WM_PROTOCOLS changed: re-query wm_delete, keep accepts_input
        // from cache to avoid a redundant WM_HINTS round-trip.
        const existing: ?CachedProps = if (!state.?.cache_ready) null else blk: {
            break :blk if (state.?.cache_slots.indexOfById(event.window)) |i| state.?.cache_slots.items[i].props else null;
        };
        const wm_delete = queryWMProtocolsProps(conn, event.window).wm_delete;
        const accepts_input = if (existing) |p| p.accepts_input else queryWMHintsAcceptsInput(conn, event.window);
        putCachedProps(event.window, .{ .accepts_input = accepts_input, .wm_delete = wm_delete });
    } else if (event.atom == xcb.XCB_ATOM_WM_HINTS) {
        // Only WM_HINTS changed: re-query accepts_input, keep wm_delete
        // from cache to avoid a redundant WM_PROTOCOLS round-trip.
        const existing: ?CachedProps = if (!state.?.cache_ready) null else blk: {
            break :blk if (state.?.cache_slots.indexOfById(event.window)) |i| state.?.cache_slots.items[i].props else null;
        };
        const accepts_input = queryWMHintsAcceptsInput(conn, event.window);
        const wm_delete = if (existing) |p| p.wm_delete else queryWMProtocolsProps(conn, event.window).wm_delete;
        putCachedProps(event.window, .{ .accepts_input = accepts_input, .wm_delete = wm_delete });
    }
}

inline fn clampToU16(v: u32) u16 {
    return @intCast(@min(v, std.math.maxInt(u16)));
}

// Extract a pair of consecutive u16 fields when the flag is set and enough
// fields are present. Shared by max_size and resize_inc extraction which
// share the same 2-field pattern.
const SizePair = struct { width: u16, height: u16 };

inline fn extractFieldPair(fields: [*]const u32, field_count: u32, want: bool, comptime off: usize) SizePair {
    if (want and field_count >= off + 2) return .{ .width = clampToU16(fields[off]), .height = clampToU16(fields[off + 1]) };
    return .{ .width = 0, .height = 0 };
}

/// Called at map time and whenever WM_NORMAL_HINTS changes post-map
/// (see handlePropertyNotify).
fn refreshSizeHints(win: u32) void {
    const conn = core.getState().conn;
    const cookie = xcb.xcb_get_property(
        conn,
        property_no_delete,
        win,
        xcb.XCB_ATOM_WM_NORMAL_HINTS,
        xcb.XCB_ATOM_WM_SIZE_HINTS,
        0,
        wm_normal_hints_long_length,
    );
    parseSizeHintsIntoCache(win, cookie);
}

fn parseSizeHintsIntoCache(
    win: u32,
    cookie: xcb.xcb_get_property_cookie_t,
) void {
    const reply = xcb.xcb_get_property_reply(core.getState().conn, cookie, null) orelse return;
    defer std.c.free(reply);
    if (reply.*.format != 32 or reply.*.value_len < 5) return;

    const fields = u32Values(reply);
    const field_count = reply.*.value_len;
    const flags = fields[0];

    // PMinSize and PBaseSize (min_width/min_height) are intentionally not
    // cached: applyHintsToRect skips min-size clamping for tiling because the
    // layout engine owns all dimensions. All other ICCCM constraints are
    // forwarded so windows with max-size, resize-increment, or aspect-ratio
    // hints behave correctly.
    const want_max = flags & p_max_size != 0;
    const want_inc = flags & p_resize_inc != 0;
    const want_asp = flags & p_aspect != 0;

    if (!want_max and !want_inc and !want_asp) return;

    // PMaxSize: fields[7..9] and PResizeInc: fields[9..11] share the same
    // pattern: flag-check + field_count gate + 2-field extraction.
    const max_pair = extractFieldPair(fields, field_count, want_max, 7);
    const inc_pair = extractFieldPair(fields, field_count, want_inc, 9);

    // PAspect: fields[11..14] = min_aspect.x/y, max_aspect.x/y.
    // dwm convention: min_aspect = y/x (lower bound on h/w),
    //                 max_aspect = x/y (upper bound on w/h).
    var min_aspect: f32 = 0.0;
    var max_aspect: f32 = 0.0;
    if (want_asp and field_count >= 15) {
        const min_x = fields[11];
        const min_y = fields[12];
        const max_x = fields[13];
        const max_y = fields[14];
        if (min_x > 0) min_aspect = @as(f32, @floatFromInt(min_y)) / @as(f32, @floatFromInt(min_x));
        if (max_y > 0) max_aspect = @as(f32, @floatFromInt(max_x)) / @as(f32, @floatFromInt(max_y));
    }

    if (build_options.has_tiling) tiling.cacheSizeHints(win, .{
        .max_width = max_pair.width,
        .max_height = max_pair.height,
        .inc_width = inc_pair.width,
        .inc_height = inc_pair.height,
        .min_aspect = min_aspect,
        .max_aspect = max_aspect,
    });
}

pub inline fn getBorderWidth() u16 {
    return borders.width();
}

fn applyBorderWidth(win: u32) void {
    borders.applyWidth(core.getState().conn, win);
}

pub fn applyBorder(win: u32) void {
    borders.apply(core.getState().conn, win);
}

/// Refresh border colors for all windows on the current workspace. Shared
/// iteration loop for workspace border sweeps:
///
/// - `skip_tiled` true (updateFloatingWindowBorders): skip tiled windows,
///   configureWithHints already updated their borders via get_border_color.
/// - `skip_tiled` false (updateWorkspaceBorders): dedup via the tiling
///   CacheMap (sendBorderColorIfChanged), so the steady-state focused-window
///   sweep generates zero XCB traffic.
fn sweepWorkspaceBorders(comptime skip_tiled: bool) void {
    const cur = tracking.getCurrentWorkspace() orelse return;
    const cur_bit = tracking.workspaceBit(cur);
    const cs = core.getState();
    const conn = cs.conn;
    for (tracking.allWindows()) |entry| {
        const win = entry.win;
        if (entry.mask & cur_bit == 0) continue;
        const color = borders.color(win);
        if (comptime skip_tiled) {
            if (tilingActive() and build_options.has_tiling and tiling.isWindowTiled(win)) continue;
        } else {
            // Dedup via the tiling CacheMap: skip the XCB call when unchanged.
            if (build_options.has_tiling and tiling.sendBorderColorIfChanged(win, color)) continue;
        }
        utils.setBorderPixel(conn, win, color);
    }
}

pub fn updateWorkspaceBorders() void {
    sweepWorkspaceBorders(false);
}

/// Called after a retile: `configureWithHints` already updated tiled-window
/// borders via the `get_border_color` callback, so re-sending them here would
/// be redundant. When tiling is absent or disabled, falls back to a full sweep
/// because there are no tiled windows to skip.
pub fn updateFloatingWindowBorders() void {
    sweepWorkspaceBorders(true);
}

/// Event-loop entry point for the per-batch border sweep. Sweeps only when no
/// grab-flush path (markBordersFlushed) already did so, then resets the flag
/// for the next batch.
///
/// CALLING CONTRACT: must be called exactly once per event batch, at its end.
/// Multiple calls per batch cause redundant sweeps, the flag resets
/// unconditionally, so a second call sees it false and sweeps again.
pub fn updateWorkspaceBordersIfNeeded() void {
    if (!state.?.borders_flushed_this_batch) updateWorkspaceBorders();
    state.?.borders_flushed_this_batch = false;
}

// ClientMessage: EWMH fullscreen requests from applications

pub fn handleClientMessage(event: *const xcb.xcb_client_message_event_t) void {
    if (event.format != 32) return;

    const net_wm_state = utils.getAtomOrZero("_NET_WM_STATE");
    if (net_wm_state == 0 or event.type != net_wm_state) return;

    const fs_atom = utils.getAtomOrZero("_NET_WM_STATE_FULLSCREEN");
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
    if (should_enter == is_fs) return;
    if (should_enter)
        fullscreen.enterFullscreen(win, null)
    else
        // Use the per-window exit path, not toggle() (which acts on whatever
        // the fullscreen module deems "current"), multiple workspaces can
        // each hold a fullscreen window.
        fullscreen.exitFullscreen(win);
}

/// Called on config reload.
pub fn reloadBorders() void {
    for (tracking.allWindows()) |entry| applyBorder(entry.win);
}
