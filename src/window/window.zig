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
const icccm = @import("icccm");
const build_options = @import("build_options");
const window_mods = @import("window_modules").modules;
const screen_mod = @import("screen");
const wincache = @import("wincache");
const borders = @import("borders");
const pipeline = @import("pipeline");
const actions = @import("actions");
const persist = @import("persist");

// Private transition-layer gate for mutable model access (tracking no longer
// exports a shared one; each transition owner declares its own token).
const gate: pipeline.Gate = .{};

/// Registry lookup for the hook `field` (see `plugin.providerOf`), null when
/// no module binds it; shared by the window layer (actions/borders alias this).
pub fn providerOf(
    comptime field: std.meta.FieldEnum(@import("plugin").WindowModule),
) ?@import("plugin").WindowModule {
    return @import("plugin").providerOf(window_mods[0..], field);
}

pub fn callHook(
    comptime field: std.meta.FieldEnum(@import("plugin").WindowModule),
    args: anytype,
) void {
    inline for (window_mods[0..]) |m| if (@field(m, @tagName(field))) |f| {
        @call(.auto, f, args);
        break;
    };
}

pub fn callHookBool(
    comptime field: std.meta.FieldEnum(@import("plugin").WindowModule),
    args: anytype,
) bool {
    inline for (window_mods[0..]) |m| if (@field(m, @tagName(field))) |f| {
        return @call(.auto, f, args);
    };
    return false;
}

/// Runs a hook on EVERY module that binds it, not just the first (callHook
/// returns after the first provider). Dispatch loops shared by actions.
pub fn dispatchAll(
    comptime field: std.meta.FieldEnum(@import("plugin").WindowModule),
    args: anytype,
) void {
    inline for (window_mods[0..]) |m| if (@field(m, @tagName(field))) |f| @call(.auto, f, args);
}

/// Like dispatchAll but returns true at the first provider whose hook does;
/// false when no provider binds the hook or none returns true.
pub fn dispatchFirstTrue(
    comptime field: std.meta.FieldEnum(@import("plugin").WindowModule),
    args: anytype,
) bool {
    inline for (window_mods[0..]) |m| if (@field(m, @tagName(field))) |f| {
        if (@call(.auto, f, args)) return true;
    };
    return false;
}

/// The return type of a hook field's optional function pointer
/// (`?*const fn(...) T`); lets callHook-value wrappers avoid hardcoding it.
fn HookReturnOf(comptime Hook: type) type {
    return @typeInfo(@typeInfo(@typeInfo(Hook).optional.child).pointer.child).@"fn".return_type.?;
}

/// Returns the first provider's hook result (callHook that yields a value),
/// with the return type derived from the hook field instead of hardcoded.
pub inline fn callFirst(
    comptime field: std.meta.FieldEnum(@import("plugin").WindowModule),
    args: anytype,
) ?HookReturnOf(@TypeOf(@field(window_mods[0], @tagName(field)))) {
    inline for (window_mods[0..]) |m| if (@field(m, @tagName(field))) |f| return @call(.auto, f, args);
    return null;
}

/// True when `win` is currently screen-covering via a covering-mode module
/// (fullscreen). Shared by the configure-resolution and client-message paths;
/// actions aliases this as its dispatch seam.
pub fn isCoveringMode(m: *const @import("model").Model, win: u32) bool {
    return callHookBool(.isCoveringMode, .{ m, win });
}

// ICCCM protocol surface (ICCCM 4.1.2/4.1.7) lives in icccm.zig; window.zig
// re-exports the pub API so `window.*` stays the stable external facade.
pub const fireWMProtocolsQuery = icccm.fireWMProtocolsQuery;
pub const getInputModelResolved = icccm.getInputModelResolved;
pub const getInputModelResolvedConsume = icccm.getInputModelResolvedConsume;
pub const getInputModel = icccm.getInputModel;
pub const supportsWMDeleteCached = icccm.supportsWMDeleteCached;
pub const isInputModelCached = icccm.isInputModelCached;
pub const sendWMTakeFocus = icccm.sendWMTakeFocus;
pub const sendWMTakeFocusKnown = icccm.sendWMTakeFocusKnown;
pub const discardProtocolCookie = icccm.discardProtocolCookie;

// XSizeHints flags (ICCCM 4.1.2.3)
const p_min_size: u32 = 0x10;
const p_max_size: u32 = 0x20;
const p_resize_inc: u32 = 0x40;
const p_aspect: u32 = 0x80;
const p_base_size: u32 = 0x100;

const wm_normal_hints_long_length: u32 = 18; // flags + 17 fields (up to base_size/win_gravity)

const max_window_tree_depth = constants.max_window_tree_depth;

// Spawn queue: pending (workspace, pid) assignments for newly-mapped windows,
// consumed by resolveTargetWorkspace. Capped at max_spawn_queue; overflow logs
// and drops the entry rather than growing unbounded.

