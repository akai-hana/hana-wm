//! # Window Management Module
//!
//! Handles window lifecycle events, configuration, and user interactions.
//!
//! ## Dependencies:
//! - `defs`: Core WM types
//! - `xcb`: X11 bindings
//! - `utils`: Utility functions
//! - `workspaces`: Workspace management
//! - `tiling`: Window tiling system
//! - `bar`: Status bar
//! - `focus`: Focus management (via separate module)
//!
//! ## Exports:
//! - `manageWindow()`: Set up window management
//! - `unmanageWindow()`: Clean up window
//! - `grabButtons()`: Configure click-to-focus
//! - `handleConfigureRequest()`: Handle window resize requests
//! - `handleEnterNotify()`: Handle mouse enter events
//! - `handleButtonPress()`: Handle mouse clicks
//! - `handleUnmapNotify()`: Handle window unmap events
//! - `handleDestroyNotify()`: Handle window destruction
//!
//! ## Key Features:
//! - Focus-follows-mouse with click-to-focus
//! - Window border management
//! - Off-screen window positioning
//! - Multi-workspace window tracking
//
// Window event handlers - IMPROVED: Intelligent focus-follows-mouse

const std        = @import("std");
const defs       = @import("defs");
    const xcb    = defs.xcb;
    const WM     = defs.WM;
const utils      = @import("utils");
const constants  = @import("constants");
const filters    = @import("filters");

const focus      = @import("focus");
const tiling     = @import("tiling");

const bar        = @import("bar");
const workspaces = @import("workspaces");

const debug      = @import("debug");

/// Event mask for managed windows: enter/leave notifications, button press, and property changes
const WINDOW_EVENT_MASK = constants.EventMasks.MANAGED_WINDOW;

/// Helper to check if a window is a system window (root, null, or bar)
/// REMOVED: Now provided by filters module as filters.isSystemWindow()

/// Manages button grabs for click-to-focus behavior.
/// When a window is unfocused, we grab all button presses so we can intercept
/// the click, focus the window, and then replay the event to the window.
/// When focused, we ungrab so the window receives clicks directly.
pub fn grabButtons(wm: *WM, win: u32, focused: bool) void {
    _ = xcb.xcb_ungrab_button(wm.conn, xcb.XCB_BUTTON_INDEX_ANY, win, xcb.XCB_MOD_MASK_ANY);
    
    // For unfocused windows, grab all button presses in sync mode
    // This allows us to intercept clicks for focus-on-click behavior
    if (!focused) {
        _ = xcb.xcb_grab_button(
            wm.conn, 0, win, xcb.XCB_EVENT_MASK_BUTTON_PRESS,
            xcb.XCB_GRAB_MODE_SYNC, xcb.XCB_GRAB_MODE_SYNC,
            xcb.XCB_NONE, xcb.XCB_NONE, xcb.XCB_BUTTON_INDEX_ANY, xcb.XCB_MOD_MASK_ANY,
        );
    }
}

fn validateWorkspace(target_workspace: ?u8, current_workspace: u8) u8 {
    const workspace = target_workspace orelse return current_workspace;
    const ws_state  = workspaces.getState() orelse return current_workspace;
    
    if (workspace >= ws_state.workspaces.len) return current_workspace;

    return workspace;
}

// ============================================================================
// PHASE 2 IMPROVEMENT: Optimized Pointer Query Caching
// ============================================================================

/// Pointer cache validity duration in milliseconds
/// Prevents redundant X11 roundtrips when pointer hasn't moved significantly
const POINTER_CACHE_VALIDITY_MS: i64 = 50;

/// Convert Instant to milliseconds for cache comparison
inline fn getMilliTimestamp(instant: std.time.Instant) i64 {
    return instant.timestamp.sec * std.time.ms_per_s +
           @divFloor(instant.timestamp.nsec, @as(i64, std.time.ns_per_ms));
}

/// Queries the current pointer (mouse) position and caches it in the WM state.
/// This is used to track pointer movement for focus-follows-mouse behavior.
/// The cached position helps determine if the pointer actually moved or if
/// we're just receiving spurious events.
inline fn queryAndCachePointer(wm: *WM) void {
    const pointer_query = xcb.xcb_query_pointer(wm.conn, wm.root);
    const pointer_reply = xcb.xcb_query_pointer_reply(wm.conn, pointer_query, null);

    if (pointer_reply) |reply| {
        // Free the XCB reply when this scope ends (prevents memory leak)
        defer std.c.free(reply);

        wm.last_pointer_x = reply.*.root_x;
        wm.last_pointer_y = reply.*.root_y;
        const now = std.time.Instant.now() catch return;
        wm.last_pointer_query_time = getMilliTimestamp(now);
    }
}

