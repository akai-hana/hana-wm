//! Window lifecycle — map/unmap/destroy, configure, enter/button events,
//! and per-window property caching.

const std           = @import("std");
const core          = @import("core");
const xcb           = core.xcb;
const utils         = @import("utils");
const constants     = @import("constants");
const focus         = @import("focus");
const build_options = @import("build_options");
const tiling        = if (build_options.has_tiling) @import("tiling") else struct {};
const layouts       = @import("layouts");
const bar           = @import("bar");
const tracking    = @import("tracking");
const workspaces  = if (build_options.has_workspaces) @import("workspaces") else struct {};
const WsWorkspace = if (build_options.has_workspaces) workspaces.Workspace else struct {};
fn wsGetState() ?*workspaces.State             { return if (comptime build_options.has_workspaces) workspaces.getState()                 else null; }
fn wsGetCurrentWorkspaceObject() ?*WsWorkspace { return if (comptime build_options.has_workspaces) workspaces.getCurrentWorkspaceObject() else null; }
inline fn wsMoveWindowTo(win: u32, ws: u8) !void {
    if (comptime build_options.has_workspaces) try workspaces.moveWindowTo(win, ws)
    else try tracking.registerWindow(win, 0);
}
inline fn wsRemoveWindow(win: u32) void {
    if (comptime build_options.has_workspaces) workspaces.removeWindow(win)
    else tracking.removeWindow(win);
}
const drag          = @import("drag");
const scale         = if (build_options.has_scale) @import("scale") else struct {
    pub fn scaleBorderWidth(value: anytype, reference_dimension: u16) u16 {
        if (value.is_percentage) {
            const dim_f: f32 = @floatFromInt(reference_dimension);
            return @intFromFloat(@max(0.0, @round((value.value / 100.0) * 0.5 * dim_f)));
        } else return @intFromFloat(@max(0.0, @round(value.value)));
    }
};
const debug         = @import("debug");
const minimize      = if (build_options.has_minimize) @import("minimize") else struct {};
const fullscreen    = if (build_options.has_fullscreen) @import("fullscreen") else struct {};

// XSizeHints flags (ICCCM §4.1.2.3)
const XSIZE_HINTS_P_MIN_SIZE:   u32 = 0x10;
const XSIZE_HINTS_P_RESIZE_INC: u32 = 0x40;
const XSIZE_HINTS_P_BASE_SIZE:  u32 = 0x100;

// Spawn queue
//
// Tracks pending (workspace, pid) assignments for newly-mapped windows.
// Lives here (window.zig) because it is exclusively accessed by this module.

const SpawnEntry = struct {
    workspace: u8,
    /// _NET_WM_PID of the grandchild; 0 for daemon-mode terminals.
    pid: u32,
};

/// Module-level spawn state.
const SpawnQueue = struct {
    const capacity = 16;

    buf: [capacity]SpawnEntry = undefined,
    len: u8 = 0,

    fn push(self: *SpawnQueue, entry: SpawnEntry) void {
        if (self.len == capacity) {
            std.mem.copyForwards(SpawnEntry, self.buf[0 .. capacity - 1], self.buf[1..capacity]);
            self.len -= 1;
        }
        self.buf[self.len] = entry;
        self.len += 1;
    }

    /// Removes the entry at index i, shifting later entries left, and returns
    /// its workspace.
    fn consume(self: *SpawnQueue, i: usize) u8 {
        const ws = self.buf[i].workspace;
        std.mem.copyForwards(SpawnEntry, self.buf[i .. self.len - 1], self.buf[i + 1 .. self.len]);
        self.len -= 1;
        return ws;
    }

    fn slice(self: *SpawnQueue) []SpawnEntry { return self.buf[0..self.len]; }
};

var spawn_queue: SpawnQueue = .{};
var spawn_cursor: struct { x: i16 = 0, y: i16 = 0 } = .{};

// Module-level atom cache
//
// The three atoms used on every MapRequest are resolved once into plain u32
// fields, turning per-event hash probes into direct field reads.
// Atoms that cannot be interned remain 0; property cookies sent with atom 0
// return an empty reply, which existing null-reply guards handle correctly.

