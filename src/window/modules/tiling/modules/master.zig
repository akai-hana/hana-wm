//! Master-stack tiling layout
//! Divides the screen into a master pane and a stack pane, with overflow handling for extra windows.

const utils = @import("utils");
const constants = @import("constants");

const tiling = @import("tiling");
const layouts = @import("layouts");

/// The two adjustable stack-column weights derived from LayoutConfig's
/// signed `stack_balance` scalar (see that field's doc comment in tiling.zig
/// for why it's a single signed value rather than two independent boosts).
/// Bundled together so tileColumn/tileStack only need to thread one extra
/// parameter through.
///
/// tileStack's simple column path splits height among stack ("slave")
/// windows proportionally to weight; every slot starts at weight 1.0 (an
/// even split, identical to the pre-existing behaviour), and `top`/`bottom`
/// here add to the weight of the first/last slot respectively. Because the
/// *shrink* isn't subtracted from specific slots but simply falls out of
/// everyone else's weight becoming a smaller fraction of a larger total,
/// this generalizes correctly to any slave count without extra bookkeeping:
///   - 2 slaves: boosting one slot's weight directly steals share from the
///     other one — matches "grow slave A, shrink slave B" 1:1.
///   - 3+ slaves: boosting the top (or bottom) slot's weight shrinks every
///     other slot's share by the same proportion, since they all keep equal
///     weight (1.0) relative to each other — matches "the rest shrink evenly".
/// See distributeStackHeightsWeighted for the actual math.
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
    const n = windows.len;
    if (n == 0) return;

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

    // Inner width accounts for the gap between master and stack panes.
    const master_inner_w = if (stack_n > 0)
        layouts.shrinkClamped(master_w, m.gap + (m.gap / 2 + utils.doubledBorder(m)))
    else
        layouts.shrinkClamped(master_w, m.gap + (m.gap + utils.doubledBorder(m)));

    // The master column never uses the stack boost — it isn't a "slave"
    // column, so mod+n/mod+o have no effect on it.
    tileColumn(ctx, windows[0..master_n], master_x +| m.gap, y_offset, screen_h, master_inner_w, m, .{});

    if (stack_n == 0) return;

    const stack_x: u16 = if (is_master_on_right) 0 else master_w;
    tileStack(ctx, windows[master_n..], stack_x, y_offset, screen_w -| master_w, screen_h, m, StackBoost.fromBalance(state.config.stack_balance));
}

