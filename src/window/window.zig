//! X11-facing window protocol layer: the event boundary for managed toplevels.
//! Translates MapRequest / UnmapNotify / DestroyNotify / ConfigureRequest /
//! Enter-LeaveNotify / PropertyNotify / ClientMessage into model transitions
//! (actions, focus) and owns what surrounds them: child-to-toplevel
//! resolution for Electron/Qt/GTK clients, WM_NORMAL_HINTS parsing, and the
//! per-batch border sweep. The admission policy itself (WM_CLASS
//! workspace/float rules, the spawn queue, the five-cookie admission
//! pipeline) and boot-time adoption of pre-existing root children live in
//! admission.zig.
//!
//! Also this layer's stable facade: window.zig re-exports the icccm protocol
//! surface and the window-module hook dispatch (providerOf, callHook*, etc.) so
//! `window.*` is the import seam instead of icccm/contract.

const std = @import("std");

const core = @import("core");
const xcb = core.xcb;
const constants = @import("constants");
const log = @import("log");
const tracking = @import("tracking");
const focus = @import("focus");
const icccm = @import("icccm");
const hints = @import("hints");
const build_options = @import("build_options");
const window_mods = @import("window_modules").modules;
const usable_area_mod = @import("usable_area");
const wincache = @import("wincache");
const borders = @import("borders");
const pipeline = @import("pipeline");
const admission = @import("admission");
const actions = @import("actions");
const contract = @import("contract");
const model_mod = @import("model");

const atoms = @import("atoms");
const idmap = @import("idmap");
const requests = @import("requests");
const time = @import("time");
const ledger = @import("ledger");
const reconcile = @import("reconcile");

// BINDING-LAYER SURFACE (KISS audit note): the five dispatch wrappers below
// (providerOf/callHook/callHookBool/dispatchAll/dispatchFirstTrue) are thin
// on purpose. Collapsing them would spread providerOf + @call pairs across
// every dispatch call site, and folding them back into contract would
// re-create the comptime-generic helpers the contract 6->2 dispatch
// collapse deliberately removed. Further collapse: considered, rejected.

/// Registry lookup for the hook `field` (see `contract.providerOf`), null when
/// no module binds it; shared by the window layer (actions/borders alias this).
/// Thin typed forward onto the single canonical `contract` dispatch family
/// (two primitives: providerOf + callAll).
pub fn providerOf(
    comptime field: std.meta.FieldEnum(contract.WindowModule),
) ?*const contract.WindowModule {
    return contract.providerOf(contract.WindowModule, window_mods[0..], field);
}

/// First-match dispatch: invokes the first module that binds `field`, nothing
/// when none does (the "adopt by name" seam for single-binder hooks, see
/// `single_binder_hooks`). providerOf + invoke stated here -- the shape had
/// this one consumer, so it lives at the binding layer rather than as a
/// comptime-generic helper in contract (the 6->2 collapse).
pub fn callHook(
    comptime field: std.meta.FieldEnum(contract.WindowModule),
    args: anytype,
) void {
    if (providerOf(field)) |m| @call(.auto, @field(m, @tagName(field)).?, args);
}

/// Like callHook but returns the first provider's hook result; false when no
/// module binds the hook.
pub fn callHookBool(
    comptime field: std.meta.FieldEnum(contract.WindowModule),
    args: anytype,
) bool {
    if (providerOf(field)) |m| return @call(.auto, @field(m, @tagName(field)).?, args);
    return false;
}

/// Runs a hook on EVERY module that binds it, not just the first (callHook
/// returns after the first provider). Dispatch loops shared by actions.
pub fn dispatchAll(
    comptime field: std.meta.FieldEnum(contract.WindowModule),
    args: anytype,
) void {
    contract.callAll(contract.WindowModule, window_mods[0..], field, args);
}

/// Like dispatchAll but returns true at the first provider whose hook does;
/// false when no provider binds the hook or none returns true. The any-true
/// scan is stated here (one consumer per owner layer -- see the dispatch-
/// primitives note in contract.zig); the fallible fan-out variant was inlined
/// at its single lifecycle-init call site.
pub fn dispatchFirstTrue(
    comptime field: std.meta.FieldEnum(contract.WindowModule),
    args: anytype,
) bool {
    for (window_mods) |m| {
        if (@field(m, @tagName(field))) |f| if (@call(.auto, f, args)) return true;
    }
    return false;
}

