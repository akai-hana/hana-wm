//! Floating window subsystem.
//! A self-contained plugin over the model: placement, dragging, and
//! per-corner resizing of floating windows, plus floating geometry honoring
//! (configure requests update the model's floating rect).

const std = @import("std");

const core = @import("core");
const xcb = core.xcb;
const utils = @import("utils");

const window = @import("window");
const borders = @import("borders");
const focus = @import("focus");
const tracking = @import("tracking");

const pipeline = @import("pipeline");
const actions = @import("actions");
const screen = @import("screen");

const model = @import("model");
const build_options = @import("build_options");

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
    /// arrived; consumed by the resize ConfigureRequest deny while the
    /// drag is active.
    last_rect: utils.Rect = .{ .x = 0, .y = 0, .width = 0, .height = 0 },
    /// Resolved once at drag start: snap distance in pixels (0 = disabled) and
    /// the work-area edges used for snapping. Both are constant for the whole
    /// drag, so re-resolving them on every motion event would be wasted work.
    snap_px: i32 = 0,
    work_area: WorkArea = .{ .left = 0, .right = 0, .top = 0, .bottom = 0 },
};

/// Snap distance from config, resolved to pixels (0 = disabled).
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
    const bw2: i32 = @as(i32, borders.width()) * 2;
    const work = screen.workArea(cs.screen);
    return .{
        .left = 0,
        .right = sw - bw2,
        .top = work.y,
        .bottom = work.y + @as(i32, work.height) - bw2,
    };
}

/// 8-directional resize direction nearest the cursor at a given point.
pub const ResizeDirection = enum { none, n, s, e, w, ne, nw, se, sw };

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

inline fn snapAxis(pos: i32, dim: i32, near: i32, far: i32, snap: i32) i32 {
    if (@abs(pos - near) < snap) return near;
    if (@abs((pos + dim) - far) < snap) return far - dim;
    return pos;
}

inline fn snapEdge(edge: i32, boundary: i32, snap: i32) i32 {
    if (snap > 0 and @abs(edge - boundary) < snap) return boundary;
    return edge;
}

const State = struct {
    drag: DragState = .{},
    pending_float: bool = false,
};

var g_state: State = .{};

/// Determines the resize direction from a cursor point relative to a window
/// rectangle and border width. Returns the 8-directional direction the cursor
/// is closest to (n, s, e, w, ne, nw, se, sw), or none if the point is well
/// inside the window far from any edge.
pub fn resizeDirectionFromPoint(cursor_x: i32, cursor_y: i32, rect: utils.Rect, border_width: u32) ResizeDirection {
    const left: i32 = rect.x;
    const top: i32 = rect.y;
    const right: i32 = rect.x + @as(i32, rect.width);
    const bottom: i32 = rect.y + @as(i32, rect.height);
    const bw: i32 = @intCast(border_width);

    const near_left = @abs(cursor_x - left) <= bw;
    const near_right = @abs(cursor_x - right) <= bw;
    const near_top = @abs(cursor_y - top) <= bw;
    const near_bottom = @abs(cursor_y - bottom) <= bw;

    if (near_left and near_top) return .nw;
    if (near_right and near_top) return .ne;
    if (near_left and near_bottom) return .sw;
    if (near_right and near_bottom) return .se;
    if (near_top) return .n;
    if (near_bottom) return .s;
    if (near_left) return .w;
    if (near_right) return .e;
    return .none;
}

/// Maps an 8-directional ResizeDirection to the 4-corner ResizeCorner used by
/// the resize engine. For cardinal directions the choice of corner is arbitrary
/// (e.g. n and s both anchor at bottom/top respectively) since only one axis
/// is constrained.
fn directionToCorner(dir: ResizeDirection) ResizeCorner {
    return switch (dir) {
        .nw => .top_left,
        .ne => .top_right,
        .sw => .bottom_left,
        .se => .bottom_right,
        .n, .w => .top_left,
        .s, .e => .bottom_right,
        .none => .bottom_right,
    };
}

fn nearestCorner(x: i16, y: i16, geom: utils.Rect, border_width: u32) ResizeCorner {
    const dir = resizeDirectionFromPoint(x, y, geom, border_width);
    return directionToCorner(dir);
}

