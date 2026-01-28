//! Window dragging and resizing

const std = @import("std");
const defs = @import("defs");
const xcb = defs.xcb;
const WM = defs.WM;
const utils = @import("utils");
const tiling = @import("tiling");

const DragMode = enum { move, resize };

const DragState = struct {
    active: bool,
    window: u32,
    mode: DragMode,
    start_x: i16,
    start_y: i16,
    start_win_x: i16,
    start_win_y: i16,
    start_win_width: u16,
    start_win_height: u16,
};

var drag_state = DragState{
    .active = false,
    .window = 0,
    .mode = .move,
    .start_x = 0,
    .start_y = 0,
    .start_win_x = 0,
    .start_win_y = 0,
    .start_win_width = 0,
    .start_win_height = 0,
};

pub fn isDragging() bool {
    return drag_state.active;
}

pub fn startDrag(wm: *WM, win: u32, button: u8, x: i16, y: i16) void {
    if (drag_state.active) return;

    const geom = utils.getGeometry(wm.conn, win) orelse return;

    drag_state = .{
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

    utils.setFocus(wm, win, true);

    if (tiling.isWindowTiled(win) and wm.config.tiling.enabled) {
        tiling.removeWindow(wm, win);
    }
}

pub fn updateDrag(wm: *WM, x: i16, y: i16) void {
    if (!drag_state.active) return;

    const dx = x - drag_state.start_x;
    const dy = y - drag_state.start_y;

    switch (drag_state.mode) {
        .move => {
            const new_x = drag_state.start_win_x + dx;
            const new_y = drag_state.start_win_y + dy;

            const rect = utils.Rect{
                .x = new_x,
                .y = new_y,
                .width = drag_state.start_win_width,
                .height = drag_state.start_win_height,
            };

            utils.configureWindow(wm.conn, drag_state.window, rect);
        },
        .resize => {
            const new_width: i32 = @max(@as(i32, defs.MIN_WINDOW_DIM), @as(i32, drag_state.start_win_width) + dx);
            const new_height: i32 = @max(@as(i32, defs.MIN_WINDOW_DIM), @as(i32, drag_state.start_win_height) + dy);

            const rect = utils.Rect{
                .x = drag_state.start_win_x,
                .y = drag_state.start_win_y,
                .width = @intCast(new_width),
                .height = @intCast(new_height),
            };

            utils.configureWindow(wm.conn, drag_state.window, rect);
        },
    }

    utils.flush(wm.conn);
}

pub fn stopDrag(_: *WM) void {
    drag_state.active = false;
}
