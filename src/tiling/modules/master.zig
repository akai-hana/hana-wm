//! Master-stack tiling layout.
//! Master + stack panes, spilling overflow into a column-major grid.

const utils = @import("utils");
const constants = @import("constants");
const model = @import("model");
const tiling = @import("tiling");

/// Stack-column weight boosts derived from `secondary_balance`:
/// positive boosts the top slot, negative boosts the bottom slot.
const StackBoost = struct {
    top: f32 = 0,
    bottom: f32 = 0,

    inline fn isZero(self: StackBoost) bool {
        return self.top == 0 and self.bottom == 0;
    }

    inline fn fromBalance(balance: f32) StackBoost {
        return .{ .top = @max(0, balance), .bottom = @max(0, -balance) };
    }
};

/// Master-stack layout: master pane + stack pane, gaps at screen edges and
/// half-gap between panes. Heights via cumulative integer division with
/// max_height capping (water-filling).
pub fn compute(v: *const tiling.View, out: *tiling.List) void {
    const windows = v.order;
    const n = windows.len;
    const m = v.env.margins;
    const ctx = tiling.LayoutCtx.init(v, out);

    const screen_w = v.workarea.width;
    const screen_h = v.workarea.height;
    const master_n: u16 = @intCast(@min(v.params.primary_count, n));
    const stack_n: u16 = @intCast(n - master_n);
    const stack_windows = windows[master_n..];
    const y = tiling.waY(v);

    // When no stack exists the master pane takes the full width.
    const master_w_frac: u16 = if (stack_n > 0)
        utils.scaling.roundToU16(@as(f32, @floatFromInt(screen_w)) * v.params.primary_width, 0.0)
    else
        screen_w;

    // Shrink the stack pane to the widest bounded slave's max_width
    // (dialogs/small windows no longer leave a dead gap beside them).
    const is_primary_on_right = v.env.primary_on_right;
    const stack_pane_w: u16 = screen_w -| master_w_frac;
    const natural_stack_w: u16 = minStackWidth(ctx, stack_windows);
    const stack_w: u16 = if (natural_stack_w > 0 and natural_stack_w < stack_pane_w)
        natural_stack_w
    else
        stack_pane_w;
    const master_w: u16 = screen_w -| stack_w;

    const master_x: u16 = if (is_primary_on_right) screen_w -| master_w else 0;

    // The master column gets a full gap on its screen edge and a half-gap
    // toward the stack; with no stack both edges carry a full gap. Borders
    // are then subtracted from the width.
    const master_inner_w = tiling.shrinkClamped(
        master_w,
        if (stack_n > 0) stackSeamMargin(m) else tiling.totalInset(m.gap, m),
        ctx.min_dim,
    );

    tileColumn(
        ctx,
        windows[0..master_n],
        master_x +| m.gap,
        y,
        screen_h,
        master_inner_w,
        .{},
    );

    if (stack_n == 0) return;

    const stack_origin: u16 = if (is_primary_on_right) m.gap else master_w;
    tileStack(
        ctx,
        stack_windows,
        stack_origin,
        y,
        stack_w,
        screen_h,
        StackBoost.fromBalance(v.params.secondary_balance),
    );
}

/// Tile a vertical column at fixed `x` with content width `inner_w`,
/// distributing heights via cumulative division with max_height capping.
fn tileColumn(
    ctx: tiling.LayoutCtx,
    windows: []const model.WindowId,
    x: u16,
    y_offset: u16,
    h: u16,
    inner_w: u16,
    boost: StackBoost,
) void {
    const count: u16 = @intCast(windows.len);
    const avail = calcAvailableHeight(h, count, ctx.m, ctx.min_dim);

    var heights_buf: [constants.max_tiled_windows]u16 = undefined;
    const heights = heights_buf[0..windows.len];
    const used = fillHeights(ctx, windows, avail, boost, heights);

    // If every window is capped, sum(heights) < avail; centre the stack in
    // the column instead of stranding the slack at the bottom.
    const dead_space: u32 = @as(u32, avail) -| used;
    const pad_top: u16 = @intCast(dead_space / 2);

    var y: u16 = y_offset +| ctx.m.gap +| pad_top;
    const row_pitch = rowPitch(ctx.m);
    for (windows, 0..) |win, i| {
        emitRow(ctx, win, x, y, inner_w, heights[i]);
        y = y +| heights[i] +| row_pitch;
    }
}

