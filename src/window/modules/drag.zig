//! Window dragging and resizing

const defs   = @import("defs");
const xcb    = defs.xcb;
const WM     = defs.WM;
const utils  = @import("utils");
const focus  = @import("focus");
const tiling = @import("tiling");
const bar    = @import("bar");

/// Apply an i16 delta to a u16 dimension, floored at MIN_WINDOW_DIM.
inline fn clampDim(base: u16, delta: i16) u16 {
    return @intCast(@max(@as(i32, defs.MIN_WINDOW_DIM), @as(i32, base) + delta));
}

pub fn startDrag(wm: *WM, win: u32, button: u8, x: i16, y: i16) void {
    if (wm.drag_state.active) return;
    if (bar.isBarWindow(win)) return;
    // Prefer the tiling cache; fall back to a live round-trip for floating windows.
    const geom = tiling.getCachedGeom(win) orelse
        utils.getGeometry(wm.conn, win) orelse return;
    wm.drag_state = .{
        .active           = true,
        .window           = win,
        .mode             = if (button == 1) .move else .resize,
        .start_x          = x,
        .start_y          = y,
        .start_win_x      = geom.x,
        .start_win_y      = geom.y,
        .start_win_width  = geom.width,
        .start_win_height = geom.height,
    };
    focus.setFocus(wm, win, .user_command);
    // Remove from tiling so the drag moves the window freely.
    // Wrap removal + retile in a grab to prevent a one-frame gap in the layout.
    if (tiling.isWindowTiled(win)) {
        _ = xcb.xcb_grab_server(wm.conn);
        tiling.removeWindow(win);
        tiling.retileCurrentWorkspace(wm);
        _ = xcb.xcb_ungrab_server(wm.conn);
        utils.flush(wm.conn);
    }
}

pub fn updateDrag(wm: *WM, x: i16, y: i16) void {
    if (!wm.drag_state.active) return;
    const drag = &wm.drag_state;
    const dx = x - drag.start_x;
    const dy = y - drag.start_y;
    const rect = switch (drag.mode) {
        .move => utils.Rect{
            .x      = drag.start_win_x + dx,
            .y      = drag.start_win_y + dy,
            .width  = drag.start_win_width,
            .height = drag.start_win_height,
        },
        .resize => utils.Rect{
            .x      = drag.start_win_x,
            .y      = drag.start_win_y,
            .width  = clampDim(drag.start_win_width,  dx),
            .height = clampDim(drag.start_win_height, dy),
        },
    };
    utils.configureWindow(wm.conn, drag.window, rect);
    utils.flush(wm.conn);
}

pub inline fn stopDrag(wm: *WM) void {
    wm.drag_state.active = false;
}

pub inline fn isDragging(wm: *WM) bool {
    return wm.drag_state.active;
}