var atoms: struct {
    wm_protocols: u32 = 0,
    wm_class:     u32 = 0,
    net_wm_pid:   u32 = 0,
} = .{};

// Geometry cache
//
// Stores last-known window geometry for workspace-switch and minimize/restore.
// When tiling is present, all operations delegate to tiling's own cache so
// there is exactly one source of truth. When tiling is absent, this module
// owns the cache directly, giving workspaces.zig and minimize.zig a stable
// save/restore API regardless of build configuration.

var g_geom_cache: layouts.CacheMap = .{};

/// Save `rect` as the last-known geometry for `win`.
/// Delegates to tiling when present; writes to g_geom_cache otherwise.
pub fn saveWindowGeom(win: u32, rect: utils.Rect) void {
    if (comptime build_options.has_tiling) {
        tiling.saveWindowGeom(win, rect);
    } else {
        g_geom_cache.getOrPut(win).value_ptr.rect = rect;
    }
}

/// Return the last-known geometry for `win`, or null if none is cached.
/// Delegates to tiling when present; reads from g_geom_cache otherwise.
pub fn getWindowGeom(win: u32) ?utils.Rect {
    if (comptime build_options.has_tiling) return tiling.getWindowGeom(win);
    const wd = g_geom_cache.get(win) orelse return null;
    if (!wd.hasValidRect()) return null;
    return wd.rect;
}

/// Zero out the cached rect for `win` so the next retile recomputes it.
pub fn invalidateWindowGeom(win: u32) void {
    if (comptime build_options.has_tiling) {
        tiling.invalidateGeomCache(win);
        return;
    }
    if (g_geom_cache.getPtr(win)) |wd| wd.rect = .{};
}

/// Remove `win`'s entry from the cache entirely (called on unmanage).
pub fn evictWindowGeom(win: u32) void {
    if (comptime build_options.has_tiling) return; // tiling.removeWindow handles this
    g_geom_cache.remove(win);
}


fn populateAtomCache() void {
    inline for (.{
        .{ .field = "wm_protocols", .atom = "WM_PROTOCOLS" },
        .{ .field = "wm_class",     .atom = "WM_CLASS"     },
        .{ .field = "net_wm_pid",   .atom = "_NET_WM_PID"  },
    }) |e| @field(atoms, e.field) = utils.getAtomCached(e.atom) catch 0;
}

pub fn init(alloc: std.mem.Allocator) void {
    tracking.init(alloc);
    focus.init(alloc);
    // tiling must precede workspaces: workspaces.init() calls tiling.getState().
    if (comptime build_options.has_tiling)      tiling.init();
    if (comptime build_options.has_fullscreen)  fullscreen.init();
    if (comptime build_options.has_workspaces)  workspaces.init();
    if (comptime build_options.has_minimize)    minimize.init();
    populateAtomCache();
}

pub fn deinit() void {
    if (comptime build_options.has_tiling)     tiling.deinit();
    if (comptime build_options.has_fullscreen) fullscreen.deinit();
    if (comptime build_options.has_workspaces) workspaces.deinit();
    focus.deinit();
    tracking.deinit();
}