const SpawnEntry = struct {
    workspace: u8,
    /// _NET_WM_PID of the grandchild; 0 for daemon-mode terminals.
    pid: u32,
};

// Bounds pending spawns awaiting their first map, not the tiled-window pool.
const max_spawn_queue: usize = 64;

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

    // Float-rule fast-lookup map: WM_CLASS name -> float, rebuilt from the
    // same config rules (entries whose `float` bit is set). First rule wins;
    // a name lives in exactly one of the two maps. Keys borrow slices from the
    // config, valid until the next rebuild.
    float_rules: std.StringHashMapUnmanaged(void) = .{},

    // Child XID -> managed toplevel XID (see "Child window resolution").
    child_cache: utils.BoundedList(ChildEntry, max_child_cache) = .{},

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
    const reply = xcb.xcb_get_geometry_reply(conn, xcb.xcb_get_geometry(conn, win), null) orelse
        return null;
    defer std.c.free(reply);
    return utils.rectFromXcb(reply, true);
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

const max_child_cache: usize = 64;

const ChildEntry = struct { id: u32, managed: u32 };

/// Record that `child` resolves to `managed` so future tree walks are skipped.
fn cacheChildWindow(child: u32, managed: u32) void {
    if (child == managed) return; // direct hit, not a child, nothing to cache
    // At cap, append silently drops, the tree walk fallback is always correct.
    _ = state.?.child_cache.upsertById(.id, child, .{ .id = child, .managed = managed });
}

/// Called from unmanageWindow so stale child entries don't linger.
fn evictChildCache(managed_win: u32) void {
    _ = state.?.child_cache.removeAllWhere(managed_win, struct {
        fn match(m: u32, item: ChildEntry) bool {
            return item.managed == m;
        }
    }.match);
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
/// wins, matching a plain linear scan through the rule list. Float rules land
/// in `float_rules` (workspace rules in `rules_map`); a name can only ever be
/// one or the other, never both.
pub fn buildRulesMap() void {
    const alloc = state.?.alloc orelse return;
    state.?.rules_map.clearRetainingCapacity();
    state.?.float_rules.clearRetainingCapacity();
    for (core.getState().config.workspaces.rules.items) |rule| {
        if (rule.float) {
            // A workspace rule for this name already won; never promote it to
            // floating after the fact.
            if (state.?.rules_map.contains(rule.class_name)) continue;
            // getOrPut: first occurrence wins. On OOM the entry is silently
            // dropped, the window behaves as if unruled.
            _ = state.?.float_rules.getOrPut(alloc, rule.class_name) catch {};
        } else {
            // A float rule for this name already won; never tile it after the
            // fact.
            if (state.?.float_rules.contains(rule.class_name)) continue;
            // putNoClobber: first occurrence wins. On OOM the entry is silently
            // dropped, the window is routed to the current workspace instead.
            state.?.rules_map.putNoClobber(alloc, rule.class_name, rule.workspace) catch {};
        }
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
        debug.warn(
            "window: spawn queue pre-allocation failed ({s}); will grow on demand",
            .{@errorName(err)},
        );
    };
    icccm.reset(true);
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
        state.?.float_rules.deinit(a);
    }
    // Clear the focus-property cache before focus/tracking deinit, whose
    // managed-window sweeps must not encounter a partially-valid cache.
    icccm.reset(false);
    focus.deinit();
    tracking.deinit();
    // Set to null so any accidental post-deinit access hits a panic (via
    // getState()) or null-deref instead of silently reading freed state.
    // init() restores it to .{} unconditionally.
    state = null;
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

pub inline fn clampToValidWorkspace(target: u8, fallback: core.WorkspaceId) core.WorkspaceId {
    return if (target < tracking.getWorkspaceCount())
        core.WorkspaceId.fromIndex(target)
    else
        fallback;
}

/// A matched class rule: either a workspace target or the float marker. The
/// float bit is set for "float" rules, in which case `workspace` is null and
/// the window is admitted floating on the current workspace.
pub const AdmissionRule = struct {
    workspace: ?u8,
    float: bool,
};

/// Resolves a pre-fired WM_CLASS property cookie against workspace and float
/// rules. Parses the WM_CLASS reply inline (no allocation), then does two O(1)
/// hash lookups per map (class, then instance). The maps are built at init()
/// and after every config reload, so no linear rule scan runs at spawn time.
fn findAdmissionRuleByClass(cookie: xcb.xcb_get_property_cookie_t) ?AdmissionRule {
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
        if (state.?.float_rules.contains(class)) return .{ .workspace = null, .float = true };
        if (state.?.rules_map.get(class)) |ws| return .{ .workspace = ws, .float = false };
    }
    if (instance.len > 0) {
        if (state.?.float_rules.contains(instance)) return .{ .workspace = null, .float = true };
        if (state.?.rules_map.get(instance)) |ws| return .{ .workspace = ws, .float = false };
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
        const pid_reply = xcb.xcb_get_property_reply(
            core.getState().conn,
            c_net_wm_pid,
            null,
        ) orelse break :pid 0;
        defer std.c.free(pid_reply);
        if (pid_reply.*.format != 32 or pid_reply.*.value_len < 1) break :pid 0;
        break :pid icccm.u32Values(pid_reply)[0];
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
        debug.debug(
            "spawn: no exact PID match for pid={d}, {d} pending; ambiguous, routing to current ws",
            .{ win_pid, state.?.spawn_queue.items.len },
        );
        return null;
    }
    debug.debug(
        "spawn: no exact PID match for pid={d}, sole entry ws={d}, using heuristic",
        .{ win_pid, state.?.spawn_queue.items[0].workspace },
    );
    const ws = state.?.spawn_queue.items[0].workspace;
    _ = state.?.spawn_queue.swapRemove(0); // order has no semantic meaning
    return ws;
}

