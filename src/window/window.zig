//! Window lifecycle — map/unmap/destroy, configure, enter/button events,
//! and per-window property caching.

const std   = @import("std");
const build = @import("build_options");

const core      = @import("core");
const xcb       = core.xcb;
const utils     = @import("utils");
const constants = @import("constants");
const debug     = @import("debug");

const tracking = @import("tracking");
const focus    = @import("focus");

const fullscreen = if (build.has_fullscreen) @import("fullscreen") else struct {};
const minimize   = if (build.has_minimize)   @import("minimize")   else struct {};
const workspaces = if (build.has_workspaces) @import("workspaces") else struct {};

const tiling  = if (build.has_tiling) @import("tiling") else struct {};
const layouts = @import("layouts");

const drag = @import("drag");

const bar = if (build.has_bar) @import("bar") else struct {
    pub fn isBarWindow(_: u32) bool { return false; }
    pub fn redrawInsideGrab() void {}
    pub fn scheduleRedraw() void {}
    pub fn setBarState(_: anytype) void {}
};

const WsWorkspace = if (build.has_workspaces) workspaces.Workspace else struct {};

fn wsGetState() ?*workspaces.State { return if (build.has_workspaces) workspaces.getState() else null; }
fn wsGetCurrentWorkspaceObject() ?*WsWorkspace { return if (build.has_workspaces) workspaces.getCurrentWorkspaceObject() else null; }
inline fn wsMoveWindowTo(win: u32, ws: u8) !void {
    if (build.has_workspaces) try workspaces.moveWindowTo(win, ws)
    else try tracking.registerWindow(win, 0);
}
inline fn wsRemoveWindow(win: u32) void {
    if (build.has_workspaces) workspaces.removeWindow(win)
    else tracking.removeWindow(win);
}

// NOTE: This fallback stub must stay in sync with the real implementation in
// scale.zig (scaleBorderWidth).  If the formula changes there, update this stub
// too.  Ideally scaleBorderWidth would be moved to a file that is always
// compiled (not gated on has_scale), eliminating this duplication entirely.
// There is no compile-time enforcement of that sync; update both sites together.
const scale = if (build.has_scale) @import("scale") else struct {
    /// Stub matching scale.scaleBorderWidth for builds without the scale module.
    /// Formula must stay identical to scale.zig:scaleBorderWidth.
    pub fn scaleBorderWidth(value: anytype, reference_dimension: u16) u16 {
        if (value.is_percentage) {
            const dim_f: f32 = @floatFromInt(reference_dimension);
            return @intFromFloat(@max(0.0, @round((value.value / 100.0) * 0.5 * dim_f)));
        } else return @intFromFloat(@max(0.0, @round(value.value)));
    }
};


// XSizeHints flags (ICCCM §4.1.2.3)
const XSizeHintsFlags = struct {
    const p_min_size:   u32 = 0x10;
    const p_resize_inc: u32 = 0x40;
    const p_base_size:  u32 = 0x100;
};

// ---------------------------------------------------------------------------
// Spawn queue
// ---------------------------------------------------------------------------
//
// Tracks pending (workspace, pid) assignments for newly-mapped windows.
// Lives here (window.zig) because it is exclusively accessed by this module.
//
// Implemented as a module-level std.ArrayListUnmanaged so there is one logical
// allocation rather than two (the old design heap-allocated a SpawnQueue node
// that itself heap-allocated its backing slice, plus stored a redundant alloc
// field).  The allocator is stored once at module level (g_alloc) and used for
// both the spawn queue and any other window-module lifetime allocations.
//
// The list is capped at SPAWN_QUEUE_CAP entries.  Exceeding the cap logs an
// error and drops the entry; it never terminates the process.

const SpawnEntry = struct {
    workspace: u8,
    /// _NET_WM_PID of the grandchild; 0 for daemon-mode terminals.
    pid: u32,
};

const SPAWN_QUEUE_CAP: usize = 64;

/// Module allocator, set in init() and used for the spawn queue and any other
/// window-module lifetime allocations.  Null before the first init() call.
var g_alloc: ?std.mem.Allocator = null;

var g_spawn_queue: std.ArrayListUnmanaged(SpawnEntry) = .empty;

var spawn_cursor: struct { x: i16 = 0, y: i16 = 0 } = .{};

// Module-level atom cache
//
// The atoms used on every MapRequest are resolved once into plain u32 fields,
// turning per-event hash probes into direct field reads.  Atoms that cannot be
// interned remain 0; property cookies sent with atom 0 return an empty reply,
// which existing null-reply guards handle correctly.

