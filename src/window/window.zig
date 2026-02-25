// Window lifecycle — map/unmap/destroy, configure, enter/button events.

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

// XSizeHints flags (ICCCM §4.1.2.3) — indicate which size fields are present
// in the wire format.  Used when parsing WM_NORMAL_HINTS property replies.
const XSIZE_HINTS_P_MIN_SIZE:  u32 = 0x010;
const XSIZE_HINTS_P_BASE_SIZE: u32 = 0x100;

// Window predicates

/// Returns true when `win` is non-zero, not the root window, not the bar, and
/// is tracked by the window manager. This is the core validity check for any
/// window operation.
pub inline fn isValidManagedWindow(wm: *WM, win: u32) bool {
    return win != 0 and
           win != wm.root and
           !bar.isBarWindow(win) and
           workspaces.getWorkspaceForWindow(win) != null;
}

/// Returns true when `win` passes isValidManagedWindow and is on the current
/// workspace. Combines both checks in a single call for event handlers.
pub inline fn isOnCurrentWorkspace(wm: *WM, win: u32) bool {
    return isValidManagedWindow(wm, win) and
           workspaces.isOnCurrentWorkspace(win);
}

// Button grab management

/// For unfocused windows we grab all buttons in sync mode so we can intercept
/// the click, focus the window, and replay the event.  For focused windows we
/// ungrab so the window receives clicks directly.
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
/// Returns the target workspace index, or null if no rule matched or no reply.
fn workspaceRuleForClass(wm: *WM, cookie: xcb.xcb_get_property_cookie_t) ?u8 {
    const reply = xcb.xcb_get_property_reply(wm.conn, cookie, null) orelse return null;
    defer std.c.free(reply);
    if (reply.*.format != 8 or reply.*.value_len == 0) return null;

    const raw: [*]const u8 = @ptrCast(xcb.xcb_get_property_value(reply));
    // Strip trailing null bytes that some clients include in value_len.
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

/// Register `win` with the tiling system and, when `and_retile` is true,
/// immediately retile the current workspace.  No-op when tiling is disabled.
fn registerWithTiling(wm: *WM, win: u32, and_retile: bool) void {
    if (!wm.config.tiling.enabled) return;
    tiling.addWindow(wm, win);
    if (and_retile) tiling.retileCurrentWorkspace(wm);
}

// Workspace assignment

/// Determine which workspace `win` should appear on.
/// Priority: workspace class rules > exec-spawn workspace > current workspace.
fn resolveTargetWorkspace(
    wm:                 *WM,
    win:                u32,
    current_ws:         u8,
    c_net_wm_pid:       xcb.xcb_get_property_cookie_t,
    has_pending_spawns: bool,
) u8 {
    // Phase 1 — Workspace class rules (highest priority).
    if (wm.config.workspaces.rules.items.len > 0) {
        const c_class = xcb.xcb_get_property(
            wm.conn, 0, win,
            utils.getAtomCached("WM_CLASS") catch 0,
            xcb.XCB_ATOM_STRING, 0, 256,
        );
        if (workspaceRuleForClass(wm, c_class)) |target| {
            // Discard the PID cookie so XCB does not see an uncollected reply.
            if (has_pending_spawns)
                xcb.xcb_discard_reply(wm.conn, c_net_wm_pid.sequence);
            return resolveWorkspace(target, current_ws);
        }
    }

    // Phase 2 — Exec-spawn workspace (two-sub-phase lookup).
    if (has_pending_spawns) {
        // Extract the window's PID from _NET_WM_PID, defaulting to 0 if the
        // property is absent or malformed (daemon-mode terminals, or programs
        // that fail to write it before mapping).
        const win_pid: u32 = pid: {
            const pid_reply = xcb.xcb_get_property_reply(wm.conn, c_net_wm_pid, null)
                orelse break :pid 0;
            defer std.c.free(pid_reply);
            if (pid_reply.*.format != 32 or pid_reply.*.value_len < 1) break :pid 0;
            break :pid @as([*]const u32, @ptrCast(@alignCast(xcb.xcb_get_property_value(pid_reply))))[0];
        };

        // Phase 2a: direct PID match — works for any program that sets _NET_WM_PID.
        if (wm.spawn_queue.popByPid(win_pid)) |spawn_ws|
            return resolveWorkspace(spawn_ws, current_ws);

        // Phase 2b: daemon fallback — only when the window has no PID.
        // Windows with a non-zero PID that didn't match the queue were not
        // launched from a WM keybind; leave them on the current workspace.
        if (win_pid == 0) {
            if (wm.spawn_queue.popOldestDaemon()) |spawn_ws|
                return resolveWorkspace(spawn_ws, current_ws);
        }
    }

    // Phase 3 — Default: whichever workspace is active at map time.
    return current_ws;
}

// Map request

/// Called by input.executeShellCommand after a confirmed successful exec.
/// `pid` is the grandchild PID forwarded via pipe; 0 for daemon-mode terminals.
pub fn registerSpawn(wm: *WM, workspace: u8, pid: u32) void {
    wm.spawn_queue.push(workspace, pid);
}

/// Capture the pointer position right after a window spawn so subsequent
/// crossing events at the same coordinates can be identified as retile
/// side-effects rather than genuine user movement.
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

    // Subscribe to events on this window before anything else so no
    // state-change events escape between setup and the map.
    _ = xcb.xcb_change_window_attributes(
        wm.conn, win, xcb.XCB_CW_EVENT_MASK, &[_]u32{WINDOW_EVENT_MASK},
    );

    // Fire focus-cache property cookies — always needed, no blocking.
    const c_protocols = xcb.xcb_get_property(
        wm.conn, 0, win,
        utils.getAtomCached("WM_PROTOCOLS") catch 0,
        xcb.XCB_ATOM_ATOM, 0, 256,
    );
    const c_hints = xcb.xcb_get_property(
        wm.conn, 0, win, xcb.XCB_ATOM_WM_HINTS, xcb.XCB_ATOM_WM_HINTS, 0, 9,
    );
    // WM_NORMAL_HINTS: used to clamp tiled geometry to the window's declared
    // minimum size.  Fired here with the other cookies — no extra round-trip.
    const c_normal_hints = xcb.xcb_get_property(
        wm.conn, 0, win,
        xcb.XCB_ATOM_WM_NORMAL_HINTS, xcb.XCB_ATOM_ANY, 0, 18,
    );
    // _NET_WM_PID: only queried when there are pending spawn entries, so the
    // extra round-trip is paid only when we have a reason to use the result.
    const has_pending_spawns = wm.spawn_queue.len > 0;
    const c_net_wm_pid = if (has_pending_spawns) xcb.xcb_get_property(
        wm.conn, 0, win,
        utils.getAtomCached("_NET_WM_PID") catch 0,
        xcb.XCB_ATOM_CARDINAL, 0, 1,
    ) else undefined;

    const target_ws            = resolveTargetWorkspace(wm, win, current_ws, c_net_wm_pid, has_pending_spawns);
    const on_current_workspace = (target_ws == current_ws);

    // Assign the window to its target workspace.  Pure bookkeeping — no XCB calls.
    workspaces.moveWindowTo(wm, win, target_ws) catch |err| {
        debug.logError(err, win);
        utils.flush(wm.conn);
        return;
    };

    // Cache WM_NORMAL_HINTS before any retile so configureSafe can clamp
    // geometry immediately, regardless of which workspace the window lands on.
    collectAndCacheSizeHints(wm, win, c_normal_hints);

    if (on_current_workspace) {
        // Queue the tiled geometry configure BEFORE the map command.  XCB
        // guarantees in-order processing within a connection, so the server
        // applies the geometry first — the window appears at its correct
        // tiled position with no intermediate geometry flash.
        registerWithTiling(wm, win, true);
        _ = xcb.xcb_map_window(wm.conn, win);
    } else {
        // Window belongs to a different workspace — do not map it yet.
        // executeSwitch() maps it inside a server grab when its workspace is
        // activated, so the compositor never allocates a buffer for it early.
        //
        // We MUST still register it with the tiling system (addWindow), even
        // though it won't be retiled now.  Without this:
        //   - s.windows never contains the window, so filterWorkspaceWindows
        //     skips it on every subsequent retileCurrentWorkspace call.
        //   - No border width or colour is ever set on it.
        //   - On the first visit the window appears at server-default geometry
        //     with no border; after the first hide-to-offscreen in executeSwitch
        //     step 1 it is stranded off-screen permanently.
        registerWithTiling(wm, win, false);
        grabButtons(wm, win, false);
    }

    // Single flush covers: change_window_attributes + focus cookies +
    // (for on_current_workspace) all configure_window calls + map_window.
    utils.flush(wm.conn);

    // Collect focus property replies fired at the start of handleMapRequest.
    utils.populateFocusCacheFromCookies(wm.conn, win, c_protocols, c_hints);

    if (on_current_workspace) {
        focus.setFocus(wm, win, .window_spawn);

        // Snapshot cursor so crossing events at the same position are
        // suppressed (layout shifted under a stationary cursor, not user move).
        snapshotSpawnCursor(wm);
    }

    bar.markDirty();
}