/// Water-filling: pins windows whose max_height is at or below their fair
/// share and redistributes their pixels, then distributes heights to the rest.
/// Zero boost uses an even split. Returns the total pixel height used.
fn fillHeights(ctx: tiling.LayoutCtx, windows: []const model.WindowId, avail: u16, boost: StackBoost, out: []u16) u32 {
    const n: u16 = @intCast(windows.len);
    const zero_boost = boost.isZero();

    var capped: [constants.max_tiled_windows]bool = undefined;
    @memset(capped[0..windows.len], false);
    // Snapshot each window's max_height ONCE: the water-fill below re-reads
    // the hint inside its pinning passes, and hoisting it keeps those passes
    // O(n) plain u16 compares instead of re-resolving the hint each time.
    var max_h: [constants.max_tiled_windows]u16 = undefined;
    for (windows, 0..) |win, i| max_h[i] = ctx.v.hints.forWin(win).max_height;
    var rem_avail = avail;
    var rem_weight: f32 = @as(f32, @floatFromInt(n)) + boost.top + boost.bottom;
    var rem_count = n;

    var pinned = true;
    while (pinned and rem_count > 0) {
        pinned = false;
        for (windows, 0..) |_, i| {
            if (capped[i]) continue;
            const w_i: f32 = windowWeight(@intCast(i), n, boost);
            // rem_weight ≥ rem_count here (windowWeight ≥ 1.0, boost ≥ 0), so
            // the division never divides by zero — no `else 0` arm needed.
            const fair: u16 = @intFromFloat(@as(f32, @floatFromInt(rem_avail)) * w_i / rem_weight);
            if (max_h[i] > 0 and max_h[i] <= fair) {
                out[i] = @max(ctx.min_dim, max_h[i]);
                capped[i] = true;
                rem_avail -|= out[i];
                rem_weight -= w_i;
                rem_count -= 1;
                pinned = true;
            }
        }
    }

    // Three rounding schemes coexist here, deliberately not merged: the
    // zero-boost pass uses integer even-split chunks (windowHeight: largest
    // rows first, any row differs from its neighbor by <= 1px); the boost pass
    // rounds cumulative pixel boundaries to nearest and diffs them; pinned
    // windows take their exact hint floored at min_dim. The pin threshold
    // `fair` above floors too, but only as a comparator.
    var cum: f32 = 0;
    var prev_px: f32 = 0;
    var seen: u16 = 0;
    for (windows, 0..) |_, i| {
        if (capped[i]) continue;
        if (zero_boost) {
            out[i] = windowHeight(seen, rem_count, rem_avail, ctx.min_dim);
            seen += 1;
        } else {
            cum += windowWeight(@intCast(i), n, boost);
            // Same rem_weight ≥ rem_count invariant as the pin pass above.
            const px: f32 = @round(@as(f32, @floatFromInt(rem_avail)) * cum / rem_weight);
            out[i] = @max(ctx.min_dim, @as(u16, @intFromFloat(@max(@as(f32, 0), px - prev_px))));
            prev_px = px;
        }
    }

    var total: u32 = 0;
    for (out) |h| total += h;
    return total;
}

/// Weight of stack slot `i`: 1.0 baseline plus `boost.top` (first slot) and
/// `boost.bottom` (last slot); both apply harmlessly when `count == 1`.
inline fn windowWeight(i: u16, count: u16, boost: StackBoost) f32 {
    var w: f32 = 1.0;
    if (i == 0) w += boost.top;
    if (i == count - 1) w += boost.bottom;
    return w;
}

inline fn stackSeamMargin(m: utils.Margins) u16 {
    return tiling.seamGap(m) +| rowPitch(m);
}

inline fn rowPitch(m: utils.Margins) u16 {
    return m.gap +| 2 *| m.border;
}

/// Minimum stack-pane width: widest bounded slave's max_width (floored to
/// min_dim) plus gap/border margins; horizontal mirror of max_height capping.
fn minStackWidth(
    ctx: tiling.LayoutCtx,
    windows: []const model.WindowId,
) u16 {
    var widest_bounded: u16 = 0;
    for (windows) |win| {
        const max_w = ctx.v.hints.forWin(win).max_width;
        if (max_w == 0) continue;
        widest_bounded = @max(widest_bounded, @max(ctx.min_dim, max_w));
    }
    if (widest_bounded == 0) return 0;
    // Reverse of tileStack's single-column stack_inner_w shrink: pane width
    // = content + (stack half-gap + shared gap + doubled border).
    return widest_bounded +| stackSeamMargin(ctx.m);
}

/// Tile the stack pane, spilling into a column-major overflow grid when the
/// stack exceeds what fits in a single column.
///
/// `boost` only affects the single-column path, see tileStackExtra for why.
fn tileStack(
    ctx: tiling.LayoutCtx,
    windows: []const model.WindowId,
    x: u16,
    y_offset: u16,
    w: u16,
    h: u16,
    boost: StackBoost,
) void {
    const stack_n: u16 = @intCast(windows.len);

    // Fits per window: min pane dim plus the row pitch (gap + doubled border).
    const space_per_window: u16 = ctx.min_dim +| rowPitch(ctx.m);
    const available: u32 = @as(u32, h) -| @as(u32, ctx.m.gap);
    const max_fit: u16 = @intCast(@max(1, available / space_per_window));

    if (stack_n <= max_fit) {
        const stack_inner_w = tiling.shrinkClamped(w, stackSeamMargin(ctx.m), ctx.min_dim);
        tileColumn(ctx, windows, x +| tiling.seamGap(ctx.m), y_offset, h, stack_inner_w, boost);
        return;
    }
    tileStackExtra(ctx, windows, x, y_offset, w, h, max_fit);
}

