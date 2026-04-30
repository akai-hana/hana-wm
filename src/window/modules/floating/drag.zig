//! Window drag and resize
//! Handles interactive dragging and resizing of floating windows with the mouse.

const std   = @import("std");
const build = @import("build_options");

const core      = @import("core");
    const xcb   = core.xcb;
const constants = @import("constants");
const utils     = @import("utils");

const window = @import("window");
const focus  = @import("focus");

const tiling     = if (build.has_tiling) @import("tiling");
const fullscreen = if (build.has_fullscreen) @import("fullscreen");


const bar = if (build.has_bar) @import("bar") else struct {
    pub fn isVisible() bool { return false; }
    pub fn getBarHeight() u16 { return 0; }
    pub fn isBarWindow(_: u32) bool { return false; }
};

// Drag state types

pub const DragMode = enum { move, resize };

/// Which corner of the window is being dragged during a resize.
///
/// Determined at drag-start by comparing the cursor position to the window
/// centre.  The chosen corner is the one closest to the cursor:
///
///   top_left     | top_right
///   -------------|------------
///   bottom_left  | bottom_right
///
/// During updateDrag the opposite (anchor) corner is held fixed.  The window
/// always spans from min→max of anchor and current cursor, so when the cursor
/// crosses the anchor horizontally or vertically the resize wraps: the window
/// begins growing toward the opposite side instead of collapsing.  The
/// effective dragged corner therefore mirrors itself across the midpoint.
pub const ResizeCorner = enum { top_left, top_right, bottom_left, bottom_right };

pub const DragState = struct {
    active:           bool          = false,
    window:           core.WindowId = 0,
    mode:             DragMode      = .move,
    resize_corner:    ResizeCorner  = .bottom_right,
    start_x:          i16           = 0,
    start_y:          i16           = 0,
    start_win_x:      i16           = 0,
    start_win_y:      i16           = 0,
    start_win_width:  u16           = 0,
    start_win_height: u16           = 0,
    /// Last geometry applied by updateDrag; saved to the geometry cache by
    /// stopDrag so workspace-switch float-restore finds the post-drag position.
    /// Zero (default) means no motion event arrived during this drag.
    last_rect:        utils.Rect    = .{ .x = 0, .y = 0, .width = 0, .height = 0 },
};

// Named work-area type 
// A named struct makes the return type of workArea() referenceable in
// variable declarations and future doc-comments, unlike an anonymous return
// struct whose type cannot be spelled anywhere else in the code.
const WorkArea = struct { left: i32, right: i32, top: i32, bottom: i32 };

// Snap helpers 

/// Resolve snap_distance from config into pixels.
/// Percentage values are relative to screen width (the primary drag axis).
/// Returns 0 when snapping is disabled.
///
/// Note: a misconfigured negative value degrades safely — snapAxis's
/// abs-comparison is never satisfied when snap < 0, so no snap fires.
/// Zero is the canonical "disabled" sentinel.
fn snapDistance() i32 {
    const sv = core.config.snap_distance;
    if (sv.value == 0) return 0;
    if (sv.is_percentage) {
        const sw: f32 = @floatFromInt(core.screen.width_in_pixels);
        return @intFromFloat(@round(sv.value / 100.0 * sw));
    }
    return @intFromFloat(@round(sv.value));
}

/// Compute the work area edges accounting for bar height/position.
///
/// Border correction: X positions the window's content area, not its outer
/// border. To align the outer border flush with a far boundary, we subtract
/// 2 * border_width from that edge (total footprint = pos + dim + 2*bw).
/// Near edges need no correction because the outer border is already at pos.
fn workArea() WorkArea {
    const sw: i32  = core.screen.width_in_pixels;
    const sh: i32  = core.screen.height_in_pixels;
    const bh: i32  = if (bar.isVisible()) bar.getBarHeight() else 0;
    const bw2: i32 = @as(i32, window.getBorderWidth()) * 2;
    // bar_at_bottom only has observable effect when bh > 0 (bar is visible).
    // When bh == 0 both branches of the ternaries below produce identical
    // results, so evaluating it unconditionally is harmless.
    const bar_at_bottom = core.config.bar.bar_position == .bottom;
    return .{
        .left   = 0,
        .right  = sw - bw2,
        .top    = if (bar_at_bottom) 0 else bh,
        .bottom = (if (bar_at_bottom) sh - bh else sh) - bw2,
    };
}

