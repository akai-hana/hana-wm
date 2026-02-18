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

const WINDOW_EVENT_MASK = constants.EventMasks.MANAGED_WINDOW;

// Button grabs ─

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

// Workspace rule matching ──────────────────────────────────────────────────

fn matchWorkspaceRule(wm: *WM, win: u32) ?u8 {
    const rules = wm.config.workspaces.rules.items;
    if (rules.len == 0) return null;
    const wm_class = utils.getWMClass(wm.conn, win, wm.allocator) orelse return null;
    defer wm_class.deinit(wm.allocator);
    for (rules) |rule| {
        if (std.mem.eql(u8, rule.class_name, wm_class.class) or
            std.mem.eql(u8, rule.class_name, wm_class.instance))
        {
            return rule.workspace;
        }
    }
    return null;
}

fn validateWorkspace(target: ?u8, current: u8) u8 {
    const ws = target orelse return current;
    const s  = workspaces.getState() orelse return current;
    return if (ws < s.workspaces.len) ws else current;
}

// Setup helpers 

inline fn setupTiling(wm: *WM, win: u32, on_current: bool) void {
    if (!wm.config.tiling.enabled) return;
    tiling.addWindow(wm, win);
    if (on_current) tiling.retileCurrentWorkspace(wm, false);
}

inline fn setupWindow(wm: *WM, win: u32, workspace_index: u8) !void {
    _ = xcb.xcb_change_window_attributes(wm.conn, win, xcb.XCB_CW_EVENT_MASK, &[_]u32{WINDOW_EVENT_MASK});
    try wm.addWindow(win);
    workspaces.moveWindowTo(wm, win, workspace_index);
}

// Map request ──

pub fn handleMapRequest(event: *const xcb.xcb_map_request_event_t, wm: *WM) void {
    const win          = event.window;
    const current_ws   = workspaces.getCurrentWorkspace() orelse 0;
    const validated_ws = validateWorkspace(matchWorkspaceRule(wm, win), current_ws);
    const is_current   = (validated_ws == current_ws);

    setupWindow(wm, win, validated_ws) catch |err| { debug.logError(err, win); return; };

    // Only map immediately for the current workspace.  Windows on inactive
    // workspaces are left unmapped so the compositor never allocates a buffer
    // for off-screen content.  executeSwitch() maps them inside the server grab.
    if (is_current) _ = xcb.xcb_map_window(wm.conn, win);

    utils.cacheWMTakeFocus(wm.conn, win);
    setupTiling(wm, win, is_current);
    utils.flush(wm.conn);

    if (is_current) {
        focus.setFocus(wm, win, .window_spawn);
    } else {
        grabButtons(wm, win, false);
    }

    bar.markDirty();
}

// Configure request ────────────────────────────────────────────────────────

pub fn handleConfigureRequest(event: *const xcb.xcb_configure_request_event_t, wm: *WM) void {
    const win = event.window;
    // Tiled and fullscreen windows have their geometry managed by us — ignore.
    if ((wm.config.tiling.enabled and tiling.isWindowTiled(win)) or
        wm.fullscreen.isFullscreen(win)) return;

    _ = xcb.xcb_configure_window(wm.conn, win, event.value_mask, &[_]u32{
        @intCast(event.x), @intCast(event.y),
        @intCast(event.width), @intCast(event.height),
        @intCast(event.border_width),
    });
    utils.flush(wm.conn);
}

// Focus events ─

pub fn handleEnterNotify(event: *const xcb.xcb_enter_notify_event_t, wm: *WM) void {
    wm.last_event_time = event.time;

    // Ignore crossings caused by pointer grabs/ungrabs (e.g. during window drags).
    if (event.mode != xcb.XCB_NOTIFY_MODE_NORMAL) return;

    // Root receives a virtual EnterNotify (detail=NonlinearVirtual) whenever the
    // pointer moves to any direct child, regardless of that child's own event mask.
    // This is the only delivery path for apps like Electron/Chromium that call
    // XSelectInput after mapping to strip ENTER_WINDOW from our subscription.
    // For normal windows we receive both root's virtual event and the window's own
    // event; the focused_window equality check below deduplicates them.
    const win = if (event.event == wm.root and event.child != 0)
        event.child
    else
        event.event;

    const managed_win = utils.findManagedWindow(wm.conn, win, wm);

    if (filters.isSystemWindow(wm, managed_win)) return;
    if (!wm.hasWindow(managed_win)) return;
    if (!workspaces.isOnCurrentWorkspace(managed_win)) return;
    if (wm.focused_window == managed_win) return;

    // Suppress synthetic EnterNotify events generated when retiling shifts
    // windows under the cursor after a window spawn.  Cleared in
    // handleMotionNotify once the user actually moves the mouse.
    if (wm.suppress_focus_reason == .window_spawn) return;

    focus.setFocus(wm, managed_win, .mouse_enter);
}

