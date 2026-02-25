//! Fibonacci (spiral) tiling layout.
//! Windows spiral counter-clockwise: right, down, left, up, repeat.

const defs    = @import("defs");
const xcb     = @import("defs").xcb;
const utils   = @import("utils");
const layouts = @import("layouts");
const tiling  = @import("tiling");
const State   = tiling.State;

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
    s:                *State,
    visible:          []const u32,
    screen_width:     u16,
    available_height: u16,
    y_offset:         u16,
) void {
    if (visible.len == 0) return;

    const margin = s.margins();
    const gap    = margin.gap;
    const border = margin.border;

    tileFibonacci(conn, visible,
        @intCast(gap),
        @intCast(y_offset +| gap),
        screen_width  -| gap *| 2,
        available_height -| gap *| 2,
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
    // The remaining area is too small to keep splitting.  Stack all overflow
    // windows on top of each other in whatever space is still available — like
    // a single-cell monocle for the remainder.
    if (width < gap * 2 + border * 2 or height < gap * 2 + border * 2) {
        const rect = utils.Rect{
            .x      = @intCast(x),
            .y      = @intCast(y),
            .width  = if (width  > border * 2) width  - border * 2 else defs.MIN_WINDOW_DIM,
            .height = if (height > border * 2) height - border * 2 else defs.MIN_WINDOW_DIM,
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
