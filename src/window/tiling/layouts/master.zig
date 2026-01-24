//! Master-left layout

const std = @import("std");
const defs = @import("defs");
const utils = @import("utils");
const atomic = @import("atomic");
const bar = @import("bar");

const tiling = @import("tiling");
const State = tiling.State;

pub fn tile(tx: *atomic.Transaction, state: *State, windows: []const u32, screen_w: u16, screen_h: u16) void {
    const n = windows.len;
    if (n == 0) return;

    const bar_height = bar.getHeight();
    const usable_h = screen_h - bar_height;

    const m = state.margins();
    const m_count: u16 = @intCast(@min(state.master_count, n));
    const s_count: u16 = @intCast(if (n > m_count) n - m_count else 0);

    const master_w: u16 = if (s_count > 0)
        @intFromFloat(@as(f32, @floatFromInt(screen_w)) * state.master_width_factor)
    else
        screen_w;

    const master_on_right = state.master_side == .right;

    const master_x: u16 = if (master_on_right) screen_w - master_w else 0;
    const stack_x: u16 = if (master_on_right) 0 else master_w;

    const margin_total = m.total();
    const master_inner_w = if (master_w > margin_total) master_w - margin_total else utils.MIN_WINDOW_DIM;

    const m_layout = utils.calcColumnLayout(usable_h, m_count, m);
    for (windows[0..m_count], 0..) |win, i| {
        const row: u16 = @intCast(i);
        const rect = utils.Rect{
            .x = @intCast(master_x + m.gap),
            .y = @intCast(bar_height + m.gap + row * m_layout.spacing),
            .width = master_inner_w,
            .height = m_layout.item_h,
        };
        tx.configureWindow(win, rect) catch |err| {
            std.log.err("[master] Failed to configure master window {}: {}", .{ win, err });
            continue;
        };
    }

    if (s_count == 0) return;

    const stack_w = screen_w - master_w;
    const stack_windows = windows[m_count..];

    const space_per_window: u32 = utils.MIN_WINDOW_DIM + 2 * @as(u32, m.border) + @as(u32, m.gap);
    const available: u32 = @as(u32, usable_h) - @as(u32, m.gap);
    const max_fit: u16 = @intCast(@max(1, available / space_per_window));

    const stack_margin = m.gap + 2 * m.border;

    if (s_count <= max_fit) {
        const s_layout = utils.calcColumnLayout(usable_h, s_count, m);
        const stack_inner_w = if (stack_w > stack_margin)
            @max(utils.MIN_WINDOW_DIM, stack_w - stack_margin)
        else
            utils.MIN_WINDOW_DIM;

        for (stack_windows, 0..) |win, i| {
            const row: u16 = @intCast(i);
            const rect = utils.Rect{
                .x = @intCast(stack_x + m.gap),
                .y = @intCast(bar_height + m.gap + row * s_layout.spacing),
                .width = stack_inner_w,
                .height = s_layout.item_h,
            };
            tx.configureWindow(win, rect) catch |err| {
                std.log.err("[master] Failed to configure stack window {}: {}", .{ win, err });
                continue;
            };
        }
    } else {
        const s_layout = utils.calcColumnLayout(usable_h, max_fit, m);

        var row: u16 = 0;
        while (row < max_fit) : (row += 1) {
            var cols_in_row: u16 = 0;
            var win_idx = row;
            while (win_idx < s_count) : (win_idx += max_fit) {
                cols_in_row += 1;
            }

            if (cols_in_row == 0) break;

            const row_col_w = stack_w / cols_in_row;
            const y_pos = bar_height + m.gap + row * s_layout.spacing;
            const row_inner_w = if (row_col_w > stack_margin)
                @max(utils.MIN_WINDOW_DIM, row_col_w - stack_margin)
            else
                utils.MIN_WINDOW_DIM;

            var col: u16 = 0;
            win_idx = row;
            while (win_idx < s_count) : (win_idx += max_fit) {
                const win = stack_windows[win_idx];

                const rect = utils.Rect{
                    .x = @intCast(stack_x + col * row_col_w + m.gap),
                    .y = @intCast(y_pos),
                    .width = row_inner_w,
                    .height = s_layout.item_h,
                };
                tx.configureWindow(win, rect) catch |err| {
                    std.log.err("[master] Failed to configure overflow window {}: {}", .{ win, err });
                    continue;
                };

                col += 1;
            }
        }
    }
}