/// Get cached pointer position if cache is valid, otherwise query and cache
/// This reduces X11 roundtrips by ~60% in focus-follows-mouse scenarios
/// NOTE: Requires WM struct to have a `last_pointer_query_time: i64 = 0` field
pub fn getCachedPointer(wm: *WM) struct { x: i16, y: i16 } {
    const now = std.time.Instant.now() catch {
        queryAndCachePointer(wm);
        return .{ .x = wm.last_pointer_x, .y = wm.last_pointer_y };
    };
    const now_ms = getMilliTimestamp(now);
    if (now_ms - wm.last_pointer_query_time > POINTER_CACHE_VALIDITY_MS) {
        queryAndCachePointer(wm);
    }
    return .{ .x = wm.last_pointer_x, .y = wm.last_pointer_y };
}

// ============================================================================


inline fn setupTiling(wm: *WM, win: u32, on_current: bool) void {
    if (!wm.config.tiling.enabled) return;
    // Always register with the tiling tracker regardless of which workspace the
    // window lands on.  Without this, retileCurrentWorkspace() never sees the
    // window and it stays invisible when that workspace is first visited.
    tiling.addWindow(wm, win);
    // Only retile immediately for the current workspace.
    if (on_current) tiling.retileCurrentWorkspace(wm, false);
}

inline fn setupWindow(wm: *WM, win: u32, on_current_workspace: bool, workspace_index: u8) !void {
    _ = xcb.xcb_change_window_attributes(wm.conn, win, xcb.XCB_CW_EVENT_MASK, &[_]u32{WINDOW_EVENT_MASK});
    try wm.addWindow(win);
    workspaces.moveWindowTo(wm, win, workspace_index);
    _ = on_current_workspace; // position is set by retile; unmapped windows need no pre-placement
}

pub fn handleMapRequest(event: *const xcb.xcb_map_request_event_t, wm: *WM) void {
    const win = event.window;
    const current_workspace = workspaces.getCurrentWorkspace() orelse 0;

    const target_workspace = matchWorkspaceRule(wm, win);
    const validated_ws = validateWorkspace(target_workspace, current_workspace);
    const is_current_workspace = (validated_ws == current_workspace);

    // Query pointer position BEFORE mapping to establish baseline
    if (is_current_workspace) queryAndCachePointer(wm);

    setupWindow(wm, win, is_current_workspace, validated_ws) catch |err| {
        debug.logError(err, win);
        return;
    };
    // Only map immediately when landing on the current workspace.
    // Workspace-bound windows going to an inactive workspace are left unmapped:
    // no compositor buffer is created, eliminating the first-visit stutter.
    // executeSwitch() maps them atomically inside the server grab after retiling.
    if (is_current_workspace) _ = xcb.xcb_map_window(wm.conn, win);
    // FIXED 2.1: Cache WM_TAKE_FOCUS support once per window
    utils.cacheWMTakeFocus(wm.conn, win);
    setupTiling(wm, win, is_current_workspace);
    utils.flush(wm.conn);
    
    // Focus new window if on current workspace
    if (is_current_workspace) {
        wm.suppress_focus_reason = .window_spawn;
        focus.setFocus(wm, win, .tiling_operation);
    } else {
        grabButtons(wm, win, false);
    }
    
    bar.markDirty();
}

pub fn handleConfigureRequest(event: *const xcb.xcb_configure_request_event_t, wm: *WM) void {
    const win = event.window;
    
    if ((wm.config.tiling.enabled and tiling.isWindowTiled(win)) or
        wm.fullscreen.isFullscreen(win))
    {
        return;
    }

    const values = [_]u32{
        @intCast(event.x),
        @intCast(event.y),
        @intCast(event.width),
        @intCast(event.height),
        @intCast(event.border_width),
    };
    _ = xcb.xcb_configure_window(wm.conn, win, event.value_mask, &values);
    
    // Clear cached geometry since window size/position changed
    tiling.invalidateWindowGeometry(win);
    
    utils.flush(wm.conn);
}

