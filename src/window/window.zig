//! Window lifecycle — map/unmap/destroy, configure, enter/button events,
//! and per-window property caching.

const std        = @import("std");
const core = @import("core");
const xcb        = core.xcb;
const utils      = @import("utils");
const constants  = @import("constants");
const focus      = @import("focus");
const tiling     = @import("tiling");
const bar        = @import("bar");
const workspaces = @import("workspaces");
const drag       = @import("drag");
const debug      = @import("debug");
const minimize   = @import("minimize");
const fullscreen = @import("fullscreen");

// XSizeHints flags (ICCCM §4.1.2.3)
const XSIZE_HINTS_P_MIN_SIZE:  u32 = 0x10;
const XSIZE_HINTS_P_BASE_SIZE: u32 = 0x100;

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
    buf: [16]SpawnEntry = undefined,
    len: u5 = 0,

    fn push(self: *SpawnQueue, entry: SpawnEntry) void {
        if (self.len == 16) {
            std.mem.copyForwards(SpawnEntry, self.buf[0..15], self.buf[1..16]);
            self.len -= 1;
        }
        self.buf[self.len] = entry;
        self.len += 1;
    }

    fn slice(self: *SpawnQueue) []SpawnEntry { return self.buf[0..self.len]; }
};

var g_spawn_queue: SpawnQueue = .{};
var g_spawn_cursor: struct { x: i16 = 0, y: i16 = 0 } = .{};

// Module-level atom cache
//
// The three atoms used on every MapRequest are resolved once into plain u32
// fields, turning per-event hash probes into direct field reads.
// Atoms that cannot be interned remain 0; property cookies sent with atom 0
// return an empty reply, which existing null-reply guards handle correctly.
//
// g_init_once guarantees populateAtomCache runs exactly once and is safe
// under a future multi-threaded event loop without further changes.

var g_atoms: struct {
    wm_protocols: u32 = 0,
    wm_class:     u32 = 0,
    net_wm_pid:   u32 = 0,
} = .{};

var g_init_once = std.once(populateAtomCache);

fn populateAtomCache() void {
    inline for (.{
        .{ .field = "wm_protocols", .atom = "WM_PROTOCOLS" },
        .{ .field = "wm_class",     .atom = "WM_CLASS"     },
        .{ .field = "net_wm_pid",   .atom = "_NET_WM_PID"  },
    }) |e| @field(g_atoms, e.field) = utils.getAtomCached(e.atom) catch 0;
}

// Window predicates

pub inline fn isValidManagedWindow(win: u32) bool {
    return win != 0 and
           win != core.root and
           !bar.isBarWindow(win) and
           workspaces.getWorkspaceForWindow(win) != null;
}