/// Snap a window origin on one axis toward the near or far work-area boundary.
///
/// Snapping engages when a window edge comes within `snap` pixels of a
/// boundary.  It disengages as soon as the raw position would push the edge
/// past the boundary — the user is intentionally crossing it.
///
/// Precondition: all inputs are within normal window-coordinate range
/// (i.e. well within ±32 767).  The subtractions `pos - near` and
/// `(pos + dim) - far` are not overflow-guarded; wrapping cannot occur
/// for any real screen geometry.
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

/// Snap a single edge position toward `boundary` if within `snap` pixels of it.
/// Used for both near (left/top) and far (right/bottom) edges during resize.
inline fn snapEdge(edge: i32, boundary: i32, snap: i32) i32 {
    if (snap > 0 and @abs(edge - boundary) < snap) return boundary;
    return edge;
}

// snapNearEdge and snapFarEdge are identical in implementation; use snapEdge directly.

// Module state 

const State = struct {
    drag:          DragState = .{},
    pending_float: bool      = false,
};

var g_state: State = .{};

// Public API 

/// Begins a move (button 1) or resize (button 3) drag on `win` at pointer position (x, y).
/// No-op when a drag is already active, or for bar/fullscreen windows.
pub fn startDrag(win: u32, button: u8, x: i16, y: i16) void {
    if (g_state.drag.active) return;
    if (bar.isBarWindow(win)) return;
    // Fullscreen windows must not be drag-resized: they occupy the entire
    // screen and resizing them would corrupt their fullscreen geometry record.
    if (build.has_fullscreen) {
        if (fullscreen.isFullscreen(win)) return;
    }
    // Geometry source priority: prefer the tiling-cached geometry over a live
    // XCB round-trip.  The tiling engine keeps this up-to-date after every
    // retile, so it reflects the window's current position without a server
    // round-trip.  The live fallback covers purely floating windows that were
    // never tracked by the tiling engine.
    const geom = blk: {
        if (build.has_tiling) {
            if (tiling.getWindowGeom(win)) |g| break :blk g;
        }
        break :blk window.getGeometry(core.conn, win) orelse return;
    };

    // For resize drags, determine which corner of the window is closest to the
    // cursor.  Comparing the cursor to the window centre gives four quadrants
    // that map cleanly onto the four corners.
    const resize_corner: ResizeCorner = corner: {
        if (button == 1) break :corner .bottom_right; // move — corner unused
        const cx: i32 = @as(i32, geom.x) + @divTrunc(@as(i32, geom.width),  2);
        const cy: i32 = @as(i32, geom.y) + @divTrunc(@as(i32, geom.height), 2);
        const cursor_x: i32 = x;
        const cursor_y: i32 = y;
        if (cursor_x < cx and cursor_y < cy) break :corner .top_left;
        if (cursor_x >= cx and cursor_y < cy) break :corner .top_right;
        if (cursor_x < cx and cursor_y >= cy) break :corner .bottom_left;
        break :corner .bottom_right;
    };

    // pending_float is set for any drag (move *or* resize) on a tiled window
    // in a non-floating layout.  On the first motion event it triggers tiling
    // detach and a full retile of the workspace.
    // For .move specifically, the first event after detach also skips snap to
    // prevent the window appearing frozen when its tiled position coincides
    // with a screen edge (see updateDrag's was_pending_float guard).
    g_state = .{
        .drag = .{
            .active           = true,
            .window           = win,
            .mode             = if (button == 1) .move else .resize,
            .resize_corner    = resize_corner,
            .start_x          = x,
            .start_y          = y,
            .start_win_x      = geom.x,
            .start_win_y      = geom.y,
            .start_win_width  = geom.width,
            .start_win_height = geom.height,
        },
        .pending_float = if (build.has_tiling)
            tiling.isWindowTiled(win) and !tiling.isFloatingLayout()
        else
            false,
    };
    focus.setFocus(win, .user_command);
    // Raise the window to the top of the stack.  The cookie is intentionally
    // discarded — XCB errors surface only via xcb_request_check, which we do
    // not call here; a stack-raise failure is non-fatal.
    _ = xcb.xcb_configure_window(core.conn, win,
        xcb.XCB_CONFIG_WINDOW_STACK_MODE, &[_]u32{xcb.XCB_STACK_MODE_ABOVE});
    _ = xcb.xcb_flush(core.conn);
}

