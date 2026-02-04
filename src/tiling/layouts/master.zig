//! Master-stack layout with overflow handling

const std = @import("std");
const defs = @import("defs");
const utils = @import("utils");
const batch = @import("batch");
const layout_common = @import("layout_common");

const tiling = @import("tiling");
const State = tiling.State;

inline fn calcColumnLayout(total_h: u16, count: u16, margins: utils.Margins) struct { item_h: u16, spacing: u16 } {
    if (count == 0) return .{ .item_h = 0, .spacing = 0 };

    const overhead = margins.gap * (count + 1) + margins.border * 2 * count;
    const available = if (total_h > overhead) total_h - overhead else count * defs.MIN_WINDOW_DIM;
    const item_h = @max(defs.MIN_WINDOW_DIM, available / count);

    return .{ .item_h = item_h, .spacing = item_h + 2 * margins.border + margins.gap };
}

inline fn calcMarginedWidth(full_w: u16, left_margin: u16, right_margin: u16) u16 {
    const total_margin = left_margin + right_margin;
    return if (full_w > total_margin) full_w - total_margin else defs.MIN_WINDOW_DIM;
}

pub fn tile(b: *batch.Batch, state: *State, windows: []const u32, screen_w: u16, screen_h: u16) void {
    layout_common.tileWrapper(tileWithOffset, b, state, windows, screen_w, screen_h);
}

pub fn tileWithOffset(b: *batch.Batch, state: *State, windows: []const u32, screen_w: u16, screen_h: u16, y_offset: u16) void {
    const n = windows.len;
    if (n == 0) return;

    const m = state.margins();
    const m_count: u16 = @intCast(@min(state.master_count, n));
    const s_count: u16 = @intCast(if (n > m_count) n - m_count else 0);

    // Calculate master area width
    const master_w: u16 = if (s_count > 0)
        @intFromFloat(@as(f32, @floatFromInt(screen_w)) * state.master_width_factor)
    else
        screen_w;

    const master_on_right = state.master_side == .right;

    // Calculate positions
    const master_x: u16 = if (master_on_right) screen_w - master_w else 0;
    const stack_x: u16 = if (master_on_right) 0 else master_w;
    const stack_w = screen_w - master_w;

    // Calculate master inner width based on whether stack exists
    const master_inner_w = if (s_count > 0)
        calcMarginedWidth(master_w, m.gap, m.gap / 2 + 2 * m.border)
    else
        calcMarginedWidth(master_w, m.gap, m.gap + 2 * m.border);

    // Tile master windows
    const m_layout = calcColumnLayout(screen_h, m_count, m);
    for (windows[0..m_count], 0..) |win, i| {
        const row: u16 = @intCast(i);
        const rect = utils.Rect{
            .x = @intCast(master_x + m.gap),
            .y = @intCast(y_offset + m.gap + row * m_layout.spacing),
            .width = master_inner_w,
            .height = m_layout.item_h,
        };
        layout_common.configureSafe(b, win, rect, "master");
    }

    if (s_count == 0) return;

    // Tile stack windows
    tileStack(b, windows[m_count..], stack_x, y_offset, stack_w, screen_h, m);
}

fn tileStack(b: *batch.Batch, windows: []const u32, x: u16, y_offset: u16, w: u16, h: u16, m: utils.Margins) void {
    const s_count: u16 = @intCast(windows.len);

    // Calculate how many windows can fit vertically
    const space_per_window: u32 = defs.MIN_WINDOW_DIM + 2 * @as(u32, m.border) + @as(u32, m.gap);
    const available: u32 = @as(u32, h) - @as(u32, m.gap);
    const max_fit: u16 = @intCast(@max(1, available / space_per_window));

    const stack_inner_w = calcMarginedWidth(w, m.gap / 2, m.gap + 2 * m.border);

    if (s_count <= max_fit) {
        // Simple vertical stack
        tileStackSimple(b, windows, x, y_offset, h, stack_inner_w, m);
    } else {
        // Overflow: wrap into columns
        tileStackOverflow(b, windows, x, y_offset, w, h, max_fit, m);
    }
}

fn tileStackSimple(b: *batch.Batch, windows: []const u32, x: u16, y_offset: u16, h: u16, inner_w: u16, m: utils.Margins) void {
    const s_count: u16 = @intCast(windows.len);
    const s_layout = calcColumnLayout(h, s_count, m);

    for (windows, 0..) |win, i| {
        const row: u16 = @intCast(i);
        const rect = utils.Rect{
            .x = @intCast(x + m.gap / 2),
            .y = @intCast(y_offset + m.gap + row * s_layout.spacing),
            .width = inner_w,
            .height = s_layout.item_h,
        };
        layout_common.configureSafe(b, win, rect, "master");
    }
}

fn tileStackOverflow(b: *batch.Batch, windows: []const u32, x: u16, y_offset: u16, w: u16, h: u16, max_fit: u16, m: utils.Margins) void {
    const s_count: u16 = @intCast(windows.len);
    const s_layout = calcColumnLayout(h, max_fit, m);

    var row: u16 = 0;
    while (row < max_fit) : (row += 1) {
        // Count columns in this row
        var cols_in_row: u16 = 0;
        var win_idx = row;
        while (win_idx < s_count) : (win_idx += max_fit) {
            cols_in_row += 1;
        }

        if (cols_in_row == 0) break;

        // Calculate column width for this row
        const gaps_in_row = m.gap / 2 + m.gap + m.gap * (cols_in_row - 1);
        const row_total_w = if (w > gaps_in_row) w - gaps_in_row else cols_in_row * defs.MIN_WINDOW_DIM;
        const row_col_w = row_total_w / cols_in_row;
        const row_inner_w = if (row_col_w > 2 * m.border)
            @max(defs.MIN_WINDOW_DIM, row_col_w - 2 * m.border)
        else
            defs.MIN_WINDOW_DIM;

        const y_pos = y_offset + m.gap + row * s_layout.spacing;

        // Tile windows in this row
        var col: u16 = 0;
        win_idx = row;
        while (win_idx < s_count) : (win_idx += max_fit) {
            const win = windows[win_idx];
            const x_pos = x + m.gap / 2 + col * (row_col_w + m.gap);

            const rect = utils.Rect{
                .x = @intCast(x_pos),
                .y = @intCast(y_pos),
                .width = row_inner_w,
                .height = s_layout.item_h,
            };
            layout_common.configureSafe(b, win, rect, "master");

            col += 1;
        }
    }
}
