//! Window lifecycle — map/unmap/destroy, configure, enter/button events,
//! and per-window property caching.

const std   = @import("std");
const build = @import("build_options");

const core      = @import("core");
    const xcb   = core.xcb;
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

const scale = if (build.has_scale) @import("scale") else struct {
    pub fn scaleBorderWidth(value: anytype, reference_dimension: u16) u16 {
        if (value.is_percentage) {
            const dim_f: f32 = @floatFromInt(reference_dimension);
            return @intFromFloat(@max(0.0, @round((value.value / 100.0) * 0.5 * dim_f)));
        } else return @intFromFloat(@max(0.0, @round(value.value)));
    }
};


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

/// Module-level spawn queue — dynamically allocated to handle bursty concurrent spawns.
///
/// X11 applications may spawn unpredictably (e.g., terminal emulators that F11 or re-exec).
/// A fixed-size array would silently lose registrations and misroute windows.
/// The queue grows on first-use and shrinks on config reload.

const SpawnQueue = struct {
    buf: []SpawnEntry,
    len: usize,
    alloc: std.mem.Allocator,

    fn init(self: *SpawnQueue, alloc: std.mem.Allocator) !void {
        self.alloc = alloc;
        self.buf = try alloc.alloc(SpawnEntry, 16);
        self.len = 0;
    }

    fn deinit(self: *const SpawnQueue) void {
        self.alloc.free(self.buf);
    }

    /// Appends `entry` to the queue.
    ///
    /// If we would overflow `len`, double-capacity and realloc.  Never loses data.
    fn push(self: *SpawnQueue, entry: SpawnEntry) !void {
        const new_len = self.len + 1;

        // Double buffer when needed; keep 64 as a soft ceiling to avoid excessive growth.
        if (new_len > self.buf.len) {
            const doubled = self.buf.len * 2;
            if (doubled < 64) {
                self.buf = try self.alloc.alloc(SpawnEntry, doubled);
                std.mem.copyForwards(SpawnEntry, self.buf[0..doubled], self.buf[0..doubled - 1]);
            } else {
                // Hit ceiling: reallocate at ceiling size.
                const ceiling = 64;
                self.buf = try self.alloc.alloc(SpawnEntry, ceiling);
                const to_copy = @min(new_len, ceiling);
                std.mem.copyForwards(SpawnEntry, self.buf[0..to_copy], self.buf[0..to_copy]);
            }
            self.len = 0;
        }

        self.buf[self.len] = entry;
        self.len += 1;
    }

    /// Removes the entry at index i, shifting later entries left, and returns its workspace.
    fn consume(self: *SpawnQueue, i: usize) u8 {
        const ws = self.buf[i].workspace;
        std.mem.copyForwards(SpawnEntry, self.buf[i .. self.len - 1], self.buf[i + 1 .. self.len]);
        self.len -= 1;
        return ws;
    }

    fn slice(self: *const SpawnQueue) []SpawnEntry { return self.buf[0..self.len]; }
};

var spawn_cursor: struct { x: i16 = 0, y: i16 = 0 } = .{};

var g_spawn_queue: ?*SpawnQueue = null;

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

/// Set by grab-flush paths that already called updateWorkspaceBorders() inside
/// their server grab, so the event loop can skip the redundant second sweep.
/// Reset unconditionally by updateWorkspaceBordersIfNeeded() at the end of each
/// event batch regardless of whether the flag was set.
var borders_flushed_this_batch: bool = false;

/// Save `rect` as the last-known geometry for `win`.
/// Delegates to tiling when present; writes to g_geom_cache otherwise.
pub fn saveWindowGeom(win: u32, rect: utils.Rect) void {
    if (build.has_tiling) {
        tiling.saveWindowGeom(win, rect);
    } else {
        g_geom_cache.getOrPut(win).value_ptr.rect = rect;
    }
}

/// Return the last-known geometry for `win`, or null if none is cached.
/// Delegates to tiling when present; reads from g_geom_cache otherwise.
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
    if (build.has_tiling) {
        // tiling.removeWindow handles this
    } else {
        g_geom_cache.remove(win);
    }
}


