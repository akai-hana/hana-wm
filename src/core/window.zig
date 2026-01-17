//! Window management optimized for responsivity
//! - Map windows IMMEDIATELY (no blocking on WM_CLASS)
//! - Apply workspace rules asynchronously after mapping
const std = @import("std");
const defs = @import("defs");
const xcb = defs.xcb;
const WM = defs.WM;
const utils = @import("utils");
const tiling = @import("tiling");
const workspaces = @import("workspaces");
const focus = @import("focus");
const builtin = @import("builtin");

pub fn init(_: *WM) void {}
pub fn deinit(_: *WM) void {}

// ============================================================================
// EVENT HANDLERS - OPTIMIZED FOR IMMEDIATE RESPONSE
// ============================================================================

pub fn handleMapRequest(event: *const xcb.xcb_map_request_event_t, wm: *WM) void {
    const win = event.window;

    // CRITICAL: Check workspace rules BEFORE mapping to avoid flicker
    const target_ws = if (wm.config.workspaces.rules.items.len > 0)
        matchWorkspaceRule(wm, win)
    else
        null;

    const current_ws = workspaces.getCurrentWorkspace() orelse 0;

    if (target_ws) |ws| {
        if (ws != current_ws) {
            // Add to target workspace but don't map (it's not current)
            workspaces.addWindowToWorkspace(wm, win, ws);
            
            // Configure window but don't show it
            if (wm.config.tiling.enabled) {
                // Set up tiling state but don't map
                const attrs = utils.WindowAttrs{
                    .border_width = wm.config.tiling.border_width,
                    .event_mask = xcb.XCB_EVENT_MASK_ENTER_WINDOW | xcb.XCB_EVENT_MASK_LEAVE_WINDOW,
                };
                attrs.configure(wm.conn, win);
            }
            
            utils.flush(wm.conn);
            return; // Don't map - window goes to different workspace
        }
    }

    // Map to current workspace
    workspaces.addWindowToCurrentWorkspace(wm, win);
    _ = xcb.xcb_map_window(wm.conn, win);

    if (wm.config.tiling.enabled) {
        tiling.notifyWindowMapped(wm, win);
    }

    utils.flush(wm.conn);
}

pub fn handleConfigureRequest(event: *const xcb.xcb_configure_request_event_t, wm: *WM) void {
    // Let tiling handle tiled windows
    if (wm.config.tiling.enabled and tiling.isWindowTiled(event.window)) return;

    // Configure floating window - single XCB call
    _ = xcb.xcb_configure_window(wm.conn, event.window, event.value_mask, &[_]u32{
        @intCast(event.x),
        @intCast(event.y),
        @intCast(event.width),
        @intCast(event.height),
        @intCast(event.border_width),
    });
}

pub fn handleEnterNotify(event: *const xcb.xcb_enter_notify_event_t, wm: *WM) void {
    if (event.event == wm.root or event.event == 0) return;
    focus.setFocus(wm, event.event, .mouse_enter);
}

pub fn handleDestroyNotify(event: *const xcb.xcb_destroy_notify_event_t, wm: *WM) void {
    const win = event.window;
    const was_focused = wm.focused_window == win;

    // CRITICAL: Clean up in correct order
    // 1. Notify tiling FIRST (while window is still in workspaces)
    tiling.notifyWindowDestroyed(wm, win);
    
    // 2. Remove from workspaces
    workspaces.removeWindow(win);
    
    // 3. Remove from WM's window map
    wm.removeWindow(win);

    // 4. Handle focus
    if (was_focused) {
        wm.focused_window = null;
        
        // Try to focus a window from current workspace, not global window list
        if (workspaces.getCurrentWindowsView()) |ws_windows| {
            if (ws_windows.len > 0) {
                focus.setFocus(wm, ws_windows[0], .window_destroyed);
                return;
            }
        }
        
        // No windows left, clear focus
        focus.clearFocus(wm);
    }
}

// ============================================================================
// WORKSPACE RULES - NON-BLOCKING
// ============================================================================

fn matchWorkspaceRule(wm: *WM, win: u32) ?usize {
    // This may block on X11, but only BEFORE window is mapped
    const wm_class = utils.getWMClass(wm.conn, win, wm.allocator) orelse return null;
    defer wm_class.deinit(wm.allocator);

    for (wm.config.workspaces.rules.items) |rule| {
        if (std.mem.eql(u8, rule.class_name, wm_class.class) or
            std.mem.eql(u8, rule.class_name, wm_class.instance))
        {
            return rule.workspace;
        }
    }

    return null;
}
