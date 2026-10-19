//! Window admission policy: where a newly-mapped window lands and
//! how it is registered.
//!
//! Owns the admission slice of the window manager: the workspace
//! rules map (one map, rebuilt from `config.workspaces.rules` at
//! init and on every reload), the spawn
//! queue (pending (workspace, pid) assignments consumed at the next
//! MapRequest), the five-cookie admission pipeline (fire every
//! property query up-front so the X server processes them in
//! parallel, drain the replies sequentially), the admission decision,
//! and the registration helper both admission paths run through.
//! The cookie/decision/register helpers serve both paths: the runtime
//! MapRequest pipeline and the boot-time adoption driver, which walks the
//! root's children with the same pipeline that runs per MapRequest.
//!
//! One consumer lives in window.zig: handleMapRequest (the runtime
//! MapRequest path); it fires its cookies here, resolves the decision
//! here, and registers through admitWindow here — the same pipeline
//! adoptSession runs for every surviving root child.
//!
//! Mutual runtime-only dependency with window.zig (the same shape as the
//! key/mouse dispatch pair in core/input): the wire geometry read and the
//! size-hints cache bridge used while admitting a window live there,
//! while the admission policy lives here.

const std = @import("std");
const build_options = @import("build_options");

const core = @import("core");
const xcb = core.xcb;
const masks = @import("masks");
const log = std.log.scoped(.admission);
const query = @import("query");
const icccm = @import("icccm");
const reply_mod = @import("reply");
const title_cache = @import("title_cache");
const atoms = @import("atoms");
const contract = @import("tiling_contract");
const focus = @import("focus");
const model_mod = @import("model");
const window_state_ops = @import("window_state_ops");
const tiling_seam = @import("tiling_seam");
const types = @import("types");
const window = @import("window");
const session = @import("session");
const pipeline = @import("pipeline");
const reconcile = @import("reconcile");
const usable_area_mod = @import("usable_area");
const window_mods = @import("window_modules").modules;
const registry = @import("registry");

// Spawn queue: pending (workspace, pid) assignments for newly-mapped windows,
// consumed by mapRequest below at admission. Capped at spawn_queue_capacity;
// overflow logs and drops the entry rather than growing unbounded.

pub const SpawnEntry = struct {
    workspace: u8,
    /// _NET_WM_PID of the grandchild; 0 for daemon-mode terminals.
    pid: u32,
};

/// One spawn-queue match: the INDEX of the entry to consume (swapRemove
/// order, which carries no meaning) and WHETHER it matched by exact PID or
/// by the sole-entry heuristic (the caller logs the two differently).
pub const SpawnMatch = struct {
    index: usize,
    heuristic: bool,
};

/// The spawn-queue match POLICY, split from the XCB reply drain below so it
/// is testable without a server (P1-19): returns which pending entry this
/// window's PID claims, or null when nothing unambiguously matches.
///
///   - Exact PID hit, gated on `win_pid != 0`: a window without
///     _NET_WM_PID must never consume a daemon entry (pid == 0) by exact
///     match — that would conflate "terminal that will fork a grandchild"
///     with "app that simply doesn't set the property".
///   - Sole-entry fallback: with exactly one pending entry there is no
///     ambiguity (the app was launched via `sh -c "cmd"` and the window
///     reports a grandchild PID), so it is consumed whatever the PID
///     says — including when that one entry is a daemon entry, since a
///     single pending spawn still has no rival to be mis-routed against.
///   - Ambiguous (0 or >1 entries with no exact hit): null, and the caller
///     falls back to the current workspace rather than guessing
///     oldest-first (consuming items[0] would mis-route the window to the
///     oldest pending spawn's workspace).
pub fn spawnQueueMatch(queue: []const SpawnEntry, win_pid: u32) ?SpawnMatch {
    for (queue, 0..) |e, i| {
        if (win_pid != 0 and e.pid == win_pid) return .{ .index = i, .heuristic = false };
    }
    if (queue.len != 1) return null;
    return .{ .index = 0, .heuristic = true };
}

// Bounds pending spawns awaiting their first map, not the tiled-window pool.
const spawn_queue_capacity: usize = 64;

// Admission-side state is grouped into a single State struct (mirroring
// the pattern focus.zig uses) so init()/deinit() each reset everything
// in one assignment, and a deinit()+init() cycle can't leave a stale
// field behind. The admission module is initialized from window.init,
// so its state is null exactly when the window module's is.
const State = struct {
    /// Module allocator, set in init(). Null before the first init() call.
    alloc: ?std.mem.Allocator = null,

    spawn_queue: std.ArrayListUnmanaged(SpawnEntry) = .empty,

    // The single class-rule fast-lookup map: WM_CLASS name -> outcome
    // (null = float rule, u8 = target workspace), rebuilt from
    // config.workspaces.rules at init and on every reload. First rule wins;
    // a name lives at most once. Keys borrow slices from the config, valid
    // until the next rebuild.
    rules_map: std.StringHashMapUnmanaged(?u8) = .{},
};