/// Returns true when tiling is both compiled in and enabled at runtime.
inline fn tilingActive() bool {
    if (!comptime build_options.has_tiling) return false;
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

// Button grab management

pub fn grabButtons(win: u32, focused: bool) void {
    _ = xcb.xcb_ungrab_button(core.conn, xcb.XCB_BUTTON_INDEX_ANY, win, xcb.XCB_MOD_MASK_ANY);
    if (!focused) {
        _ = xcb.xcb_grab_button(
            core.conn, 0, win, xcb.XCB_EVENT_MASK_BUTTON_PRESS,
            xcb.XCB_GRAB_MODE_SYNC, xcb.XCB_GRAB_MODE_SYNC,
            xcb.XCB_NONE, xcb.XCB_NONE, xcb.XCB_BUTTON_INDEX_ANY, xcb.XCB_MOD_MASK_ANY,
        );
    }
}

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
/// Returns the matching workspace index, or null if no rule applies.
/// Guards on atoms.wm_class: if atom internment failed the cookie would
/// carry atom 0, triggering a pointless server round-trip on every MapRequest.
fn findClassRuleWorkspace(win: u32) ?u8 {
    if (core.config.workspaces.rules.items.len == 0 or atoms.wm_class == 0) return null;
    const cookie = xcb.xcb_get_property(
        core.conn, 0, win,
        atoms.wm_class,
        xcb.XCB_ATOM_STRING, 0, 256,
    );
    return findWorkspaceRuleByClass(cookie);
}

/// Phase 2 of workspace resolution: matches the window against the spawn queue.
/// Tries exact PID match, then daemon-mode (pid==0) match, then falls back to
/// the oldest pending entry — the correct heuristic when an app re-execs or
/// forks internally and its window PID differs from the registered grandchild.
/// Returns null when the spawn queue was empty (c_net_wm_pid == null).
fn findSpawnQueueWorkspace(c_net_wm_pid: ?xcb.xcb_get_property_cookie_t) ?u8 {
    const pid_cookie = c_net_wm_pid orelse return null;

    const win_pid: u32 = pid: {
        const pid_reply = xcb.xcb_get_property_reply(core.conn, pid_cookie, null)
            orelse break :pid 0;
        defer std.c.free(pid_reply);
        if (pid_reply.*.format != 32 or pid_reply.*.value_len < 1) break :pid 0;
        break :pid @as([*]const u32, @ptrCast(@alignCast(xcb.xcb_get_property_value(pid_reply))))[0];
    };

    const entries = spawn_queue.slice();

    // Exact PID match.
    if (win_pid != 0) {
        for (entries, 0..) |e, i| {
            if (e.pid == win_pid) return spawn_queue.consume(i);
        }
    }

    // Daemon match (pid == 0 in both window and queue entry).
    if (win_pid == 0) {
        for (entries, 0..) |e, i| {
            if (e.pid == 0) return spawn_queue.consume(i);
        }
    }

    // Oldest-entry fallback: any pending entry is almost certainly the source
    // of this window (the queue is only populated by explicit user exec actions).
    // The queue is provably non-empty here: this function is only entered when
    // c_net_wm_pid is non-null, which firePropertyCookies guarantees only when
    // spawn_queue.len > 0, and no branch above removes an entry without returning.
    return spawn_queue.consume(0);
}

/// Resolves the target workspace for a newly mapped window.
/// `c_net_wm_pid` is null when the spawn queue is empty — avoids the need for
/// a separate `has_pending_spawns` bool and makes it impossible to access an
/// undefined cookie.
fn resolveTargetWorkspace(
    win:          u32,
    current_ws:   u8,
    c_net_wm_pid: ?xcb.xcb_get_property_cookie_t,
) u8 {
    if (findClassRuleWorkspace(win)) |target| {
        // Discard the PID cookie if one was fired; XCB requires every
        // outstanding cookie to be consumed before the connection is closed.
        if (c_net_wm_pid) |pid_cookie|
            xcb.xcb_discard_reply(core.conn, pid_cookie.sequence);
        return clampToValidWorkspace(target, current_ws);
    }

    if (findSpawnQueueWorkspace(c_net_wm_pid)) |spawn_ws|
        return clampToValidWorkspace(spawn_ws, current_ws);

    return current_ws;
}

// Map request

pub inline fn registerSpawn(workspace: u8, pid: u32) void {
    spawn_queue.push(.{ .workspace = workspace, .pid = pid });
}

/// Called when a child process exits (via SIGCHLD delivered through a
/// signalfd or self-pipe in the event loop) before its window has ever
/// mapped.  Removes the matching queue entry immediately so a later,
/// unrelated MapRequest cannot be mis-routed to the wrong workspace.
///
/// Integration: in the event loop, drain the signalfd/self-pipe on
/// SIGCHLD, call waitpid(-1, WNOHANG) in a loop, and pass each reaped
/// PID here.  No timers, no polling, no arbitrary timeouts.
///
/// No-op for pid == 0: daemon-mode entries have no trackable child
/// process, so they self-resolve on the next MapRequest.
pub fn removeSpawnByPid(pid: u32) void {
    if (pid == 0) return;
    for (spawn_queue.slice(), 0..) |e, i| {
        if (e.pid == pid) {
            _ = spawn_queue.consume(i);
            return;
        }
    }
}

fn snapshotSpawnCursor() void {
    if (focus.getSuppressReason() != .window_spawn) return;
    const ptr = xcb.xcb_query_pointer_reply(
        core.conn, xcb.xcb_query_pointer(core.conn, core.root), null,
    ) orelse return;
    defer std.c.free(ptr);
    spawn_cursor.x = ptr.*.root_x;
    spawn_cursor.y = ptr.*.root_y;
}

/// Cookies for all properties fired at the start of a MapRequest.
/// net_wm_pid is null when the spawn queue is empty — see firePropertyCookies.
const PropertyCookies = struct {
    protocols:    xcb.xcb_get_property_cookie_t,
    hints:        xcb.xcb_get_property_cookie_t,
    normal_hints: xcb.xcb_get_property_cookie_t,
    net_wm_pid:   ?xcb.xcb_get_property_cookie_t,
};

/// Fires all property requests in a single batch before any blocking work,
/// so the replies arrive concurrently with in-memory setup.
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
        // Only fired when the spawn queue is non-empty so the type system
        // enforces this cookie is never accessed on an idle queue.
        .net_wm_pid = if (spawn_queue.len > 0) xcb.xcb_get_property(
            core.conn, 0, win,
            atoms.net_wm_pid,
            xcb.XCB_ATOM_CARDINAL, 0, 1,
        ) else null,
    };
}

