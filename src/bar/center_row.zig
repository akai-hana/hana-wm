//! Center-row layout math: the budget and share derivation for the
//! bar's center row, plus the merged clock width that sizes it.
//!
//! The policy is pure over injected seams, following the metrics.zig
//! pattern: the segment registry is resolved here (comptime, from the
//! generated `bar_modules`), the clock budget arrives as a value, and
//! the one Pango-dependent input (a string's pixel width) is a probe
//! parameter -- so every derivation is unit-testable without a
//! DrawContext or a live bar.

const types = @import("types");
const segmod = @import("segment");

const bar_mods = @import("bar_modules").modules;

/// Even split of `remaining` among `count` center slots, distributed
/// left to right in config order: every slot gets `remaining / count`,
/// and the leading `remaining % count` slots (the leftmost) carry one
/// extra pixel, so the shares sum exactly to `remaining` with no
/// fractional residue.
pub fn centerShare(remaining: u16, count: u16, idx: u16) u16 {
    const base = @divFloor(remaining, count);
    const extra: u16 = @intCast(@rem(remaining, count));
    return if (idx < extra) base + 1 else base;
}

/// Center-row budget derivation: reserves a center layout's own
/// non-center segments (their widths plus trailing gaps) out of
/// `avail`, returning what remains for the center-slot segments and
/// how many slots share it. For a non-center layout the budget is
/// empty (`.left`/`.right` rows carry no center slots).
///
/// The host's segment-width probe is replaced by the two values it
/// was a closure over -- the frame and the merged clock width -- so
/// the derivation has no dependency on the bar's State.
pub fn centerRowBudget(
    lay: types.BarLayout,
    avail: u16,
    scaled_spacing: u16,
    frame: *const segmod.Frame,
    clock_width: u16,
) struct { remaining: u16, center_count: u16 } {
    var remaining: u16 = 0;
    var center_count: u16 = 0;
    if (lay.position != .center) return .{ .remaining = remaining, .center_count = center_count };
    // Reserve the layout's own non-center segments (their widths plus
    // trailing gaps) before the center-slot budget, so a center row
    // that also carries a clock or workspaces slot can't spill into
    // the right cluster.
    const clamped = @min(
        @max(segmod.title_min_width, avail -| scaled_spacing),
        avail,
    );
    var claim: u16 = 0;
    for (lay.segments.items) |s| {
        // One name -> id resolution per segment for the whole budget pass.
        const id = segmod.segId(s);
        if (segmod.isRole(id, segmod.center_slot_ids)) {
            center_count += 1;
            continue;
        }
        claim +|= segmod.naturalWidthOf(id, frame, clock_width);
        claim +|= scaled_spacing;
    }
    remaining = clamped -| claim;
    return .{ .remaining = remaining, .center_count = center_count };
}

/// The bar-wide merged display width of the self-ticking segments:
/// the max across them of each one's width probe plus its segment
/// padding (a segment with no probe contributes 0). The single
/// definition of the "clock budget" handed to every naturalWidth hook
/// as its fallback, so a fresh bar (State.init) and a post-mode-cycle
/// re-derivation (adoptFreshClockWidth) can never disagree.
///
/// `measure` is the host's string-width probe WITH the segment's
/// `[bar.properties]` styling applied (a DrawContext's
/// measureTextWidthStyled), injected so this derivation needs no
/// Pango. Styled, because the draw measures the same probe styled:
/// an unstyled budget reserves a narrower slot than a bold/italic
/// clock paints, and the row overlaps until an unrelated full
/// redraw. For plain (default) props the two probes are identical,
/// so styled costs nothing on an unstyled bar.
pub fn mergedClockWidth(
    ctx: anytype,
    config: types.BarConfig,
    height: u16,
    measure: *const fn (@TypeOf(ctx), []const u8, types.SegmentProps) u16,
) u16 {
    var width: u16 = 0;
    // Comptime guard: with no self-ticking segment compiled in the
    // loop below is dropped whole, so its registry index is never
    // analyzed against the empty registry.
    const self_ticking_ids = segmod.self_ticking_ids;
    if (comptime self_ticking_ids.len == 0) return width;
    for (self_ticking_ids) |cid| {
        if (bar_mods[cid].measureString) |ms|
            width = @max(width, measure(ctx, ms(), config.segmentProps(bar_mods[cid].name)) +
                2 * config.scaledSegmentPadding(height));
    }
    return width;
}