var state: ?State = null;

/// Admission-side lifecycle: resets the admission state (spawn queue,
/// rules map) and rebuilds the map from the current config. Called from
/// window.init, after the window module's own sub-systems are up.
pub fn init(alloc: std.mem.Allocator) void {
    // Reset every field to its zero value so that a deinit() + init()
    // cycle (session restart, test harness) starts from a clean slate
    // rather than carrying over whatever the previous cycle left behind.
    state = .{};
    state.?.alloc = alloc;
    // Pre-allocate spawn queue capacity for the common case (a handful of
    // concurrent spawns). Failure is non-fatal; the list grows on demand.
    state.?.spawn_queue.ensureTotalCapacity(alloc, 16) catch |err| {
        log.warn(
            "admission: spawn queue pre-allocation failed ({s}); will grow on demand",
            .{@errorName(err)},
        );
    };
    buildRulesMap();
}

pub fn deinit() void {
    // Free heap-backed state before the reset below wipes the struct; a bare
    // `state = .{}` would leak the spawn queue's and rules map's backing
    // memory. Guarded by `if (state)` instead of unwrapping: deinit is
    // idempotent (P1-40) -- a second call, or one before the first init, is
    // a no-op rather than a null-unwrap panic.
    if (state) |*s| {
        if (s.alloc) |a| {
            s.spawn_queue.deinit(a);
            s.rules_map.deinit(a);
        }
    }
    // Set to null so any accidental post-deinit access null-derefs instead
    // of silently reading freed state. init() restores it to .{}
    // unconditionally.
    state = null;
}

/// The module allocator, null before the first init() (or after deinit).
/// The boot-time adoption driver (session adoption, below) uses this as its
/// readiness guard: admission state exists exactly when window.init has
/// run, so a null allocator means boot is too early to touch the queue,
/// the rules map, or the cookie pipeline.
pub fn allocator() ?std.mem.Allocator {
    if (state == null) return null;
    return state.?.alloc;
}

/// Rebuilds `rules` from a config's rule list (the pure half of
/// buildRulesMap, so the first-wins merge is testable without a server).
/// A float rule stores null, a workspace rule its target; a name lives at
/// most once and the first rule for it wins, matching a plain linear scan
/// through the rule list (getOrPut: an existing key keeps its value, so a
/// later rule of either kind never overwrites it). Keys are borrowed slices
/// into the config's allocations, valid until the next rebuild. On OOM the
/// entry is silently dropped, the window behaves as if unruled.
pub fn buildRulesMapFrom(
    rules: *std.StringHashMapUnmanaged(?u8),
    alloc: std.mem.Allocator,
    config_rules: []const types.Rule,
) void {
    rules.clearRetainingCapacity();
    for (config_rules) |rule| {
        const value: ?u8 = if (rule.float) null else rule.workspace;
        const gop = rules.getOrPut(alloc, rule.class_name) catch continue;
        if (!gop.found_existing) gop.value_ptr.* = value;
    }
}

/// Rebuilds the live map from the current config (see buildRulesMapFrom).
pub fn buildRulesMap() void {
    if (comptime !build_options.has_workspaces) return;
    const alloc = state.?.alloc orelse return;
    buildRulesMapFrom(&state.?.rules_map, alloc, core.getState().config.workspaces.rules.items);
}

pub inline fn clampToValidWorkspace(target: u8, fallback: core.WorkspaceId) core.WorkspaceId {
    return if (target < query.getWorkspaceCount())
        core.WorkspaceId.fromIndex(target)
    else
        fallback;
}

/// A matched class rule: either a workspace target or the float marker. The
/// float bit is set for "float" rules, in which case `workspace` is null and
/// the window is admitted floating on the current workspace.
const AdmissionRule = struct {
    workspace: ?u8,
    float: bool,
};

/// Resolves a pre-fired WM_CLASS property cookie against workspace and float
/// rules. Parses the WM_CLASS reply inline (no allocation), then does one
/// O(1) hash lookup per candidate key (class, then instance). The map is
/// built at init() and after every config reload, so no linear rule scan
/// runs at spawn time.
fn findAdmissionRuleByClass(cookie: xcb.xcb_get_property_cookie_t) ?AdmissionRule {
    const reply = xcb.xcb_get_property_reply(core.getState().conn, cookie, null) orelse return null;
    defer std.c.free(reply);
    if (reply.*.format != 8 or reply.*.value_len == 0) return null;

    const raw: [*]const u8 = @ptrCast(xcb.xcb_get_property_value(reply));
    const data = raw[0..reply.*.value_len];

    const wc = reply_mod.parseWmClass(data) orelse return null;
    return matchRule(&state.?.rules_map, wc.instance, wc.class);
}