/// Performs all visual work for a newly adopted window inside a server grab:
/// tiling registration, geometry configuration, map, focus, and bar redraw.
fn commitWindowToScreen(win: u32, on_current_workspace: bool) void {
    if (on_current_workspace) _ = xcb.xcb_grab_server(core.conn);

    // Configure geometry BEFORE mapping.  xcb_configure_window is valid on
    // an unmapped window — the geometry is stored and takes effect atomically
    // when the window is mapped.  Retiling here (which also pushes background
    // monocle windows offscreen) means the compositor never sees the new
    // window at its default X position or background windows still on-screen.
    if (tilingActive()) {
        tiling.addWindow(win);
        if (on_current_workspace) tiling.retileCurrentWorkspace();
    } else if (on_current_workspace) {
        // Without tiling, retileCurrentWorkspace() never runs, so we must
        // manually push the new window offscreen when fullscreen is active —
        // otherwise it maps on top of the fullscreen window and appears to
        // immediately vanish when the fullscreen window is raised above it.
        if (comptime build_options.has_fullscreen) {
            if (fullscreen.hasAnyFullscreen()) {
                _ = xcb.xcb_configure_window(core.conn, win,
                    xcb.XCB_CONFIG_WINDOW_X,
                    &[_]u32{@bitCast(@as(i32, constants.OFFSCREEN_X_POSITION))});
            }
        }
    }

    // Apply border width and initial color before mapping so the compositor
    // never sees a borderless first frame. Color is corrected to focused below
    // after setFocus, still inside the server grab.
    applyBorder(win);

    if (on_current_workspace) {
        _ = xcb.xcb_map_window(core.conn, win);
        snapshotSpawnCursor();
    } else {
        grabButtons(win, false);
    }

    bar.scheduleRedraw();
    if (on_current_workspace) {
        const old_focused = focus.getFocused();
        focus.setFocus(win, .window_spawn);
        // Correct the new window to focused and strip focus from the old one,
        // still inside the server grab so no intermediate frame is visible.
        updateFocusBorders(old_focused, win);
    }

    if (on_current_workspace) _ = xcb.xcb_ungrab_server(core.conn);
    _ = xcb.xcb_flush(core.conn);
}

fn discardPropertyCookies(cookies: PropertyCookies) void {
    xcb.xcb_discard_reply(core.conn, cookies.protocols.sequence);
    xcb.xcb_discard_reply(core.conn, cookies.hints.sequence);
    xcb.xcb_discard_reply(core.conn, cookies.normal_hints.sequence);
    if (cookies.net_wm_pid) |c| xcb.xcb_discard_reply(core.conn, c.sequence);
}

