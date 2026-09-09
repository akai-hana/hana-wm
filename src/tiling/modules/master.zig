//! Master-stack tiling layout.
//! Master + stack panes, spilling overflow into a column-major grid.

const std = @import("std");
const utils = @import("utils");
const constants = @import("constants");
const model = @import("model");
const tiling = @import("tiling");

/// Stack-column weight boosts derived from `secondary_balance`:
/// positive boosts the top slot, negative boosts the bottom slot.
pub const StackBoost = struct {
    top: f32 = 0,
    bottom: f32 = 0,

    inline fn isZero(self: StackBoost) bool {
        return self.top == 0 and self.bottom == 0;
    }

    /// Derive from `secondary_balance`: positive → top, negative → bottom.
    pub inline fn fromBalance(balance: f32) StackBoost {
        return .{ .top = @max(0, balance), .bottom = @max(0, -balance) };
    }
};

/// Master-stack layout: master pane + stack pane, gaps at screen edges and
/// half-gap between panes. Heights via cumulative integer division with
/// max_height capping (water-filling).
pub fn compute(v: tiling.View, out: *tiling.List) void {
    const windows = v.order;
    const n = windows.len;
    const m = v.env.margins;
    const ctx = tiling.LayoutCtx{
        .v = &v,
        .out = out,
        .m = m,
        .min_dim = v.env.min_dim,
    };

    const screen_w = v.workarea.width;
    const screen_h = v.workarea.height;
    const master_n: u16 = @intCast(@min(v.params.primary_count, n));
    const stack_n: u16 = @intCast(n - master_n);

    // When no stack exists the master pane takes the full width.
    const master_w_frac: u16 = if (stack_n > 0) blk: {
        const raw = @as(f32, @floatFromInt(screen_w)) * v.params.primary_width;
        break :blk utils.scaling.roundToU16(raw, 0.0);
    } else screen_w;

    // Shrink the stack pane to the widest bounded slave's max_width
    // (dialogs/small windows no longer leave a dead gap beside them).
    const is_primary_on_right = v.env.primary_on_right;
    const stack_pane_w: u16 = screen_w -| master_w_frac;
    const natural_stack_w: u16 = minStackWidth(ctx, windows[master_n..]);
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
        if (stack_n > 0) stackSeamMargin(m) else m.gap *| 2 + utils.doubledBorder(m),
        ctx.min_dim,
    );

    tileColumn(
        ctx,
        windows[0..master_n],
        master_x +| m.gap,
        tiling.waY(&v),
        screen_h,
        master_inner_w,
        .{},
    );

    if (stack_n == 0) return;

    const stack_origin: u16 = if (is_primary_on_right) m.gap else master_w;
    tileStack(
        ctx,
        windows[master_n..],
        stack_origin,
        tiling.waY(&v),
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

    var heights_buf: [constants.Limits.max_tiled_windows]u16 = undefined;
    const heights = heights_buf[0..windows.len];
    const used = distributeStackHeightsWeighted(ctx, windows, avail, boost, heights);

    // If every window is capped, sum(heights) < avail; centre the stack in
    // the column instead of stranding the slack at the bottom.
    const dead_space: u32 = @as(u32, avail) -| used;
    const pad_top: u16 = @intCast(dead_space / 2);

    var y: u16 = y_offset +| ctx.m.gap +| pad_top;
    for (windows, 0..) |win, i| {
        tiling.emitView(ctx.v, ctx.out, win, .{ .x = @intCast(x), .y = @intCast(y), .width = inner_w, .height = heights[i] }, true);
        y = y +| heights[i] +| ctx.m.gap +| 2 *| ctx.m.border;
    }
}

/// Packed bit-bag test/set over the capped-window flags.
inline fn bitIsSet(bits: []u8, i: usize) bool {
    return bits[i / 8] & (@as(u8, 1) << @intCast(i % 8)) != 0;
}

/// Leftover budget after the water-filling pass: the pixels, total weight,
/// and count of windows that were NOT capped.
const CapResult = struct {
    remaining_avail: u16,
    remaining_weight: f32,
    remaining_count: u16,
};

/// Water-filling pass: pins windows whose max_height is at or below their
/// fair share and redistributes their pixels, until no new window pins.
fn findCappedWindows(
    ctx: tiling.LayoutCtx,
    windows: []const model.WindowId,
    avail: u16,
    boost: StackBoost,
    out: []u16,
    capped: []u8,
) CapResult {
    const n: u16 = @intCast(windows.len);
    @memset(capped, 0);

    var remaining_avail = avail;
    var remaining_weight: f32 = @as(f32, @floatFromInt(n)) + boost.top + boost.bottom;
    var remaining_count: u16 = n;
    const zero_boost = boost.isZero();

    var pinned_any = true;
    while (pinned_any and remaining_count > 0) {
        pinned_any = false;
        for (windows, 0..) |win, i| {
            if (bitIsSet(capped, i)) continue;
            // When boost is zero every weight is identically 1.0; skip the
            // function call and its two branches to keep the hot path tight.
            const w_i: f32 = if (zero_boost) 1.0 else windowWeight(@intCast(i), n, boost);
            const fair_share: u16 = if (remaining_weight > 0)
                @intFromFloat(@as(f32, @floatFromInt(remaining_avail)) * w_i / remaining_weight)
            else
                0;
            const max_h = ctx.v.hints.forWin(win).max_height;
            if (max_h > 0 and max_h <= fair_share) {
                out[i] = @max(ctx.min_dim, max_h);
                capped[i / 8] |= @as(u8, 1) << @intCast(i % 8);
                remaining_avail = remaining_avail -| out[i];
                remaining_weight -= w_i;
                remaining_count -= 1;
                pinned_any = true;
            }
        }
    }

    return .{
        .remaining_avail = remaining_avail,
        .remaining_weight = remaining_weight,
        .remaining_count = remaining_count,
    };
}

