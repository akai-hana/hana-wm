//! Window admission policy: where a newly-mapped window lands and
//! how it is registered.
//!
//! Owns the admission slice of the window manager: the workspace
//! rules map and float-rules map (rebuilt from
//! `config.workspaces.rules` at init and on every reload), the spawn
//! queue (pending (workspace, pid) assignments consumed at the next
//! MapRequest), the five-cookie admission pipeline (fire every
//! property query up-front so the X server processes them in
//! parallel, drain the replies sequentially), the admission decision,
//! and the boot-time adoption helpers (restore-record lookup,
//! float-bit resolution, restored-record application).
//!
//! Two consumers remain in window.zig: handleMapRequest (the runtime
//! MapRequest path) and adoptRootWindows (the boot-time adoption
//! path); both fire their cookies here, resolve the decision here,
//! and register through admitWindow here.
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
const tracking = @import("tracking");
const icccm = @import("icccm");
const identity = @import("identity");
const hints = @import("hints");
const wincache = @import("wincache");
const atoms = @import("atoms");
const persist = @import("persist");
const actions = @import("actions");
const pipeline = @import("pipeline");
const model_mod = @import("model");
const window = @import("window");
const window_mods = @import("window_modules").modules;

// Private transition-layer gate for mutable model access (per-owner token,
// see tracking.gate).
const gate: pipeline.Gate = .{};

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

/// Pointer root position snapshot at spawn-admission time. The first
/// crossing event armed by a `.window_spawn` suppress compares against
/// this to tell a synthetic crossing (the new window mapping under a
/// parked cursor) apart from a real hover that must refocus. Recorded
/// in handleMapRequest; consumed by suppressSpawnCrossing.
const SpawnCursor = struct { x: i16 = 0, y: i16 = 0 };

// Admission-side state is grouped into a single State struct (mirroring
// the pattern focus.zig uses) so init()/deinit() each reset everything
// in one assignment, and a deinit()+init() cycle can't leave a stale
// field behind. The admission module is initialized from window.init,
// so its state is null exactly when the window module's is.
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

    /// Pointer root position snapshot at spawn-admission time (see
    /// SpawnCursor). Recorded in handleMapRequest; consumed by the
    /// window module's spawn-crossing suppression.
    spawn_cursor: SpawnCursor = .{},
};

var state: ?State = null;

/// Admission-side lifecycle: resets the admission state (spawn queue,
/// rules maps, spawn-cursor snapshot) and rebuilds the rules maps from
/// the current config. Called from window.init, after the window
/// module's own sub-systems are up.
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
        state.?.float_rules.deinit(a);
    }
    // Set to null so any accidental post-deinit access null-derefs instead
    // of silently reading freed state. init() restores it to .{}
    // unconditionally.
    state = null;
}