pub fn handleMapRequest(event: *const xcb.xcb_map_request_event_t) void {
    const win        = event.window;
    const current_ws: u8 = @intCast(tracking.getCurrentWorkspace() orelse 0);

    _ = xcb.xcb_change_window_attributes(
        core.conn, win, xcb.XCB_CW_EVENT_MASK, &[_]u32{constants.EventMasks.MANAGED_WINDOW},
    );

    const cookies   = firePropertyCookies(win);
    const target_ws = resolveTargetWorkspace(win, current_ws, cookies.net_wm_pid);
    const on_current = target_ws == current_ws;

    wsMoveWindowTo(win, target_ws) catch |err| {
        debug.logError(err, win);
        discardPropertyCookies(cookies);
        _ = xcb.xcb_flush(core.conn);
        return;
    };

    parseSizeHintsIntoCache(win, cookies.normal_hints);

    // Collect focus-cache property replies before any visual commands so that
    // registerWithTiling + xcb_map_window + setFocus all land at the server in
    // one atomic batch, eliminating the intermediate unfocused frame that was
    // visible when the flush preceded these round-trips.
    utils.populateFocusCacheFromCookies(core.conn, win, cookies.protocols, cookies.hints);

    commitWindowToScreen(win, on_current);
}

// Unmap / destroy

