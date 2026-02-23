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


// Button grabs 

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

fn validateWorkspace(target: u8, current: u8) u8 {
    const s = workspaces.getState() orelse return current;
    return if (target < s.workspaces.len) target else current;
}

/// Collect a pre-fired WM_CLASS property cookie and match it against workspace
/// rules.  Parses instance/class directly from the reply buffer — no allocation.
/// Returns the target workspace index, or null if no rule matched or no reply.
fn collectWorkspaceRule(wm: *WM, cookie: xcb.xcb_get_property_cookie_t) ?u8 {
    const reply = xcb.xcb_get_property_reply(wm.conn, cookie, null) orelse return null;
    defer std.c.free(reply);
    if (reply.*.format != 8 or reply.*.value_len == 0) return null;

    const data: [*]const u8 = @ptrCast(xcb.xcb_get_property_value(reply));
    // Strip trailing null bytes that some clients include in value_len.
    var len: usize = @intCast(reply.*.value_len);
    while (len > 0 and data[len - 1] == 0) len -= 1;

    const sep = std.mem.indexOfScalar(u8, data[0..len], 0) orelse return null;
    const class_start = sep + 1;
    if (class_start >= len) return null;

    const instance = data[0..sep];
    const class    = data[class_start..len];

    for (wm.config.workspaces.rules.items) |rule| {
        if (std.mem.eql(u8, rule.class_name, class) or
            std.mem.eql(u8, rule.class_name, instance))
        {
            return rule.workspace;
        }
    }
    return null;
}

// Setup helper

inline fn setupTiling(wm: *WM, win: u32, on_current: bool) void {
    if (!wm.config.tiling.enabled) return;
    tiling.addWindow(wm, win);
    if (on_current) tiling.retileCurrentWorkspace(wm);
}

// Spawn workspace recovery 

// Spawn workspace queue
//
// When the user presses an exec keybind, input.executeShellCommand calls
// registerSpawn() with the active workspace before forking.  handleMapRequest
// pops the oldest non-expired entry and uses it as the workspace assignment.
//
// This replaces the _NET_WM_PID + /proc/pid/environ approach, which fails for
// daemon-mode terminals (kitty, wezterm, foot --server): those terminals
// re-use a long-lived daemon process whose /proc/pid/environ still reflects
// the workspace that was active when the daemon was first started, not now.
// The queue is purely in-process — no X round-trips, no filesystem reads.

const SPAWN_QUEUE_CAP: u8 = 16;

const SpawnEntry = struct {
    workspace: u8,
    /// PID written into _NET_WM_PID by the grandchild process.  Used for
    /// direct matching so the window is assigned to the right workspace even
    /// when the program takes arbitrarily long to start.  Set to 0 for
    /// daemon-mode terminals (kitty --single-instance, wezterm server, foot
    /// --server): their client process exits before the window maps, so no PID
    /// match is possible; those entries fall back to the FIFO path instead.
    pid: u32,
};

var spawn_buf:  [SPAWN_QUEUE_CAP]SpawnEntry = undefined;
var spawn_head: u8 = 0;
var spawn_len:  u8 = 0;

/// Called by input.executeShellCommand after a confirmed successful exec.
/// `pid` is the grandchild PID forwarded via pipe; it is 0 for daemon-mode
/// terminals whose client process exited before we could verify exec success.
pub fn registerSpawn(workspace: u8, pid: u32) void {
    const tail = (spawn_head + spawn_len) % SPAWN_QUEUE_CAP;
    spawn_buf[tail] = .{ .workspace = workspace, .pid = pid };
    if (spawn_len < SPAWN_QUEUE_CAP) {
        spawn_len += 1;
    } else {
        // Queue full — silently discard oldest entry.
        spawn_head = (spawn_head + 1) % SPAWN_QUEUE_CAP;
    }
}

/// Search for an entry whose PID matches `win_pid` (from _NET_WM_PID).
/// On a hit the entry is removed and its workspace returned.  On a miss
/// returns null — the caller should fall back to popSpawnFifo().
fn popSpawnByPid(win_pid: u32) ?u8 {
    if (win_pid == 0) return null;
    var i: u8 = 0;
    while (i < spawn_len) : (i += 1) {
        const idx = (spawn_head + i) % SPAWN_QUEUE_CAP;
        if (spawn_buf[idx].pid != win_pid) continue;
        const ws = spawn_buf[idx].workspace;
        // Collapse the slot by shifting the tail of the logical queue down.
        var j: u8 = i;
        while (j + 1 < spawn_len) : (j += 1) {
            const cur  = (spawn_head + j)     % SPAWN_QUEUE_CAP;
            const next = (spawn_head + j + 1) % SPAWN_QUEUE_CAP;
            spawn_buf[cur] = spawn_buf[next];
        }
        spawn_len -= 1;
        return ws;
    }
    return null;
}

