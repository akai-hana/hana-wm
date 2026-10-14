//! The center-row layout math (bar/center_row.zig), lifted out of
//! bar.zig so the budget/share derivation is unit-testable without a
//! live bar, a DrawContext, or Pango -- the metrics.zig pattern: pure
//! policy over injected seams.

// (28.6) Declared here, next to the imports that make it necessary,
// rather than in a build.zig table that had to be kept in agreement
// with them by hand.
// build-gate: bar

const std = @import("std");
const testing = std.testing;

const center_row = @import("center_row");
const segmod = @import("segment");
const types = @import("types");

const bar_mods = @import("bar_modules").modules;

/// The registry's self-ticking set, resolved at comptime exactly as
/// the bar resolves its role sets (the capability query is
/// comptime-only: it concatenates into a comptime-known slice).
const self_ticking_ids = segmod.findAllByCapability(&bar_mods, .self_ticking);

test "centerShare splits evenly, leftmost slots carry the remainder" {
    // 100 across 3: 34/33/33 -- the leading slot carries the extra
    // pixel, so the shares sum to exactly 100 with no residue.
    try testing.expectEqual(@as(u16, 34), center_row.centerShare(100, 3, 0));
    try testing.expectEqual(@as(u16, 33), center_row.centerShare(100, 3, 1));
    try testing.expectEqual(@as(u16, 33), center_row.centerShare(100, 3, 2));
    // Exact division: no remainder to distribute.
    try testing.expectEqual(@as(u16, 25), center_row.centerShare(100, 4, 3));
    // A single slot takes the whole budget.
    try testing.expectEqual(@as(u16, 100), center_row.centerShare(100, 1, 0));
    // A zero budget splits to zero, whatever the count.
    try testing.expectEqual(@as(u16, 0), center_row.centerShare(0, 3, 2));
}

fn centerLayout(segments: []const []const u8) !types.BarLayout {
    var lay = types.BarLayout{ .position = .center, .segments = .empty };
    for (segments) |s| try lay.segments.append(testing.allocator, s);
    return lay;
}

test "centerRowBudget is empty for non-center rows" {
    var lay = types.BarLayout{ .position = .left, .segments = .empty };
    defer lay.segments.deinit(testing.allocator);
    const frame = segmod.Frame{};
    const budget = center_row.centerRowBudget(lay, 1000, 10, &frame, 0);
    try testing.expectEqual(@as(u16, 0), budget.remaining);
    try testing.expectEqual(@as(u16, 0), budget.center_count);
}

test "centerRowBudget reserves a trailing gap per non-center segment" {
    // Unknown names carry no natural width (no hook), so the only
    // reservation is the trailing gap: the derivation stays
    // registry-independent this way. The clamped budget is
    // avail - spacing (300 - 10 = 290, above the 100-px floor).
    const frame = segmod.Frame{};
    var lay = try centerLayout(&.{ "nosuch_a", "nosuch_b" });
    defer lay.segments.deinit(testing.allocator);
    const budget = center_row.centerRowBudget(lay, 300, 10, &frame, 0);
    try testing.expectEqual(@as(u16, 0), budget.center_count);
    // claim = 2 gaps = 20, off the 290-px clamped budget.
    try testing.expectEqual(@as(u16, 290 - 20), budget.remaining);
}

test "centerRowBudget counts a center slot without measuring it" {
    // "title" is the registry's center-slot segment: it is counted,
    // not reserved, so the whole clamped budget remains for the share.
    const frame = segmod.Frame{};
    var lay = try centerLayout(&.{"title"});
    defer lay.segments.deinit(testing.allocator);
    const budget = center_row.centerRowBudget(lay, 300, 10, &frame, 0);
    try testing.expectEqual(@as(u16, 1), budget.center_count);
    try testing.expectEqual(@as(u16, 290), budget.remaining);
}

test "centerRowBudget floors a thin budget at the title minimum" {
    // avail - spacing (150 - 100 = 50) falls below the 100-px
    // floor, so the center slots split the floor instead -- a center
    // row never collapses to a sliver when one gap eats it.
    const frame = segmod.Frame{};
    var lay = try centerLayout(&.{"title"});
    defer lay.segments.deinit(testing.allocator);
    const budget = center_row.centerRowBudget(lay, 150, 100, &frame, 0);
    try testing.expectEqual(@as(u16, 1), budget.center_count);
    try testing.expectEqual(@as(u16, segmod.title_min_width), budget.remaining);
    // Below the floor entirely the ceiling wins: the budget is the
    // whole (tiny) row, not a phantom reservation off-screen.
    const tiny = center_row.centerRowBudget(lay, 50, 10, &frame, 0);
    try testing.expectEqual(@as(u16, 50), tiny.remaining);
}

fn stubWidth(_: void, text: []const u8, props: types.SegmentProps) u16 {
    // Props are part of the injected probe's contract: a bold segment must
    // measure wider than a plain one, so the expected walk below fails if
    // mergedClockWidth ever stops threading each module's OWN props through.
    return @intCast(text.len + (if (props.bold) @as(usize, 500) else 0));
}

test "mergedClockWidth is the max self-ticker span plus double padding" {
    // The string-width probe is injected, so the derivation runs
    // without Pango. Expected is the same walk the derivation performs
    // over the registry's own self-ticking set (a segment with no
    // measureString hook contributes nothing), which pins the max
    // semantics, the 2x padding multiplier, and the per-module props
    // threading (bold only the clock, so a shared-default regression
    // measures the +500 away).
    var config = types.BarConfig{};
    try config.segment_props.put(testing.allocator, try testing.allocator.dupe(u8, "clock"), .{ .bold = true });
    defer types.freeSegmentMap(types.SegmentProps, &config.segment_props, testing.allocator);
    const height: u16 = 100;
    const padding = config.scaledSegmentPadding(height);
    var expected: u16 = 0;
    for (self_ticking_ids) |cid| {
        if (bar_mods[cid].measureString) |ms|
            expected = @max(expected, stubWidth({}, ms(), config.segmentProps(bar_mods[cid].name)) + 2 * padding);
    }
    try testing.expectEqual(expected, center_row.mergedClockWidth({}, config, height, stubWidth));
}
