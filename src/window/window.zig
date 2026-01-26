//! Core window event handlers.

const std = @import("std");
const defs = @import("defs");
const xcb = defs.xcb;
const WM = defs.WM;
const utils = @import("utils");
const tiling = @import("tiling");
const workspaces = @import("workspaces");
const focus = @import("focus");
const atomic = @import("atomic");

pub fn init(_: *WM) void {}
pub fn deinit(_: *WM) void {}

pub fn handleMapRequest(event: *const xcb.xcb_map_request_event_t, wm: *WM) void {
    const win = event.window;

    const target_ws = if (wm.config.workspaces.rules.items.len > 0)
        matchWorkspaceRule(wm, win)
    else
        null;

    const current_ws = workspaces.getCurrentWorkspace() orelse 0;

    const validated_target_ws = if (target_ws) |ws| blk: {
        const ws_state = workspaces.getState() orelse break :blk current_ws;
        if (ws >= ws_state.workspaces.len) {
            std.log.warn("[window] Rule target workspace {} exceeds count {}, using current workspace", .{ ws, ws_state.workspaces.len });
            break :blk current_ws;
        }
        break :blk ws;
    } else current_ws;

    if (validated_target_ws != current_ws) {
        _ = xcb.xcb_map_window(wm.conn, win);

        workspaces.moveWindowTo(wm, win, validated_target_ws);

        if (wm.config.tiling.enabled) {
            const attrs = utils.WindowAttrs{
                .border_width = wm.config.tiling.border_width,
                .border_color = wm.config.tiling.border_normal,
                .event_mask = xcb.XCB_EVENT_MASK_ENTER_WINDOW | xcb.XCB_EVENT_MASK_LEAVE_WINDOW,
            };
            attrs.configure(wm.conn, win);

            if (tiling.getState()) |t_state| {
                t_state.window_borders.put(win, wm.config.tiling.border_normal) catch {};
            }
        }

        _ = xcb.xcb_unmap_window(wm.conn, win);

        utils.flush(wm.conn);
        return;
    }

    atomic.atomicMapWindow(wm, win, validated_target_ws) catch |err| {
        std.log.err("[window] Failed to map window {} atomically: {}", .{ win, err });
        return;
    };

    if (wm.config.tiling.enabled) {
        const attrs = utils.WindowAttrs{
            .border_width = wm.config.tiling.border_width,
            .border_color = wm.config.tiling.border_focused,
            .event_mask = xcb.XCB_EVENT_MASK_ENTER_WINDOW | xcb.XCB_EVENT_MASK_LEAVE_WINDOW,
        };
        attrs.configure(wm.conn, win);

        if (tiling.getState()) |t_state| {
            t_state.window_borders.put(win, wm.config.tiling.border_focused) catch {};
        }

        focus.setFocus(wm, win, .tiling_operation);
        tiling.retileCurrentWorkspace(wm);
    } else {
        utils.flush(wm.conn);
    }
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
}

pub fn handleEnterNotify(event: *const xcb.xcb_enter_notify_event_t, wm: *WM) void {
    if (event.event == wm.root or event.event == 0) return;

    focus.setFocus(wm, event.event, .mouse_enter);
}

pub fn handleDestroyNotify(event: *const xcb.xcb_destroy_notify_event_t, wm: *WM) void {
    const win = event.window;

    atomic.atomicDestroyWindow(wm, win) catch |err| {
        std.log.err("[window] Failed to destroy window {} atomically: {}", .{ win, err });
    };

    wm.removeWindow(win);

    if (wm.config.tiling.enabled) {
        tiling.retileCurrentWorkspace(wm);
    }
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
