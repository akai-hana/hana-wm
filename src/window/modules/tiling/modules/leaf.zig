//! Binary Space Partitioning tiling layout
//! Recursively partitions the screen using a balanced binary tree.
//TODO: improve these comments

const constants = @import("constants");
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
    if (windows.len == 0) return;

    const m = state.margins();

    // Strip the outer gap; each recursive split inserts one gap at its seam,
    // so adjacent windows are always separated by exactly one gap_width.
    // If swap_master deferred a window (see LayoutCtx.defer_win), emitOrDefer
    // (called from the leaf case of tileRegion below) stashes its rect into
    // ctx.deferred; invokeLayout flushes it once, after this whole call tree
    // returns, instead of inline during the recursion.
    tileRegion(
        ctx,
        windows,
        m,
        @as(i32, @intCast(m.gap)),
        @as(i32, @intCast(y_offset +| m.gap)),
        screen_w -| m.gap *| 2,
        screen_h -| m.gap *| 2,
    );
}

/// Splits `dim` into two halves separated by `gap`.
/// Each half is clamped to `constants.MIN_WINDOW_DIM` when `dim` is too small
/// to produce a valid split, so recursive calls never produce zero-size regions.
/// The invariant `first + gap + second ≈ dim` holds for all normal inputs.
inline fn halveWithMin(dim: u16, gap: u16) struct { first: u16, second: u16 } {
    const first: u16 = if (dim > gap) (dim - gap) / 2 else constants.MIN_WINDOW_DIM;
    const second: u16 = if (dim > first +| gap) dim - first - gap else constants.MIN_WINDOW_DIM;
    return .{ .first = first, .second = second };
}

/// Recursively tile `windows` into the region (x, y, w, h).
/// Splits the longer axis 50/50, inserting one gap at each seam; border subtracted at leaf nodes only.
/// Ties (w == h) favour a vertical split.
fn tileRegion(
    ctx: *const layouts.LayoutCtx,
    windows: []const u32,
    m: utils.Margins,
    x: i32,
    y: i32,
    w: u16,
    h: u16,
) void {
    const n = windows.len;
    if (n == 0) return;

    const b2: u16 = 2 *| m.border;

    // Leaf: place the single window in this region.
    if (n == 1) {
        const rect = utils.Rect{
            .x = @intCast(x),
            .y = @intCast(y),
            .width = layouts.shrinkClamped(w, b2),
            .height = layouts.shrinkClamped(h, b2),
        };
        layouts.emitOrDefer(ctx, windows[0], rect);
        return;
    }

    // Internal node: split this region into two and recurse.
    const n_left: usize = n / 2;
    const gap = m.gap;

    if (w >= h) {
        // Vertical split (wide/square region)
        const split = halveWithMin(w, gap);
        const right_x: i32 = x + @as(i32, @intCast(split.first +| gap));
        tileRegion(ctx, windows[0..n_left], m, x, y, split.first, h);
        tileRegion(ctx, windows[n_left..], m, right_x, y, split.second, h);
    } else {
        // Horizontal split (tall region)
        const split = halveWithMin(h, gap);
        const bottom_y: i32 = y + @as(i32, @intCast(split.first +| gap));
        tileRegion(ctx, windows[0..n_left], m, x, y, w, split.first);
        tileRegion(ctx, windows[n_left..], m, x, bottom_y, w, split.second);
    }
}