/// Tile a vertical column of `windows` at a fixed x position with a fixed
/// content width. Used for both the master pane and the simple stack path.
///
/// Windows normally split the column's height evenly, EXCEPT any window
/// whose cached WM_NORMAL_HINTS max_height caps it below its fair share —
/// that window is pinned to its declared max instead, and the pixels it
/// doesn't use are folded back into the split for the rest of the column
/// (see distributeHeights). This is what keeps a short fixed-height window
/// (e.g. a picture-in-picture pane or a dialog with PMaxSize set) from
/// leaving a dead gap in its slot: its column neighbours grow to absorb
/// the space it gives up, so the column always fills `h` exactly.
///
/// When `ctx.defer_win` names a window in this column, that window's
/// configure_window call is sent after every other window in the column —
/// see LayoutCtx.defer_win for why (swap_master's one-frame-gap fix).
///
/// `boost` is always `.{}` (zero) for the master column — only the stack's
/// simple-column path ever passes a non-zero value (mod+n/mod+o). When zero,
/// this takes the exact same code path it always has (distributeHeights);
/// a non-zero boost switches to distributeStackHeightsWeighted instead, so
/// nobody who never touches mod+n/mod+o sees any change in behaviour.
fn tileColumn(
    ctx: *const layouts.LayoutCtx,
    windows: []const u32,
    x: u16,
    y_offset: u16,
    h: u16,
    inner_w: u16,
    m: utils.Margins,
    boost: StackBoost,
) void {
    const count: u16 = @intCast(windows.len);
    const avail = calcAvailableHeight(h, count, m);

    var heights_buf: [constants.Limits.MAX_TILED_WINDOWS]u16 = undefined;
    const heights = heights_buf[0..windows.len];
    if (boost.isZero()) {
        distributeHeights(ctx, windows, avail, heights);
    } else {
        distributeStackHeightsWeighted(ctx, windows, avail, boost, heights);
    }

    // distributeHeights only folds a capped window's unused pixels into
    // *other* windows in this column. If every window ends up capped
    // (e.g. a lone fixed-height window on the workspace, or a master/stack
    // pane that holds just one window), there's nothing left to absorb the
    // slack, so sum(heights) < avail. Center the resulting stack in the
    // column instead of leaving all that space stranded at the bottom.
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
/// A window whose cached max_height hint sits at or below its *current*
/// fair share is "capped": it's pinned to that max_height and removed from
/// the pool, and the pixels it left unclaimed flow back into what's left
/// for everyone else. Because pinning one window raises the fair share for
/// the rest, that can newly cap a window that wasn't capped a moment ago —
/// so this repeats pass by pass until nothing new gets pinned (standard
/// water-filling; bounded by `windows.len` passes, since each pass that
/// changes anything pins at least one window). Whatever is still uncapped
/// at the end — which is every window, in the common case with no size
/// hints — is split evenly using the same cumulative-division scheme
/// windowHeight/windowY use elsewhere, so no two adaptive siblings differ
/// by more than 1px.
fn distributeHeights(ctx: *const layouts.LayoutCtx, windows: []const u32, avail: u16, out: []u16) void {
    var capped_buf: [constants.Limits.MAX_TILED_WINDOWS]bool = undefined;
    const capped = capped_buf[0..windows.len];
    @memset(capped, false);

    var remaining_avail = avail;
    var remaining_count: u16 = @intCast(windows.len);

    var pinned_any = true;
    while (pinned_any and remaining_count > 0) {
        pinned_any = false;
        const fair_share = remaining_avail / remaining_count;
        for (windows, 0..) |win, i| {
            if (capped[i]) continue;
            const max_h = windowMaxHeight(ctx, win);
            if (max_h > 0 and max_h <= fair_share) {
                out[i] = @max(constants.MIN_WINDOW_DIM, max_h);
                capped[i] = true;
                remaining_avail = remaining_avail -| out[i];
                remaining_count -= 1;
                pinned_any = true;
            }
        }
    }

    var seen: u16 = 0;
    for (windows, 0..) |_, i| {
        if (capped[i]) continue;
        out[i] = windowHeight(seen, remaining_count, remaining_avail);
        seen += 1;
    }
}

/// Weighted counterpart of distributeHeights, used only when the stack has
/// an active top and/or bottom boost (LayoutConfig.stack_balance, derived via
/// StackBoost.fromBalance — see that struct's doc comment for the weight
/// scheme). Structurally identical to distributeHeights — same iterative
/// max_height water-filling — except the fair share used for both the
/// capping check and the final split comes from `windowWeight` instead of a
/// flat 1/n. Keep the two functions in sync if the capping algorithm above
/// ever changes.
///
/// The final split uses rounding (rather than distributeHeights' truncating
/// integer division) so fractional weights land on the right pixel; a
/// telescoping cumulative sum (`cum`/`prev_px` below) guarantees the
/// individually-rounded heights still add up to exactly `remaining_avail`.
fn distributeStackHeightsWeighted(ctx: *const layouts.LayoutCtx, windows: []const u32, avail: u16, boost: StackBoost, out: []u16) void {
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
                out[i] = @max(constants.MIN_WINDOW_DIM, max_h);
                capped[i] = true;
                remaining_avail = remaining_avail -| out[i];
                remaining_weight -= w_i;
                remaining_count -= 1;
                pinned_any = true;
            }
        }
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
        out[i] = @max(constants.MIN_WINDOW_DIM, h);
        prev_px = px;
    }
}

/// Sum of every stack slot's weight (see windowWeight) before any capping.
inline fn totalWeight(count: u16, boost: StackBoost) f32 {
    return @as(f32, @floatFromInt(count)) + boost.top + boost.bottom;
}

/// Weight of stack slot `i` out of `count`: 1.0 baseline, plus `boost.top`
/// for the first (topmost) slot and `boost.bottom` for the last (bottommost)
/// one. When `count == 1` both apply to the lone window, which is harmless —
/// a single window always claims 100% of the column regardless of weight.
inline fn windowWeight(i: u16, count: u16, boost: StackBoost) f32 {
    var w: f32 = 1.0;
    if (i == 0) w += boost.top;
    if (count > 0 and i == count - 1) w += boost.bottom;
    return w;
}

/// Cached WM_NORMAL_HINTS max_height for `win`, or 0 if it declared none.
/// 0 doubles as "unconstrained" (see layouts.SizeHints), so callers never
/// need to special-case a missing cache entry vs. a window with no hint.
inline fn windowMaxHeight(ctx: *const layouts.LayoutCtx, win: u32) u16 {
    const wd = ctx.cache.get(win) orelse return 0;
    return wd.hints.max_height;
}

