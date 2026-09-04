//! Fibonacci (spiral) tiling layout.
//! Arranges windows in a counter-clockwise spiral, each taking half the remaining screen area.

const utils = @import("utils");
const model = @import("model");
const tiling = @import("tiling");

// Counter-clockwise spiral direction for the next window split.
const SpiralDirection = enum(u2) {
    right, // Split vertically: window on left, remainder on right.
    down, // Split horizontally: window on top, remainder below.
    left, // Split vertically: window on right, remainder on left.
    up, // Split horizontally: window on bottom, remainder above.

    inline fn next(self: SpiralDirection) SpiralDirection {
        // Increments by one, wrapping past `up` via the 2-bit representation.
        return @enumFromInt(@intFromEnum(self) +% 1);
    }
};

/// Compute Fibonacci spiral layout. Outer gap stripped first; each split
/// halves the remaining dimension with one gap at the seam. Drawn by value;
/// helpers take a pointer to avoid copies in the recursive path.
pub fn compute(v: tiling.View, out: *tiling.List) void {
    const m = v.env.margins;
    const border2 = utils.doubledBorder(m);

    const outer = tiling.outerArea(v.workarea, m.gap);
    var cur = Cursor{
        .x = outer.x,
        .y = outer.y,
        .w = outer.w,
        .h = outer.h,
    };
    var dir: SpiralDirection = .right;

    // Minimum remaining dimension for a window (gap + border on each side).
    const min_area = m.gap * 2 + border2;

    const windows = v.order;
    for (windows, 0..) |win, i| {
        // Too small to split: raise a window and push the rest offscreen.
        if (cur.w < min_area or cur.h < min_area) {
            const top_rect = utils.Rect{
                .x = @intCast(cur.x),
                .y = @intCast(cur.y),
                .width = tiling.shrinkClamped(cur.w, border2, v.env.min_dim),
                .height = tiling.shrinkClamped(cur.h, border2, v.env.min_dim),
            };
            // Raise focusedElse's pick among the overflow set and park the rest.
            const top = tiling.focusedElse(&v, windows[i..], windows[i]);
            tiling.emitView(&v, out, top, top_rect, true);
            for (windows[i..]) |w| {
                if (w == top) continue;
                tiling.emitHidden(out, w);
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
            tiling.emitView(&v, out, win, rect, true);
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
    v: *const tiling.View,
    out: *tiling.List,
    win: model.WindowId,
    dir: SpiralDirection,
    border2: u16,
    gap: u16,
    cur: *Cursor,
) void {
    const split_x = dir == .right or dir == .left;
    const forward = dir == .right or dir == .down;
    // forward (right/down) places the window at the leading edge; backward
    // (left/up) keeps the origin put and only shrinks the remaining dimension.
    const dim: u16 = if (split_x) cur.w else cur.h;
    const win_dim = (dim -| gap) / 2;
    const off: u16 = if (forward) 0 else dim - win_dim;
    const off_x: i32 = if (split_x) @intCast(off) else 0;
    const off_y: i32 = if (split_x) 0 else @intCast(off);
    const advance: i32 = if (forward) @intCast(win_dim + gap) else 0;

    const rect = utils.Rect{
        .x = @intCast(cur.x + off_x),
        .y = @intCast(cur.y + off_y),
        .width = (if (split_x) win_dim else cur.w) -| border2,
        .height = (if (split_x) cur.h else win_dim) -| border2,
    };
    tiling.emitView(v, out, win, rect, true);
    if (dir == .right) cur.x += advance;
    if (dir == .down) cur.y += advance;
    if (split_x) {
        cur.w = cur.w -| (win_dim + gap);
    } else {
        cur.h = cur.h -| (win_dim + gap);
    }
}

/// This layout's registry contribution: metadata plus the dispatch hook.
pub const module: @import("plugin").Layout = .{
    .name = "fibonacci",
    .compute = tiling.computeHook(compute),
    .variant_count = 1,
    .icon = "[@]",
};