/// The WM_CLASS rule match, split from the XCB property read above so the
/// POLICY is testable without a server: one O(1) hash lookup per candidate
/// key, class first (when non-empty) then instance; a null map value marks a
/// float rule. Reading a property is not part of this decision.
pub fn matchRule(
    rules: *const std.StringHashMapUnmanaged(?u8),
    instance: []const u8,
    class: []const u8,
) ?AdmissionRule {
    if (class.len > 0) {
        if (rules.get(class)) |ws| return .{ .workspace = ws, .float = ws == null };
    }
    if (instance.len > 0) {
        if (rules.get(instance)) |ws| return .{ .workspace = ws, .float = ws == null };
    }
    return null;
}

/// Tries an exact PID match first, then falls back to the sole-pending-entry
/// heuristic. The caller only fires `c_net_wm_pid` when the queue is non-empty,
/// so no empty-queue case is handled here. The POLICY itself lives in
/// spawnQueueMatch (pure, headless-tested); this half only drains the reply.
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

    const match = spawnQueueMatch(state.?.spawn_queue.items, win_pid) orelse {
        log.debug(
            "spawn: no exact PID match for pid={d}, {d} pending; routing to current workspace",
            .{ win_pid, state.?.spawn_queue.items.len },
        );
        return null;
    };
    if (match.heuristic) {
        log.debug(
            "spawn: no exact PID match for pid={d}, sole entry ws={d}, using heuristic",
            .{ win_pid, state.?.spawn_queue.items[match.index].workspace },
        );
    }
    // swapRemove returns the removed entry; order has no semantic meaning.
    const removed = state.?.spawn_queue.swapRemove(match.index);
    return removed.workspace;
}

/// The admission policy for a brand-new spawn: the target workspace (class
/// rule, then spawn-queue PID rule, else current) plus whether the class rule
/// floats the window.
const AdmissionDecision = struct {
    workspace: core.WorkspaceId,
    float: bool,
};