/// Begins a move (button 1) or resize (button 3) drag on `win` at (x, y).
/// No-op if a drag is already active, or for bar/fullscreen windows.
pub fn startDrag(win: u32, button: u8, x: i16, y: i16) void {
    const cs = core.getState();
    if (!cs.config.drag_enabled) return;
    if (g_state.drag.active) return;
    if (screen.isSurfaceWindow(win)) return;
    if (build_options.has_fullscreen) {
        if (@import("fullscreen").isFullscreenMode(pipeline.model(), win)) return; // fullscreen geometry must not be touched
    }

    // Model/sync truth (floating base or last-sent rect) over a live XCB
    // round-trip; fall back to a live query when never placed.
    const geom = blk: {
        if (@import("sync").truthRect(pipeline.model(), win)) |g| break :blk g;
        break :blk window.getGeometry(cs.conn, win) orelse return;
    };

    const resize_corner: ResizeCorner = if (button == 1) .bottom_right else nearestCorner(x, y, geom, core.borderWidth());

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
        // A base-tiled window detaches to floating on first motion (see
        // updateDrag); move also skips snap on that first event so the
        // window doesn't appear frozen at a tiled edge.
        .pending_float = tracking.isTiledMode(win),
    };
    focus.grabFocus(win, .user_command);
    utils.raiseWindow(cs.conn, win);
    _ = xcb.xcb_flush(cs.conn);
}

fn computeMoveRect(drag: DragState, dx: i16, dy: i16, wa: WorkArea, was_pending_float: bool) utils.Rect {
    const snap = drag.snap_px;
    const raw_x: i32 = @as(i32, drag.start_win_x) + @as(i32, dx);
    const raw_y: i32 = @as(i32, drag.start_win_y) + @as(i32, dy);
    const win_w: i32 = drag.start_win_width;
    const win_h: i32 = drag.start_win_height;
    // Raw drag coords are unbounded i32; pin down to the i16 wire range
    // before the narrowing cast so a window dragged beyond +/-32767 (or into
    // negative X11 coords) can't UB in ReleaseFast.
    const mx: i32 = std.math.clamp(if (was_pending_float) raw_x else snapAxis(raw_x, win_w, wa.left, wa.right, snap), std.math.minInt(i16), std.math.maxInt(i16));
    const my: i32 = std.math.clamp(if (was_pending_float) raw_y else snapAxis(raw_y, win_h, wa.top, wa.bottom, snap), std.math.minInt(i16), std.math.maxInt(i16));
    return .{
        .x = @intCast(mx),
        .y = @intCast(my),
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
        .x = @intCast(std.math.clamp(pinned_x, std.math.minInt(i16), std.math.maxInt(i16))),
        .y = @intCast(std.math.clamp(pinned_y, std.math.minInt(i16), std.math.maxInt(i16))),
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
        actions.detachToFloating(drag.window);
    }

    const dx = x - drag.start_x;
    const dy = y - drag.start_y;
    const wa = drag.work_area;

    const rect = switch (drag.mode) {
        .move => computeMoveRect(drag.*, dx, dy, wa, was_pending_float),
        .resize => computeResizeRect(drag.*, dx, dy, wa),
    };
    drag.last_rect = rect;
    actions.dragRect(drag.window, rect);
}

/// Ends the active drag. The model floating rect already holds the final
/// position (actions.dragRect ran on every tick); nothing else to record;
/// the sync ledger is the wire truth.
pub fn stopDrag() void {
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

/// Updates a floating window's rect on the model, no-op for tiled/unknown.
pub fn setFloatingRect(m: *model.Model, win: model.WindowId, r: utils.Rect) void {
    const e = m.store.getPtr(win) orelse return;
    if (e.presence == .covering) return; // fullscreen owns geometry
    if (e.anchor == .floating) {
        e.anchor.floating = r;
    }
}

/// Honors a configure request against a floating window record on the model.
pub fn honorConfigureRequest(m: *model.Model, win: model.WindowId, req: model.ConfigureReq) model.HonorDecision {
    if (build_options.has_minimize) {
        if (@import("minimize").isMinimized(m, win)) return .ignored;
    }
    const e = m.store.getPtr(win) orelse return .ignored;
    if (e.presence == .covering) return .ignored; // fullscreen owns geometry
    switch (e.anchor) {
        .floating => |*r| {
            if (req.x) |v| r.x = v;
            if (req.y) |v| r.y = v;
            if (req.width) |v| r.width = v;
            if (req.height) |v| r.height = v;
            // NOTE: a requested border_width is not stored here (the
            // floating rect has no bw field); the entry point sends and
            // caches it alongside the geometry it applies.
            return .geometry_applied;
        },
        .tiled => {
            // Geometry denied. BW honored; recording is SYNC's job.
            if (req.border_width != null) return .border_only;
            return .ignored;
        },
    }
}

/// This module's window sub-system contribution: the floating drag/resize
/// commands floating owns.
pub const module: @import("plugin").WindowModule = .{
    .startDrag = startDrag,
    .stopDrag = stopDrag,
    .updateDrag = updateDrag,
    .isDragging = isDragging,
    .isResizingWindow = isResizingWindow,
    .getDragLastRect = getDragLastRect,
    .cancelDragForWindow = cancelDragForWindow,
    .setFloatingRect = setFloatingRect,
    .honorConfigureRequest = honorConfigureRequest,
};
