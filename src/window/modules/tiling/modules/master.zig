//! Master-stack tiling layout
//! Divides the screen into a master pane and a stack pane, with overflow handling for extra windows.

const utils = @import("utils");
const constants = @import("constants");

const tiling = @import("tiling");
const layouts = @import("layouts");

/// The two adjustable stack-column weights derived from LayoutConfig's
/// signed `stack_balance` scalar (see its doc in tiling.zig). Bundled so
/// tileColumn/tileStack thread one extra parameter through.
///
/// Every slot starts at 1.0 (the historical even split); `top`/`bottom` add
/// to the first/last slot's weight. Because shrink falls out of weights
/// becoming smaller fractions of a larger total, this generalizes to any
/// slave count: with 2 slaves it's grow-A/shrink-B 1:1; with 3+, boosting
/// one slot shrinks the rest evenly. See distributeStackHeightsWeighted.
pub const StackBoost = struct {
    top: f32 = 0,
    bottom: f32 = 0,

    inline fn isZero(self: StackBoost) bool {
        return self.top == 0 and self.bottom == 0;
    }

    /// `balance` is LayoutConfig.stack_balance: positive boosts the top slot,
    /// negative boosts the bottom slot, and the two are mutually exclusive by
    /// construction — exactly one of `top`/`bottom` is ever nonzero.
    pub inline fn fromBalance(balance: f32) StackBoost {
        return .{ .top = @max(0, balance), .bottom = @max(0, -balance) };
    }
};

/// Tile `windows` into the master-stack layout using the given screen area.
pub fn tileWithOffset(
    ctx: *const layouts.LayoutCtx,
    state: *tiling.State,
    windows: []const u32,
    screen_w: u16,
    screen_h: u16,
    y_offset: u16,
) void {
    // Windows list is guaranteed non-empty by invokeLayout (see tiling.zig).
    const n = windows.len;
    const min_dim = state.config.min_window_dim;

    const m = state.margins();
    const master_n: u16 = @intCast(@min(state.config.master_count, n));
    const stack_n: u16 = @intCast(n - master_n);

    // When no stack exists the master pane takes the full width.
    const master_w: u16 = if (stack_n > 0)
        @intFromFloat(@round(@as(f32, @floatFromInt(screen_w)) * state.config.master_width))
    else
        screen_w;

    const is_master_on_right = state.config.master_side == .right;
    const master_x: u16 = if (is_master_on_right) screen_w -| master_w else 0;

    // Master column: full gap on its screen edge, half-gap toward the stack
    // (the stack's own half-gap completes the shared gap); with no stack both
    // edges carry a full gap. Borders are then subtracted from the width.
    const edge_inset: u16 = if (stack_n > 0) m.gap + m.gap / 2 else m.gap * 2;
    const master_inner_w = layouts.shrinkClamped(master_w, edge_inset + utils.doubledBorder(m), min_dim);

    // The master column never uses the stack boost — it isn't a "slave"
    // column, so mod+n/mod+o have no effect on it.
    tileColumn(ctx, windows[0..master_n], master_x +| m.gap, y_offset, screen_h, master_inner_w, m, .{}, min_dim);

    if (stack_n == 0) return;

    const stack_x: u16 = if (is_master_on_right) 0 else master_w;
    tileStack(ctx, windows[master_n..], stack_x, y_offset, screen_w -| master_w, screen_h, m, StackBoost.fromBalance(state.config.stack_balance), min_dim);
}

/// Tile a vertical column of `windows` at a fixed x with a fixed content
/// width. Used for both the master pane and the simple stack path.
///
/// Windows split the column's height evenly, EXCEPT a window whose cached
/// max_height caps it below its fair share — it's pinned to that max and its
/// pixels fold back into the split (see distributeStackHeightsWeighted), so a
/// short fixed-height window (PiP pane, PMaxSize dialog) never leaves a dead
/// gap and the column always fills `h`.
///
/// `ctx.defer_win` is configured last (swap_master's one-frame-gap fix).
/// `boost` is zero for the master column, which reduces the split to plain even.
fn tileColumn(
    ctx: *const layouts.LayoutCtx,
    windows: []const u32,
    x: u16,
    y_offset: u16,
    h: u16,
    inner_w: u16,
    m: utils.Margins,
    boost: StackBoost,
    min_dim: u16,
) void {
    const count: u16 = @intCast(windows.len);
    const avail = calcAvailableHeight(h, count, m, min_dim);

    var heights_buf: [constants.Limits.MAX_TILED_WINDOWS]u16 = undefined;
    const heights = heights_buf[0..windows.len];
    distributeStackHeightsWeighted(ctx, windows, avail, boost, min_dim, heights);

    // If every window is capped, sum(heights) < avail — centre the stack in
    // the column instead of stranding the slack at the bottom.
    var used: u32 = 0;
    for (heights) |win_h| used += win_h;
    const dead_space: u32 = @as(u32, avail) -| used;
    const pad_top: u16 = @intCast(dead_space / 2);

    var y: u16 = y_offset +| m.gap +| pad_top;
    for (windows, 0..) |win, i| {
        const rect = utils.Rect{
            .x = @intCast(x),
            .y = @intCast(y),
            .width = inner_w,
            .height = heights[i],
        };
        layouts.emitOrDefer(ctx, win, rect);
        y = y +| heights[i] +| m.gap +| 2 *| m.border;
    }
}