/// The admission policy for a brand-new spawn: the target workspace (class
/// rule, then spawn-queue PID rule, else current) plus whether the class rule
/// floats the window.
pub const AdmissionDecision = struct {
    workspace: core.WorkspaceId,
    float: bool,
};

/// Drains pre-fired WM_CLASS / _NET_WM_PID cookies to resolve the admission
/// decision. Cookies are fired by the caller (handleMapRequest) together with
/// the other three property queries so the X server can process all five in
/// parallel; this function only drains the two workspace-resolution replies.
fn resolveAdmissionDecision(
    current_ws: core.WorkspaceId,
    c_wm_class: ?xcb.xcb_get_property_cookie_t,
    c_net_wm_pid: ?xcb.xcb_get_property_cookie_t,
) AdmissionDecision {
    const cs = core.getState();

    // Drain replies: WM_CLASS first, then _NET_WM_PID.
    if (c_wm_class) |cookie| if (findAdmissionRuleByClass(cookie)) |rule| {
        discardProtocolCookie(cs.conn, c_net_wm_pid);
        const ws = if (rule.workspace) |target|
            clampToValidWorkspace(target, current_ws)
        else
            current_ws;
        return .{ .workspace = ws, .float = rule.float };
    };
    if (c_net_wm_pid) |cookie| if (findSpawnQueueWorkspace(cookie)) |spawn_ws|
        return .{
            .workspace = clampToValidWorkspace(spawn_ws, current_ws),
            .float = false,
        };
    return .{ .workspace = current_ws, .float = false };
}

pub fn registerSpawn(workspace: core.WorkspaceId, pid: u32) void {
    const alloc = state.?.alloc orelse return;
    if (state.?.spawn_queue.items.len >= max_spawn_queue) {
        debug.warn(
            "registerSpawn: spawn queue full ({d} entries); entry dropped",
            .{max_spawn_queue},
        );
        return;
    }
    state.?.spawn_queue.append(alloc, .{ .workspace = workspace.index, .pid = pid }) catch |err| {
        debug.warn("registerSpawn: failed to queue spawn entry: {}", .{err});
    };
}

/// The five property-query cookies fired for an admitted window. All are
/// fired up-front (before any reply is drained) so the X server processes
/// them in parallel; the callers differ only in how they drain the two
/// workspace-resolution cookies (rules/spawn resolution vs. discard).
const AdmissionCookies = struct {
    c_wm_class: ?xcb.xcb_get_property_cookie_t,
    c_net_wm_pid: ?xcb.xcb_get_property_cookie_t,
    normal_hints_cookie: xcb.xcb_get_property_cookie_t,
    protocols_cookie: xcb.xcb_get_property_cookie_t,
    hints_cookie: xcb.xcb_get_property_cookie_t,
    title_cookies: wincache.TitleCookies,
};

