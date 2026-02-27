//! Window lifecycle — map/unmap/destroy, configure, enter/button events,
//! and per-window property caching.

const std        = @import("std");
const defs       = @import("defs");
const xcb        = defs.xcb;
const WM         = defs.WM;
const utils      = @import("utils");
const constants  = @import("constants");
const focus      = @import("focus");
const tiling     = @import("tiling");
const bar        = @import("bar");
const workspaces = @import("workspaces");
const debug      = @import("debug");
const minimize   = @import("minimize");
const layouts    = @import("layouts");

const WINDOW_EVENT_MASK = constants.EventMasks.MANAGED_WINDOW;

// XSizeHints flags (ICCCM §4.1.2.3)
const XSIZE_HINTS_P_MIN_SIZE:  u32 = 0x010;
const XSIZE_HINTS_P_BASE_SIZE: u32 = 0x100;

// ── Module-level atom cache ───────────────────────────────────────────────────
//
// utils.getAtomCached already memoises atom→ID lookups, but each call still
// pays a string-keyed hash probe.  The three atoms used on every MapRequest
// are resolved once into plain u32 fields on first use, turning per-event
// probes into direct field reads.
//
// Atoms that cannot be interned remain 0 (XCB_ATOM_NONE); property cookies
// sent with atom 0 return an empty reply, which existing null-reply guards
// already handle correctly.

var g_atoms: struct {
    wm_protocols: u32 = 0,
    wm_class:     u32 = 0,
    net_wm_pid:   u32 = 0,
} = .{};
var g_atoms_ready: bool = false;

// Populate g_atoms on the first call; all subsequent calls are a branch-predictable early return.
// TODO: replace with std.once when the codebase moves to a multi-threaded event loop.
fn initAtomCache() void {
    if (g_atoms_ready) return;
    inline for (.{
        .{ "wm_protocols", "WM_PROTOCOLS" },
        .{ "wm_class",     "WM_CLASS"     },
        .{ "net_wm_pid",   "_NET_WM_PID"  },
    }) |e| @field(g_atoms, e[0]) = utils.getAtomCached(e[1]) catch 0;
    g_atoms_ready = true;
}

// Window predicates

pub inline fn isValidManagedWindow(wm: *WM, win: u32) bool {
    return win != 0 and
           win != wm.root and
           !bar.isBarWindow(win) and
           workspaces.getWorkspaceForWindow(win) != null;
}

pub inline fn isOnCurrentWorkspace(wm: *WM, win: u32) bool {
    return isValidManagedWindow(wm, win) and
           workspaces.isOnCurrentWorkspace(win);
}

// Button grab management

pub fn grabButtons(wm: *WM, win: u32, focused: bool) void {
    _ = xcb.xcb_ungrab_button(wm.conn, xcb.XCB_BUTTON_INDEX_ANY, win, xcb.XCB_MOD_MASK_ANY);
    if (!focused) {
        _ = xcb.xcb_grab_button(
            wm.conn, 0, win, xcb.XCB_EVENT_MASK_BUTTON_PRESS,
            xcb.XCB_GRAB_MODE_SYNC, xcb.XCB_GRAB_MODE_SYNC,
            xcb.XCB_NONE, xcb.XCB_NONE, xcb.XCB_BUTTON_INDEX_ANY, xcb.XCB_MOD_MASK_ANY,
        );
    }
}

// Workspace rule matching

fn resolveWorkspace(target: u8, fallback: u8) u8 {
    const s = workspaces.getState() orelse return fallback;
    return if (target < s.workspaces.len) target else fallback;
}

