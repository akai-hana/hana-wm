//! Fibonacci (spiral) tiling layout.
//! Arranges windows in a clockwise spiral, each taking half the remaining screen area.

const utils = @import("utils");
const model = @import("model");
const tiling = @import("tiling");
const Region = tiling.Region;

// Clockwise spiral direction for the next window split.
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
    var cur = outer;
    var dir: SpiralDirection = .right;

    const windows = v.order;
    const ctx = tiling.LayoutCtx.init(v, out);
    for (windows, 0..) |win, i| {
        const last = i == windows.len - 1;
        // Too small for another split: the seam would leave no room for a
        // border either side. Gate is geometry-only (gap+borders), unlike
        // leaf.zig's 2*min_dim+gap floor for a flat two-child pane.
        if (last or cur.w < m.gap *| 2 + border2 or cur.h < m.gap *| 2 + border2) {
            // focusedElse: fallback is the current split-remainder head.
            const top = tiling.focusedElse(v, windows[i..], win);
            tiling.emitOverflowShare(ctx, windows[i..], top, cur);
            return;
        }

        splitAndAdvance(ctx, win, dir, &cur);
        dir = dir.next();
    }
}

inline fn splitAndAdvance(
    ctx: tiling.LayoutCtx,
    win: model.WindowId,
    dir: SpiralDirection,
    cur: *Region,
) void {
    const m = ctx.m;
    const border2 = utils.doubledBorder(m);
    const gap = m.gap;
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

    tiling.emitRect(
        ctx.v,
        ctx.out,
        win,
        cur.x + off_x,
        cur.y + off_y,
        (if (split_x) win_dim else cur.w) -| border2,
        (if (split_x) cur.h else win_dim) -| border2,
    );
    if (forward and split_x) cur.x += @intCast(win_dim + gap);
    if (forward and !split_x) cur.y += @intCast(win_dim + gap);
    if (split_x) {
        cur.w = cur.w -| (win_dim + gap);
    } else {
        cur.h = cur.h -| (win_dim + gap);
    }
}

/// This layout's registry contribution: metadata plus the dispatch hook.
pub const module = tiling.layoutModule("fibonacci", "[@]", compute, .{});
