//! X11-facing window protocol layer: the event boundary for managed toplevels.
//! Translates MapRequest / UnmapNotify / DestroyNotify / ConfigureRequest /
//! Enter-LeaveNotify / PropertyNotify / ClientMessage into model transitions
//! (actions, focus) and owns what surrounds them: child-to-toplevel
//! resolution for Electron/Qt/GTK clients and WM_NORMAL_HINTS parsing. The
//! admission policy itself (WM_CLASS workspace/float rules, the spawn queue,
//! the five-cookie admission pipeline) and boot-time adoption of pre-existing
//! root children live in admission.zig.
//!
//! The event handlers themselves are split by concern beside this file --
//! client_events.zig (ConfigureRequest compliance, EWMH ClientMessage,
//! Enter/Leave) -- and the per-batch border sweeps live in
//! protocol/borders.zig; window.zig re-exports all of them so
//! `window.*` remains the single dispatch surface. Also this layer's stable
//! facade: window.zig re-exports the icccm protocol surface and the
//! window-module hook dispatch from registry.zig (providerOf, callHook*,
//! etc.) so `window.*` is the import surface instead of
//! icccm/registry/contract.

const std = @import("std");

const core = @import("core");
const xcb = core.xcb;
const constants = @import("constants");
const log = @import("log");
const query = @import("query");
const focus = @import("focus");
const icccm = @import("icccm");
const hints = @import("hints");
const build_options = @import("build_options");
const window_mods = @import("window_modules").modules;
const registry = @import("registry");
const props = @import("props");
const wincache = @import("wincache");
const borders = @import("borders");
const child_cache = @import("child_cache");
const client_events = @import("client_events");
const pipeline = @import("pipeline");
const admission = @import("admission");
const actions = @import("actions");
const model_mod = @import("model");

const atoms = @import("atoms");
const requests = @import("requests");
const time = @import("time");

// Window-module hook dispatch lives in registry.zig (the binding layer);
// window.zig re-exports the five wrappers so `window.*` stays the stable
// external facade. Inside `src/window/**`, import `registry` directly.
pub const providerOf = registry.providerOf;
pub const callHook = registry.callHook;
pub const callHookBool = registry.callHookBool;
pub const dispatchAll = registry.dispatchAll;
pub const dispatchFirstTrue = registry.dispatchFirstTrue;

// ICCCM protocol surface (ICCCM 4.1.2/4.1.7) lives in icccm.zig; window.zig
// re-exports the pub API so `window.*` stays the stable external facade.
pub const peekInputModelResolved = icccm.peekInputModelResolved;
pub const provisionalResolution = icccm.provisionalResolution;
pub const supportsWMDeleteCached = icccm.supportsWMDeleteCached;
pub const sendWMTakeFocusKnown = icccm.sendWMTakeFocusKnown;
pub const discardProtocolCookie = icccm.discardProtocolCookie;

// Event handlers and border sweeps split out of this file:
// client_events.zig (ConfigureRequest, EWMH ClientMessage, Enter/Leave),
// protocol/borders.zig (per-batch sweeps).
// window.* stays the dispatch surface events.zig, input, reload and the
// tests import, so their call sites are untouched.
pub const handleConfigureRequest = client_events.handleConfigureRequest;
pub const handleEnterNotify = client_events.handleEnterNotify;
pub const handleLeaveNotify = client_events.handleLeaveNotify;
pub const handleClientMessage = client_events.handleClientMessage;
pub const updateWorkspaceBorders = borders.updateWorkspaceBorders;
pub const updateFloatingWindowBorders = borders.updateFloatingWindowBorders;
pub const reloadBorders = borders.reloadBorders;

const max_window_tree_depth = constants.max_window_tree_depth;

// Live geometry is read straight off the wire via getGeometry(). The
// last-sent geometry for X-side state (workspace-switch replay, minimize/
// restore) lives in the sync ledger and the model, not here.