/// Collect a pre-fired WM_CLASS property cookie and match it against workspace
/// rules.  Parses instance/class directly from the reply buffer — no allocation.
/// O(n) in the number of rules; typical configs have a handful, so this is
/// fine.  If rule counts grow large, a pre-built StringHashMap at config-load
/// time would give O(1) per MapRequest.
fn workspaceRuleForClass(wm: *WM, cookie: xcb.xcb_get_property_cookie_t) ?u8 {
    const reply = xcb.xcb_get_property_reply(wm.conn, cookie, null) orelse return null;
    defer std.c.free(reply);
    if (reply.*.format != 8 or reply.*.value_len == 0) return null;

    const raw: [*]const u8 = @ptrCast(xcb.xcb_get_property_value(reply));
    const raw_all = raw[0..@as(usize, @intCast(reply.*.value_len))];
    const data    = std.mem.trimEnd(u8, raw_all, &[_]u8{0});

    const sep = std.mem.indexOfScalar(u8, data, 0) orelse return null;
    const class_start = sep + 1;
    if (class_start >= data.len) return null;

    const instance = data[0..sep];
    const class    = data[class_start..];

    for (wm.config.workspaces.rules.items) |rule| {
        if (std.mem.eql(u8, rule.class_name, class) or
            std.mem.eql(u8, rule.class_name, instance))
        {
            return rule.workspace;
        }
    }
    return null;
}

// Tiling registration

fn registerWithTiling(wm: *WM, win: u32, and_retile: bool) void {
    if (!wm.config.tiling.enabled) return;
    tiling.addWindow(wm, win);
    if (and_retile) tiling.retileCurrentWorkspace(wm);
}

// Workspace assignment

fn resolveTargetWorkspace(
    wm:          *WM,
    win:         u32,
    current_ws:  u8,
    // Null when the spawn queue is empty — avoids the need for a separate
    // `has_pending_spawns` bool and makes it impossible to access an
    // undefined cookie.
    c_net_wm_pid: ?xcb.xcb_get_property_cookie_t,
) u8 {
    // Phase 1 — Workspace class rules (highest priority).
    // g_atoms.wm_class is a cached direct field read; no hash probe.
    if (wm.config.workspaces.rules.items.len > 0) {
        const c_class = xcb.xcb_get_property(
            wm.conn, 0, win,
            g_atoms.wm_class,
            xcb.XCB_ATOM_STRING, 0, 256,
        );
        if (workspaceRuleForClass(wm, c_class)) |target| {
            // Discard the PID cookie if one was fired; XCB requires every
            // outstanding cookie to be consumed before the connection is closed.
            if (c_net_wm_pid) |pid_cookie|
                xcb.xcb_discard_reply(wm.conn, pid_cookie.sequence);
            return resolveWorkspace(target, current_ws);
        }
    }

    // Phase 2 — Exec-spawn workspace.
    if (c_net_wm_pid) |pid_cookie| {
        const win_pid: u32 = pid: {
            const pid_reply = xcb.xcb_get_property_reply(wm.conn, pid_cookie, null)
                orelse break :pid 0;
            defer std.c.free(pid_reply);
            if (pid_reply.*.format != 32 or pid_reply.*.value_len < 1) break :pid 0;
            break :pid @as([*]const u32, @ptrCast(@alignCast(xcb.xcb_get_property_value(pid_reply))))[0];
        };

        if (wm.spawn_queue.popByPid(win_pid)) |spawn_ws|
            return resolveWorkspace(spawn_ws, current_ws);

        if (win_pid == 0) {
            if (wm.spawn_queue.popOldestDaemon()) |spawn_ws|
                return resolveWorkspace(spawn_ws, current_ws);
        }
    }

    return current_ws;
}

// Map request

pub fn registerSpawn(wm: *WM, workspace: u8, pid: u32) void {
    wm.spawn_queue.push(workspace, pid);
}

fn snapshotSpawnCursor(wm: *WM) void {
    if (wm.suppress_focus_reason != .window_spawn) return;
    const ptr = xcb.xcb_query_pointer_reply(
        wm.conn, xcb.xcb_query_pointer(wm.conn, wm.root), null,
    ) orelse return;
    defer std.c.free(ptr);
    wm.spawn_cursor_x = ptr.*.root_x;
    wm.spawn_cursor_y = ptr.*.root_y;
}