fn populateAtomCache() void {
    inline for (.{
        .{ .field = "wm_protocols", .atom = "WM_PROTOCOLS" },
        .{ .field = "wm_class",     .atom = "WM_CLASS"     },
        .{ .field = "net_wm_pid",   .atom = "_NET_WM_PID"  },
    }) |e| @field(atoms, e.field) = utils.getAtomCached(e.atom) catch 0;
}

pub fn init(alloc: std.mem.Allocator) !void {
    tracking.init(alloc);
    focus.init(alloc);
    // tiling must precede workspaces: workspaces.init() calls tiling.getState().
    if (build.has_tiling)      tiling.init();
    if (build.has_fullscreen)  fullscreen.init();
    if (build.has_workspaces) try workspaces.init();
    if (build.has_minimize)    minimize.init();
    if (build.has_minimize or build.has_workspaces) {
        // Only allocate spawn queue if we have workspaces or minimize.
        // Pure tiling mode never needs spawn queue.
        if (g_spawn_queue == null) {
            g_spawn_queue = try alloc.create(SpawnQueue);
            if (g_spawn_queue) |sq| {
                sq.alloc = alloc;
                sq.buf = try alloc.alloc(SpawnEntry, 16);
                sq.len = 0;
            }
        }
    }
    populateAtomCache();
}

pub fn deinit() void {
    // Teardown in reverse-init order.
    if (build.has_tiling)     tiling.deinit();
    if (build.has_fullscreen) fullscreen.deinit();
    if (build.has_workspaces) workspaces.deinit();
    if (build.has_minimize)   minimize.deinit();
    if (g_spawn_queue) |sq| {
        sq.deinit();
        g_spawn_queue = null;
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
    // WM_CLASS may be NUL-padded; trim so the final class string has no trailing NUL.
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
///
/// Precondition: when c_net_wm_pid is non-null, the spawn queue is provably
/// non-empty — firePropertyCookies only fires the PID cookie when spawn queue
/// is non-empty.  No branch above consumes an entry without returning,
/// so the oldest-entry fallback is always reached with at least one entry present.
fn findSpawnQueueWorkspace(
    c_net_wm_pid: ?xcb.xcb_get_property_cookie_t,
    current_ws: u8,
) ?u8 {
    const pid_cookie = c_net_wm_pid orelse return null;

    const win_pid: u32 = pid: {
        const pid_reply = xcb.xcb_get_property_reply(core.conn, pid_cookie, null)
            orelse break :pid 0;
        defer std.c.free(pid_reply);
        if (pid_reply.*.format != 32 or pid_reply.*.value_len < 1) break :pid 0;
        break :pid @as([*]const u32, @ptrCast(@alignCast(xcb.xcb_get_property_value(pid_reply))))[0];
    };

    if (g_spawn_queue) |sq| {
        const entries = sq.slice();

        // Exact PID match.
        if (win_pid != 0) {
            for (entries, 0..) |e, i| {
                if (e.pid == win_pid) return sq.consume(i);
            }
        }

        // Daemon match (pid == 0 in both window and queue entry).
        if (win_pid == 0) {
            for (entries, 0..) |e, i| {
                if (e.pid == 0) return sq.consume(i);
            }
        }

        // Oldest-entry fallback — queue is non-empty per precondition (see doc comment).
        return sq.consume(0);
    }
    // spawn_queue is provably non-empty per firePropertyCookies logic

    // This branch should never be reached (atom 0 means empty queue),
    // but handle it conservatively: return current_ws as fallback.
    return current_ws;
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

    if (findSpawnQueueWorkspace(c_net_wm_pid, current_ws)) |spawn_ws|
        return clampToValidWorkspace(spawn_ws, current_ws);

    return current_ws;
}

// Map request

pub inline fn registerSpawn(workspace: u8, pid: u32) void {
    if (g_spawn_queue) |sq| {
        sq.push(.{ .workspace = workspace, .pid = pid }) catch |err| {
            debug.warn("registerSpawn: failed to queue spawn entry: {}", .{err});
        };
    }
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
    if (g_spawn_queue) |sq| {
        for (sq.slice(), 0..) |e, i| {
            if (e.pid == pid) {
                _ = sq.consume(i);
                return;
            }
        }
    }
}

/// Drain a pre-fired xcb_query_pointer cookie (fired before the server grab)
/// and record the cursor position for later spawn-crossing suppression checks.
/// The cookie is always consumed here — either drained if suppression is active,
/// or discarded if not — so the caller never holds an outstanding reply.
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
        .net_wm_pid = if (g_spawn_queue) |sq| if (sq.len > 0)
            xcb.xcb_get_property(
                core.conn, 0, win,
                atoms.net_wm_pid,
                xcb.XCB_ATOM_CARDINAL, 0, 1,
            )
            else null else null,
    };
}

