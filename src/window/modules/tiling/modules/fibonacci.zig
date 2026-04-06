//! Fibonacci (spiral) tiling layout.
//!
//! Windows spiral counter-clockwise through the available area: the first
//! window takes the left half, the second takes the top half of the remainder,
//! the third the right half, the fourth the bottom half, and so on. When the
//! remaining area becomes too small to split further, all overflow windows are
//! stacked at the same position.

const constants = @import("constants");
const utils     = @import("utils");
const layouts   = @import("layouts");
const tiling    = @import("tiling");
const State     = tiling.State;

/// Counter-clockwise spiral direction for the next window split.
const SpiralDirection = enum {
    right, // Split vertically:   window on left,   remainder on right.
    down,  // Split horizontally: window on top,    remainder below.
    left,  // Split vertically:   window on right,  remainder on left.
    up,    // Split horizontally: window on bottom, remainder above.

    inline fn next(self: SpiralDirection) SpiralDirection {
        return switch (self) {
            .right => .down,
            .down  => .left,
            .left  => .up,
            .up    => .right,
        };
    }
};

/// Tile `windows` into a Fibonacci spiral using the given screen area.
pub fn tileWithOffset(
    ctx:      *const layouts.LayoutCtx,
    state:    *State,
    windows:  []const u32,
    screen_w: u16,
    screen_h: u16,
    y_offset: u16,
) void {
    if (windows.len == 0) return;

    const m  = state.margins();
    const b2 = m.border * 2;

    var x: i32 = @intCast(m.gap);
    var y: i32 = @intCast(y_offset +| m.gap);
    var w: u16 = screen_w -| m.gap *| 2;
    var h: u16 = screen_h -| m.gap *| 2;
    var dir: SpiralDirection = .right;

    for (windows, 0..) |win, i| {
        // Remaining area too small to split: stack all overflow windows here.
        if (w < m.gap * 2 + b2 or h < m.gap * 2 + b2) {
            const overflow_rect = utils.Rect{
                .x      = @intCast(x),
                .y      = @intCast(y),
                .width  = if (w > b2) w - b2 else constants.MIN_WINDOW_DIM,
                .height = if (h > b2) h - b2 else constants.MIN_WINDOW_DIM,
            };
            for (windows[i..]) |overflow_win| layouts.configureWithHints(ctx, overflow_win, overflow_rect);
            return;
        }

        // Last window takes the entire remaining area.
        if (i == windows.len - 1) {
            layouts.configureWithHints(ctx, win, .{
                .x      = @intCast(x),
                .y      = @intCast(y),
                .width  = w -| b2,
                .height = h -| b2,
            });
            return;
        }

        splitAndAdvance(ctx, win, dir, b2, m.gap, &x, &y, &w, &h);
        dir = dir.next();
    }
}

// ============================================================================
// Private helpers
// ============================================================================

/// Place `win` in its split half and advance the remaining area cursor.
inline fn splitAndAdvance(
    ctx: *const layouts.LayoutCtx,
    win: u32,
    dir: SpiralDirection,
    b2:  u16,
    gap: u16,
    x: *i32, y: *i32, w: *u16, h: *u16,
) void {
    switch (dir) {
        .right => {
            const win_w = (w.* -| gap) / 2;
            layouts.configureWithHints(ctx, win, .{
                .x = @intCast(x.*), .y = @intCast(y.*),
                .width = win_w -| b2, .height = h.* -| b2,
            });
            x.* += @as(i32, @intCast(win_w + gap));
            w.*  = w.* -| (win_w + gap);
        },
        .down => {
            const win_h = (h.* -| gap) / 2;
            layouts.configureWithHints(ctx, win, .{
                .x = @intCast(x.*), .y = @intCast(y.*),
                .width = w.* -| b2, .height = win_h -| b2,
            });
            y.* += @as(i32, @intCast(win_h + gap));
            h.*  = h.* -| (win_h + gap);
        },
        .left => {
            const win_w = (w.* -| gap) / 2;
            layouts.configureWithHints(ctx, win, .{
                .x = @intCast(x.* + @as(i32, @intCast(w.* - win_w))),
                .y = @intCast(y.*),
                .width = win_w -| b2, .height = h.* -| b2,
            });
            w.* = w.* -| (win_w + gap); // x stays; shrink from the right
        },
        .up => {
            const win_h = (h.* -| gap) / 2;
            layouts.configureWithHints(ctx, win, .{
                .x = @intCast(x.*),
                .y = @intCast(y.* + @as(i32, @intCast(h.* - win_h))),
                .width = w.* -| b2, .height = win_h -| b2,
            });
            h.* = h.* -| (win_h + gap); // y stays; shrink from the bottom
        },
    }
}