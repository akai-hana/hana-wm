//! Master-stack tiling layout.
//! Master + stack panes, spilling overflow into a column-major grid.

const std = @import("std");
const model = @import("model");
const tiling = @import("tiling");

const scaling = @import("scaling");
/// Stack-column weight boosts derived from `secondary_balance`: positive boosts the top
/// slot, negative the bottom.
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

/// Master-stack layout: master + stack panes, gaps at screen edges and a half-gap
/// between panes. Heights via cumulative integer division with max_height capping
/// (water-filling).
fn compute(v: *const tiling.View, out: *tiling.List) void {
    const windows = v.order;
    const n = windows.len;
    const ctx = tiling.LayoutCtx.init(v, out);
    const m = ctx.m;

    const screen_w = tiling.waWidth(v.workarea);
    const screen_h = tiling.waHeight(v.workarea);
    // A workarea smaller than edge-gap plus a border-inset pane on either axis
    // (including the degenerate 0x0) cannot host a single placement: shrinkClamped's
    // min_dim floor and the water-fill's height floor would flare windows off the
    // workarea. Park everything.
    if (!tiling.insetFits(screen_w, screen_h, tiling.totalInset(m.gap, m))) {
        for (windows) |win| tiling.emitHidden(ctx.out, win);
        return;
    }
    // Row-fit count: windows that fit in one column at min pane height, i.e. min pane
    // dim plus row pitch (gap + doubled border) each. A zero min_dim+gap+border Env
    // would make the denominator 0 and panic, so it floors to 1 (the fit count then
    // goes huge, which the stack/clamp handle). The same row_fit caps the master COUNT
    // below -- floored at 1, else a primary_count of 0 would size the master pane to
    // zero width -- so surplus windows fall to tileStack, which has its own
    // overflow/park guard; without the cap a master column overflows its rows off the
    // workarea.
    const space_per_window: u16 = ctx.min_dim +| rowPitch(ctx.m);
    const available: u32 = @as(u32, screen_h) -| @as(u32, m.gap);
    const row_fit: u16 = @intCast(@max(1, available / @max(1, @as(u32, space_per_window))));
    const master_n: u16 = @intCast(@max(1, @min(@min(v.params.primary_count, n), row_fit)));
    const stack_n: u16 = @intCast(n - master_n);
    const stack_windows = windows[master_n..];
    const y: u16 = @intCast(tiling.waY(v.workarea));

    // When no stack exists the master pane takes the full width.
    const master_w_frac: u16 = if (stack_n > 0)
        scaling.roundToU16(@as(f32, @floatFromInt(screen_w)) * v.params.primary_width, 0.0)
    else
        screen_w;

    // Shrink the stack pane to the widest bounded slave's max_width, so dialogs/small
    // windows don't leave a dead gap beside them.
    const is_primary_on_right = ctx.v.env.primary_on_right;
    const stack_pane_w: u16 = screen_w -| master_w_frac;
    const natural_stack_w: u16 = minStackWidth(ctx, stack_windows);
    const stack_w: u16 = if (natural_stack_w > 0 and natural_stack_w < stack_pane_w)
        natural_stack_w
    else
        stack_pane_w;
    const master_w: u16 = screen_w -| stack_w;

    const master_x: u16 = if (is_primary_on_right) screen_w -| master_w else 0;

    // The master column gets a full gap on its screen edge and a half-gap toward the
    // stack (both edges full when there is no stack); borders are then subtracted from
    // the width. A pane no wider than those margins cannot host the column:
    // shrinkClamped's min_dim floor would flare it over the stack (primary_width near
    // 0 suffices). Park the master; the stack survives.
    const master_margin = if (stack_n > 0) stackSeamMargin(m) else tiling.totalInset(m.gap, m);
    if (master_w > master_margin) {
        const master_inner_w = tiling.shrinkClamped(master_w, master_margin, ctx.min_dim);
        tileColumn(
            ctx,
            windows[0..master_n],
            master_x +| m.gap,
            y,
            screen_h,
            master_inner_w,
            .{},
        );
    } else {
        for (windows[0..master_n]) |win| tiling.emitHidden(ctx.out, win);
    }

    if (stack_n == 0) return;

    const stack_origin: u16 = if (is_primary_on_right) m.gap else master_w;
    tileStack(
        ctx,
        stack_windows,
        stack_origin,
        y,
        stack_w,
        screen_h,
        row_fit,
        StackBoost.fromBalance(v.params.secondary_balance),
    );
}

