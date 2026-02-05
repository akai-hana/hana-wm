// Window event handlers - Optimized for instant window spawning

const std = @import("std");
const defs = @import("defs");
const xcb = defs.xcb;
const WM = defs.WM;
const utils = @import("utils");
const focus = @import("focus");
const tiling = @import("tiling");
const workspaces = @import("workspaces");
const bar = @import("bar");
const batch = @import("batch");
const debug = @import("debug");

const WINDOW_EVENT_MASK = xcb.XCB_EVENT_MASK_ENTER_WINDOW | 
                          xcb.XCB_EVENT_MASK_LEAVE_WINDOW |
                          xcb.XCB_EVENT_MASK_BUTTON_PRESS;

// Grab/ungrab buttons for click-to-focus (DWM approach)
pub fn grabButtons(wm: *WM, win: u32, focused: bool) void {
    // Ungrab all first
    _ = xcb.xcb_ungrab_button(wm.conn, xcb.XCB_BUTTON_INDEX_ANY, win, xcb.XCB_MOD_MASK_ANY);
    
    // If unfocused, grab all buttons to intercept clicks for focus
    if (!focused) {
        _ = xcb.xcb_grab_button(
            wm.conn,
            0, // owner_events = false
            win,
            xcb.XCB_EVENT_MASK_BUTTON_PRESS,
            xcb.XCB_GRAB_MODE_SYNC, // Freeze pointer until we replay
            xcb.XCB_GRAB_MODE_SYNC, // Freeze keyboard too
            xcb.XCB_NONE,
            xcb.XCB_NONE,
            xcb.XCB_BUTTON_INDEX_ANY,
            xcb.XCB_MOD_MASK_ANY,
        );
    }
}

// OPTIMIZATION: Inline workspace validation function
inline fn validateWorkspace(target_ws: ?usize, current_ws: usize) usize {
    const ws = target_ws orelse return current_ws;
    const ws_state = workspaces.getState() orelse return current_ws;
    
    if (ws >= ws_state.workspaces.len) {
        debug.warn("Rule workspace {} exceeds count, using current {}", .{ ws, current_ws });
        return current_ws;
    }
    return ws;
}

pub fn handleMapRequest(event: *const xcb.xcb_map_request_event_t, wm: *WM) void {
    const win = event.window;

    // Bar windows are handled immediately
    if (bar.isBarWindow(win)) {
        _ = xcb.xcb_map_window(wm.conn, win);
        utils.flush(wm.conn);
        return;
    }

    const current_ws = workspaces.getCurrentWorkspace() orelse 0;
    const target_ws = matchWorkspaceRule(wm, win);
    const validated_ws = validateWorkspace(target_ws, current_ws);
    const is_current_ws = (validated_ws == current_ws);

    // OPTIMIZATION: Use batch operations for all XCB calls
    var b = batch.Batch.begin(wm) catch {
        // Fallback to direct calls if batch fails
        handleMapRequestDirect(wm, win, is_current_ws, validated_ws);
        return;
    };
    defer b.deinit();

    // Subscribe to enter/leave events
    _ = xcb.xcb_change_window_attributes(wm.conn, win, xcb.XCB_CW_EVENT_MASK, &[_]u32{WINDOW_EVENT_MASK});

    // DWM APPROACH: Always map window, but position off-screen if not on current workspace
    if (!is_current_ws) {
        // Position window off-screen before mapping
        const off_screen_x: i32 = -4000;
        const values = [_]u32{@bitCast(off_screen_x)};
        _ = xcb.xcb_configure_window(wm.conn, win, xcb.XCB_CONFIG_WINDOW_X, &values);
    }
    
    // Always map the window (on-screen if current workspace, off-screen otherwise)
    b.map(win) catch {};

    // Track window
    wm.addWindow(win) catch |err| {
        debug.err("Failed to track window {x}: {}", .{ win, err });
    };

    // Add to workspace
    if (is_current_ws) {
        workspaces.addWindowToCurrentWorkspace(wm, win);
    } else {
        workspaces.moveWindowTo(wm, win, validated_ws);
    }

    // Set up tiling
    if (wm.config.tiling.enabled) {
        b.setBorderWidth(win, wm.config.tiling.border_width) catch {};
        if (is_current_ws) {
            b.setBorder(win, wm.config.tiling.border_unfocused) catch {};
        }
        tiling.addWindow(wm, win);
    }

    b.execute();
    
    // Grab buttons for click-to-focus (window starts unfocused)
    grabButtons(wm, win, false);
    
    bar.markDirty();
}

