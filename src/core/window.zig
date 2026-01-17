//! Window event handling module.
//!
//! Handles core X11 window events:
//! - Map requests (window wants to be displayed)
//! - Configure requests (window wants to resize/move)
//! - Destroy notifications (window closed)
//! - Enter notifications (mouse enters window - focus follows mouse)

const std = @import("std");
const defs = @import("defs");
const log = @import("logging");
const tiling = @import("tiling");
const workspaces = @import("workspaces");
const focus = @import("focus");
const xcb = defs.xcb;
const WM = defs.WM;
const builtin = @import("builtin");

pub const EVENT_TYPES = [_]u8{
    xcb.XCB_MAP_REQUEST,
    xcb.XCB_CONFIGURE_REQUEST,
    xcb.XCB_DESTROY_NOTIFY,
    xcb.XCB_ENTER_NOTIFY,
};

pub fn init(_: *WM) void {
    log.debugWindowModuleInit();
}

pub fn deinit(_: *WM) void {}

pub fn handleEvent(event_type: u8, event: *anyopaque, wm: *WM) void {
    switch (event_type & 0x7F) {
        xcb.XCB_MAP_REQUEST => handleMapRequest(event, wm),
        xcb.XCB_CONFIGURE_REQUEST => handleConfigureRequest(event, wm),
        xcb.XCB_ENTER_NOTIFY => handleEnterNotify(event, wm),
        xcb.XCB_DESTROY_NOTIFY => handleDestroyNotify(event, wm),
        else => {},
    }
}

/// Get WM_CLASS property from a window (returns class and instance)
fn getWindowClass(wm: *WM, window: u32, allocator: std.mem.Allocator) ?struct { class: []const u8, instance: []const u8 } {
    const WM_CLASS = xcb.xcb_intern_atom_reply(wm.conn, 
        xcb.xcb_intern_atom(wm.conn, 0, 8, "WM_CLASS"), null);
    if (WM_CLASS == null) return null;
    defer std.c.free(WM_CLASS);
    
    const cookie = xcb.xcb_get_property(wm.conn, 0, window, 
        WM_CLASS.*.atom, xcb.XCB_ATOM_STRING, 0, 256);
    const reply = xcb.xcb_get_property_reply(wm.conn, cookie, null) orelse return null;
    defer std.c.free(reply);
    
    if (reply.*.value_len == 0) return null;
    
    const value_ptr = xcb.xcb_get_property_value(reply);
    const value_len = xcb.xcb_get_property_value_length(reply);
    if (value_ptr == null or value_len == 0) return null;
    
    // WM_CLASS format: "instance\0class\0"
    const data: [*]const u8 = @ptrCast(value_ptr);
    const total_len = @as(usize, @intCast(value_len));
    
    // Find the null terminator for instance
    var instance_len: usize = 0;
    while (instance_len < total_len and data[instance_len] != 0) : (instance_len += 1) {}
    
    if (instance_len >= total_len) return null;
    
    const instance = allocator.dupe(u8, data[0..instance_len]) catch return null;
    
    // Find class (starts after first null)
    const class_start = instance_len + 1;
    if (class_start >= total_len) {
        allocator.free(instance);
        return null;
    }
    
    var class_len: usize = 0;
    while (class_start + class_len < total_len and data[class_start + class_len] != 0) : (class_len += 1) {}
    
    const class = allocator.dupe(u8, data[class_start..class_start + class_len]) catch {
        allocator.free(instance);
        return null;
    };
    
    return .{ .class = class, .instance = instance };
}

