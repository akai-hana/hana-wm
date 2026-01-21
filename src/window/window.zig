//! Core window event handlers.

const std = @import("std");
const defs = @import("defs");
const xcb = defs.xcb;
const WM = defs.WM;
const utils = @import("utils");
const tiling = @import("tiling");
const workspaces = @import("workspaces");
const focus = @import("focus");

pub fn init(_: *WM) void {}
pub fn deinit(_: *WM) void {}

pub fn handleMapRequest(event: *const xcb.xcb_map_request_event_t, wm: *WM) void {
    const win = event.window;

    const target_ws = if (wm.config.workspaces.rules.items.len > 0)
        matchWorkspaceRule(wm, win)
    else
        null;

    const current_ws = workspaces.getCurrentWorkspace() orelse 0;

    if (target_ws) |ws| {
        if (ws != current_ws) {
            workspaces.moveWindowTo(wm, win, ws);

            if (wm.config.tiling.enabled) {
                const attrs = utils.WindowAttrs{
                    .border_width = wm.config.tiling.border_width,
                    .event_mask = xcb.XCB_EVENT_MASK_ENTER_WINDOW | xcb.XCB_EVENT_MASK_LEAVE_WINDOW,
                };
                attrs.configure(wm.conn, win);
            }

            utils.flush(wm.conn);
            return;
        }
    }

    workspaces.addWindowToCurrentWorkspace(wm, win);
    _ = xcb.xcb_map_window(wm.conn, win);

    if (wm.config.tiling.enabled) {
        tiling.notifyWindowMapped(wm, win);
    }

    focus.markLayoutOperation();
    utils.flush(wm.conn);
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
    if (focus.shouldSuppressMouseFocus()) return;
    if (hasQueuedEnterEvents(wm.conn)) return;

    focus.setFocus(wm, event.event, .mouse_enter);
}

fn hasQueuedEnterEvents(conn: *xcb.xcb_connection_t) bool {
    var count: u8 = 0;
    while (count < 2) : (count += 1) {
        const queued = xcb.xcb_poll_for_event(conn) orelse return count > 0;
        defer std.c.free(queued);
        const next_type = @as(*u8, @ptrCast(queued)).* & 0x7F;
        if (next_type != xcb.XCB_ENTER_NOTIFY) return count > 0;
    }
    return true;
}

pub fn handleDestroyNotify(event: *const xcb.xcb_destroy_notify_event_t, wm: *WM) void {
    const win = event.window;
    const was_focused = wm.focused_window == win;

    tiling.notifyWindowDestroyed(wm, win);
    workspaces.removeWindow(win);
    wm.removeWindow(win);

    if (was_focused) {
        wm.focused_window = null;

        if (workspaces.getCurrentWindowsView()) |ws_windows| {
            if (ws_windows.len > 0) {
                focus.setFocus(wm, ws_windows[0], .window_destroyed);
                return;
            }
        }

        focus.clearFocus(wm);
    }
}

fn matchWorkspaceRule(wm: *WM, win: u32) ?usize {
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
