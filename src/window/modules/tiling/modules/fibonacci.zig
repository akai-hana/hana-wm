//! Fibonacci (spiral) tiling layout
//! Arranges windows in a counter-clockwise spiral, each taking half the remaining screen area.

const constants = @import("constants");
const utils     = @import("utils");
const layouts   = @import("layouts");
const tiling    = @import("tiling");
const State     = tiling.State;

/// Counter-clockwise spiral direction for the next window split.
const SpiralDirection = enum(u2) {
    right, // Split vertically:   window on left,   remainder on right.
    down,  // Split horizontally: window on top,    remainder below.
    left,  // Split vertically:   window on right,  remainder on left.
    up,    // Split horizontally: window on bottom, remainder above.

    inline fn next(self: SpiralDirection) SpiralDirection {
        return @enumFromInt(@intFromEnum(self) +% 1); // 2-bit wrapping; 4 variants
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

    const m       = state.margins();
    const border2 = 2 *| m.border;

    var x: i32 = @intCast(m.gap);
    var y: i32 = @intCast(y_offset +| m.gap);
    var w: u16 = screen_w -| m.gap *| 2;
    var h: u16 = screen_h -| m.gap *| 2;
    var dir: SpiralDirection = .right;

    var defer_slot = layouts.DeferredConfigure.init(ctx);

    for (windows, 0..) |win, i| {
        // Remaining area too small to split: stack all overflow windows here.
        if (w < m.gap * 2 + border2 or h < m.gap * 2 + border2) {
            const overflow_rect = utils.Rect{
                .x      = @intCast(x),
                .y      = @intCast(y),
                .width  = if (w > border2) w - border2 else constants.MIN_WINDOW_DIM,
                .height = if (h > border2) h - border2 else constants.MIN_WINDOW_DIM,
            };
            for (windows[i..]) |overflow_win| {
                if (!defer_slot.capture(ctx, overflow_win, overflow_rect))
                    layouts.configureWithHints(ctx, overflow_win, overflow_rect);
            }
            defer_slot.flush(ctx);
            return;
        }

        // Last window takes the entire remaining area.
        if (i == windows.len - 1) {
            const rect = utils.Rect{
                .x      = @intCast(x),
                .y      = @intCast(y),
                .width  = w -| border2,
                .height = h -| border2,
            };
            if (!defer_slot.capture(ctx, win, rect))
                layouts.configureWithHints(ctx, win, rect);
            defer_slot.flush(ctx);
            return;
        }

        splitAndAdvance(ctx, win, dir, &defer_slot, border2, m.gap, &x, &y, &w, &h);
        dir = dir.next();
    }
    defer_slot.flush(ctx);
}

/// Place `win` in its split half and advance the remaining area cursor.
/// If `win` is the deferred window, stores its rect in `defer_slot` rather
/// than calling configureWithHints — the caller flushes it after the loop.
inline fn splitAndAdvance(
    ctx:        *const layouts.LayoutCtx,
    win:        u32,
    dir:        SpiralDirection,
    defer_slot: *layouts.DeferredConfigure,
    border2:    u16,
    gap:        u16,
    x: *i32, y: *i32, w: *u16, h: *u16,
) void {
    switch (dir) {
        .right => {
            const win_w = (w.* -| gap) / 2;
            const rect = utils.Rect{
                .x = @intCast(x.*), .y = @intCast(y.*),
                .width = win_w -| border2, .height = h.* -| border2,
            };
            if (!defer_slot.capture(ctx, win, rect)) layouts.configureWithHints(ctx, win, rect);
            x.* += @as(i32, @intCast(win_w + gap));
            w.*  = w.* -| (win_w + gap);
        },
        .down => {
            const win_h = (h.* -| gap) / 2;
            const rect = utils.Rect{
                .x = @intCast(x.*), .y = @intCast(y.*),
                .width = w.* -| border2, .height = win_h -| border2,
            };
            if (!defer_slot.capture(ctx, win, rect)) layouts.configureWithHints(ctx, win, rect);
            y.* += @as(i32, @intCast(win_h + gap));
            h.*  = h.* -| (win_h + gap);
        },
        .left => {
            const win_w = (w.* -| gap) / 2;
            const rect = utils.Rect{
                .x = @intCast(x.* + @as(i32, @intCast(w.* - win_w))),
                .y = @intCast(y.*),
                .width = win_w -| border2, .height = h.* -| border2,
            };
            if (!defer_slot.capture(ctx, win, rect)) layouts.configureWithHints(ctx, win, rect);
            w.* = w.* -| (win_w + gap);
        },
        .up => {
            const win_h = (h.* -| gap) / 2;
            const rect = utils.Rect{
                .x = @intCast(x.*),
                .y = @intCast(y.* + @as(i32, @intCast(h.* - win_h))),
                .width = w.* -| border2, .height = win_h -| border2,
            };
            if (!defer_slot.capture(ctx, win, rect)) layouts.configureWithHints(ctx, win, rect);
            h.* = h.* -| (win_h + gap);
        },
    }
}