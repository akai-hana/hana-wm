//! BSP (Binary Space Partitioning) tiling layout
//! Recursively partitions the screen using a balanced binary tree.
//!
//! How it works (based on bspwm):
//!   - Each internal node splits its rectangle in half along the longer
//!     axis (vertical split if wide, horizontal if tall) at a 50/50 ratio.
//!   - Each leaf node holds exactly one window.
//!   - With N windows the tree is balanced: the left/top subtree receives
//!     ⌊N/2⌋ windows and the right/bottom subtree receives ⌈N/2⌉.
//!
//! The result is that every window occupies a roughly equal, non-overlapping
//! region of the screen with no privileged "master" pane.  Every split seam
//! is separated by exactly one gap_width, matching the spacing every other
//! layout uses.
//!
//! Layout examples (gap lines omitted for brevity):
//!
//!   2 windows (wide screen)     3 windows               4 windows
//!   ┌─────────┬─────────┐       ┌─────────┬─────────┐   ┌────┬────┬────┬────┐
//!   │    1    │    2    │       │    1    │    2    │   │  1 │  2 │  3 │  4 │
//!   │         │         │       │         ├─────────┤   │    │    │    │    │
//!   │         │         │       │         │    3    │   │    │    │    │    │
//!   └─────────┴─────────┘       └─────────┴─────────┘   └────┴────┴────┴────┘
//!
//!   5 windows (wide screen)     6 windows
//!   ┌────┬────┬────┬────┬────┐  ┌───┬───┬───┬───┬───┬───┐
//!   │  1 │  2 │  3 │  4 │  5│  │ 1 │ 2 │ 3 │ 4 │ 5 │ 6 │
//!   └────┴────┴────┴────┴───┘  └───┴───┴───┴───┴───┴───┘
//!   (root splits 2|3, each sub-region splits further)

const constants = @import("constants");
const utils     = @import("utils");
const layouts   = @import("layouts");
const tiling    = @import("tiling");
const State     = tiling.State;

/// Tile `windows` into a balanced BSP layout using the given screen area.
///
/// Strips the outer `gap_width` margin on all four sides, then hands off to
/// the recursive `tileRegion` splitter.  Mirrors the tileWithOffset signature
/// of every other layout module.
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

    // Strip the outer gap on all four edges before entering the recursive
    // splitter.  Each subsequent split inserts exactly one gap at its seam,
    // so the total padding between any two adjacent windows equals gap_width.
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

// ============================================================================
// Private helpers
// ============================================================================

/// Recursively assign each window in `windows` to a sub-rectangle of the
/// region described by (x, y, w, h).
///
/// Split direction:  the longer axis is split first.
///                   Ties (w == h) favour a vertical (side-by-side) split.
///
/// Split ratio:      always 50 / 50 — left/top sub-region gets ⌊n/2⌋ windows,
///                   right/bottom sub-region gets the remaining ⌈n/2⌉.
///
/// Gap handling:     one `m.gap` pixel gap is inserted at every split seam.
///                   The border (m.border) is subtracted from leaf nodes only,
///                   exactly as every other layout module does.
fn tileRegion(
    ctx:     *const layouts.LayoutCtx,
    windows: []const u32,
    m:       utils.Margins,
    x: i32,
    y: i32,
    w: u16,
    h: u16,
) void {
    const n = windows.len;
    if (n == 0) return;

    const b2: u16 = 2 *| m.border;

    // ── Leaf: place the single window in this region ─────────────────────────
    if (n == 1) {
        layouts.configureWithHints(ctx, windows[0], .{
            .x      = @intCast(x),
            .y      = @intCast(y),
            .width  = if (w > b2) w - b2 else constants.MIN_WINDOW_DIM,
            .height = if (h > b2) h - b2 else constants.MIN_WINDOW_DIM,
        });
        return;
    }

    // ── Internal node: split this region into two and recurse ─────────────────
    //
    // n_left  = ⌊n/2⌋  →  left  / top    sub-region
    // n_right = ⌈n/2⌉  →  right / bottom sub-region
    const n_left: usize = n / 2;
    const gap = m.gap;

    if (w >= h) {
        // ── Vertical split (wide / square region) ────────────────────────────
        //
        //   x           x + left_w + gap
        //   │                │
        //   ▼                ▼
        //   ┌──────────┬─────────────┐  ─ y
        //   │          │             │
        //   │  n_left  │  n - n_left │
        //   │ windows  │   windows   │
        //   │          │             │
        //   └──────────┴─────────────┘
        //     left_w   │   right_w
        //              ↑ gap seam
        //
        // left_w  = (w - gap) / 2          (rounded down → left pane slightly
        //                                   smaller on odd pixel counts)
        // right_w = w - left_w - gap        (takes the remainder)
        const left_w: u16  = if (w > gap) (w - gap) / 2 else constants.MIN_WINDOW_DIM;
        const right_w: u16 = if (w > left_w +| gap) w - left_w - gap
                             else constants.MIN_WINDOW_DIM;
        const right_x: i32 = x + @as(i32, @intCast(left_w +| gap));

        tileRegion(ctx, windows[0..n_left], m, x,       y, left_w,  h);
        tileRegion(ctx, windows[n_left..],  m, right_x, y, right_w, h);
    } else {
        // ── Horizontal split (tall region) ───────────────────────────────────
        //
        //   y ─► ┌─────────────────────┐
        //        │    n_left windows   │  top_h
        //        ├─────────────────────┤  ← gap seam
        //        │  n - n_left windows │  bottom_h
        //        └─────────────────────┘
        //
        // top_h    = (h - gap) / 2
        // bottom_h = h - top_h - gap
        const top_h: u16    = if (h > gap) (h - gap) / 2 else constants.MIN_WINDOW_DIM;
        const bottom_h: u16 = if (h > top_h +| gap) h - top_h - gap
                              else constants.MIN_WINDOW_DIM;
        const bottom_y: i32 = y + @as(i32, @intCast(top_h +| gap));

        tileRegion(ctx, windows[0..n_left], m, x, y,        w, top_h);
        tileRegion(ctx, windows[n_left..],  m, x, bottom_y, w, bottom_h);
    }
}