/// Column-major overflow grid: row `r` holds windows r, r+max_fit, ...
/// Overflow rows skip max_height redistribution and the stack boost.
fn tileStackExtra(
    ctx: tiling.LayoutCtx,
    windows: []const model.WindowId,
    x: u16,
    y_offset: u16,
    w: u16,
    h: u16,
    max_fit: u16,
) void {
    const stack_n: u16 = @intCast(windows.len);
    const row_avail = calcAvailableHeight(h, max_fit, ctx.m, ctx.min_dim);

    const min_col_w: u16 = ctx.min_dim +| utils.doubledBorder(ctx.m);

    var row: u16 = 0;
    while (row < max_fit) : (row += 1) {
        // Cap each column to a min_dim+border window so a column's origin never
        // leaves the stack pane; surplus (a row narrower than the column count)
        // has no free row to spill into and is parked instead.
        const cols_by_count: u16 = (stack_n - row + max_fit - 1) / max_fit;
        const cols_by_width: u16 = @max(1, (w +| ctx.m.gap) / (min_col_w +| ctx.m.gap));
        const cols_in_row: u16 = @max(1, @min(cols_by_count, cols_by_width));

        const gaps_in_row = tiling.seamGap(ctx.m) +| ctx.m.gap *| cols_in_row;
        const row_total_w = if (w > gaps_in_row) w - gaps_in_row else cols_in_row *| min_col_w;
        const col_w = row_total_w / cols_in_row;
        const col_inner_w = tiling.shrinkClamped(col_w, utils.doubledBorder(ctx.m), ctx.min_dim);

        const y_pos = y_offset +| ctx.m.gap +|
            @as(u16, @intCast(@as(u32, row) * @as(u32, row_avail) / @as(u32, max_fit))) +|
            row *| rowPitch(ctx.m);
        const row_h = windowHeight(row, max_fit, row_avail, ctx.min_dim);

        var win_idx: u16 = row;
        while (win_idx < stack_n) : (win_idx += max_fit) {
            const col: u16 = (win_idx - row) / max_fit;
            // Columns past the width cap would start outside the pane; park
            // them (no in-pane row remains for a true spill).
            if (col >= cols_in_row) {
                tiling.emitHidden(ctx.out, windows[win_idx]);
                continue;
            }
            emitRow(ctx, windows[win_idx], x +| tiling.seamGap(ctx.m) +| tiling.cellStride(col_w, ctx.m.gap, col), y_pos, col_inner_w, row_h);
        }
    }
}

/// Shared single-window row emission used by both layout passes (the stack
/// column and the multi-column grid). The two HEIGHT DISTRIBUTIONS stay at
/// the call sites on purpose: they differ in the min_dim-floor corner, and
/// merging them is not behavior-preserving.
inline fn emitRow(ctx: tiling.LayoutCtx, win: model.WindowId, px: u16, py: u16, w: u16, h: u16) void {
    tiling.emitRect(ctx.v, ctx.out, win, @intCast(px), @intCast(py), w, h);
}

/// Total pixel height available for window content after gaps and borders.
/// Falls back to count * min_dim when margins exceed total_h.
inline fn calcAvailableHeight(total_h: u16, count: u16, m: utils.Margins, min_dim: u16) u16 {
    // gap + count * rowPitch: the row seam gaps (one leading, count+1 with the
    // trailing gap folded in) plus each row's doubled border.
    const overhead = m.gap +| count *| rowPitch(m);
    return if (total_h > overhead) total_h - overhead else @min(count *| min_dim, total_h);
}

/// Height of window `i` out of `count`, distributing `available` pixels via
/// cumulative integer division. No two siblings differ by more than 1 px.
inline fn windowHeight(i: u16, count: u16, available: u16, min_dim: u16) u16 {
    const hi: u32 = (@as(u32, i) + 1) * @as(u32, available) / @as(u32, count);
    const lo: u32 = @as(u32, i) * @as(u32, available) / @as(u32, count);
    return @max(min_dim, @as(u16, @intCast(hi - lo)));
}

/// This layout's registry contribution: metadata plus the dispatch hook.
pub const module = tiling.layoutModule("master", "[]=", compute, .{
    .variant_count = 2,
    .fifo_variant = 1,
    .variant_parse = tiling.variantParse(&.{ "lifo", "fifo" }),
    .indicators = &.{ "[N]", "=N=" },
});
