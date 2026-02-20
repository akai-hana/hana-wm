// Window lifecycle — map/unmap/destroy, configure, enter/button events.

const std        = @import("std");
const defs       = @import("defs");
const xcb        = defs.xcb;
const WM         = defs.WM;
const utils      = @import("utils");
const constants  = @import("constants");
const filters    = @import("filters");
const focus      = @import("focus");
const tiling     = @import("tiling");
const bar        = @import("bar");
const workspaces = @import("workspaces");
const debug      = @import("debug");
const minimize   = @import("minimize");
const layouts    = @import("layouts");

const WINDOW_EVENT_MASK = constants.EventMasks.MANAGED_WINDOW;

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

fn validateWorkspace(target: ?u8, current: u8) u8 {
    const ws = target orelse return current;
    const s  = workspaces.getState() orelse return current;
    return if (ws < s.workspaces.len) ws else current;
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

const SPAWN_TIMEOUT_NS: u64 = 15 * std.time.ns_per_s;
const SPAWN_QUEUE_CAP:  u8  = 16;

const SpawnEntry = struct { workspace: u8, time: std.time.Instant };

var spawn_buf:  [SPAWN_QUEUE_CAP]SpawnEntry = undefined;
var spawn_head: u8 = 0;
var spawn_len:  u8 = 0;

/// Called by input.executeShellCommand immediately after a successful fork.
/// Records the workspace the user was on when they pressed the exec keybind.
pub fn registerSpawn(workspace: u8) void {
    const now = std.time.Instant.now() catch return;
    const tail = (spawn_head + spawn_len) % SPAWN_QUEUE_CAP;
    spawn_buf[tail] = .{ .workspace = workspace, .time = now };
    if (spawn_len < SPAWN_QUEUE_CAP) {
        spawn_len += 1;
    } else {
        // Queue full — silently discard oldest entry.
        spawn_head = (spawn_head + 1) % SPAWN_QUEUE_CAP;
    }
}

/// Pop the oldest non-expired entry.  Expired entries are silently discarded.
/// Returns null when the queue is empty or all entries have timed out.
fn popSpawnWorkspace() ?u8 {
    const now = std.time.Instant.now() catch return null;
    while (spawn_len > 0) {
        const entry = spawn_buf[spawn_head];
        spawn_head = (spawn_head + 1) % SPAWN_QUEUE_CAP;
        spawn_len -= 1;
        if (now.since(entry.time) <= SPAWN_TIMEOUT_NS) return entry.workspace;
        // Expired — discard and try the next entry.
    }
    return null;
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
    // Determine target workspace.
    // Priority: workspace rules > exec spawn workspace > current workspace.
    //
    // Workspace rules (WM_CLASS): one round-trip; xcb_get_property_reply
    //   flushes the output buffer implicitly, so all cookies above also land.
    // Spawn workspace (queue): zero round-trips — registerSpawn() was called
    //   at fork time; popSpawnWorkspace() is a pure in-process ring-buffer pop.
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
                break :blk validateWorkspace(target, current_ws);
            }
            // No rule matched; fall through and try the spawn workspace.
        }
        // 2. Exec spawn workspace — window was launched via a keybind exec action.
        //    executeShellCommand called registerSpawn() before forking, recording
        //    the active workspace in the spawn queue.  Pop the oldest non-expired
        //    entry so the window lands on the workspace where the bind was pressed,
        //    even when the terminal reuses a long-lived daemon process.
        if (popSpawnWorkspace()) |spawn_ws|
            break :blk validateWorkspace(spawn_ws, current_ws);
        // 3. Default: whichever workspace is active at map time.
        break :blk current_ws;
    };
    const is_current = (validated_ws == current_ws);

    // All local state — no X11 round-trips.
    wm.addWindow(win) catch |err| {
        debug.logError(err, win);
        utils.flush(wm.conn);
        return;
    };
    workspaces.moveWindowTo(wm, win, validated_ws);

    if (is_current) {
        // Queue the tiled geometry configure BEFORE the map command.  XCB
        // guarantees in-order processing within a connection, so the server
        // applies the geometry first — the window appears at its correct
        // tiled position with no intermediate geometry flash.
        //
        // Cache WM_NORMAL_HINTS before the first retile so configureSafe
        // can clamp the geometry immediately.
        collectAndCacheSizeHints(wm, win, c_normal_hints);
        setupTiling(wm, win, true);
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
        //
        // setupTiling with on_current=false calls addWindow (registering the
        // window in s.windows, setting its border, marking dirty) but does NOT
        // call retileCurrentWorkspace — the current workspace is unaffected.
        // Consume the WM_NORMAL_HINTS reply now so the reply queue stays
        // clean.  The hints are cached and will be used when this workspace
        // is first visited and retiled.
        collectAndCacheSizeHints(wm, win, c_normal_hints);
        setupTiling(wm, win, false);
        grabButtons(wm, win, false);
    }

    // Single flush covers: change_window_attributes + focus cookies +
    // (for is_current) all configure_window calls + map_window.
    utils.flush(wm.conn);

    // Collect focus property replies.  On the no-rules path these were
    // fired before any blocking and the flush just pushed them to the
    // server; replies are typically already in the socket read buffer.
    // On the rules path the WM_CLASS blocking step also flushed them.
    utils.populateFocusCacheFromCookies(wm.conn, win, c_protocols, c_hints);

    if (is_current) {
        focus.setFocus(wm, win, .window_spawn);

        // The flush above has already delivered all configure_window calls to
        // the X server, so its hit-testing reflects the post-retile layout.
        // If the cursor is now inside a tiled window (child != 0) it means it
        // was previously sitting in a gap that the retile just covered.  The
        // X server will fire two crossing events — LeaveNotify on root and
        // EnterNotify on the newly covering window — both of which would
        // otherwise steal focus away from the just-spawned window.  Bump the
        // suppression counter so both are absorbed rather than just the first.
        // Record where the cursor is the moment the window spawns.
        // handleEnterNotify / handleLeaveNotify compare incoming events against
        // this position: events with matching coords are retile side-effects
        // (the window layout shifted under a stationary cursor) and are silently
        // dropped.  The first crossing event whose coords differ means the cursor
        // genuinely moved, so suppression lifts automatically — regardless of how
        // many spurious events the X server generates before then.
        if (wm.suppress_focus_reason == .window_spawn) {
            const ptr_cookie = xcb.xcb_query_pointer(wm.conn, wm.root);
            if (xcb.xcb_query_pointer_reply(wm.conn, ptr_cookie, null)) |ptr| {
                defer std.c.free(ptr);
                wm.spawn_cursor_x = ptr.*.root_x;
                wm.spawn_cursor_y = ptr.*.root_y;
            }
        }
    }

    bar.markDirty();
}