/// Split `avail` content-height pixels across `windows`, writing one height
/// per window into `out` (same order/length as `windows`).
///
/// A window whose cached max_height sits at or below its fair share is
/// "capped": pinned to that max_height, removed from the pool, and its pixels
/// flow back to everyone else. Pinning raises remaining fair shares, which can
/// cap a previously-uncapped window — so this repeats until nothing new gets
/// pinned (water-filling; bounded by `windows.len` passes).
///
/// Fair shares are weighted by `boost`. Zero boost — the common case — gives
/// every slot weight 1.0 and takes the same cumulative-division path as
/// windowHeight/windowY, so output stays bit-identical to the historical even
/// split. Non-zero boost uses the telescoping rounded cumulative sum
/// (`cum`/`prev_px`) so fractional weights land on the right pixel.
fn distributeStackHeightsWeighted(ctx: *const layouts.LayoutCtx, windows: []const u32, avail: u16, boost: StackBoost, min_dim: u16, out: []u16) void {
    const n: u16 = @intCast(windows.len);

    var capped_buf: [constants.Limits.MAX_TILED_WINDOWS]bool = undefined;
    const capped = capped_buf[0..windows.len];
    @memset(capped, false);

    var remaining_avail = avail;
    var remaining_weight: f32 = totalWeight(n, boost);
    var remaining_count: u16 = n;

    var pinned_any = true;
    while (pinned_any and remaining_count > 0) {
        pinned_any = false;
        for (windows, 0..) |win, i| {
            if (capped[i]) continue;
            const w_i = windowWeight(@intCast(i), n, boost);
            const fair_share: u16 = if (remaining_weight > 0)
                @intFromFloat(@as(f32, @floatFromInt(remaining_avail)) * w_i / remaining_weight)
            else
                0;
            const max_h = windowMaxHeight(ctx, win);
            if (max_h > 0 and max_h <= fair_share) {
                out[i] = @max(min_dim, max_h);
                capped[i] = true;
                remaining_avail = remaining_avail -| out[i];
                remaining_weight -= w_i;
                remaining_count -= 1;
                pinned_any = true;
            }
        }
    }

    if (boost.isZero()) {
        var seen: u16 = 0;
        for (windows, 0..) |_, i| {
            if (capped[i]) continue;
            out[i] = windowHeight(seen, remaining_count, remaining_avail, min_dim);
            seen += 1;
        }
        return;
    }

    var cum: f32 = 0;
    var prev_px: f32 = 0;
    for (windows, 0..) |_, i| {
        if (capped[i]) continue;
        cum += windowWeight(@intCast(i), n, boost);
        const px: f32 = if (remaining_weight > 0)
            @round(@as(f32, @floatFromInt(remaining_avail)) * cum / remaining_weight)
        else
            0;
        const h: u16 = @intFromFloat(@max(@as(f32, 0), px - prev_px));
        out[i] = @max(min_dim, h);
        prev_px = px;
    }
}

/// Sum of every stack slot's weight (see windowWeight) before any capping.
inline fn totalWeight(count: u16, boost: StackBoost) f32 {
    return @as(f32, @floatFromInt(count)) + boost.top + boost.bottom;
}

/// Weight of stack slot `i` out of `count`: 1.0 baseline plus `boost.top`
/// (first slot) and `boost.bottom` (last slot). When `count == 1` both apply
/// to the lone window — harmless, since one window takes the whole column.
inline fn windowWeight(i: u16, count: u16, boost: StackBoost) f32 {
    var w: f32 = 1.0;
    if (i == 0) w += boost.top;
    if (count > 0 and i == count - 1) w += boost.bottom;
    return w;
}

/// Cached WM_NORMAL_HINTS max_height for `win`, or 0 when it declared none —
/// 0 doubles as "unconstrained", so callers needn't special-case a missing
/// cache entry.
inline fn windowMaxHeight(ctx: *const layouts.LayoutCtx, win: u32) u16 {
    const wd = ctx.cache.get(win) orelse return 0;
    return wd.hints.max_height;
}

