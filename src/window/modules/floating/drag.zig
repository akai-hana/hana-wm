//! Window dragging and resizing via pointer button grabs.

const std        = @import("std");
const constants  = @import("constants");
const core       = @import("core");
const xcb        = core.xcb;
const utils      = @import("utils");
const focus      = @import("focus");
const build_options = @import("build_options");
const tiling        = if (build_options.has_tiling) @import("tiling") else struct {};
const bar        = @import("bar");
const fullscreen = @import("fullscreen");
const window     = @import("window");

/// Resolve snap_distance from config against screen width.
/// Percentage values are relative to screen width (the primary drag axis).
/// Returns 0 when snapping is disabled.
inline fn snapDistance() i32 {
    const sv = core.config.snap_distance;
    if (sv.value == 0) return 0;
    if (sv.is_percentage) {
        const sw: f32 = @floatFromInt(core.screen.width_in_pixels);
        return @intFromFloat(@round(sv.value / 100.0 * sw));
    }
    return @intFromFloat(@round(sv.value));
}

/// Compute the work area edges accounting for bar height/position.
/// The border width is subtracted from far edges and added to near edges so
/// that snap aligns the window's outer border flush with the boundary — X
/// positions the content area, so without this correction the window overlaps
/// the bar or screen edge by exactly one border width.
fn workArea() struct { left: i32, right: i32, top: i32, bottom: i32 } {
    const sw: i32  = core.screen.width_in_pixels;
    const sh: i32  = core.screen.height_in_pixels;
    const bh: i32  = if (bar.isVisible()) bar.getBarHeight() else 0;
    const bw2: i32 = @as(i32, window.getBorderWidth()) * 2;
    const bar_at_bottom = core.config.bar.vertical_position == .bottom;
    // Near edges: x,y is the outer border corner, so no offset needed —
    // the outer border sits flush with the boundary at 0 / bar_height.
    // Far edges: total footprint = pos + dim + 2*border_width, so to align
    // the outer border with the far boundary we subtract 2*border_width.
    return .{
        .left   = 0,
        .right  = sw - bw2,
        .top    = if (bar_at_bottom) 0 else bh,
        .bottom = (if (bar_at_bottom) sh - bh else sh) - bw2,
    };
}

/// Snap a window position on one axis.
///
/// Snapping engages when a window edge comes within `snap` pixels of a
/// work-area boundary. It disengages as soon as the raw position would push
/// the window edge past the boundary — the user is intentionally crossing it.
///
/// `pos`  — raw window origin on this axis
/// `dim`  — window size on this axis (width or height), excluding borders
/// `near` — work-area near boundary (left or top)
/// `far`  — work-area far boundary (right or bottom)
inline fn snapAxis(pos: i32, dim: i32, near: i32, far: i32, snap: i32) i32 {
    if (@abs(pos - near) < snap) return near;
    if (@abs((pos + dim) - far) < snap) return far - dim;
    return pos;
}

const State = struct {
    drag:          core.DragState = .{},
    pending_float: bool           = false,
};
var g_state: State = .{};

pub fn startDrag(win: u32, button: u8, x: i16, y: i16) void {
    if (g_state.drag.active) return;
    if (bar.isBarWindow(win)) return;
    // Fullscreen windows must not be drag-resized: they occupy the entire
    // screen and resizing them would corrupt their fullscreen geometry record.
    if (fullscreen.isFullscreen(win)) return;
    const geom = blk: {
        if (comptime build_options.has_tiling) {
            if (tiling.getWindowGeom(win)) |g| break :blk g;
        }
        break :blk utils.getGeometry(core.conn, win) orelse return;
    };
    g_state = .{
        .drag = .{
            .active           = true,
            .window           = win,
            .mode             = if (button == 1) .move else .resize,
            .start_x          = x,
            .start_y          = y,
            .start_win_x      = geom.x,
            .start_win_y      = geom.y,
            .start_win_width  = geom.width,
            .start_win_height = geom.height,
        },
        .pending_float = if (comptime build_options.has_tiling)
            tiling.isWindowTiled(win) and !tiling.isFloatingLayout()
        else
            false,
    };
    focus.setFocus(win, .user_command);
    _ = xcb.xcb_configure_window(core.conn, win,
        xcb.XCB_CONFIG_WINDOW_STACK_MODE, &[_]u32{xcb.XCB_STACK_MODE_ABOVE});
    _ = xcb.xcb_flush(core.conn);
}

pub fn updateDrag(x: i16, y: i16) void {
    if (!g_state.drag.active) return;
    const drag = &g_state.drag;

    const was_pending_float = g_state.pending_float;
    if (g_state.pending_float) {
        g_state.pending_float = false;
        _ = xcb.xcb_grab_server(core.conn);
        if (comptime build_options.has_tiling) {
            tiling.removeWindow(drag.window);
            tiling.retileCurrentWorkspace();
        }
        _ = xcb.xcb_ungrab_server(core.conn);
        _ = xcb.xcb_flush(core.conn);
    }

    const dx = x - drag.start_x;
    const dy = y - drag.start_y;
    const rect = switch (drag.mode) {
        .move => blk: {
            const raw_x: i32 = @as(i32, drag.start_win_x) + @as(i32, dx);
            const raw_y: i32 = @as(i32, drag.start_win_y) + @as(i32, dy);
            // Skip snap on the first motion after a tiled-to-float transition:
            // the tiled position may coincide with a screen edge, which would
            // make the window appear frozen on the first drag movement.
            if (was_pending_float) break :blk utils.Rect{
                .x      = @intCast(raw_x),
                .y      = @intCast(raw_y),
                .width  = drag.start_win_width,
                .height = drag.start_win_height,
            };
            const snap = snapDistance();
            const wa   = workArea();
            const win_w: i32 = drag.start_win_width;
            const win_h: i32 = drag.start_win_height;
            break :blk utils.Rect{
                .x      = @intCast(snapAxis(raw_x, win_w, wa.left, wa.right,  snap)),
                .y      = @intCast(snapAxis(raw_y, win_h, wa.top,  wa.bottom, snap)),
                .width  = drag.start_win_width,
                .height = drag.start_win_height,
            };
        },
        .resize => blk: {
            const raw_w: i32 = @max(constants.MIN_WINDOW_DIM, @as(i32, drag.start_win_width)  + @as(i32, dx));
            const raw_h: i32 = @max(constants.MIN_WINDOW_DIM, @as(i32, drag.start_win_height) + @as(i32, dy));
            const snap = snapDistance();
            const wa   = workArea();
            // Snap the trailing edges: right = origin_x + width, bottom = origin_y + height.
            const snapped_w: i32 = if (snap > 0 and @abs((@as(i32, drag.start_win_x) + raw_w) - wa.right)  < snap) wa.right  - drag.start_win_x else raw_w;
            const snapped_h: i32 = if (snap > 0 and @abs((@as(i32, drag.start_win_y) + raw_h) - wa.bottom) < snap) wa.bottom - drag.start_win_y else raw_h;
            break :blk utils.Rect{
                .x      = drag.start_win_x,
                .y      = drag.start_win_y,
                .width  = @intCast(@min(std.math.maxInt(u16), @max(constants.MIN_WINDOW_DIM, snapped_w))),
                .height = @intCast(@min(std.math.maxInt(u16), @max(constants.MIN_WINDOW_DIM, snapped_h))),
            };
        },
    };
    utils.configureWindow(core.conn, drag.window, rect);
    _ = xcb.xcb_flush(core.conn);
}

pub fn stopDrag() void {
    g_state = .{};
}

pub inline fn isDragging() bool { return g_state.drag.active; }
