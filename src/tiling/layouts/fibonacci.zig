//! Fibonacci (spiral) Tiling Layout
//!
//! Creates a true fibonacci spiral pattern where windows spiral around the center
//! in a counter-clockwise direction: right → down → left → up → repeat

const xcb     = @import("defs").xcb;
const utils   = @import("utils");
const layouts = @import("layouts");

const Direction = enum {
    right, // Split vertically, window on left, remaining on right
    down,  // Split horizontally, window on top, remaining below
    left,  // Split vertically, window on right, remaining on left
    up,    // Split horizontally, window on bottom, remaining above

    fn next(self: Direction) Direction {
        return switch (self) {
            .right => .down,
            .down  => .left,
            .left  => .up,
            .up    => .right,
        };
    }
};

pub fn tileWithOffset(
    conn:             *xcb.xcb_connection_t,
    s:                anytype,
    visible:          []const u32,
    screen_width:     u16,
    available_height: u16,
    y_offset:         u16,
) void {
    const margin = s.margins();
    const gap    = margin.gap;
    const border = margin.border;

    if (visible.len == 0) return;
    if (visible.len == 1) {
        layouts.configureSafe(conn, visible[0], .{
            .x      = @intCast(gap),
            .y      = @intCast(y_offset + gap),
            .width  = screen_width - gap * 2 - border * 2,
            .height = available_height - gap * 2 - border * 2,
        });
        return;
    }

    tileFibonacci(conn, visible,
        @intCast(gap),
        @intCast(y_offset + gap),
        screen_width - gap * 2,
        available_height - gap * 2,
        gap, border, 0, .right);
}

fn tileFibonacci(
    conn:      *xcb.xcb_connection_t,
    windows:   []const u32,
    x:         i32,
    y:         i32,
    width:     u16,
    height:    u16,
    gap:       u16,
    border:    u16,
    index:     usize,
    direction: Direction,
) void {
    if (index >= windows.len) return;

    // The remaining area is too small to keep splitting.  Stack all overflow
    // windows on top of each other in whatever space is still available — like
    // a single-cell monocle for the remainder.
    if (width < gap * 2 + border * 2 or height < gap * 2 + border * 2) {
        const rect = utils.Rect{
            .x      = @intCast(x),
            .y      = @intCast(y),
            .width  = if (width  > border * 2) width  - border * 2 else 1,
            .height = if (height > border * 2) height - border * 2 else 1,
        };
        for (windows[index..]) |win| layouts.configureSafe(conn, win, rect);
        return;
    }

    const win = windows[index];

    if (index == windows.len - 1) {
        // Last window gets all remaining space.
        layouts.configureSafe(conn, win, .{
            .x      = @intCast(x),
            .y      = @intCast(y),
            .width  = width  -| border * 2,
            .height = height -| border * 2,
        });
        return;
    }

    // Split the space according to the spiral direction.
    switch (direction) {
        .right => {
            const win_width = width / 2 -| gap;
            layouts.configureSafe(conn, win, .{
                .x      = @intCast(x),
                .y      = @intCast(y),
                .width  = win_width -| border * 2,
                .height = height    -| border * 2,
            });
            tileFibonacci(conn, windows,
                x + @as(i32, @intCast(win_width + gap)), y,
                width -| (win_width + gap), height,
                gap, border, index + 1, direction.next());
        },
        .down => {
            const win_height = height / 2 -| gap;
            layouts.configureSafe(conn, win, .{
                .x      = @intCast(x),
                .y      = @intCast(y),
                .width  = width      -| border * 2,
                .height = win_height -| border * 2,
            });
            tileFibonacci(conn, windows,
                x, y + @as(i32, @intCast(win_height + gap)),
                width, height -| (win_height + gap),
                gap, border, index + 1, direction.next());
        },
        .left => {
            const win_width = width / 2 -| gap;
            layouts.configureSafe(conn, win, .{
                .x      = @intCast(x + @as(i32, @intCast(width - win_width))),
                .y      = @intCast(y),
                .width  = win_width -| border * 2,
                .height = height    -| border * 2,
            });
            tileFibonacci(conn, windows,
                x, y,
                width -| (win_width + gap), height,
                gap, border, index + 1, direction.next());
        },
        .up => {
            const win_height = height / 2 -| gap;
            layouts.configureSafe(conn, win, .{
                .x      = @intCast(x),
                .y      = @intCast(y + @as(i32, @intCast(height - win_height))),
                .width  = width      -| border * 2,
                .height = win_height -| border * 2,
            });
            tileFibonacci(conn, windows,
                x, y,
                width, height -| (win_height + gap),
                gap, border, index + 1, direction.next());
        },
    }
}
