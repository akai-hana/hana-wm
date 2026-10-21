//! Fibonacci (spiral) tiling layout.
//! Arranges windows in a clockwise spiral, each taking half the remaining screen area.

const model = @import("model");
const tiling = @import("tiling");
const shrinkCapped = tiling.shrinkCapped;
const Region = tiling.Region;

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

/// Compute Fibonacci spiral layout. Outer gap stripped first; each split halves
/// the remaining dimension with one gap at the seam. Helpers take a pointer to
/// avoid copies in the recursion.
fn compute(v: *const tiling.View, out: *tiling.List) void {
    const ctx = tiling.LayoutCtx.init(v, out);
    const m = ctx.m;
    // The overflow gate deliberately stays GEOMETRY-ONLY (what the strip can
    // carry): min_dim is handled at EMISSION by capping w/h to the strip's
    // content area, so folding it into the gate would be redundant and would
    // only move the overflow threshold, changing layout batching. The
    // `gap + 2` floor is the split's own positivity requirement: bisectRegion's
    // first half is (dim - gap) / 2, which is 0 when dim <= gap + 1, and a
    // zero-width strip would emit through shrinkCapped's >=1 floor while the
    // remainder stays put, stacking later windows on the same cell.
    // totalInset dominates for any border >= 1; the floor only bites
    // borderless zero/one-gap configs.
    const min_region = @max(tiling.totalInset(m.gap, m), m.gap + 2);

    const outer = tiling.outerArea(v.workarea, m.gap);
    var cur = outer;
    var dir: SpiralDirection = .right;

    const windows = v.order;
    for (windows, 0..) |win, i| {
        const last = i == windows.len - 1;
        // Too small for another split: the seam would leave no room for a
        // border either side. Geometry-only (gap+borders), unlike leaf.zig's
        // 2*min_dim+gap floor for a flat two-child pane.
        if (last or cur.w < min_region or cur.h < min_region) {
            tiling.emitOverflowShare(ctx, windows[i..], cur);
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
    const border2 = model.doubledBorder(m);
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

    const strip_w = if (split_x) win_dim else cur.w;
    const strip_h = if (split_x) cur.h else win_dim;
    const w = shrinkCapped(strip_w, border2);
    const h = shrinkCapped(strip_h, border2);
    tiling.emitRect(ctx.v, ctx.out, win, cur.x + off_x, cur.y + off_y, w, h);
    if (split_x) {
        if (forward) cur.x += @intCast(win_dim + gap);
        cur.w = cur.w -| (win_dim + gap);
    } else {
        if (forward) cur.y += @intCast(win_dim + gap);
        cur.h = cur.h -| (win_dim + gap);
    }
}

pub const module = tiling.layoutModule("fibonacci", "[@]", compute, &.{}, .{});
