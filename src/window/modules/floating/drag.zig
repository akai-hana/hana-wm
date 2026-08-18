//! Window drag and resize
//! Handles interactive dragging and resizing of floating windows with the mouse.

const std = @import("std");

const core = @import("core");
const xcb = core.xcb;
const utils = @import("utils");

const window = @import("window");
const focus = @import("focus");

const build_options = @import("build_options");
const hooks = @import("hooks");
const bar = if (build_options.has_bar) @import("bar") else null;
const tiling = if (build_options.has_tiling) @import("tiling") else null;
const fullscreen = @import("fullscreen");

// Drag state

pub const DragMode = enum { move, resize };

/// Corner closest to the cursor at drag-start; the opposite corner is the
/// anchor that stays fixed during the resize. Crossing the anchor on an axis
/// wraps the resize to grow the opposite way instead of collapsing.
pub const ResizeCorner = enum { top_left, top_right, bottom_left, bottom_right };

const WorkArea = struct { left: i32, right: i32, top: i32, bottom: i32 };

pub const DragState = struct {
    active: bool = false,
    window: core.WindowId = 0,
    mode: DragMode = .move,
    resize_corner: ResizeCorner = .bottom_right,
    start_x: i16 = 0,
    start_y: i16 = 0,
    start_win_x: i16 = 0,
    start_win_y: i16 = 0,
    start_win_width: u16 = 0,
    start_win_height: u16 = 0,
    /// Geometry from the last updateDrag call. Zero means no motion event
    /// arrived; saved to the geometry cache by stopDrag on exit.
    last_rect: utils.Rect = .{ .x = 0, .y = 0, .width = 0, .height = 0 },
    /// Resolved once at drag start: snap distance in pixels (0 = disabled) and
    /// the work-area edges used for snapping. Both are constant for the whole
    /// drag, so re-resolving them on every motion event would be wasted work.
    snap_px: i32 = 0,
    work_area: WorkArea = .{ .left = 0, .right = 0, .top = 0, .bottom = 0 },
};

// Snapping

/// snap_distance from config, resolved to pixels (0 = disabled).
/// Percentages are relative to screen width.
fn snapDistance() i32 {
    const cs = core.getState();
    const sv = cs.config.snap_distance;
    if (sv.value == 0) return 0;
    const sw: f32 = @floatFromInt(cs.screen.width_in_pixels);
    return @intFromFloat(@round(utils.scaling.scaleToPixels(sv, sw)));
}

/// Work-area edges, accounting for the bar and border width. X positions a
/// window's content area, so far edges are pulled in by 2*border_width to
/// keep the outer border flush with the screen edge.
fn workArea() WorkArea {
    const cs = core.getState();
    const sw: i32 = cs.screen.width_in_pixels;
    const bw2: i32 = @as(i32, window.getBorderWidth()) * 2;
    const work = if (build_options.has_bar) bar.workAreaRect() else .{ .x = 0, .y = 0, .width = core.screen.width, .height = core.screen.height };
    return .{
        .left = 0,
        .right = sw - bw2,
        .top = work.y,
        .bottom = work.y + @as(i32, work.height) - bw2,
    };
}

/// Which sides of the window the grabbed corner anchors to (left/top = the
/// corner is a left or top edge). Collapses the four per-axis corner switches
/// in updateDrag into two booleans.
const CornerAxes = struct { left: bool, top: bool };

inline fn cornerAxes(corner: ResizeCorner) CornerAxes {
    return switch (corner) {
        .top_left => .{ .left = true, .top = true },
        .top_right => .{ .left = false, .top = true },
        .bottom_left => .{ .left = true, .top = false },
        .bottom_right => .{ .left = false, .top = false },
    };
}

/// Snap a window origin toward `near` or `far` when within `snap` pixels.
inline fn snapAxis(pos: i32, dim: i32, near: i32, far: i32, snap: i32) i32 {
    if (@abs(pos - near) < snap) return near;
    if (@abs((pos + dim) - far) < snap) return far - dim;
    return pos;
}

/// Snap a single edge toward `boundary` when within `snap` pixels of it.
inline fn snapEdge(edge: i32, boundary: i32, snap: i32) i32 {
    if (snap > 0 and @abs(edge - boundary) < snap) return boundary;
    return edge;
}

