//! Master-stack layout with overflow handling.

const constants = @import("constants");
const utils     = @import("utils");
const layouts   = @import("layouts");
const tiling    = @import("tiling");
const State     = tiling.State;

// Total pixel height available for window content after gaps and borders.
// Falls back to count * MIN_WINDOW_DIM if margins exceed total_h.
inline fn calcAvailable(total_h: u16, count: u16, margins: utils.Margins) u16 {
    const overhead = margins.gap * (count + 1) + margins.border * 2 * count;
    return if (total_h > overhead) total_h - overhead else count * constants.MIN_WINDOW_DIM;
}

// Height of window i out of count, distributing available pixels via cumulative
// integer division. No window differs from any sibling by more than 1px.
inline fn windowHeight(i: u16, count: u16, available: u16) u16 {
    const h = ((i + 1) * available / count) -| (i * available / count);
    return @max(constants.MIN_WINDOW_DIM, h);
}

// Y position of window i, derived from the same cumulative formula so that
// preceding windows' heights (which may vary by 1px) are accounted for.
inline fn windowY(i: u16, count: u16, available: u16, y_offset: u16, margins: utils.Margins) u16 {
    return y_offset +| margins.gap +| (i * available / count) +| i *| (margins.gap +| 2 * margins.border);
}

inline fn calcMarginedWidth(full_w: u16, left_margin: u16, right_margin: u16) u16 {
    return if (full_w > left_margin + right_margin) full_w - left_margin - right_margin else constants.MIN_WINDOW_DIM;
}

// Tile a vertical column of windows at a fixed x position with a fixed inner width.
// Used for both the master pane and the simple stack path.
fn tileColumn(ctx: *const layouts.LayoutCtx, windows: []const u32, x: u16, y_offset: u16, h: u16, inner_w: u16, m: utils.Margins) void {
    const count: u16 = @intCast(windows.len);
    const avail = calcAvailable(h, count, m);
    for (windows, 0..) |win, i| {
        const row: u16 = @intCast(i);
        layouts.configureSafe(ctx, win, utils.Rect{
            .x      = @intCast(x),
            .y      = @intCast(windowY(row, count, avail, y_offset, m)),
            .width  = inner_w,
            .height = windowHeight(row, count, avail),
        });
    }
}

pub fn tileWithOffset(ctx: *const layouts.LayoutCtx, state: *State, windows: []const u32, screen_w: u16, screen_h: u16, y_offset: u16) void {
    const n = windows.len;
    if (n == 0) return;

    const m = state.margins();
    const m_count: u16 = @intCast(@min(state.master_count, n));
    const s_count: u16 = @intCast(n - m_count);

    const master_w: u16 = if (s_count > 0)
        @intFromFloat(@as(f32, @floatFromInt(screen_w)) * state.master_width)
    else
        screen_w;

    const master_on_right = state.master_side == .right;
    const master_x: u16   = if (master_on_right) screen_w -| master_w else 0;

    const master_inner_w = if (s_count > 0)
        calcMarginedWidth(master_w, m.gap, m.gap / 2 + 2 * m.border)
    else
        calcMarginedWidth(master_w, m.gap, m.gap + 2 * m.border);

    tileColumn(ctx, windows[0..m_count], master_x +| m.gap, y_offset, screen_h, master_inner_w, m);

    if (s_count == 0) return;

    const stack_x: u16 = if (master_on_right) 0 else master_w;
    const stack_w      = screen_w -| master_w;
    tileStack(ctx, windows[m_count..], stack_x, y_offset, stack_w, screen_h, m);
}

fn tileStack(ctx: *const layouts.LayoutCtx, windows: []const u32, x: u16, y_offset: u16, w: u16, h: u16, m: utils.Margins) void {
    const s_count: u16 = @intCast(windows.len);

    const space_per_window: u32 = constants.MIN_WINDOW_DIM + 2 * @as(u32, m.border) + @as(u32, m.gap);
    const available: u32        = @as(u32, h) -| @as(u32, m.gap);
    const max_fit: u16          = @intCast(@max(1, available / space_per_window));

    if (s_count <= max_fit) {
        tileColumn(ctx, windows, x +| m.gap / 2, y_offset, h, calcMarginedWidth(w, m.gap / 2, m.gap + 2 * m.border), m);
    } else {
        tileStackOverflow(ctx, windows, x, y_offset, w, h, max_fit, m);
    }
}

// Column-major overflow grid: row r contains windows at indices r, r+max_fit,
// r+2*max_fit, … Each row's column count is ceil((s_count - r) / max_fit).
fn tileStackOverflow(ctx: *const layouts.LayoutCtx, windows: []const u32, x: u16, y_offset: u16, w: u16, h: u16, max_fit: u16, m: utils.Margins) void {
    const s_count: u16 = @intCast(windows.len);
    const s_avail  = calcAvailable(h, max_fit, m);

    var row: u16 = 0;
    while (row < max_fit) : (row += 1) {
        const remaining   = s_count - row;
        const cols_in_row: u16 = (remaining + max_fit - 1) / max_fit;

        const gaps_in_row = m.gap / 2 + m.gap * cols_in_row;
        const row_total_w = if (w > gaps_in_row) w - gaps_in_row else cols_in_row * constants.MIN_WINDOW_DIM;
        const row_col_w   = row_total_w / cols_in_row;
        const row_inner_w = calcMarginedWidth(row_col_w, 0, 2 * m.border);

        const y_pos = windowY(row, max_fit, s_avail, y_offset, m);
        const row_h  = windowHeight(row, max_fit, s_avail);

        var win_idx: u16 = row;
        while (win_idx < s_count) : (win_idx += max_fit) {
            const col: u16 = (win_idx - row) / max_fit;
            layouts.configureSafe(ctx, windows[win_idx], utils.Rect{
                .x      = @intCast(x +| m.gap / 2 +| col *| (row_col_w +| m.gap)),
                .y      = @intCast(y_pos),
                .width  = row_inner_w,
                .height = row_h,
            });
        }
    }
}
