//! Window event handlers - MINIMAL: Instant spawning, immediate flushing

const std = @import("std");
const defs = @import("defs");
const xcb = defs.xcb;
const WM = defs.WM;
const utils = @import("utils");
const tiling = @import("tiling");
const workspaces = @import("workspaces");
const bar = @import("bar");
const batch = @import("batch");

pub fn init(_: *WM) void {}
pub fn deinit(_: *WM) void {}

pub fn handleMapRequest(event: *const xcb.xcb_map_request_event_t, wm: *WM) void {
    const win = event.window;

    if (bar.isBarWindow(win)) {
        _ = xcb.xcb_map_window(wm.conn, win);
        utils.flush(wm.conn);  // Flush immediately
        return;
    }

    const target_ws = if (wm.config.workspaces.rules.items.len > 0)
        matchWorkspaceRule(wm, win)
    else
        null;

    const current_ws = workspaces.getCurrentWorkspace() orelse 0;

    const validated_target_ws = if (target_ws) |ws| blk: {
        const ws_state = workspaces.getState() orelse break :blk current_ws;
        if (ws >= ws_state.workspaces.len) {
            std.log.warn("[window] Rule workspace {} exceeds count, using current {}", .{ ws, current_ws });
            break :blk current_ws;
        }
        break :blk ws;
    } else current_ws;

    // Map window immediately
    _ = xcb.xcb_map_window(wm.conn, win);
    wm.addWindow(win) catch {};

    if (validated_target_ws == current_ws) {
        workspaces.addWindowToCurrentWorkspace(wm, win);
    } else {
        workspaces.moveWindowTo(wm, win, validated_target_ws);
    }

    // Set up tiling immediately
    if (wm.config.tiling.enabled and validated_target_ws == current_ws) {
        _ = xcb.xcb_configure_window(wm.conn, win, xcb.XCB_CONFIG_WINDOW_BORDER_WIDTH, 
            &[_]u32{wm.config.tiling.border_width});
        _ = xcb.xcb_change_window_attributes(wm.conn, win, xcb.XCB_CW_BORDER_PIXEL, 
            &[_]u32{wm.config.tiling.border_normal});
        
        tiling.addWindow(wm, win);  // This marks dirty and will retile in main loop
    }

    bar.markDirty();
    utils.flush(wm.conn);  // Flush immediately
}

pub fn handleConfigureRequest(event: *const xcb.xcb_configure_request_event_t, wm: *WM) void {
    if (wm.config.tiling.enabled and tiling.isWindowTiled(event.window)) return;

    _ = xcb.xcb_configure_window(wm.conn, event.window, event.value_mask, &[_]u32{
        @intCast(event.x),
        @intCast(event.y),
        @intCast(event.width),
        @intCast(event.height),
        @intCast(event.border_width),
    });
    utils.flush(wm.conn);  // Flush immediately
}

pub fn handleEnterNotify(event: *const xcb.xcb_enter_notify_event_t, wm: *WM) void {
    if (event.event == wm.root or event.event == 0) return;
    if (bar.isBarWindow(event.event)) return;
    if (utils.isProtected()) return;

    const old_focus = wm.focused_window;
    utils.setFocus(wm, event.event, false);

    tiling.updateWindowFocus(wm, old_focus, event.event);  // This flushes
}

pub fn handleDestroyNotify(event: *const xcb.xcb_destroy_notify_event_t, wm: *WM) void {
    const win = event.window;

    if (bar.isBarWindow(win)) return;

    if (wm.config.tiling.enabled) {
        tiling.removeWindow(wm, win);
    }

    workspaces.removeWindow(win);
    wm.removeWindow(win);

    if (wm.focused_window == win) {
        utils.clearFocus(wm);
    }

    bar.markDirty();
    utils.flush(wm.conn);  // Flush immediately
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