// Configure request 

/// Send a synthetic ConfigureNotify to `win` reporting its current geometry.
/// Required by ICCCM §4.1.5 whenever a WM silently ignores a ConfigureRequest:
/// the client must be told what geometry it actually has, or it may block
/// waiting for an acknowledgement that never arrives.
fn sendSyntheticConfigureNotify(wm: *WM, win: u32) void {
    // Fast path: serve the geometry from the tiling cache — zero round-trips.
    // Tiled windows always have a cache entry written by the last retile.
    // Fullscreen windows are never in the geom cache, so they fall through to
    // the live get_geometry query below (one blocking round-trip, rare).
    if (tiling.getCachedGeom(win)) |rect| {
        const border: u16 = if (tiling.getState()) |s| s.border_width else 0;
        const ev = xcb.xcb_configure_notify_event_t{
            .response_type     = xcb.XCB_CONFIGURE_NOTIFY,
            .pad0              = 0,
            .sequence          = 0,
            .event             = win,
            .window            = win,
            .above_sibling     = xcb.XCB_NONE,
            .x                 = rect.x,
            .y                 = rect.y,
            .width             = rect.width,
            .height            = rect.height,
            .border_width      = border,
            .override_redirect = 0,
            .pad1              = 0,
        };
        _ = xcb.xcb_send_event(
            wm.conn, 0, win,
            xcb.XCB_EVENT_MASK_STRUCTURE_NOTIFY,
            @ptrCast(&ev),
        );
        return;
    }

    // Slow path: fullscreen windows (or a cache miss on a newly-tiled window
    // before the first retile).  One blocking round-trip.
    const reply = xcb.xcb_get_geometry_reply(
        wm.conn, xcb.xcb_get_geometry(wm.conn, win), null,
    ) orelse return;
    defer std.c.free(reply);

    const ev = xcb.xcb_configure_notify_event_t{
        .response_type     = xcb.XCB_CONFIGURE_NOTIFY,
        .pad0              = 0,
        .sequence          = 0,
        .event             = win,
        .window            = win,
        .above_sibling     = xcb.XCB_NONE,
        .x                 = reply.*.x,
        .y                 = reply.*.y,
        .width             = reply.*.width,
        .height            = reply.*.height,
        .border_width      = reply.*.border_width,
        .override_redirect = 0,
        .pad1              = 0,
    };
    _ = xcb.xcb_send_event(
        wm.conn, 0, win,
        xcb.XCB_EVENT_MASK_STRUCTURE_NOTIFY,
        @ptrCast(&ev),
    );
    // No flush here — the caller (event loop) flushes after each event batch.
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

    if (!filters.isOnCurrentWorkspace(wm, win)) return;
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

    if (!filters.isOnCurrentWorkspace(wm, target)) return;
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
    if (!wm.hasWindow(event.window)) return;
    const wm_protocols = utils.getAtomCached("WM_PROTOCOLS") catch return;
    if (event.atom == wm_protocols or event.atom == xcb.XCB_ATOM_WM_HINTS) {
        utils.recacheInputModel(wm.conn, event.window);
    }
}

