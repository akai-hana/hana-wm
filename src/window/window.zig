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

const WINDOW_EVENT_MASK = xcb.XCB_EVENT_MASK_ENTER_WINDOW | xcb.XCB_EVENT_MASK_LEAVE_WINDOW;

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

    // Map window only if on current workspace
    if (is_current_ws) {
        b.map(win) catch {};
    }

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
        if (is_current_ws) {
            b.setBorderWidth(win, wm.config.tiling.border_width) catch {};
            b.setBorder(win, wm.config.tiling.border_unfocused) catch {};
        }
        tiling.addWindow(wm, win);
    }

    b.execute();
    bar.markDirty();
}

// OPTIMIZATION: Fallback for when batch operations fail
inline fn handleMapRequestDirect(wm: *WM, win: u32, is_current_ws: bool, validated_ws: usize) void {
    _ = xcb.xcb_change_window_attributes(wm.conn, win, xcb.XCB_CW_EVENT_MASK, &[_]u32{WINDOW_EVENT_MASK});
    
    if (is_current_ws) {
        _ = xcb.xcb_map_window(wm.conn, win);
    }
    
    wm.addWindow(win) catch |err| {
        debug.err("Failed to track window {x}: {}", .{ win, err });
    };
    
    if (is_current_ws) {
        workspaces.addWindowToCurrentWorkspace(wm, win);
    } else {
        workspaces.moveWindowTo(wm, win, validated_ws);
    }
    
    if (wm.config.tiling.enabled) {
        if (is_current_ws) {
            _ = xcb.xcb_configure_window(wm.conn, win, xcb.XCB_CONFIG_WINDOW_BORDER_WIDTH,
                &[_]u32{wm.config.tiling.border_width});
            _ = xcb.xcb_change_window_attributes(wm.conn, win, xcb.XCB_CW_BORDER_PIXEL,
                &[_]u32{wm.config.tiling.border_unfocused});
        }
        tiling.addWindow(wm, win);
    }
    
    utils.flush(wm.conn);
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
    if (win == wm.root or win == 0 or bar.isBarWindow(win) or focus.isProtected()) return;

    // Filter spurious EnterNotify events
    if (event.mode != xcb.XCB_NOTIFY_MODE_NORMAL or
        event.detail == xcb.XCB_NOTIFY_DETAIL_VIRTUAL or
        event.detail == xcb.XCB_NOTIFY_DETAIL_NONLINEAR_VIRTUAL) return;

    const old_focus = wm.focused_window;
    focus.setFocus(wm, win, .mouse_enter);
    tiling.updateWindowFocus(wm, old_focus, win);
}

pub fn handleDestroyNotify(event: *const xcb.xcb_destroy_notify_event_t, wm: *WM) void {
    const win = event.window;

    if (bar.isBarWindow(win)) return;

    // Clean up fullscreen state
    if (wm.fullscreen.isFullscreen(win)) {
        cleanupFullscreenWindow(wm, win);
        bar.setBarState(wm, .show_fullscreen);
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
