//! Window lifecycle
//! Manages window creation, destruction, configuration, and event handling for all managed windows.

const std = @import("std");

const core = @import("core");
const xcb = core.xcb;
const utils = @import("utils");
const constants = @import("constants");
const masks = @import("masks");
const debug = @import("debug");
const tracking = @import("tracking");
const focus = @import("focus");
const build_options = @import("build_options");
// Optional window sub-systems are reached through the build-generated
// `window_modules` registry, never by naming an optional module here.
// `window_mods` is the auto-discovered `[N]WindowModule` array in
// deterministic filesystem scan order; the lifecycle dispatch below runs
// each present module's init/deinit, and absent modules are simply not in
// the array.
const window_mods = @import("window_modules").modules;

/// Registry lookup for the hook `field`; the canonical scan lives in
/// `plugin.zig` (see `plugin.providerOf`). Null when no module binds it.
fn providerOf(comptime field: std.meta.FieldEnum(@import("plugin").WindowModule)) ?@import("plugin").WindowModule {
    return @import("plugin").providerOf(window_mods[0..], field);
}
const screen_mod = @import("screen");
const wincache = @import("wincache");
const borders = @import("borders");
const pipeline = @import("pipeline");
const actions = @import("actions");
const persist = @import("persist");

// XSizeHints flags (ICCCM 4.1.2.3)
const p_max_size: u32 = 0x20;
const p_resize_inc: u32 = 0x40;
const p_aspect: u32 = 0x80;

// WM_HINTS constants (ICCCM 4.1.2.4)
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

// Geometry cache: last-known window geometry for workspace-switch and
// minimize/restore. Owned by wincache.zig, the single source of truth for both
// tiled and floating windows.

pub fn markBordersFlushed() void {
    state.?.borders_flushed_this_batch = true;
}