var atoms: struct {
    wm_protocols:            u32 = 0,
    wm_class:                u32 = 0,
    net_wm_pid:              u32 = 0,
    net_wm_state:            u32 = 0,
    net_wm_state_fullscreen: u32 = 0,
} = .{};

// Geometry cache
//
// Stores last-known window geometry for workspace-switch and minimize/restore.
// When tiling is present, all operations delegate to tiling's own cache so
// there is exactly one source of truth.  When tiling is absent, this module
// owns the cache directly.

var g_geom_cache: layouts.CacheMap = .{};

/// Set by grab-flush paths that already called updateWorkspaceBorders() inside
/// their server grab, so the event loop can skip the redundant second sweep.
/// Reset unconditionally by updateWorkspaceBordersIfNeeded() at the end of each
/// event batch.
var borders_flushed_this_batch: bool = false;

/// Save `rect` as the last-known geometry for `win`.
pub fn saveWindowGeom(win: u32, rect: utils.Rect) void {
    if (build.has_tiling) {
        tiling.saveWindowGeom(win, rect);
    } else {
        g_geom_cache.getOrPut(win).value_ptr.rect = rect;
    }
}

/// Return the last-known geometry for `win`, or null if none is cached.
pub fn getWindowGeom(win: u32) ?utils.Rect {
    if (build.has_tiling) {
        return tiling.getWindowGeom(win);
    } else {
        const wd = g_geom_cache.get(win) orelse return null;
        if (!wd.hasValidRect()) return null;
        return wd.rect;
    }
}

/// Zero out the cached rect for `win` so the next retile recomputes it.
pub fn invalidateWindowGeom(win: u32) void {
    if (build.has_tiling) {
        tiling.invalidateGeomCache(win);
    } else {
        if (g_geom_cache.getPtr(win)) |wd| wd.rect = .{};
    }
}

/// Remove `win`'s entry from the cache entirely (called on unmanage).
pub fn evictWindowGeom(win: u32) void {
    if (build.has_tiling) return;
    g_geom_cache.remove(win);
}


fn populateAtomCache() void {
    inline for (.{
        .{ .field = "wm_protocols",            .atom = "WM_PROTOCOLS"              },
        .{ .field = "wm_class",                .atom = "WM_CLASS"                  },
        .{ .field = "net_wm_pid",              .atom = "_NET_WM_PID"               },
        .{ .field = "net_wm_state",            .atom = "_NET_WM_STATE"             },
        .{ .field = "net_wm_state_fullscreen", .atom = "_NET_WM_STATE_FULLSCREEN"  },
    }) |e| @field(atoms, e.field) = utils.getAtomCached(e.atom) catch 0;
}

pub fn init(alloc: std.mem.Allocator) !void {
    g_alloc = alloc;
    tracking.init(alloc);
    focus.init(alloc);
    // tiling must precede workspaces: workspaces.init() calls tiling.getState().
    if (build.has_tiling)      tiling.init();
    if (build.has_fullscreen)  fullscreen.init();
    if (build.has_workspaces) try workspaces.init();
    if (build.has_minimize)    minimize.init();
    if (build.has_minimize or build.has_workspaces) {
        // Pre-allocate spawn queue capacity for the common case (a handful of
        // concurrent spawns).  Failure is non-fatal; the list grows on demand.
        g_spawn_queue.ensureTotalCapacity(alloc, 16) catch |err| {
            std.log.warn("window: spawn queue pre-allocation failed ({s}); will grow on demand", .{@errorName(err)});
        };
    }
    populateAtomCache();
}

pub fn deinit() void {
    // Teardown in reverse-init order.
    if (build.has_tiling)     tiling.deinit();
    if (build.has_fullscreen) fullscreen.deinit();
    if (build.has_workspaces) workspaces.deinit();
    if (build.has_minimize)   minimize.deinit();
    if (g_alloc) |a| {
        g_spawn_queue.deinit(a);
        g_spawn_queue = .empty;
    }
    focus.deinit();
    tracking.deinit();
}

/// Returns true when tiling is both compiled in and enabled at runtime.
inline fn tilingActive() bool {
    if (!build.has_tiling) return false;
    return core.config.tiling.enabled;
}

// Window predicates

pub inline fn isValidManagedWindow(win: u32) bool {
    return win != 0 and
           win != core.root and
           !bar.isBarWindow(win) and
           tracking.isManaged(win);
}