/// Applies pointer motion to the active drag, updating window position or size.
/// No-op when no drag is active.
pub fn updateDrag(x: i16, y: i16) void {
    if (!g_state.drag.active) return;
    const drag = &g_state.drag;

    const was_pending_float = g_state.pending_float;
    if (g_state.pending_float) {
        g_state.pending_float = false;
        // Grab the server to suppress intermediate renders during the detach +
        // retile sequence.  A failed grab is intentionally ignored — it is a
        // visual nicety, not a correctness requirement; the retile proceeds
        // regardless.
        _ = xcb.xcb_grab_server(core.conn);
        if (build.has_tiling) {
            tiling.removeWindow(drag.window);
            tiling.retileCurrentWorkspace();
        }
        utils.ungrabAndFlush(core.conn);
    }

    const dx = x - drag.start_x;
    const dy = y - drag.start_y;

    // Compute snap threshold and work area once, shared by both switch arms.
    // workArea() is only evaluated when snapping is active; when snap == 0
    // the zero-value sentinel is never read (all snap logic short-circuits).
    const snap = snapDistance();
    const wa: WorkArea = if (snap > 0) workArea() else .{ .left = 0, .right = 0, .top = 0, .bottom = 0 };

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
            // was_pending_float triggered the tiling detach above.  No
            // snap-skip is needed here: the "frozen at edge" problem only
            // arises during move (window origin snaps to a tiled edge);
            // resize starts from the current size and is unaffected.
            //
            // Anchor-based resizing with automatic corner wrapping.
            //
            // The anchor is the corner diagonally opposite the one being
            // dragged; it stays fixed throughout the drag.  The moving corner
            // follows the cursor.  The window always spans min→max of anchor
            // and moving on each axis, so:
            //
            //   • While the cursor is on the same side as the original corner
            //     the behaviour is identical to the old per-corner code.
            //
            //   • When the cursor crosses the anchor horizontally the
            //     left/right roles swap automatically — the window begins
            //     growing toward the opposite horizontal side.
            //
            //   • The same applies vertically, and both axes are independent,
            //     so all four quadrant transitions are handled.
            //
            // Snapping is applied to the moving edge toward whichever
            // work-area boundary (near or far) it is closest to.  The anchor
            // edge is fixed and never snapped.

            const start_x: i32 = drag.start_win_x;
            const start_y: i32 = drag.start_win_y;
            const start_w: i32 = drag.start_win_width;
            const start_h: i32 = drag.start_win_height;

            // Anchor: the edge that stays fixed (opposite side from the
            // initially-dragged corner).
            const anchor_x: i32 = switch (drag.resize_corner) {
                .top_left,    .bottom_left  => start_x + start_w, // anchor = right edge
                .top_right,   .bottom_right => start_x,            // anchor = left  edge
            };
            const anchor_y: i32 = switch (drag.resize_corner) {
                .top_left,    .top_right    => start_y + start_h, // anchor = bottom edge
                .bottom_left, .bottom_right => start_y,            // anchor = top   edge
            };

            // Moving corner: initial position of the edge under the cursor.
            const moving_x0: i32 = switch (drag.resize_corner) {
                .top_left,    .bottom_left  => start_x,            // moving = left  edge
                .top_right,   .bottom_right => start_x + start_w, // moving = right edge
            };
            const moving_y0: i32 = switch (drag.resize_corner) {
                .top_left,    .top_right    => start_y,            // moving = top    edge
                .bottom_left, .bottom_right => start_y + start_h, // moving = bottom edge
            };

            // Apply cursor delta then snap toward whichever work-area
            // boundary the moving edge is closest to.
            const raw_moving_x: i32 = moving_x0 + @as(i32, dx);
            const raw_moving_y: i32 = moving_y0 + @as(i32, dy);

            const moving_x: i32 = snapEdge(snapEdge(raw_moving_x, wa.left, snap), wa.right,  snap);
            const moving_y: i32 = snapEdge(snapEdge(raw_moving_y, wa.top,  snap), wa.bottom, snap);

            // The four edges are simply the min/max of anchor and moving on
            // each axis.  Crossing the anchor wraps the resize direction.
            const new_left:   i32 = @min(anchor_x, moving_x);
            const new_right:  i32 = @max(anchor_x, moving_x);
            const new_top:    i32 = @min(anchor_y, moving_y);
            const new_bottom: i32 = @max(anchor_y, moving_y);

            const new_w = new_right  - new_left;
            const new_h = new_bottom - new_top;

            // Clamp dimensions first, then re-pin the position so the anchor
            // edge stays fixed even when the minimum size is hit.
            //
            // Without this correction the anchor drifts: .x is set to new_left
            // (the cursor-tracked edge) while .width is inflated by the clamp,
            // so the far edge overshoots anchor_x.  Example: dragging the left
            // edge rightward past (anchor_x - MIN_WINDOW_DIM) would push the
            // right edge beyond anchor_x instead of holding it steady.
            //
            // The rule is straightforward:
            //   • moving edge is on the LEFT  (moving_x < anchor_x)
            //     → anchor is the RIGHT edge; x = anchor_x - clamped_w
            //   • moving edge is on the RIGHT (moving_x >= anchor_x)
            //     → anchor is the LEFT  edge; x = new_left (unchanged)
            // Identical logic applies vertically.
            const clamped_w: i32 = std.math.clamp(new_w, constants.MIN_WINDOW_DIM, std.math.maxInt(u16));
            const clamped_h: i32 = std.math.clamp(new_h, constants.MIN_WINDOW_DIM, std.math.maxInt(u16));

            const pinned_x: i32 = if (moving_x < anchor_x) anchor_x - clamped_w else new_left;
            const pinned_y: i32 = if (moving_y < anchor_y) anchor_y - clamped_h else new_top;

            break :blk utils.Rect{
                .x      = @intCast(pinned_x),
                .y      = @intCast(pinned_y),
                .width  = @intCast(clamped_w),
                .height = @intCast(clamped_h),
            };
        },
    };
    drag.last_rect = rect;
    utils.configureWindow(core.conn, drag.window, rect);
    _ = xcb.xcb_flush(core.conn);
}

/// Ends the active drag and resets all drag state.
pub fn stopDrag() void {
    // Save the final geometry so workspace-switch float-restore finds the
    // drag-moved position rather than the pre-drag tiling or default position.
    // last_rect is zero when no motion event arrived during this drag (a bare
    // click-and-release), in which case the cached geometry is already correct.
    const drag = &g_state.drag;
    if (drag.active and drag.last_rect.width != 0) {
        window.saveWindowGeom(drag.window, drag.last_rect);
    }
    // No flush needed: the last updateDrag call already flushed all pending
    // geometry changes before this function is reached.
    g_state = .{};
}

pub inline fn isDragging() bool { return g_state.drag.active; }

/// Returns true when a resize drag is active on the given window.
/// Use this in handleConfigureRequest to deny min-size requests from the
/// window being resized, preventing flicker between the client minimum and
/// the WM-enforced size.
pub inline fn isResizingWindow(win: u32) bool {
    return g_state.drag.active and g_state.drag.mode == .resize and g_state.drag.window == win;
}

/// Returns the rect last applied during the active drag.
/// Only meaningful when isDragging() is true and at least one motion event
/// has arrived (last_rect.width != 0).
pub inline fn getDragLastRect() utils.Rect { return g_state.drag.last_rect; }