/// Returns null if the window does not exist or is not yet mapped.
pub fn getGeometry(conn: core.Connection, win: u32) ?model_mod.Rect {
    const reply = xcb.xcb_get_geometry_reply(conn, xcb.xcb_get_geometry(conn, win), null) orelse
        return null;
    defer std.c.free(reply);
    return requests.rectFromXcb(reply);
}

/// Walks up the X11 window tree from `win` to find the managed toplevel.
///
/// Fast paths: direct managed window (most common), then the child-window
/// cache (common for Electron/Qt after the first hover, zero XCB calls) --
/// the cache itself lives in state/child_cache.zig. Slow path: one blocking
/// xcb_query_tree round-trip per level (2-3 for Electron), only on the first
/// hover over a new child window.
pub fn findManagedWindow(conn: core.Connection, win: u32, is_managed: *const fn (u32) bool) u32 {
    if (is_managed(win)) return win;

    // Cache hit; validate the cached toplevel is still managed (it may have
    // been unmanaged since the entry was written), else fall through.
    if (child_cache.get(win)) |managed| {
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
            child_cache.put(win, current);
            return current;
        }
    }
    return win;
}

pub fn init(alloc: std.mem.Allocator) !void {
    // Reset every module-local cache to its zero value so that a deinit() +
    // init() cycle (session restart, test harness) starts from a clean slate
    // rather than carrying over whatever the previous cycle left behind.
    // Admission sub-state and the other reset disciplines live beside their
    // owners (admission.init, props.reset, client_events.reset, ...).
    child_cache.reset();
    query.init();
    focus.init();
    wincache.init(alloc);
    // Uniform lifecycle dispatch: each compiled-in sub-system's init
    // runs, absent modules aren't in the array, so nothing else needs
    // a has_* guard. The fallible fan-out is stated here (init is its
    // only user; contract's two dispatch primitives are providerOf +
    // callAll, per the 6->2 collapse).
    for (window_mods) |wm| if (wm.init) |f| try f();
    props.reset();
    // Admission sub-state (spawn queue, rules maps): reset and rules-map
    // rebuild live with the admission policy in admission.zig.
    admission.init(alloc);
    // Client-message warn latches live in client_events.zig; re-arm them
    // with the rest of the reset discipline.
    client_events.reset();
}

pub fn deinit() void {
    wincache.deinit();
    // Uniform lifecycle dispatch: every compiled-in sub-system's
    // deinit runs, absent modules aren't in the array.
    dispatchAll(.deinit, .{});
    // Free the admission sub-state's heap-backed memory (spawn queue,
    // rules maps) before its reset wipes the struct.
    admission.deinit();
    // Clear the focus-property cache before focus/query deinit,
    // whose managed-window sweeps must not encounter a partially-valid
    // cache.
    props.reset();
    focus.deinit();
    query.deinit();
    // Empty the child cache so accidental post-deinit lookups MISS instead
    // of silently serving stale child->toplevel rows. init() re-arms it.
    child_cache.reset();
}

// Window predicates

/// The "is this window ours" predicates live in query.zig (the state/query
/// facade); window.zig re-exports the manage predicate so `window.*` keeps
/// the API events.zig routes through from outside the layer. isInvalidWindow
/// has no window.zig consumer left (focus and configure reach query.zig).
pub const isValidManagedWindow = query.isValidManagedWindow;

// Button grab management is owned by focus.zig (a focus-protocol concern).
// Off-workspace windows that need initial grab setup call focus.initWindowGrabs.

/// Workspace-rule resolution lives with the admission machinery
/// (admission.zig); re-exported here so the window module stays the
/// facade its callers route through.
pub const clampToValidWorkspace = admission.clampToValidWorkspace;

