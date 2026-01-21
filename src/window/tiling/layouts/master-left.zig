//! Master-left layout: master area on left, stack on right with wrapping.
//!
//! Normal:              With wrapping (when any windows clip at the bottom):
//! ┌──────────┬──────┐  ┌──────────┬───┬───┐
//! │          │  S1  │  │          │S1 │S4 │
//! │          ├──────┤  │          ├───┼───┤
//! │  Master  │  S2  │  │  Master  │S2 │S5 │
//! │          ├──────┤  │          ├───┴───┤
//! │          │  S3  │  │          │  S3   │
//! └──────────┴──────┘  └──────────┴───────┘

const std = @import("std");
const defs = @import("defs");
const log = @import("logging");
const utils = @import("utils");
const WM = defs.WM;

// Import the State type from tiling module
const tiling = @import("tiling");
const State = tiling.State;

/// Calculate maximum number of windows that fit vertically at minimum size
fn calcMaxWindowsFit(screen_h: u16, gap: u16, bw: u16) u16 {
    if (screen_h <= gap) return 1;

    const space_per_window: u32 = utils.MIN_WINDOW_DIM + 2 * @as(u32, bw) + @as(u32, gap);
    const available: u32 = @as(u32, screen_h) - @as(u32, gap);

    const max_windows = available / space_per_window;
    return @intCast(@max(1, max_windows));
}

pub fn tile(wm: *WM, state: *State, windows: []const u32, screen_w: u16, screen_h: u16) void {
    const n = windows.len;
    if (n == 0) return;

    const m = state.margins();
    const m_count: u16 = @intCast(@min(state.master_count, n));
    const s_count: u16 = @intCast(if (n > m_count) n - m_count else 0);

    if (log.isDebug()) {
        std.log.debug("[layout:master_left] Tiling {} windows (master={}, stack={})", .{n, m_count, s_count});
    }

    const master_w: u16 = if (s_count == 0)
        screen_w
    else
        @intFromFloat(@as(f32, @floatFromInt(screen_w)) * state.master_width_factor);

    // Calculate wrapping for stack
    var stack_cols: u16 = 1;
    var rows_per_col: u16 = s_count;

    if (s_count > 0) {
        const max_fit = calcMaxWindowsFit(screen_h, m.gap, m.border);

        if (log.isDebug()) {
            std.log.debug("[layout:master_left] Stack: {} windows, max {} fit vertically (screen_h={})", .{
                s_count, max_fit, screen_h
            });
        }

        if (s_count > max_fit) {
            rows_per_col = max_fit;
            stack_cols = @intCast((s_count + max_fit - 1) / max_fit);

            if (log.isDebug()) {
                std.log.debug("[layout:master_left] WRAPPING: {} columns x {} rows", .{stack_cols, rows_per_col});
            }
        }
    }

    const m_layout = utils.calcColumnLayout(screen_h, m_count, m);
    const s_layout = if (s_count > 0)
        utils.calcColumnLayout(screen_h, rows_per_col, m)
    else
        @TypeOf(m_layout){ .item_h = 0, .spacing = 0 };

    for (windows, 0..) |win, i| {
        const rect = if (i < m_count) blk: {
            // Master area
            const row: u16 = @intCast(i);
            break :blk utils.Rect{
                .x = @intCast(m.gap),
                .y = @intCast(m.gap + row * m_layout.spacing),
                .width = if (master_w > m.total()) master_w - m.total() else utils.MIN_WINDOW_DIM,
                .height = m_layout.item_h,
            };
        } else blk: {
            // Stack area with wrapping
            const stack_idx = i - m_count;
            const stack_w = screen_w - master_w;

            const col: u16 = @intCast(stack_idx / rows_per_col);
            const row: u16 = @intCast(stack_idx % rows_per_col);

            const col_width = stack_w / stack_cols;

            break :blk utils.Rect{
                .x = @intCast(master_w + col * col_width),
                .y = @intCast(m.gap + row * s_layout.spacing),
                .width = if (col_width > m.gap + 2 * m.border)
                    @max(utils.MIN_WINDOW_DIM, col_width - m.gap - 2 * m.border)
                else
                    utils.MIN_WINDOW_DIM,
                .height = s_layout.item_h,
            };
        };

        utils.configureWindow(wm.conn, win, rect);

        if (log.isDebug() and i >= m_count) {
            const stack_idx = i - m_count;
            const col = stack_idx / rows_per_col;
            const row = stack_idx % rows_per_col;
            std.log.debug("[layout:master_left] Win {} -> stack[{}] col={} row={} at {}x{}+{}+{}", .{
                i, stack_idx, col, row, rect.width, rect.height, rect.x, rect.y
            });
        }
    }
}