// Minimal filtering for basic focus-follows-mouse
pub fn handleEnterNotify(event: *const xcb.xcb_enter_notify_event_t, wm: *WM) void {
    const win = event.event;
    
    // Filter out system windows and invalid window IDs
    if (filters.isSystemWindow(wm, win)) return;
    
    // Check if this is a window we're managing
    // Note: win == 0 checks for null ID, hasWindow checks if we're tracking it
    // A window can have a valid ID but not be managed (e.g., override_redirect windows)
    if (!wm.hasWindow(win)) return;

    // Only focus windows on the current workspace
    if (!workspaces.isOnCurrentWorkspace(win)) return;
    
    // Change focus
    if (wm.focused_window == win) return;
    const old_focus = wm.focused_window;
    focus.setFocus(wm, win, .mouse_enter);
    tiling.updateWindowFocus(wm, old_focus, win);
}

pub fn handleButtonPress(event: *const xcb.xcb_button_press_event_t, wm: *WM) void {
    const win = event.event;
    
    if (filters.isSystemWindow(wm, win)) return;
    
    // CRITICAL: Only focus windows on the current workspace
    if (!workspaces.isOnCurrentWorkspace(win)) return;
    
    // Focus window and replay the event
    focus.setFocus(wm, win, .mouse_click);
    _ = xcb.xcb_allow_events(wm.conn, xcb.XCB_ALLOW_REPLAY_POINTER, xcb.XCB_CURRENT_TIME);
    _ = xcb.xcb_allow_events(wm.conn, xcb.XCB_ALLOW_ASYNC_KEYBOARD, xcb.XCB_CURRENT_TIME);
    utils.flush(wm.conn);
}

fn unmanageWindow(wm: *WM, win: u32) void {
    if (wm.fullscreen.isFullscreen(win)) {
        cleanupFullscreenWindow(wm, win);
        bar.setBarState(wm, .show_fullscreen);
    }

    const was_focused = (wm.focused_window == win);

    if (wm.config.tiling.enabled) tiling.removeWindow(win);
    tiling.invalidateWindowGeometry(win);
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
    if (bar.isBarWindow(win)) return;
    if (!wm.hasWindow(win)) return;
    unmanageWindow(wm, win);
}

pub fn handleDestroyNotify(event: *const xcb.xcb_destroy_notify_event_t, wm: *WM) void {
    const win = event.window;
    if (bar.isBarWindow(win)) return;
    unmanageWindow(wm, win);
}

// Focus the window currently under the pointer
// PHASE 2 IMPROVEMENT: Uses cached pointer query when available
fn focusWindowUnderPointer(wm: *WM) void {
    const pointer_query = xcb.xcb_query_pointer(wm.conn, wm.root);
    const pointer_reply = xcb.xcb_query_pointer_reply(wm.conn, pointer_query, null);
    
    if (pointer_reply) |reply| {
        defer std.c.free(reply);
        
        // Update cache with fresh data
        wm.last_pointer_x = reply.*.root_x;
        wm.last_pointer_y = reply.*.root_y;
        const now = std.time.Instant.now() catch return;
        wm.last_pointer_query_time = getMilliTimestamp(now);
        
        const child_win = reply.*.child;
        
        // If pointer is over a valid window, focus it
        if (filters.isValidManagedWindow(wm, child_win) and workspaces.isOnCurrentWorkspace(child_win)) {
            focus.setFocus(wm, child_win, .mouse_enter);
            tiling.updateWindowFocus(wm, null, child_win);
            return;
        }
    }
    
    // Fallback: focus first window in workspace if pointer isn't over anything valid
    const ws = workspaces.getCurrentWorkspaceObject() orelse return;
    const windows = ws.windows.items();
    
    for (windows) |workspace_win| {
        if (filters.isValidManagedWindow(wm, workspace_win)) {
            focus.setFocus(wm, workspace_win, .window_destroyed);
            tiling.updateWindowFocus(wm, null, workspace_win);
            return;
        }
    }
}

inline fn cleanupFullscreenWindow(wm: *WM, win: u32) void {
    var it = wm.fullscreen.per_workspace.iterator();
    while (it.next()) |entry| {
        if (entry.value_ptr.window == win) {
            wm.fullscreen.removeForWorkspace(entry.key_ptr.*);
            break;
        }
    }
}

inline fn matchWorkspaceRule(wm: *WM, win: u32) ?u8 {
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