/// Map a newly adopted window that is on the current workspace.
///
/// Runs inside a server grab: tiling registration + retile, geometry
/// configuration, map, focus, border sweep, and bar redraw all land in a
/// single atomic batch.  The pointer query is pre-fired before the grab
/// (analogous to unmanageWindow's pre-fire pattern) so the round-trip
/// overlaps with grab setup and tiling work.
fn mapWindowToScreen(win: u32) void {
    // Pre-fire pointer query before taking the grab so its round-trip overlaps
    // with grab setup and tiling work.  snapshotSpawnCursor drains or discards
    // it inside the grab depending on the suppress reason at that point.
    const ptr_cookie = xcb.xcb_query_pointer(core.conn, core.root);

    _ = xcb.xcb_grab_server(core.conn);

    // Configure geometry BEFORE mapping.  xcb_configure_window is valid on
    // an unmapped window — the geometry is stored and takes effect atomically
    // when the window is mapped.  Retiling here (which also pushes background
    // monocle windows offscreen) means the compositor never sees the new
    // window at its default X position or background windows still on-screen.
    if (tilingActive()) {
        tiling.addWindow(win);
        tiling.retileCurrentWorkspace();
    } else {
        // Without tiling, retileCurrentWorkspace() never runs, so we must
        // manually push the new window offscreen when fullscreen is active —
        // otherwise it maps on top of the fullscreen window and appears to
        // immediately vanish when the fullscreen window is raised above it.
        if (build.has_fullscreen) {
            if (fullscreen.hasAnyFullscreen()) {
                _ = xcb.xcb_configure_window(core.conn, win,
                    xcb.XCB_CONFIG_WINDOW_X,
                    &[_]u32{@bitCast(@as(i32, constants.OFFSCREEN_X_POSITION))});
            }
        }
    }

    // Apply border width and initial color before mapping so the compositor
    // never sees a borderless first frame.  The color is swept to its correct
    // focused value below by updateWorkspaceBorders(), still inside the grab.
    applyBorder(win);
    _ = xcb.xcb_map_window(core.conn, win);

    focus.setFocus(win, .window_spawn);
    // Capture the suppress reason written by setFocus(.window_spawn) and pass
    // it explicitly to snapshotSpawnCursor so its temporal dependency on
    // getSuppressReason() is structural (visible in the signature) rather than
    // implicit (hidden inside the function body).
    snapshotSpawnCursor(ptr_cookie, focus.getSuppressReason());

    // Sweep all workspace border colors inside the grab so they land in the
    // same atomic batch as the layout, map, and focus commands above.
    // updateWorkspaceBorders() already covers every window on the workspace —
    // including the newly focused one and the previously focused one — so a
    // separate updateFocusBorders() call here would be redundant.
    // markBordersFlushed() prevents the event loop from queuing a second sweep.
    updateWorkspaceBorders();
    bar.redrawInsideGrab();
    markBordersFlushed();

    _ = xcb.xcb_ungrab_server(core.conn);
    _ = xcb.xcb_flush(core.conn);
}