pub inline fn isOnCurrentWorkspace(win: u32) bool {
    if (win == 0 or win == core.root or bar.isBarWindow(win)) return false;
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
/// Parses instance/class directly from the reply buffer — no allocation.
fn findWorkspaceRuleByClass(cookie: xcb.xcb_get_property_cookie_t) ?u8 {
    const reply = xcb.xcb_get_property_reply(core.conn, cookie, null) orelse return null;
    defer std.c.free(reply);
    if (reply.*.format != 8 or reply.*.value_len == 0) return null;

    const raw: [*]const u8 = @ptrCast(xcb.xcb_get_property_value(reply));
    const data = std.mem.trimEnd(u8, raw[0..reply.*.value_len], "\x00");

    const sep = std.mem.indexOfScalar(u8, data, 0) orelse return null;
    const class_start = sep + 1;
    if (class_start >= data.len) return null;

    const instance = data[0..sep];
    const class    = data[class_start..];

    for (core.config.workspaces.rules.items) |rule| {
        if (std.mem.eql(u8, rule.class_name, class) or
            std.mem.eql(u8, rule.class_name, instance))
        {
            return rule.workspace;
        }
    }
    return null;
}

// Workspace assignment

/// Phase 1 of workspace resolution: checks WM_CLASS against config rules.
fn findClassRuleWorkspace(cookie: xcb.xcb_get_property_cookie_t) ?u8 {
    if (core.config.workspaces.rules.items.len == 0 or atoms.wm_class == 0) {
        xcb.xcb_discard_reply(core.conn, cookie.sequence);
        return null;
    }
    return findWorkspaceRuleByClass(cookie);
}

/// Phase 2 of workspace resolution: matches the window against the spawn queue.
/// Tries exact PID match first; tracks the earliest daemon-mode (pid==0) entry
/// as a candidate; falls back to the oldest pending entry.
/// Returns null when the spawn queue was empty (c_net_wm_pid == null).
///
/// Logs a debug message on both fallback branches so heuristic routing is
/// visible in debug sessions.
fn findSpawnQueueWorkspace(
    c_net_wm_pid: ?xcb.xcb_get_property_cookie_t,
) ?u8 {
    const pid_cookie = c_net_wm_pid orelse return null;

    const win_pid: u32 = pid: {
        const pid_reply = xcb.xcb_get_property_reply(core.conn, pid_cookie, null)
            orelse break :pid 0;
        defer std.c.free(pid_reply);
        if (pid_reply.*.format != 32 or pid_reply.*.value_len < 1) break :pid 0;
        break :pid @as([*]const u32, @ptrCast(@alignCast(xcb.xcb_get_property_value(pid_reply))))[0];
    };

    const entries = g_spawn_queue.items;

    // Single pass: exact PID match takes priority; daemon-mode index is
    // recorded as a fallback candidate without a second scan.
    var daemon_idx: ?usize = null;
    for (entries, 0..) |e, i| {
        if (win_pid != 0 and e.pid == win_pid) {
            const ws = entries[i].workspace;
            _ = g_spawn_queue.orderedRemove(i);
            return ws;
        }
        if (daemon_idx == null and e.pid == 0 and win_pid == 0) daemon_idx = i;
    }

    if (daemon_idx) |i| {
        std.log.debug("spawn: daemon-mode PID match at entry={d}, ws={d}", .{ i, g_spawn_queue.items[i].workspace });
        const ws = g_spawn_queue.items[i].workspace;
        _ = g_spawn_queue.orderedRemove(i);
        return ws;
    }

    // Oldest-entry fallback — queue is non-empty per precondition: firePropertyCookies
    // only sets net_wm_pid when the spawn queue is non-empty.
    if (g_spawn_queue.items.len == 0) return null;
    std.log.debug(
        "spawn: no exact PID match for pid={d}, using oldest entry ws={d}",
        .{ win_pid, g_spawn_queue.items[0].workspace },
    );
    const ws = g_spawn_queue.items[0].workspace;
    _ = g_spawn_queue.orderedRemove(0);
    return ws;
}

/// Resolves the target workspace for a newly mapped window.
fn resolveTargetWorkspace(
    current_ws:    u8,
    c_wm_class:    xcb.xcb_get_property_cookie_t,
    c_net_wm_pid:  ?xcb.xcb_get_property_cookie_t,
) u8 {
    if (findClassRuleWorkspace(c_wm_class)) |target| {
        if (c_net_wm_pid) |pid_cookie|
            xcb.xcb_discard_reply(core.conn, pid_cookie.sequence);
        return clampToValidWorkspace(target, current_ws);
    }

    if (findSpawnQueueWorkspace(c_net_wm_pid)) |spawn_ws|
        return clampToValidWorkspace(spawn_ws, current_ws);

    return current_ws;
}

// Map request

pub fn registerSpawn(workspace: u8, pid: u32) void {
    const alloc = g_alloc orelse return;
    if (g_spawn_queue.items.len >= SPAWN_QUEUE_CAP) {
        debug.warn("registerSpawn: spawn queue full ({d} entries); entry dropped", .{SPAWN_QUEUE_CAP});
        return;
    }
    g_spawn_queue.append(alloc, .{ .workspace = workspace, .pid = pid }) catch |err| {
        debug.warn("registerSpawn: failed to queue spawn entry: {}", .{err});
    };
}

/// Called when a child process exits (via SIGCHLD) before its window has
/// ever mapped.  Removes the matching queue entry immediately so a later,
/// unrelated MapRequest cannot be mis-routed to the wrong workspace.
///
/// No-op for pid == 0: daemon-mode entries have no trackable child process,
/// so they self-resolve on the next MapRequest.
pub fn removeSpawnByPid(pid: u32) void {
    if (pid == 0) return;
    for (g_spawn_queue.items, 0..) |e, i| {
        if (e.pid == pid) {
            _ = g_spawn_queue.orderedRemove(i);
            return;
        }
    }
}

/// Drain a pre-fired xcb_query_pointer cookie and record the cursor position
/// for later spawn-crossing suppression checks.
fn snapshotSpawnCursor(ptr_cookie: xcb.xcb_query_pointer_cookie_t, suppress_reason: core.FocusSuppressReason) void {
    if (suppress_reason != .window_spawn) {
        xcb.xcb_discard_reply(core.conn, ptr_cookie.sequence);
        return;
    }
    const ptr = xcb.xcb_query_pointer_reply(core.conn, ptr_cookie, null) orelse return;
    defer std.c.free(ptr);
    spawn_cursor.x = ptr.*.root_x;
    spawn_cursor.y = ptr.*.root_y;
}

/// Cookies for all properties fired at the start of a MapRequest.
const PropertyCookies = struct {
    protocols:    xcb.xcb_get_property_cookie_t,
    hints:        xcb.xcb_get_property_cookie_t,
    normal_hints: xcb.xcb_get_property_cookie_t,
    wm_class:     xcb.xcb_get_property_cookie_t,
    net_wm_pid:   ?xcb.xcb_get_property_cookie_t,
};

/// Fires all property requests in a single batch before any blocking work.
fn firePropertyCookies(win: u32) PropertyCookies {
    return .{
        .protocols = xcb.xcb_get_property(
            core.conn, 0, win,
            atoms.wm_protocols,
            xcb.XCB_ATOM_ATOM, 0, 256,
        ),
        .hints = xcb.xcb_get_property(
            core.conn, 0, win,
            xcb.XCB_ATOM_WM_HINTS, xcb.XCB_ATOM_WM_HINTS, 0, 9,
        ),
        .normal_hints = xcb.xcb_get_property(
            core.conn, 0, win,
            xcb.XCB_ATOM_WM_NORMAL_HINTS, xcb.XCB_ATOM_ANY, 0, 18,
        ),
        .wm_class = xcb.xcb_get_property(
            core.conn, 0, win,
            atoms.wm_class,
            xcb.XCB_ATOM_STRING, 0, 256,
        ),
        // Only fired when the spawn queue is non-empty so the type system
        // enforces this cookie is never accessed on an idle queue.
        .net_wm_pid = blk: {
            if (g_spawn_queue.items.len == 0) break :blk null;
            break :blk xcb.xcb_get_property(
                core.conn, 0, win,
                atoms.net_wm_pid,
                xcb.XCB_ATOM_CARDINAL, 0, 1,
            );
        },
    };
}

/// Map a newly adopted window that is on the current workspace.
///
/// Runs inside a server grab: tiling registration + retile, geometry
/// configuration, map, focus, border sweep, and bar redraw all land in a
/// single atomic batch.
fn mapWindowToScreen(win: u32) void {
    const ptr_cookie = xcb.xcb_query_pointer(core.conn, core.root);

    _ = xcb.xcb_grab_server(core.conn);

    if (tilingActive()) {
        tiling.addWindow(win);
        tiling.retileCurrentWorkspace();
    } else {
        if (build.has_fullscreen) {
            if (fullscreen.hasAnyFullscreen()) {
                _ = xcb.xcb_configure_window(core.conn, win,
                    xcb.XCB_CONFIG_WINDOW_X,
                    &[_]u32{@bitCast(@as(i32, constants.OFFSCREEN_X_POSITION))});
            }
        }
    }

    applyBorderWidth(win);
    _ = xcb.xcb_map_window(core.conn, win);

    focus.setFocus(win, .window_spawn);
    snapshotSpawnCursor(ptr_cookie, focus.getSuppressReason());

    updateWorkspaceBorders();
    bar.redrawInsideGrab();
    markBordersFlushed();

    _ = xcb.xcb_ungrab_server(core.conn);
    _ = xcb.xcb_flush(core.conn);
}

/// Register a newly adopted window that is on a non-current workspace.
fn registerWindowOffscreen(win: u32) void {
    if (tilingActive()) tiling.addWindow(win);

    applyBorder(win);
    focus.initWindowGrabs(win);

    bar.scheduleRedraw();
    _ = xcb.xcb_flush(core.conn);
}

fn discardPropertyCookies(cookies: PropertyCookies) void {
    xcb.xcb_discard_reply(core.conn, cookies.protocols.sequence);
    xcb.xcb_discard_reply(core.conn, cookies.hints.sequence);
    xcb.xcb_discard_reply(core.conn, cookies.normal_hints.sequence);
    xcb.xcb_discard_reply(core.conn, cookies.wm_class.sequence);
    if (cookies.net_wm_pid) |c| xcb.xcb_discard_reply(core.conn, c.sequence);
}

pub fn handleMapRequest(event: *const xcb.xcb_map_request_event_t) void {
    const win = event.window;

    // Guard against double-manage: a window can send multiple MapRequest events
    // (e.g. if it unmaps and remaps itself quickly while the WM is still
    // processing the first).  Without this guard, tiling.addWindow and
    // firePropertyCookies could fire twice for the same window.
    if (tracking.isManaged(win)) return;

    // getCurrentWorkspace() returns ?u8; the value is already bounded to [0,255]
    // by the u8 return type, so no further clamping is needed.
    const current_ws: u8 = tracking.getCurrentWorkspace() orelse 0;

    _ = xcb.xcb_change_window_attributes(
        core.conn, win, xcb.XCB_CW_EVENT_MASK, &[_]u32{constants.EventMasks.MANAGED_WINDOW},
    );

    const cookies   = firePropertyCookies(win);
    const target_ws = resolveTargetWorkspace(current_ws, cookies.wm_class, cookies.net_wm_pid);
    const on_current = target_ws == current_ws;

    wsMoveWindowTo(win, target_ws) catch |err| {
        debug.logError(err, win);
        discardPropertyCookies(cookies);
        _ = xcb.xcb_flush(core.conn);
        return;
    };

    parseSizeHintsIntoCache(win, cookies.normal_hints);

    utils.populateFocusCacheFromCookies(core.conn, win, cookies.protocols, cookies.hints);

    if (on_current) mapWindowToScreen(win) else registerWindowOffscreen(win);
}

// Unmap / destroy

fn unmanageWindow(win: u32) void {
    const was_fullscreen = if (build.has_fullscreen) blk: {
        const fs_ws = fullscreen.workspaceFor(win);
        if (fs_ws) |ws| fullscreen.removeForWorkspace(ws);
        break :blk fs_ws != null;
    } else false;

    const was_focused = (focus.getFocused() == win);

    const window_workspace = tracking.getWorkspaceForWindow(win);
    const current_ws       = tracking.getCurrentWorkspace();

    utils.uncacheWindowFocusProps(win);

    focus.removeFromHistory(win);

    const ptr_cookie: ?xcb.xcb_query_pointer_cookie_t =
        if (was_focused) xcb.xcb_query_pointer(core.conn, core.root) else null;

    _ = xcb.xcb_grab_server(core.conn);

    if (build.has_tiling) {
        tiling.removeWindow(win);
        tiling.evictSizeHints(win);
    }
    if (build.has_minimize) minimize.forceUntrack(win);
    wsRemoveWindow(win);

    if (was_fullscreen) bar.setBarState(.show_fullscreen);

    if (was_focused) {
        if (tilingActive()) tiling.retileIfDirty();
        focus.clearFocus();
        focusWindowUnderPointer(ptr_cookie.?);
    } else if (!was_fullscreen and tilingActive()) {
        if (window_workspace) |ws|
            if (current_ws == ws) tiling.retileIfDirty()
            else tiling.retileInactiveWorkspace(ws);
    }

    updateWorkspaceBorders();
    bar.redrawInsideGrab();
    markBordersFlushed();

    _ = xcb.xcb_ungrab_server(core.conn);
    _ = xcb.xcb_flush(core.conn);
}

pub fn handleUnmapNotify(event: *const xcb.xcb_unmap_notify_event_t) void {
    if (isValidManagedWindow(event.window)) unmanageWindow(event.window);
}

pub fn handleDestroyNotify(event: *const xcb.xcb_destroy_notify_event_t) void {
    if (isValidManagedWindow(event.window)) unmanageWindow(event.window);
}

/// Post-unmanage focus recovery.
fn focusWindowUnderPointer(ptr_cookie: xcb.xcb_query_pointer_cookie_t) void {
    const fallback: ?*const fn () void = if (build.has_minimize)
        minimize.focusMasterOrFirst
    else
        null;
    const reply = xcb.xcb_query_pointer_reply(core.conn, ptr_cookie, null) orelse {
        focus.focusBestAvailable(.tiling_operation, tracking.isOnCurrentWorkspaceAndVisible, fallback);
        return;
    };
    defer std.c.free(reply);
    const child = reply.*.child;
    if (tracking.isOnCurrentWorkspaceAndVisible(child)) {
        focus.setFocus(child, .mouse_enter);
        return;
    }
    focus.focusBestAvailable(.tiling_operation, tracking.isOnCurrentWorkspaceAndVisible, fallback);
}

// Configure request

const GEOMETRY_MASK: u16 =
    xcb.XCB_CONFIG_WINDOW_X | xcb.XCB_CONFIG_WINDOW_Y |
    xcb.XCB_CONFIG_WINDOW_WIDTH | xcb.XCB_CONFIG_WINDOW_HEIGHT |
    xcb.XCB_CONFIG_WINDOW_BORDER_WIDTH;

const WindowGeometry = struct {
    x:            i16,
    y:            i16,
    width:        u16,
    height:       u16,
    border_width: u16,
};

fn sendConfigureNotify(win: u32, geom: WindowGeometry) void {
    const ev = xcb.xcb_configure_notify_event_t{
        .response_type     = xcb.XCB_CONFIGURE_NOTIFY,
        .pad0              = 0,
        .sequence          = 0,
        .event             = win,
        .window            = win,
        .above_sibling     = xcb.XCB_NONE,
        .x                 = geom.x,
        .y                 = geom.y,
        .width             = geom.width,
        .height            = geom.height,
        .border_width      = geom.border_width,
        .override_redirect = 0,
        .pad1              = 0,
    };
    _ = xcb.xcb_send_event(core.conn, 0, win, xcb.XCB_EVENT_MASK_STRUCTURE_NOTIFY, @ptrCast(&ev));
}

/// Synthesize and send a ConfigureNotify event with the window's current geometry.
///
/// Fast path: serves geometry from the tiling cache — zero round-trips.
///
/// Slow path: for fullscreen windows or cache misses, issues a blocking
/// xcb_get_geometry round-trip.
///
/// NOTE — slow-path latency: a fullscreen window that generates many
/// ConfigureRequest events (e.g. a video player attempting to resize while
/// locked) will block the event loop on one round-trip per event.  Fullscreen
/// geometry is deterministic (screen dimensions), so this could be replaced by
/// returning the screen geometry directly.  The blocking call is retained for
/// simplicity; optimize if profiling reveals this path is hot.
fn sendSyntheticConfigureNotify(win: u32) void {
    // Fast path: serve the geometry from the tiling cache — zero round-trips.
    if (build.has_tiling) {
        if (tiling.getWindowGeom(win)) |rect| {
            const border: u16 = if (tiling.getStateOpt()) |s| s.border_width else 0;
            sendConfigureNotify(win, .{
                .x = rect.x, .y = rect.y, .width = rect.width, .height = rect.height,
                .border_width = border,
            });
            return;
        }
    }

    // Slow path: fullscreen windows or a cache miss. One blocking round-trip.
    const reply = xcb.xcb_get_geometry_reply(
        core.conn, xcb.xcb_get_geometry(core.conn, win), null,
    ) orelse return;
    defer std.c.free(reply);
    sendConfigureNotify(win, .{
        .x = reply.*.x, .y = reply.*.y, .width = reply.*.width, .height = reply.*.height,
        .border_width = reply.*.border_width,
    });
}

pub fn handleConfigureRequest(event: *const xcb.xcb_configure_request_event_t) void {
    const win = event.window;
    const is_tiled = tilingActive() and tiling.isWindowActiveTiled(win);
    const is_fullscreen = if (build.has_fullscreen) fullscreen.isFullscreen(win) else false;
    if (is_tiled or is_fullscreen) {
        sendSyntheticConfigureNotify(win);
        return;
    }

    const mask = event.value_mask & GEOMETRY_MASK;
    if (mask == 0) return;

    const GeomField = struct { bit: u16, value: u32 };
    const geom_fields = [_]GeomField{
        .{ .bit = xcb.XCB_CONFIG_WINDOW_X,            .value = @bitCast(@as(i32, event.x)) },
        .{ .bit = xcb.XCB_CONFIG_WINDOW_Y,            .value = @bitCast(@as(i32, event.y)) },
        .{ .bit = xcb.XCB_CONFIG_WINDOW_WIDTH,        .value = event.width                 },
        .{ .bit = xcb.XCB_CONFIG_WINDOW_HEIGHT,       .value = event.height                },
        .{ .bit = xcb.XCB_CONFIG_WINDOW_BORDER_WIDTH, .value = event.border_width          },
    };
    var values: [5]u32 = undefined;
    var n: usize = 0;
    for (geom_fields) |f| {
        if (mask & f.bit != 0) { values[n] = f.value; n += 1; }
    }
    _ = xcb.xcb_configure_window(core.conn, win, mask, &values);
}

// Focus / crossing events

inline fn suppressSpawnCrossing(root_x: i16, root_y: i16) bool {
    if (focus.getSuppressReason() != .window_spawn) return false;
    if (root_x == spawn_cursor.x and root_y == spawn_cursor.y) return true;
    focus.setSuppressReason(.none);
    return false;
}

inline fn maybeFocusWindow(win: u32) void {
    if (!isOnCurrentWorkspace(win)) {
        debug.info("[MAYBE_FOCUS] 0x{x} -> not on current workspace", .{win});
        return;
    }
    if (build.has_minimize) {
        if (minimize.isMinimized(win)) {
            debug.info("[MAYBE_FOCUS] 0x{x} -> minimized", .{win});
            return;
        }
    }
    debug.info("[MAYBE_FOCUS] 0x{x} -> calling dwmFocus", .{win});
    focus.dwmFocus(win);
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
    const managed = utils.findManagedWindow(core.conn, event.event, tracking.isManaged);
    debug.info("[ENTER] -> resolved managed=0x{x}", .{managed});
    maybeFocusWindow(managed);
}

pub fn handleLeaveNotify(event: *const xcb.xcb_leave_notify_event_t) void {
    focus.setLastEventTime(event.time);
    if (event.event != core.root) return;
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
    if (event.atom != atoms.wm_protocols and event.atom != xcb.XCB_ATOM_WM_HINTS) return;
    focus.invalidateInputModelCache(event.window);
}

// Size-hint parsing

/// Clamps a u32 to u16 range.
inline fn clampToU16(v: u32) u16 {
    return @intCast(@min(v, std.math.maxInt(u16)));
}

fn parseSizeHintsIntoCache(
    win:    u32,
    cookie: xcb.xcb_get_property_cookie_t,
) void {
    const reply = xcb.xcb_get_property_reply(core.conn, cookie, null) orelse return;
    defer std.c.free(reply);
    if (reply.*.format != 32 or reply.*.value_len < 5) return;

    const fields: [*]const u32 = @ptrCast(@alignCast(xcb.xcb_get_property_value(reply)));
    const field_count = reply.*.value_len;
    const flags       = fields[0];

    if (flags & (XSizeHintsFlags.p_min_size | XSizeHintsFlags.p_base_size | XSizeHintsFlags.p_resize_inc) == 0) return;

    var min_width:  u16 = 0;
    var min_height: u16 = 0;

    if (flags & XSizeHintsFlags.p_min_size != 0 and field_count >= 7) {
        min_width  = clampToU16(fields[5]);
        min_height = clampToU16(fields[6]);
    }

    if (flags & XSizeHintsFlags.p_base_size != 0 and field_count >= 17) {
        min_width  = clampToU16(fields[15]);
        min_height = clampToU16(fields[16]);
    }

    var inc_width:  u16 = 0;
    var inc_height: u16 = 0;
    if (flags & XSizeHintsFlags.p_resize_inc != 0 and field_count >= 11) {
        inc_width  = clampToU16(fields[9]);
        inc_height = clampToU16(fields[10]);
    }

    if (build.has_tiling)
        tiling.cacheSizeHints(win, .{
            .min_width  = min_width,
            .min_height = min_height,
            .inc_width  = inc_width,
            .inc_height = inc_height,
        });
}

// Window borders

/// Returns the DPI-scaled border width.
pub inline fn getBorderWidth() u16 {
    if (build.has_tiling) {
        if (tiling.getStateOpt()) |s| return s.border_width;
    }
    return scale.scaleBorderWidth(
        core.config.tiling.border_width,
        core.screen.height_in_pixels,
    );
}

/// Returns the correct border color for `win`.
inline fn borderColor(win: u32) u32 {
    if (build.has_fullscreen) {
        if (fullscreen.isFullscreen(win)) return 0;
    }
    const cfg = &core.config.tiling;
    return if (focus.getFocused() == win) cfg.border_focused else cfg.border_unfocused;
}

/// Apply border width only to `win`.
pub fn applyBorderWidth(win: u32) void {
    const width = getBorderWidth();
    if (width > 0)
        _ = xcb.xcb_configure_window(core.conn, win,
            xcb.XCB_CONFIG_WINDOW_BORDER_WIDTH, &[_]u32{width});
}

/// Apply border width and color to `win`.
pub fn applyBorder(win: u32) void {
    applyBorderWidth(win);
    _ = xcb.xcb_change_window_attributes(core.conn, win,
        xcb.XCB_CW_BORDER_PIXEL, &[_]u32{borderColor(win)});
}

/// Refresh border color for `old_focused` and `new_focused` after a focus change.
pub fn updateFocusBorders(old_focused: ?u32, new_focused: ?u32) void {
    for ([2]?u32{ old_focused, new_focused }) |opt| {
        const win = opt orelse continue;
        _ = xcb.xcb_change_window_attributes(core.conn, win,
            xcb.XCB_CW_BORDER_PIXEL, &[_]u32{borderColor(win)});
    }
}

/// Refresh border colors for every window on the current workspace.
pub fn updateWorkspaceBorders() void {
    if (!build.has_workspaces) return;
    const ws = wsGetCurrentWorkspaceObject() orelse return;
    for (ws.windows.items()) |win|
        _ = xcb.xcb_change_window_attributes(core.conn, win,
            xcb.XCB_CW_BORDER_PIXEL, &[_]u32{borderColor(win)});
}

/// Mark that the current event batch already swept all workspace border colors
/// inside a server grab, so the event loop does not need to do it again.
pub fn markBordersFlushed() void { borders_flushed_this_batch = true; }

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
    if (!borders_flushed_this_batch) updateWorkspaceBorders();
    borders_flushed_this_batch = false;
}

