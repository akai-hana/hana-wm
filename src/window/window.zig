//! X11-facing window protocol layer: the event boundary for managed toplevels.
//! Translates MapRequest / UnmapNotify / DestroyNotify / ConfigureRequest /
//! Enter-LeaveNotify / PropertyNotify / ClientMessage into model transitions
//! (commands, focus) and owns what surrounds them: child-to-toplevel
//! resolution for Electron/Qt/GTK clients and WM_NORMAL_HINTS parsing. The
//! admission policy itself (WM_CLASS workspace/float rules, the spawn queue,
//! the five-cookie admission pipeline) and boot-time adoption of pre-existing
//! root children live in admission.zig.
//!
//! The event handlers themselves live in protocol/ beside this file --
//! client_events.zig (ConfigureRequest compliance, EWMH ClientMessage,
//! Enter/Leave) -- with the pure border helpers in protocol/borders.zig and
//! the per-batch border sweeps in sync/border_sweeps.zig;
//! window.zig re-exports all of them so `window.*` remains the single
//! dispatch surface. Also this layer's stable
//! facade: window.zig re-exports the icccm protocol surface and the
//! window-module hook dispatch from registry.zig (providerOf, callHook*,
//! etc.) so `window.*` is the import surface instead of
//! icccm/registry/contract.

const std = @import("std");

const core = @import("core");
const xcb = core.xcb;
const log = std.log.scoped(.window);
const query = @import("query");
const focus = @import("focus");
const icccm = @import("icccm");
const reply_mod = @import("reply");
const build_options = @import("build_options");
const window_mods = @import("window_modules").modules;
const registry = @import("registry");
const title_cache = @import("title_cache");
const borders = @import("borders");
const border_sweeps = @import("border_sweeps");
const client_events = @import("client_events");
const pipeline = @import("pipeline");
const admission = @import("admission");
const model_mod = @import("model");
const window_state_ops = @import("window_state_ops");
const idmap = @import("idmap");

const atoms = @import("atoms");
const requests = @import("requests");
const reconcile_tails = @import("reconcile_tails");
const reconcile = @import("reconcile");

// Window-module hook dispatch lives in registry.zig (the binding layer);
// window.zig re-exports the five top-level wrappers plus the six family
// namespaces (D12/P2-54) so `window.*` stays the stable external facade.
// Inside `src/window/**`, import `registry` directly.
pub const providerOf = registry.providerOf;
pub const callHook = registry.callHook;
pub const callHookBool = registry.callHookBool;
pub const dispatchAll = registry.dispatchAll;
pub const dispatchFirstTrue = registry.dispatchFirstTrue;
pub const hide = registry.hide;
pub const covering = registry.covering;
pub const workspaces = registry.workspaces;
pub const floating = registry.floating;
pub const drag = registry.drag;
pub const command = registry.command;

// The command surface, re-exported through this facade. Always-present
// transitions are re-exported as the concrete functions they are;
// optional-module commands are reached through `callHook` above, so this
// facade never names an optional module. Tests and the bar import `window`
// and never the owning file.
pub const mapRequest = admission.mapRequest;
pub const cycleLayoutKind = reconcile_tails.cycleLayoutKind;
pub const stepVariantDir = reconcile_tails.stepVariantDir;
pub const adjustPrimaryWidthAction = reconcile_tails.adjustPrimaryWidthAction;
pub const adjustPrimaryCount = reconcile_tails.adjustPrimaryCount;
pub const adjustSecondaryBalance = reconcile_tails.adjustSecondaryBalance;
pub const swapPrimaryAction = reconcile_tails.swapPrimaryAction;
pub const moveFocused = reconcile_tails.moveFocused;
pub const viewportStep = reconcile_tails.viewportStep;
pub const snapViewportFocusedDuty = reconcile_tails.snapViewportFocusedDuty;