/// Match window against workspace rules
fn matchWorkspaceRule(wm: *WM, window: u32) ?usize {
    const wm_class = getWindowClass(wm, window, wm.allocator) orelse return null;
    defer {
        wm.allocator.free(wm_class.class);
        wm.allocator.free(wm_class.instance);
    }
    
    if (builtin.mode == .Debug) {
        std.log.info("[rules] Window 0x{x}: class=\"{s}\", instance=\"{s}\"", 
            .{window, wm_class.class, wm_class.instance});
    }
    
    // Check rules against both class and instance
    for (wm.config.workspaces.rules.items) |rule| {
        if (std.mem.eql(u8, rule.class_name, wm_class.class) or 
            std.mem.eql(u8, rule.class_name, wm_class.instance)) {
            if (builtin.mode == .Debug) {
                std.log.info("[rules] Matched rule: '{s}' → workspace {}", 
                    .{rule.class_name, rule.workspace + 1});
            }
            return rule.workspace;
        }
    }
    
    return null;
}

/// Handle window map requests - make window visible
/// This is the ONLY place that should handle MAP_REQUEST to avoid triple-mapping
fn handleMapRequest(event: *anyopaque, wm: *WM) void {
    const e: *const xcb.xcb_map_request_event_t = @ptrCast(@alignCast(event));
    const window_id = e.window;

    log.debugWindowMapRequest(window_id);

    // Check if window matches any workspace rule
    const target_workspace = matchWorkspaceRule(wm, window_id);
    
    if (target_workspace) |ws| {
        // Add to target workspace instead of current
        if (builtin.mode == .Debug) {
            std.log.info("[rules] Assigning window 0x{x} to workspace {}", .{window_id, ws + 1});
        }
        workspaces.addWindowToWorkspace(wm, window_id, ws);
        
        // Only map if it's being added to the current workspace
        const current_ws = workspaces.getCurrentWorkspace() orelse 0;
        if (ws == current_ws) {
            _ = xcb.xcb_map_window(wm.conn, window_id);
            if (wm.config.tiling.enabled) {
                tiling.notifyWindowMapped(wm, window_id);
            }
        }
        // If not current workspace, don't map it (will be mapped when switching to that workspace)
    } else {
        // No rule matched - use default behavior (add to current workspace)
        workspaces.addWindowToCurrentWorkspace(wm, window_id);
        _ = xcb.xcb_map_window(wm.conn, window_id);
        if (wm.config.tiling.enabled) {
            tiling.notifyWindowMapped(wm, window_id);
        }
    }
}

/// Handle window configure requests - resize/move floating windows
fn handleConfigureRequest(event: *anyopaque, wm: *WM) void {
    const e: *const xcb.xcb_configure_request_event_t = @ptrCast(@alignCast(event));
    log.debugWindowConfigure(e.window, e.width, e.height, e.x, e.y);

    // Let tiling module handle tiled windows, we only handle floating
    if (wm.config.tiling.enabled and tiling.isWindowTiled(e.window)) return;

    // Apply requested configuration for floating windows
    _ = xcb.xcb_configure_window(wm.conn, e.window, e.value_mask, &[_]u32{
        @intCast(e.x),
        @intCast(e.y),
        @intCast(e.width),
        @intCast(e.height),
        @intCast(e.border_width),
    });
}

/// Handle mouse entering window - focus follows mouse
fn handleEnterNotify(event: *anyopaque, wm: *WM) void {
    const e: *const xcb.xcb_enter_notify_event_t = @ptrCast(@alignCast(event));

    // Ignore root window and null windows
    if (e.event == wm.root or e.event == 0) return;

    // Use centralized focus management
    focus.setFocus(wm, e.event, .mouse_enter);
    log.debugWindowFocusChanged(e.event);
}

/// Handle window destruction - clean up and refocus
fn handleDestroyNotify(event: *anyopaque, wm: *WM) void {
    const e: *const xcb.xcb_destroy_notify_event_t = @ptrCast(@alignCast(event));
    log.debugWindowDestroyed(e.window);

    const was_focused = wm.focused_window == e.window;
    wm.removeWindow(e.window);

    // If we just destroyed the focused window, focus another one
    if (was_focused) {
        wm.focused_window = null;

        // Try to focus any remaining window
        var iter = wm.windows.keyIterator();
        if (iter.next()) |window_id| {
            focus.setFocus(wm, window_id.*, .window_destroyed);
        }
    }
}
