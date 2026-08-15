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
            const top_rect = utils.Rect{
                .x = @intCast(x),
                .y = @intCast(y),
                .width = layouts.shrinkClamped(w, border2, state.config.min_window_dim),
                .height = layouts.shrinkClamped(h, border2, state.config.min_window_dim),
            };
            // Find the focused window among the overflow set; fall back to the
            // first window if no focused window is present here. Same reasoning
            // as monocle: showOneHideRest never raises on a background retile
            // (LayoutCtx.is_background) — there's no viewer to show it to, and
            // raising would leave it first in the global stacking order.
            const top = layouts.focusedElse(ctx, windows[i..], windows[i]);
            layouts.showOneHideRest(ctx, windows[i..], top, top_rect);
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
    const split_x = dir == .right or dir == .left;
    const dim: u16 = if (split_x) w.* else h.*;
    const win_dim = (dim -| gap) / 2;
    const off: u16 = if (dir == .right or dir == .down) 0 else dim - win_dim;
    const off_x: i32 = if (split_x) @intCast(off) else 0;
    const off_y: i32 = if (split_x) 0 else @intCast(off);
    const advance: i32 = if (dir == .right or dir == .down) @intCast(win_dim + gap) else 0;

    const rect = utils.Rect{
        .x = @intCast(x.* + off_x),
        .y = @intCast(y.* + off_y),
        .width = (if (split_x) win_dim else w.*) -| border2,
        .height = (if (split_x) h.* else win_dim) -| border2,
    };
    layouts.emitOrDefer(ctx, win, rect);
    x.* += advance;
    y.* += advance;
    if (split_x) {
        w.* = w.* -| (win_dim + gap);
    } else {
        h.* = h.* -| (win_dim + gap);
    }
}