// Focus-property cache + ICCCM 4.1.7 input-model surface lives in
// focus.zig (the cache's owner); the WM_DELETE verdict and cookie helpers
// stay in icccm.zig. window.zig re-exports the pub API so `window.*` stays
// the stable external facade.
pub const supportsWMDeleteCached = icccm.supportsWMDeleteCached;
pub const closeViaProtocol = icccm.closeViaProtocol;
// Event handlers and border sweeps live beside this file:
// client_events.zig (ConfigureRequest, EWMH ClientMessage, Enter/Leave),
// border_sweeps.zig (per-batch sweeps).
// window.* stays the dispatch surface events.zig, input, reload and the
// tests import, so they reach the handlers without naming those files.
pub const handleConfigureRequest = client_events.handleConfigureRequest;
pub const handleEnterNotify = client_events.handleEnterNotify;
pub const handleLeaveNotify = client_events.handleLeaveNotify;
// FocusIn reassert lives with the focus protocol (focus.zig owns the
// prepare/apply machinery it drives); re-exported here like the rest of the
// event surface.
pub const handleFocusIn = focus.handleFocusIn;
pub const handleClientMessage = client_events.handleClientMessage;
pub const updateWorkspaceBorders = border_sweeps.updateWorkspaceBorders;
pub const updateFloatingWindowBorders = border_sweeps.updateFloatingWindowBorders;
pub const reloadBorders = border_sweeps.reloadBorders;

/// Maximum depth when walking the X11 window tree in findManagedWindow.
/// Public as the CONTRACT the walk is bounded by: find_managed_test pins
/// one parent-query per level against it (P1-36).
pub const max_window_tree_depth: usize = 10;

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

/// Child XID -> managed toplevel cache, backing findManagedWindow's fast path
/// below. A fixed flat array (Electron nests at most 3-5 children per app);
/// keyed storage makes the hit O(1) with no capacity cliff, since the lookup
/// sits on the slow path of a BLOCKING xcb_query_tree round trip.
/// Child-window cache ceiling: bounds findManagedWindow's child->toplevel
/// rows (a flat array; Electron/Qt nest at most a handful of children per app).
const capacity: usize = 64;

/// child XID -> managed toplevel (IdMap, not a BoundedList).
var cache: idmap.IdMap(u32, capacity) = .{};

/// Re-arm for a deinit()+init() cycle (window.init's reset discipline).
pub fn reset() void {
    cache = .{};
    prop_dirty = .{};
}

/// Record that `child` resolves to `managed` so future tree walks are skipped.
pub fn put(child: u32, managed: u32) void {
    if (child == managed) return; // direct hit, not a child, nothing to cache
    // At cap, put returns false and the entry is dropped; the tree walk
    // fallback is always correct, so a miss only costs the walk it would have
    // paid anyway.
    _ = cache.put(child, managed);
}

/// Cached child->toplevel resolution; null on miss (fresh tree walk).
pub fn get(child: u32) ?u32 {
    return cache.get(child);
}

/// Called from unmanageWindow so stale child entries don't linger.
///
/// A value-keyed sweep, which is the one thing keyed storage does NOT make
/// O(1): collect first, then remove. Removing inside the iteration would
/// tombstone slots the live iterator is walking over.
pub fn evictFor(managed_win: u32) void {
    var stale: [capacity]u32 = undefined;
    var n: usize = 0;
    var it = cache.iterator();
    while (it.next()) |item| {
        if (item.val.* != managed_win) continue;
        stale[n] = item.key;
        n += 1;
    }
    for (stale[0..n]) |child| _ = cache.remove(child);
}

/// One step of a window-tree walk: the parent query for `current` either
/// failed (`fail`), reached the top of the tree (`stop` -- the parent is the
/// root or 0), or yields the next level to try.
///
/// Test seam (P1-36): the walker core below takes this step function, so the
/// "at most one blocking round trip per level, none on the fast paths" bound
/// is pinned in find_managed_test without a server. Production binds
/// `windowParentOf`, which pays one xcb_query_tree round trip per step.
pub const ParentStep = union(enum) { fail, stop, parent: u32 };

/// Adapter signature for `findManagedWindowWith`; see `ParentStep`.
pub const ParentOf = *const fn (ctx: *anyopaque, current: u32) ParentStep;

/// Production adapter for `findManagedWindowWith`: one blocking
/// xcb_query_tree round trip per step. `ctx` is a `*WalkCtx`.
fn windowParentOf(raw: *anyopaque, current: u32) ParentStep {
    const ctx: *WalkCtx = @ptrCast(@alignCast(raw));
    const tree_reply = xcb.xcb_query_tree_reply(
        ctx.conn,
        xcb.xcb_query_tree(ctx.conn, current),
        null,
    ) orelse return .fail;
    defer std.c.free(tree_reply);
    if (tree_reply.*.parent == tree_reply.*.root or tree_reply.*.parent == 0) return .stop;
    return .{ .parent = tree_reply.*.parent };
}

const WalkCtx = struct { conn: core.Connection };