pub inline fn isOnCurrentWorkspace(win: u32) bool {
    return isValidManagedWindow(win) and
           workspaces.isOnCurrentWorkspace(win);
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
    const s = workspaces.getState() orelse return fallback;
    return if (target < s.workspaces.len) target else fallback;
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
/// Guards on g_atoms.wm_class: if atom internment failed the cookie would
/// carry atom 0, triggering a pointless server round-trip on every MapRequest.
fn findClassRuleWorkspace(win: u32) ?u8 {
    if (core.config.workspaces.rules.items.len == 0 or g_atoms.wm_class == 0) return null;
    const cookie = xcb.xcb_get_property(
        core.conn, 0, win,
        g_atoms.wm_class,
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

    const entries = g_spawn_queue.slice();

    // Exact PID match.
    if (win_pid != 0) {
        for (entries, 0..) |e, i| {
            if (e.pid == win_pid) {
                const ws = e.workspace;
                std.mem.copyForwards(SpawnEntry, entries[i..entries.len-1], entries[i+1..]);
                g_spawn_queue.len -= 1;
                return ws;
            }
        }
    }

    // Daemon match (pid == 0 in both window and queue entry).
    if (win_pid == 0) {
        for (entries, 0..) |e, i| {
            if (e.pid == 0) {
                const ws = e.workspace;
                std.mem.copyForwards(SpawnEntry, entries[i..entries.len-1], entries[i+1..]);
                g_spawn_queue.len -= 1;
                return ws;
            }
        }
    }

    // Oldest-entry fallback: any pending entry is almost certainly the source
    // of this window (the queue is only populated by explicit user exec actions).
    if (g_spawn_queue.len > 0) {
        const ws = entries[0].workspace;
        std.mem.copyForwards(SpawnEntry, entries[0..entries.len-1], entries[1..]);
        g_spawn_queue.len -= 1;
        return ws;
    }

    return null;
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
    g_spawn_queue.push(.{ .workspace = workspace, .pid = pid });
}

fn snapshotSpawnCursor() void {
    if (focus.getSuppressReason() != .window_spawn) return;
    const ptr = xcb.xcb_query_pointer_reply(
        core.conn, xcb.xcb_query_pointer(core.conn, core.root), null,
    ) orelse return;
    defer std.c.free(ptr);
    g_spawn_cursor.x = ptr.*.root_x;
    g_spawn_cursor.y = ptr.*.root_y;
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
            g_atoms.wm_protocols,
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
        .net_wm_pid = if (g_spawn_queue.len > 0) xcb.xcb_get_property(
            core.conn, 0, win,
            g_atoms.net_wm_pid,
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
    if (core.config.tiling.enabled) {
        tiling.addWindow(win);
        if (on_current_workspace) tiling.retileCurrentWorkspace();
    }

    if (on_current_workspace) {
        _ = xcb.xcb_map_window(core.conn, win);
        snapshotSpawnCursor();
    } else {
        grabButtons(win, false);
    }

    bar.scheduleRedraw();
    if (on_current_workspace) focus.setFocus(win, .window_spawn);

    if (on_current_workspace) _ = xcb.xcb_ungrab_server(core.conn);
    _ = xcb.xcb_flush(core.conn);
}

pub fn handleMapRequest(event: *const xcb.xcb_map_request_event_t) void {
    const win        = event.window;
    const current_ws = workspaces.getCurrentWorkspace() orelse 0;

    g_init_once.call();

    _ = xcb.xcb_change_window_attributes(
        core.conn, win, xcb.XCB_CW_EVENT_MASK, &[_]u32{constants.EventMasks.MANAGED_WINDOW},
    );

    const cookies  = firePropertyCookies(win);
    const target_ws = resolveTargetWorkspace(win, current_ws, cookies.net_wm_pid);
    const on_current = target_ws == current_ws;

    workspaces.moveWindowTo(win, target_ws) catch |err| {
        debug.logError(err, win);
        xcb.xcb_discard_reply(core.conn, cookies.protocols.sequence);
        xcb.xcb_discard_reply(core.conn, cookies.hints.sequence);
        xcb.xcb_discard_reply(core.conn, cookies.normal_hints.sequence);
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
    const fs_ws = fullscreen.workspaceFor(win);
    if (fs_ws) |ws| fullscreen.removeForWorkspace(ws);
    const was_fullscreen = fs_ws != null;

    const was_focused = (focus.getFocused() == win);

    const window_workspace = workspaces.getWorkspaceForWindow(win);
    const current_ws       = workspaces.getCurrentWorkspace();

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
    if (core.config.tiling.enabled) tiling.removeWindow(win);
    tiling.evictSizeHints(win);
    minimize.forceUntrack(win);
    workspaces.removeWindow(win);

    if (was_fullscreen) bar.setBarState(.show_fullscreen);

    if (was_focused) {
        if (core.config.tiling.enabled) tiling.retileIfDirty();
        focus.clearFocus();
        focusWindowUnderPointer(ptr_cookie.?);
    } else if (!was_fullscreen and core.config.tiling.enabled) {
        if (window_workspace) |ws| {
            if (current_ws == ws) {
                tiling.retileIfDirty();
            } else {
                tiling.retileInactiveWorkspace(ws);
            }
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

// Post-unmanage focus recovery.
//
// Priority order:
//   1. Window directly under the pointer (hover-focus expectation).
//   2. MRU history scan — the most recently focused window that is still
//      present, on the current workspace, and not minimized.  This means
//      closing N windows in a row always returns focus to the last window the
//      user actually interacted with, regardless of tiling order.
//   3. Tiling best-available fallback (master or first remaining slave) for
//      the case where history is empty or all history entries are gone.
fn focusPrevOrBest() void {
    for (focus.historyItems()) |prev| {
        if (isOnCurrentWorkspace(prev) and !minimize.isMinimized(prev)) {
            focus.setFocus(prev, .tiling_operation);
            return;
        }
    }
    minimize.focusBestAvailable();
}

fn focusWindowUnderPointer(ptr_cookie: xcb.xcb_query_pointer_cookie_t) void {
    const reply = xcb.xcb_query_pointer_reply(core.conn, ptr_cookie, null) orelse {
        focusPrevOrBest();
        return;
    };
    defer std.c.free(reply);
    const child = reply.*.child;
    if (isOnCurrentWorkspace(child) and !minimize.isMinimized(child)) {
        focus.setFocus(child, .mouse_enter);
        return;
    }
    focusPrevOrBest();
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
    if (tiling.getWindowGeom(win)) |rect| {
        const border: u16 = if (tiling.getStateOpt()) |s| s.border_width else 0;
        sendConfigureNotify(win, .{
            .x = rect.x, .y = rect.y, .width = rect.width, .height = rect.height,
            .border_width = border,
        });
        return;
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
    if (tiling.isWindowActiveTiled(win) or fullscreen.isFullscreen(win)) {
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
    if (root_x == g_spawn_cursor.x and root_y == g_spawn_cursor.y) return true;
    focus.setSuppressReason(.none);
    return false;
}

inline fn maybeFocusWindow(win: u32) void {
    if (!isOnCurrentWorkspace(win)) return;
    if (minimize.isMinimized(win)) return;
    if (focus.getFocused() == win) return;
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
    maybeFocusWindow(utils.findManagedWindow(core.conn, win, workspaces.isManaged));
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
    if (event.atom == g_atoms.wm_protocols or event.atom == xcb.XCB_ATOM_WM_HINTS) {
        utils.recacheInputModel(core.conn, event.window);
    }
}

// Size-hint parsing

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
    if (flags & (XSIZE_HINTS_P_MIN_SIZE | XSIZE_HINTS_P_BASE_SIZE) == 0) return;

    var min_width:  u16 = 0;
    var min_height: u16 = 0;

    if (flags & XSIZE_HINTS_P_MIN_SIZE != 0 and field_count >= 7) {
        min_width  = @intCast(@min(fields[5], std.math.maxInt(u16)));
        min_height = @intCast(@min(fields[6], std.math.maxInt(u16)));
    }
    if (flags & XSIZE_HINTS_P_BASE_SIZE != 0 and field_count >= 17) {
        min_width  = @max(min_width,  @as(u16, @intCast(@min(fields[15], std.math.maxInt(u16)))));
        min_height = @max(min_height, @as(u16, @intCast(@min(fields[16], std.math.maxInt(u16)))));
    }

    tiling.cacheSizeHints(core.alloc, win, .{ .min_width = min_width, .min_height = min_height });
}