fn unmanageWindow(win: u32) void {
    const was_fullscreen = if (comptime build_options.has_fullscreen) blk: {
        const fs_ws = fullscreen.workspaceFor(win);
        if (fs_ws) |ws| fullscreen.removeForWorkspace(ws);
        break :blk fs_ws != null;
    } else false;

    const was_focused = (focus.getFocused() == win);

    const window_workspace = tracking.getWorkspaceForWindow(win);
    const current_ws       = tracking.getCurrentWorkspace();

    utils.uncacheWindowFocusProps(win);

    // Prune the window from focus history before any focus-recovery logic runs,
    // so the history never vends a pointer to the window being destroyed.
    focus.removeFromHistory(win);

    // Pre-fire pointer query before grab so the round-trip runs concurrently
    // with in-memory cleanup. Conditional: no round-trip when window wasn't focused.
    const ptr_cookie: ?xcb.xcb_query_pointer_cookie_t =
        if (was_focused) xcb.xcb_query_pointer(core.conn, core.root) else null;

    _ = xcb.xcb_grab_server(core.conn);

    // Notify each module in order inside the server grab.
    if (tilingActive()) {
        tiling.removeWindow(win);
        tiling.evictSizeHints(win);
    }
    if (comptime build_options.has_minimize) minimize.forceUntrack(win);
    wsRemoveWindow(win);

    if (was_fullscreen) bar.setBarState(.show_fullscreen);

    if (was_focused) {
        if (tilingActive()) tiling.retileIfDirty();
        focus.clearFocus();
        focusWindowUnderPointer(ptr_cookie.?);
    } else if (!was_fullscreen and tilingActive()) {
        if (window_workspace) |ws| {
            if (current_ws == ws) tiling.retileIfDirty()
            else tiling.retileInactiveWorkspace(ws);
        }
    }

    bar.redrawInsideGrab();

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
///
/// Consults MRU history first (via focus.focusBestAvailable), falling back
/// to minimize.focusMasterOrFirst when the history is exhausted or contains no
/// window visible on the current workspace.  If a window is directly under the
/// pointer it is preferred over history (hover-focus expectation); the
/// pointer-position reply is pre-fired before the server grab to overlap the
/// round-trip.
fn focusWindowUnderPointer(ptr_cookie: xcb.xcb_query_pointer_cookie_t) void {
    const fallback: ?*const fn () void = if (comptime build_options.has_minimize)
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

fn sendSyntheticConfigureNotify(win: u32) void {
    // Fast path: serve the geometry from the tiling cache — zero round-trips.
    if (comptime build_options.has_tiling) {
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
    const is_fullscreen = if (comptime build_options.has_fullscreen) fullscreen.isFullscreen(win) else false;
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
    var n: u3 = 0;
    for (geom_fields) |f| {
        if (mask & f.bit != 0) { values[n] = f.value; n += 1; }
    }
    _ = xcb.xcb_configure_window(core.conn, win, mask, &values);
    _ = xcb.xcb_flush(core.conn);
}

// Focus / crossing events

inline fn suppressSpawnCrossing(root_x: i16, root_y: i16) bool {
    if (focus.getSuppressReason() != .window_spawn) return false;
    if (root_x == spawn_cursor.x and root_y == spawn_cursor.y) return true;
    focus.setSuppressReason(.none);
    return false;
}

// Guards are ordered cheapest-first: `getFocused() == win` is a single field
// read that short-circuits the rest for the common re-entry (mouse jitter) case.
inline fn maybeFocusWindow(win: u32) void {
    if (focus.getFocused() == win) return;
    if (!isOnCurrentWorkspace(win)) return;
    if (comptime build_options.has_minimize) {
        if (minimize.isMinimized(win)) return;
    }
    focus.setFocus(win, .mouse_enter);
}

pub fn handleEnterNotify(event: *const xcb.xcb_enter_notify_event_t) void {
    focus.setLastEventTime(event.time);
    if (event.mode == xcb.XCB_NOTIFY_MODE_GRAB or
        event.mode == xcb.XCB_NOTIFY_MODE_UNGRAB) return;
    if (drag.isDragging()) return;
    if (suppressSpawnCrossing(event.root_x, event.root_y)) return;
    // A tiling operation (e.g. fullscreen exit) just repositioned windows,
    // potentially sliding one under the cursor.  Suppress focus-follow-mouse
    // until the user actually moves the cursor; cleared by handleMotionNotify.
    if (focus.getSuppressReason() == .tiling_operation) return;

    // EnterNotify on the root window names the entered child in event.child.
    // For all other windows the event window is the target directly.
    const win: u32 = if (event.event == core.root and event.child != 0)
        event.child
    else
        event.event;
    maybeFocusWindow(utils.findManagedWindow(core.conn, win, tracking.isManaged));
}

pub fn handleLeaveNotify(event: *const xcb.xcb_leave_notify_event_t) void {
    focus.setLastEventTime(event.time);
    if (event.event != core.root) return;
    if (event.mode != xcb.XCB_NOTIFY_MODE_NORMAL) return;
    if (drag.isDragging()) return;
    if (suppressSpawnCrossing(event.root_x, event.root_y)) return;
    // When child is zero the pointer left to an area not covered by any window;
    // maybeFocusWindow(0) would immediately fail isOnCurrentWorkspace anyway.
    if (event.child == 0) return;
    maybeFocusWindow(event.child);
}

// Property notify

pub fn handlePropertyNotify(event: *const xcb.xcb_property_notify_event_t) void {
    if (!isValidManagedWindow(event.window)) return;
    if (event.atom == atoms.wm_protocols or event.atom == xcb.XCB_ATOM_WM_HINTS) {
        utils.recacheInputModel(core.conn, event.window);
    }
}

// Size-hint parsing

/// Clamps a u32 to u16 range. Used when reading XSizeHints fields, which are
/// typed as u32 in the wire format but semantically bounded to u16 geometry values.
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

    // Skip the cache write entirely for windows that declare no size constraints,
    // which is the common case.
    if (flags & (XSIZE_HINTS_P_MIN_SIZE | XSIZE_HINTS_P_BASE_SIZE | XSIZE_HINTS_P_RESIZE_INC) == 0) return;

    var min_width:  u16 = 0;
    var min_height: u16 = 0;

    if (flags & XSIZE_HINTS_P_MIN_SIZE != 0 and field_count >= 7) {
        min_width  = clampToU16(fields[5]);
        min_height = clampToU16(fields[6]);
    }
    if (flags & XSIZE_HINTS_P_BASE_SIZE != 0 and field_count >= 17) {
        min_width  = @max(min_width,  clampToU16(fields[15]));
        min_height = @max(min_height, clampToU16(fields[16]));
    }

    // XSizeHints wire layout (ICCCM §4.1.2.3):
    //   [0] flags  [1-4] obsolete  [5] min_w  [6] min_h
    //   [7] max_w  [8] max_h  [9] inc_w  [10] inc_h
    //   [11-14] aspect  [15] base_w  [16] base_h  [17] gravity
    //
    // inc_w/inc_h constrain window dimensions to multiples of the increment
    // value added to the base.  Without them terminal emulators receive
    // fractional character cells and render ragged grids.
    var inc_width:  u16 = 0;
    var inc_height: u16 = 0;
    if (flags & XSIZE_HINTS_P_RESIZE_INC != 0 and field_count >= 11) {
        inc_width  = clampToU16(fields[9]);
        inc_height = clampToU16(fields[10]);
    }

    if (comptime build_options.has_tiling)
        // NOTE: tiling.SizeHints must carry inc_width and inc_height fields.
        // Add `inc_width: u16 = 0, inc_height: u16 = 0` to that struct and
        // apply them in the layout pass: dimension = base + N * inc, where N
        // is chosen so that base + N * inc ≤ available_space.
        tiling.cacheSizeHints(win, .{
            .min_width  = min_width,
            .min_height = min_height,
            .inc_width  = inc_width,
            .inc_height = inc_height,
        });
}

// Window borders
//
// Border state lives here so borders work regardless of whether the tiling
// subsystem is present. Width is read from tiling state when available (tiling
// owns the DPI-scaled value it uses in layout math); it is computed directly
// from config + DPI info only when tiling is absent.
// Colors are always owned by this module and read straight from config so they
// are automatically correct after a config reload without any extra init step.

/// Returns the DPI-scaled border width. Reads the pre-computed value from
/// tiling state when tiling is present, avoids redundant DPI arithmetic.
pub inline fn getBorderWidth() u16 {
    if (comptime build_options.has_tiling) {
        if (tiling.getStateOpt()) |s| return s.border_width;
    }
    return scale.scaleBorderWidth(
        core.config.tiling.border_width,
        core.screen.height_in_pixels,
    );
}

/// Returns the correct border color for `win`:
///   0               — fullscreen windows (compositor owns the frame)
///   border_focused  — the currently focused window
///   border_unfocused — everything else
inline fn borderColor(win: u32) u32 {
    if (comptime build_options.has_fullscreen) {
        if (fullscreen.isFullscreen(win)) return 0;
    }
    const cfg = &core.config.tiling;
    return if (focus.getFocused() == win) cfg.border_focused else cfg.border_unfocused;
}

/// Apply border width and color to `win`. Called when a window is first
/// managed so it has its border before it ever appears on screen.
pub fn applyBorder(win: u32) void {
    const width = getBorderWidth();
    if (width > 0)
        _ = xcb.xcb_configure_window(core.conn, win,
            xcb.XCB_CONFIG_WINDOW_BORDER_WIDTH, &[_]u32{width});
    _ = xcb.xcb_change_window_attributes(core.conn, win,
        xcb.XCB_CW_BORDER_PIXEL, &[_]u32{borderColor(win)});
}

/// Refresh border color for `old_focused` and `new_focused` after a focus
/// change. Pass null for either when no window held or will hold focus.
/// Does NOT flush — callers are responsible for flushing at the right time.
pub fn updateFocusBorders(old_focused: ?u32, new_focused: ?u32) void {
    for ([2]?u32{ old_focused, new_focused }) |opt| {
        const win = opt orelse continue;
        _ = xcb.xcb_change_window_attributes(core.conn, win,
            xcb.XCB_CW_BORDER_PIXEL, &[_]u32{borderColor(win)});
    }
}

/// Refresh border colors for every window on the current workspace.
/// Called after a retile pass: layout changes can implicitly shift which
/// window is fullscreen or focused, making cached colors stale.
pub fn updateWorkspaceBorders() void {
    if (comptime !build_options.has_workspaces) return;
    const ws = wsGetCurrentWorkspaceObject() orelse return;
    for (ws.windows.items()) |win|
        _ = xcb.xcb_change_window_attributes(core.conn, win,
            xcb.XCB_CW_BORDER_PIXEL, &[_]u32{borderColor(win)});
}

/// Push updated border width and colors to every managed window across all
/// workspaces. Called on config reload so color and width changes take effect
/// immediately on all windows, not just those on the current workspace.
pub fn reloadBorders() void {
    if (getBorderWidth() == 0) return;
    if (comptime !build_options.has_workspaces) return;
    const ws_state = wsGetState() orelse return;
    if (comptime build_options.has_workspaces) for (ws_state.workspaces) |*ws|
        for (ws.windows.items()) |win| applyBorder(win);
}