pub fn handleMapRequest(event: *const xcb.xcb_map_request_event_t, wm: *WM) void {
    const win        = event.window;
    const current_ws = workspaces.getCurrentWorkspace() orelse 0;

    // Ensure atom IDs are populated.  No-op after first call.
    initAtomCache();

    _ = xcb.xcb_change_window_attributes(
        wm.conn, win, xcb.XCB_CW_EVENT_MASK, &[_]u32{WINDOW_EVENT_MASK},
    );

    // Fire focus-cache property cookies — always needed, no blocking.
    // g_atoms.wm_protocols is a direct field read; no string hash probe.
    const c_protocols = xcb.xcb_get_property(
        wm.conn, 0, win,
        g_atoms.wm_protocols,
        xcb.XCB_ATOM_ATOM, 0, 256,
    );
    const c_hints = xcb.xcb_get_property(
        wm.conn, 0, win, xcb.XCB_ATOM_WM_HINTS, xcb.XCB_ATOM_WM_HINTS, 0, 9,
    );
    const c_normal_hints = xcb.xcb_get_property(
        wm.conn, 0, win,
        xcb.XCB_ATOM_WM_NORMAL_HINTS, xcb.XCB_ATOM_ANY, 0, 18,
    );
    // g_atoms.net_wm_pid is a direct field read; no string hash probe.
    // Use an optional so the type system enforces that this cookie is only
    // consumed when the spawn queue is non-empty — no silent undefined reads.
    const c_net_wm_pid: ?xcb.xcb_get_property_cookie_t =
        if (!wm.spawn_queue.isEmpty()) xcb.xcb_get_property(
            wm.conn, 0, win,
            g_atoms.net_wm_pid,
            xcb.XCB_ATOM_CARDINAL, 0, 1,
        ) else null;

    const target_ws            = resolveTargetWorkspace(wm, win, current_ws, c_net_wm_pid);
    const on_current_workspace = (target_ws == current_ws);

    workspaces.moveWindowTo(wm, win, target_ws) catch |err| {
        debug.logError(err, win);
        // Discard all outstanding property cookies.  XCB buffers uncollected
        // replies internally; never discarding them causes unbounded growth in
        // applications that fail to map frequently (e.g. crash-looping clients).
        xcb.xcb_discard_reply(wm.conn, c_protocols.sequence);
        xcb.xcb_discard_reply(wm.conn, c_hints.sequence);
        xcb.xcb_discard_reply(wm.conn, c_normal_hints.sequence);
        utils.flush(wm.conn);
        return;
    };

    collectAndCacheSizeHints(wm, win, c_normal_hints);

    // Collect focus-cache property replies *before* any visual commands.
    //
    // Previously this call came after utils.flush(), which meant the server
    // (and compositor) received map + unfocused-border in one batch, then had
    // to wait for two xcb_get_property_reply round-trips before seeing
    // set_input_focus + focused-border in a second batch.  With a compositor
    // running that produced a visible intermediate frame where the spawned
    // window appeared briefly unfocused/unfocused-colored before snapping to
    // its final state — the "sluggish spawn" feel.
    //
    // Moving the call here is safe: the cookies were fired at the top of this
    // function before any flush, so the X server has already queued the
    // property replies by the time we read them.  getInputModelCached in
    // setFocus finds the cache warm and does no live query.
    //
    // Result: registerWithTiling + xcb_map_window + setFocus (set_input_focus
    // + focused border) are all queued on the XCB write buffer before the
    // single flush below.  They land at the server — and the compositor — as
    // one atomic batch, matching dwm's Xlib-buffer behaviour.
    utils.populateFocusCacheFromCookies(wm.conn, win, c_protocols, c_hints);

    if (on_current_workspace) {
        registerWithTiling(wm, win, true);
        _ = xcb.xcb_map_window(wm.conn, win);
        focus.setFocus(wm, win, .window_spawn);
        snapshotSpawnCursor(wm);
    } else {
        registerWithTiling(wm, win, false);
        grabButtons(wm, win, false);
    }

    // Single flush — all visual state (geometry, map, border, focus) arrives
    // at the server in one batch.  No intermediate compositor frame possible.
    utils.flush(wm.conn);

    bar.markDirty();
}

