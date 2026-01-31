//! Window event handlers - Optimized for instant window spawning

const std = @import("std");
const defs = @import("defs");
const xcb = defs.xcb;
const WM = defs.WM;
const utils = @import("utils");
const focus = @import("focus");
const tiling = @import("tiling");
const workspaces = @import("workspaces");
const bar = @import("bar");

pub fn handleMapRequest(event: *const xcb.xcb_map_request_event_t, wm: *WM) void {
    const win = event.window;

    // Bar windows are handled immediately
    if (bar.isBarWindow(win)) {
        _ = xcb.xcb_map_window(wm.conn, win);
        utils.flush(wm.conn);
        return;
    }

    // Determine target workspace based on rules
    const target_ws = if (wm.config.workspaces.rules.items.len > 0)
        matchWorkspaceRule(wm, win)
    else
        null;

    const current_ws = workspaces.getCurrentWorkspace() orelse 0;

    // Validate target workspace exists
    const validated_target_ws = if (target_ws) |ws| blk: {
        const ws_state = workspaces.getState() orelse break :blk current_ws;
        if (ws >= ws_state.workspaces.len) {
            std.log.warn("[window] Rule workspace {} exceeds count, using current {}", .{ ws, current_ws });
            break :blk current_ws;
        }
        break :blk ws;
    } else current_ws;

    // Subscribe to enter/leave events for focus-follows-mouse
    _ = xcb.xcb_change_window_attributes(wm.conn, win, xcb.XCB_CW_EVENT_MASK, 
        &[_]u32{xcb.XCB_EVENT_MASK_ENTER_WINDOW | xcb.XCB_EVENT_MASK_LEAVE_WINDOW});
    
    // ISSUE #5 FIX: Only map window if it belongs to current workspace
    // This prevents windows bound to other workspaces from appearing on screen
    const should_map = (validated_target_ws == current_ws);
    
    if (should_map) {
        _ = xcb.xcb_map_window(wm.conn, win);
    }
    
    wm.addWindow(win) catch |err| {
        std.log.err("[window] Failed to track window {x}: {}", .{ win, err });
    };

    // Add to appropriate workspace
    if (validated_target_ws == current_ws) {
        workspaces.addWindowToCurrentWorkspace(wm, win);
    } else {
        workspaces.moveWindowTo(wm, win, validated_target_ws);
    }

    // Set up tiling if enabled.
    // Border pre-configuration only runs when the window is mapped on the
    // current workspace.  tiling.addWindow is called unconditionally so that
    // windows bound to a different workspace are still registered in the tiling
    // lists and will be laid out correctly when that workspace is switched to.
    if (wm.config.tiling.enabled) {
        if (validated_target_ws == current_ws and should_map) {
            _ = xcb.xcb_configure_window(wm.conn, win, xcb.XCB_CONFIG_WINDOW_BORDER_WIDTH, 
                &[_]u32{wm.config.tiling.border_width});
            _ = xcb.xcb_change_window_attributes(wm.conn, win, xcb.XCB_CW_BORDER_PIXEL, 
                &[_]u32{wm.config.tiling.border_normal});
        }
        tiling.addWindow(wm, win);
    }

    bar.markDirty();
    utils.flush(wm.conn);
}

pub fn handleConfigureRequest(event: *const xcb.xcb_configure_request_event_t, wm: *WM) void {
    // Block fullscreen window from reconfiguring itself
    if (wm.fullscreen.isFullscreen(event.window)) return;
    
    // Tiled windows ignore configure requests - WM controls their geometry
    if (wm.config.tiling.enabled and tiling.isWindowTiled(event.window)) return;

    // Allow floating windows to configure themselves
    _ = xcb.xcb_configure_window(wm.conn, event.window, event.value_mask, &[_]u32{
        @intCast(event.x),
        @intCast(event.y),
        @intCast(event.width),
        @intCast(event.height),
        @intCast(event.border_width),
    });
    utils.flush(wm.conn);
}

pub fn handleEnterNotify(event: *const xcb.xcb_enter_notify_event_t, wm: *WM) void {
    // Ignore invalid windows
    if (event.event == wm.root or event.event == 0) return;
    
    // Ignore bar
    if (bar.isBarWindow(event.event)) return;
    
    // Respect focus protection (prevents focus stealing during explicit focus changes)
    if (focus.isProtected()) return;
    
    // Filter spurious EnterNotify events
    // X11 generates EnterNotify in many scenarios beyond "mouse entered window":
    // - Window map/unmap operations
    // - Pointer grabs/ungrabs (e.g., during Super+drag)
    // - Virtual crossings when pointer is grabbed
    
    // Ignore grab/ungrab related events
    if (event.mode != xcb.XCB_NOTIFY_MODE_NORMAL) return;
    
    // Ignore virtual crossings
    if (event.detail == xcb.XCB_NOTIFY_DETAIL_VIRTUAL or 
        event.detail == xcb.XCB_NOTIFY_DETAIL_NONLINEAR_VIRTUAL) return;

    const old_focus = wm.focused_window;
    focus.setFocus(wm, event.event, .mouse_enter);

    tiling.updateWindowFocus(wm, old_focus, event.event);
}

pub fn handleDestroyNotify(event: *const xcb.xcb_destroy_notify_event_t, wm: *WM) void {
    const win = event.window;

    if (bar.isBarWindow(win)) return;

    // Clean up fullscreen state if this window was fullscreened
    if (wm.fullscreen.isFullscreen(win)) {
        // Find which workspace this window was fullscreened on and remove it
        var it = wm.fullscreen.per_workspace.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.window == win) {
                wm.fullscreen.removeForWorkspace(entry.key_ptr.*);
                break;
            }
        }
    }

    if (wm.config.tiling.enabled) {
        tiling.removeWindow(wm, win);
    }

    workspaces.removeWindow(win);
    wm.removeWindow(win);

    if (wm.focused_window == win) {
        focus.clearFocus(wm);
    }

    bar.markDirty();
    utils.flush(wm.conn);
}

fn matchWorkspaceRule(wm: *WM, win: u32) ?usize {
    if (wm.config.workspaces.rules.items.len == 0) return null;

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