/// Register a newly adopted window that is on a non-current workspace.
///
/// No server grab is taken — the window is not mapped and no visual work
/// is needed.  Tiling registration and border setup run ungrabbed; the bar
/// is scheduled for a normal end-of-batch redraw.
fn registerWindowOffscreen(win: u32) void {
    // Register with tiling (no retile — the window is not visible yet and
    // will be retiled when its workspace is switched to).
    if (tilingActive()) tiling.addWindow(win);

    // Apply border width and initial color so the window is styled correctly
    // when its workspace is eventually switched to.
    applyBorder(win);
    focus.initWindowGrabs(win);

    // Off-workspace window: schedule bar update for the event loop's normal
    // end-of-batch flush.
    bar.scheduleRedraw();
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

    if (on_current) mapWindowToScreen(win) else registerWindowOffscreen(win);
}

// Unmap / destroy

fn unmanageWindow(win: u32) void {
    const was_fullscreen = if (build.has_fullscreen) blk: {
        const fs_ws = fullscreen.workspaceFor(win);
        if (fs_ws) |ws| fullscreen.removeForWorkspace(ws);
        break :blk fs_ws != null;
    } else false;

    // Capture before clearFocus/focusWindowUnderPointer commits any transition.
    // Both values depend on state that this function is about to mutate; reading
    // them after the mutation would give incorrect results.
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
    // tilingActive() reads core.config.tiling.enabled, which can change on a
    // config reload *after* a window was added to the tiling pool.  If
    // enabled flips false between addWindow and this unmanage call, the
    // runtime guard would skip removeWindow and leave the window as a zombie
    // in tiling.State.windows — causing ghost tiles on the next retile.
    // tiling.removeWindow is a safe no-op if the window was never added.
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
        if (window_workspace) |ws| {
            if (current_ws == ws) tiling.retileIfDirty()
            else tiling.retileInactiveWorkspace(ws);
        }
    }

    // Sweep border colors inside the grab so the repaint lands in the same
    // atomic batch as the layout and focus changes above.
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
///
/// Consults MRU history first (via focus.focusBestAvailable), falling back
/// to minimize.focusMasterOrFirst when the history is exhausted or contains no
/// window visible on the current workspace.  If a window is directly under the
/// pointer it is preferred over history (hover-focus expectation); the
/// pointer-position reply is pre-fired before the server grab to overlap the
/// round-trip.
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
    var n: u3 = 0;
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
    // DWM: if ((ev->mode != NotifyNormal || ev->detail == NotifyInferior) && ev->window != root) return;
    //
    // The `&& ev->window != root` clause is omitted here — root is never a
    // managed window so maybeFocusWindow would return early for it anyway.
    // This filters three cases DWM rejects:
    //   • mode != Normal  (GRAB, UNGRAB, WHILE_GRABBED — events during grabs)
    //   • detail == Inferior  (pointer moved to a child of this window; the
    //     managed window itself did not change — no focus action needed)
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
    // DWM: c = wintoclient(ev->window) — direct lookup, no tree walk.
    // We use findManagedWindow so child-window EnterNotify events (e.g. from
    // apps that create subwindows) resolve to their managed parent, but the
    // root redirect that was here previously is removed: DWM's wintoclient
    // returns NULL for root and exits early, so we should do the same.
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
    // When child is zero the pointer left to an area not covered by any window;
    // maybeFocusWindow(0) would immediately fail isOnCurrentWorkspace anyway.
    if (event.child == 0) return;
    maybeFocusWindow(event.child);
}

// Property notify

