//! Window dragging and resizing with mouse.

const std = @import("std");
const defs = @import("defs");
const log = @import("logging");
const xcb = defs.xcb;
const WM = defs.WM;

const DragState = struct {
    button: u8 = 0,
    window: u32 = 0,
    start_x: i16 = 0,
    start_y: i16 = 0,
    attr_x: i16 = 0,
    attr_y: i16 = 0,
    attr_width: u16 = 0,
    attr_height: u16 = 0,

    fn isDragging(self: *const DragState) bool {
        return self.window != 0;
    }

    fn reset(self: *DragState) void {
        self.window = 0;
    }
};

var drag_state: DragState = .{};

/// Start dragging: button 1 = move, button 3 = resize
pub fn startDrag(wm: *WM, window: u32, button: u8, root_x: i16, root_y: i16) void {
    if (button != 1 and button != 3) return;

    const geom_cookie = xcb.xcb_get_geometry(wm.conn, window);
    const geom_reply = xcb.xcb_get_geometry_reply(wm.conn, geom_cookie, null) orelse return;
    defer std.c.free(geom_reply);

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

    _ = xcb.xcb_configure_window(wm.conn, window, xcb.XCB_CONFIG_WINDOW_STACK_MODE, &[_]u32{xcb.XCB_STACK_MODE_ABOVE});
}

pub fn updateDrag(wm: *WM, root_x: i16, root_y: i16) void {
    if (!drag_state.isDragging()) return;

    const dx: i32 = @as(i32, root_x) - @as(i32, drag_state.start_x);
    const dy: i32 = @as(i32, root_y) - @as(i32, drag_state.start_y);

    if (drag_state.button == 1) {
        // Move
        const new_x_i32 = std.math.add(i32, drag_state.attr_x, dx) catch
            if (dx > 0) @as(i32, std.math.maxInt(i16)) else @as(i32, std.math.minInt(i16));
        const new_y_i32 = std.math.add(i32, drag_state.attr_y, dy) catch
            if (dy > 0) @as(i32, std.math.maxInt(i16)) else @as(i32, std.math.minInt(i16));

        const new_x: i16 = @intCast(std.math.clamp(new_x_i32, std.math.minInt(i16), std.math.maxInt(i16)));
        const new_y: i16 = @intCast(std.math.clamp(new_y_i32, std.math.minInt(i16), std.math.maxInt(i16)));

        _ = xcb.xcb_configure_window(wm.conn, drag_state.window, xcb.XCB_CONFIG_WINDOW_X | xcb.XCB_CONFIG_WINDOW_Y, &[_]u32{
            @bitCast(@as(i32, new_x)),
            @bitCast(@as(i32, new_y)),
        });
    } else {
        // Resize
        const new_width = std.math.add(i32, drag_state.attr_width, dx) catch defs.MAX_WINDOW_DIM;
        const new_height = std.math.add(i32, drag_state.attr_height, dy) catch defs.MAX_WINDOW_DIM;

        _ = xcb.xcb_configure_window(wm.conn, drag_state.window, xcb.XCB_CONFIG_WINDOW_WIDTH | xcb.XCB_CONFIG_WINDOW_HEIGHT, &[_]u32{
            @intCast(std.math.clamp(new_width, defs.MIN_WINDOW_DIM, defs.MAX_WINDOW_DIM)),
            @intCast(std.math.clamp(new_height, defs.MIN_WINDOW_DIM, defs.MAX_WINDOW_DIM)),
        });
    }
}

pub fn stopDrag(wm: *WM) void {
    if (!drag_state.isDragging()) return;

    log.dragStopped(drag_state.window);

    _ = xcb.xcb_flush(wm.conn);
    drag_state.reset();
}

pub fn isDragging() bool {
    return drag_state.isDragging();
}

pub fn getDraggedWindow() ?u32 {
    return if (drag_state.isDragging()) drag_state.window else null;
}
