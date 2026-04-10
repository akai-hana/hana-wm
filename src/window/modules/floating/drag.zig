//! Window dragging and resizing via pointer button grabs.

const std   = @import("std");
const build = @import("build_options");

const core      = @import("core");
    const xcb   = core.xcb;
const constants = @import("constants");
const utils     = @import("utils");

const window = @import("window");
const focus  = @import("focus");

const tiling     = if (build.has_tiling) @import("tiling") else struct {};
const fullscreen = if (build.has_fullscreen) @import("fullscreen") else struct {};

const scale = if (build.has_scale) @import("scale") else struct {
    pub fn cachedRefreshRate() f64 { return 60.0; }
};

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
///   bottom_left  | bottom_right   ← was the only option before
///
/// During updateDrag the deltas (dx, dy) are applied to the appropriate
/// edges so the window follows the corner under the cursor:
///
///   bottom_right  →  x/y fixed,    w += dx, h += dy   (original behaviour)
///   bottom_left   →  x += dx,      w -= dx, h += dy
///   top_right     →  y += dy,      w += dx, h -= dy
///   top_left      →  x += dx, y += dy, w -= dx, h -= dy
pub const ResizeCorner = enum { top_left, top_right, bottom_left, bottom_right };

pub const DragState = struct {
    active:           bool         = false,
    window:           core.WindowId = 0,
    mode:             DragMode     = .move,
    resize_corner:    ResizeCorner = .bottom_right,
    start_x:          i16         = 0,
    start_y:          i16         = 0,
    start_win_x:      i16         = 0,
    start_win_y:      i16         = 0,
    start_win_width:  u16         = 0,
    start_win_height: u16         = 0,
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
    frame_ms:       f64      = 0.0,
    last_update_ms: u32      = 0,
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
    if (comptime build.has_fullscreen) {
        if (fullscreen.isFullscreen(win)) return;
    }
    // Geometry source priority: prefer the tiling-cached geometry over a live
    // XCB round-trip.  The tiling engine keeps this up-to-date after every
    // retile, so it reflects the window's current position without a server
    // round-trip.  The live fallback covers purely floating windows that were
    // never tracked by the tiling engine.
    const geom = blk: {
        if (comptime build.has_tiling) {
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
        .pending_float = if (comptime build.has_tiling)
            tiling.isWindowTiled(win) and !tiling.isFloatingLayout()
        else
            false,
    };
    g_state.frame_ms = 1000.0 / scale.cachedRefreshRate();
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
        if (comptime build.has_tiling) {
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
            // The corner determines which edges move with the cursor:
            //
            //   bottom_right  x/y fixed,    right  += dx, bottom += dy
            //   bottom_left   left  += dx,  right  fixed, bottom += dy
            //   top_right     x/y fixed*,   right  += dx, top    += dy
            //   top_left      left  += dx,  right  fixed, top    += dy
            //
            // "left += dx" means: new_x = start_x + dx, new_w = start_w - dx
            // "top  += dy" means: new_y = start_y + dy, new_h = start_h - dy
            //
            // Snapping: far edges snap toward the far work-area boundary
            // (snapFarEdge); near edges snap toward the near boundary
            // (snapNearEdge).  Each direction is handled independently so
            // that a top-left drag snaps both the left and top edges.

            const start_x: i32 = drag.start_win_x;
            const start_y: i32 = drag.start_win_y;
            const start_w: i32 = drag.start_win_width;
            const start_h: i32 = drag.start_win_height;

            // Compute raw new edges for each side.
            const raw_left:   i32 = start_x;
            const raw_top:    i32 = start_y;
            const raw_right:  i32 = start_x + start_w + @as(i32, dx); // used by right-side corners
            const raw_bottom: i32 = start_y + start_h + @as(i32, dy); // used by bottom corners
            const raw_left_m: i32 = start_x             + @as(i32, dx); // used by left-side corners
            const raw_top_m:  i32 = start_y             + @as(i32, dy); // used by top corners

            // Resolve which x/y origin and width/height to use.
            const new_left: i32 = switch (drag.resize_corner) {
                .top_left, .bottom_left =>
                    snapEdge(raw_left_m, wa.left, snap),
                .top_right, .bottom_right => raw_left,
            };
            const new_top: i32 = switch (drag.resize_corner) {
                .top_left, .top_right =>
                    snapEdge(raw_top_m, wa.top, snap),
                .bottom_left, .bottom_right => raw_top,
            };
            const new_right: i32 = switch (drag.resize_corner) {
                .top_right, .bottom_right =>
                    snapEdge(raw_right, wa.right, snap),
                .top_left, .bottom_left =>
                    // Right edge is fixed; derive from start so width shrinks
                    // correctly when the left edge moves right.
                    start_x + start_w,
            };
            const new_bottom: i32 = switch (drag.resize_corner) {
                .bottom_left, .bottom_right =>
                    snapEdge(raw_bottom, wa.bottom, snap),
                .top_left, .top_right =>
                    // Bottom edge is fixed.
                    start_y + start_h,
            };

            const new_w = new_right  - new_left;
            const new_h = new_bottom - new_top;

            break :blk utils.Rect{
                .x      = @intCast(new_left),
                .y      = @intCast(new_top),
                .width  = @intCast(std.math.clamp(new_w, constants.MIN_WINDOW_DIM, std.math.maxInt(u16))),
                .height = @intCast(std.math.clamp(new_h, constants.MIN_WINDOW_DIM, std.math.maxInt(u16))),
            };
        },
    };
    utils.configureWindow(core.conn, drag.window, rect);
    _ = xcb.xcb_flush(core.conn);
}

/// Ends the active drag and resets all drag state.
pub fn stopDrag() void {
    // No flush needed: the last updateDrag call already flushed all pending
    // geometry changes before this function is reached.
    g_state = .{};
}

pub inline fn isDragging() bool { return g_state.drag.active; }