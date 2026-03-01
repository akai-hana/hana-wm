//! Fibonacci (spiral) tiling layout.
//! Windows spiral counter-clockwise: right, down, left, up, repeat.

const defs    = @import("defs");
const xcb     = @import("defs").xcb;
const utils   = @import("utils");
const layouts = @import("layouts");
const tiling  = @import("tiling");
const State   = tiling.State;

// Direction cycles counter-clockwise: right → down → left → up → right …
const Direction = enum {
    right, // Split vertically: window on left, remaining on right
    down,  // Split horizontally: window on top, remaining below
    left,  // Split vertically: window on right, remaining on left
    up,    // Split horizontally: window on bottom, remaining above

    inline fn next(self: Direction) Direction {
        return switch (self) {
            .right => .down,
            .down  => .left,
            .left  => .up,
            .up    => .right,
        };
    }
};

pub fn tileWithOffset(
    ctx:              *const layouts.LayoutCtx,
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

    // Iterative spiral: tracks the shrinking bounding box and current
    // direction. Eliminates the previous recursive implementation whose call
    // depth equalled the window count, carrying conn, windows, gap, and border
    // down every frame unnecessarily.
    var x: i32 = @intCast(gap);
    var y: i32 = @intCast(y_offset +| gap);
    var w: u16 = screen_width    -| gap *| 2;
    var h: u16 = available_height -| gap *| 2;
    var dir: Direction = .right;

    for (visible, 0..) |win, i| {
        // If the remaining area is too small to keep splitting, stack all
        // overflow windows on top of each other in whatever space is left —
        // a single-cell monocle for the remainder.
        if (w < gap * 2 + border * 2 or h < gap * 2 + border * 2) {
            const rect = utils.Rect{
                .x      = @intCast(x),
                .y      = @intCast(y),
                .width  = if (w > border * 2) w - border * 2 else defs.MIN_WINDOW_DIM,
                .height = if (h > border * 2) h - border * 2 else defs.MIN_WINDOW_DIM,
            };
            for (visible[i..]) |ow| layouts.configureSafe(ctx, ow, rect);
            return;
        }

        // Last window gets all remaining space.
        if (i == visible.len - 1) {
            layouts.configureSafe(ctx, win, .{
                .x      = @intCast(x),
                .y      = @intCast(y),
                .width  = w -| border * 2,
                .height = h -| border * 2,
            });
            return;
        }

        // Split the bounding box according to the spiral direction, place the
        // current window in its half, then shrink the box to the remainder.
        switch (dir) {
            .right => {
                const win_w = (w -| gap) / 2;
                layouts.configureSafe(ctx, win, .{
                    .x      = @intCast(x),
                    .y      = @intCast(y),
                    .width  = win_w -| border * 2,
                    .height = h     -| border * 2,
                });
                x += @as(i32, @intCast(win_w + gap));
                w  = w -| (win_w + gap);
            },
            .down => {
                const win_h = (h -| gap) / 2;
                layouts.configureSafe(ctx, win, .{
                    .x      = @intCast(x),
                    .y      = @intCast(y),
                    .width  = w     -| border * 2,
                    .height = win_h -| border * 2,
                });
                y += @as(i32, @intCast(win_h + gap));
                h  = h -| (win_h + gap);
            },
            .left => {
                const win_w = (w -| gap) / 2;
                layouts.configureSafe(ctx, win, .{
                    .x      = @intCast(x + @as(i32, @intCast(w - win_w))),
                    .y      = @intCast(y),
                    .width  = win_w -| border * 2,
                    .height = h     -| border * 2,
                });
                // x stays; shrink w from the right
                w = w -| (win_w + gap);
            },
            .up => {
                const win_h = (h -| gap) / 2;
                layouts.configureSafe(ctx, win, .{
                    .x      = @intCast(x),
                    .y      = @intCast(y + @as(i32, @intCast(h - win_h))),
                    .width  = w     -| border * 2,
                    .height = win_h -| border * 2,
                });
                // y stays; shrink h from the bottom
                h = h -| (win_h + gap);
            },
        }
        dir = dir.next();
    }
}