pub fn handlePropertyNotify(event: *const xcb.xcb_property_notify_event_t) void {
    if (!isValidManagedWindow(event.window)) return;
    // Invalidate the focus-model cache on either WM_HINTS or WM_PROTOCOLS changes.
    // WM_HINTS carries the ICCCM input flag (passive/locally_active/globally_active/
    // no_input); WM_PROTOCOLS carries WM_TAKE_FOCUS advertisement.  Both can change
    // after a window is mapped — see focus.invalidateInputModelCache for details.
    if (event.atom != atoms.wm_protocols and event.atom != xcb.XCB_ATOM_WM_HINTS) return;
    focus.invalidateInputModelCache(event.window);
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

    if (build.has_tiling)
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
    if (build.has_tiling) {
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
    if (build.has_fullscreen) {
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
///
/// Do NOT call this when updateWorkspaceBorders() is also being called in
/// the same batch — the workspace sweep already covers both windows, and
/// calling this first generates two redundant xcb_change_window_attributes
/// requests that are immediately overwritten before the server flushes them.
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
    if (!build.has_workspaces) return;
    const ws = wsGetCurrentWorkspaceObject() orelse return;
    for (ws.windows.items()) |win|
        _ = xcb.xcb_change_window_attributes(core.conn, win,
            xcb.XCB_CW_BORDER_PIXEL, &[_]u32{borderColor(win)});
}

/// Mark that the current event batch already swept all workspace border colors
/// inside a server grab, so the event loop does not need to do it again.
/// Called by grab-flush paths in this module (and exposed to input.zig for the
/// swap_master handlers) immediately after calling updateWorkspaceBorders().
pub fn markBordersFlushed() void { borders_flushed_this_batch = true; }

/// Event-loop entry point for the per-batch border sweep.
/// Calls updateWorkspaceBorders() only when no grab-flush path already did so,
/// then unconditionally resets the flag for the next batch.
pub fn updateWorkspaceBordersIfNeeded() void {
    if (!borders_flushed_this_batch) updateWorkspaceBorders();
    borders_flushed_this_batch = false;
}

// ClientMessage — EWMH fullscreen requests from applications

/// Handles _NET_WM_STATE ClientMessage events sent by applications requesting
/// fullscreen transitions (e.g. browsers pressing F11, SDL games, video players).
/// Per EWMH §5.6.1: data32[0] = action (0=remove,1=add,2=toggle),
///                   data32[1]/[2] = the state atoms to change.
pub fn handleClientMessage(event: *const xcb.xcb_client_message_event_t) void {
    if (event.format != 32) return;

    const net_wm_state = utils.getAtomCached("_NET_WM_STATE") catch return;
    if (event.type != net_wm_state) return;

    const fs_atom = utils.getAtomCached("_NET_WM_STATE_FULLSCREEN") catch return;
    const prop1   = event.data.data32[1];
    const prop2   = event.data.data32[2];
    if (prop1 != fs_atom and prop2 != fs_atom) return;

    const win = event.window;
    if (!isValidManagedWindow(win)) return;

    if (build.has_fullscreen) {
        const action = event.data.data32[0];
        const is_fs  = fullscreen.isFullscreen(win);
        const should_enter = switch (action) {
            // ADD: unconditionally want fullscreen; the `should_enter and !is_fs`
            // guard below prevents a double-enter when already fullscreen.
            // Using `!is_fs` here was wrong: it made should_enter=false when
            // is_fs=true, causing `else if (!should_enter and is_fs)` to fire
            // and incorrectly exit fullscreen on a redundant ADD request.
            1 => true,   // _NET_WM_STATE_ADD
            0 => false,  // _NET_WM_STATE_REMOVE
            2 => !is_fs, // _NET_WM_STATE_TOGGLE
            else => return,
        };
        if (should_enter and !is_fs) {
            fullscreen.enterFullscreen(win, null);
        } else if (!should_enter and is_fs) {
            // enterFullscreen takes null saved_geom for a fresh exit path; re-use toggle()
            // which resolves the correct workspace and restores floating windows.
            fullscreen.toggle();
        }
    }
}

/// Push updated border width and colors to every managed window across all
/// workspaces. Called on config reload so color and width changes take effect
/// immediately on all windows, not just those on the current workspace.
pub fn reloadBorders() void {
    if (getBorderWidth() == 0) return;
    if (!build.has_workspaces) return;
    const ws_state = wsGetState() orelse return;
    for (ws_state.workspaces) |*ws|
        for (ws.windows.items()) |win| applyBorder(win);
}