/// The tree-walk core behind `findManagedWindow` with the parent query
/// injected (P1-36 test seam). Semantics identical to the pre-split
/// function: a fail/stop/exhaust walk returns the START window untouched,
/// a managed hit `put`s the start->hit mapping and returns the hit.
///
/// Fast paths: direct managed window (most common), then the child-window
/// cache (common for Electron/Qt after the first hover, zero queries).
/// Slow path: at most `max_window_tree_depth` steps, only on the first
/// hover over a new child window.
pub fn findManagedWindowWith(
    win: u32,
    is_managed: *const fn (u32) bool,
    ctx: *anyopaque,
    parent_of: ParentOf,
) u32 {
    if (is_managed(win)) return win;

    // Cache hit; validate the cached toplevel is still managed (it may have
    // been unmanaged since the entry was written), else fall through.
    if (get(win)) |managed| {
        if (is_managed(managed)) return managed;
    }

    var current = win;
    for (0..max_window_tree_depth) |_| {
        switch (parent_of(ctx, current)) {
            .fail => return win,
            .stop => return win,
            .parent => |p| {
                current = p;
                if (is_managed(current)) {
                    put(win, current);
                    return current;
                }
            },
        }
    }
    return win;
}

/// Walks up the X11 window tree from `win` to find the managed toplevel.
///
/// Fast paths: direct managed window (most common), then the child-window
/// cache above (common for Electron/Qt after the first hover, zero XCB
/// calls). Slow path: one blocking xcb_query_tree round-trip per level
/// (2-3 for Electron), only on the first hover over a new child window,
/// bounded by `max_window_tree_depth`. The walk core sits behind the
/// `findManagedWindowWith` seam so that bound is testable (P1-36;
/// find_managed_test.zig).
pub fn findManagedWindow(conn: core.Connection, win: u32, is_managed: *const fn (u32) bool) u32 {
    var ctx: WalkCtx = .{ .conn = conn };
    return findManagedWindowWith(win, is_managed, &ctx, windowParentOf);
}

pub fn init(alloc: std.mem.Allocator) !void {
    // Reset every module-local cache to its zero value so that a deinit() +
    // init() cycle (session restart, test harness) starts from a clean slate
    // rather than carrying over whatever the previous cycle left behind.
    // Admission sub-state and the other reset disciplines live beside their
    // owners (admission.init, focus.reset, client_events.reset, ...).
    reset();
    pipeline.clearFocusMru();
    focus.init();
    title_cache.init(alloc);
    // Uniform lifecycle dispatch: each compiled-in sub-system's init
    // runs, absent modules aren't in the array, so nothing else needs
    // a has_* guard. The fallible fan-out is stated here (init is its
    // only user; contract's two dispatch primitives are providerOf +
    // callAll).
    for (window_mods) |wm| if (wm.init) |f| try f();
    focus.reset();
    // Admission sub-state (spawn queue, rules maps): reset and rules-map
    // rebuild live with the admission policy in admission.zig.
    admission.init(alloc);
    // Client-message warn latches live in client_events.zig; re-arm them
    // with the rest of the reset discipline.
    client_events.reset();
}

pub fn deinit() void {
    title_cache.deinit();
    // Uniform lifecycle dispatch: every compiled-in sub-system's
    // deinit runs, absent modules aren't in the array.
    dispatchAll(.deinit, .{});
    // Free the admission sub-state's heap-backed memory (spawn queue,
    // rules maps) before its reset wipes the struct.
    admission.deinit();
    // Clear the focus-property cache before focus deinit,
    // whose managed-window sweeps must not encounter a partially-valid
    // cache.
    focus.reset();
    focus.deinit();
    pipeline.clearFocusMru();
    // Empty the child cache so accidental post-deinit lookups MISS instead
    // of silently serving stale child->toplevel rows. init() re-arms it.
    reset();
}

// Window predicates