/// Handles a MapRequest by firing ALL property query cookies up-front, then
/// draining replies sequentially. Firing all five cookies before draining any
/// lets the X server process them in parallel, saving 2-3 blocking round trips
/// compared to the previous fire-then-drain-per-property approach.
///
/// TIMING (gated by `-Dprofile-key`, mirroring actions.switchTo): measures
/// MapRequest receipt -> the map queued by the reconcile inside
/// admission.admitWindow. `drain_us` is the dominant X round-trip (the reply
/// to the first of the pipelined batch); `after_drain_us` is pure local work
/// (workspace resolve, model register, reconcile/map). Both are logged once
/// per spawn.
pub fn handleMapRequest(event: *const xcb.xcb_map_request_event_t) void {
    const win = event.window;
    const conn = core.getState().conn;
    const t0: u64 = if (build_options.profile_key) time.monotonicNs() else 0;

    if (query.isManaged(win)) return; // double-manage guard, see query.isManaged

    // Snapshot the pointer position now so the crossing the map generates can
    // be matched against it (see focus.snapshotSpawnCursor /
    // suppressSpawnCrossing).
    focus.snapshotSpawnCursor(conn);

    // getCurrentWorkspace() returns ?u8; the value is already bounded to [0,255]
    // by the u8 return type, so no further clamping is needed.
    const current_ws = core.WorkspaceId.fromIndex(query.getCurrentWorkspace() orelse 0);

    admission.claimManagedEventMask(conn, win);

    // Fire ALL property cookies before draining any reply
    // The server processes all five requests in parallel while we do pure
    // local bookkeeping below.
    const cookies = admission.fireAdmissionCookies(conn, win);
    const t_fire: u64 = if (build_options.profile_key) time.monotonicNs() else 0;

    // Drain replies sequentially
    const decision = admission.resolveAdmissionDecision(current_ws, cookies.c_wm_class, cookies.c_net_wm_pid);
    const target_ws = decision.workspace;
    const on_current = target_ws.eql(current_ws);

    const size_hints = admission.drainAdmissionCookies(conn, win, cookies, false);
    const t_drain: u64 = if (build_options.profile_key) time.monotonicNs() else 0;

    // Shared admission policy (MapRequest path). The cookie firing above is
    // specific to the MapRequest event source; everything from here on (the
    // model registration + grabs + child-cache seeding) is identical to the
    // boot-time adoption path, so it lives in admission.admitWindow.
    admission.admitWindow(win, target_ws.index, on_current, decision.float, size_hints);

    if (build_options.profile_key) {
        const t_map = time.monotonicNs();
        log.info("[TIMING] spawn 0x{x}: local={d}us drain={d}us after_drain={d}us total={d}us", .{
            win,
            @as(u64, @intCast(t_fire - t0)) / 1000,
            @as(u64, @intCast(t_drain - t_fire)) / 1000,
            @as(u64, @intCast(t_map - t_drain)) / 1000,
            @as(u64, @intCast(t_map - t0)) / 1000,
        });
    }
}

fn unmanageWindow(win: u32) void {
    // Covering truth is model-side (actions.unmanage reads it); the module
    // store is queried through the registry below.
    props.evict(win);

    // Evict child-cache entries pointing at this toplevel, so a new window
    // reusing the same XID can't be mis-identified as its child on the next
    // hover.
    child_cache.evictFor(win);

    // Local bookkeeping, before the grab
    // wincache.removeWindow unconditionally evicts the combined cache entry
    // (geometry + border + size hints). All three removes are pure local
    // bookkeeping (no X requests), so they run pre-grab, letting the
    // post-close focus target be resolved against win-free query state,
    // with its input model queried BEFORE the grab.
    wincache.removeWindow(win);

    // Module cleanup on window drop: each compiled-in window module's
    // onWindowGone fires before the model entry is unregistered below, so
    // per-window bookkeeping (e.g. the minimize module's parked record) is
    // dropped with the window. This is the ONLY fire on the withdraw route
    // (UnmapNotify / wm_close, XID still alive); a DestroyNotify already
    // fired it from events.zig first, and every hook is idempotent
    // (find-then-clear), so the repeat for the same window is harmless.
    dispatchAll(.onWindowGone, .{win});

    // Drop the MODEL entry, resolve the post-close focus target (fallback
    // tiers) and reconcile under one grab. Idempotent: a window withdrawn
    // via unmap+destroy runs this once per event; unregister/fallback no-op
    // on the second invocation.
    //
    // actions.unmanage owns the unregister.
    actions.unmanage(win);
}