// Unmap / destroy

fn unmanageWindow(wm: *WM, win: u32) void {
    const was_fullscreen = if (wm.fullscreen.window_to_workspace.get(win)) |ws| blk: {
        wm.fullscreen.removeForWorkspace(ws);
        break :blk true;
    } else false;

    const was_focused = (wm.focused_window == win);

    const window_workspace = workspaces.getWorkspaceForWindow(win);
    const current_ws       = workspaces.getCurrentWorkspace();

    // Pre-fire pointer query before state cleanup so the round-trip runs
    // concurrently with the in-memory operations below (tiling remove, cache
    // evictions, workspace remove — all pure hash-table work, no X round-trips).
    // By the time focusWindowUnderPointer consumes the reply the network
    // latency is fully hidden and the reply is already in the receive buffer.
    // The cookie is conditional: no query needed when the closed window was not
    // focused, avoiding an unnecessary round-trip in the common case.
    const ptr_cookie: ?xcb.xcb_query_pointer_cookie_t =
        if (was_focused) xcb.xcb_query_pointer(wm.conn, wm.root) else null;

    if (wm.config.tiling.enabled) tiling.removeWindow(win);
    utils.uncacheWindowFocusProps(win);
    layouts.evictSizeHints(win);
    minimize.forceUntrack(wm, win);
    workspaces.removeWindow(win);

    _ = xcb.xcb_grab_server(wm.conn);

    if (was_fullscreen) {
        bar.setBarState(wm, .show_fullscreen);
    }

    if (was_focused) {
        if (wm.config.tiling.enabled) tiling.retileIfDirty(wm);
        focus.clearFocus(wm);
        focusWindowUnderPointer(wm, ptr_cookie.?);
    } else if (!was_fullscreen and wm.config.tiling.enabled) {
        if (window_workspace) |ws| {
            if (current_ws == ws) {
                tiling.retileIfDirty(wm);
            } else {
                tiling.retileInactiveWorkspace(wm, ws);
            }
        }
    }

    bar.redrawImmediate(wm);
    _ = xcb.xcb_ungrab_server(wm.conn);
    utils.flush(wm.conn);
}

fn handleWindowGone(wm: *WM, win: u32) void {
    if (!isValidManagedWindow(wm, win)) return;
    unmanageWindow(wm, win);
}

pub fn handleUnmapNotify(event: *const xcb.xcb_unmap_notify_event_t, wm: *WM) void {
    handleWindowGone(wm, event.window);
}

pub fn handleDestroyNotify(event: *const xcb.xcb_destroy_notify_event_t, wm: *WM) void {
    handleWindowGone(wm, event.window);
}

// Post-unmanage focus recovery
//
// Accepts a pre-fired xcb_query_pointer cookie so the round-trip runs
// concurrently with the in-memory state cleanup in unmanageWindow (tiling
// remove, cache evictions, workspace remove).  By the time this is called
// the reply is already in the receive buffer — zero additional wait.
fn focusWindowUnderPointer(wm: *WM, ptr_cookie: xcb.xcb_query_pointer_cookie_t) void {
    const reply = xcb.xcb_query_pointer_reply(wm.conn, ptr_cookie, null) orelse {
        minimize.focusBestAvailable(wm);
        return;
    };
    defer std.c.free(reply);

    const child = reply.*.child;
    if (isOnCurrentWorkspace(wm, child) and !minimize.isMinimized(wm, child)) {
        focus.setFocus(wm, child, .mouse_enter);
        return;
    }
    minimize.focusBestAvailable(wm);
}