/// Drains pre-fired WM_CLASS / _NET_WM_PID cookies to resolve the admission
/// decision. Cookies are fired by the caller (handleMapRequest) together with
/// the other three property queries so the X server can process all five in
/// parallel; this function only drains the two workspace-resolution replies.
pub fn resolveAdmissionDecision(
    current_ws: core.WorkspaceId,
    c_wm_class: ?xcb.xcb_get_property_cookie_t,
    c_net_wm_pid: ?xcb.xcb_get_property_cookie_t,
) AdmissionDecision {
    const cs = core.getState();

    // Drain replies: WM_CLASS first, then _NET_WM_PID.
    if (c_wm_class) |cookie| if (findAdmissionRuleByClass(cookie)) |rule| {
        icccm.discardProtocolCookie(cs.conn, c_net_wm_pid);
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
    if (state.?.spawn_queue.items.len >= spawn_queue_capacity) {
        log.warn(
            "registerSpawn: spawn queue full ({d} entries); entry dropped",
            .{spawn_queue_capacity},
        );
        return;
    }
    state.?.spawn_queue.append(alloc, .{ .workspace = workspace.index, .pid = pid }) catch |err| {
        log.warn("registerSpawn: failed to queue spawn entry: {}", .{err});
    };
}

/// The five property-query cookies fired for an admitted window. All are
/// fired up-front (before any reply is drained) so the X server processes
/// them in parallel; the callers differ only in how they drain the two
/// workspace-resolution cookies (rules/spawn resolution vs. discard).
pub const AdmissionCookies = struct {
    c_wm_class: ?xcb.xcb_get_property_cookie_t,
    c_net_wm_pid: ?xcb.xcb_get_property_cookie_t,
    normal_hints_cookie: xcb.xcb_get_property_cookie_t,
    protocols_cookie: xcb.xcb_get_property_cookie_t,
    hints_cookie: xcb.xcb_get_property_cookie_t,
    /// ICCCM WM_TRANSIENT_FOR (dialog parent). Always fired with the rest so
    /// the server processes it in parallel; drained by drainAdmissionCookies
    /// into the AdmissionDrain's transient_for.
    transient_cookie: xcb.xcb_get_property_cookie_t,
    title_cookies: title_cache.TitleCookies,
};

/// Fires all property-query cookies for an admitted window (WM_CLASS,
/// _NET_WM_PID, WM_NORMAL_HINTS, WM_PROTOCOLS, WM_HINTS) before any reply is
/// drained. Shared by handleMapRequest and the session-adoption driver below;
/// both are preceded
/// by the change_window_attributes preamble and followed by the size-hints and
/// focus-cache drains, but route the two conditional workspace cookies
/// differently, so only the firing lives here.
pub fn fireAdmissionCookies(conn: core.Connection, win: u32) AdmissionCookies {
    const cs = core.getState();

    // Workspace resolution cookies (conditional).
    const wm_class_atom = atoms.getAtomOrZero("WM_CLASS");
    const c_wm_class: ?xcb.xcb_get_property_cookie_t =
        if (comptime build_options.has_workspaces)
            if (cs.config.workspaces.rules.items.len > 0 and wm_class_atom != 0)
                icccm.firePropQuery(conn, win, wm_class_atom, xcb.XCB_ATOM_STRING, icccm.property_max_length)
            else
                null
        else
            null;

    const c_net_wm_pid: ?xcb.xcb_get_property_cookie_t =
        if (state.?.spawn_queue.items.len > 0)
            icccm.firePropQuery(conn, win, atoms.getAtomOrZero("_NET_WM_PID"), xcb.XCB_ATOM_CARDINAL, 1)
        else
            null;

    // Property cookies (always fired).
    const normal_hints_cookie = icccm.firePropQuery(conn, win, xcb.XCB_ATOM_WM_NORMAL_HINTS, xcb.XCB_ATOM_WM_SIZE_HINTS, reply_mod.wm_normal_hints_long_length);
    const protocols_cookie = icccm.fireWMProtocolsQuery(conn, win) orelse
        icccm.firePropQuery(conn, win, 0, xcb.XCB_ATOM_ATOM, icccm.property_max_length);
    const hints_cookie = icccm.firePropQuery(conn, win, xcb.XCB_ATOM_WM_HINTS, xcb.XCB_ATOM_WM_HINTS, icccm.wm_hints_long_length);
    const transient_cookie = icccm.firePropQuery(conn, win, xcb.XCB_ATOM_WM_TRANSIENT_FOR, xcb.XCB_ATOM_WINDOW, 1);

    return .{
        .c_wm_class = c_wm_class,
        .c_net_wm_pid = c_net_wm_pid,
        .normal_hints_cookie = normal_hints_cookie,
        .protocols_cookie = protocols_cookie,
        .hints_cookie = hints_cookie,
        .transient_cookie = transient_cookie,
        .title_cookies = title_cache.fireTitleCookies(conn, win),
    };
}

/// Claims the management event mask so `win` delivers PropertyNotify/
/// StructureNotify/FocusChange events (shared MapRequest/adoption preamble).
pub fn claimManagedEventMask(conn: core.Connection, win: u32) void {
    _ = xcb.xcb_change_window_attributes(
        conn,
        win,
        xcb.XCB_CW_EVENT_MASK,
        &[_]u32{masks.EventMasks.managed_window},
    );
}

/// Everything drainAdmissionCookies extracts from a fired cookie batch: the
/// parsed size hints and the ICCCM transient parent (dialog placement).
pub const AdmissionDrain = struct {
    size_hints: ?model_mod.SizeHints,
    /// WM_TRANSIENT_FOR's parent window id, or null for a non-transient
    /// window. The id is unvalidated here; admitWindow resolves it against
    /// the model (preferred) or the X server (unmanaged parent).
    transient_for: ?u32,
};

/// Drains the three unconditionally-fired admission cookies plus the
/// transient cookie; with `discard_workspace` the two conditional
/// workspace-resolution replies are discarded instead (adoption never
/// resolves from them; the MapRequest path has already drained them via
/// mapRequest). Returns the parsed WM_NORMAL_HINTS for the caller to thread
/// into registration (the model entry does not exist yet when the reply
/// drains, so the value travels as a parameter -- single store: the model;
/// there is no staging copy) and the transient parent.
pub fn drainAdmissionCookies(conn: core.Connection, win: u32, cookies: AdmissionCookies, comptime discard_workspace: bool) AdmissionDrain {
    if (comptime discard_workspace) {
        icccm.discardProtocolCookie(conn, cookies.c_wm_class);
        icccm.discardProtocolCookie(conn, cookies.c_net_wm_pid);
    }
    const size_hints = window.parseSizeHints(cookies.normal_hints_cookie);
    icccm.populateFocusCacheFromCookies(conn, win, cookies.protocols_cookie, cookies.hints_cookie);
    title_cache.collectTitleCookies(conn, win, cookies.title_cookies);
    return .{
        .size_hints = size_hints,
        .transient_for = drainTransientFor(conn, cookies.transient_cookie),
    };
}

/// Drains WM_TRANSIENT_FOR: a WINDOW-typed property holding the dialog's
/// parent id. Absent, empty, or wrong-typed means non-transient.
fn drainTransientFor(conn: core.Connection, cookie: xcb.xcb_get_property_cookie_t) ?u32 {
    const reply = xcb.xcb_get_property_reply(conn, cookie, null) orelse return null;
    defer std.c.free(reply);
    if (reply.*.format != 32 or reply.*.value_len == 0) return null;
    const parent = icccm.u32Values(reply)[0];
    return if (parent == xcb.XCB_WINDOW_NONE) null else parent;
}

/// Discards every cookie in a fired AdmissionCookies batch without parsing it.
/// adoptSession fires admission cookies for ALL root children up-front, so
/// a candidate that fails its attribute gate (vanished / override-redirect /
/// unmapped-and-unparked) must still consume its own batch to keep the XCB
/// reply stream from accumulating unconsumed results. Firing order is preserved
/// so replies are read back in request order alongside the drain path.
pub fn discardAdmissionCookies(conn: core.Connection, cookies: AdmissionCookies) void {
    icccm.discardProtocolCookie(conn, cookies.c_wm_class);
    icccm.discardProtocolCookie(conn, cookies.c_net_wm_pid);
    title_cache.discardTitleCookies(conn, cookies.title_cookies);
    inline for (.{
        cookies.normal_hints_cookie,
        cookies.protocols_cookie,
        cookies.hints_cookie,
        cookies.transient_cookie,
    }) |ck| xcb.xcb_discard_reply(conn, ck.sequence);
}

/// The map-request tail and the post-geometry focus handoff. Both end in ONE
/// model transition plus ONE reconcile, and both sit here because admission
/// is what knows whether a window has been registered at all.
/// MapRequest tail. The caller's front-end (event masks, property queries)
/// has already run; this registers the window in
/// the model and lets ONE reconcile do map+pixel+bw+geom(+ABOVE winner) for
/// on-current spawns. Off-current spawns park by construction; the reconciler sends
/// their border width at first show instead of immediately (invisible either
/// way; one less request).
///
/// `float_rect` admits the window already floating: the entry is registered
/// tiled (core membership is tiled-only) and then immediately detached to the
/// given rect with no home-list membership, mirroring detachTiledToFloating's
/// anchor/home_ws state. The reconcile tail then sizes it floating in one
/// reconcile, so a float-rule spawn never flashes a tiled slot.
///
/// `size_hints` is the admission drain's parsed WM_NORMAL_HINTS, threaded
/// through as a parameter because no model entry exists when the reply
/// drains. The model entry is the single store for size hints.
/// Where a freshly-admitted tiled window should be reordered to on `home`:
/// the primary-column head slot (index 0) under the active layout's fifo
/// variant, null otherwise (lifo, single-window lists, non-fifo layouts).
///
/// Pure and headless: the whole spawn-placement decision, extracted so
/// admission_test can pin both variants without an X server. The policy is
/// metadata-driven — the active module declares which of its variant indices
/// is the fifo one (`fifo_variant`), and the new window only takes the head
/// when that variant is active AND a previous window already holds the slot
/// (`tiled_order.len > 1`), so the first window on an empty column is never
/// reordered.
pub fn spawnPlacementTarget(m: *const model_mod.Model, home: model_mod.WSId) ?usize {
    if (!build_options.has_tiling) return null;
    const p = &m.ws[home.index].params;
    const mv = contract.moduleOf(p.kind) orelse return null;
    const v = mv.fifo_variant orelse return null;
    if (p.variant_idx != v) return null;
    if (m.ws[home.index].tiled_order.len <= 1) return null;
    return 0; // fifo: the new window lands at the head; the old head drops one slot
}

/// The map front-end for one MapRequest: resolve the admission cookies'
/// replies, then admit. The window is mapped under the same grab that does
/// the model write, so a tiled spawn never flashes at its default position.
pub fn mapRequest(
    win: model_mod.WindowId,
    target_ws: u8,
    on_current: bool,
    float_rect: ?model_mod.Rect,
    size_hints: ?model_mod.SizeHints,
) void {
    const m = pipeline.mut();
    if (query.isManaged(win)) return; // double-manage guard, see query.isManaged

    // Mirror of handleMapRequest's preamble: claim the managed event mask so
    // a window admitted through this DIRECT entry (the tests' admission
    // path -- production arrives via handleMapRequest, which claims before
    // it gets here) delivers the same PropertyNotify/StructureNotify/
    // FocusChange stream a production window does. Without it a test could
    // assert focus/property behaviour that never sees the events production
    // acts on (the P1-09 FocusIn reassert is exactly that class).
    claimManagedEventMask(core.getState().conn, win);

    // A defined refusal (store or home-list full) leaves the window
    // unmanaged.
    window_state_ops.register(m, win, if (on_current) null else model_mod.WSId.fromIndex(target_ws)) catch {
        log.warn("mapRequest: capacity full; window 0x{x} left unmanaged", .{win});
        // Evict, or a refused window's XID lingers in the cache forever: XIDs
        // are recycled, so the next client to be handed this id would inherit
        // a stale title/child entry and read the wrong window.
        title_cache.removeWindow(win);
        return;
    };
    // Install the admission drain's WM_NORMAL_HINTS on the fresh entry (no
    // entry existed when the reply drains, hence the parameter above).
    const e = m.store.getPtr(win);
    if (e) |ep| {
        if (size_hints) |h| ep.size_hints = h;
    }

    // Float-rule admission: detach the entry from its tiled slot before the
    // fifo placement runs (which assumes a home slot, nonsensical for a
    // floating window). The anchor/home_ws state mirrors toggleFloating's
    // detach, and the reconcile tail applies the rect in the same reconcile.
    if (float_rect) |rect| {
        if (e) |ep| model_mod.detachTiledToFloating(m, ep, win, rect);
    } else {
        // Primary-fifo variant spawn placement (it is SPAWN policy, not
        // membership policy — register itself lives in window_state_ops):
        // a new window takes the primary-column head slot, and the previous
        // head window drops one slot. Pinned headlessly by
        // spawnPlacementTarget (admission_test), which is the whole decision.
        {
            // Clamp the requested home workspace so a misconfigured target
            // can't index past the `ws` array in ReleaseFast (defense in depth;
            // the MapRequest front-end already resolves/clamps the target).
            const home: model_mod.WSId = if (on_current)
                m.current
            else
                window.clampToValidWorkspace(target_ws, model_mod.WSId.fromIndex(m.current.index));
            if (spawnPlacementTarget(m, home)) |head_slot|
                tiling_seam.reorderTiled(m, win, head_slot);
        }
    }
    focus.initWindowGrabs(win); // protocol-side keygrabs, both paths do this
    core.window.bump(); // a window was admitted

    if (!on_current) return;

    // Focus prep before the model write (same rule as focusFallback): a
    // spawned no_input window must never take model focus -- its focus
    // protocol can't land, so marking it focused would leave borders and
    // stacking claiming a focus X will never deliver. X input focus lands
    // AFTER the reconcile, inside the same grab: the window must be mapped
    // before xcb_set_input_focus, so both map+focus land under one grab.
    const ft = focus.prepareAndSetFocus(m, win, .window_spawn);
    pipeline.reconcileGrabFocus(.{}, ft, .after, null);
}

/// The tail shared with session adoption: put X input focus on whatever the
/// model says is focused, inside one grab AFTER geometry, or -- when nothing is
/// focused -- reconcile under the grab with no focus handoff.
///
/// Adopted windows are already mapped, so the mapRequest path's ordering
/// ("map, then focus, in the same grab") is satisfied here for the same
/// reason. Both callers need this to be identical: a session that adopts 40
/// windows and then focuses differently from a session that spawned them is a
/// bug that only shows up after a re-exec.
pub fn focusAfterGeometry() void {
    if (pipeline.state().focused) |focused| {
        const ft = focus.prepareAndSetFocus(pipeline.mut(), focused, .window_spawn);
        pipeline.reconcileGrabFocus(.{}, ft, .after, null);
    } else {
        pipeline.reconcileGrab(.{});
    }
}

/// Admission policy shared by the MapRequest path (handleMapRequest) and the
/// boot-time adoption path (adoptSession). Both sources fire and drain
/// their property cookies and resolve the target workspace BEFORE calling
/// here; this is the single place where a window is registered with the model
/// and its keyboard grabs seeded. One map-request path, one adoption path, one
/// admission policy.
///
pub fn admitWindow(
    win: u32,
    target_ws: u8,
    on_current: bool,
    float: bool,
    size_hints: ?model_mod.SizeHints,
    transient_for: ?u32,
) void {
    const cs = core.getState();
    // A transient (dialog) is floating by definition, rule or not: tiling a
    // dialog against its neighbors is not a placement any toolkit asks for,
    // and the centered-over-parent placement below only has meaning on a
    // floating anchor.
    const as_float = float or transient_for != null;
    var float_rect: ?model_mod.Rect = if (as_float) window.getGeometry(cs.conn, win) else null;
    if (float_rect) |*fr| {
        if (transient_for) |parent| {
            if (parentCenteredRect(parent, fr.*)) |centered| fr.* = centered;
        }
    }
    mapRequest(win, target_ws, on_current, float_rect, size_hints);
}

/// Center a dialog over its WM_TRANSIENT_FOR parent, clamped to the work
/// area. Parent truth comes from the model when the parent is managed (no
/// round trip); an unmanaged-but-live parent falls back to one geometry
/// query; a vanished parent means no centering and the dialog keeps its own
/// pre-map position (float_rect's client-side geometry).
fn parentCenteredRect(parent: u32, dialog: model_mod.Rect) ?model_mod.Rect {
    const m = pipeline.state();
    const parent_rect: model_mod.Rect = reconcile.truthRect(m, parent) orelse
        window.getGeometry(core.getState().conn, parent) orelse return null;
    return model_mod.centerRectIn(parent_rect, dialog.width, dialog.height, usable_area_mod.workArea(core.getState().screen));
}

/// Resolves only the float bit of a class rule (adoption never relocates a
/// pre-existing window's workspace, so a workspace match is deliberately
/// ignored here). Drains the WM_CLASS reply. The session-adoption path
/// is the caller; the policy stays here beside the rules map it reads.
pub fn resolveClassFloat(cookie: ?xcb.xcb_get_property_cookie_t) bool {
    const c = cookie orelse return false;
    const rule = findAdmissionRuleByClass(c) orelse return false;
    return rule.float;
}

/// Session adoption: the re-exec-only path where a successor WM takes over
/// the X clients a predecessor left behind. main calls adoptSession exactly
/// once -- after surfaces.init() (bar up so bar-aware work area is live) and
/// before events.run() -- sequencing handoff, window adoption, and focus
/// against each other.
/// Adopt the session described by `restore_path`, if there is one to adopt.
///
/// Called after the bar is up, so the bar-aware work area is already live and
/// the single reconcile that follows places windows against the same geometry a
/// normal boot would use. A missing or unreadable restore file is not an
/// error: that is an ordinary first boot.
pub fn adoptSession(restore_path: []const u8) void {
    if (!session.loadToGlobal(core.getState().alloc, restore_path)) return;

    const n = adoptRootWindows() catch |err| blk: {
        log.err("Window adoption failed: {}", .{err});
        break :blk 0;
    };
    // Nothing adopted: the file named windows the server no longer has, and
    // there is no level to re-apply and nothing to focus.
    if (n == 0) return;

    // Re-play the persisted level now that every window is registered; no
    // reconcile here — the single reconcile after adoptSession places every
    // adopted window exactly as it was.
    session.applyModelLevel(pipeline.mut());
    focusAfterGeometry();
}

/// Linear scan for a window's restore record. Restore files are small
/// (bounded by the model's store_capacity), so a flat scan is cache-local and
/// avoids allocating a lookup map just for adoption.
fn findWindowRecord(windows: []const session.WindowRecord, win: u32) ?*const session.WindowRecord {
    for (windows) |*r| {
        if (r.win == win) return r;
    }
    return null;
}

/// Target workspace for an adopted window: the restore record's home
/// workspace (lowest set bit of its mask) when present, else the currently
/// active workspace. Deliberately NOT the spawn-queue/rules resolution, which
/// describes brand-new spawns rather than pre-existing windows.
fn restoredOrCurrent(record: ?*const session.WindowRecord) u8 {
    if (record) |r| {
        if (r.mask != 0) return @intCast((model_mod.lowestBit(r.mask) orelse unreachable).index);
    }
    return query.getCurrentWorkspace() orelse 0;
}

/// Re-applies a restore record's mask, anchor, and ext-driven presence onto an
/// already-registered model entry. Registration (admitWindow ->
/// mapRequest) creates the entry as a present tiled-anchored window on
/// its target workspace; this overwrites the per-window state that survived
/// the re-exec so the caller's reconcile can place it exactly as before.
/// Presence bookkeeping that would otherwise drift is routed through the owning
/// window module's deserialize hook rather than patched by hand (the record's
/// own `presence`/`covering_ws` fields are deliberately NOT read here: the
/// model-authoritative covering phase is `session.applyModelLevel`, pinned in
/// session_test's F10 — this fn owns mask/anchor/ext only).
///
/// Takes the model as a parameter (the `buildRulesMapFrom`/`matchRule` split)
/// so the whole policy is testable headlessly against a local model; the
/// single production call site passes `pipeline.mut()`.
pub fn applyRestoredRecord(m: *model_mod.Model, win: u32, record: *const session.WindowRecord) void {
    const e = m.store.getPtr(win) orelse return;

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
    // same dispatch. When no module claims the blob (the feature was stripped, or
    // the record carried no ext), the entry stays present and reconciles
    // on-screen -- the graceful degrade.
    //
    // Claim resolution: the blob is stamped with the claiming module's NAME at
    // save time (session.ext_format_version). Adoption fast-paths on the name;
    // when the name no longer resolves (the module was removed or renamed) or
    // its hook declines, the magic-byte scan over every module's
    // self-identifying format tag claims it instead. Blobs written by the
    // pre-name format still resolve through their registry ordinal.
    if (record.ext) |stored| {
        // A recognised header narrows WHICH module is asked first; it never
        // decides the outcome, because the payload's own magic bytes do that.
        // Anything unrecognised (a foreign version, a truncated header) is
        // passed through whole, exactly as an unstamped blob was.
        const header = session.decodeExt(stored);
        const payload: []const u8 = header.payload;
        if (header.claimed_name) |name| {
            for (window_mods) |mod| {
                if (!std.mem.eql(u8, mod.name, name)) continue;
                if (mod.deserializeWindow) |f| {
                    if (f(win, payload, m)) return;
                }
                break; // named claimant found; the scan below is the fallback
            }
        } else if (header.legacy_ordinal) |ordinal| {
            if (ordinal < window_mods.len) {
                if (window_mods[ordinal].deserializeWindow) |f| {
                    if (f(win, payload, m)) return;
                }
            }
        }
        // Uniform magic-byte claim scan: every module in registry order gets
        // a chance; the first hook to claim (return true) ends the scan, so
        // this is dispatchFirstTrue's stop-at-first-true shape rather than a
        // full fan-out.
        _ = registry.dispatchFirstTrue(.deserializeWindow, .{ win, payload, m });
    }
}

const AdoptionEntry = struct {
    win: u32,
    attr_cookie: xcb.xcb_get_window_attributes_cookie_t,
    record: ?*const session.WindowRecord,
    cookies: AdmissionCookies,
};

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
///   - each admitted window registers through the shared
///     admitWindow path on
///     its restored-or-current workspace;
///   - a restore record (if any) then re-applies the window's mask, mode, and
///     presence directly on the model entry.
///
/// CALLING CONTRACT: this does NOT reconcile. Placement derives from
/// tiled_order / focus_mru, which are rebuilt by session.applyModelLevel
/// AFTER this returns; a reconcile here would place pre-restore state.
/// adoptSession therefore sequences:
///     adoptRootWindows(); session.applyModelLevel(m); one reconcile.
/// Returns the number of windows admitted (restored-parked ones included).
///
/// PIPELINING: MapRequest pipelines one window's five property queries. Boot
/// restore pipelines the attribute + property query of every root child: fires
/// all cookies across all children into a single list, then drains each
/// batch in request order. The X server answers the whole batch back-to-back,
/// so the once per-window serial attribute-then-properties pattern collapses to
/// ~2 blocking reads total (the query_tree reply plus one drain that pulls the
/// entire batch off the wire).
fn adoptRootWindows() !usize {
    // Defensive boot-order guard: adoption runs the admission pipeline below
    // (spawn queue, rules maps, allocator). init is called from
    // window.init AFTER the window module's own sub-systems are up, so a null
    // allocator means boot is too early and nothing is safe to touch yet.
    const alloc = allocator() orelse return 0;

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

    const loaded = session.loaded();

    // The attribute query and the per-window admission queries are all fired
    // up-front, before any reply is drained: the serial alternative costs one
    // blocking round trip for the attribute plus one for the admission batch
    // per child (1 + 2N total). Firing them all up-front lets the X server
    // process every child's attribute + property query in parallel; the
    // replies then arrive back-to-back and are drained in order below, so the
    // batch costs a single blocking read. Candidates that fail the attribute
    // gate during the drain still have their up-front property replies
    // discarded, never leaked.
    var entries: std.ArrayListUnmanaged(AdoptionEntry) = .empty;
    defer entries.deinit(alloc);
    try entries.ensureTotalCapacity(alloc, child_count);

    for (children[0..child_count]) |win| {
        // Same guard as window.handleMapRequest: never re-admit a window another path
        // already manages.
        if (query.isManaged(win)) continue;

        // The WM's own bar window is a root child we created; leave it alone.
        if (usable_area_mod.surfaceWindow()) |bar_win| if (bar_win == win) continue;

        // The restore-record lookup is a local scan; carry the result into the
        // drain loop so it does no X work before consuming each batch.
        const record = if (loaded) |f| findWindowRecord(f.windows, win) else null;

        entries.appendAssumeCapacity(.{
            .win = win,
            .attr_cookie = xcb.xcb_get_window_attributes(conn, win),
            .record = record,
            .cookies = fireAdmissionCookies(conn, win),
        });
    }

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
        // window vanished between the cookie fire and this drain; release its
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
        // rely on (mirror of window.handleMapRequest's preamble).
        claimManagedEventMask(conn, win);

        // Adoption never resolves the target workspace from these cookies
        // (restored-or-current wins, not spawn rules), so the two
        // conditionally-fired replies are discarded to keep the XCB queue
        // from accumulating unconsumed results. A persisted restore record
        // wins over the float rule too (it carries the window's exact
        // pre-restart anchor); record-less windows still honor a class float
        // rule, matching the MapRequest admission policy.
        const float = if (entry.record == null) resolveClassFloat(entry.cookies.c_wm_class) else false;
        // resolveClassFloat already consumed the WM_CLASS reply, so draining it
        // again (drainAdmissionCookies with all=true) would double-dispose
        // the same XCB reply (a freed sequence wedged at the 16-bit wrap, plus
        // a leaked discard entry per adopted window). Null it out in the drain
        // copy: the spawn-queue cookie is still discarded below, and when a
        // restore record supplied the anchor resolveClassFloat never ran, so
        // c_wm_class stays live and is discarded here as before.
        var drain_cookies = entry.cookies;
        if (entry.record == null) drain_cookies.c_wm_class = null;
        const drain = drainAdmissionCookies(conn, win, drain_cookies, true);

        // Register on the restored-or-current workspace. on_current=false so
        // mapRequest does NOT reconcile per-window (the caller owns
        // the single end-of-adoption reconcile) or steal model focus before
        // applyModelLevel restores the session's focus.
        admitWindow(win, restoredOrCurrent(entry.record), false, float, drain.size_hints, drain.transient_for);

        if (entry.record) |r| applyRestoredRecord(pipeline.mut(), win, r);

        adopted += 1;
    }

    log.info("Adopted {d} pre-existing windows", .{adopted});
    return adopted;
}
