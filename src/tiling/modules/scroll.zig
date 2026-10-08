//! Scroll tiling layout.
//! Places windows in half-screen slots along a scrollable horizontal strip.

const model = @import("model");
const tiling = @import("tiling");

// GROW DUTY (optional): on window grow, callers may pre-clamp viewport_offset
// to maxOffset(n, slotWidth(wa.w), wa.w) and update viewport_prev_count
// (see pipeline.preReconcileDuties); compute clamps internally either way.
// slotWidth/maxOffset feed actions too.

/// Pixel width of one scroll slot: exactly half the screen width. Single
/// source of truth; maxOffset and compute derive their geometry from it.
pub fn slotWidth(screen_w: u16) i32 {
    return @intCast(screen_w / 2);
}

/// Maximum scroll offset: reached when the last of `n` windows' right edge
/// is flush with the screen's right edge. Zero (nothing to scroll) when the
/// strip is no wider than the screen.
pub fn maxOffset(n: usize, slot_w: i32, screen_w: u16) i32 {
    const n_i32: i32 = @intCast(n);
    const sw_i32: i32 = @intCast(screen_w);
    return @max(0, n_i32 * slot_w - sw_i32);
}

/// Compute scroll layout: half-screen slots, full gap at screen edges and
/// half-gap at interior boundaries. Off-viewport slots hidden; offset clamped.
fn compute(v: *const tiling.View, out: *tiling.List) void {
    const ctx = tiling.LayoutCtx.init(v, out);
    const windows = v.order;

    const m = ctx.m;

    const screen_w = v.workarea.width;
    const screen_h = v.workarea.height;

    const slot_w: i32 = slotWidth(screen_w);

    const sw_i32: i32 = @intCast(screen_w);

    // Clamped internally (self-contained); the optional pre-clamp grow duty is
    // described at the module header.
    const scroll: i32 = clampOffset(v.params.viewport_offset, windows.len, screen_w);

    // Border subtracted here (once); emitView's applyHints never touches it.
    const content_h: u16 = tiling.shrinkClamped(screen_h, tiling.totalInset(m.gap, m), ctx.min_dim);
    const win_y: i32 = @as(i32, tiling.waY(v) +| m.gap);

    // Full gap at screen edges; half-gap at interior slot boundaries so that
    // adjacent windows together share exactly one full gap.
    const gap_i32: i32 = @intCast(m.gap);
    const gap_half: i32 = @intCast(tiling.seamGap(m));
    const border2: i32 = @as(i32, model.doubledBorder(m));

    for (windows, 0..) |win, i| {
        const col: i32 = @intCast(i);

        const slot_left: i32 = col * slot_w - scroll;

        // <=/>= rather than </> to handle off-by-one from odd-width division.
        const left_inset: i32 = if (slot_left <= 0) gap_i32 else gap_half;
        const right_inset: i32 = if (slot_left + slot_w >= sw_i32) gap_i32 else gap_half;

        const x: i32 = slot_left + left_inset;
        const avail: i32 = slot_w - left_inset - right_inset - border2;
        // Clamp the width to the slot so a min_dim floor can't flare a window
        // over its neighbor; floor at 1 so a degenerate slot stays positive.
        const content_w: u16 = @intCast(@max(avail, 1));

        // The visibility cutoff uses the EMITTED width, not the stale slot
        // width: a boundary slot is parked using exactly what would be on
        // screen, so a slot that clipped to empty is caught off-viewport here
        // instead of mapping a sliver of window past the edge.
        //
        // Clip the emitted rect against the screen (workarea-relative) bounds:
        // a slot straddling an edge emits only its visible slice rather than a
        // straddling rect whose one side maps an offscreen sliver.
        var clipped_x = x;
        var clipped_w: i32 = @intCast(content_w);
        if (clipped_x < 0) {
            clipped_w += clipped_x; // the off-left part was off-window
            clipped_x = 0;
        }
        if (clipped_x + clipped_w > sw_i32) clipped_w = sw_i32 - clipped_x;
        if (clipped_w <= 0) {
            tiling.emitHidden(out, win);
            continue;
        }
        tiling.emitRect(v, out, win, clipped_x + v.workarea.x, win_y, @intCast(clipped_w), content_h);
    }
}

/// THE scroll clamp (14.7): a viewport offset is always in [0, max_off] for
/// the CURRENT window count and slot width. Two sites need that and they used
/// to spell it differently -- `@max(0, @min(...))` in the layout,
/// `std.math.clamp` in the pre-reconcile grow duty -- so tightening one bound
/// (a different max_off, a signed-vs-unsigned edge) would silently not apply
/// to the other, and the two answers disagree by exactly the window that
/// scrolls the furthest.
fn clampOffset(offset: i32, n: usize, wa_width: u16) i32 {
    const slot_w = slotWidth(wa_width);
    const max_off = maxOffset(n, slot_w, wa_width);
    return @max(0, @min(offset, max_off));
}

/// Pre-reconcile duty (pure): snap right when the visible count grew
/// (spawn/restore/tag-add), then clamp to content. Takes the workspace's
/// layout params BY VALUE; the pipeline choke point applies the returned
/// delta (value-in, value-out -- no mutable pointer into the model).
fn preReconcileHook(p: model.LayoutParams, n: usize, wa_width: u16) model.LayoutParams {
    const slot_w = slotWidth(wa_width);
    const max_off = maxOffset(n, slot_w, wa_width);
    var next = p;
    if (n > next.viewport_prev_count) next.viewport_offset = max_off;
    next.viewport_offset = clampOffset(next.viewport_offset, n, wa_width);
    next.viewport_prev_count = @intCast(n);
    return next;
}

/// This layout's registry contribution: metadata plus the dispatch hooks.
pub const module = tiling.layoutModule("scroll", "[|]", compute, &.{}, .{
    .slotWidth = slotWidth,
    .maxOffset = maxOffset,
    .preReconcile = preReconcileHook,
});