// OPTIMIZATION: Fallback for when batch operations fail
inline fn handleMapRequestDirect(wm: *WM, win: u32, is_current_ws: bool, validated_ws: usize) void {
    _ = xcb.xcb_change_window_attributes(wm.conn, win, xcb.XCB_CW_EVENT_MASK, &[_]u32{WINDOW_EVENT_MASK});
    
    // DWM APPROACH: Always map, but position off-screen if not current workspace
    if (!is_current_ws) {
        const off_screen_x: i32 = -4000;
        const values = [_]u32{@bitCast(off_screen_x)};
        _ = xcb.xcb_configure_window(wm.conn, win, xcb.XCB_CONFIG_WINDOW_X, &values);
    }
    
    _ = xcb.xcb_map_window(wm.conn, win);
    
    wm.addWindow(win) catch |err| {
        debug.err("Failed to track window {x}: {}", .{ win, err });
    };
    
    if (is_current_ws) {
        workspaces.addWindowToCurrentWorkspace(wm, win);
    } else {
        workspaces.moveWindowTo(wm, win, validated_ws);
    }
    
    if (wm.config.tiling.enabled) {
        _ = xcb.xcb_configure_window(wm.conn, win, xcb.XCB_CONFIG_WINDOW_BORDER_WIDTH,
            &[_]u32{wm.config.tiling.border_width});
        if (is_current_ws) {
            _ = xcb.xcb_change_window_attributes(wm.conn, win, xcb.XCB_CW_BORDER_PIXEL,
                &[_]u32{wm.config.tiling.border_unfocused});
        }
        tiling.addWindow(wm, win);
    }
    
    utils.flush(wm.conn);
    grabButtons(wm, win, false);
    bar.markDirty();
}

pub fn handleConfigureRequest(event: *const xcb.xcb_configure_request_event_t, wm: *WM) void {
    const win = event.window;
    
    // OPTIMIZATION: Combine checks with early return
    if (wm.fullscreen.isFullscreen(win) or 
        (wm.config.tiling.enabled and tiling.isWindowTiled(win))) return;

    // Allow floating windows to configure themselves
    const values = [_]u32{
        @intCast(event.x),
        @intCast(event.y),
        @intCast(event.width),
        @intCast(event.height),
        @intCast(event.border_width),
    };
    _ = xcb.xcb_configure_window(wm.conn, win, event.value_mask, &values);
    utils.flush(wm.conn);
}

pub fn handleEnterNotify(event: *const xcb.xcb_enter_notify_event_t, wm: *WM) void {
    const win = event.event;
    
    // OPTIMIZATION: Combined early return checks
    if (win == wm.root or win == 0 or bar.isBarWindow(win)) return;

    // Filter spurious EnterNotify events
    if (event.mode != xcb.XCB_NOTIFY_MODE_NORMAL or
        event.detail == xcb.XCB_NOTIFY_DETAIL_VIRTUAL or
        event.detail == xcb.XCB_NOTIFY_DETAIL_NONLINEAR_VIRTUAL) return;

    const old_focus = wm.focused_window;
    focus.setFocus(wm, win, .mouse_enter);
    tiling.updateWindowFocus(wm, old_focus, win);
}