/// The "is this window ours" predicates live in query.zig (the state/query
/// facade); window.zig re-exports the manage predicate so `window.*` keeps
/// the API events.zig routes through from outside the layer. isInvalidWindow
/// is not re-exported (focus and configure reach query.zig).
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
/// over a fire-then-drain-per-property approach.
///
/// TIMING (gated by `-Dprofile-key`, mirroring workspaces.switchWorkspace): measures
/// MapRequest receipt -> the map queued by the reconcile inside
/// admission.admitWindow. `drain_us` is the dominant X round-trip (the reply
/// to the first of the pipelined batch); `after_drain_us` is pure local work
/// (workspace resolve, model register, reconcile/map). Both are logged once
/// per spawn.
pub fn handleMapRequest(event: *const xcb.xcb_map_request_event_t) void {
    const win = event.window;
    const conn = core.getState().conn;
    const t0: u64 = if (build_options.profile_key) core.monotonicNs() else 0;

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
    const t_fire: u64 = if (build_options.profile_key) core.monotonicNs() else 0;

    // Drain replies sequentially
    const decision = admission.resolveAdmissionDecision(current_ws, cookies.c_wm_class, cookies.c_net_wm_pid);
    const target_ws = decision.workspace;
    const on_current = target_ws.eql(current_ws);

    const drain = admission.drainAdmissionCookies(conn, win, cookies, false);
    const t_drain: u64 = if (build_options.profile_key) core.monotonicNs() else 0;

    // Shared admission policy (MapRequest path). The cookie firing above is
    // specific to the MapRequest event source; everything from here on (the
    // model registration + grabs + child-cache seeding) is identical to the
    // boot-time adoption path, so it lives in admission.admitWindow.
    admission.admitWindow(win, target_ws.index, on_current, decision.float, drain.size_hints, drain.transient_for);

    if (build_options.profile_key) {
        const t_map = core.monotonicNs();
        log.info("[TIMING] spawn 0x{x}: local={d}us drain={d}us after_drain={d}us total={d}us", .{
            win,
            @as(u64, @intCast(t_fire - t0)) / 1000,
            @as(u64, @intCast(t_drain - t_fire)) / 1000,
            @as(u64, @intCast(t_map - t_drain)) / 1000,
            @as(u64, @intCast(t_map - t0)) / 1000,
        });
    }
}

/// Unmanage tail: close/destroy/unmap of a managed window. Local
/// bookkeeping (covering record, caches, sub-system removes) has already
/// run; this drops the model entry and re-focuses. Inactive-workspace
/// geometry repairs ride the same global LastSent diff.
///
/// Lives here rather than in the admission half of the layer because it is
/// the OPPOSITE of admission: everything `mapRequest` builds, this unwinds.
pub fn unmanage(win: model_mod.WindowId) void {
    const m = pipeline.mut();
    // Covering and focus truth must be read BEFORE the unregister below
    // drops the model entry (after which no store query could recover it):
    // an onWindowGone binder mutating model focus or the covering record
    // would make them unreadable. The hooks that fire on this path touch
    // module-local stores only.
    const was_fs_current = if (model_mod.coveringWsOf(m, win)) |ws_id| ws_id.eql(m.current) else false;
    const was_focused = m.focused == win;

    window_state_ops.unregister(m, win);
    reconcile.forget(win); // X ids recycle; stale LastSent must not survive

    // Closing the current workspace's covering occupant releases the area;
    // retileWithFallback bumps the core fact so the bar reacts.
    reconcile_tails.retileWithFallback(m, was_fs_current, was_focused);
}

fn unmanageWindow(win: u32) void {
    // Covering truth is model-side (unmanage reads it); the module
    // store is queried through the registry below.
    focus.evict(win);

    // Evict child-cache entries pointing at this toplevel, so a new window
    // reusing the same XID can't be mis-identified as its child on the next
    // hover.
    evictFor(win);

    // Local bookkeeping, before the grab
    // title_cache.removeWindow unconditionally evicts the combined cache entry
    // (geometry + border + size hints). All three removes are pure local
    // bookkeeping (no X requests), so they run pre-grab, letting the
    // post-close focus target be resolved against win-free query state,
    // with its input model queried BEFORE the grab.
    title_cache.removeWindow(win);

    // Module cleanup on window drop: each compiled-in window module's
    // onWindowGone fires before the model entry is unregistered below, so
    // per-window bookkeeping (e.g. the minimize module's parked record) is
    // dropped with the window. This is the ONLY fire: DestroyNotify used to
    // pre-fire from events.zig as well (double fan-out, harmless because
    // every hook is idempotent find-then-clear) — that pre-fire is gone
    // (P1-40/D28) and the exactly-once contract is pinned by the P1-19
    // X-gated destroy test through registry.onWindowGone_fires.
    dispatchAll(.onWindowGone, .{win});

    // Drop the MODEL entry, resolve the post-close focus target (fallback
    // tiers) and reconcile under one grab. Idempotent: a window withdrawn
    // via unmap+destroy runs this once per event; unregister/fallback no-op
    // on the second invocation.
    //
    // unmanage owns the unregister.
    unmanage(win);
}

pub fn handleUnmapNotify(event: *const xcb.xcb_unmap_notify_event_t) void {
    if (isValidManagedWindow(event.window)) unmanageWindow(event.window);
}