/// Tile a vertical column at fixed `x` with content width `inner_w`, distributing
/// heights via cumulative division with max_height capping.
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

    var heights_buf: [model.max_tiled_windows]u16 = undefined;
    const heights = heights_buf[0..windows.len];
    const used = fillHeights(ctx, windows, avail, boost, heights);
    // Every water-filled height floors at min_dim, so the total can exceed avail when
    // a boosted share starves a sibling below its floor (or fair shares were already
    // under it): parking the column beats flaring its bottom rows off the workarea. A
    // zero height in the mix (min_dim=0 splits rounding a share to 0) is the unmappable
    // twin: park rather than hand the server a zero-area rect.
    var any_zero = false;
    for (heights) |hi| {
        if (hi == 0) any_zero = true;
    }
    if (used > avail or any_zero) {
        for (windows) |win| tiling.emitHidden(ctx.out, win);
        return;
    }

    // If every window is capped, sum(heights) < avail: centre the stack in the column
    // instead of stranding the slack at the bottom.
    const dead_space: u32 = @as(u32, avail) -| used;
    const pad_top: u16 = @intCast(dead_space / 2);

    var y: u16 = y_offset +| ctx.m.gap +| pad_top;
    const row_pitch = rowPitch(ctx.m);
    for (windows, 0..) |win, i| {
        emitRow(ctx, win, x, y, inner_w, heights[i]);
        y = y +| heights[i] +| row_pitch;
    }
}

/// Per-window water-fill state: the snapshot `max_height` and the pinned flag, packed
/// in one AoS slot -- both indexed by column position and consulted together on every
/// pinning pass.
const FillSlot = struct {
    max_h: u16 = 0,
    capped: bool = false,
};

