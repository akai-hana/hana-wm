//! Window dragging and resizing

const std = @import("std");
const defs = @import("defs");
const xcb = defs.xcb;
const WM = defs.WM;
const utils = @import("utils");
const focus = @import("focus");
const tiling = @import("tiling");

pub fn startDrag(wm: *WM, win: u32, button: u8, x: i16, y: i16) void {
    if (wm.drag_state.active) return;

    const geom = utils.getGeometry(wm.conn, win) orelse return;

    wm.drag_state = .{
        .active = true,
        .window = win,
        .mode = if (button == 1) .move else .resize,
        .start_x = x,
        .start_y = y,
        .start_win_x = geom.x,
        .start_win_y = geom.y,
        .start_win_width = geom.width,
        .start_win_height = geom.height,
    };

    focus.setFocus(wm, win, .user_command);

    // Remove window from tiling if it's tiled
    if (tiling.isWindowTiled(win) and wm.config.tiling.enabled) {
        tiling.removeWindow(wm, win);
    }
}

pub fn updateDrag(wm: *WM, x: i16, y: i16) void {
    if (!wm.drag_state.active) return;

    const drag = &wm.drag_state;
    const dx = x - drag.start_x;
    const dy = y - drag.start_y;

    switch (drag.mode) {
        .move => {
            const rect = utils.Rect{
                .x = drag.start_win_x + dx,
                .y = drag.start_win_y + dy,
                .width = drag.start_win_width,
                .height = drag.start_win_height,
            };

            utils.configureWindow(wm.conn, drag.window, rect);
        },
        .resize => {
            const new_width: i32 = @max(@as(i32, defs.MIN_WINDOW_DIM), @as(i32, drag.start_win_width) + dx);
            const new_height: i32 = @max(@as(i32, defs.MIN_WINDOW_DIM), @as(i32, drag.start_win_height) + dy);

            const rect = utils.Rect{
                .x = drag.start_win_x,
                .y = drag.start_win_y,
                .width = @intCast(new_width),
                .height = @intCast(new_height),
            };

            utils.configureWindow(wm.conn, drag.window, rect);
        },
    }

    utils.flush(wm.conn);
}

pub fn stopDrag(wm: *WM) void {
    wm.drag_state.active = false;
}

pub fn isDragging(wm: *WM) bool {
    return wm.drag_state.active;
}
