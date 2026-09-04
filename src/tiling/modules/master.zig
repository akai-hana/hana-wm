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
    // Empty workspace emits nothing; callers may run layouts on an empty
    // order (e.g. sync's per-reconcile compute), so it is a supported input.
    if (v.order.len == 0) return;

    const windows = v.order;
    const n = windows.len;
    const min_dim = v.env.min_dim;

    const m = v.env.margins;
    const screen_w = v.workarea.width;
    const screen_h = v.workarea.height;
    const master_n: u16 = @intCast(@min(v.params.primary_count, n));
    const stack_n: u16 = @intCast(n - master_n);

    // When no stack exists the master pane takes the full width.
    const master_w_frac: u16 = if (stack_n > 0) blk: {
        const raw = @as(f32, @floatFromInt(screen_w)) * v.params.primary_width;
        const capped = @min(raw, @as(f32, @floatFromInt(std.math.maxInt(u16))));
        break :blk @intFromFloat(@round(capped));
    } else screen_w;

    // Shrink the stack pane to the widest bounded slave's max_width
    // (dialogs/small windows no longer leave a dead gap beside them).
    const is_primary_on_right = v.env.primary_on_right;
    const stack_pane_w: u16 = screen_w -| master_w_frac;
    const natural_stack_w: u16 = minStackWidth(&v, windows[master_n..], m, min_dim);
    const stack_w: u16 = if (natural_stack_w > 0 and natural_stack_w < stack_pane_w)
        natural_stack_w
    else
        stack_pane_w;
    const master_w: u16 = screen_w -| stack_w;

    const master_x: u16 = if (is_primary_on_right) screen_w -| master_w else 0;

    // The master column gets a full gap on its screen edge and a half-gap
    // toward the stack; with no stack both edges carry a full gap. Borders
    // are then subtracted from the width.
    const edge_inset: u16 = if (stack_n > 0) m.gap +| m.gap / 2 else m.gap *| 2;
    const master_inner_w = tiling.shrinkClamped(
        master_w,
        edge_inset + utils.doubledBorder(m),
        min_dim,
    );

    tileColumn(
        &v,
        out,
        windows[0..master_n],
        master_x +| m.gap,
        tiling.waY(&v),
        screen_h,
        master_inner_w,
        m,
        .{},
        min_dim,
    );

    if (stack_n == 0) return;

    const stack_origin: u16 = if (is_primary_on_right) m.gap else master_w;
    tileStack(
        &v,
        out,
        windows[master_n..],
        stack_origin,
        tiling.waY(&v),
        stack_w,
        screen_h,
        m,
        StackBoost.fromBalance(v.params.secondary_balance),
        min_dim,
    );
}

/// Tile a vertical column at fixed `x` with content width `inner_w`,
/// distributing heights via cumulative division with max_height capping.
fn tileColumn(
    v: *const tiling.View,
    out: *tiling.List,
    windows: []const model.WindowId,
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

    var heights_buf: [constants.Limits.max_tiled_windows]u16 = undefined;
    const heights = heights_buf[0..windows.len];
    const used = distributeStackHeightsWeighted(v, windows, avail, boost, min_dim, heights);

    // If every window is capped, sum(heights) < avail; centre the stack in
    // the column instead of stranding the slack at the bottom.
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
        tiling.emitView(v, out, win, rect, true);
        y = y +| heights[i] +| m.gap +| 2 *| m.border;
    }
}

/// Packed bit-bag test/set over the capped-window flags.
inline fn bitIsSet(bits: []u8, i: usize) bool {
    return bits[i / 8] & (@as(u8, 1) << @intCast(i % 8)) != 0;
}