pub fn handleDestroyNotify(event: *const xcb.xcb_destroy_notify_event_t) void {
    drag.dispatchAll(.cancelDragForWindow, .{event.window});
    if (isValidManagedWindow(event.window)) unmanageWindow(event.window);
}

pub fn handlePropertyNotify(event: *const xcb.xcb_property_notify_event_t) void {
    if (!isValidManagedWindow(event.window)) return;
    const conn = core.getState().conn;

    // Window title (_NET_WM_NAME / WM_NAME) and WM_NORMAL_HINTS are MARKED
    // here, not refreshed: a rename-looping client would otherwise pay two
    // blocking round trips per PropertyNotify, serialized in the event loop.
    // flushPropertyRefresh (batch end) fetches each marked window once,
    // converging on the property's final state. The WM remains the sole
    // owner of title freshness; the bar does no title property fetching.
    const net_wm_name = atoms.getAtomOrZero("_NET_WM_NAME");
    if (event.atom == xcb.XCB_ATOM_WM_NAME or (net_wm_name != 0 and event.atom == net_wm_name)) {
        if (prop_dirty.getPtr(event.window)) |bits| {
            bits.* |= prop_dirty_title;
        } else if (!prop_dirty.put(event.window, prop_dirty_title)) {
            // Set full (pathological): fall back to the immediate refresh so
            // the title still converges.
            if (title_cache.refreshTitle(conn, event.window)) core.window.bump();
        }
        return;
    }

    // WM_NORMAL_HINTS: refresh the model's size hints so max-size, resize-
    // increment, and aspect-ratio constraints stay accurate for apps that
    // update hints after map time (e.g. terminal emulators adjusting their
    // increment grid when the font changes).
    if (event.atom == xcb.XCB_ATOM_WM_NORMAL_HINTS) {
        if (prop_dirty.getPtr(event.window)) |bits| {
            bits.* |= prop_dirty_hints;
        } else if (!prop_dirty.put(event.window, prop_dirty_hints)) {
            refreshSizeHints(event.window);
        }
        return;
    }

    if (event.atom == atoms.getAtomOrZero("WM_PROTOCOLS") or
        event.atom == xcb.XCB_ATOM_WM_HINTS)
    {
        focus.refreshCachedPropHalf(conn, event.window, event.atom);
    }
}

// P1-12 coalesced property refresh: a PropertyNotify storm (rename-looping
// clients, hint-flapping toolkits) marks the window in this fixed-capacity
// set instead of paying a blocking round trip per event; flushPropertyRefresh
// runs once per event batch (events.zig's post-batch housekeeping, before the
// bar repaint) and refreshes each marked window exactly once, converging on
// the property's final state. The set mirrors title_cache's discipline:
// allocation-free IdMap, ceiling above the model store, set-full drops the
// mark and falls back to an immediate refresh so correctness never depends
// on capacity.
const prop_dirty_title: u2 = 1;
const prop_dirty_hints: u2 = 2;
var prop_dirty: idmap.IdMap(u2, idmap.max_window_cache) = .{};

/// Batch-end flush: one title refresh + one size-hints refresh per window
/// marked during the batch, then the set is cleared. A window unmapped or
/// destroyed mid-batch (no longer managed at flush time) is dropped without
/// a round trip -- the unmap path already cleared its title cache entry.
pub fn flushPropertyRefresh() void {
    if (prop_dirty.count() == 0) return;
    const conn = core.getState().conn;
    var it = prop_dirty.iterator();
    while (it.next()) |item| {
        const win = item.key;
        const bits = item.val.*;
        if (!query.isValidManagedWindow(win)) continue;
        if (bits & prop_dirty_title != 0) {
            if (title_cache.refreshTitle(conn, win)) core.window.bump();
        }
        if (bits & prop_dirty_hints != 0) refreshSizeHints(win);
    }
    // Full clear after iteration (IdMap iteration is slot-walking; removing
    // mid-loop would tombstone slots it still walks).
    prop_dirty.clear();
}

/// Test seam: how many windows the live dirty set covers (pre-flush).
pub fn pendingPropertyRefreshCount() usize {
    return prop_dirty.count();
}

fn refreshSizeHints(win: u32) void {
    const conn = core.getState().conn;
    const cookie = icccm.firePropQuery(conn, win, xcb.XCB_ATOM_WM_NORMAL_HINTS, xcb.XCB_ATOM_WM_SIZE_HINTS, reply_mod.wm_normal_hints_long_length);
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
    return reply_mod.parse(icccm.u32Values(reply), reply.*.value_len);
}
