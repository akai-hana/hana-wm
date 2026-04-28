//! Binary Space Partitioning tiling layout
//! Recursively partitions the screen using a balanced binary tree.
//TODO: improve these comments

const constants = @import("constants");
const utils     = @import("utils");
const layouts   = @import("layouts");
const tiling    = @import("tiling");
const State     = tiling.State;

/// Tile `windows` into a balanced BSP layout using the given screen area.
/// Strips the outer gap margin, then delegates to the recursive `tileRegion` splitter.
pub fn tileWithOffset(
    ctx:      *const layouts.LayoutCtx,
    state:    *State,
    windows:  []const u32,
    screen_w: u16,
    screen_h: u16,
    y_offset: u16,
) void {
    if (windows.len == 0) return;

    const m = state.margins();

    var defer_slot = layouts.DeferredConfigure.init(ctx);

    // Strip the outer gap; each recursive split inserts one gap at its seam,
    // so adjacent windows are always separated by exactly one gap_width.
    tileRegion(
        ctx,
        windows,
        m,
        @as(i32, @intCast(m.gap)),
        @as(i32, @intCast(y_offset +| m.gap)),
        screen_w -| m.gap *| 2,
        screen_h -| m.gap *| 2,
        &defer_slot,
    );

    defer_slot.flush(ctx);
}

/// Recursively tile `windows` into the region (x, y, w, h).
/// Splits the longer axis 50/50, inserting one gap at each seam; border subtracted at leaf nodes only.
/// Ties (w == h) favour a vertical split.
fn tileRegion(
    ctx:        *const layouts.LayoutCtx,
    windows:    []const u32,
    m:          utils.Margins,
    x: i32,
    y: i32,
    w: u16,
    h: u16,
    defer_slot: *layouts.DeferredConfigure,
) void {
    const n = windows.len;
    if (n == 0) return;

    const b2: u16 = 2 *| m.border;

    // Leaf: place the single window in this region.
    if (n == 1) {
        const rect = utils.Rect{
            .x      = @intCast(x),
            .y      = @intCast(y),
            .width  = if (w > b2) w - b2 else constants.MIN_WINDOW_DIM,
            .height = if (h > b2) h - b2 else constants.MIN_WINDOW_DIM,
        };
        if (!defer_slot.capture(ctx, windows[0], rect))
            layouts.configureWithHints(ctx, windows[0], rect);
        return;
    }

    // Internal node: split this region into two and recurse.
    const n_left: usize = n / 2;
    const gap = m.gap;

    if (w >= h) {
        // Vertical split (wide/square region)
        const left_w: u16  = if (w > gap) (w - gap) / 2 else constants.MIN_WINDOW_DIM;
        const right_w: u16 = if (w > left_w +| gap) w - left_w - gap
                             else constants.MIN_WINDOW_DIM;
        const right_x: i32 = x + @as(i32, @intCast(left_w +| gap));

        tileRegion(ctx, windows[0..n_left], m, x,       y, left_w,  h, defer_slot);
        tileRegion(ctx, windows[n_left..],  m, right_x, y, right_w, h, defer_slot);
    } else {
        // Horizontal split (tall region)
        const top_h: u16    = if (h > gap) (h - gap) / 2 else constants.MIN_WINDOW_DIM;
        const bottom_h: u16 = if (h > top_h +| gap) h - top_h - gap
                              else constants.MIN_WINDOW_DIM;
        const bottom_y: i32 = y + @as(i32, @intCast(top_h +| gap));

        tileRegion(ctx, windows[0..n_left], m, x, y,        w, top_h,    defer_slot);
        tileRegion(ctx, windows[n_left..],  m, x, bottom_y, w, bottom_h, defer_slot);
    }
}