/// Fires all property-query cookies for an admitted window (WM_CLASS,
/// _NET_WM_PID, WM_NORMAL_HINTS, WM_PROTOCOLS, WM_HINTS) before any reply is
/// drained. Shared by handleMapRequest and adoptRootWindows; both are preceded
/// by the change_window_attributes preamble and followed by the size-hints and
/// focus-cache drains, but route the two conditional workspace cookies
/// differently, so only the firing lives here.
fn fireAdmissionCookies(conn: core.Connection, win: u32) AdmissionCookies {
    const cs = core.getState();

    // Workspace resolution cookies (conditional).
    const wm_class_atom = utils.getAtomOrZero("WM_CLASS");
    const c_wm_class: ?xcb.xcb_get_property_cookie_t =
        if (cs.config.workspaces.rules.items.len > 0 and wm_class_atom != 0)
            icccm.firePropQuery(conn, win, wm_class_atom, xcb.XCB_ATOM_STRING, constants.property_max_length)
        else
            null;

    const c_net_wm_pid: ?xcb.xcb_get_property_cookie_t =
        if (state.?.spawn_queue.items.len > 0)
            icccm.firePropQuery(conn, win, utils.getAtomOrZero("_NET_WM_PID"), xcb.XCB_ATOM_CARDINAL, 1)
        else
            null;

    // Property cookies (always fired).
    const normal_hints_cookie = icccm.firePropQuery(conn, win, xcb.XCB_ATOM_WM_NORMAL_HINTS, xcb.XCB_ATOM_WM_SIZE_HINTS, wm_normal_hints_long_length);
    const protocols_cookie = fireWMProtocolsQuery(conn, win) orelse
        icccm.firePropQuery(conn, win, 0, xcb.XCB_ATOM_ATOM, constants.property_max_length);
    const hints_cookie = icccm.firePropQuery(conn, win, xcb.XCB_ATOM_WM_HINTS, xcb.XCB_ATOM_WM_HINTS, icccm.wm_hints_long_length);

    return .{
        .c_wm_class = c_wm_class,
        .c_net_wm_pid = c_net_wm_pid,
        .normal_hints_cookie = normal_hints_cookie,
        .protocols_cookie = protocols_cookie,
        .hints_cookie = hints_cookie,
        .title_cookies = wincache.fireTitleCookies(conn, win),
    };
}

/// Claims the management event mask so `win` delivers PropertyNotify/
/// StructureNotify/FocusChange events (shared MapRequest/adoption preamble).
fn claimManagedEventMask(conn: core.Connection, win: u32) void {
    _ = xcb.xcb_change_window_attributes(
        conn,
        win,
        xcb.XCB_CW_EVENT_MASK,
        &[_]u32{masks.EventMasks.managed_window},
    );
}

/// Drains the three unconditionally-fired admission cookies; with
/// `discard_workspace` the two conditional workspace-resolution replies are
/// discarded instead (adoption never resolves from them; the MapRequest path
/// has already drained them via resolveTargetWorkspace).
fn drainAdmissionCookies(conn: core.Connection, win: u32, cookies: AdmissionCookies, comptime discard_workspace: bool) void {
    if (comptime discard_workspace) {
        discardProtocolCookie(conn, cookies.c_wm_class);
        discardProtocolCookie(conn, cookies.c_net_wm_pid);
    }
    parseSizeHintsIntoCache(win, cookies.normal_hints_cookie);
    icccm.populateFocusCacheFromCookies(conn, win, cookies.protocols_cookie, cookies.hints_cookie);
    wincache.collectTitleCookies(conn, win, cookies.title_cookies);
}

/// Discards every cookie in a fired AdmissionCookies batch without parsing it.
/// adoptRootWindows fires admission cookies for ALL root children up-front, so
/// a candidate that fails its attribute gate (vanished / override-redirect /
/// unmapped-and-unparked) must still consume its own batch to keep the XCB
/// reply stream from accumulating unconsumed results. Firing order is preserved
/// so replies are read back in request order alongside the drain path.
fn discardAdmissionCookies(conn: core.Connection, cookies: AdmissionCookies) void {
    discardProtocolCookie(conn, cookies.c_wm_class);
    discardProtocolCookie(conn, cookies.c_net_wm_pid);
    wincache.discardTitleCookies(conn, cookies.title_cookies);
    inline for (.{
        cookies.normal_hints_cookie,
        cookies.protocols_cookie,
        cookies.hints_cookie,
    }) |ck| xcb.xcb_discard_reply(conn, ck.sequence);
}

