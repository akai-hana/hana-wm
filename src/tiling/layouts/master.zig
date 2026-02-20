//! Master-stack layout with overflow handling
/// Direct XCB calls — no batch overhead

const std = @import("std");
const defs = @import("defs");
const utils = @import("utils");
const layouts = @import("layouts");

const tiling = @import("tiling");
const State = tiling.State;

inline fn calcAvailable(total_h: u16, count: u16, margins: utils.Margins) u16 {
    const overhead = margins.gap * (count + 1) + margins.border * 2 * count;
    return if (total_h > overhead) total_h - overhead else count * defs.MIN_WINDOW_DIM;
}

/// Height of window `i` out of `count`, distributing `available` pixels via
/// cumulative integer division. No window differs from any sibling by more than
/// 1px, and the column fills exactly — in a single pass, no remainder field needed.
inline fn windowHeight(i: u16, count: u16, available: u16) u16 {
    const h = ((i + 1) * available / count) -| (i * available / count);
    return @max(defs.MIN_WINDOW_DIM, h);
}

/// Y position of window `i`, derived from the same cumulative formula so that
/// preceding windows' heights (which may vary by 1px) are automatically accounted for.
inline fn windowY(i: u16, count: u16, available: u16, y_offset: u16, margins: utils.Margins) u16 {
    const y_start = i * available / count;
    return y_offset + margins.gap + y_start + i * (margins.gap + 2 * margins.border);
}

inline fn calcMarginedWidth(full_w: u16, left_margin: u16, right_margin: u16) u16 {
    const total_margin = left_margin + right_margin;
    return if (full_w > total_margin) full_w - total_margin else defs.MIN_WINDOW_DIM;
}

pub fn tileWithOffset(conn: *defs.xcb.xcb_connection_t, state: *State, windows: []const u32, screen_w: u16, screen_h: u16, y_offset: u16) void {
    const n = windows.len;
    if (n == 0) return;

    const m = state.margins();
    const m_count: u16 = @intCast(@min(state.master_count, n));
    const s_count: u16 = @intCast(if (n > m_count) n - m_count else 0);

    const master_w: u16 = if (s_count > 0)
        @intFromFloat(@as(f32, @floatFromInt(screen_w)) * state.master_width)
    else
        screen_w;

    const master_on_right = state.master_side == .right;
    const master_x: u16  = if (master_on_right) screen_w - master_w else 0;
    const stack_x: u16   = if (master_on_right) 0 else master_w;
    const stack_w         = screen_w - master_w;

    const master_inner_w = if (s_count > 0)
        calcMarginedWidth(master_w, m.gap, m.gap / 2 + 2 * m.border)
    else
        calcMarginedWidth(master_w, m.gap, m.gap + 2 * m.border);

    const m_avail = calcAvailable(screen_h, m_count, m);
    for (windows[0..m_count], 0..) |win, i| {
        const row: u16 = @intCast(i);
        const rect = utils.Rect{
            .x      = @intCast(master_x + m.gap),
            .y      = @intCast(windowY(row, m_count, m_avail, y_offset, m)),
            .width  = master_inner_w,
            .height = windowHeight(row, m_count, m_avail),
        };
        layouts.configureSafe(conn, win, rect);
    }

    if (s_count == 0) return;

    tileStack(conn, windows[m_count..], stack_x, y_offset, stack_w, screen_h, m);
}

fn tileStack(conn: *defs.xcb.xcb_connection_t, windows: []const u32, x: u16, y_offset: u16, w: u16, h: u16, m: utils.Margins) void {
    const s_count: u16 = @intCast(windows.len);

    const space_per_window: u32 = defs.MIN_WINDOW_DIM + 2 * @as(u32, m.border) + @as(u32, m.gap);
    const available: u32        = @as(u32, h) - @as(u32, m.gap);
    const max_fit: u16          = @intCast(@max(1, available / space_per_window));

    const stack_inner_w = calcMarginedWidth(w, m.gap / 2, m.gap + 2 * m.border);

    if (s_count <= max_fit) {
        tileStackSimple(conn, windows, x, y_offset, h, stack_inner_w, m);
    } else {
        tileStackOverflow(conn, windows, x, y_offset, w, h, max_fit, m);
    }
}

fn tileStackSimple(conn: *defs.xcb.xcb_connection_t, windows: []const u32, x: u16, y_offset: u16, h: u16, inner_w: u16, m: utils.Margins) void {
    const s_count: u16 = @intCast(windows.len);
    const s_avail  = calcAvailable(h, s_count, m);

    for (windows, 0..) |win, i| {
        const row: u16 = @intCast(i);
        const rect = utils.Rect{
            .x      = @intCast(x + m.gap / 2),
            .y      = @intCast(windowY(row, s_count, s_avail, y_offset, m)),
            .width  = inner_w,
            .height = windowHeight(row, s_count, s_avail),
        };
        layouts.configureSafe(conn, win, rect);
    }
}

fn tileStackOverflow(conn: *defs.xcb.xcb_connection_t, windows: []const u32, x: u16, y_offset: u16, w: u16, h: u16, max_fit: u16, m: utils.Margins) void {
    const s_count: u16 = @intCast(windows.len);
    const s_avail  = calcAvailable(h, max_fit, m);

    var row: u16 = 0;
    while (row < max_fit) : (row += 1) {
        var cols_in_row: u16 = 0;
        var win_idx = row;
        while (win_idx < s_count) : (win_idx += max_fit) cols_in_row += 1;
        if (cols_in_row == 0) break;

        const gaps_in_row = m.gap / 2 + m.gap + m.gap * (cols_in_row - 1);
        const row_total_w = if (w > gaps_in_row) w - gaps_in_row else cols_in_row * defs.MIN_WINDOW_DIM;
        const row_col_w   = row_total_w / cols_in_row;
        const row_inner_w = if (row_col_w > 2 * m.border)
            @max(defs.MIN_WINDOW_DIM, row_col_w - 2 * m.border)
        else
            defs.MIN_WINDOW_DIM;

        const y_pos = windowY(row, max_fit, s_avail, y_offset, m);
        const row_h  = windowHeight(row, max_fit, s_avail);

        var col: u16 = 0;
        win_idx = row;
        while (win_idx < s_count) : (win_idx += max_fit) {
            const rect = utils.Rect{
                .x      = @intCast(x + m.gap / 2 + col * (row_col_w + m.gap)),
                .y      = @intCast(y_pos),
                .width  = row_inner_w,
                .height = row_h,
            };
            layouts.configureSafe(conn, windows[win_idx], rect);
            col += 1;
        }
    }
}