pub fn handleUnmapNotify(event: *const xcb.xcb_unmap_notify_event_t) void {
    if (isValidManagedWindow(event.window)) unmanageWindow(event.window);
}

pub fn handleDestroyNotify(event: *const xcb.xcb_destroy_notify_event_t) void {
    actions.cancelDragForWindow(event.window);
    if (isValidManagedWindow(event.window)) unmanageWindow(event.window);
}

pub fn handlePropertyNotify(event: *const xcb.xcb_property_notify_event_t) void {
    if (!isValidManagedWindow(event.window)) return;
    const conn = core.getState().conn;

    // Window title (_NET_WM_NAME / WM_NAME): refresh the WM-owned title cache
    // and bump the window fact so surfaces reading titles from the cache (the
    // bar) repaint. The WM is now the sole owner of title freshness; the bar
    // does no title property fetching at all.
    const net_wm_name = atoms.getAtomOrZero("_NET_WM_NAME");
    if (event.atom == xcb.XCB_ATOM_WM_NAME or (net_wm_name != 0 and event.atom == net_wm_name)) {
        if (wincache.refreshTitle(conn, event.window)) core.window.bump();
        return;
    }

    // WM_NORMAL_HINTS: refresh the model's size hints so max-size, resize-
    // increment, and aspect-ratio constraints stay accurate for apps that
    // update hints after map time (e.g. terminal emulators adjusting their
    // increment grid when the font changes).
    if (event.atom == xcb.XCB_ATOM_WM_NORMAL_HINTS) {
        refreshSizeHints(event.window);
        return;
    }

    if (event.atom == atoms.getAtomOrZero("WM_PROTOCOLS") or
        event.atom == xcb.XCB_ATOM_WM_HINTS)
    {
        icccm.refreshCachedPropHalf(conn, event.window, event.atom);
    }
}

fn refreshSizeHints(win: u32) void {
    const conn = core.getState().conn;
    const cookie = icccm.firePropQuery(conn, win, xcb.XCB_ATOM_WM_NORMAL_HINTS, xcb.XCB_ATOM_WM_SIZE_HINTS, hints.wm_normal_hints_long_length);
    // Always drain the reply (parseSizeHints consumes and frees it), then
    // apply: PropertyNotify refresh, post-registration -- the model entry is
    // the one store (layouts read Entry.size_hints via contract's HintsView).
    // A reply that arrives with no entry to write has nothing to refresh --
    // the admission cookie drain re-reads the property for a window about to
    // be registered, so dropping the value here cannot lose hints.
    const parsed = parseSizeHints(cookie) orelse return;
    if (core.isModelReady()) {
        if (pipeline.mut().store.getPtr(win)) |e| e.size_hints = parsed;
    }
}

/// Parses a WM_NORMAL_HINTS reply into the model's SizeHints. Pure reply
/// read: no cache, no model write, no window identity needed. The ADMISSION
/// path threads the value to mapRequest as a parameter (the model entry does
/// not exist yet when the reply drains), and the PropertyNotify refresh path
/// writes it into the registered entry. Null when the property is malformed
/// or declares no constraint (the entry keeps the empty default).
pub fn parseSizeHints(
    cookie: xcb.xcb_get_property_cookie_t,
) ?model_mod.SizeHints {
    const reply = xcb.xcb_get_property_reply(core.getState().conn, cookie, null) orelse return null;
    defer std.c.free(reply);
    if (reply.*.format != 32 or reply.*.value_len < 5) return null;
    return hints.parse(icccm.u32Values(reply), reply.*.value_len);
}
