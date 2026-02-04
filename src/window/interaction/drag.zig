///! Window dragging and resizing - OPTIMIZED with throttling

const std = @import("std");
const defs = @import("defs");
const xcb = defs.xcb;
const WM = defs.WM;
const utils = @import("utils");
const focus = @import("focus");
const tiling = @import("tiling");

// OPTIMIZATION: Throttle drag updates to reduce XCB overhead
const DRAG_UPDATE_EVERY_N_FRAMES = 2; // Update every 2nd frame (~120Hz on 240Hz mouse)

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
    if (wm.config.tiling.enabled and tiling.isWindowTiled(win)) {
        tiling.removeWindow(wm, win);
    }
    
    // Reset frame counter
    frame_counter = 0;
}

// OPTIMIZATION: Throttled drag updates with deferred flushing
var frame_counter: u32 = 0;
var pending_update: bool = false;
var pending_rect: utils.Rect = undefined;
var pending_window: u32 = 0;

pub fn updateDrag(wm: *WM, x: i16, y: i16) void {
    if (!wm.drag_state.active) return;

    const drag = &wm.drag_state;
    const dx = x - drag.start_x;
    const dy = y - drag.start_y;

    // OPTIMIZATION: Build rect inline to avoid duplication
    const rect = switch (drag.mode) {
        .move => utils.Rect{
            .x = drag.start_win_x + dx,
            .y = drag.start_win_y + dy,
            .width = drag.start_win_width,
            .height = drag.start_win_height,
        },
        .resize => utils.Rect{
            .x = drag.start_win_x,
            .y = drag.start_win_y,
            .width = @intCast(@max(@as(i32, defs.MIN_WINDOW_DIM), @as(i32, drag.start_win_width) + dx)),
            .height = @intCast(@max(@as(i32, defs.MIN_WINDOW_DIM), @as(i32, drag.start_win_height) + dy)),
        },
    };

    // OPTIMIZATION: Frame-based throttling to reduce XCB overhead
    frame_counter += 1;
    
    if (frame_counter >= DRAG_UPDATE_EVERY_N_FRAMES) {
        // Enough frames have passed - send update immediately
        utils.configureWindow(wm.conn, drag.window, rect);
        utils.flush(wm.conn);
        frame_counter = 0;
        pending_update = false;
    } else {
        // Too soon - store pending update (will be sent on stop or next threshold)
        pending_update = true;
        pending_rect = rect;
        pending_window = drag.window;
    }
}

pub inline fn stopDrag(wm: *WM) void {
    // OPTIMIZATION: Flush any pending drag update before stopping
    if (pending_update and wm.drag_state.active) {
        utils.configureWindow(wm.conn, pending_window, pending_rect);
        utils.flush(wm.conn);
        pending_update = false;
    }
    
    wm.drag_state.active = false;
    frame_counter = 0;
}

pub inline fn isDragging(wm: *WM) bool {
    return wm.drag_state.active;
}

// OPTIMIZATION: Allow manual flush of pending updates (e.g., before workspace switch)
pub inline fn flushPendingUpdate(wm: *WM) void {
    if (pending_update and wm.drag_state.active) {
        utils.configureWindow(wm.conn, pending_window, pending_rect);
        utils.flush(wm.conn);
        pending_update = false;
        frame_counter = 0;
    }
}
