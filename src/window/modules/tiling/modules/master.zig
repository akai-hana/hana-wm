//! Master-stack tiling layout.
//!
//! Divides the screen into a master pane (left or right) holding the first
//! `master_count` windows, and a stack pane holding the rest. When the stack
//! overflows its visible height, windows spill into a column-major overflow
//! grid rather than being clipped or hidden.

const constants = @import("constants");
const utils     = @import("utils");
const layouts   = @import("layouts");
const tiling    = @import("tiling");
const State     = tiling.State;

/// Tile `windows` into the master-stack layout using the given screen area.
pub fn tileWithOffset(
    ctx:      *const layouts.LayoutCtx,
    state:    *State,
    windows:  []const u32,
    screen_w: u16,
    screen_h: u16,
    y_offset: u16,
) void {
    const n = windows.len;
    if (n == 0) return;

    const m         = state.margins();
    const master_n: u16 = @intCast(@min(state.master_count, n));
    const stack_n:  u16 = @intCast(n - master_n);

    // When no stack exists the master pane takes the full width.
    const master_w: u16 = if (stack_n > 0)
        @intFromFloat(@as(f32, @floatFromInt(screen_w)) * state.master_width)
    else
        screen_w;

    const is_master_on_right = state.master_side == .right;
    const master_x: u16      = if (is_master_on_right) screen_w -| master_w else 0;

    // Inner width accounts for the gap between master and stack panes.
    const master_inner_w = if (stack_n > 0)
        calcInnerWidth(master_w, m.gap, m.gap / 2 + 2 * m.border)
    else
        calcInnerWidth(master_w, m.gap, m.gap + 2 * m.border);

    tileColumn(ctx, windows[0..master_n], master_x +| m.gap, y_offset, screen_h, master_inner_w, m);

    if (stack_n == 0) return;

    const stack_x: u16 = if (is_master_on_right) 0 else master_w;
    tileStack(ctx, windows[master_n..], stack_x, y_offset, screen_w -| master_w, screen_h, m);
}

// ============================================================================
// Private helpers
// ============================================================================

/// Tile a vertical column of `windows` at a fixed x position with a fixed
/// content width. Used for both the master pane and the simple stack path.
///
/// When ctx.defer_configure is non-null and names a window in this column,
/// that window's configure_window call is emitted after all other windows in
/// the column.  This guarantees the shrinking window (old master moving into
/// the stack) fills its slot before the growing window (new master) vacates its
/// old slot, preventing a one-frame wallpaper gap.
fn tileColumn(
    ctx:      *const layouts.LayoutCtx,
    windows:  []const u32,
    x:        u16,
    y_offset: u16,
    h:        u16,
    inner_w:  u16,
    m:        utils.Margins,
) void {
    const count: u16 = @intCast(windows.len);
    const avail = calcAvailableHeight(h, count, m);
    var deferred_win:  ?u32        = null;
    var deferred_rect: utils.Rect  = undefined;
    for (windows, 0..) |win, i| {
        const row: u16 = @intCast(i);
        const rect = utils.Rect{
            .x      = @intCast(x),
            .y      = @intCast(windowY(row, count, avail, y_offset, m)),
            .width  = inner_w,
            .height = windowHeight(row, count, avail),
        };
        if (ctx.defer_configure == win) {
            deferred_win  = win;
            deferred_rect = rect;
        } else {
            layouts.configureWithHints(ctx, win, rect);
        }
    }
    if (deferred_win) |w| layouts.configureWithHints(ctx, w, deferred_rect);
}

/// Tile the stack pane, spilling into a column-major overflow grid when the
/// number of stack windows exceeds what fits in a single column.
fn tileStack(
    ctx:      *const layouts.LayoutCtx,
    windows:  []const u32,
    x:        u16,
    y_offset: u16,
    w:        u16,
    h:        u16,
    m:        utils.Margins,
) void {
    const stack_n: u16 = @intCast(windows.len);

    const space_per_window: u32 = constants.MIN_WINDOW_DIM + 2 * @as(u32, m.border) + @as(u32, m.gap);
    const available: u32        = @as(u32, h) -| @as(u32, m.gap);
    const max_fit: u16          = @intCast(@max(1, available / space_per_window));

    if (stack_n <= max_fit) {
        tileColumn(ctx, windows, x +| m.gap / 2, y_offset, h,
            calcInnerWidth(w, m.gap / 2, m.gap + 2 * m.border), m);
        return;
    }
    tileStackExtra(ctx, windows, x, y_offset, w, h, max_fit, m);
}