// Leave notify (root) ──────────────────────────────────────────────────────

/// Root's LeaveNotify fires the instant the pointer enters any child window,
/// including Electron/Chromium which generates no EnterNotify or MotionNotify
/// events visible to root.  This gives us an event-driven focus path for those
/// windows rather than relying on the 50 ms polling fallback.
pub fn handleLeaveNotify(event: *const xcb.xcb_leave_notify_event_t, wm: *WM) void {
    wm.last_event_time = event.time;

    // Only care about root losing the pointer to a child window.
    if (event.event != wm.root) return;
    if (event.mode != xcb.XCB_NOTIFY_MODE_NORMAL) return;
    if (wm.drag_state.active) return;
    if (wm.suppress_focus_reason == .window_spawn) return;

    // event.child is the direct child of root being entered (if any).
    // If it is zero (pointer left root entirely, which shouldn't happen, or
    // the field wasn't populated), fall back to a single pointer query.
    const target: u32 = if (event.child != 0) event.child else blk: {
        const reply = xcb.xcb_query_pointer_reply(
            wm.conn, xcb.xcb_query_pointer(wm.conn, wm.root), null,
        ) orelse return;
        defer std.c.free(reply);
        break :blk reply.*.child;
    };

    if (target == 0 or target == wm.root) return;

    const managed = utils.findManagedWindow(wm.conn, target, wm);
    if (filters.isSystemWindow(wm, managed)) return;
    if (!wm.hasWindow(managed)) return;
    if (!workspaces.isOnCurrentWorkspace(managed)) return;
    if (wm.focused_window == managed) return;

    focus.setFocus(wm, managed, .mouse_enter);
}

// Property notify ──────────────────────────────────────────────────────────

/// Refresh WM_TAKE_FOCUS cache when WM_PROTOCOLS changes. Electron apps
/// set this after mapping, which would leave a stale false in the cache.
pub fn handlePropertyNotify(event: *const xcb.xcb_property_notify_event_t, wm: *WM) void {
    if (!wm.hasWindow(event.window)) return;
    const wm_protocols = utils.getAtomCached("WM_PROTOCOLS") catch return;
    if (event.atom == wm_protocols) {
        utils.cacheWMTakeFocus(wm.conn, event.window);
    }
}

// Unmap / destroy ──────────────────────────────────────────────────────────

fn unmanageWindow(wm: *WM, win: u32) void {
    if (wm.fullscreen.isFullscreen(win)) {
        // Clear fullscreen state for this window across all workspaces.
        var it = wm.fullscreen.per_workspace.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.window == win) {
                wm.fullscreen.removeForWorkspace(entry.key_ptr.*);
                break;
            }
        }
        bar.setBarState(wm, .show_fullscreen);
    }

    const was_focused = (wm.focused_window == win);

    if (wm.config.tiling.enabled) tiling.removeWindow(win);
    utils.uncacheWMTakeFocus(win);
    workspaces.removeWindow(win);
    wm.removeWindow(win);

    if (was_focused) {
        if (wm.config.tiling.enabled) {
            tiling.retileIfDirty(wm);
            utils.flush(wm.conn);
        }
        focus.clearFocus(wm);
        focusWindowUnderPointer(wm);
    }

    bar.markDirty();
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

// Post-unmanage focus recovery ─────────────────────────────────────────────

fn focusWindowUnderPointer(wm: *WM) void {
    const reply = xcb.xcb_query_pointer_reply(
        wm.conn, xcb.xcb_query_pointer(wm.conn, wm.root), null,
    ) orelse { focusFallback(wm); return; };
    defer std.c.free(reply);

    const child = reply.*.child;
    if (filters.isValidManagedWindow(wm, child) and workspaces.isOnCurrentWorkspace(child)) {
        focus.setFocus(wm, child, .mouse_enter);
        tiling.updateWindowFocus(wm, null, child);
        return;
    }
    focusFallback(wm);
}

/// Focus the first visible window in the current workspace (last-resort fallback).
fn focusFallback(wm: *WM) void {
    const ws = workspaces.getCurrentWorkspaceObject() orelse return;
    for (ws.windows.items()) |win| {
        if (filters.isValidManagedWindow(wm, win)) {
            focus.setFocus(wm, win, .window_destroyed);
            tiling.updateWindowFocus(wm, null, win);
            return;
        }
    }
}
