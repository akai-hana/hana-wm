//! Fibonacci (spiral) tiling layout (pure port of modules/fibonacci.zig).
//! Arranges windows in a counter-clockwise spiral, each taking half the remaining screen area.

const utils = @import("utils");
const model = @import("model");
const engine = @import("engine");

// Counter-clockwise spiral direction for the next window split.
const SpiralDirection = enum(u2) {
    right, // Split vertically:   window on left,   remainder on right.
    down, // Split horizontally: window on top,    remainder below.
    left, // Split vertically:   window on right,  remainder on left.
    up, // Split horizontally: window on bottom, remainder above.

    inline fn next(self: SpiralDirection) SpiralDirection {
        return @enumFromInt(@intFromEnum(self) +% 1); // 2-bit wrapping; 4 variants
    }
};

/// Compute Fibonacci spiral layout. Origin top-left, y-down. Outer gap
/// stripped first; each split halves the remaining dimension with one gap
/// at the seam. Spiral direction cycles right→down→left→up. Dimensions are
/// u16, integer-halved; border subtracted at placement time.
// View is small enough to pass by value; helpers take pointer to avoid
// copies in the recursive path.
pub fn compute(v: engine.View, out: *engine.List) void {
    const m = v.env.margins;
    const border2 = utils.doubledBorder(m);

    const outer = engine.outerArea(v.workarea, m.gap);
    var cur = Cursor{
        .x = outer.x,
        .y = outer.y,
        .w = outer.w,
        .h = outer.h,
    };
    var dir: SpiralDirection = .right;

    // Minimum remaining dimension to place a window (gap on each side + border
    // on each side). Loop-invariant: hoisted to avoid redundant arithmetic.
    const min_area = m.gap * 2 + border2;

    const windows = v.order;
    for (windows, 0..) |win, i| {
        // Remaining area too small to split: raise the focused window (or the
        // first overflow window as fallback) and push the rest offscreen so the
        // user at least sees one window rather than a stack of identical rects.
        if (cur.w < min_area or cur.h < min_area) {
            const top_rect = utils.Rect{
                .x = @intCast(cur.x),
                .y = @intCast(cur.y),
                .width = engine.shrinkClamped(cur.w, border2, v.env.min_dim),
                .height = engine.shrinkClamped(cur.h, border2, v.env.min_dim),
            };
            // Find the focused window among the overflow set; fall back to the
            // first window if no focused window is present here. Same reasoning
            // as monocle: never raise on a background retile; there's no viewer
            // to show it to, and raising would leave it first in the global
            // stacking order. (Background handling is sync's stacking policy.)
            const top = engine.focusedElse(&v, windows[i..], windows[i]);
            engine.emitView(&v, out, top, top_rect, true);
            for (windows[i..]) |w| {
                if (w == top) continue;
                engine.emitHidden(out, w);
            }
            return;
        }

        if (i == windows.len - 1) {
            const rect = utils.Rect{
                .x = @intCast(cur.x),
                .y = @intCast(cur.y),
                .width = cur.w -| border2,
                .height = cur.h -| border2,
            };
            engine.emitView(&v, out, win, rect, true);
            return;
        }

        splitAndAdvance(&v, out, win, dir, border2, m.gap, &cur);
        dir = dir.next();
    }
}

// Mutable cursor tracking the remaining screen area as windows are placed.
const Cursor = struct {
    x: i32,
    y: i32,
    w: u16,
    h: u16,
};

inline fn splitAndAdvance(
    v: *const engine.View,
    out: *engine.List,
    win: model.WindowId,
    dir: SpiralDirection,
    border2: u16,
    gap: u16,
    cur: *Cursor,
) void {
    const split_x = dir == .right or dir == .left;
    const dim: u16 = if (split_x) cur.w else cur.h;
    const win_dim = (dim -| gap) / 2;
    const off: u16 = if (dir == .right or dir == .down) 0 else dim - win_dim;
    const off_x: i32 = if (split_x) @intCast(off) else 0;
    const off_y: i32 = if (split_x) 0 else @intCast(off);
    const advance: i32 = if (dir == .right or dir == .down) @intCast(win_dim + gap) else 0;

    const rect = utils.Rect{
        .x = @intCast(cur.x + off_x),
        .y = @intCast(cur.y + off_y),
        .width = (if (split_x) win_dim else cur.w) -| border2,
        .height = (if (split_x) cur.h else win_dim) -| border2,
    };
    engine.emitView(v, out, win, rect, true);
    // Positional advance only when the remainder lies ahead of the placed
    // window (right/down); for left/up the origin stays and only the
    // dimension shrinks. The shrink applies in every direction.
    if (dir == .right) cur.x += advance;
    if (dir == .down) cur.y += advance;
    if (split_x) {
        cur.w = cur.w -| (win_dim + gap);
    } else {
        cur.h = cur.h -| (win_dim + gap);
    }
}