// Configure request

const GEOMETRY_MASK: u16 =
    xcb.XCB_CONFIG_WINDOW_X | xcb.XCB_CONFIG_WINDOW_Y |
    xcb.XCB_CONFIG_WINDOW_WIDTH | xcb.XCB_CONFIG_WINDOW_HEIGHT |
    xcb.XCB_CONFIG_WINDOW_BORDER_WIDTH;

fn sendConfigureNotify(wm: *WM, win: u32, x: i16, y: i16, width: u16, height: u16, border: u16) void {
    const ev = xcb.xcb_configure_notify_event_t{
        .response_type     = xcb.XCB_CONFIGURE_NOTIFY,
        .pad0              = 0,
        .sequence          = 0,
        .event             = win,
        .window            = win,
        .above_sibling     = xcb.XCB_NONE,
        .x                 = x,
        .y                 = y,
        .width             = width,
        .height            = height,
        .border_width      = border,
        .override_redirect = 0,
        .pad1              = 0,
    };
    _ = xcb.xcb_send_event(wm.conn, 0, win, xcb.XCB_EVENT_MASK_STRUCTURE_NOTIFY, @ptrCast(&ev));
}

fn sendSyntheticConfigureNotify(wm: *WM, win: u32) void {
    // Fast path: serve the geometry from the tiling cache — zero round-trips.
    if (tiling.getCachedGeom(win)) |rect| {
        const border: u16 = if (tiling.getState()) |s| s.border_width else 0;
        sendConfigureNotify(wm, win, rect.x, rect.y, rect.width, rect.height, border);
        return;
    }

    // Slow path: fullscreen windows or a cache miss. One blocking round-trip.
    const reply = xcb.xcb_get_geometry_reply(
        wm.conn, xcb.xcb_get_geometry(wm.conn, win), null,
    ) orelse return;
    defer std.c.free(reply);
    sendConfigureNotify(wm, win, reply.*.x, reply.*.y, reply.*.width, reply.*.height, reply.*.border_width);
}

pub fn handleConfigureRequest(event: *const xcb.xcb_configure_request_event_t, wm: *WM) void {
    const win = event.window;
    if ((wm.config.tiling.enabled and tiling.isWindowTiled(win)) or
        wm.fullscreen.isFullscreen(win))
    {
        sendSyntheticConfigureNotify(wm, win);
        return;
    }

    const mask = event.value_mask & GEOMETRY_MASK;
    if (mask == 0) return;

    var values: [5]u32 = undefined;
    var n: u3 = 0;
    if (mask & xcb.XCB_CONFIG_WINDOW_X != 0)            { values[n] = @bitCast(@as(i32, event.x));            n += 1; }
    if (mask & xcb.XCB_CONFIG_WINDOW_Y != 0)            { values[n] = @bitCast(@as(i32, event.y));            n += 1; }
    if (mask & xcb.XCB_CONFIG_WINDOW_WIDTH != 0)        { values[n] = event.width;                            n += 1; }
    if (mask & xcb.XCB_CONFIG_WINDOW_HEIGHT != 0)       { values[n] = event.height;                           n += 1; }
    if (mask & xcb.XCB_CONFIG_WINDOW_BORDER_WIDTH != 0) { values[n] = event.border_width;                     n += 1; }
    _ = xcb.xcb_configure_window(wm.conn, win, mask, &values);
    utils.flush(wm.conn);
}

// Focus / crossing events

inline fn suppressSpawnCrossing(wm: *WM, root_x: i16, root_y: i16) bool {
    if (wm.suppress_focus_reason != .window_spawn) return false;
    if (root_x == wm.spawn_cursor_x and root_y == wm.spawn_cursor_y) return true;
    wm.suppress_focus_reason = .none;
    return false;
}