/// Returns null if the window does not exist or is not yet mapped.
pub fn getGeometry(conn: core.Connection, win: u32) ?utils.Rect {
    const reply = xcb.xcb_get_geometry_reply(conn, xcb.xcb_get_geometry(conn, win), null) orelse return null;
    defer std.c.free(reply);
    return utils.rectFromXcb(reply);
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

/// The four ICCCM focus delivery modes (4.1.7), determined by the combination of
/// WM_HINTS.input and WM_TAKE_FOCUS presence in WM_PROTOCOLS.
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
/// matching ICCCM 4.1.2.4 defaults.
fn extractWMHintsInput(
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

/// Resolves the ICCCM 4.1.7 focus-delivery model for `win` together with the
/// take_focus answer from the SAME live WM_PROTOCOLS reply, so callers can
/// dispatch WM_TAKE_FOCUS without firing a second protocol query.
pub const InputModelResolution = struct {
    model: InputModel,
    /// True when `win` advertises WM_TAKE_FOCUS, scanned from the same live
    /// reply that produced `model`.
    take_focus: bool,
};

pub fn getInputModelResolved(conn: core.Connection, win: u32) InputModelResolution {
    const accepts_input = getOrQueryCachedProps(conn, win).accepts_input;

    const supports_take_focus = queryWMProtocolsProps(conn, win).take_focus;

    return .{ .model = inputModelFrom(supports_take_focus, accepts_input), .take_focus = supports_take_focus };
}

/// Resolves the ICCCM 4.1.7 focus-delivery model for `win`: accepts_input
/// comes from the cache above (live query on a miss); supports_take_focus is
/// always queried live, see the "ICCCM focus property cache" note for why.
pub fn getInputModel(conn: core.Connection, win: u32) InputModel {
    return getInputModelResolved(conn, win).model;
}

/// Falls back to a live query only on a genuine cache miss (extremely rare).
pub fn supportsWMDeleteCached(conn: core.Connection, win: u32) bool {
    return getOrQueryCachedProps(conn, win).wm_delete;
}

/// Called by `sendWMTakeFocus` (live round-trip path) to keep the send logic in one place.
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

    sendTakeFocusEvent(conn, win, time, protocols_atom, take_focus_atom);
}

/// Builds and sends the WM_TAKE_FOCUS ClientMessage. No protocol-list scan:
/// callers either scanned already or hold an authoritative answer.
fn sendTakeFocusEvent(
    conn: core.Connection,
    win: u32,
    time: u32,
    protocols_atom: u32,
    take_focus_atom: u32,
) void {
    var event = std.mem.zeroes(xcb.xcb_client_message_event_t);
    event.response_type = xcb.XCB_CLIENT_MESSAGE;
    event.window = win;
    event.type = protocols_atom;
    event.format = 32;
    event.data.data32[0] = take_focus_atom;
    event.data.data32[1] = time;

    _ = xcb.xcb_send_event(conn, 0, win, xcb.XCB_EVENT_MASK_NO_EVENT, @ptrCast(&event));
}

/// Dispatches WM_TAKE_FOCUS from an already-known advertisement bit, the one
/// returned by `getInputModelResolved` alongside the input model. Skips the
/// WM_PROTOCOLS round trip entirely; used by the grab-wrapped focus path so a
/// keyboard focus change costs one protocol query instead of two.
pub fn sendWMTakeFocusKnown(
    conn: core.Connection,
    win: u32,
    time: u32,
    advertises_take_focus: bool,
) void {
    if (!advertises_take_focus) return;
    const protocols_atom = utils.getAtomCached("WM_PROTOCOLS") catch return;
    const take_focus_atom = utils.getAtomCached("WM_TAKE_FOCUS") catch return;
    sendTakeFocusEvent(conn, win, time, protocols_atom, take_focus_atom);
}

/// Shared body of sendWMTakeFocus and sendWMTakeFocusWithCookie: resolves the
/// WM_PROTOCOLS and WM_TAKE_FOCUS atoms, drains the WM_PROTOCOLS reply (from the
/// pre-fired `cookie` when present, else a fresh round-trip), and dispatches the
/// WM_TAKE_FOCUS ClientMessage iff `win` advertises the protocol (ICCCM 4.1.7).
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

/// Sends a WM_TAKE_FOCUS client message (ICCCM 4.1.7) iff `win` advertises
/// WM_TAKE_FOCUS in WM_PROTOCOLS. Checked live on every call, matching dwm's
/// sendevent(), this one flag is never cached (see the "ICCCM focus property
/// cache" note: Electron/GTK apps can set WM_PROTOCOLS before we subscribe to
/// PropertyNotify, permanently staling a cached value).
///
/// Fallback for callers that don't pre-fire the cookie (drainPendingConfirm).
pub fn sendWMTakeFocus(conn: core.Connection, win: u32, time: u32) void {
    dispatchTakeFocus(conn, win, time, null);
}

// Private ICCCM helpers

/// See ICCCM 4.1.7: the matrix of (accepts_input x supports_take_focus)
/// determines which focus delivery mechanism the WM must use.
fn inputModelFrom(supports_take_focus: bool, accepts_input: bool) InputModel {
    return if (supports_take_focus)
        (if (accepts_input) .locally_active else .globally_active)
    else
        (if (accepts_input) .passive else .no_input);
}

const WMProtocolsProps = struct { take_focus: bool = false, wm_delete: bool = false };

/// Shared by queryWMProtocolsProps (live query) and populateFocusCacheFromCookies
/// (cookie path).
fn scanProtocolAtoms(protocol_atoms: []const u32, take_focus_atom: u32, wm_delete_atom: u32) WMProtocolsProps {
    var props: WMProtocolsProps = .{};
    for (protocol_atoms) |atom| {
        if (atom == take_focus_atom) props.take_focus = true;
        if (atom == wm_delete_atom) props.wm_delete = true;
        if (props.take_focus and props.wm_delete) break;
    }
    return props;
}

/// Alignment-cast to the u32 value array of a format-32 get_property reply.
fn u32Values(r: *xcb.xcb_get_property_reply_t) [*]const u32 {
    return @ptrCast(@alignCast(xcb.xcb_get_property_value(r)));
}

/// Shared by queryWMProtocolsProps (live query) and populateFocusCacheFromCookies
/// (cookie path); the caller owns `reply`'s memory.
fn protocolPropsFromReply(
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
    wincache.init(alloc);
    // Uniform lifecycle dispatch: each compiled-in sub-system's init runs,
    // absent modules aren't in the array, so nothing else needs a has_* guard.
    for (window_mods) |m| if (m.init) |init_fn| try init_fn();
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
    wincache.deinit();
    // Uniform lifecycle dispatch: every compiled-in sub-system's deinit runs,
    // absent modules aren't in the array.
    for (window_mods) |m| if (m.deinit) |deinit_fn| deinit_fn();
    // Free heap-backed state before the reset below wipes the struct; a bare
    // `state = .{}` would leak the spawn queue's and rules map's backing memory.
    if (state.?.alloc) |a| {
        state.?.spawn_queue.deinit(a);
        state.?.rules_map.deinit(a);
    }
    // Clear the focus-property cache before focus/tracking deinit, whose
    // managed-window sweeps must not encounter a partially-valid cache.
    state.?.cache_slots.clear();
    state.?.cache_ready = false;
    focus.deinit();
    tracking.deinit();
    // Reset every remaining field (child_cache, borders_flushed_this_batch,
    // and the now-freed spawn_queue/rules_map/alloc) so nothing is left stale
    // for the next init()/deinit() cycle.
    state = .{};
}

inline fn tilingActive() bool {
    return core.getState().config.tiling.enabled;
}

// Window predicates

/// True for the null window, the root, or the bar, never valid focus/manage targets.
pub inline fn isInvalidWindow(win: u32) bool {
    return win == 0 or win == core.getState().root or screen_mod.isSurfaceWindow(win);
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

/// Drains pre-fired WM_CLASS / _NET_WM_PID cookies to resolve the target
/// workspace. Cookies are fired by the caller (handleMapRequest) together with
/// the other three property queries so the X server can process all five in
/// parallel; this function only drains the two workspace-resolution replies.
fn resolveTargetWorkspace(
    current_ws: core.WorkspaceId,
    c_wm_class: ?xcb.xcb_get_property_cookie_t,
    c_net_wm_pid: ?xcb.xcb_get_property_cookie_t,
) core.WorkspaceId {
    const cs = core.getState();

    // Drain replies: WM_CLASS first, then _NET_WM_PID.
    if (c_wm_class) |cookie| {
        if (findWorkspaceRuleByClass(cookie)) |target| {
            // The _NET_WM_PID query may already be in flight; discard it so
            // no unconsumed reply lingers in the XCB queue past this return.
            if (c_net_wm_pid) |pid| xcb.xcb_discard_reply(cs.conn, pid.sequence);
            return clampToValidWorkspace(target, current_ws);
        }
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

/// Handles a MapRequest by firing ALL property query cookies up-front, then
/// draining replies sequentially. Firing all five cookies before draining any
/// lets the X server process them in parallel, saving 2-3 blocking round trips
/// compared to the previous fire-then-drain-per-property approach.
pub fn handleMapRequest(event: *const xcb.xcb_map_request_event_t) void {
    const win = event.window;
    const conn = core.getState().conn;
    const cs = core.getState();

    // Double-manage guard: a window can send multiple MapRequest events (e.g.
    // an unmap+remap race while the first is still processing); without it,
    // the model registration and property queries below would fire twice.
    if (tracking.isManaged(win)) return;

    // getCurrentWorkspace() returns ?u8; the value is already bounded to [0,255]
    // by the u8 return type, so no further clamping is needed.
    const current_ws = core.WorkspaceId.fromIndex(tracking.getCurrentWorkspace() orelse 0);

    _ = xcb.xcb_change_window_attributes(
        conn,
        win,
        xcb.XCB_CW_EVENT_MASK,
        &[_]u32{masks.EventMasks.managed_window},
    );

    // ----- Fire ALL property cookies before draining any reply -----
    // The server processes all five requests in parallel while we do pure
    // local bookkeeping below.

    // Workspace resolution cookies (conditional).
    var c_wm_class: ?xcb.xcb_get_property_cookie_t = null;
    if (cs.config.workspaces.rules.items.len > 0 and utils.getAtomOrZero("WM_CLASS") != 0) {
        c_wm_class = xcb.xcb_get_property(conn, property_no_delete, win, utils.getAtomOrZero("WM_CLASS"), xcb.XCB_ATOM_STRING, 0, constants.property_max_length);
    }

    var c_net_wm_pid: ?xcb.xcb_get_property_cookie_t = null;
    if (state.?.spawn_queue.items.len > 0) {
        c_net_wm_pid = xcb.xcb_get_property(conn, property_no_delete, win, utils.getAtomOrZero("_NET_WM_PID"), xcb.XCB_ATOM_CARDINAL, 0, 1);
    }

    // Property cookies (always fired).
    const normal_hints_cookie = xcb.xcb_get_property(
        conn,
        property_no_delete,
        win,
        xcb.XCB_ATOM_WM_NORMAL_HINTS,
        xcb.XCB_ATOM_WM_SIZE_HINTS,
        0,
        wm_normal_hints_long_length,
    );
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

    // ----- Drain replies sequentially -----
    const target_ws = resolveTargetWorkspace(current_ws, c_wm_class, c_net_wm_pid);
    const on_current = target_ws.eql(current_ws);

    parseSizeHintsIntoCache(win, normal_hints_cookie);
    populateFocusCacheFromCookies(conn, win, protocols_cookie, hints_cookie);

    // Shared admission policy (MapRequest path). The cookie firing above is
    // specific to the MapRequest event source; everything from here on (the
    // model registration + grabs + child-cache seeding) is identical to the
    // boot-time adoption path, so it lives in admitWindow.
    admitWindow(win, target_ws.index, on_current);
}

/// Admission policy shared by the MapRequest path (handleMapRequest) and the
/// boot-time adoption path (adoptRootWindows). Both sources fire and drain
/// their property cookies and resolve the target workspace BEFORE calling
/// here; this is the single place where a window is registered with the model
/// and its keyboard grabs seeded. One map-request path, one adoption path, one
/// admission policy.
///
/// `cacheChildWindow` maps the window to root: for a MapRequest toplevel its
/// parent IS root, and for adoption root is the only meaningful parent (there
/// is no map-request event), so both paths funnel through the same cache write,
/// an entry keyed on the (now-managed) toplevel itself, which
/// findManagedWindow's direct `is_managed` hit short-circuits anyway.
fn admitWindow(win: u32, target_ws: u8, on_current: bool) void {
    const cs = core.getState();
    actions.mapRequest(win, target_ws, on_current);
    cacheChildWindow(win, cs.root);
}

/// Linear scan for a window's restore record. Restore files are small
/// (bounded by the model's store_capacity), so a flat scan is cache-local and
/// avoids allocating a lookup map just for adoption.
fn findWindowRecord(windows: []const persist.WindowRecord, win: u32) ?*const persist.WindowRecord {
    for (windows) |*r| {
        if (r.win == win) return r;
    }
    return null;
}

/// Target workspace for an adopted window: the restore record's home
/// workspace (lowest set bit of its mask) when present, else the currently
/// active workspace. Deliberately NOT the spawn-queue/rules resolution, which
/// describes brand-new spawns rather than pre-existing windows.
fn restoredOrCurrent(record: ?*const persist.WindowRecord) u8 {
    if (record) |r| {
        if (r.mask != 0) return @intCast(@import("model").lowestBit(r.mask));
    }
    return tracking.getCurrentWorkspace() orelse 0;
}

/// Re-applies a restore record's mask, anchor, and presence onto an
/// already-registered model entry. Registration (admitWindow ->
/// actions.mapRequest) creates the entry as a present tiled-anchored window on
/// its target workspace; this overwrites the per-window state that survived
/// the re-exec so the caller's reconcile can place it exactly as before.
/// Presence bookkeeping that would otherwise drift is routed through the owning
/// window module's deserialize hook rather than patched by hand.
fn applyRestoredRecord(win: u32, record: *const persist.WindowRecord) void {
    const model = pipeline.model();
    const e = model.store.getPtr(win) orelse return;

    e.mask = record.mask;

    switch (record.anchor) {
        .tiled => {
            // Registration already created a tiled-anchored entry with its
            // home_ws populated; nothing further to patch.
        },
        .floating => |rect| {
            // Mirror toggleFloating's floating storage: anchor + home_ws null
            // (a floating window has no tiled slot). The caller's reconcile
            // sizes the window from this rect.
            e.anchor = .{ .floating = rect };
            e.home_ws = null;
        },
    }

    // Presence that was non-present at save time is re-asserted through the
    // window-module registry's deserialize hook: the module that claims the
    // opaque ext blob re-parks the window / resumes its coverage and restores
    // its private record. Dispatch happens for ANY non-null ext (not only
    // parked records): a covering (fullscreen) window advertises presence
    // .covering + a fullscreen blob, and must route through the module in the
    // same pass. When no module claims the blob (the feature was stripped, or
    // the record carried no ext), the entry stays present and reconciles
    // on-screen -- the graceful degrade.
    if (record.ext) |blob| {
        const m_ptr: *anyopaque = @ptrCast(model);
        for (window_mods) |mod| if (mod.deserializeWindow) |f| {
            if (f(win, blob, m_ptr)) break; // claimed
        };
    }
}

/// Adopts top-level windows that pre-existed the WM's (re)start as direct
/// root children (hana never reparents: clients are root children, borders
/// via the client's own X border), so after a re-exec the fresh process takes
/// over the old session's windows instead of waiting for new maps.
///
/// Per-window policy:
///   - skip already-managed windows, the WM's own bar window, and
///     override-redirect popups (never manage those);
///   - unmapped windows are adopted ONLY when the restore file records them
///     as parked (a surviving hidden window must stay hidden); other unmapped
///     windows are likely withdrawn toplevels and are skipped;
///   - each admitted window registers through the shared admitWindow path on
///     its restored-or-current workspace;
///   - a restore record (if any) then re-applies the window's mask, mode, and
///     presence directly on the model entry.
///
/// CALLING CONTRACT: this does NOT reconcile. Placement derives from
/// tiled_order / focus_mru, which are rebuilt by persist.applyModelLevel
/// AFTER this returns; a reconcile here would place pre-restore state. The
/// caller (main) therefore runs:
///     adoptRootWindows(); persist.applyModelLevel(m); one reconcile.
/// Returns the number of windows admitted (restored-parked ones included).
pub fn adoptRootWindows() !usize {
    // Defensive boot-order guard: adoption expects the window module's state
    // (child cache, spawn queue) to be initialized; if window.init hasn't run
    // yet, there is nothing safe to touch.
    if (state == null) return 0;

    const cs = core.getState();
    const conn = cs.conn;

    const tree_reply = xcb.xcb_query_tree_reply(conn, xcb.xcb_query_tree(conn, cs.root), null) orelse return 0;
    defer std.c.free(tree_reply);
    const children = xcb.xcb_query_tree_children(tree_reply);
    const child_count: usize = @intCast(xcb.xcb_query_tree_children_length(tree_reply));

    const loaded = persist.loaded();

    var adopted: usize = 0;
    for (children[0..child_count]) |win| {
        // Double-manage guard (parity with handleMapRequest): never re-admit a
        // window another path already manages.
        if (tracking.isManaged(win)) continue;

        // The WM's own bar window is a root child we created; leave it alone.
        if (screen_mod.surfaceWindow()) |bar_win| {
            if (bar_win == win) continue;
        }

        const attr_reply = xcb.xcb_get_window_attributes_reply(
            conn,
            xcb.xcb_get_window_attributes(conn, win),
            null,
        ) orelse continue;
        const override_redirect = attr_reply.*.override_redirect != 0;
        const map_state = attr_reply.*.map_state;
        std.c.free(attr_reply);

        // Override-redirect windows are transient/popup, never manage.
        if (override_redirect) continue;

        // Visibility gate: adopt mapped windows; adopt unmapped ONLY when the
        // restore file records them as parked (a surviving hidden window must
        // stay hidden). Other unmapped windows are likely withdrawn toplevels
        // and are skipped.
        const record = if (loaded) |f| findWindowRecord(f.windows, win) else null;
        if (map_state != xcb.XCB_MAP_STATE_VIEWABLE) {
            if (record == null or record.?.presence != .parked) continue;
        }

        // Claim the management event mask so the adopted window delivers the
        // PropertyNotify/StructureNotify/FocusChange events managed windows
        // rely on (mirror of handleMapRequest's preamble).
        _ = xcb.xcb_change_window_attributes(
            conn,
            win,
            xcb.XCB_CW_EVENT_MASK,
            &[_]u32{masks.EventMasks.managed_window},
        );

        // ----- Fire the same property cookies the MapRequest path fires -----
        var c_wm_class: ?xcb.xcb_get_property_cookie_t = null;
        if (cs.config.workspaces.rules.items.len > 0 and utils.getAtomOrZero("WM_CLASS") != 0) {
            c_wm_class = xcb.xcb_get_property(conn, property_no_delete, win, utils.getAtomOrZero("WM_CLASS"), xcb.XCB_ATOM_STRING, 0, constants.property_max_length);
        }

        var c_net_wm_pid: ?xcb.xcb_get_property_cookie_t = null;
        if (state.?.spawn_queue.items.len > 0) {
            c_net_wm_pid = xcb.xcb_get_property(conn, property_no_delete, win, utils.getAtomOrZero("_NET_WM_PID"), xcb.XCB_ATOM_CARDINAL, 0, 1);
        }

        const normal_hints_cookie = xcb.xcb_get_property(
            conn,
            property_no_delete,
            win,
            xcb.XCB_ATOM_WM_NORMAL_HINTS,
            xcb.XCB_ATOM_WM_SIZE_HINTS,
            0,
            wm_normal_hints_long_length,
        );
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

        // Adoption never resolves the target workspace from these cookies
        // (restored-or-current wins, not spawn rules), so discard the two
        // conditionally-fired replies to keep the XCB queue from accumulating
        // unconsumed results.
        if (c_wm_class) |c| xcb.xcb_discard_reply(conn, c.sequence);
        if (c_net_wm_pid) |c| xcb.xcb_discard_reply(conn, c.sequence);

        parseSizeHintsIntoCache(win, normal_hints_cookie);
        populateFocusCacheFromCookies(conn, win, protocols_cookie, hints_cookie);

        // Register on the restored-or-current workspace. on_current=false so
        // actions.mapRequest does NOT reconcile per-window (the caller owns
        // the single end-of-adoption reconcile) or steal model focus before
        // applyModelLevel restores the session's focus.
        admitWindow(win, restoredOrCurrent(record), false);

        if (record) |r| applyRestoredRecord(win, r);

        adopted += 1;
    }

    debug.info("Adopted {d} pre-existing windows", .{adopted});
    return adopted;
}

fn unmanageWindow(win: u32) void {
    // Covering truth is model-side (actions.unmanage reads it); the module
    // store is queried through the registry below.
    if (state.?.cache_ready) {
        if (state.?.cache_slots.indexOfById(win)) |i| state.?.cache_slots.swapRemove(i);
    }

    // Evict child-cache entries pointing at this toplevel, so a new window
    // reusing the same XID can't be mis-identified as its child on the next
    // hover.
    evictChildCache(win);

    // -- Local bookkeeping, before the grab ---------------------------------
    // wincache.removeWindow unconditionally evicts the combined cache entry
    // (geometry + border + size hints). All three removes are pure local
    // bookkeeping (no X requests), so they run pre-grab, letting the
    // post-close focus target be resolved against win-free tracking state,
    // with its input model queried BEFORE the grab.
    wincache.removeWindow(win);

    // Capture the covering record and focus ownership BEFORE
    // tracking.removeWindow (the workspace layer's removeWindow facade ->
    // unregister) drops the model entry: after that, actions.unmanage could
    // never know that the closed window held focus (m.focused is already
    // cleared), so closing a window left the workspace unfocused until a
    // pointer event re-focused it. Both facts ride ctx into
    // actions.unmanage, which runs the same close fallback as the hide path.
    var actx: actions.Ctx = .{
        .withdrawn_fullscreen_ws = if (pipeline.initialized) (if (providerOf(.coveringWsOf)) |wm| wm.coveringWsOf.?(pipeline.model(), win) else null) else null,
        .withdrawn_was_focused = pipeline.initialized and pipeline.model().focused == win,
    };
    // Module cleanup on window drop: each compiled-in window module's
    // onWindowGone fires before the model entry is unregistered below, so
    // per-window bookkeeping (e.g. the hide module's parked record) is
    // dropped with the window. This is the ONLY fire on the withdraw route
    // (UnmapNotify / wm_close, XID still alive); a DestroyNotify already
    // fired it from events.zig first, and every hook is idempotent
    // (find-then-clear), so the repeat for the same window is harmless.
    for (window_mods) |mod| if (mod.onWindowGone) |f| f(win);
    if (build_options.has_workspaces) tracking.removeWindow(win);

    // Drop the MODEL entry, resolve the post-close focus target (fallback
    // tiers) and reconcile under one grab. Idempotent: a window withdrawn
    // via unmap+destroy runs this once per event; unregister/fallback no-op
    // on the second pass.
    actions.unmanage(&actx, win);
}

pub fn handleUnmapNotify(event: *const xcb.xcb_unmap_notify_event_t) void {
    if (isValidManagedWindow(event.window)) unmanageWindow(event.window);
}

pub fn handleDestroyNotify(event: *const xcb.xcb_destroy_notify_event_t) void {
    if (build_options.has_floating) actions.cancelDragForWindow(event.window);
    if (isValidManagedWindow(event.window)) unmanageWindow(event.window);
}

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
///   2. Covering: geometry is pinned to the screen rect (0, 0, screen_w,
///      screen_h, bw=0) -- sync seeds the covering winner with `ctx.screen` --
///      so the fixed value is returned directly. Handling it here avoids a
///      blocking xcb_get_geometry per ConfigureRequest, which matters
///      for video players that poll their size continuously.
///   3. True cache miss: one blocking xcb_get_geometry. Floating windows
///      never retiled; a fallback, not a hot path.
///
/// Returns null when even the fallback fails (window gone).
fn resolveConfigureGeometry(win: u32) ?utils.Rect {
    // Model/sync truth: floating base or last-sent ledger rect.
    if (@import("sync").truthRect(pipeline.model(), win)) |rect| {
        const border: u16 = (if (build_options.has_tiling) @import("core").borderWidth() else 0);
        return .{ .x = rect.x, .y = rect.y, .width = rect.width, .height = rect.height, .border_width = border };
    }

    if (providerOf(.isCoveringMode)) |wm| {
        if (wm.isCoveringMode.?(pipeline.model(), win)) {
            const screen = core.getState().screen;
            return .{
                .x = 0,
                .y = 0,
                .width = @intCast(screen.width_in_pixels),
                .height = @intCast(screen.height_in_pixels),
                .border_width = 0,
            };
        }
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

    // Deny min-size ConfigureRequests from the window being drag-resized. When
    // the WM sizes a floating window below its WM_NORMAL_HINTS minimum, the
    // client fires a ConfigureRequest back with its minimum dimensions;
    // honouring it races the next MotionNotify and causes visible flicker.
    // Echo the geometry the WM already applied so the client settles without
    // fighting the drag. (Protocol-side guard: must run before the model
    // decision, which has no view of in-flight drags.)
    if (build_options.has_floating and actions.isResizingWindow(win)) {
        const last = actions.getDragLastRect();
        if (last.width != 0) {
            sendConfigureNotify(win, .{ .x = last.x, .y = last.y, .width = last.width, .height = last.height, .border_width = borders.width() });
        } else {
            // No motion event yet in this drag, get_geometry round-trip so we
            // echo an accurate current size.
            sendSyntheticConfigureNotify(win);
        }
        return;
    }

    // DECISION goes through the model's single tested procedure (T13):
    // tiled/fullscreen/parked -> deny+echo; floating -> apply into the
    // model rect (which also stops reconcile snap-backs after a client
    // self-move); unknown windows stay honored (unmanaged clients are not
    // the WM's to override). Wire sends + cache recording remain here per
    // the check-layers allowlist; only the decision is centralized.
    const managed = pipeline.initialized and tracking.isManaged(win);
    if (managed) {
        const req: @import("model").ConfigureReq = .{
            .x = if (mask & xcb.XCB_CONFIG_WINDOW_X != 0) event.x else null,
            .y = if (mask & xcb.XCB_CONFIG_WINDOW_Y != 0) event.y else null,
            .width = if (mask & xcb.XCB_CONFIG_WINDOW_WIDTH != 0) event.width else null,
            .height = if (mask & xcb.XCB_CONFIG_WINDOW_HEIGHT != 0) event.height else null,
            .border_width = if (mask & xcb.XCB_CONFIG_WINDOW_BORDER_WIDTH != 0) event.border_width else null,
        };
        if (providerOf(.honorConfigureRequest)) |wm| {
            switch (wm.honorConfigureRequest.?(pipeline.model(), win, req)) {
                .geometry_applied => {
                    // Floating: the model stored exactly these values, so the
                    // wire send mirrors the request verbatim. BW rides along and
                    // is cached so dedup compares against server truth.
                    if (build_options.has_tiling and mask & xcb.XCB_CONFIG_WINDOW_BORDER_WIDTH != 0)
                        _ = wincache.cacheBorderWidth(win, event.border_width);
                    if (mask == xcb.XCB_CONFIG_WINDOW_BORDER_WIDTH) return;
                    sendRequestedConfigure(win, event, mask);
                },
                .border_only => {
                    // Tiled: geometry DENIED, BW honored. Cache + forward the
                    // border width ONLY; the old fall-through forwarded the
                    // whole mixed mask, moving denied-geometry windows until the
                    // next reconcile repaired them.
                    if (build_options.has_tiling)
                        _ = wincache.cacheBorderWidth(win, event.border_width);
                    if (mask != xcb.XCB_CONFIG_WINDOW_BORDER_WIDTH)
                        _ = xcb.xcb_configure_window(core.getState().conn, win, xcb.XCB_CONFIG_WINDOW_BORDER_WIDTH, &[_]u32{event.border_width});
                },
                .ignored => {
                    sendSyntheticConfigureNotify(win);
                },
            }
        }
        return;
    }

    sendRequestedConfigure(win, event, mask);
}

/// Builds the value list from `event` in XCB_CONFIG_WINDOW_* bit order and
/// issues the ConfigureWindow request.
fn sendRequestedConfigure(win: u32, event: *const xcb.xcb_configure_request_event_t, mask: u16) void {
    var values: [5]u32 = undefined;
    var n: usize = 0;
    if (mask & xcb.XCB_CONFIG_WINDOW_X != 0) {
        values[n] = utils.toXcbCoord(event.x);
        n += 1;
    }
    if (mask & xcb.XCB_CONFIG_WINDOW_Y != 0) {
        values[n] = utils.toXcbCoord(event.y);
        n += 1;
    }
    if (mask & xcb.XCB_CONFIG_WINDOW_WIDTH != 0) {
        values[n] = event.width;
        n += 1;
    }
    if (mask & xcb.XCB_CONFIG_WINDOW_HEIGHT != 0) {
        values[n] = event.height;
        n += 1;
    }
    if (mask & xcb.XCB_CONFIG_WINDOW_BORDER_WIDTH != 0) {
        values[n] = event.border_width;
        n += 1;
    }
    _ = xcb.xcb_configure_window(core.getState().conn, win, mask, &values);
}

inline fn suppressSpawnCrossing(root_x: i16, root_y: i16) bool {
    if (focus.getSuppressReason() != .window_spawn) return false;
    // Consume the suppression flag unconditionally: it is a one-shot guard that
    // only applies to the first crossing event after a spawn. Clearing it
    // only when the cursor had moved would instead suppress all future
    // hover-focus events if the cursor stayed at the exact spawn pixel.
    focus.setSuppressReason(.none);
    // `spawn_cursor` was intended to record the spawn
    // position but was never implemented, so the (0,0) comparison only fires
    // when the cursor is parked at the screen origin. Kept verbatim
    // (harness-pinned: S16).
    return root_x == 0 and root_y == 0;
}

/// Attempt to focus `win` via the hover (EnterNotify) path.
///
/// Guards against workspace membership and hidden state before calling
/// focus.grabFocus(.mouse_enter). The .mouse_enter reason is the direct
/// EnterNotify path: lightweight, no raise, no confirm.
inline fn maybeFocusWindow(win: u32) void {
    if (!isOnCurrentWorkspace(win)) return;
    if (providerOf(.isWindowHidden)) |wm| {
        if (wm.isWindowHidden.?(pipeline.model(), win)) return;
    }
    debug.info("[MAYBE_FOCUS] 0x{x}", .{win});
    focus.grabFocus(win, .mouse_enter);
}

pub fn handleEnterNotify(event: *const xcb.xcb_enter_notify_event_t) void {
    focus.setLastEventTime(event.time);
    if (event.mode != xcb.XCB_NOTIFY_MODE_NORMAL or
        event.detail == xcb.XCB_NOTIFY_DETAIL_INFERIOR)
        return;
    if (build_options.has_floating and actions.isDragging()) return;
    if (suppressSpawnCrossing(event.root_x, event.root_y)) return;
    if (focus.shouldSuppressEnterNotify()) return;
    maybeFocusWindow(findManagedWindow(core.getState().conn, event.event, tracking.isManaged));
}

pub fn handleLeaveNotify(event: *const xcb.xcb_leave_notify_event_t) void {
    focus.setLastEventTime(event.time);
    if (event.event != core.getState().root) return;
    if (event.mode != xcb.XCB_NOTIFY_MODE_NORMAL) return;
    if (build_options.has_floating and actions.isDragging()) return;
    if (suppressSpawnCrossing(event.root_x, event.root_y)) return;
    // When child is zero the pointer left to an area not covered by any window.
    if (event.child == 0) return;
    // Guard against unmanaged subwindows (e.g. embedded GTK widgets): a root
    // LeaveNotify with non-zero child doesn't guarantee a managed toplevel.
    // Walk up to the managed toplevel, consistent with handleEnterNotify's
    // findManagedWindow.
    maybeFocusWindow(findManagedWindow(core.getState().conn, event.child, tracking.isManaged));
}

/// Refresh one half of CachedProps after a PropertyNotify, keeping the other
/// half from cache to avoid a redundant round-trip. When the old half is not
/// cached, both halves are queried live; this fallback costs one extra XCB
/// call per window until populateFocusCacheFromCookies seeds the cache.
fn refreshCachedPropHalf(conn: core.Connection, win: u32, atom: u32) void {
    const is_protocols = atom == utils.getAtomOrZero("WM_PROTOCOLS");

    const existing: ?CachedProps = if (!state.?.cache_ready) null else blk: {
        break :blk if (state.?.cache_slots.indexOfById(win)) |i| state.?.cache_slots.items[i].props else null;
    };

    const wm_delete = if (is_protocols)
        queryWMProtocolsProps(conn, win).wm_delete
    else if (existing) |p|
        p.wm_delete
    else
        queryWMProtocolsProps(conn, win).wm_delete;

    const accepts_input = if (!is_protocols)
        queryWMHintsAcceptsInput(conn, win)
    else if (existing) |p|
        p.accepts_input
    else
        queryWMHintsAcceptsInput(conn, win);

    putCachedProps(win, .{ .accepts_input = accepts_input, .wm_delete = wm_delete });
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

    if (event.atom == utils.getAtomOrZero("WM_PROTOCOLS") or
        event.atom == xcb.XCB_ATOM_WM_HINTS)
    {
        refreshCachedPropHalf(conn, event.window, event.atom);
    }
}

inline fn clampToU16(v: u32) u16 {
    return @intCast(@min(v, std.math.maxInt(u16)));
}

// Extract a pair of consecutive u16 fields when the flag is set and enough
// fields are present. Shared by max_size and resize_inc extraction which
// share the same 2-field pattern.
const SizePair = struct { width: u16, height: u16 };

fn extractFieldPair(fields: [*]const u32, field_count: u32, want: bool, comptime off: usize) SizePair {
    if (want and field_count >= off + 2) return .{ .width = clampToU16(fields[off]), .height = clampToU16(fields[off + 1]) };
    return .{ .width = 0, .height = 0 };
}

/// Called whenever WM_NORMAL_HINTS changes post-map (see handlePropertyNotify).
/// The map-time path no longer goes through here: handleMapRequest fires the
/// WM_NORMAL_HINTS cookie together with its other property queries and drains
/// via parseSizeHintsIntoCache, saving one round trip per spawn.
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

    // The MODEL copy of size hints must never go stale, since layouts read
    // Entry.size_hints via engine.HintsView. The wincache entry is only the
    // pre-registration staging area (actions.mapRequest bridges it into the
    // freshly created model entry); once registered, the model write below is
    // the only truth and the wincache copy is never read again.
    const hints: @import("model").SizeHints = .{
        .max_width = max_pair.width,
        .max_height = max_pair.height,
        .inc_width = inc_pair.width,
        .inc_height = inc_pair.height,
        .min_aspect = min_aspect,
        .max_aspect = max_aspect,
    };
    if (pipeline.initialized) {
        if (pipeline.model().store.getPtr(win)) |e| {
            e.size_hints = hints;
            return;
        }
    }
    wincache.cacheSizeHints(win, hints); // pre-registration staging bridge only
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
        if (comptime skip_tiled) {
            if (build_options.has_tiling and tilingActive() and tracking.isTiledMode(win)) continue;
        }
        const color = borders.color(win);
        // Same CacheMap dedup in both sweep variants: windows with a cache
        // entry skip the XCB call when their color is unchanged; uncached
        // ones get an entry created and colored in one step.
        if (wincache.sendBorderColorIfChanged(win, color)) continue;
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

/// Warn-once latches for SW-10 client-message diagnostics (see
/// handleClientMessage): pager loops would otherwise flood the log.
var warned_active_unimplemented = false;
var warned_state_unmanaged = false;

pub fn handleClientMessage(event: *const xcb.xcb_client_message_event_t) void {
    if (event.format != 32) return;

    // Unhonorable pager requests are dropped silently otherwise; both warns
    // fire once per process so a looping pager cannot flood the log.
    const net_active = utils.getAtomOrZero("_NET_ACTIVE_WINDOW");
    if (net_active != 0 and event.type == net_active) {
        if (!warned_active_unimplemented) {
            warned_active_unimplemented = true;
            debug.warn("Ignoring _NET_ACTIVE_WINDOW request for 0x{x}: EWMH activation is not implemented", .{event.window});
        }
        return;
    }

    const net_wm_state = utils.getAtomOrZero("_NET_WM_STATE");
    if (net_wm_state == 0 or event.type != net_wm_state) return;

    const fs_atom = utils.getAtomOrZero("_NET_WM_STATE_FULLSCREEN");
    if (fs_atom == 0) return;
    const prop1 = event.data.data32[1];
    const prop2 = event.data.data32[2];
    if (prop1 != fs_atom and prop2 != fs_atom) return;

    const win = event.window;
    if (!isValidManagedWindow(win)) {
        if (!warned_state_unmanaged) {
            warned_state_unmanaged = true;
            debug.warn("Ignoring _NET_WM_STATE request for unmanaged window 0x{x}", .{win});
        }
        return;
    }

    const action = event.data.data32[0];
    const is_fs = if (providerOf(.isCoveringMode)) |wm| wm.isCoveringMode.?(pipeline.model(), win) else false;
    const should_enter = switch (action) {
        1 => true, // _NET_WM_STATE_ADD
        0 => false, // _NET_WM_STATE_REMOVE
        2 => !is_fs, // _NET_WM_STATE_TOGGLE
        else => return,
    };
    if (should_enter == is_fs) return;
    // PIPELINE: model-path transition; the transition stays on the single
    // source of truth.
    actions.fullscreenToggleWindow(win);
}

/// Called on config reload.
pub fn reloadBorders() void {
    for (tracking.allWindows()) |entry| borders.apply(core.getState().conn, entry.win);
}