/// Tile the stack pane, spilling into a column-major overflow grid when the
/// stack exceeds what fits in a single column.
///
/// `boost` only affects the single-column path — see tileStackExtra for why.
fn tileStack(
    ctx: *const layouts.LayoutCtx,
    windows: []const u32,
    x: u16,
    y_offset: u16,
    w: u16,
    h: u16,
    m: utils.Margins,
    boost: StackBoost,
    min_dim: u16,
) void {
    const stack_n: u16 = @intCast(windows.len);

    const space_per_window: u32 = min_dim + 2 * @as(u32, m.border) + @as(u32, m.gap);
    const available: u32 = @as(u32, h) -| @as(u32, m.gap);
    const max_fit: u16 = @intCast(@max(1, available / space_per_window));

    if (stack_n <= max_fit) {
        tileColumn(ctx, windows, x +| m.gap / 2, y_offset, h, layouts.shrinkClamped(w, m.gap / 2 + (m.gap + 2 * m.border), min_dim), m, boost, min_dim);
        return;
    }
    tileStackExtra(ctx, windows, x, y_offset, w, h, max_fit, m, min_dim);
}

/// Column-major overflow grid: row `r` holds windows at indices r, r+max_fit,
/// r+2*max_fit, … Each row's column count is ceil((stack_n - r) / max_fit).
/// Respects ctx.defer_win.
///
/// NOTE: overflow rows get neither tileColumn's max_height redistribution (a
/// row's windows share one height, so one capped window would cap the whole
/// row) nor the stack boost ("topmost"/"bottommost" lose meaning once the
/// stack wraps into multiple columns).
fn tileStackExtra(
    ctx: *const layouts.LayoutCtx,
    windows: []const u32,
    x: u16,
    y_offset: u16,
    w: u16,
    h: u16,
    max_fit: u16,
    m: utils.Margins,
    min_dim: u16,
) void {
    const stack_n: u16 = @intCast(windows.len);
    const row_avail = calcAvailableHeight(h, max_fit, m, min_dim);

    var row: u16 = 0;
    while (row < max_fit) : (row += 1) {
        const cols_in_row: u16 = (stack_n - row + max_fit - 1) / max_fit;

        const gaps_in_row = m.gap / 2 +| m.gap *| cols_in_row;
        const row_total_w = if (w > gaps_in_row) w - gaps_in_row else cols_in_row * min_dim;
        const col_w = row_total_w / cols_in_row;
        const col_inner_w = layouts.shrinkClamped(col_w, 2 * m.border, min_dim);

        const y_pos = windowY(row, max_fit, row_avail, y_offset, m);
        const row_h = windowHeight(row, max_fit, row_avail, min_dim);

        var win_idx: u16 = row;
        while (win_idx < stack_n) : (win_idx += max_fit) {
            const col: u16 = (win_idx - row) / max_fit;
            const rect = utils.Rect{
                .x = @intCast(x +| m.gap / 2 +| col *| (col_w +| m.gap)),
                .y = @intCast(y_pos),
                .width = col_inner_w,
                .height = row_h,
            };
            layouts.emitOrDefer(ctx, windows[win_idx], rect);
        }
    }
}

/// Total pixel height available for window content after gaps and borders.
/// Falls back to count * min_dim when margins exceed total_h.
inline fn calcAvailableHeight(total_h: u16, count: u16, m: utils.Margins, min_dim: u16) u16 {
    const overhead = m.gap *| (count + 1) +| m.border *| 2 *| count;
    return if (total_h > overhead) total_h - overhead else count * min_dim;
}

/// Height of window `i` out of `count`, distributing `available` pixels via
/// cumulative integer division. No two siblings differ by more than 1 px.
inline fn windowHeight(i: u16, count: u16, available: u16, min_dim: u16) u16 {
    const hi: u32 = (@as(u32, i) + 1) * @as(u32, available) / @as(u32, count);
    const lo: u32 = @as(u32, i) * @as(u32, available) / @as(u32, count);
    return @max(min_dim, @as(u16, @intCast(hi - lo)));
}

/// Y position of window `i`, derived from the same cumulative formula so that
/// preceding windows' heights (which may vary by 1 px) are accounted for.
inline fn windowY(i: u16, count: u16, available: u16, y_offset: u16, m: utils.Margins) u16 {
    const cum: u32 = @as(u32, i) * @as(u32, available) / @as(u32, count);
    return y_offset +| m.gap +| @as(u16, @intCast(cum)) +| i *| (m.gap +| 2 *| m.border);
}