// Unmap / destroy

fn unmanageWindow(wm: *WM, win: u32) void {
    // Single map lookup: covers both the "is fullscreen?" check and retrieves
    // the workspace ID for removeForWorkspace.  Avoids the double-lookup that
    // isFullscreen (contains) + window_to_workspace.get would otherwise cause.
    // Must clear fullscreen state BEFORE the grab so setBarState (called inside
    // the grab) doesn't see the workspace as still-fullscreen and bail early.
    const was_fullscreen = if (wm.fullscreen.window_to_workspace.get(win)) |ws| blk: {
        wm.fullscreen.removeForWorkspace(ws);
        break :blk true;
    } else false;

    const was_focused = (wm.focused_window == win);

    // Capture the window's workspace and the current workspace BEFORE removing
    // the window from tracking — workspaces.removeWindow (below) drops it from
    // window_to_workspace, so getWorkspaceForWindow would return null afterward.
    const window_workspace = workspaces.getWorkspaceForWindow(win);
    const current_ws       = workspaces.getCurrentWorkspace();

    // Update all bookkeeping state before the grab — no XCB calls here.
    if (wm.config.tiling.enabled) tiling.removeWindow(win);
    utils.uncacheWindowFocusProps(win);
    layouts.evictSizeHints(win);
    minimize.forceUntrack(wm, win);
    workspaces.removeWindow(win);

    // Wrap all visual changes in a single server grab so picom never composites
    // an intermediate state where the destroyed window's slot is empty but the
    // remaining windows have not yet been repositioned, or where the bar has
    // reappeared but the layout still reflects the old (fullscreen) geometry.
    _ = xcb.xcb_grab_server(wm.conn);

    if (was_fullscreen) {
        // setBarState(.show_fullscreen) restores bar visibility and retiles.
        bar.setBarState(wm, .show_fullscreen);
    }

    if (was_focused) {
        // retileIfDirty is a no-op when was_fullscreen (setBarState already
        // retiled and cleared the dirty flag).
        if (wm.config.tiling.enabled) tiling.retileIfDirty(wm);
        focus.clearFocus(wm);
        // Round-trips from our own connection are safe inside a server grab.
        focusWindowUnderPointer(wm);
    } else if (!was_fullscreen and wm.config.tiling.enabled) {
        // The window was not focused, so the was_focused branch did not retile.
        if (window_workspace) |ws| {
            if (current_ws == ws) {
                // Killed on the current workspace but not the focused window.
                tiling.retileIfDirty(wm);
            } else {
                // Killed on an inactive workspace — pre-compute correct geometry
                // so restoreWorkspaceGeom succeeds at switch time without a flash.
                tiling.retileInactiveWorkspace(wm, ws);
            }
        }
    }

    // Redraw the bar inside the grab so the updated title and focus state are
    // composited atomically with the window removal and layout change.
    bar.redrawImmediate(wm);
    _ = xcb.xcb_ungrab_server(wm.conn);
    utils.flush(wm.conn);
}