/// Pop the oldest entry unconditionally (FIFO, no expiry).
/// Used as a fallback for daemon-mode terminals whose grandchild exits before
/// the window maps, making PID matching impossible.  Entries only accumulate
/// here from confirmed successful execs, so there are no stale entries to
/// time out — the exec-pipe mechanism in executeShellCommand guarantees that
/// failed launches are discarded before registerSpawn is ever called.
fn popSpawnFifo() ?u8 {
    if (spawn_len == 0) return null;
    const ws = spawn_buf[spawn_head].workspace;
    spawn_head = (spawn_head + 1) % SPAWN_QUEUE_CAP;
    spawn_len -= 1;
    return ws;
}

// Map request 

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
    // minimum size.  Terminals set min_height = one character row; without this
    // clamp they can receive invalid geometry.  Fired here with the other
    // cookies — no extra round-trip cost.
    const c_normal_hints = xcb.xcb_get_property(
        wm.conn, 0, win,
        xcb.XCB_ATOM_WM_NORMAL_HINTS, xcb.XCB_ATOM_ANY, 0, 18,
    );
    // _NET_WM_PID: only queried when there are pending spawn entries, so the
    // extra round-trip is paid only when we have a reason to use the result.
    // The cookie is pipelined with the others above — no extra flush needed.
    const has_pending_spawns = spawn_len > 0;
    const c_net_wm_pid = if (has_pending_spawns) xcb.xcb_get_property(
        wm.conn, 0, win,
        utils.getAtomCached("_NET_WM_PID") catch 0,
        xcb.XCB_ATOM_CARDINAL, 0, 1,
    ) else undefined;

    // Determine target workspace.
    // Priority: workspace rules > exec spawn workspace > current workspace.
    //
    // Workspace rules (WM_CLASS): one round-trip; xcb_get_property_reply
    //   flushes the output buffer implicitly, so all cookies above also land.
    // Spawn workspace: two-phase lookup —
    //   Phase 1 (PID match): compare _NET_WM_PID against stored grandchild
    //     PIDs.  Works for any program regardless of startup time — no expiry.
    //   Phase 2 (FIFO fallback): for daemon-mode terminals (kitty, wezterm,
    //     foot --server) whose client process exits before the window maps,
    //     making PID matching impossible.  Entries are guaranteed stale-free
    //     because executeShellCommand only calls registerSpawn() after the
    //     exec-pipe confirms the grandchild exec'd successfully; exec failures
    //     are discarded there and never enter the queue.
    // Current workspace: zero round-trips (fast path for unmanaged windows).
    const validated_ws: u8 = blk: {
        // 1. Workspace rules — explicit class-based assignment, highest priority.
        if (wm.config.workspaces.rules.items.len > 0) {
            const c_class = xcb.xcb_get_property(
                wm.conn, 0, win,
                utils.getAtomCached("WM_CLASS") catch 0,
                xcb.XCB_ATOM_STRING, 0, 256,
            );
            if (collectWorkspaceRule(wm, c_class)) |target| {
                // Discard the PID cookie so XCB does not see an uncollected reply.
                if (has_pending_spawns) xcb.xcb_discard_reply(wm.conn, c_net_wm_pid.sequence);
                break :blk validateWorkspace(target, current_ws);
            }
            // No rule matched; fall through and try the spawn workspace.
        }
        // 2. Exec spawn workspace.
        if (has_pending_spawns) {
            // Phase 1: direct PID match.
            const pid_reply = xcb.xcb_get_property_reply(wm.conn, c_net_wm_pid, null);
            if (pid_reply) |r| {
                defer std.c.free(r);
                if (r.*.format == 32 and r.*.value_len >= 1) {
                    const win_pid = @as([*]const u32, @ptrCast(@alignCast(xcb.xcb_get_property_value(r))))[0];
                    if (popSpawnByPid(win_pid)) |spawn_ws|
                        break :blk validateWorkspace(spawn_ws, current_ws);
                }
            }
            // Phase 2: FIFO fallback for daemon-mode terminals.
            if (popSpawnFifo()) |spawn_ws|
                break :blk validateWorkspace(spawn_ws, current_ws);
        }
        // 3. Default: whichever workspace is active at map time.
        break :blk current_ws;
    };
    const is_current = (validated_ws == current_ws);

    // All local state — no X11 round-trips.
    workspaces.moveWindowTo(wm, win, validated_ws) catch |err| {
        debug.logError(err, win);
        utils.flush(wm.conn);
        return;
    };

    // Cache WM_NORMAL_HINTS before any retile so configureSafe can clamp
    // geometry immediately, regardless of which workspace the window lands on.
    collectAndCacheSizeHints(wm, win, c_normal_hints);

    if (is_current) {
        // Freeze the compositor for the duration of retile + map so picom never
        // composites a frame where the existing windows have been repositioned
        // but the new window has not yet appeared (or vice-versa).
        _ = xcb.xcb_grab_server(wm.conn);
        setupTiling(wm, win, true);
        _ = xcb.xcb_map_window(wm.conn, win);
        _ = xcb.xcb_ungrab_server(wm.conn);
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
        //
        // setupTiling with on_current=false calls addWindow (registering the
        // window in s.windows, setting its border, marking dirty) but does NOT
        // call retileCurrentWorkspace — the current workspace is unaffected.
        setupTiling(wm, win, false);
        grabButtons(wm, win, false);

        // Pre-compute the correct tiled geometry for the inactive workspace now,
        // so that restoreWorkspaceGeom can take its fast path when the user
        // switches to it — no mid-switch layout run, no flash.
        //
        // This mirrors the inactive-workspace kill fix in unmanageWindow: addWindow
        // set s.dirty, which would cause restoreWorkspaceGeom to fall back to a
        // full retile at switch time.  Calling retileInactiveWorkspace inside a
        // grab here clears dirty and populates the geom cache with the correct
        // positions (including the new window), then pushes them back offscreen.
        if (wm.config.tiling.enabled) {
            _ = xcb.xcb_grab_server(wm.conn);
            tiling.retileInactiveWorkspace(wm, validated_ws);
            _ = xcb.xcb_ungrab_server(wm.conn);
        }
    }

    // Single flush delivers the entire batch: change_window_attributes, focus
    // cookies, and for is_current: grab + retile + map + ungrab — all in one
    // syscall.  For the inactive path: border set + retileInactiveWorkspace.
    utils.flush(wm.conn);

    // Collect focus property replies.  On the no-rules path these were
    // fired before any blocking and the flush just pushed them to the
    // server; replies are typically already in the socket read buffer.
    // On the rules path the WM_CLASS blocking step also flushed them.
    utils.populateFocusCacheFromCookies(wm.conn, win, c_protocols, c_hints);

    if (is_current) {
        // Second grab: focus the new window and redraw the bar atomically so
        // picom never composites a frame where the window is mapped and tiled
        // but the bar still shows the old focused title and workspace state.
        // The focus property cookies were collected above (round-trips done),
        // so setFocus has everything it needs without any further blocking.
        _ = xcb.xcb_grab_server(wm.conn);
        focus.setFocus(wm, win, .window_spawn);
        bar.redrawImmediate(wm);
        _ = xcb.xcb_ungrab_server(wm.conn);
        utils.flush(wm.conn);

        // The flush above has delivered all configure_window calls to the X
        // server, so its hit-testing reflects the post-retile layout.
        // Record where the cursor is the moment the window spawns so that
        // handleEnterNotify / handleLeaveNotify can distinguish retile-induced
        // crossings (cursor stationary, layout shifted under it) from genuine
        // movement and suppress only the former.
        if (wm.suppress_focus_reason == .window_spawn) {
            const ptr_cookie = xcb.xcb_query_pointer(wm.conn, wm.root);
            if (xcb.xcb_query_pointer_reply(wm.conn, ptr_cookie, null)) |ptr| {
                defer std.c.free(ptr);
                wm.spawn_cursor_x = ptr.*.root_x;
                wm.spawn_cursor_y = ptr.*.root_y;
            }
        }
    } else {
        bar.markDirty();
    }
}