/// True when `win` holds covering intent (12.4: a model query -- see
/// contract.WindowModule for why the covering-mode hook is gone).
pub fn isCoveringMode(m: *const model_mod.Model, win: u32) bool {
    return model_mod.isCovering(m, win);
}

// ICCCM protocol surface (ICCCM 4.1.2/4.1.7) lives in icccm.zig; window.zig
// re-exports the pub API so `window.*` stays the stable external facade.
pub const peekInputModelResolved = icccm.peekInputModelResolved;
pub const provisionalResolution = icccm.provisionalResolution;
pub const supportsWMDeleteCached = icccm.supportsWMDeleteCached;
pub const sendWMTakeFocusKnown = icccm.sendWMTakeFocusKnown;
pub const discardProtocolCookie = icccm.discardProtocolCookie;

const max_window_tree_depth = constants.max_window_tree_depth;

// All mutable window-module state is grouped into a single State struct
// (mirroring the pattern focus.zig uses) so init()/deinit() each reset
// everything in one assignment, and a deinit()+init() cycle can't leave a
// stale field behind. The admission sub-state (spawn queue, rules maps,
// spawn-cursor snapshot) lives in admission.zig beside the policy that
// reads it. Still exactly one context per process, this is for
// reset discipline, not multi-context support.
const State = struct {
    /// Caller-owned scratch for tracking.allWindowsInto (border sweeps).
    snapshot: [model_mod.store_capacity]tracking.Entry = undefined,

    // Warn-once latches for client-message diagnostics (see
    // handleClientMessage): a looping pager would otherwise flood the log.
    // One latch per message class -- two unrelated warnings sharing a latch
    // meant whichever fired first silenced the other for the process's life.
    // All live in State so `state = .{}` in init() resets them together.
    warned_unmanaged_fs_request: bool = false,
    warned_active_ignore: bool = false,
    warned_unmanaged_state: bool = false,

    // Child XID -> managed toplevel XID (see "Child window resolution").
    /// child XID -> managed toplevel (9.7: IdMap, not a BoundedList).
    ///
    /// A BoundedList needed a linear scan per lookup, and the lookup sits on
    /// the slow path of a BLOCKING xcb_query_tree round trip -- a list miss
    /// cost a linear scan, a hit cost a round trip saved, and at cap the
    /// append silently dropped so the walk repeated forever. Keyed storage
    /// makes the hit O(1) with no capacity cliff.
    child_cache: idmap.IdMap(u32, child_cache_capacity) = .{},
};

var state: ?State = null;

/// Logs `fmt` at warn level at most once per process, arming `latch` (a field
/// of `State`, so an init() reset re-arms every diagnostic together). The
/// client-message handlers are fed by EWMH pagers that can loop forever, and
/// one shared latch between two message classes meant the second warning could
/// never fire after the first.
fn warnOnce(latch: *bool, comptime fmt: []const u8, args: anytype) void {
    if (latch.*) return;
    latch.* = true;
    log.warn(fmt, args);
}

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

// Child window resolution
//
// Electron/Qt/GTK toolkits render into child windows beneath their managed
// toplevel, so ButtonPress/EnterNotify often land on a child, not the window
// we manage. findManagedWindow walks the X11 tree upward (each step a blocking
// round-trip) to find the managed ancestor; state.child_cache maps child XID
// -> managed toplevel XID so repeat hovers cost zero XCB calls. Entries are
// evicted when their toplevel is unmanaged (evictChildCache). A fixed flat
// array is enough: Electron nests at most 3-5 children per app.

// Child-window cache ceiling: bounds findManagedWindow's child->toplevel rows
// (a flat array; Electron/Qt nest at most a handful of children per app).
const child_cache_capacity: usize = 64;

/// Record that `child` resolves to `managed` so future tree walks are skipped.
fn cacheChildWindow(child: u32, managed: u32) void {
    if (child == managed) return; // direct hit, not a child, nothing to cache
    // At cap, put returns false and the entry is dropped; the tree walk
    // fallback is always correct, so a miss only costs the walk it would have
    // paid anyway.
    _ = state.?.child_cache.put(child, managed);
}