// handleUnmapNotify and handleDestroyNotify share identical logic: validate
// then unmanage.  A single private function avoids duplicating the guard.
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

fn focusWindowUnderPointer(wm: *WM) void {
    const reply = xcb.xcb_query_pointer_reply(
        wm.conn, xcb.xcb_query_pointer(wm.conn, wm.root), null,
    ) orelse {
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

// Geometry-only bits from xcb_config_window_t.  Sibling (0x020) and
// StackMode (0x040) are intentionally excluded: passing them would cause XCB
// to read past our fixed-size values array if a client sets those bits.
const GEOMETRY_MASK: u16 =
    xcb.XCB_CONFIG_WINDOW_X | xcb.XCB_CONFIG_WINDOW_Y |
    xcb.XCB_CONFIG_WINDOW_WIDTH | xcb.XCB_CONFIG_WINDOW_HEIGHT |
    xcb.XCB_CONFIG_WINDOW_BORDER_WIDTH;

/// Send a synthetic ConfigureNotify to `win` reporting its current geometry.
/// Required by ICCCM §4.1.5 whenever a WM silently ignores a ConfigureRequest.
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
    // Tiled windows always have a cache entry written by the last retile.
    // Fullscreen windows are never in the geom cache, so they fall through to
    // the live get_geometry query below (one blocking round-trip, rare).
    if (tiling.getCachedGeom(win)) |rect| {
        const border: u16 = if (tiling.getState()) |s| s.border_width else 0;
        sendConfigureNotify(wm, win, rect.x, rect.y, rect.width, rect.height, border);
        return;
    }

    // Slow path: fullscreen windows (or a cache miss on a newly-tiled window
    // before the first retile).  One blocking round-trip.
    const reply = xcb.xcb_get_geometry_reply(
        wm.conn, xcb.xcb_get_geometry(wm.conn, win), null,
    ) orelse return;
    defer std.c.free(reply);
    // No flush here — the caller (event loop) flushes after each event batch.
    sendConfigureNotify(wm, win, reply.*.x, reply.*.y, reply.*.width, reply.*.height, reply.*.border_width);
}

pub fn handleConfigureRequest(event: *const xcb.xcb_configure_request_event_t, wm: *WM) void {
    const win = event.window;
    if ((wm.config.tiling.enabled and tiling.isWindowTiled(win)) or
        wm.fullscreen.isFullscreen(win))
    {
        // ICCCM §4.1.5: when a WM ignores a ConfigureRequest it must send the
        // client a synthetic ConfigureNotify with the window's actual current
        // geometry.  Without this, clients that block on ConfigureNotify to
        // finish initialising (most terminals) stall indefinitely — visible as
        // a frozen window that only wakes up when a subsequent retile happens
        // to send a real configure_window for unrelated reasons.
        sendSyntheticConfigureNotify(wm, win);
        return;
    }

    // Honour only the geometry bits we provide values for.
    const mask = event.value_mask & GEOMETRY_MASK;
    if (mask == 0) return;

    // XCB reads values in bit-order: for each set bit in mask (lowest first)
    // it consumes values[0], values[1], etc.  Build the array in the same
    // order so that e.g. a WIDTH|HEIGHT-only request doesn't read event.x
    // into the width slot.
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

/// Returns true and suppresses the crossing event if it is a retile
/// side-effect rather than genuine cursor movement.  When a window spawns we
/// snapshot the cursor position; any crossing event at those same coordinates
/// was generated by the layout shifting under a stationary cursor, not by the
/// user.  The first event at a different position lifts suppression so that
/// genuine movement is never lost, regardless of how many spurious events the
/// X server emits before then.
inline fn suppressSpawnCrossing(wm: *WM, root_x: i16, root_y: i16) bool {
    if (wm.suppress_focus_reason != .window_spawn) return false;
    if (root_x == wm.spawn_cursor_x and root_y == wm.spawn_cursor_y) return true;
    wm.suppress_focus_reason = .none;
    return false;
}

pub fn handleEnterNotify(event: *const xcb.xcb_enter_notify_event_t, wm: *WM) void {
    wm.last_event_time = event.time;
    // Filter GRAB/UNGRAB crossings (passive grab activate/deactivate).
    // WHILE_GRABBED must pass through — it fires during active grabs from
    // other clients (GTK, Qt) and represents genuine pointer movement.
    if (event.mode == xcb.XCB_NOTIFY_MODE_GRAB or
        event.mode == xcb.XCB_NOTIFY_MODE_UNGRAB) return;
    if (wm.drag_state.active) return;
    if (suppressSpawnCrossing(wm, event.root_x, event.root_y)) return;

    // Prefer the child (a direct root-child) over the event window.  If child
    // is 0, win becomes event; isOnCurrentWorkspace rejects root and unmanaged
    // windows, so no additional null/root guard is needed here.
    const win = if (event.event == wm.root and event.child != 0) event.child else event.event;

    if (!isOnCurrentWorkspace(wm, win)) return;
    if (minimize.isMinimized(wm, win)) return;
    if (wm.focused_window == win) return;

    focus.setFocus(wm, win, .mouse_enter);
}

/// Root's LeaveNotify fires the instant the pointer enters any child window,
/// including Electron/Chromium which generates no EnterNotify events visible
/// to root.  This gives us event-driven focus at the same latency as
/// handleEnterNotify for all other windows.
pub fn handleLeaveNotify(event: *const xcb.xcb_leave_notify_event_t, wm: *WM) void {
    wm.last_event_time = event.time;
    if (event.event != wm.root) return;
    if (event.mode != xcb.XCB_NOTIFY_MODE_NORMAL) return;
    if (wm.drag_state.active) return;
    if (suppressSpawnCrossing(wm, event.root_x, event.root_y)) return;

    // event.child is the direct child of root being entered.  Fall back to a
    // pointer query only when child is unset (rare: pointer moved to root bg).
    const target: u32 = if (event.child != 0) event.child else blk: {
        const reply = xcb.xcb_query_pointer_reply(
            wm.conn, xcb.xcb_query_pointer(wm.conn, wm.root), null,
        ) orelse return;
        defer std.c.free(reply);
        break :blk reply.*.child;
    };

    // isOnCurrentWorkspace covers target==0 and target==wm.root implicitly.
    if (!isOnCurrentWorkspace(wm, target)) return;
    if (minimize.isMinimized(wm, target)) return;
    if (wm.focused_window == target) return;

    focus.setFocus(wm, target, .mouse_enter);
}

// Property notify

/// Keep the focus-property cache coherent when relevant window properties change.
/// WM_PROTOCOLS: Electron sets WM_TAKE_FOCUS after mapping, so a cached false
///               would make us treat it as passive.  Recompute on any change.
/// WM_HINTS:     The input field is stable in practice, but some apps update it.
///               Recomputing is cheap — one property round-trip, done rarely.
pub fn handlePropertyNotify(event: *const xcb.xcb_property_notify_event_t, wm: *WM) void {
    if (!isValidManagedWindow(wm, event.window)) return;
    const wm_protocols = utils.getAtomCached("WM_PROTOCOLS") catch return;
    if (event.atom == wm_protocols or event.atom == xcb.XCB_ATOM_WM_HINTS) {
        utils.recacheInputModel(wm.conn, event.window);
    }
}

// Size-hint parsing

/// Clamp a u32 field value to u16 range. Used when parsing XSizeHints.
inline fn clampU16(v: u32) u16 {
    return @intCast(@min(v, std.math.maxInt(u16)));
}

/// Parse a WM_NORMAL_HINTS reply and populate the layouts size-hints cache.
/// XSizeHints wire layout (each field is one 32-bit CARD32):
///   [0]       flags
///   [1..4]    x, y, width, height  (deprecated USPosition/USSize — ignored)
///   [5..6]    min_width, min_height          (PMinSize  = 0x010)
///   [7..8]    max_width, max_height          (PMaxSize  = 0x020)
///   [9..10]   width_inc, height_inc          (PResizeInc = 0x040)
///   [11..14]  min/max aspect numerator/denom (PAspect  = 0x080)
///   [15..16]  base_width, base_height        (PBaseSize = 0x100)
///   [17]      win_gravity                    (PWinGravity = 0x200)
///
/// We cache min_width / min_height (and base_* as a fallback lower bound)
/// so that configureSafe can clamp tiled rects to the window's minimums.
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
    // PBaseSize gives the zero-increment base; use it as an additional lower
    // bound — some apps set base > min for character-cell sizing reasons.
    if (flags & XSIZE_HINTS_P_BASE_SIZE != 0 and field_count >= 17) {
        const base_width  = clampU16(fields[15]);
        const base_height = clampU16(fields[16]);
        if (base_width  > 0) min_width  = @max(min_width,  base_width);
        if (base_height > 0) min_height = @max(min_height, base_height);
    }

    layouts.cacheSizeHints(wm.allocator, win, .{ .min_width = min_width, .min_height = min_height });
}