// Configure request 

/// Send a synthetic ConfigureNotify to `win` reporting its current geometry.
/// Required by ICCCM §4.1.5 whenever a WM silently ignores a ConfigureRequest:
/// the client must be told what geometry it actually has, or it may block
/// waiting for an acknowledgement that never arrives.
fn sendConfigureNotify(wm: *WM, win: u32, x: i16, y: i16, w: u16, h: u16, border: u16) void {
    const ev = xcb.xcb_configure_notify_event_t{
        .response_type     = xcb.XCB_CONFIGURE_NOTIFY,
        .pad0              = 0,
        .sequence          = 0,
        .event             = win,
        .window            = win,
        .above_sibling     = xcb.XCB_NONE,
        .x                 = x,
        .y                 = y,
        .width             = w,
        .height            = h,
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

    // Honour only the geometry bits we provide values for.  Passing the raw
    // value_mask unmodified would cause XCB to read past our value array if
    // the client also sets Sibling (0x020) or StackMode (0x040).
    const GEOMETRY_MASK: u16 =
        xcb.XCB_CONFIG_WINDOW_X | xcb.XCB_CONFIG_WINDOW_Y |
        xcb.XCB_CONFIG_WINDOW_WIDTH | xcb.XCB_CONFIG_WINDOW_HEIGHT |
        xcb.XCB_CONFIG_WINDOW_BORDER_WIDTH;
    const mask = event.value_mask & GEOMETRY_MASK;
    if (mask == 0) return;

    // XCB reads values in bit-order: for each set bit in mask (lowest first)
    // it consumes values[0], values[1], etc.  Providing all 5 values regardless
    // of which bits are set is wrong — e.g. if only WIDTH|HEIGHT are requested,
    // XCB reads values[0] for width, but we would have stored event.x there.
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

// Focus events 

pub fn handleEnterNotify(event: *const xcb.xcb_enter_notify_event_t, wm: *WM) void {
    wm.last_event_time = event.time;
    // Filter GRAB/UNGRAB crossings (passive grab activate/deactivate).
    // WHILE_GRABBED must pass through — it fires during active grabs from
    // other clients (GTK, Qt) and represents genuine pointer movement.
    if (event.mode == xcb.XCB_NOTIFY_MODE_GRAB or
        event.mode == xcb.XCB_NOTIFY_MODE_UNGRAB) return;
    if (wm.drag_state.active) return;
    // Suppress crossing events that are retile side-effects rather than genuine
    // cursor movement.  When a new window spawns we record the cursor position;
    // any EnterNotify whose root coordinates still match means the pointer has
    // not moved — the X server generated the event because the layout shifted
    // under a stationary cursor.  The first event with different coordinates
    // signals real movement and lifts the suppression unconditionally.
    // This is strictly stronger than the old counter approach: it absorbs any
    // number of spurious events with no timing dependency, so it works correctly
    // on slow hardware that generates more crossing events than the counter could
    // anticipate.
    if (wm.suppress_focus_reason == .window_spawn) {
        if (event.root_x == wm.spawn_cursor_x and event.root_y == wm.spawn_cursor_y) {
            return; // cursor hasn't moved — suppress this retile-induced crossing
        }
        // Cursor moved: genuine user intent, lift suppression and fall through.
        wm.suppress_focus_reason = .none;
    }

    const win = if (event.event == wm.root and event.child != 0)
        event.child
    else
        event.event;

    if (!isOnCurrentWorkspace(wm, win)) return;
    if (minimize.isMinimized(win)) return;
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
    // Same position-based suppression as handleEnterNotify — see comment there.
    // A retile after spawn can push a window under the stationary cursor, which
    // generates a LeaveNotify on root.  If the cursor coordinates in the event
    // still match the position recorded at spawn time the pointer has not moved,
    // so this event is spurious and is silently dropped.
    if (wm.suppress_focus_reason == .window_spawn) {
        if (event.root_x == wm.spawn_cursor_x and event.root_y == wm.spawn_cursor_y) {
            return;
        }
        wm.suppress_focus_reason = .none;
    }

    // event.child is the direct child of root being entered.
    const target: u32 = if (event.child != 0) event.child else blk: {
        const reply = xcb.xcb_query_pointer_reply(
            wm.conn, xcb.xcb_query_pointer(wm.conn, wm.root), null,
        ) orelse return;
        defer std.c.free(reply);
        break :blk reply.*.child;
    };
    if (target == 0 or target == wm.root) return;

    if (!isOnCurrentWorkspace(wm, target)) return;
    if (minimize.isMinimized(target)) return;
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
    if (workspaces.getWorkspaceForWindow(event.window) == null) return;
    const wm_protocols = utils.getAtomCached("WM_PROTOCOLS") catch return;
    if (event.atom == wm_protocols or event.atom == xcb.XCB_ATOM_WM_HINTS) {
        utils.recacheInputModel(wm.conn, event.window);
    }
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
    const win_ws     = workspaces.getWorkspaceForWindow(win);
    const current_ws = workspaces.getCurrentWorkspace();

    // Update all bookkeeping state before the grab — no XCB calls here.
    if (wm.config.tiling.enabled) tiling.removeWindow(win);
    utils.uncacheWindowFocusProps(win);
    layouts.evictSizeHints(win);
    workspaces.removeWindow(win);

    // Wrap all visual changes in a single server grab so picom never composites
    // an intermediate state where the destroyed window's slot is empty but the
    // remaining windows have not yet been repositioned, or where the bar has
    // reappeared but the layout still reflects the old (fullscreen) geometry.
    _ = xcb.xcb_grab_server(wm.conn);

    if (was_fullscreen) {
        // setBarState(.show_fullscreen) restores bar visibility and retiles.
        // Its internal flush is harmless — picom is frozen during our grab.
        bar.setBarState(wm, .show_fullscreen);
    }

    if (was_focused) {
        // retileIfDirty is a no-op when was_fullscreen (setBarState already
        // retiled and cleared the dirty flag).  For non-fullscreen focused
        // windows, removeWindow set dirty and this call retiles the workspace.
        if (wm.config.tiling.enabled) tiling.retileIfDirty(wm);
        focus.clearFocus(wm);
        // focusWindowUnderPointer does a round-trip (xcb_query_pointer).
        // Round-trips from our own connection are safe inside a server grab —
        // the server responds normally; only other connections are frozen.
        focusWindowUnderPointer(wm);
    } else if (!was_fullscreen and wm.config.tiling.enabled) {
        // The window was not focused, so the was_focused branch did not retile.
        // Determine whether it was on the current workspace or a different one
        // and retile accordingly so the layout is correct immediately.
        if (win_ws) |ws| {
            const cur = current_ws orelse std.math.maxInt(u8);
            if (ws == cur) {
                // Killed on the current workspace but was not the focused window
                // (e.g. there are 3 windows and a non-focused one is pkilled).
                // Retile inside the grab for atomicity.
                tiling.retileIfDirty(wm);
            } else {
                // Killed on an inactive workspace.  Pre-compute the correct
                // geometry for that workspace now so that restoreWorkspaceGeom
                // succeeds at switch time without running the layout algorithm
                // mid-switch — preventing the flash the deferred retile causes.
                tiling.retileInactiveWorkspace(wm, ws);
            }
        }
    }

    // Redraw the bar inside the grab so the updated title and focus state are
    // composited atomically with the window removal and layout change.  The bar
    // is redrawn whether or not the window was focused: the workspace indicator
    // and window count change regardless.
    bar.redrawImmediate(wm);
    _ = xcb.xcb_ungrab_server(wm.conn);
    utils.flush(wm.conn);
}

pub fn handleUnmapNotify(event: *const xcb.xcb_unmap_notify_event_t, wm: *WM) void {
    const win = event.window;
    if (bar.isBarWindow(win) or workspaces.getWorkspaceForWindow(win) == null) return;
    unmanageWindow(wm, win);
}

pub fn handleDestroyNotify(event: *const xcb.xcb_destroy_notify_event_t, wm: *WM) void {
    const win = event.window;
    if (bar.isBarWindow(win) or workspaces.getWorkspaceForWindow(win) == null) return;
    unmanageWindow(wm, win);
}

// Post-unmanage focus recovery 

fn focusWindowUnderPointer(wm: *WM) void {
    const reply = xcb.xcb_query_pointer_reply(
        wm.conn, xcb.xcb_query_pointer(wm.conn, wm.root), null,
    ) orelse { minimize.focusBestAvailable(wm); return; };
    defer std.c.free(reply);

    const child = reply.*.child;
    if (isOnCurrentWorkspace(wm, child) and !minimize.isMinimized(child)) {
        focus.setFocus(wm, child, .mouse_enter);
        return;
    }
    minimize.focusBestAvailable(wm);
}


// WM_NORMAL_HINTS 

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

    const vals: [*]const u32 = @ptrCast(@alignCast(xcb.xcb_get_property_value(reply)));
    const len   = reply.*.value_len;
    const flags = vals[0];

    const P_MIN_SIZE:  u32 = 0x10;
    const P_BASE_SIZE: u32 = 0x100;

    var min_w: u16 = 0;
    var min_h: u16 = 0;

    if (flags & P_MIN_SIZE != 0 and len >= 7) {
        min_w = @intCast(@min(vals[5], std.math.maxInt(u16)));
        min_h = @intCast(@min(vals[6], std.math.maxInt(u16)));
    }
    // PBaseSize gives the zero-increment base; use it as an additional lower
    // bound — some apps set base > min for character-cell sizing reasons.
    if (flags & P_BASE_SIZE != 0 and len >= 17) {
        const bw: u16 = @intCast(@min(vals[15], std.math.maxInt(u16)));
        const bh: u16 = @intCast(@min(vals[16], std.math.maxInt(u16)));
        if (bw > 0) min_w = @max(min_w, bw);
        if (bh > 0) min_h = @max(min_h, bh);
    }

    layouts.cacheSizeHints(wm.allocator, win, .{ .min_width = min_w, .min_height = min_h });
}