/// Called from unmanageWindow so stale child entries don't linger.
///
/// A value-keyed sweep, which is the one thing keyed storage does NOT make
/// O(1): collect first, then remove. Removing inside the iteration would
/// tombstone slots the live iterator is walking over.
fn evictChildCache(managed_win: u32) void {
    var stale: [child_cache_capacity]u32 = undefined;
    var n: usize = 0;
    var it = state.?.child_cache.iterator();
    while (it.next()) |item| {
        if (item.val.* != managed_win) continue;
        stale[n] = item.key;
        n += 1;
    }
    for (stale[0..n]) |child| _ = state.?.child_cache.remove(child);
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
    if (state.?.child_cache.get(win)) |managed| {
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

pub fn init(alloc: std.mem.Allocator) !void {
    // Reset every field to its zero value so that a deinit() + init()
    // cycle (session restart, test harness) starts from a clean slate
    // rather than carrying over whatever the previous cycle left
    // behind.
    state = .{};
    tracking.init();
    focus.init();
    wincache.init(alloc);
    // Uniform lifecycle dispatch: each compiled-in sub-system's init
    // runs, absent modules aren't in the array, so nothing else needs
    // a has_* guard. The fallible fan-out is stated here (init is its
    // only user; contract's two dispatch primitives are providerOf +
    // callAll, per the 6->2 collapse).
    for (window_mods) |wm| if (wm.init) |f| try f();
    icccm.reset();
    // Admission sub-state (spawn queue, rules maps, spawn-cursor
    // snapshot): reset and rules-map rebuild live with the admission
    // policy in admission.zig.
    admission.init(alloc);
}

pub fn deinit() void {
    wincache.deinit();
    // Uniform lifecycle dispatch: every compiled-in sub-system's
    // deinit runs, absent modules aren't in the array.
    dispatchAll(.deinit, .{});
    // Free the admission sub-state's heap-backed memory (spawn queue,
    // rules maps) before its reset wipes the struct.
    admission.deinit();
    // Clear the focus-property cache before focus/tracking deinit,
    // whose managed-window sweeps must not encounter a partially-valid
    // cache.
    icccm.reset();
    focus.deinit();
    tracking.deinit();
    // Set to null so any accidental post-deinit access null-derefs
    // instead of
    // silently reading freed state. init() restores it to .{}
    // unconditionally.
    state = null;
}

inline fn tilingActive() bool {
    return core.getState().config.tiling.enabled;
}

// Window predicates

/// True for the null window, the root, or the bar, never valid focus/manage targets.
pub inline fn isInvalidWindow(win: u32) bool {
    return win == 0 or win == core.getState().root or usable_area_mod.isSurfaceWindow(win);
}

/// True when `win` is a real manage target we are tracking. The single
/// predicate for "is this window ours" (events.zig, reconcile paths).
pub inline fn isValidManagedWindow(win: u32) bool {
    return !isInvalidWindow(win) and tracking.isManaged(win);
}

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

    if (tracking.isManaged(win)) return; // double-manage guard, see tracking.isManaged

    // Snapshot the pointer position now so the crossing the map generates can
    // be matched against it (see focus.snapshotSpawnCursor /
    // suppressSpawnCrossing).
    focus.snapshotSpawnCursor(conn);

    // getCurrentWorkspace() returns ?u8; the value is already bounded to [0,255]
    // by the u8 return type, so no further clamping is needed.
    const current_ws = core.WorkspaceId.fromIndex(tracking.getCurrentWorkspace() orelse 0);

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
    icccm.evictCache(win);

    // Evict child-cache entries pointing at this toplevel, so a new window
    // reusing the same XID can't be mis-identified as its child on the next
    // hover.
    evictChildCache(win);

    // Local bookkeeping, before the grab
    // wincache.removeWindow unconditionally evicts the combined cache entry
    // (geometry + border + size hints). All three removes are pure local
    // bookkeeping (no X requests), so they run pre-grab, letting the
    // post-close focus target be resolved against win-free tracking state,
    // with its input model queried BEFORE the grab.
    wincache.removeWindow(win);

    // Module cleanup on window drop: each compiled-in window module's
    // onWindowGone fires before the model entry is unregistered below, so
    // per-window bookkeeping (e.g. the hide module's parked record) is
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

const geometry_mask: u16 =
    xcb.XCB_CONFIG_WINDOW_X | xcb.XCB_CONFIG_WINDOW_Y |
    xcb.XCB_CONFIG_WINDOW_WIDTH | xcb.XCB_CONFIG_WINDOW_HEIGHT |
    xcb.XCB_CONFIG_WINDOW_BORDER_WIDTH;

fn sendConfigureNotify(win: u32, rect: model_mod.Rect) void {
    var ev = std.mem.zeroes(xcb.xcb_configure_notify_event_t);
    ev.response_type = xcb.XCB_CONFIGURE_NOTIFY;
    ev.event = win;
    ev.window = win;
    ev.x = rect.x;
    ev.y = rect.y;
    ev.width = rect.width;
    ev.height = rect.height;
    ev.border_width = rect.border_width;
    _ = xcb.xcb_send_event(
        core.getState().conn,
        0,
        win,
        xcb.XCB_EVENT_MASK_STRUCTURE_NOTIFY,
        @ptrCast(&ev),
    );
}

/// Resolve the window's current geometry, cheapest source first:
///
///   1. Model/sync truth: floating base or last-sent ledger rect. Covers
///      covering winners too -- sync seeds the covering winner's ledger rect
///      with the screen rect (bw 0), so the screen pin needs no special case
///      here (a redundant covering branch would duplicate that).
///   2. True cache miss: one blocking xcb_get_geometry. Floating windows
///      never retiled; a fallback, not a hot path.
///
/// Returns null when even the fallback fails (window gone).
fn resolveConfigureGeometry(win: u32) ?model_mod.Rect {
    // Model/sync truth: floating base or last-sent ledger rect.
    if (reconcile.truthRect(pipeline.model(), win)) |rect| {
        // Report the border width we actually last sent for this window
        // (the ledger), not the global config default. The two differ before
        // the first reconcile and for per-window overrides; a wrong value here
        // makes clients mis-size themselves.
        const border: u16 = if (!build_options.has_tiling)
            0
        else
            ledger.lastBorderWidthFor(win) orelse core.borderWidth();
        return .{
            .x = rect.x,
            .y = rect.y,
            .width = rect.width,
            .height = rect.height,
            .border_width = border,
        };
    }

    const conn = core.getState().conn;
    return getGeometry(conn, win);
}

fn sendSyntheticConfigureNotify(win: u32) void {
    const rect = resolveConfigureGeometry(win) orelse return;
    sendConfigureNotify(win, rect);
}

fn handleManagedConfigureRequest(
    win: u32,
    event: *const xcb.xcb_configure_request_event_t,
    mask: u16,
) void {
    const req: model_mod.ConfigureReq = .{
        .x = if (mask & xcb.XCB_CONFIG_WINDOW_X != 0) event.x else null,
        .y = if (mask & xcb.XCB_CONFIG_WINDOW_Y != 0) event.y else null,
        .width = if (mask & xcb.XCB_CONFIG_WINDOW_WIDTH != 0) event.width else null,
        .height = if (mask & xcb.XCB_CONFIG_WINDOW_HEIGHT != 0) event.height else null,
        .border_width = if (mask & xcb.XCB_CONFIG_WINDOW_BORDER_WIDTH != 0)
            event.border_width
        else
            null,
    };
    const wm = providerOf(.honorConfigureRequest) orelse return;
    switch (wm.honorConfigureRequest.?(pipeline.mut(), win, req)) {
        .geometry_applied => {
            // ICCCM 4.1.5: a border-width-only request applied by the module
            // needs the synthetic ConfigureNotify (the width isn't otherwise
            // observable) AND the reconcile ledger updated so the next reconcile
            // doesn't re-assert the WM width (reverting the honored value).
            if (mask == xcb.XCB_CONFIG_WINDOW_BORDER_WIDTH) {
                noteHonoredBorderWidth(win, event.border_width);
                sendSyntheticConfigureNotify(win);
                return;
            }
            // Don't teleport an off-screen window onto the visible usable area.
            // A parked (off-workspace) or non-current-workspace floating
            // window's ConfigureRequest must update its model rect (done in the
            // module above) but not move the X window, which would flash it
            // onto the current workspace; it is configured when next shown.
            const m = pipeline.model();
            if (model_mod.visibleOn(m, win, m.current))
                sendRequestedConfigure(win, event, mask);
            return;
        },
        .border_only => {
            if (mask != xcb.XCB_CONFIG_WINDOW_BORDER_WIDTH)
                _ = xcb.xcb_configure_window(
                    core.getState().conn,
                    win,
                    xcb.XCB_CONFIG_WINDOW_BORDER_WIDTH,
                    &[_]u32{event.border_width},
                );
            noteHonoredBorderWidth(win, event.border_width);
        },
        .ignored => {},
    }
    // ICCCM 4.1.5: echo a synthetic ConfigureNotify so the client observes
    // its denied geometry / new border width.
    sendSyntheticConfigureNotify(win);
}

/// Record an honored border width in the reconcile ledger so the next reconcile
/// doesn't re-assert the WM default (reverting the honored value). No-op on
/// non-tiling builds.
fn noteHonoredBorderWidth(win: u32, bw: u16) void {
    if (build_options.has_tiling) ledger.markSentBorderWidth(win, bw);
}

pub fn handleConfigureRequest(event: *const xcb.xcb_configure_request_event_t) void {
    const win = event.window;

    // Fast exit: no geometry fields requested, so skip the managed predicates
    // (stacking-order-only requests from compositors/override-redirect).
    const mask = event.value_mask & geometry_mask;
    if (mask == 0) return;

    // Deny min-size ConfigureRequests from the window being drag-resized.
    if (actions.isResizingWindow(win)) {
        const last = actions.getDragLastRect();
        if (last.width != 0) {
            sendConfigureNotify(win, .{
                .x = last.x,
                .y = last.y,
                .width = last.width,
                .height = last.height,
                .border_width = core.borderWidth(),
            });
        } else {
            sendSyntheticConfigureNotify(win);
        }
        return;
    }

    // isValidManagedWindow, not a bare isManaged: every other consumer of this
    // predicate already filters the invalid-window sentinel first, and one
    // spelling means a chrome XID cannot slip through this path.
    if (core.isModelReady() and isValidManagedWindow(win)) {
        handleManagedConfigureRequest(win, event, mask);
        return;
    }

    sendRequestedConfigure(win, event, mask);
}

/// Builds the value list from `event` in XCB_CONFIG_WINDOW_* bit order and
/// issues the ConfigureWindow request.
fn sendRequestedConfigure(
    win: u32,
    event: *const xcb.xcb_configure_request_event_t,
    mask: u16,
) void {
    const fields = .{
        .{ xcb.XCB_CONFIG_WINDOW_X, model_mod.toXcbCoord(event.x) },
        .{ xcb.XCB_CONFIG_WINDOW_Y, model_mod.toXcbCoord(event.y) },
        .{ xcb.XCB_CONFIG_WINDOW_WIDTH, event.width },
        .{ xcb.XCB_CONFIG_WINDOW_HEIGHT, event.height },
        .{ xcb.XCB_CONFIG_WINDOW_BORDER_WIDTH, event.border_width },
    };
    var values: [5]u32 = undefined;
    var n: usize = 0;
    inline for (fields) |f| {
        if (mask & f[0] != 0) {
            values[n] = @intCast(f[1]);
            n += 1;
        }
    }
    _ = xcb.xcb_configure_window(core.getState().conn, win, mask, &values);
}

inline fn suppressSpawnCrossing(root_x: i16, root_y: i16) bool {
    if (focus.getSuppressReason() != .window_spawn) return false;
    // The spawn snapshot (focus.spawnCursor()) is taken by
    // handleMapRequest
    // when the spawn's MapRequest arrives. Mapping a new window under the
    // stationary cursor produces a PAIR of synthetic crossings, both carrying
    // the spawn's root coordinates: the enter into the spawned window, and the
    // return crossing into the window it displaced (which, when the spawned
    // window immediately parks offscreen, is the previous focus). A one-shot
    // guard only drops the first, letting the return crossing re-steal focus
    // from the just-spawned window via mouse_enter.
    //
    // Keep the guard armed while crossings stay at the spawn pixel: only a
    // genuine pointer move (different coordinates) is a real hover and may
    // clear it. A cursor parked where it was when the app launched can't hover
    // a different window at that same pixel until it moves, which is the
    // acceptable price for not stealing focus during the spawn's layout.
    const cursor = focus.spawnCursor();
    if (root_x == cursor.x and root_y == cursor.y) return true;
    focus.setSuppressReason(.none);
    return false;
}

/// Shared guard tail for the EnterNotify/LeaveNotify handlers, run after each
/// handler's event-shape filter (mode/detail/root): a floating drag owns the
/// pointer, and a spawn's synthetic crossing (the window mapping under the
/// parked cursor) must be suppressed. Returns true when the crossing should
/// be dropped.
inline fn crossingShouldDrop(root_x: i16, root_y: i16) bool {
    if (actions.isDragging()) return true;
    return suppressSpawnCrossing(root_x, root_y);
}

/// Attempt to focus `win` via the hover (EnterNotify) path.
///
/// Guards against workspace membership and hidden state before calling
/// focus.grabFocus(.mouse_enter). The .mouse_enter reason is the direct
/// EnterNotify path: lightweight, no raise, no confirm.
inline fn maybeFocusWindow(win: u32) void {
    // In all-view mode every window is visible on the current workspace
    // regardless of its tag mask, so hover must be able to focus it too; a
    // bare membership check made all-view windows un-focusable by ENTER.
    if (!tracking.isOnCurrentWorkspace(win) and !pipeline.model().all_view_active) return;
    if (callHookBool(.isWindowHidden, .{ pipeline.model(), win })) return;
    focus.grabFocus(win, .mouse_enter);
}

pub fn handleEnterNotify(event: *const xcb.xcb_enter_notify_event_t) void {
    focus.setLastEventTime(event.time);
    if (event.mode != xcb.XCB_NOTIFY_MODE_NORMAL or
        event.detail == xcb.XCB_NOTIFY_DETAIL_INFERIOR)
        return;
    if (crossingShouldDrop(event.root_x, event.root_y)) return;
    if (focus.shouldSuppressEnterNotify()) return;
    maybeFocusWindow(findManagedWindow(core.getState().conn, event.event, tracking.isManaged));
}

pub fn handleLeaveNotify(event: *const xcb.xcb_leave_notify_event_t) void {
    focus.setLastEventTime(event.time);
    if (event.event != core.getState().root) return;
    if (event.mode != xcb.XCB_NOTIFY_MODE_NORMAL) return;
    if (crossingShouldDrop(event.root_x, event.root_y)) return;
    // When child is zero the pointer left to an area not covered by any window.
    if (event.child == 0) return;
    // Guard against unmanaged subwindows (e.g. embedded GTK widgets): a root
    // LeaveNotify with non-zero child doesn't guarantee a managed toplevel.
    // Walk up to the managed toplevel, consistent with handleEnterNotify's
    // findManagedWindow.
    maybeFocusWindow(findManagedWindow(core.getState().conn, event.child, tracking.isManaged));
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

/// Refresh border colors for all windows on the current workspace. Shared
/// iteration loop for workspace border sweeps:
///
/// - `skip_tiled` true (updateFloatingWindowBorders): skip tiled windows,
///   `configureWithHints` already updated their borders via get_border_color;
///   when tiling is absent or disabled it falls back to a full sweep because
///   there are no tiled windows to skip.
/// - `skip_tiled` false (updateWorkspaceBorders): dedup via the sent ledger
///   (markSentBorderPixelIfChanged), so the steady-state focused-window
///   sweep generates zero XCB traffic.
/// Fill `buf` with the per-workspace covering-occupant table in ONE store
/// pass. Every per-window color decision asks "does this window's workspace
/// have a covering occupant"; asking per window made the sweep O(N^2) in
/// store scans, so both sweep variants (and reloadBorders) build it once
/// up-front.
fn occupantsInto(buf: *[constants.max_workspaces]?model_mod.WindowId) void {
    buf.* = @splat(null);
    model_mod.coveringOccupants(pipeline.model(), buf);
}

fn sweepWorkspaceBorders(comptime skip_tiled: bool) void {
    const cur = tracking.getCurrentWorkspace() orelse return;
    const cur_ws = model_mod.WSId.fromIndex(cur);
    var occupants: [constants.max_workspaces]?model_mod.WindowId = undefined;
    occupantsInto(&occupants);
    for (tracking.allWindowsInto(&state.?.snapshot)) |entry| {
        const win = entry.win;
        if (!model_mod.maskedOn(entry.mask, cur_ws)) continue;
        // Parked (offscreen/minimized) windows are invisible; recoloring
        // them is pointless XCB traffic and can race the park position. The
        // unpark reconcile re-establishes their border color.
        if (entry.presence == .parked) continue;
        if (comptime skip_tiled) {
            if (build_options.has_tiling and tilingActive() and tracking.isTiledMode(win)) continue;
        }
        const color = borders.resolveBorderColorWith(win, &occupants);
        // Same ledger dedup in both sweep variants: a window whose color is
        // unchanged (per the ledger's record) skips the XCB call outright.
        // 11.4: one record has to answer this for both the sweep and the
        // reconcile -- see borders.applyWith.
        if (ledger.markSentBorderPixelIfChanged(win, color))
            requests.setBorderPixel(core.getState().conn, win, color);
    }
}

pub fn updateWorkspaceBorders() void {
    sweepWorkspaceBorders(false);
}

pub fn updateFloatingWindowBorders() void {
    sweepWorkspaceBorders(true);
}

// ClientMessage: EWMH fullscreen requests from applications

pub fn handleClientMessage(event: *const xcb.xcb_client_message_event_t) void {
    if (event.format != 32) return;

    // Unhonorable pager requests are dropped silently otherwise; each warn
    // fires once per process so a looping pager cannot flood the log.
    // `_NET_WM_FULLSCREEN_REQUEST` is a SEPARATE EWMH message from
    // `_NET_WM_STATE`, and it is the one browsers use for native video
    // fullscreen. Its layout is: window field = the window, data32[0] = the
    // intended end state (1 enter, 0 leave). Dropping it -- as the pre-fix
    // handler did, since the atom appeared nowhere in the tree -- is why F
    // did nothing in a YouTube player while hana's own Mod+F worked.
    const net_fs_request = atoms.getAtomOrZero("_NET_WM_FULLSCREEN_REQUEST");
    if (net_fs_request != 0 and event.type == net_fs_request) {
        const win = event.window;
        if (!isValidManagedWindow(win)) {
            warnOnce(
                &state.?.warned_unmanaged_fs_request,
                "Ignoring _NET_WM_FULLSCREEN_REQUEST for unmanaged window 0x{x}",
                .{win},
            );
            return;
        }
        // Only 0 and 1 are defined; anything else is dropped rather than
        // guessed at, since guessing means entering or leaving fullscreen on
        // a client that asked for neither.
        const target = switch (event.data.data32[0]) {
            0 => false,
            1 => true,
            else => return,
        };
        // PIPELINE: model-path transition; the transition stays on the single
        // source of truth.
        actions.fullscreenSetWindow(win, target);
        return;
    }

    const net_active = atoms.getAtomOrZero("_NET_ACTIVE_WINDOW");
    if (net_active != 0 and event.type == net_active) {
        warnOnce(
            &state.?.warned_active_ignore,
            "Ignoring _NET_ACTIVE_WINDOW request for 0x{x}: EWMH activation is not implemented",
            .{event.window},
        );
        return;
    }

    const net_wm_state = atoms.getAtomOrZero("_NET_WM_STATE");
    if (net_wm_state == 0 or event.type != net_wm_state) return;

    const fs_atom = atoms.getAtomOrZero("_NET_WM_STATE_FULLSCREEN");
    if (fs_atom == 0) return;
    const prop1 = event.data.data32[1];
    const prop2 = event.data.data32[2];
    if (prop1 != fs_atom and prop2 != fs_atom) return;

    const win = event.window;
    if (!isValidManagedWindow(win)) {
        warnOnce(
            &state.?.warned_unmanaged_state,
            "Ignoring _NET_WM_STATE request for unmanaged window 0x{x}",
            .{win},
        );
        return;
    }

    const action = event.data.data32[0];
    // EWMH _NET_WM_STATE action codes, carried in data32[0]. `want` is
    // the target state for the SET paths (add/remove); `toggle` is null
    // -- a genuine flip, the keybind path's meaning.
    const ewmh_state_add: u32 = 1;
    const ewmh_state_remove: u32 = 0;
    const ewmh_state_toggle: u32 = 2;
    const want: ?bool = switch (action) {
        ewmh_state_add => true,
        ewmh_state_remove => false,
        ewmh_state_toggle => null,
        else => return,
    };
    // PIPELINE: model-path transition; the transition stays on the single
    // source of truth. `fullscreenSetWindow` re-checks want-vs-current
    // itself (and computes the covering state inside the same grab), so
    // the covering pre-scan and the explicit guard this arm used to make
    // are gone -- one covering scan per request instead of two.
    actions.fullscreenSetWindow(win, want);
}

/// Called on config reload.
pub fn reloadBorders() void {
    var occupants: [constants.max_workspaces]?model_mod.WindowId = undefined;
    occupantsInto(&occupants);
    for (tracking.allWindowsInto(&state.?.snapshot)) |entry| {
        borders.applyWith(core.getState().conn, entry.win, &occupants);
    }
}