/// Water-filling: pins windows whose max_height is at or below their fair share and
/// redistributes their pixels, then distributes heights to the rest. Zero boost uses
/// an even split. Returns the total pixel height used.
fn fillHeights(ctx: tiling.LayoutCtx, windows: []const model.WindowId, avail: u16, boost: StackBoost, out: []u16) u32 {
    const n: u16 = @intCast(windows.len);
    const zero_boost = boost.isZero();

    // Snapshot each window's max_height ONCE: the water-fill below would otherwise
    // re-read the hint inside every pinning pass, and hoisting keeps those passes O(n)
    // plain u16 compares.
    var slots_buf: [model.max_tiled_windows]FillSlot = @splat(.{});
    const slots = slots_buf[0..windows.len];
    for (windows, 0..) |win, i| slots[i].max_h = ctx.v.hintsFor(win).max_height;
    var rem_avail = avail;
    var rem_weight: f32 = @as(f32, @floatFromInt(n)) + boost.top + boost.bottom;
    var rem_count = n;

    var pinned = true;
    while (pinned and rem_count > 0) {
        pinned = false;
        for (windows, 0..) |_, i| {
            if (slots[i].capped) continue;
            const w_i: f32 = windowWeight(@intCast(i), n, boost);
            // rem_weight ≥ rem_count here (windowWeight ≥ 1.0, boost ≥ 0), so the
            // division can never divide by zero.
            const fair: u16 = @intFromFloat(@as(f32, @floatFromInt(rem_avail)) * w_i / rem_weight);
            if (slots[i].max_h > 0 and slots[i].max_h <= fair) {
                out[i] = @max(ctx.min_dim, slots[i].max_h);
                slots[i].capped = true;
                rem_avail -|= out[i];
                rem_weight -= w_i;
                rem_count -= 1;
                pinned = true;
            }
        }
    }

    // Three rounding schemes coexist deliberately unmerged: the zero-boost pass uses
    // integer even-split chunks (windowHeight: any row differs from its neighbor by
    // <= 1px); the boost pass rounds cumulative pixel boundaries to nearest and diffs
    // them; pinned windows take their exact hint floored at min_dim. The pin threshold
    // `fair` above floors too, only as a comparator.
    var cum: f32 = 0;
    var prev_px: f32 = 0;
    var seen: u16 = 0;
    for (windows, 0..) |_, i| {
        if (slots[i].capped) continue;
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
/// `boost.bottom` (last); both apply harmlessly when `count == 1`.
inline fn windowWeight(i: u16, count: u16, boost: StackBoost) f32 {
    var w: f32 = 1.0;
    if (i == 0) w += boost.top;
    if (i == count - 1) w += boost.bottom;
    return w;
}

inline fn stackSeamMargin(m: model.Margins) u16 {
    return tiling.seamGap(m) +| rowPitch(m);
}

inline fn rowPitch(m: model.Margins) u16 {
    return m.gap +| 2 *| m.border;
}

/// Minimum stack-pane width: widest bounded slave's max_width (floored to min_dim)
/// plus gap/border margins; horizontal mirror of max_height capping.
fn minStackWidth(
    ctx: tiling.LayoutCtx,
    windows: []const model.WindowId,
) u16 {
    var widest_bounded: u16 = 0;
    for (windows) |win| {
        const max_w = ctx.v.hintsFor(win).max_width;
        if (max_w == 0) continue;
        widest_bounded = @max(widest_bounded, @max(ctx.min_dim, max_w));
    }
    if (widest_bounded == 0) return 0;
    // Reverse of tileStack's single-column shrink: pane width = content +
    // (stack half-gap + shared gap + doubled border).
    return widest_bounded +| stackSeamMargin(ctx.m);
}

/// Tile the stack pane, spilling into a column-major overflow grid when the stack
/// exceeds a single column. `row_fit` is compute's single row-fit computation (shared
/// with the master COUNT cap); `boost` only affects the single-column path (see
/// tileStackExtra).
fn tileStack(
    ctx: tiling.LayoutCtx,
    windows: []const model.WindowId,
    x: u16,
    y_offset: u16,
    w: u16,
    h: u16,
    row_fit: u16,
    boost: StackBoost,
) void {
    const stack_n: u16 = @intCast(windows.len);

    if (stack_n <= row_fit) {
        // A stack pane no wider than its seam+border margins cannot host a column:
        // shrinkClamped's min_dim floor would flare it over the master (or the screen
        // edge). Park the stack; the master survives.
        if (w <= stackSeamMargin(ctx.m)) {
            for (windows) |win| tiling.emitHidden(ctx.out, win);
            return;
        }
        const stack_inner_w = tiling.shrinkClamped(w, stackSeamMargin(ctx.m), ctx.min_dim);
        tileColumn(ctx, windows, x +| tiling.seamGap(ctx.m), y_offset, h, stack_inner_w, boost);
        return;
    }
    tileStackExtra(ctx, windows, x, y_offset, w, h, row_fit);
}

/// Column-major overflow grid: row `r` holds windows r, r+max_fit, ... Overflow rows
/// skip max_height redistribution and the stack boost.
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
    // Same seam-margin floor as the single-column path: a pane no wider than its
    // seam+border margins cannot host even one column (min_col_w below would otherwise
    // inflate a column past the pane). Park; master survives.
    if (w <= stackSeamMargin(ctx.m)) {
        for (windows) |win| tiling.emitHidden(ctx.out, win);
        return;
    }
    const row_avail = calcAvailableHeight(h, max_fit, ctx.m, ctx.min_dim);
    // Row heights floor at min_dim too: rows whose share cannot hold max_fit * min_dim
    // would spill the bottom row off the workarea. Each row takes an integer share of
    // row_avail (windowHeight), so every row is >= 1 only while row_avail >= max_fit;
    // min_dim is the stronger bound at >= 1.
    if (row_avail < @max(max_fit, max_fit *| ctx.min_dim)) {
        for (windows) |win| tiling.emitHidden(ctx.out, win);
        return;
    }
    // row_fit invariant: with row_avail >= max_fit each row's integer share is >= 1
    // (consecutive cumulative-division floors differ by at least one), so the emission
    // can never hand the server a zero-height row. Debug-only.
    std.debug.assert(row_avail >= max_fit);

    const min_col_w: u16 = ctx.min_dim +| model.doubledBorder(ctx.m);

    var row: u16 = 0;
    while (row < max_fit) : (row += 1) {
        // Cap each column to a min_dim+border window so a column's origin never leaves
        // the stack pane; surplus (a row narrower than the column count) has no free
        // row to spill into and is parked.
        const cols_by_count: u16 = (stack_n - row + max_fit - 1) / max_fit;
        // The width budget is the pane minus the LEADING seam: column k starts at
        // seam + k * (col_w + gap), so the last column needs
        // seam + cols * min_col_w + (cols-1)*gap <= w. Budgeting the seam out let a
        // narrow pane claim one column too many and the stride pushed it off the
        // workarea (fuzz-found: w=24, seam=5, cols_by_width=2 -> second column 2px past
        // the pane edge).
        const usable_w = w -| tiling.seamGap(ctx.m);
        const cols_by_width: u16 = @max(1, (usable_w +| ctx.m.gap) / @max(1, min_col_w +| ctx.m.gap));
        const cols_in_row: u16 = @max(1, @min(cols_by_count, cols_by_width));

        const gaps_in_row = tiling.seamGap(ctx.m) +| ctx.m.gap *| cols_in_row;
        // The min_col_w floor is capped by the pane: a count-driven column count can ask
        // for more pixels than a narrow pane has.
        const row_total_w: u16 = if (w > gaps_in_row) w - gaps_in_row else @min(cols_in_row *| min_col_w, w);
        const col_w = row_total_w / cols_in_row;
        // A column narrower than the doubled border: the shrink's min_dim floor would
        // flare the window over its neighbour. Park the row's windows (the col >=
        // cols_in_row park below is the sibling guard).
        if (col_w <= model.doubledBorder(ctx.m)) {
            var park_idx: u16 = row;
            while (park_idx < stack_n) : (park_idx += max_fit) tiling.emitHidden(ctx.out, windows[park_idx]);
            continue;
        }
        const col_inner_w = tiling.shrinkClamped(col_w, model.doubledBorder(ctx.m), ctx.min_dim);

        const y_pos = y_offset +| ctx.m.gap +|
            @as(u16, @intCast(@as(u32, row) * @as(u32, row_avail) / @as(u32, max_fit))) +|
            row *| rowPitch(ctx.m);
        const row_h = windowHeight(row, max_fit, row_avail, ctx.min_dim);

        var win_idx: u16 = row;
        while (win_idx < stack_n) : (win_idx += max_fit) {
            const col: u16 = (win_idx - row) / max_fit;
            // Columns past the width cap would start outside the pane; park them (no
            // in-pane row remains for a true spill).
            if (col >= cols_in_row) {
                tiling.emitHidden(ctx.out, windows[win_idx]);
                continue;
            }
            emitRow(ctx, windows[win_idx], x +| tiling.seamGap(ctx.m) +| tiling.cellStride(col_w, ctx.m.gap, col), y_pos, col_inner_w, row_h);
        }
    }
}

/// Shared single-window row emission used by both layout passes. The two HEIGHT
/// DISTRIBUTIONS stay at the call sites on purpose: they differ in the min_dim-floor
/// corner, and merging them is not behavior-preserving.
inline fn emitRow(ctx: tiling.LayoutCtx, win: model.WindowId, px: u16, py: u16, w: u16, h: u16) void {
    // Every caller parks degenerate geometry instead of emitting it (zero height
    // share, column at/below its doubled border, pane at/below its seam margin), so a
    // zero here is a caller bug. The sink would reject the configure (0 is a BadValue),
    // but a Debug assert names the layout path instead of the server error. Debug-only.
    std.debug.assert(w >= 1 and h >= 1);
    // px is relative to the workarea's left edge (master_x/stack_origin both start at
    // 0 within screen_w): offset by the workarea origin (waX) so it lands on a
    // side-claimed workarea, not the screen's left edge.
    tiling.emitRect(ctx.v, ctx.out, win, @as(i32, @intCast(px)) + tiling.waX(ctx.v.workarea), @intCast(py), w, h);
}

/// Total pixel height available for content after gaps and borders. Saturates to 0
/// when the margins exceed total_h -- the degenerate case the callers' min_dim-fit
/// guards turn into a park.
inline fn calcAvailableHeight(total_h: u16, count: u16, m: model.Margins, min_dim: u16) u16 {
    _ = min_dim;
    // gap + count * rowPitch: the row seam gaps (one leading, count+1 with the trailing
    // gap folded in) plus each row's doubled border.
    const overhead = m.gap +| count *| rowPitch(m);
    return total_h -| overhead;
}

/// Height of window `i` out of `count`, distributing `available` pixels via cumulative
/// integer division. No two siblings differ by more than 1 px.
inline fn windowHeight(i: u16, count: u16, available: u16, min_dim: u16) u16 {
    const hi: u32 = (@as(u32, i) + 1) * @as(u32, available) / @as(u32, count);
    const lo: u32 = @as(u32, i) * @as(u32, available) / @as(u32, count);
    return @max(min_dim, @as(u16, @intCast(hi - lo)));
}

/// The ONE variant table for this layout; layoutModule derives `fifo_variant`,
/// `variant_count`, `variant_parse` and `indicators` from it.
const variants = [_]tiling.Variant{
    .{ .name = "lifo", .indicator = "[N]" },
    .{ .name = "fifo", .indicator = "=N=", .fifo = true },
};

pub const module = tiling.layoutModule("master", "[]=", compute, &variants, .{});
