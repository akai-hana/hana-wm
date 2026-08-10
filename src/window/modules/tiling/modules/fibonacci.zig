//! Fibonacci (spiral) tiling layout
//! Arranges windows in a counter-clockwise spiral, each taking half the remaining screen area.

const std = @import("std");
const utils = @import("utils");
const layouts = @import("layouts");
const tiling = @import("tiling");
const State = tiling.State;

/// Counter-clockwise spiral direction for the next window split.
const SpiralDirection = enum(u2) {
    right, // Split vertically:   window on left,   remainder on right.
    down, // Split horizontally: window on top,    remainder below.
    left, // Split vertically:   window on right,  remainder on left.
    up, // Split horizontally: window on bottom, remainder above.

    inline fn next(self: SpiralDirection) SpiralDirection {
        return @enumFromInt(@intFromEnum(self) +% 1); // 2-bit wrapping; 4 variants
    }
};

/// Tile `windows` into a Fibonacci spiral using the given screen area.
pub fn tileWithOffset(
    ctx: *const layouts.LayoutCtx,
    state: *State,
    windows: []const u32,
    screen_w: u16,
    screen_h: u16,
    y_offset: u16,
) void {
    const m = state.margins();
    const border2 = utils.doubledBorder(m);

    const outer = layouts.outerArea(screen_w, screen_h, y_offset, m.gap);
    var x: i32 = outer.x;
    var y: i32 = outer.y;
    var w: u16 = outer.w;
    var h: u16 = outer.h;
    var dir: SpiralDirection = .right;

    // splitAndAdvance's emitOrDefer honors ctx.defer_win — see LayoutCtx.defer_win.
    for (windows, 0..) |win, i| {
        // Remaining area too small to split: raise the focused window (or the
        // first overflow window as fallback) and push the rest offscreen so the
        // user at least sees one window rather than a stack of identical rects.
        if (w < m.gap * 2 + border2 or h < m.gap * 2 + border2) {
            const overflow_rect = utils.Rect{
                .x = @intCast(x),
                .y = @intCast(y),
                .width = layouts.shrinkClamped(w, border2),
                .height = layouts.shrinkClamped(h, border2),
            };
            // Find the focused window among the overflow set; fall back to the
            // first window if no focused window is present here.
            const raise_win: u32 = if (ctx.focused_win) |f|
                if (std.mem.indexOfScalar(u32, windows[i..], f) != null) f else windows[i]
            else
                windows[i];
            // Same reasoning as monocle: never raise for a background retile
            // (see LayoutCtx.is_background) — there's no on-screen viewer to
            // show `raise_win` to, and raising it would leave it first in the
            // global stacking order with nothing to ever lower it again.
            layouts.configureWithHintsAndRaiseIfVisible(ctx, raise_win, overflow_rect);
            for (windows[i..]) |overflow_win| {
                if (overflow_win == raise_win) continue;
                layouts.pushWindowOffscreenAndInvalidate(ctx, overflow_win);
            }
            return;
        }

        // Last window takes the entire remaining area.
        if (i == windows.len - 1) {
            const rect = utils.Rect{
                .x = @intCast(x),
                .y = @intCast(y),
                .width = w -| border2,
                .height = h -| border2,
            };
            layouts.emitOrDefer(ctx, win, rect);
            return;
        }

        splitAndAdvance(ctx, win, dir, border2, m.gap, &x, &y, &w, &h);
        dir = dir.next();
    }
}

/// Place `win` in its split half and advance the remaining area cursor.
inline fn splitAndAdvance(
    ctx: *const layouts.LayoutCtx,
    win: u32,
    dir: SpiralDirection,
    border2: u16,
    gap: u16,
    x: *i32,
    y: *i32,
    w: *u16,
    h: *u16,
) void {
    switch (dir) {
        .right => {
            const win_w = (w.* -| gap) / 2;
            const rect = utils.Rect{
                .x = @intCast(x.*),
                .y = @intCast(y.*),
                .width = win_w -| border2,
                .height = h.* -| border2,
            };
            layouts.emitOrDefer(ctx, win, rect);
            x.* += @as(i32, @intCast(win_w + gap));
            w.* = w.* -| (win_w + gap);
        },
        .down => {
            const win_h = (h.* -| gap) / 2;
            const rect = utils.Rect{
                .x = @intCast(x.*),
                .y = @intCast(y.*),
                .width = w.* -| border2,
                .height = win_h -| border2,
            };
            layouts.emitOrDefer(ctx, win, rect);
            y.* += @as(i32, @intCast(win_h + gap));
            h.* = h.* -| (win_h + gap);
        },
        .left => {
            const win_w = (w.* -| gap) / 2;
            const rect = utils.Rect{
                .x = @intCast(x.* + @as(i32, @intCast(w.* - win_w))),
                .y = @intCast(y.*),
                .width = win_w -| border2,
                .height = h.* -| border2,
            };
            layouts.emitOrDefer(ctx, win, rect);
            w.* = w.* -| (win_w + gap);
        },
        .up => {
            const win_h = (h.* -| gap) / 2;
            const rect = utils.Rect{
                .x = @intCast(x.*),
                .y = @intCast(y.* + @as(i32, @intCast(h.* - win_h))),
                .width = w.* -| border2,
                .height = win_h -| border2,
            };
            layouts.emitOrDefer(ctx, win, rect);
            h.* = h.* -| (win_h + gap);
        },
    }
}