// Unmap / destroy 

fn unmanageWindow(wm: *WM, win: u32) void {
    const was_fullscreen = wm.fullscreen.isFullscreen(win);
    if (was_fullscreen) {
        // Clear fullscreen state BEFORE the grab so setBarState (called inside
        // the grab) doesn't see the workspace as still-fullscreen and bail.
        if (wm.fullscreen.window_to_workspace.get(win)) |ws| {
            wm.fullscreen.removeForWorkspace(ws);
        }
    }

    const was_focused = (wm.focused_window == win);

    // Update all bookkeeping state before the grab — no XCB calls here.
    if (wm.config.tiling.enabled) tiling.removeWindow(win);
    utils.uncacheWindowFocusProps(win);
    layouts.evictSizeHints(win);
    workspaces.removeWindow(win);
    wm.removeWindow(win);

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
    if (bar.isBarWindow(win) or !wm.hasWindow(win)) return;
    unmanageWindow(wm, win);
}

pub fn handleDestroyNotify(event: *const xcb.xcb_destroy_notify_event_t, wm: *WM) void {
    const win = event.window;
    if (bar.isBarWindow(win)) return;
    unmanageWindow(wm, win);
}

// Post-unmanage focus recovery 

fn focusWindowUnderPointer(wm: *WM) void {
    const reply = xcb.xcb_query_pointer_reply(
        wm.conn, xcb.xcb_query_pointer(wm.conn, wm.root), null,
    ) orelse { focusFallback(wm); return; };
    defer std.c.free(reply);

    const child = reply.*.child;
    if (filters.isOnCurrentWorkspace(wm, child) and !minimize.isMinimized(child)) {
        focus.setFocus(wm, child, .mouse_enter);
        return;
    }
    focusFallback(wm);
}

/// Focus the first visible, non-minimized window in the current workspace (last-resort fallback).
fn focusFallback(wm: *WM) void {
    const ws = workspaces.getCurrentWorkspaceObject() orelse return;
    for (ws.windows.items()) |win| {
        if (filters.isValidManagedWindow(wm, win) and !minimize.isMinimized(win)) {
            focus.setFocus(wm, win, .window_destroyed);
            return;
        }
    }
}

// WM_NORMAL_HINTS ─────────────────────────────────────────────────────────

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