// Module state

const State = struct {
    drag: DragState = .{},
    pending_float: bool = false,
};

var g_state: State = .{};

// Public API

fn nearestCorner(x: i16, y: i16, geom: utils.Rect) ResizeCorner {
    const cx: i32 = @as(i32, geom.x) + @divTrunc(@as(i32, geom.width), 2);
    const cy: i32 = @as(i32, geom.y) + @divTrunc(@as(i32, geom.height), 2);
    if (x < cx and y < cy) return .top_left;
    if (x >= cx and y < cy) return .top_right;
    if (x < cx and y >= cy) return .bottom_left;
    return .bottom_right;
}

/// Begins a move (button 1) or resize (button 3) drag on `win` at (x, y).
/// No-op if a drag is already active, or for bar/fullscreen windows.
pub fn startDrag(win: u32, button: u8, x: i16, y: i16) void {
    const cs = core.getState();
    if (!cs.config.drag_enabled) return;
    if (g_state.drag.active) return;
    if ((if (build_options.has_bar) bar.isBarWindow(win) else false)) return;
    if (fullscreen.isFullscreen(win)) return; // fullscreen geometry must not be touched

    // Prefer the tiling cache (always current) over a live XCB round-trip;
    // fall back to a live query for floating windows the tiler never tracked.
    const geom = blk: {
        if (if (build_options.has_tiling) tiling.getWindowGeom(win) else null) |g| break :blk g;
        break :blk window.getGeometry(cs.conn, win) orelse return;
    };

    const resize_corner: ResizeCorner = if (button == 1) .bottom_right else nearestCorner(x, y, geom);

    // Snap distance and work area are resolved here so updateDrag's per-event
    // path only does arithmetic. They are constant for the duration of a drag.
    const snap_px = snapDistance();
    g_state = .{
        .drag = .{
            .active = true,
            .window = win,
            .mode = if (button == 1) .move else .resize,
            .resize_corner = resize_corner,
            .start_x = x,
            .start_y = y,
            .start_win_x = geom.x,
            .start_win_y = geom.y,
            .start_win_width = geom.width,
            .start_win_height = geom.height,
            .snap_px = snap_px,
            .work_area = if (snap_px > 0) workArea() else .{ .left = 0, .right = 0, .top = 0, .bottom = 0 },
        },
        // A tiled window in a non-floating layout detaches on first motion
        // (see updateDrag); move also skips snap on that first event so the
        // window doesn't appear frozen at a tiled edge.
        .pending_float = (if (build_options.has_tiling) tiling.isWindowTiled(win) else false) and !(if (build_options.has_tiling) tiling.isFloatingLayout() else false),
    };
    focus.setFocus(win, .user_command);
    utils.raiseWindow(cs.conn, win);
    _ = xcb.xcb_flush(cs.conn);
}

fn computeMoveRect(drag: DragState, dx: i16, dy: i16, wa: WorkArea, was_pending_float: bool) utils.Rect {
    const snap = drag.snap_px;
    const raw_x: i32 = @as(i32, drag.start_win_x) + @as(i32, dx);
    const raw_y: i32 = @as(i32, drag.start_win_y) + @as(i32, dy);
    const win_w: i32 = drag.start_win_width;
    const win_h: i32 = drag.start_win_height;
    return .{
        .x = @intCast(if (was_pending_float) raw_x else snapAxis(raw_x, win_w, wa.left, wa.right, snap)),
        .y = @intCast(if (was_pending_float) raw_y else snapAxis(raw_y, win_h, wa.top, wa.bottom, snap)),
        .width = drag.start_win_width,
        .height = drag.start_win_height,
    };
}