inline fn bitSet(bits: []u8, i: usize) void {
    bits[i / 8] |= @as(u8, 1) << @intCast(i % 8);
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
    v: *const tiling.View,
    windows: []const model.WindowId,
    avail: u16,
    boost: StackBoost,
    min_dim: u16,
    out: []u16,
    capped: []u8,
) CapResult {
    const n: u16 = @intCast(windows.len);
    @memset(capped, 0);

    var remaining_avail = avail;
    var remaining_weight: f32 = totalWeight(n, boost);
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
            const max_h = windowMaxHeight(v, win);
            if (max_h > 0 and max_h <= fair_share) {
                out[i] = @max(min_dim, max_h);
                bitSet(capped, i);
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

/// Assigns heights to uncapped windows using plain even division (zero boost).
fn distributeEven(
    windows: []const model.WindowId,
    capped: []u8,
    remaining_count: u16,
    remaining_avail: u16,
    min_dim: u16,
    out: []u16,
) void {
    var seen: u16 = 0;
    for (windows, 0..) |_, i| {
        if (bitIsSet(capped, i)) continue;
        out[i] = windowHeight(seen, remaining_count, remaining_avail, min_dim);
        seen += 1;
    }
}

/// Assigns heights to uncapped windows using weighted cumulative division.
fn distributeWeighted(
    windows: []const model.WindowId,
    boost: StackBoost,
    capped: []u8,
    remaining_weight: f32,
    remaining_avail: u16,
    min_dim: u16,
    out: []u16,
) void {
    const n: u16 = @intCast(windows.len);
    var cum: f32 = 0;
    var prev_px: f32 = 0;
    for (windows, 0..) |_, i| {
        if (bitIsSet(capped, i)) continue;
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

/// Split `avail` content-height pixels across `windows` into `out`, pinning
/// capped windows (water-filling); zero boost uses an even split.
fn distributeStackHeightsWeighted(
    v: *const tiling.View,
    windows: []const model.WindowId,
    avail: u16,
    boost: StackBoost,
    min_dim: u16,
    out: []u16,
) u32 {
    var capped_buf: [constants.Limits.max_tiled_windows / 8]u8 = undefined;
    const capped = capped_buf[0 .. (windows.len + 7) / 8];

    const cap = findCappedWindows(v, windows, avail, boost, min_dim, out, capped);

    if (boost.isZero()) {
        distributeEven(windows, capped, cap.remaining_count, cap.remaining_avail, min_dim, out);
    } else {
        distributeWeighted(
            windows,
            boost,
            capped,
            cap.remaining_weight,
            cap.remaining_avail,
            min_dim,
            out,
        );
    }

    // Return the total so the caller avoids a redundant summation pass.
    var total: u32 = 0;
    for (out) |h| total += h;
    return total;
}

/// Sum of every stack slot's weight (see windowWeight) before any capping.
inline fn totalWeight(count: u16, boost: StackBoost) f32 {
    return @as(f32, @floatFromInt(count)) + boost.top + boost.bottom;
}

/// Weight of stack slot `i`: 1.0 baseline plus `boost.top` (first slot) and
/// `boost.bottom` (last slot); both apply harmlessly when `count == 1`.
inline fn windowWeight(i: u16, count: u16, boost: StackBoost) f32 {
    var w: f32 = 1.0;
    if (i == 0) w += boost.top;
    if (count > 0 and i == count - 1) w += boost.bottom;
    return w;
}

/// Declared max_height for `win`, or 0 when it declared none (0 = unconstrained).
inline fn windowMaxHeight(v: *const tiling.View, win: model.WindowId) u16 {
    return v.hints.forWin(win).max_height;
}

/// Minimum stack-pane width: widest bounded slave's max_width (floored to
/// min_dim) plus gap/border margins; horizontal mirror of max_height capping.
fn minStackWidth(
    v: *const tiling.View,
    windows: []const model.WindowId,
    m: utils.Margins,
    min_dim: u16,
) u16 {
    var widest_bounded: u16 = 0;
    for (windows) |win| {
        const max_w = v.hints.forWin(win).max_width;
        if (max_w == 0) continue;
        widest_bounded = @max(widest_bounded, @max(min_dim, max_w));
    }
    if (widest_bounded == 0) return 0;
    // Reverse of tileStack's single-column stack_inner_w shrink: pane width
    // = content + (stack half-gap + shared gap + doubled border).
    return widest_bounded +| (m.gap / 2 +| m.gap +| 2 *| m.border);
}

/// Tile the stack pane, spilling into a column-major overflow grid when the
/// stack exceeds what fits in a single column.
///
/// `boost` only affects the single-column path, see tileStackExtra for why.
fn tileStack(
    v: *const tiling.View,
    out: *tiling.List,
    windows: []const model.WindowId,
    x: u16,
    y_offset: u16,
    w: u16,
    h: u16,
    m: utils.Margins,
    boost: StackBoost,
    min_dim: u16,
) void {
    const stack_n: u16 = @intCast(windows.len);

    const space_per_window: u32 =
        @max(1, @as(u32, min_dim) + 2 * @as(u32, m.border) + @as(u32, m.gap));
    const available: u32 = @as(u32, h) -| @as(u32, m.gap);
    const max_fit: u16 = @intCast(@max(1, available / space_per_window));

    if (stack_n <= max_fit) {
        const stack_inner_w = tiling.shrinkClamped(w, m.gap / 2 + (m.gap + 2 * m.border), min_dim);
        tileColumn(v, out, windows, x +| m.gap / 2, y_offset, h, stack_inner_w, m, boost, min_dim);
        return;
    }
    tileStackExtra(v, out, windows, x, y_offset, w, h, max_fit, m, min_dim);
}

/// Column-major overflow grid: row `r` holds windows r, r+max_fit, ...
/// Overflow rows skip max_height redistribution and the stack boost.
fn tileStackExtra(
    v: *const tiling.View,
    out: *tiling.List,
    windows: []const model.WindowId,
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
        // Cap each column to a min_dim+border window so neighbors never
        // overlap; surplus spills to the next row, bounded by the max_fit loop.
        const min_col_w: u16 = min_dim +| 2 *| m.border;
        const cols_by_count: u16 = (stack_n - row + max_fit - 1) / max_fit;
        const cols_by_width: u16 = @max(1, (w +| m.gap) / (min_col_w +| m.gap));
        const cols_in_row: u16 = @max(1, @min(cols_by_count, cols_by_width));

        const gaps_in_row = m.gap / 2 +| m.gap *| cols_in_row;
        const row_total_w = if (w > gaps_in_row) w - gaps_in_row else cols_in_row *| min_col_w;
        const col_w = row_total_w / cols_in_row;
        const col_inner_w = tiling.shrinkClamped(col_w, 2 * m.border, min_dim);

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
            tiling.emitView(v, out, windows[win_idx], rect, true);
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

/// Y position of window `i`, derived from the same cumulative formula so that
/// preceding windows' heights (which may vary by 1 px) are accounted for.
inline fn windowY(i: u16, count: u16, available: u16, y_offset: u16, m: utils.Margins) u16 {
    const cum: u32 = @as(u32, i) * @as(u32, available) / @as(u32, count);
    return y_offset +| m.gap +| @as(u16, @intCast(cum)) +| i *| (m.gap +| 2 *| m.border);
}

/// This layout's registry contribution: metadata plus the dispatch hook.
pub const module: @import("plugin").Layout = .{
    .name = "master",
    .compute = tiling.computeHook(compute),
    .variant_count = 2,
    .has_variants = true,
    .fifo_variant = 1,
    .variant_parse = tiling.variantParse(&.{ "lifo", "fifo" }),
    .icon = "[]=",
    .indicators = &.{ "[N]", "=N=" },
};