/// Tile the stack pane, spilling into a column-major overflow grid when the
/// number of stack windows exceeds what fits in a single column.
///
/// `boost` (mod+n/mod+o) only affects the simple single-column path below —
/// see tileStackExtra's doc comment for why the overflow grid doesn't get it.
fn tileStack(
    ctx: *const layouts.LayoutCtx,
    windows: []const u32,
    x: u16,
    y_offset: u16,
    w: u16,
    h: u16,
    m: utils.Margins,
    boost: StackBoost,
) void {
    const stack_n: u16 = @intCast(windows.len);

    const space_per_window: u32 = constants.MIN_WINDOW_DIM + 2 * @as(u32, m.border) + @as(u32, m.gap);
    const available: u32 = @as(u32, h) -| @as(u32, m.gap);
    const max_fit: u16 = @intCast(@max(1, available / space_per_window));

    if (stack_n <= max_fit) {
        tileColumn(ctx, windows, x +| m.gap / 2, y_offset, h, layouts.shrinkClamped(w, m.gap / 2 + (m.gap + 2 * m.border)), m, boost);
        return;
    }
    tileStackExtra(ctx, windows, x, y_offset, w, h, max_fit, m);
}

/// Column-major overflow grid: row `r` holds windows at indices r, r+max_fit,
/// r+2*max_fit, … Each row's column count is ceil((stack_n - r) / max_fit).
/// Respects ctx.defer_win: the named window is sent last (see LayoutCtx.defer_win).
///
/// NOTE: overflow rows do NOT get the max_height redistribution tileColumn
/// gets above — every window in a row shares that row's height, so a single
/// capped window here would cap its whole row rather than just itself.
/// Handling that well needs a row-aware version of distributeHeights; out of
/// scope for now since overflow only kicks in once a stack has more windows
/// than fit one-per-slot.
///
/// NOTE: the mod+n/mod+o stack boost (LayoutConfig.stack_balance) is likewise not
/// applied here — "topmost"/"bottommost" stop being well-defined once the
/// stack wraps into multiple columns, so growTopSlave/growBottomSlave only
/// affect the stack while it still fits in a single column.
fn tileStackExtra(
    ctx: *const layouts.LayoutCtx,
    windows: []const u32,
    x: u16,
    y_offset: u16,
    w: u16,
    h: u16,
    max_fit: u16,
    m: utils.Margins,
) void {
    const stack_n: u16 = @intCast(windows.len);
    const row_avail = calcAvailableHeight(h, max_fit, m);

    var row: u16 = 0;
    while (row < max_fit) : (row += 1) {
        const cols_in_row: u16 = (stack_n - row + max_fit - 1) / max_fit;

        const gaps_in_row = m.gap / 2 +| m.gap *| cols_in_row;
        const row_total_w = if (w > gaps_in_row) w - gaps_in_row else cols_in_row * constants.MIN_WINDOW_DIM;
        const col_w = row_total_w / cols_in_row;
        const col_inner_w = layouts.shrinkClamped(col_w, 2 * m.border);

        const y_pos = windowY(row, max_fit, row_avail, y_offset, m);
        const row_h = windowHeight(row, max_fit, row_avail);

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
/// Falls back to count * MIN_WINDOW_DIM when margins exceed total_h.
inline fn calcAvailableHeight(total_h: u16, count: u16, m: utils.Margins) u16 {
    const overhead = m.gap *| (count + 1) +| m.border *| 2 *| count;
    return if (total_h > overhead) total_h - overhead else count * constants.MIN_WINDOW_DIM;
}

/// Height of window `i` out of `count`, distributing `available` pixels via
/// cumulative integer division. No two siblings differ by more than 1 px.
inline fn windowHeight(i: u16, count: u16, available: u16) u16 {
    const hi: u32 = (@as(u32, i) + 1) * @as(u32, available) / @as(u32, count);
    const lo: u32 = @as(u32, i) * @as(u32, available) / @as(u32, count);
    return @max(constants.MIN_WINDOW_DIM, @as(u16, @intCast(hi - lo)));
}

/// Y position of window `i`, derived from the same cumulative formula so that
/// preceding windows' heights (which may vary by 1 px) are accounted for.
inline fn windowY(i: u16, count: u16, available: u16, y_offset: u16, m: utils.Margins) u16 {
    const cum: u32 = @as(u32, i) * @as(u32, available) / @as(u32, count);
    return y_offset +| m.gap +| @as(u16, @intCast(cum)) +| i *| (m.gap +| 2 *| m.border);
}