/// Column-major overflow grid: row `r` holds windows at indices r, r+max_fit,
/// r+2*max_fit, … Each row's column count is ceil((stack_n - r) / max_fit).
/// Respects ctx.defer_configure: the named window is emitted last.
fn tileStackExtra(
    ctx:      *const layouts.LayoutCtx,
    windows:  []const u32,
    x:        u16,
    y_offset: u16,
    w:        u16,
    h:        u16,
    max_fit:  u16,
    m:        utils.Margins,
) void {
    const stack_n: u16 = @intCast(windows.len);
    const row_avail    = calcAvailableHeight(h, max_fit, m);

    var deferred_win:  ?u32       = null;
    var deferred_rect: utils.Rect = undefined;

    var row: u16 = 0;
    while (row < max_fit) : (row += 1) {
        const cols_in_row: u16 = (stack_n - row + max_fit - 1) / max_fit;

        const gaps_in_row = m.gap / 2 +| m.gap *| cols_in_row;
        const row_total_w = if (w > gaps_in_row) w - gaps_in_row else cols_in_row * constants.MIN_WINDOW_DIM;
        const col_w       = row_total_w / cols_in_row;
        const col_inner_w = calcInnerWidth(col_w, 0, 2 * m.border);

        const y_pos = windowY(row, max_fit, row_avail, y_offset, m);
        const row_h = windowHeight(row, max_fit, row_avail);

        var win_idx: u16 = row;
        while (win_idx < stack_n) : (win_idx += max_fit) {
            const col: u16 = (win_idx - row) / max_fit;
            const rect = utils.Rect{
                .x      = @intCast(x +| m.gap / 2 +| col *| (col_w +| m.gap)),
                .y      = @intCast(y_pos),
                .width  = col_inner_w,
                .height = row_h,
            };
            if (ctx.defer_configure == windows[win_idx]) {
                deferred_win  = windows[win_idx];
                deferred_rect = rect;
            } else {
                layouts.configureWithHints(ctx, windows[win_idx], rect);
            }
        }
    }
    if (deferred_win) |win| layouts.configureWithHints(ctx, win, deferred_rect);
}

/// Total pixel height available for window content after gaps and borders.
/// Falls back to count * MIN_WINDOW_DIM when margins exceed total_h.
inline fn calcAvailableHeight(total_h: u16, count: u16, m: utils.Margins) u16 {
    const overhead = m.gap *| (count + 1) +| m.border *| 2 *| count;
    return if (total_h > overhead) total_h - overhead else count * constants.MIN_WINDOW_DIM;
}

/// Height of window `i` out of `count`, distributing `available` pixels via
/// cumulative integer division. No two siblings differ by more than 1 px.
inline fn windowHeight(i: u16, count: u16, available: u16) u16 {
    const h = ((i + 1) * available / count) -| (i * available / count);
    return @max(constants.MIN_WINDOW_DIM, h);
}

/// Y position of window `i`, derived from the same cumulative formula so that
/// preceding windows' heights (which may vary by 1 px) are accounted for.
inline fn windowY(i: u16, count: u16, available: u16, y_offset: u16, m: utils.Margins) u16 {
    return y_offset +| m.gap +| (i * available / count) +| i *| (m.gap +| 2 *| m.border);
}

/// Width available for window content after subtracting left and right margins.
inline fn calcInnerWidth(full_w: u16, left_margin: u16, right_margin: u16) u16 {
    return if (full_w > left_margin + right_margin)
        full_w - left_margin - right_margin
    else
        constants.MIN_WINDOW_DIM;
}