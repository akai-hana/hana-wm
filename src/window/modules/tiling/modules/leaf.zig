//! Binary Space Partitioning tiling layout.
//!
//! Recursively splits the window list and screen region in lockstep: each
//! internal node bisects along its longer axis (ties split vertically) and
//! hands the halves to the halves of the window list, yielding ~log2(n)
//! balanced leaves. One gap per seam; the outer gap is stripped up front,
//! borders subtracted only at leaves.

const utils = @import("utils");
const layouts = @import("layouts");
const tiling = @import("tiling");
const State = tiling.State;

/// Tile `windows` into a balanced BSP layout using the given screen area.
/// Strips the outer gap margin, then delegates to the recursive `tileRegion` splitter.
pub fn tileWithOffset(
    ctx: *const layouts.LayoutCtx,
    state: *State,
    windows: []const u32,
    screen_w: u16,
    screen_h: u16,
    y_offset: u16,
) void {
    const m = state.margins();
    const min_dim = state.config.min_window_dim;

    // Strip the outer gap; each recursive split inserts one gap at its seam
    // (adjacent windows stay one gap_width apart). emitOrDefer honors ctx.defer_win.
    const area = layouts.outerArea(screen_w, screen_h, y_offset, m.gap);
    tileRegion(ctx, windows, m, min_dim, area.x, area.y, area.w, area.h);
}

/// Splits `dim` into two halves separated by `gap`, clamping each half to
/// `min_dim` when `dim` is too small — recursive calls never produce zero-size
/// regions, and `first + gap + second ≈ dim` for normal inputs.
inline fn halveWithMin(dim: u16, gap: u16, min_dim: u16) struct { first: u16, second: u16 } {
    const first: u16 = if (dim > gap) (dim - gap) / 2 else min_dim;
    const second: u16 = if (dim > first +| gap) dim - first - gap else min_dim;
    return .{ .first = first, .second = second };
}

/// Recursively tile `windows` into the region (x, y, w, h).
/// Splits the longer axis 50/50, inserting one gap at each seam; border subtracted at leaf nodes only.
/// Ties (w == h) favour a vertical split.
fn tileRegion(
    ctx: *const layouts.LayoutCtx,
    windows: []const u32,
    m: utils.Margins,
    min_dim: u16,
    x: i32,
    y: i32,
    w: u16,
    h: u16,
) void {
    const n = windows.len;
    if (n == 0) return;

    const b2: u16 = utils.doubledBorder(m);

    // Leaf: place the single window in this region.
    if (n == 1) {
        const rect = utils.Rect{
            .x = @intCast(x),
            .y = @intCast(y),
            .width = layouts.shrinkClamped(w, b2, min_dim),
            .height = layouts.shrinkClamped(h, b2, min_dim),
        };
        layouts.emitOrDefer(ctx, windows[0], rect);
        return;
    }

    // Internal node: split this region into two and recurse.
    const n_left: usize = n / 2;
    const gap = m.gap;

    if (w >= h) {
        // Vertical split (wide/square region)
        const split = halveWithMin(w, gap, min_dim);
        const right_x: i32 = x + @as(i32, @intCast(split.first +| gap));
        tileRegion(ctx, windows[0..n_left], m, min_dim, x, y, split.first, h);
        tileRegion(ctx, windows[n_left..], m, min_dim, right_x, y, split.second, h);
    } else {
        // Horizontal split (tall region)
        const split = halveWithMin(h, gap, min_dim);
        const bottom_y: i32 = y + @as(i32, @intCast(split.first +| gap));
        tileRegion(ctx, windows[0..n_left], m, min_dim, x, y, w, split.first);
        tileRegion(ctx, windows[n_left..], m, min_dim, x, bottom_y, w, split.second);
    }
}