// Common tail for enter/leave: guard managed+visible+unfocused, then set focus.
inline fn maybeFocusWindow(wm: *WM, win: u32) void {
    if (!isOnCurrentWorkspace(wm, win)) return;
    if (minimize.isMinimized(wm, win)) return;
    if (wm.focused_window == win) return;
    focus.setFocus(wm, win, .mouse_enter);
}

pub fn handleEnterNotify(event: *const xcb.xcb_enter_notify_event_t, wm: *WM) void {
    wm.last_event_time = event.time;
    if (event.mode == xcb.XCB_NOTIFY_MODE_GRAB or
        event.mode == xcb.XCB_NOTIFY_MODE_UNGRAB) return;
    if (wm.drag_state.active) return;
    if (suppressSpawnCrossing(wm, event.root_x, event.root_y)) return;
    const win = if (event.event == wm.root and event.child != 0) event.child else event.event;
    maybeFocusWindow(wm, win);
}

pub fn handleLeaveNotify(event: *const xcb.xcb_leave_notify_event_t, wm: *WM) void {
    wm.last_event_time = event.time;
    if (event.event != wm.root) return;
    if (event.mode != xcb.XCB_NOTIFY_MODE_NORMAL) return;
    if (wm.drag_state.active) return;
    if (suppressSpawnCrossing(wm, event.root_x, event.root_y)) return;

    // `event.child` is the new inferior of root being entered.
    // When non-zero, the event already carries the answer — no round-trip needed.
    // When zero, the pointer left to an area not covered by any X window
    // (off-screen, inter-monitor gap, etc.).  A QueryPointer in that case also
    // returns child=0, so maybeFocusWindow(wm, 0) would immediately fail
    // isOnCurrentWorkspace and return.  Skip the useless round-trip entirely.
    if (event.child == 0) return;

    maybeFocusWindow(wm, event.child);
}

// Property notify

pub fn handlePropertyNotify(event: *const xcb.xcb_property_notify_event_t, wm: *WM) void {
    if (!isValidManagedWindow(wm, event.window)) return;
    // g_atoms.wm_protocols is a direct field read after initAtomCache().
    // initAtomCache is called at handleMapRequest time for every managed window,
    // so g_atoms is always populated by the time a PropertyNotify arrives.
    if (event.atom == g_atoms.wm_protocols or event.atom == xcb.XCB_ATOM_WM_HINTS) {
        utils.recacheInputModel(wm.conn, event.window);
    }
}

// Size-hint parsing

inline fn clampU16(v: u32) u16 {
    return @intCast(@min(v, std.math.maxInt(u16)));
}

fn collectAndCacheSizeHints(
    wm:     *WM,
    win:    u32,
    cookie: xcb.xcb_get_property_cookie_t,
) void {
    const reply = xcb.xcb_get_property_reply(wm.conn, cookie, null) orelse return;
    defer std.c.free(reply);
    if (reply.*.format != 32 or reply.*.value_len < 5) return;

    const fields: [*]const u32 = @ptrCast(@alignCast(xcb.xcb_get_property_value(reply)));
    const field_count = reply.*.value_len;
    const flags       = fields[0];

    var min_width:  u16 = 0;
    var min_height: u16 = 0;

    if (flags & XSIZE_HINTS_P_MIN_SIZE != 0 and field_count >= 7) {
        min_width  = clampU16(fields[5]);
        min_height = clampU16(fields[6]);
    }
    if (flags & XSIZE_HINTS_P_BASE_SIZE != 0 and field_count >= 17) {
        // @max with 0 is a no-op, so no explicit > 0 guard is needed.
        min_width  = @max(min_width,  clampU16(fields[15]));
        min_height = @max(min_height, clampU16(fields[16]));
    }

    layouts.cacheSizeHints(wm.allocator, win, .{ .min_width = min_width, .min_height = min_height });
}
