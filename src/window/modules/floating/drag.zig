//! Window dragging and resizing via pointer button grabs.

const std       = @import("std");
const constants = @import("constants");
const core      = @import("core");
const xcb       = core.xcb;
const utils     = @import("utils");
const focus     = @import("focus");
const build_options = @import("build_options");
const tiling        = if (build_options.has_tiling) @import("tiling") else struct {};
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

// All drag state in one place. A single `g_state = .{}` resets every field
// atomically — there is no separate flag that can drift out of sync with the
// rest of the drag record.
//
// pending_float is true when the dragged window was tiled at press time and
// has not yet been removed from the tiling pool. The removal is deferred until
// the first real motion event so that a quick Mod+click that never moves the
// cursor does not accidentally float the window. It is cleared either by
// updateDrag (on first motion) or by stopDrag (on early release), both of
// which now do so implicitly via the same `g_state = .{}` reset.
const State = struct {
    drag:          core.DragState = .{},
    pending_float: bool           = false,
};
var g_state: State = .{};

pub fn startDrag(win: u32, button: u8, x: i16, y: i16) void {
    if (g_state.drag.active) return;
    if (bar.isBarWindow(win)) return;
    // Prefer the tiling cache; fall back to a live round-trip for floating
    // windows. The cache holds the logical geometry the tiling engine has
    // assigned, which may differ from what X reports if a configure is queued
    // but not yet flushed — so this is a correctness choice, not only a
    // performance one.
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
        // Float conversion is deferred to the first motion event (updateDrag).
        // A tiled window must be detached from the pool on first motion so it
        // can move freely. Skip this in the floating layout — all windows are
        // already unconstrained and must stay tracked for retile on layout exit.
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

    // First real motion: commit the float conversion. Doing it here rather than
    // in startDrag means a Mod+click that never moves the cursor leaves the
    // window tiled, as if the click never happened.
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

// Single reset covers every field — no separate flag to remember.
pub fn stopDrag() void {
    g_state = .{};
}

pub inline fn isDragging() bool { return g_state.drag.active; }
