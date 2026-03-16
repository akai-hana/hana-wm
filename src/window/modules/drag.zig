//! Window dragging and resizing via pointer button grabs.

const std       = @import("std");
const constants = @import("constants");
const core = @import("core");
const xcb       = core.xcb;
const utils     = @import("utils");
const focus     = @import("focus");
const tiling    = @import("tiling");
const bar       = @import("bar");

// Apply an i16 delta to a u16 dimension, clamped to [MIN_WINDOW_DIM, u16_MAX].
// Without the upper clamp, base=65535 + delta=32767 = 98302 overflows u16 and
// panics in safe builds.
inline fn clampDim(base: u16, delta: i16) u16 {
    return @intCast(@min(
        @as(i32, std.math.maxInt(u16)),
        @max(@as(i32, constants.MIN_WINDOW_DIM), @as(i32, base) + @as(i32, delta)),
    ));
}

// Module-level drag state. Lives here instead of WM so drag.zig is the
// single owner — consistent with the module-g_state pattern used elsewhere.
var g_drag: core.DragState = .{};

// Deferred float flag: true when the dragged window was tiled at press time
// and has not yet been removed from the tiling pool.  The removal is deferred
// until the first real motion event so that a quick Mod+click that never moves
// the cursor does not accidentally float the window.
var g_pending_float: bool = false;

pub fn startDrag(win: u32, button: u8, x: i16, y: i16) void {
    if (g_drag.active) return;
    if (bar.isBarWindow(win)) return;
    // Prefer the tiling cache; fall back to a live round-trip for floating windows.
    const geom = tiling.getWindowGeom(win) orelse
        utils.getGeometry(core.conn, win) orelse return;
    g_drag = .{
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
    focus.setFocus(win, .user_command);
    // Float conversion is deferred to the first motion event.
    // Record whether the window needs it so updateDrag can act on first move.
    g_pending_float = tiling.isWindowTiled(win);
}

pub fn updateDrag(x: i16, y: i16) void {
    if (!g_drag.active) return;
    const drag = &g_drag;

    // First real motion: now commit the float conversion.  Doing it here
    // rather than in startDrag means a Mod+click that never moves the cursor
    // leaves the window tiled, as if the click never happened.
    if (g_pending_float) {
        g_pending_float = false;
        _ = xcb.xcb_grab_server(core.conn);
        tiling.removeWindow(drag.window);
        tiling.retileCurrentWorkspace();
        _ = xcb.xcb_ungrab_server(core.conn);
        _ = xcb.xcb_flush(core.conn);
    }

    const dx = x - drag.start_x;
    const dy = y - drag.start_y;
    const rect = switch (drag.mode) {
        .move => utils.Rect{
            .x      = drag.start_win_x + dx,
            .y      = drag.start_win_y + dy,
            .width  = drag.start_win_width,
            .height = drag.start_win_height,
        },
        // Resize anchors to the window's top-left: position is fixed while
        // width and height grow with the drag delta.
        .resize => utils.Rect{
            .x      = drag.start_win_x,
            .y      = drag.start_win_y,
            .width  = clampDim(drag.start_win_width,  dx),
            .height = clampDim(drag.start_win_height, dy),
        },
    };
    utils.configureWindow(core.conn, drag.window, rect);
    _ = xcb.xcb_flush(core.conn);
}

pub fn stopDrag() void {
    // If the button was released before any motion, g_pending_float is still
    // set — discard it so the window stays tiled.
    g_pending_float = false;
    g_drag.active = false;
}

pub inline fn isDragging() bool { return g_drag.active; }
