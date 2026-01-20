//! Window dragging and resizing with mouse cursor.
//!
//! Supports:
//! - Super+Button1: Move window by dragging
//! - Super+Button3: Resize window by dragging from current position
//!
//! The window's geometry is captured at drag start and updated during motion.

const std = @import("std");
const defs = @import("defs");
const log = @import("logging");
const xcb = defs.xcb;
const WM = defs.WM;

/// Drag operation state
const DragState = struct {
    /// Which button started the drag (1=move, 3=resize)
    button: u8 = 0,

    /// Window being dragged
    window: u32 = 0,

    /// Initial cursor X position when drag started
    start_x: i16 = 0,

    /// Initial cursor Y position when drag started
    start_y: i16 = 0,

    /// Window's initial X position
    attr_x: i16 = 0,

    /// Window's initial Y position
    attr_y: i16 = 0,

    /// Window's initial width
    attr_width: u16 = 0,

    /// Window's initial height
    attr_height: u16 = 0,

    fn isDragging(self: *const DragState) bool {
        return self.window != 0;
    }

    fn reset(self: *DragState) void {
        self.window = 0;
    }
};

/// Global drag state
var drag_state: DragState = .{};

/// Minimum window size for resizing
const MIN_WINDOW_SIZE = 50;

/// Start dragging a window
/// button 1 = move, button 3 = resize
pub fn startDrag(wm: *WM, window: u32, button: u8, root_x: i16, root_y: i16) void {
    // Only handle left (move) and right (resize) buttons
    if (button != 1 and button != 3) return;

    // Get current window geometry
    const geom_cookie = xcb.xcb_get_geometry(wm.conn, window);
    const geom_reply = xcb.xcb_get_geometry_reply(wm.conn, geom_cookie, null) orelse return;
    defer std.c.free(geom_reply);

    // Save drag state
    drag_state = .{
        .button = button,
        .window = window,
        .start_x = root_x,
        .start_y = root_y,
        .attr_x = geom_reply.*.x,
        .attr_y = geom_reply.*.y,
        .attr_width = geom_reply.*.width,
        .attr_height = geom_reply.*.height,
    };

    const action = if (button == 1) "move" else "resize";
    log.dragStarted(action, window, root_x, root_y);

    // Raise window to top
    _ = xcb.xcb_configure_window(wm.conn, window, xcb.XCB_CONFIG_WINDOW_STACK_MODE, &[_]u32{xcb.XCB_STACK_MODE_ABOVE});
}

/// Update window position/size as cursor moves
pub fn updateDrag(wm: *WM, root_x: i16, root_y: i16) void {
    if (!drag_state.isDragging()) return;

    // CRITICAL: Use saturating arithmetic to prevent overflow
    const dx: i32 = @as(i32, root_x) - @as(i32, drag_state.start_x);
    const dy: i32 = @as(i32, root_y) - @as(i32, drag_state.start_y);

    if (drag_state.button == 1) {
        // Move window
        const new_x_i32 = std.math.add(i32, drag_state.attr_x, dx) catch blk: {
            const max_i16: i32 = std.math.maxInt(i16);
            const min_i16: i32 = std.math.minInt(i16);
            break :blk if (dx > 0) max_i16 else min_i16;
        };
        const new_y_i32 = std.math.add(i32, drag_state.attr_y, dy) catch blk: {
            const max_i16: i32 = std.math.maxInt(i16);
            const min_i16: i32 = std.math.minInt(i16);
            break :blk if (dy > 0) max_i16 else min_i16;
        };

        const new_x: i16 = @intCast(std.math.clamp(new_x_i32, std.math.minInt(i16), std.math.maxInt(i16)));
        const new_y: i16 = @intCast(std.math.clamp(new_y_i32, std.math.minInt(i16), std.math.maxInt(i16)));

        _ = xcb.xcb_configure_window(wm.conn, drag_state.window, xcb.XCB_CONFIG_WINDOW_X | xcb.XCB_CONFIG_WINDOW_Y, &[_]u32{
            @bitCast(@as(i32, new_x)),
            @bitCast(@as(i32, new_y)),
        });
    } else {
        // Resize window
        // Prevent negative sizes and overflow
        const new_width = std.math.add(i32, drag_state.attr_width, dx) catch 65535;
        const new_height = std.math.add(i32, drag_state.attr_height, dy) catch 65535;

        _ = xcb.xcb_configure_window(wm.conn, drag_state.window, xcb.XCB_CONFIG_WINDOW_WIDTH | xcb.XCB_CONFIG_WINDOW_HEIGHT, &[_]u32{
            @intCast(std.math.clamp(new_width, MIN_WINDOW_SIZE, 65535)),
            @intCast(std.math.clamp(new_height, MIN_WINDOW_SIZE, 65535)),
        });
    }
}

/// Stop dragging and flush changes
pub fn stopDrag(wm: *WM) void {
    if (!drag_state.isDragging()) return;

    log.dragStopped(drag_state.window);

    _ = xcb.xcb_flush(wm.conn);
    drag_state.reset();
}

/// Check if currently dragging a window
pub fn isDragging() bool {
    return drag_state.isDragging();
}

/// Get the window currently being dragged
pub fn getDraggedWindow() ?u32 {
    return if (drag_state.isDragging()) drag_state.window else null;
}