fn computeResizeRect(drag: DragState, dx: i16, dy: i16, wa: WorkArea) utils.Rect {
    const snap = drag.snap_px;
    // Anchor = corner opposite the grabbed one, fixed; the moving
    // corner follows the cursor. min/max(anchor, moving) per axis
    // makes crossing the anchor flip growth automatically.
    const axes = cornerAxes(drag.resize_corner);
    const start_x: i32 = drag.start_win_x;
    const start_y: i32 = drag.start_win_y;
    const start_w: i32 = drag.start_win_width;
    const start_h: i32 = drag.start_win_height;

    const anchor_x: i32 = start_x + @as(i32, if (axes.left) start_w else 0);
    const anchor_y: i32 = start_y + @as(i32, if (axes.top) start_h else 0);
    const moving_x0: i32 = start_x + @as(i32, if (axes.left) 0 else start_w);
    const moving_y0: i32 = start_y + @as(i32, if (axes.top) 0 else start_h);

    const raw_moving_x: i32 = moving_x0 + @as(i32, dx);
    const raw_moving_y: i32 = moving_y0 + @as(i32, dy);
    const moving_x: i32 = snapEdge(snapEdge(raw_moving_x, wa.left, snap), wa.right, snap);
    const moving_y: i32 = snapEdge(snapEdge(raw_moving_y, wa.top, snap), wa.bottom, snap);

    const new_left: i32 = @min(anchor_x, moving_x);
    const new_right: i32 = @max(anchor_x, moving_x);
    const new_top: i32 = @min(anchor_y, moving_y);
    const new_bottom: i32 = @max(anchor_y, moving_y);

    // Clamp size first, then re-pin position off the anchor so the
    // anchor edge never drifts when the minimum size is hit.
    const min_dim: i32 = core.getState().config.tiling.min_window_dim;
    const clamped_w: i32 = std.math.clamp(new_right - new_left, min_dim, std.math.maxInt(u16));
    const clamped_h: i32 = std.math.clamp(new_bottom - new_top, min_dim, std.math.maxInt(u16));
    const pinned_x: i32 = if (moving_x < anchor_x) anchor_x - clamped_w else new_left;
    const pinned_y: i32 = if (moving_y < anchor_y) anchor_y - clamped_h else new_top;

    return .{
        .x = @intCast(pinned_x),
        .y = @intCast(pinned_y),
        .width = @intCast(clamped_w),
        .height = @intCast(clamped_h),
    };
}

/// Applies pointer motion to the active drag. No-op if no drag is active.
pub fn updateDrag(x: i16, y: i16) void {
    if (!g_state.drag.active) return;
    const drag = &g_state.drag;

    const was_pending_float = g_state.pending_float;
    if (g_state.pending_float) {
        g_state.pending_float = false;
        const conn = core.getState().conn;
        utils.grabServer(conn);
        if (build_options.has_tiling) tiling.removeWindow(drag.window);
        if (build_options.has_tiling) tiling.retileCurrentWorkspace();
        utils.ungrabAndFlush(conn);
    }

    const dx = x - drag.start_x;
    const dy = y - drag.start_y;
    const wa = drag.work_area;

    const rect = switch (drag.mode) {
        .move => computeMoveRect(drag.*, dx, dy, wa, was_pending_float),
        .resize => computeResizeRect(drag.*, dx, dy, wa),
    };
    drag.last_rect = rect;
    const conn = core.getState().conn;
    utils.configureWindow(conn, drag.window, rect);
    _ = xcb.xcb_flush(conn);
}

/// Ends the active drag, saving the final geometry so workspace-switch
/// float-restore finds the drag-moved position.
pub fn stopDrag() void {
    const drag = &g_state.drag;
    if (drag.active and drag.last_rect.width != 0) {
        window.saveWindowGeom(drag.window, drag.last_rect);
    }
    g_state = .{};
}

/// Clears the active drag if it targets `win`, without saving geometry. Used
/// when the dragged window is destroyed mid-drag; a lost ButtonRelease would
/// otherwise leave the drag stuck until the WM restarts, and there's no
/// geometry to persist for a dead window.
pub fn cancelDragForWindow(win: u32) void {
    if (g_state.drag.active and g_state.drag.window == win) g_state = .{};
}

pub fn isDragging() bool {
    return g_state.drag.active;
}

/// True when a resize drag is active on `win`; used to deny min-size
/// configure requests from the window being resized, preventing flicker.
pub fn isResizingWindow(win: u32) bool {
    return g_state.drag.active and g_state.drag.mode == .resize and g_state.drag.window == win;
}

/// Rect last applied during the active drag. Only meaningful while
/// isDragging() and after at least one motion event.
pub fn getDragLastRect() utils.Rect {
    return g_state.drag.last_rect;
}

pub const plugin = hooks.Plugin{};
