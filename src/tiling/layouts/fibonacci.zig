//! Fibonacci (spiral) tiling layout.
//! Windows spiral counter-clockwise: right, down, left, up, repeat.

const constants = @import("constants");
const utils     = @import("utils");
const layouts   = @import("layouts");
const tiling    = @import("tiling");
const State     = tiling.State;

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
    ctx:      *const layouts.LayoutCtx,
    state:    *State,
    visible:  []const u32,
    screen_w: u16,
    screen_h: u16,
    y_offset: u16,
) void {
    if (visible.len == 0) return;

    const margin = state.margins();
    const gap = margin.gap;
    const b2  = margin.border * 2;

    var x: i32 = @intCast(gap);
    var y: i32 = @intCast(y_offset +| gap);
    var w: u16 = screen_w -| gap *| 2;
    var h: u16 = screen_h -| gap *| 2;
    var dir: Direction = .right;

    for (visible, 0..) |win, i| {
        // Remaining area too small to split: stack all overflow windows here.
        if (w < gap * 2 + b2 or h < gap * 2 + b2) {
            const rect = utils.Rect{
                .x      = @intCast(x),
                .y      = @intCast(y),
                .width  = if (w > b2) w - b2 else constants.MIN_WINDOW_DIM,
                .height = if (h > b2) h - b2 else constants.MIN_WINDOW_DIM,
            };
            for (visible[i..]) |ow| layouts.configureSafe(ctx, ow, rect);
            return;
        }

        if (i == visible.len - 1) {
            layouts.configureSafe(ctx, win, .{
                .x      = @intCast(x),
                .y      = @intCast(y),
                .width  = w -| b2,
                .height = h -| b2,
            });
            return;
        }

        switch (dir) {
            .right => {
                const win_w = (w -| gap) / 2;
                layouts.configureSafe(ctx, win, .{
                    .x      = @intCast(x),
                    .y      = @intCast(y),
                    .width  = win_w -| b2,
                    .height = h     -| b2,
                });
                x += @as(i32, @intCast(win_w + gap));
                w  = w -| (win_w + gap);
            },
            .down => {
                const win_h = (h -| gap) / 2;
                layouts.configureSafe(ctx, win, .{
                    .x      = @intCast(x),
                    .y      = @intCast(y),
                    .width  = w     -| b2,
                    .height = win_h -| b2,
                });
                y += @as(i32, @intCast(win_h + gap));
                h  = h -| (win_h + gap);
            },
            .left => {
                const win_w = (w -| gap) / 2;
                layouts.configureSafe(ctx, win, .{
                    .x      = @intCast(x + @as(i32, @intCast(w - win_w))),
                    .y      = @intCast(y),
                    .width  = win_w -| b2,
                    .height = h     -| b2,
                });
                w = w -| (win_w + gap); // x stays; shrink from right
            },
            .up => {
                const win_h = (h -| gap) / 2;
                layouts.configureSafe(ctx, win, .{
                    .x      = @intCast(x),
                    .y      = @intCast(y + @as(i32, @intCast(h - win_h))),
                    .width  = w     -| b2,
                    .height = win_h -| b2,
                });
                h = h -| (win_h + gap); // y stays; shrink from bottom
            },
        }
        dir = dir.next();
    }
}