// ClientMessage — EWMH fullscreen requests from applications

pub fn handleClientMessage(event: *const xcb.xcb_client_message_event_t) void {
    if (event.format != 32) return;

    if (atoms.net_wm_state == 0 or event.type != atoms.net_wm_state) return;

    const fs_atom = atoms.net_wm_state_fullscreen;
    if (fs_atom == 0) return;
    const prop1   = event.data.data32[1];
    const prop2   = event.data.data32[2];
    if (prop1 != fs_atom and prop2 != fs_atom) return;

    const win = event.window;
    if (!isValidManagedWindow(win)) return;

    if (build.has_fullscreen) {
        const action = event.data.data32[0];
        const is_fs  = fullscreen.isFullscreen(win);
        const should_enter = switch (action) {
            1 => true,   // _NET_WM_STATE_ADD
            0 => false,  // _NET_WM_STATE_REMOVE
            2 => !is_fs, // _NET_WM_STATE_TOGGLE
            else => return,
        };
        if (should_enter and !is_fs) {
            fullscreen.enterFullscreen(win, null);
        } else if (!should_enter and is_fs) {
            fullscreen.toggle();
        }
    }
}

/// Push updated border width and colors to every managed window across all
/// workspaces. Called on config reload.
pub fn reloadBorders() void {
    if (!build.has_workspaces) return;
    const ws_state = wsGetState() orelse return;
    for (ws_state.workspaces) |*ws|
        for (ws.windows.items()) |win| applyBorder(win);
}
