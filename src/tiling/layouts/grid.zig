//! Grid layout - Arrange windows in optimal grid
//! Direct XCB calls — no batch overhead

const defs    = @import("defs");
const utils   = @import("utils");
const layouts = @import("layouts");

const tiling = @import("tiling");
const State  = tiling.State;
const xcb    = defs.xcb;

inline fn calcGridDims(n: usize) struct { cols: u16, rows: u16 } {
    if (n == 0) return .{ .cols = 1, .rows = 1 };
    const cols = @as(u16, @intFromFloat(@ceil(@sqrt(@as(f32, @floatFromInt(n))))));
    const rows = @as(u16, @intCast((n + cols - 1) / cols));
    return .{ .cols = cols, .rows = rows };
}

pub fn tileWithOffset(conn: *xcb.xcb_connection_t, state: *State, windows: []const u32, screen_w: u16, screen_h: u16, y_offset: u16) void {
    const n = windows.len;
    if (n == 0) return;

    const m    = state.margins();
    const dims = calcGridDims(n);

    // Calculate cell dimensions accounting for gaps
    const total_gap_w = (dims.cols + 1) * m.gap;
    const total_gap_h = (dims.rows + 1) * m.gap;

    const cell_w = (screen_w -| total_gap_w) / dims.cols;
    const cell_h = (screen_h -| total_gap_h) / dims.rows;

    // Base window dimensions accounting for borders
    const border_margin = 2 * m.border;
    const win_w = if (cell_w > border_margin) cell_w - border_margin else defs.MIN_WINDOW_DIM;
    const win_h = if (cell_h > border_margin) cell_h - border_margin else defs.MIN_WINDOW_DIM;

    // Pre-calculate spacing for performance
    const cell_spacing_w = cell_w + m.gap;
    const cell_spacing_h = cell_h + m.gap;

    // Relaxed mode: last window in an incomplete row expands to fill the row.
    // Rigid mode: every window keeps the same strict cell width.
    const windows_in_last_row: u16 = @intCast(n % dims.cols);
    const last_row_incomplete = windows_in_last_row != 0;

    for (windows, 0..) |win, idx| {
        const col: u16 = @intCast(idx % dims.cols);
        const row: u16 = @intCast(idx / dims.cols);

        // Compute the effective window width for this cell.
        const effective_win_w: u16 = switch (state.layout_variations.grid) {
            .rigid => win_w,
            .relaxed => blk: {
                const is_last = idx == n - 1;
                if (is_last and last_row_incomplete) {
                    // Expand from this cell's left edge to the right margin.
                    // x_start = m.gap + col * cell_spacing_w
                    // right edge = screen_w - m.gap
                    // available width = screen_w - m.gap - x_start - border_margin
                    const x_start    = m.gap + col * cell_spacing_w;
                    const available  = screen_w -| x_start -| m.gap -| border_margin;
                    break :blk if (available > 0) @max(available, defs.MIN_WINDOW_DIM) else defs.MIN_WINDOW_DIM;
                }
                break :blk win_w;
            },
        };

        const rect = utils.Rect{
            .x      = @intCast(m.gap + col * cell_spacing_w),
            .y      = @intCast(y_offset + m.gap + row * cell_spacing_h),
            .width  = effective_win_w,
            .height = win_h,
        };
        layouts.configureSafe(conn, win, rect);
    }
}