/// Assigns heights to uncapped windows: even division (zero boost) when
/// `weighted` is false, else weighted cumulative division.
fn distributeHeights(
    weighted: bool,
    windows: []const model.WindowId,
    boost: StackBoost,
    capped: []u8,
    remaining_weight: f32,
    remaining_count: u16,
    remaining_avail: u16,
    min_dim: u16,
    out: []u16,
) void {
    const n: u16 = @intCast(windows.len);
    var cum: f32 = 0;
    var prev_px: f32 = 0;
    var seen: u16 = 0;
    for (windows, 0..) |_, i| {
        if (bitIsSet(capped, i)) continue;
        if (weighted) {
            cum += windowWeight(@intCast(i), n, boost);
            const px: f32 = if (remaining_weight > 0)
                @round(@as(f32, @floatFromInt(remaining_avail)) * cum / remaining_weight)
            else
                0;
            out[i] = @max(min_dim, @as(u16, @intFromFloat(@max(@as(f32, 0), px - prev_px))));
            prev_px = px;
        } else {
            out[i] = windowHeight(seen, remaining_count, remaining_avail, min_dim);
            seen += 1;
        }
    }
}

/// Split `avail` content-height pixels across `windows` into `out`, pinning
/// capped windows (water-filling); zero boost uses an even split.
fn distributeStackHeightsWeighted(
    ctx: tiling.LayoutCtx,
    windows: []const model.WindowId,
    avail: u16,
    boost: StackBoost,
    out: []u16,
) u32 {
    var capped_buf: [constants.Limits.max_tiled_windows / 8]u8 = undefined;
    const capped = capped_buf[0 .. (windows.len + 7) / 8];

    const cap = findCappedWindows(ctx, windows, avail, boost, out, capped);
    distributeHeights(!boost.isZero(), windows, boost, capped, cap.remaining_weight, cap.remaining_count, cap.remaining_avail, ctx.min_dim, out);

    // Return the total so the caller avoids a redundant summation pass.
    var total: u32 = 0;
    for (out) |h| total += h;
    return total;
}

/// Weight of stack slot `i`: 1.0 baseline plus `boost.top` (first slot) and
/// `boost.bottom` (last slot); both apply harmlessly when `count == 1`.
inline fn windowWeight(i: u16, count: u16, boost: StackBoost) f32 {
    var w: f32 = 1.0;
    if (i == 0) w += boost.top;
    if (count > 0 and i == count - 1) w += boost.bottom;
    return w;
}

inline fn stackSeamMargin(m: utils.Margins) u16 {
    return m.gap / 2 +| m.gap +| 2 *| m.border;
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

    const space_per_window: u32 =
        @max(1, @as(u32, ctx.min_dim) + 2 * @as(u32, ctx.m.border) + @as(u32, ctx.m.gap));
    const available: u32 = @as(u32, h) -| @as(u32, ctx.m.gap);
    const max_fit: u16 = @intCast(@max(1, available / space_per_window));

    if (stack_n <= max_fit) {
        const stack_inner_w = tiling.shrinkClamped(w, stackSeamMargin(ctx.m), ctx.min_dim);
        tileColumn(ctx, windows, x +| ctx.m.gap / 2, y_offset, h, stack_inner_w, boost);
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

    var row: u16 = 0;
    while (row < max_fit) : (row += 1) {
        // Cap each column to a min_dim+border window so neighbors never
        // overlap; surplus spills to the next row, bounded by the max_fit loop.
        const min_col_w: u16 = ctx.min_dim +| 2 *| ctx.m.border;
        const cols_by_count: u16 = (stack_n - row + max_fit - 1) / max_fit;
        const cols_by_width: u16 = @max(1, (w +| ctx.m.gap) / (min_col_w +| ctx.m.gap));
        const cols_in_row: u16 = @max(1, @min(cols_by_count, cols_by_width));

        const gaps_in_row = ctx.m.gap / 2 +| ctx.m.gap *| cols_in_row;
        const row_total_w = if (w > gaps_in_row) w - gaps_in_row else cols_in_row *| min_col_w;
        const col_w = row_total_w / cols_in_row;
        const col_inner_w = tiling.shrinkClamped(col_w, 2 * ctx.m.border, ctx.min_dim);

        const y_pos = y_offset +| ctx.m.gap +|
            @as(u16, @intCast(@as(u32, row) * @as(u32, row_avail) / @as(u32, max_fit))) +|
            row *| (ctx.m.gap +| 2 *| ctx.m.border);
        const row_h = windowHeight(row, max_fit, row_avail, ctx.min_dim);

        var win_idx: u16 = row;
        while (win_idx < stack_n) : (win_idx += max_fit) {
            const col: u16 = (win_idx - row) / max_fit;
            tiling.emitView(ctx.v, ctx.out, windows[win_idx], .{ .x = @intCast(x +| ctx.m.gap / 2 +| col *| (col_w +| ctx.m.gap)), .y = @intCast(y_pos), .width = col_inner_w, .height = row_h }, true);
        }
    }
}

/// Total pixel height available for window content after gaps and borders.
/// Falls back to count * min_dim when margins exceed total_h.
inline fn calcAvailableHeight(total_h: u16, count: u16, m: utils.Margins, min_dim: u16) u16 {
    const overhead = m.gap *| (count + 1) +| m.border *| 2 *| count;
    return if (total_h > overhead) total_h - overhead else count *| min_dim;
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