/// Pointer root position snapshot (see State.spawn_cursor). Read by the
/// window module's spawn-crossing suppression.
pub fn spawnCursor() SpawnCursor {
    return state.?.spawn_cursor;
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

pub inline fn clampToValidWorkspace(target: u8, fallback: core.WorkspaceId) core.WorkspaceId {
    return if (target < tracking.getWorkspaceCount())
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
/// rules. Parses the WM_CLASS reply inline (no allocation), then does two O(1)
/// hash lookups per map (class, then instance). The maps are built at init()
/// and after every config reload, so no linear rule scan runs at spawn time.
fn findAdmissionRuleByClass(cookie: xcb.xcb_get_property_cookie_t) ?AdmissionRule {
    const reply = xcb.xcb_get_property_reply(core.getState().conn, cookie, null) orelse return null;
    defer std.c.free(reply);
    if (reply.*.format != 8 or reply.*.value_len == 0) return null;

    const raw: [*]const u8 = @ptrCast(xcb.xcb_get_property_value(reply));
    const data = raw[0..reply.*.value_len];

    const wc = identity.parseWmClass(data) orelse return null;
    return matchRule(wc.instance, wc.class);
}

/// The WM_CLASS rule match, split from the XCB property read above so the
/// POLICY is testable without a server: two O(1) hash lookups, class first
/// (when non-empty) then instance, float rules winning over workspace rules at
/// each step. Reading a property is not part of this decision.
fn matchRule(instance: []const u8, class: []const u8) ?AdmissionRule {
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
        log.debug(
            "spawn: no exact PID match for pid={d}, {d} pending; ambiguous, routing to current ws",
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
/// drained. Shared by handleMapRequest and adoptRootWindows; both are preceded
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
/// has already drained them via mapRequest).
pub fn drainAdmissionCookies(conn: core.Connection, win: u32, cookies: AdmissionCookies, comptime discard_workspace: bool) void {
    if (comptime discard_workspace) {
        icccm.discardProtocolCookie(conn, cookies.c_wm_class);
        icccm.discardProtocolCookie(conn, cookies.c_net_wm_pid);
    }
    window.parseSizeHintsIntoCache(win, cookies.normal_hints_cookie);
    icccm.populateFocusCacheFromCookies(conn, win, cookies.protocols_cookie, cookies.hints_cookie);
    wincache.collectTitleCookies(conn, win, cookies.title_cookies);
}

/// Discards every cookie in a fired AdmissionCookies batch without parsing it.
/// adoptRootWindows fires admission cookies for ALL root children up-front, so
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

/// Snapshot the pointer's root position for spawn-crossing suppression.
///
/// Runs once per MapRequest, synchronously, right when the spawn's window is
/// admitted. The pointer cannot have moved relative to the keypress that
/// triggered the spawn between here and the reconcile's map (both happen in
/// the same event-loop batch), so this position is exactly what the synthetic
/// crossing the map generates will carry; a real hover from a moved pointer
/// yields different coordinates and is never masked. On a failed query the
/// record stays untouched (defaults to {0,0} at init) rather than poisoning
/// an established spawn's suppression.
pub fn snapshotSpawnCursor(conn: core.Connection) void {
    const reply = xcb.xcb_query_pointer_reply(conn, xcb.xcb_query_pointer(conn, core.getState().root), null);
    defer if (reply) |r| std.c.free(r);
    if (reply) |r| {
        state.?.spawn_cursor = .{ .x = r.*.root_x, .y = r.*.root_y };
    }
}

/// Admission policy shared by the MapRequest path (handleMapRequest) and the
/// boot-time adoption path (adoptRootWindows). Both sources fire and drain
/// their property cookies and resolve the target workspace BEFORE calling
/// here; this is the single place where a window is registered with the model
/// and its keyboard grabs seeded. One map-request path, one adoption path, one
/// admission policy.
///
pub fn admitWindow(win: u32, target_ws: u8, on_current: bool, float: bool) void {
    const cs = core.getState();
    const float_rect: ?model_mod.Rect = if (float) window.getGeometry(cs.conn, win) else null;
    actions.mapRequest(win, target_ws, on_current, float_rect);
}

/// Linear scan for a window's restore record. Restore files are small
/// (bounded by the model's store_capacity), so a flat scan is cache-local and
/// avoids allocating a lookup map just for adoption.
pub fn findWindowRecord(windows: []const persist.WindowRecord, win: u32) ?*const persist.WindowRecord {
    for (windows) |*r| {
        if (r.win == win) return r;
    }
    return null;
}

/// Resolves only the float bit of a class rule (adoption never relocates a
/// pre-existing window's workspace, so a workspace match is deliberately
/// ignored here). Drains the WM_CLASS reply.
pub fn resolveClassFloat(cookie: ?xcb.xcb_get_property_cookie_t) bool {
    const c = cookie orelse return false;
    const rule = findAdmissionRuleByClass(c) orelse return false;
    return rule.float;
}

/// Target workspace for an adopted window: the restore record's home
/// workspace (lowest set bit of its mask) when present, else the currently
/// active workspace. Deliberately NOT the spawn-queue/rules resolution, which
/// describes brand-new spawns rather than pre-existing windows.
pub fn restoredOrCurrent(record: ?*const persist.WindowRecord) u8 {
    if (record) |r| {
        if (r.mask != 0) return @intCast((model_mod.lowestBit(r.mask) orelse unreachable).index);
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
pub fn applyRestoredRecord(win: u32, record: *const persist.WindowRecord) void {
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
    // same dispatch. When no module claims the blob (the feature was stripped, or
    // the record carried no ext), the entry stays present and reconciles
    // on-screen -- the graceful degrade.
    //
    // Claim resolution: the blob is stamped with the claiming module's NAME at
    // save time (persist.ext_format_version). Adoption fast-paths on the name;
    // when the name no longer resolves (the module was removed or renamed) or
    // its hook declines, the magic-byte scan over every module's
    // self-identifying format tag claims it instead. Blobs written by the
    // pre-name format still resolve through their registry ordinal.
    if (record.ext) |stored| {
        // A recognised header narrows WHICH module is asked first; it never
        // decides the outcome, because the payload's own magic bytes do that.
        // Anything unrecognised (a foreign version, a truncated header) is
        // passed through whole, exactly as an unstamped blob was.
        const header = persist.decodeExt(stored);
        const payload: []const u8 = header.payload;
        if (header.claimed_name) |name| {
            for (window_mods) |mod| {
                if (!std.mem.eql(u8, mod.name, name)) continue;
                if (mod.deserializeWindow) |f| {
                    if (f(win, payload, model)) return;
                }
                break; // named claimant found; the scan below is the fallback
            }
        } else if (header.legacy_ordinal) |ordinal| {
            if (ordinal < window_mods.len) {
                if (window_mods[ordinal].deserializeWindow) |f| {
                    if (f(win, payload, model)) return;
                }
            }
        }
        for (window_mods) |mod| if (mod.deserializeWindow) |f| {
            if (f(win, payload, model)) return; // claimed
        };
    }
}
