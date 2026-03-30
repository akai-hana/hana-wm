//! Window dragging and resizing via pointer button grabs.

const std           = @import("std");
const constants     = @import("constants");
const core          = @import("core");
const xcb           = core.xcb;
const utils         = @import("utils");
const focus         = @import("focus");
const build_options = @import("build_options");
const tiling        = if (build_options.has_tiling) @import("tiling") else struct {};
const bar           = if (build_options.has_bar) @import("bar") else struct {
    pub fn isVisible() bool { return false; }
    pub fn getBarHeight() u16 { return 0; }
    pub fn isBarWindow(_: u32) bool { return false; }
};
const fullscreen    = if (build_options.has_fullscreen) @import("fullscreen") else struct {};
const window        = @import("window");

// Drag state types

pub const DragMode = enum { move, resize };

pub const DragState = struct {
    active:           bool     = false,
    window:           core.WindowId = 0,
    mode:             DragMode = .move,
    start_x:          i16      = 0,
    start_y:          i16      = 0,
    start_win_x:      i16      = 0,
    start_win_y:      i16      = 0,
    start_win_width:  u16      = 0,
    start_win_height: u16      = 0,
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

/// Snap a single edge position toward one far boundary only.
///
/// Used during resize to snap the trailing (right / bottom) edge without
/// also snapping toward the near boundary — near-edge snap during resize
/// would collapse the window toward zero width / height, which is
/// unintuitive and handled separately by the MIN_WINDOW_DIM clamp.
inline fn snapFarEdge(edge: i32, boundary: i32, snap: i32) i32 {
    if (snap > 0 and @abs(edge - boundary) < snap) return boundary;
    return edge;
}

// Module state 

const State = struct {
    drag:          DragState = .{},
    pending_float: bool      = false,
};
var g_state: State = .{};

// Public API 

pub fn startDrag(win: u32, button: u8, x: i16, y: i16) void {
    if (g_state.drag.active) return;
    if (bar.isBarWindow(win)) return;
    // Fullscreen windows must not be drag-resized: they occupy the entire
    // screen and resizing them would corrupt their fullscreen geometry record.
    if (comptime build_options.has_fullscreen) {
        if (fullscreen.isFullscreen(win)) return;
    }
    // Geometry source priority: prefer the tiling-cached geometry over a live
    // XCB round-trip.  The tiling engine keeps this up-to-date after every
    // retile, so it reflects the window's current position without a server
    // round-trip.  The live fallback covers purely floating windows that were
    // never tracked by the tiling engine.
    const geom = blk: {
        if (comptime build_options.has_tiling) {
            if (tiling.getWindowGeom(win)) |g| break :blk g;
        }
        break :blk utils.getGeometry(core.conn, win) orelse return;
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
    // Raise the window to the top of the stack.  The cookie is intentionally
    // discarded — XCB errors surface only via xcb_request_check, which we do
    // not call here; a stack-raise failure is non-fatal.
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
        // Grab the server to suppress intermediate renders during the detach +
        // retile sequence.  A failed grab is intentionally ignored — it is a
        // visual nicety, not a correctness requirement; the retile proceeds
        // regardless.
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
            const raw_w: i32 = @as(i32, drag.start_win_width)  + @as(i32, dx);
            const raw_h: i32 = @as(i32, drag.start_win_height) + @as(i32, dy);
            // Snap the trailing edges toward the far work-area boundaries.
            // snapFarEdge suppresses near-edge snap, which would otherwise
            // collapse the window toward zero size.  The final clamp enforces
            // the minimum window dimension and the u16 ceiling in one place,
            // covering both the unsnapped path and the case where the snap
            // target itself is smaller than MIN_WINDOW_DIM (window origin near
            // the far boundary).
            const snapped_w = snapFarEdge(
                @as(i32, drag.start_win_x) + raw_w, wa.right, snap,
            ) - drag.start_win_x;
            const snapped_h = snapFarEdge(
                @as(i32, drag.start_win_y) + raw_h, wa.bottom, snap,
            ) - drag.start_win_y;
            break :blk utils.Rect{
                .x      = drag.start_win_x,
                .y      = drag.start_win_y,
                .width  = @intCast(std.math.clamp(snapped_w, constants.MIN_WINDOW_DIM, std.math.maxInt(u16))),
                .height = @intCast(std.math.clamp(snapped_h, constants.MIN_WINDOW_DIM, std.math.maxInt(u16))),
            };
        },
    };
    utils.configureWindow(core.conn, drag.window, rect);
    _ = xcb.xcb_flush(core.conn);
}

pub fn stopDrag() void {
    // No flush needed: the last updateDrag call already flushed all pending
    // geometry changes before this function is reached.
    g_state = .{};
}

pub inline fn isDragging() bool { return g_state.drag.active; }
