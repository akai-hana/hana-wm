//! Fibonacci (spiral) tiling layout.
//! Arranges windows in a counter-clockwise spiral, each taking half the remaining screen area.

const utils = @import("utils");
const model = @import("model");
const tiling = @import("tiling");
const Region = tiling.Region;

// Counter-clockwise spiral direction for the next window split.
const SpiralDirection = enum(u2) {
    right, // Split vertically: window on left, remainder on right.
    down, // Split horizontally: window on top, remainder below.
    left, // Split vertically: window on right, remainder on left.
    up, // Split horizontally: window on bottom, remainder above.

    const Step = struct {
        split_x: bool,
        forward: bool,
    };

    const steps = [_]Step{
        .{ .split_x = true, .forward = true },
        .{ .split_x = false, .forward = true },
        .{ .split_x = true, .forward = false },
        .{ .split_x = false, .forward = false },
    };

    inline fn step(self: SpiralDirection) Step {
        return steps[@intFromEnum(self)];
    }

    inline fn next(self: SpiralDirection) SpiralDirection {
        // Increments by one, wrapping past `up` via the 2-bit representation.
        return @enumFromInt(@intFromEnum(self) +% 1);
    }
};

/// Compute Fibonacci spiral layout. Outer gap stripped first; each split
/// halves the remaining dimension with one gap at the seam. Drawn by pointer;
/// helpers take the pointer to avoid copies in the recursive path.
pub fn compute(v: *const tiling.View, out: *tiling.List) void {
    const m = v.env.margins;
    const border2 = utils.doubledBorder(m);

    const outer = tiling.outerArea(v.workarea, m.gap);
    var cur = Region{
        .x = outer.x,
        .y = outer.y,
        .w = outer.w,
        .h = outer.h,
    };
    var dir: SpiralDirection = .right;

    const windows = v.order;
    for (windows, 0..) |win, i| {
        const last = i == windows.len - 1;
        if (last or cur.w < m.gap *| 2 + border2 or cur.h < m.gap *| 2 + border2) {
            const top = if (last) win else tiling.focusedElse(v, windows[i..], windows[i]);
            tiling.emitView(v, out, top, tiling.insetRect(cur.x, cur.y, cur.w, cur.h, border2, v.env.min_dim), true);
            if (!last) tiling.showOneHideRest(out, windows[i..], top);
            return;
        }

        splitAndAdvance(v, out, win, dir, border2, m.gap, &cur);
        dir = dir.next();
    }
}

inline fn splitAndAdvance(
    v: *const tiling.View,
    out: *tiling.List,
    win: model.WindowId,
    dir: SpiralDirection,
    border2: u16,
    gap: u16,
    cur: *Region,
) void {
    const step = dir.step();
    const split_x = step.split_x;
    const forward = step.forward;
    // forward (right/down) places the window at the leading edge; backward
    // (left/up) keeps the origin put and only shrinks the remaining dimension.
    const dim: u16 = if (split_x) cur.w else cur.h;
    const win_dim = tiling.bisectRegion(dim, gap).first;
    const off: u16 = if (forward) 0 else dim - win_dim;
    const off_x: i32 = if (split_x) @intCast(off) else 0;
    const off_y: i32 = if (split_x) 0 else @intCast(off);
    const advance: i32 = if (forward) @intCast(win_dim + gap) else 0;

    const rect = utils.Rect{
        .x = tiling.satI16(cur.x + off_x),
        .y = tiling.satI16(cur.y + off_y),
        .width = (if (split_x) win_dim else cur.w) -| border2,
        .height = (if (split_x) cur.h else win_dim) -| border2,
    };
    tiling.emitView(v, out, win, rect, true);
    if (forward and split_x) cur.x += advance;
    if (forward and !split_x) cur.y += advance;
    if (split_x) {
        cur.w = cur.w -| (win_dim + gap);
    } else {
        cur.h = cur.h -| (win_dim + gap);
    }
}

/// This layout's registry contribution: metadata plus the dispatch hook.
pub const module = tiling.layoutModule("fibonacci", "[@]", compute, .{});