pub fn handleButtonPress(event: *const xcb.xcb_button_press_event_t, wm: *WM) void {
    const win = event.event;
    
    if (win == wm.root or win == 0 or bar.isBarWindow(win)) return;
    
    // Always ungrab buttons on clicked window (even if already focused)
    // This is critical for apps like Firefox to receive input properly
    grabButtons(wm, win, true);
    
    // Focus window and replay the event (DWM approach)
    focus.setFocus(wm, win, .mouse_click);
    _ = xcb.xcb_allow_events(wm.conn, xcb.XCB_ALLOW_REPLAY_POINTER, xcb.XCB_CURRENT_TIME);
    _ = xcb.xcb_allow_events(wm.conn, xcb.XCB_ALLOW_ASYNC_KEYBOARD, xcb.XCB_CURRENT_TIME);
    utils.flush(wm.conn);
}

pub fn handleDestroyNotify(event: *const xcb.xcb_destroy_notify_event_t, wm: *WM) void {
    const win = event.window;

    if (bar.isBarWindow(win)) return;

    // Clean up fullscreen state
    if (wm.fullscreen.isFullscreen(win)) {
        cleanupFullscreenWindow(wm, win);
        bar.setBarState(wm, .show_fullscreen);
    }

    const was_focused = (wm.focused_window == win);

    if (wm.config.tiling.enabled) {
        tiling.removeWindow(wm, win);
    }

    workspaces.removeWindow(win);
    wm.removeWindow(win);

    if (was_focused) {
        // DWM approach: Retile FIRST, THEN handle focus
        // This ensures windows are in final positions before we decide what to focus
        if (wm.config.tiling.enabled) {
            tiling.retileIfDirty(wm);
            utils.flush(wm.conn);
        }
        
        focus.clearFocus(wm);
        
        // Now focus based on pointer position after retiling
        focusWindowUnderPointer(wm);
    }

    bar.markDirty();
    utils.flush(wm.conn);
}

// Focus the window currently under the pointer
fn focusWindowUnderPointer(wm: *WM) void {
    const pointer_query = xcb.xcb_query_pointer(wm.conn, wm.root);
    const pointer_reply = xcb.xcb_query_pointer_reply(wm.conn, pointer_query, null);
    
    if (pointer_reply) |reply| {
        defer std.c.free(reply);
        
        const child_win = reply.*.child;
        
        // If pointer is over a valid window, focus it
        if (child_win != 0 and child_win != wm.root and !bar.isBarWindow(child_win)) {
            if (wm.windows.contains(child_win) and workspaces.isOnCurrentWorkspace(child_win)) {
                focus.setFocus(wm, child_win, .mouse_enter);
                tiling.updateWindowFocus(wm, null, child_win);
                return;
            }
        }
    }
    
    // Fallback: focus first window in workspace if pointer isn't over anything valid
    if (workspaces.getCurrentWorkspaceObject()) |ws| {
        const windows = ws.windows.list.items;
        for (windows) |workspace_win| {
            if (workspace_win != 0 and workspace_win != wm.root and 
                !bar.isBarWindow(workspace_win) and wm.windows.contains(workspace_win)) {
                focus.setFocus(wm, workspace_win, .window_destroyed);
                tiling.updateWindowFocus(wm, null, workspace_win);
                return;
            }
        }
    }
}

// OPTIMIZATION: Extract fullscreen cleanup into separate function
inline fn cleanupFullscreenWindow(wm: *WM, win: u32) void {
    var it = wm.fullscreen.per_workspace.iterator();
    while (it.next()) |entry| {
        if (entry.value_ptr.window == win) {
            wm.fullscreen.removeForWorkspace(entry.key_ptr.*);
            break;
        }
    }
}

// OPTIMIZATION: Cache WM class lookups to avoid repeated allocations
inline fn matchWorkspaceRule(wm: *WM, win: u32) ?usize {
    const rules = wm.config.workspaces.rules.items;
    if (rules.len == 0) return null;

    const wm_class = utils.getWMClass(wm.conn, win, wm.allocator) orelse return null;
    defer wm_class.deinit(wm.allocator);

    // OPTIMIZATION: Single loop with early return
    for (rules) |rule| {
        if (std.mem.eql(u8, rule.class_name, wm_class.class) or
            std.mem.eql(u8, rule.class_name, wm_class.instance))
        {
            return rule.workspace;
        }
    }

    return null;
}
