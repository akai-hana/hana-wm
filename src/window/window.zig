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

// Button grabs ─────────────────────────────────────────────────────────────

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

// Setup helpers ────────────────────────────────────────────────────────────

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

// Map request ──────────────────────────────────────────────────────────────

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
        wm.suppress_focus_reason = .window_spawn;
        focus.setFocus(wm, win, .tiling_operation);
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

// Focus events ─────────────────────────────────────────────────────────────

pub fn handleEnterNotify(event: *const xcb.xcb_enter_notify_event_t, wm: *WM) void {
    const win = event.event;
    if (filters.isSystemWindow(wm, win)) return;
    if (!wm.hasWindow(win)) return;
    if (!workspaces.isOnCurrentWorkspace(win)) return;
    if (wm.focused_window == win) return;
    const old = wm.focused_window;
    focus.setFocus(wm, win, .mouse_enter);
    tiling.updateWindowFocus(wm, old, win);
}

pub fn handleButtonPress(event: *const xcb.xcb_button_press_event_t, wm: *WM) void {
    const win = event.event;
    if (filters.isSystemWindow(wm, win)) return;
    if (!workspaces.isOnCurrentWorkspace(win)) return;
    focus.setFocus(wm, win, .mouse_click);
    _ = xcb.xcb_allow_events(wm.conn, xcb.XCB_ALLOW_REPLAY_POINTER, xcb.XCB_CURRENT_TIME);
    _ = xcb.xcb_allow_events(wm.conn, xcb.XCB_ALLOW_ASYNC_KEYBOARD, xcb.XCB_CURRENT_TIME);
    utils.flush(wm.conn);
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
        wm.suppress_focus_reason = .none;
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
