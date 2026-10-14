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
//! The cookie/decision/register helpers are shared with the boot-time
//! adoption driver in restore.zig, which walks the root's children the
//! same pipeline runs per MapRequest.
//!
//! One consumer remains in window.zig: handleMapRequest (the runtime
//! MapRequest path); it fires its cookies here, resolves the decision
//! here, and registers through admitWindow here — the same pipeline
//! adoptSession runs for every surviving root child.
//!
//! Mutual runtime-only dependency with window.zig (the same shape as
//! input.zig and events.zig): the wire geometry read and the
//! size-hints cache bridge used while admitting a window live there,
//! while the admission policy lives here.

const std = @import("std");

const core = @import("core");
const xcb = core.xcb;
const constants = @import("constants");
const masks = @import("masks");
const log = @import("log");
const query = @import("query");
const icccm = @import("icccm");
const identity = @import("identity");
const hints = @import("hints");
const wincache = @import("wincache");
const atoms = @import("atoms");
const actions = @import("actions");
const model_mod = @import("model");
const types = @import("types");
const window = @import("window");

// Spawn queue: pending (workspace, pid) assignments for newly-mapped windows,
// consumed by actions.mapRequest at admission. Capped at spawn_queue_capacity;
// overflow logs and drops the entry rather than growing unbounded.

const SpawnEntry = struct {
    workspace: u8,
    /// _NET_WM_PID of the grandchild; 0 for daemon-mode terminals.
    pid: u32,
};

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
    // memory.
    if (state.?.alloc) |a| {
        state.?.spawn_queue.deinit(a);
        state.?.rules_map.deinit(a);
    }
    // Set to null so any accidental post-deinit access null-derefs instead
    // of silently reading freed state. init() restores it to .{}
    // unconditionally.
    state = null;
}

/// The module allocator, null before the first init() (or after deinit).
/// The boot-time adoption driver in restore.zig uses this as its
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

    const wc = identity.parseWmClass(data) orelse return null;
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
        log.debug(
            "spawn: no exact PID match for pid={d}, {d} pending; routing to current workspace",
            .{ win_pid, state.?.spawn_queue.items.len },
        );
        return null;
    }
    log.debug(
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
    title_cookies: wincache.TitleCookies,
};

/// Fires all property-query cookies for an admitted window (WM_CLASS,
/// _NET_WM_PID, WM_NORMAL_HINTS, WM_PROTOCOLS, WM_HINTS) before any reply is
/// drained. Shared by handleMapRequest and restore.zig's adoption driver;
/// both are preceded
/// by the change_window_attributes preamble and followed by the size-hints and
/// focus-cache drains, but route the two conditional workspace cookies
/// differently, so only the firing lives here.
pub fn fireAdmissionCookies(conn: core.Connection, win: u32) AdmissionCookies {
    const cs = core.getState();

    // Workspace resolution cookies (conditional).
    const wm_class_atom = atoms.getAtomOrZero("WM_CLASS");
    const c_wm_class: ?xcb.xcb_get_property_cookie_t =
        if (cs.config.workspaces.rules.items.len > 0 and wm_class_atom != 0)
            icccm.firePropQuery(conn, win, wm_class_atom, xcb.XCB_ATOM_STRING, constants.property_max_length)
        else
            null;

    const c_net_wm_pid: ?xcb.xcb_get_property_cookie_t =
        if (state.?.spawn_queue.items.len > 0)
            icccm.firePropQuery(conn, win, atoms.getAtomOrZero("_NET_WM_PID"), xcb.XCB_ATOM_CARDINAL, 1)
        else
            null;

    // Property cookies (always fired).
    const normal_hints_cookie = icccm.firePropQuery(conn, win, xcb.XCB_ATOM_WM_NORMAL_HINTS, xcb.XCB_ATOM_WM_SIZE_HINTS, hints.wm_normal_hints_long_length);
    const protocols_cookie = icccm.fireWMProtocolsQuery(conn, win) orelse
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
pub fn claimManagedEventMask(conn: core.Connection, win: u32) void {
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
/// has already drained them via mapRequest). Returns the parsed
/// WM_NORMAL_HINTS for the caller to thread into registration: the model
/// entry does not exist yet when the reply drains, so the value travels as a
/// parameter (single store -- the model; there is no staging copy).
pub fn drainAdmissionCookies(conn: core.Connection, win: u32, cookies: AdmissionCookies, comptime discard_workspace: bool) ?model_mod.SizeHints {
    if (comptime discard_workspace) {
        icccm.discardProtocolCookie(conn, cookies.c_wm_class);
        icccm.discardProtocolCookie(conn, cookies.c_net_wm_pid);
    }
    const size_hints = window.parseSizeHints(cookies.normal_hints_cookie);
    icccm.populateFocusCacheFromCookies(conn, win, cookies.protocols_cookie, cookies.hints_cookie);
    wincache.collectTitleCookies(conn, win, cookies.title_cookies);
    return size_hints;
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
    wincache.discardTitleCookies(conn, cookies.title_cookies);
    inline for (.{
        cookies.normal_hints_cookie,
        cookies.protocols_cookie,
        cookies.hints_cookie,
    }) |ck| xcb.xcb_discard_reply(conn, ck.sequence);
}

/// Admission policy shared by the MapRequest path (handleMapRequest) and the
/// boot-time adoption path (restore.adoptSession). Both sources fire and drain
/// their property cookies and resolve the target workspace BEFORE calling
/// here; this is the single place where a window is registered with the model
/// and its keyboard grabs seeded. One map-request path, one adoption path, one
/// admission policy.
///
pub fn admitWindow(win: u32, target_ws: u8, on_current: bool, float: bool, size_hints: ?model_mod.SizeHints) void {
    const cs = core.getState();
    const float_rect: ?model_mod.Rect = if (float) window.getGeometry(cs.conn, win) else null;
    actions.mapRequest(win, target_ws, on_current, float_rect, size_hints);
}

/// Resolves only the float bit of a class rule (adoption never relocates a
/// pre-existing window's workspace, so a workspace match is deliberately
/// ignored here). Drains the WM_CLASS reply. Restore.zig's adoption path
/// is the caller; the policy stays here beside the rules map it reads.
pub fn resolveClassFloat(cookie: ?xcb.xcb_get_property_cookie_t) bool {
    const c = cookie orelse return false;
    const rule = findAdmissionRuleByClass(c) orelse return false;
    return rule.float;
}