/// Handles a MapRequest by firing ALL property query cookies up-front, then
/// draining replies sequentially. Firing all five cookies before draining any
/// lets the X server process them in parallel, saving 2-3 blocking round trips
/// compared to the previous fire-then-drain-per-property approach.
///
/// TIMING (gated by `-Dprofile-key`, mirroring actions.switchTo): measures
/// MapRequest receipt -> the map queued by the reconcile inside admitWindow.
/// `drain_us` is the dominant X round-trip (the reply to the first of the
/// pipelined batch); `after_drain_us` is pure local work (workspace resolve,
/// model register, reconcile/map). Both are logged once per spawn.
pub fn handleMapRequest(event: *const xcb.xcb_map_request_event_t) void {
    const win = event.window;
    const conn = core.getState().conn;
    const t0: u64 = if (build_options.profile_key) utils.monotonicNs() else 0;

    // Double-manage guard: a window can send multiple MapRequest events (e.g.
    // an unmap+remap race while the first is still processing); without it,
    // the model registration and property queries below would fire twice.
    if (tracking.isManaged(win)) return;

    // getCurrentWorkspace() returns ?u8; the value is already bounded to [0,255]
    // by the u8 return type, so no further clamping is needed.
    const current_ws = core.WorkspaceId.fromIndex(tracking.getCurrentWorkspace() orelse 0);

    claimManagedEventMask(conn, win);

    // ----- Fire ALL property cookies before draining any reply -----
    // The server processes all five requests in parallel while we do pure
    // local bookkeeping below.
    const cookies = fireAdmissionCookies(conn, win);
    const t_fire: u64 = if (build_options.profile_key) utils.monotonicNs() else 0;

    // ----- Drain replies sequentially -----
    const decision = resolveAdmissionDecision(current_ws, cookies.c_wm_class, cookies.c_net_wm_pid);
    const target_ws = decision.workspace;
    const on_current = target_ws.eql(current_ws);

    drainAdmissionCookies(conn, win, cookies, false);
    const t_drain: u64 = if (build_options.profile_key) utils.monotonicNs() else 0;

    // Shared admission policy (MapRequest path). The cookie firing above is
    // specific to the MapRequest event source; everything from here on (the
    // model registration + grabs + child-cache seeding) is identical to the
    // boot-time adoption path, so it lives in admitWindow.
    admitWindow(win, target_ws.index, on_current, decision.float);

    if (build_options.profile_key) {
        const t_map = utils.monotonicNs();
        debug.info("[TIMING] spawn 0x{x}: local={d}us drain={d}us after_drain={d}us total={d}us", .{
            win,
            @as(u64, @intCast(t_fire - t0)) / 1000,
            @as(u64, @intCast(t_drain - t_fire)) / 1000,
            @as(u64, @intCast(t_map - t_drain)) / 1000,
            @as(u64, @intCast(t_map - t0)) / 1000,
        });
    }
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
/// target workspace + float flag (mirror of resolveTargetWorkspace's role at
/// the MapRequest site). The float seed's geometry is fetched here: at
/// admission there is no LastSent entry yet (no reconcile has run), so
/// detachTiledToFloating's `sync.lastRectFor` would find nothing; the one
/// extra xcb_get_geometry round-trip supplies the window's natural rect.
fn admitWindow(win: u32, target_ws: u8, on_current: bool, float: bool) void {
    const cs = core.getState();
    const float_rect: ?utils.Rect = if (float) getGeometry(cs.conn, win) else null;
    actions.mapRequest(win, target_ws, on_current, float_rect);
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

/// Resolves only the float bit of a class rule (adoption never relocates a
/// pre-existing window's workspace, so a workspace match is deliberately
/// ignored here). Drains the WM_CLASS reply.
fn resolveClassFloat(cookie: ?xcb.xcb_get_property_cookie_t) bool {
    const c = cookie orelse return false;
    const rule = findAdmissionRuleByClass(c) orelse return false;
    return rule.float;
}

/// Target workspace for an adopted window: the restore record's home
/// workspace (lowest set bit of its mask) when present, else the currently
/// active workspace. Deliberately NOT the spawn-queue/rules resolution, which
/// describes brand-new spawns rather than pre-existing windows.
fn restoredOrCurrent(record: ?*const persist.WindowRecord) u8 {
    if (record) |r| {
        if (r.mask != 0) return @intCast((@import("model").lowestBit(r.mask) orelse unreachable).index);
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
    const model = pipeline.mut(&gate);
    const e = model.store.getPtr(win) orelse return;

    e.mask = record.mask;

    switch (record.anchor) {
        .tiled => {},
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
///
/// PIPELINING: MapRequest pipelines one window's five property queries. Boot
/// restore pipelines the attribute + property query of every root child: pass 1
/// fires all cookies across all children into a single list, pass 2 drains each
/// batch in request order. The X server answers the whole batch back-to-back,
/// so the once per-window serial attribute-then-properties pattern collapses to
/// ~2 blocking reads total (the query_tree reply plus one drain that pulls the
/// entire batch off the wire).
const AdoptionEntry = struct {
    win: u32,
    attr_cookie: xcb.xcb_get_window_attributes_cookie_t,
    record: ?*const persist.WindowRecord,
    cookies: AdmissionCookies,
};

pub fn adoptRootWindows() !usize {
    // Defensive boot-order guard: adoption expects the window module's state
    // (child cache, spawn queue) to be initialized; if window.init hasn't run
    // yet, there is nothing safe to touch.
    if (state == null) return 0;

    const cs = core.getState();
    const conn = cs.conn;

    const tree_reply = xcb.xcb_query_tree_reply(
        conn,
        xcb.xcb_query_tree(conn, cs.root),
        null,
    ) orelse return 0;
    defer std.c.free(tree_reply);
    const children = xcb.xcb_query_tree_children(tree_reply);
    const child_count: usize = @intCast(xcb.xcb_query_tree_children_length(tree_reply));

    const loaded = persist.loaded();

    // ----- Pass 1: fire EVERY cookie across EVERY child before draining -----
    // The per-window admission query used to be fired and drained inside this
    // loop (and the attribute query even earlier), costing one serial blocking
    // round trip for the attribute and one for the admission batch per child:
    // 1 + 2N total. Firing them all up-front lets the X server process every
    // child's attribute + property query in parallel; the replies then arrive
    // back-to-back and are drained in order below, so the batch costs a single
    // blocking read. Candidates that fail the attribute gate in pass 2 still
    // have their up-front property replies discarded, never leaked.
    const alloc = state.?.alloc orelse return 0;
    var entries: std.ArrayListUnmanaged(AdoptionEntry) = .empty;
    defer entries.deinit(alloc);
    try entries.ensureTotalCapacity(alloc, child_count);

    for (children[0..child_count]) |win| {
        // Double-manage guard (parity with handleMapRequest): never re-admit a
        // window another path already manages.
        if (tracking.isManaged(win)) continue;

        // The WM's own bar window is a root child we created; leave it alone.
        if (screen_mod.surfaceWindow()) |bar_win| if (bar_win == win) continue;

        // The restore-record lookup is a local scan; carry the result into the
        // drain pass so pass 2 does no X work before consuming each batch.
        const record = if (loaded) |f| findWindowRecord(f.windows, win) else null;

        entries.appendAssumeCapacity(.{
            .win = win,
            .attr_cookie = xcb.xcb_get_window_attributes(conn, win),
            .record = record,
            .cookies = fireAdmissionCookies(conn, win),
        });
    }

    // ----- Pass 2: drain each batch in request order -----
    var adopted: usize = 0;
    for (entries.items) |*entry| {
        const win = entry.win;

        const attr_reply = xcb.xcb_get_window_attributes_reply(conn, entry.attr_cookie, null);
        defer std.c.free(attr_reply);

        // Override-redirect windows are transient/popup, never manage.
        // Visibility gate: adopt mapped windows; adopt unmapped ONLY when
        // the restore file records them as parked (a surviving hidden
        // window must stay hidden). Other unmapped windows are likely
        // withdrawn toplevels and are skipped. A null reply means the
        // window vanished between pass 1 and this drain; release its
        // up-front admission replies without parsing them.
        const adopt = if (attr_reply) |r|
            r.*.override_redirect == 0 and
                (r.*.map_state == xcb.XCB_MAP_STATE_VIEWABLE or
                    (entry.record != null and entry.record.?.presence == .parked))
        else
            false;
        if (!adopt) {
            discardAdmissionCookies(conn, entry.cookies);
            continue;
        }

        // Claim the management event mask so the adopted window delivers the
        // PropertyNotify/StructureNotify/FocusChange events managed windows
        // rely on (mirror of handleMapRequest's preamble).
        claimManagedEventMask(conn, win);

        // Adoption never resolves the target workspace from these cookies
        // (restored-or-current wins, not spawn rules), so the two
        // conditionally-fired replies are discarded to keep the XCB queue
        // from accumulating unconsumed results. A persisted restore record
        // wins over the float rule too (it carries the window's exact
        // pre-restart anchor); record-less windows still honor a class float
        // rule, matching the MapRequest admission policy.
        const float = if (entry.record == null) resolveClassFloat(entry.cookies.c_wm_class) else false;
        drainAdmissionCookies(conn, win, entry.cookies, true);

        // Register on the restored-or-current workspace. on_current=false so
        // actions.mapRequest does NOT reconcile per-window (the caller owns
        // the single end-of-adoption reconcile) or steal model focus before
        // applyModelLevel restores the session's focus.
        admitWindow(win, restoredOrCurrent(entry.record), false, float);

        if (entry.record) |r| applyRestoredRecord(win, r);

        adopted += 1;
    }

    debug.info("Adopted {d} pre-existing windows", .{adopted});
    return adopted;
}

fn unmanageWindow(win: u32) void {
    // Covering truth is model-side (actions.unmanage reads it); the module
    // store is queried through the registry below.
    icccm.evictCache(win);

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
    const model = if (pipeline.initialized) pipeline.model() else null;
    const fs_ws: ?@import("model").WSId = if (model) |m|
        (if (providerOf(.coveringWsOf)) |wm| wm.coveringWsOf.?(m, win) else null)
    else
        null;
    var actx: actions.Ctx = .{
        .withdrawn_fullscreen_ws = fs_ws,
        .withdrawn_was_focused = if (model) |m| m.focused == win else false,
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
    var ev = std.mem.zeroes(xcb.xcb_configure_notify_event_t);
    ev.response_type = xcb.XCB_CONFIGURE_NOTIFY;
    ev.event = win;
    ev.window = win;
    ev.x = geom.x;
    ev.y = geom.y;
    ev.width = geom.width;
    ev.height = geom.height;
    ev.border_width = geom.border_width;
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
fn resolveConfigureGeometry(win: u32) ?utils.Rect {
    // Model/sync truth: floating base or last-sent ledger rect.
    if (@import("sync").truthRect(pipeline.model(), win)) |rect| {
        // W3: report the border width we actually last sent for this window
        // (the ledger), not the global config default. The two differ before
        // the first reconcile and for per-window overrides; a wrong value here
        // makes clients mis-size themselves.
        const border: u16 = if (!build_options.has_tiling)
            0
        else
            @import("sync").lastBorderWidthFor(win) orelse @import("core").borderWidth();
        return .{
            .x = rect.x,
            .y = rect.y,
            .width = rect.width,
            .height = rect.height,
            .border_width = border,
        };
    }

    const conn = core.getState().conn;
    const reply = xcb.xcb_get_geometry_reply(
        conn,
        xcb.xcb_get_geometry(conn, win),
        null,
    ) orelse return null;
    defer std.c.free(reply);
    return utils.rectFromXcb(reply, true);
}

fn sendSyntheticConfigureNotify(win: u32) void {
    const geom = resolveConfigureGeometry(win) orelse return;
    sendConfigureNotify(win, geom);
}

fn handleManagedConfigureRequest(
    win: u32,
    event: *const xcb.xcb_configure_request_event_t,
    mask: u16,
) void {
    const req: @import("model").ConfigureReq = .{
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
    const has_bw = build_options.has_tiling and mask & xcb.XCB_CONFIG_WINDOW_BORDER_WIDTH != 0;
    switch (wm.honorConfigureRequest.?(pipeline.mut(&gate), win, req)) {
        .geometry_applied => {
            // ICCCM 4.1.5: a border-width-only request applied by the module
            // needs the synthetic ConfigureNotify (the width isn't otherwise
            // observable) AND the reconcile ledger updated so the next pass
            // doesn't re-assert the WM width (reverting the honored value).
            if (mask == xcb.XCB_CONFIG_WINDOW_BORDER_WIDTH) {
                if (build_options.has_tiling) @import("sync").markSentBorderWidth(win, event.border_width);
                if (has_bw) _ = wincache.cacheBorderWidth(win, event.border_width);
                sendSyntheticConfigureNotify(win);
                return;
            }
            // W1: don't teleport an off-screen window onto the visible screen.
            // A parked (off-workspace) or non-current-workspace floating
            // window's ConfigureRequest must update its model rect (done in the
            // module above) but not move the X window, which would flash it
            // onto the current workspace; it is configured when next shown.
            const m = pipeline.model();
            if (@import("model").visibleOn(m, win, m.current))
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
            if (build_options.has_tiling) @import("sync").markSentBorderWidth(win, event.border_width);
        },
        .ignored => {},
    }
    if (has_bw) _ = wincache.cacheBorderWidth(win, event.border_width);
    // ICCCM 4.1.5: echo a synthetic ConfigureNotify so the client observes
    // its denied geometry / new border width.
    sendSyntheticConfigureNotify(win);
}

pub fn handleConfigureRequest(event: *const xcb.xcb_configure_request_event_t) void {
    const win = event.window;

    // Fast exit: no geometry fields requested, so skip the managed predicates
    // (stacking-order-only requests from compositors/override-redirect).
    const mask = event.value_mask & geometry_mask;
    if (mask == 0) return;

    // Deny min-size ConfigureRequests from the window being drag-resized.
    if (build_options.has_floating and actions.isResizingWindow(win)) {
        const last = actions.getDragLastRect();
        if (last.width != 0) {
            sendConfigureNotify(win, .{
                .x = last.x,
                .y = last.y,
                .width = last.width,
                .height = last.height,
                .border_width = borders.width(),
            });
        } else {
            sendSyntheticConfigureNotify(win);
        }
        return;
    }

    if (pipeline.initialized and tracking.isManaged(win)) {
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
        .{ xcb.XCB_CONFIG_WINDOW_X, utils.toXcbCoord(event.x) },
        .{ xcb.XCB_CONFIG_WINDOW_Y, utils.toXcbCoord(event.y) },
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
    // W4: in all-view mode every window is visible on the current workspace
    // regardless of its tag mask, so hover must be able to focus it too; a
    // bare membership check made all-view windows un-focusable by ENTER.
    if (!isOnCurrentWorkspace(win) and !pipeline.model().all_view_active) return;
    if (callHookBool(.isWindowHidden, .{ pipeline.model(), win })) return;
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

pub fn handlePropertyNotify(event: *const xcb.xcb_property_notify_event_t) void {
    if (!isValidManagedWindow(event.window)) return;
    const conn = core.getState().conn;

    // Window title (_NET_WM_NAME / WM_NAME): refresh the WM-owned title cache
    // and bump the window fact so surfaces reading titles from the cache (the
    // bar) repaint. The WM is now the sole owner of title freshness; the bar
    // does no title property fetching at all.
    const net_wm_name = utils.getAtomOrZero("_NET_WM_NAME");
    if (event.atom == xcb.XCB_ATOM_WM_NAME or (net_wm_name != 0 and event.atom == net_wm_name)) {
        if (wincache.refreshTitle(conn, event.window)) core.window.bump();
        return;
    }

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
        icccm.refreshCachedPropHalf(conn, event.window, event.atom);
    }
}

// Extract a pair of consecutive u16 fields when the flag is set and enough
// fields are present. Shared by max_size and resize_inc extraction which
// share the same 2-field pattern.
const SizePair = struct { width: u16, height: u16 };

fn extractFieldPair(
    fields: [*]const u32,
    field_count: u32,
    want: bool,
    comptime off: usize,
) SizePair {
    if (want and field_count >= off + 2) return .{
        .width = utils.scaling.clampToU16(fields[off]),
        .height = utils.scaling.clampToU16(fields[off + 1]),
    };
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
        constants.property_no_delete,
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

    const fields = icccm.u32Values(reply);
    const field_count = reply.*.value_len;
    const flags = fields[0];

    // PMinSize/PBaseSize are cached for the floating drag-resize floor only:
    // `tiling.applyHints` still ignores declared minimums (the layout engine
    // owns tiled dimensions, and honouring them there would pin the rect and
    // block mod_h/mod_l). The max/increment/aspect constraints are forwarded
    // so hint-constrained windows behave correctly in both modes.
    const want_min = flags & p_min_size != 0;
    const want_base = flags & p_base_size != 0;
    const want_max = flags & p_max_size != 0;
    const want_inc = flags & p_resize_inc != 0;
    const want_asp = flags & p_aspect != 0;

    if (!want_min and !want_base and !want_max and !want_inc and !want_asp) return;

    // PBaseSize (offset 15) is the increment base; when both are declared the
    // effective floor is the larger, so a client can never be dragged smaller
    // than either it or its base declares.
    const min_pair = extractFieldPair(fields, field_count, want_min, 5);
    const base_pair = extractFieldPair(fields, field_count, want_base, 15);
    const max_pair = extractFieldPair(fields, field_count, want_max, 7);
    const inc_pair = extractFieldPair(fields, field_count, want_inc, 9);

    // PAspect: fields[11..14] = min_aspect.x/y, max_aspect.x/y.
    // dwm convention: min_aspect = y/x (lower bound on h/w),
    //                 max_aspect = x/y (upper bound on w/h).
    const Aspect = struct { min: f32, max: f32 };
    const aspect: Aspect = if (want_asp and field_count >= 15)
        .{
            .min = if (fields[11] > 0) @as(f32, @floatFromInt(fields[12])) / @as(f32, @floatFromInt(fields[11])) else 0.0,
            .max = if (fields[14] > 0) @as(f32, @floatFromInt(fields[13])) / @as(f32, @floatFromInt(fields[14])) else 0.0,
        }
    else
        .{ .min = 0.0, .max = 0.0 };

    // The MODEL copy of size hints must never go stale, since layouts read
    // Entry.size_hints via engine.HintsView. The wincache entry is only the
    // pre-registration staging area (actions.mapRequest bridges it into the
    // freshly created model entry); once registered, the model write below is
    // the only truth and the wincache copy is never read again.
    const hints: @import("model").SizeHints = .{
        .min_width = @max(min_pair.width, base_pair.width),
        .min_height = @max(min_pair.height, base_pair.height),
        .max_width = max_pair.width,
        .max_height = max_pair.height,
        .inc_width = inc_pair.width,
        .inc_height = inc_pair.height,
        .min_aspect = aspect.min,
        .max_aspect = aspect.max,
    };
    if (pipeline.initialized) if (pipeline.mut(&gate).store.getPtr(win)) |e| {
        e.size_hints = hints;
        return;
    };
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
        // W7: parked (offscreen/minimized) windows are invisible; recoloring
        // them is pointless XCB traffic and can race the park position. The
        // unpark reconcile re-establishes their border color.
        if (entry.presence == .parked) continue;
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

/// Warn-once latches for client-message diagnostics (see
/// handleClientMessage): pager loops would otherwise flood the log.
var warned_once: u8 = 0;
inline fn warnOnce(comptime bit: u3, msg: []const u8, args: anytype) void {
    if (warned_once & (@as(u8, 1) << bit) != 0) return;
    warned_once |= @as(u8, 1) << bit;
    debug.warn(msg, args);
}

pub fn handleClientMessage(event: *const xcb.xcb_client_message_event_t) void {
    if (event.format != 32) return;

    // Unhonorable pager requests are dropped silently otherwise; both warns
    // fire once per process so a looping pager cannot flood the log.
    const net_active = utils.getAtomOrZero("_NET_ACTIVE_WINDOW");
    if (net_active != 0 and event.type == net_active) {
        warnOnce(0, "Ignoring _NET_ACTIVE_WINDOW request for 0x{x}: EWMH activation is not implemented", .{event.window});
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
        warnOnce(1, "Ignoring _NET_WM_STATE request for unmanaged window 0x{x}", .{win});
        return;
    }

    const action = event.data.data32[0];
    const is_fs = isCoveringMode(pipeline.model(), win);
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
