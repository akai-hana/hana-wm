//! Pango text-width cache (REFACTOR-PLAN P2-60): `FontBook` serves repeated
//! measures of the same (text, style bits) from a bounded content-keyed map
//! instead of building a Pango layout per call, and a font swap drops every
//! cached width.
//!
//! Headless over an image surface (the font-probe precedent): Pango needs no
//! X display, so these tests need no connection anywhere.
//!
//! The observable is `FontBook.measure_misses`, the count of real Pango
//! measures -- exactly the thing the "static labels measure once per config"
//! acceptance names. A hit must not bump it; a font reload must.
//!
// build-gate: bar

const std = @import("std");
const testing = std.testing;

const drawing = @import("drawing");
const bar_config = @import("bar_config");

test "P2-60: repeated measure of one label is one Pango measure" {
    const dc = try drawing.DrawContext.initImage(testing.allocator, 64, 16, 96.0);
    defer dc.deinit();

    // The clock-style static label: the same string measured every frame.
    const label = "12:34";
    const first = dc.fonts.measureTextWidth(label);
    try testing.expectEqual(@as(u32, 1), dc.fonts.measure_misses);

    // A second and third measure of the identical string must be cache hits:
    // same width back, and no further Pango measure.
    for (0..2) |_| {
        try testing.expectEqual(first, dc.fonts.measureTextWidth(label));
    }
    try testing.expectEqual(@as(u32, 1), dc.fonts.measure_misses);
}

test "P2-60: styled and unstyled measures of one string are distinct keys" {
    const dc = try drawing.DrawContext.initImage(testing.allocator, 64, 16, 96.0);
    defer dc.deinit();

    const label = "dev";
    _ = dc.fonts.measureTextWidth(label);
    try testing.expectEqual(@as(u32, 1), dc.fonts.measure_misses);

    // Same text, bold: a fresh key, so a fresh measure -- the styled width can
    // never be served from the unstyled entry.
    _ = dc.fonts.measureTextWidthStyled(label, .{ .bold = true });
    try testing.expectEqual(@as(u32, 2), dc.fonts.measure_misses);

    // Re-measuring the bold form is now a hit on its own entry.
    _ = dc.fonts.measureTextWidthStyled(label, .{ .bold = true });
    try testing.expectEqual(@as(u32, 2), dc.fonts.measure_misses);

    // And the unstyled form still hits its original entry.
    _ = dc.fonts.measureTextWidth(label);
    try testing.expectEqual(@as(u32, 2), dc.fonts.measure_misses);
}

test "P2-60: font reload invalidates every cached width" {
    const dc = try drawing.DrawContext.initImage(testing.allocator, 64, 16, 96.0);
    defer dc.deinit();

    const label = "12:34";
    _ = dc.fonts.measureTextWidth(label);
    try testing.expectEqual(@as(u32, 1), dc.fonts.measure_misses);

    // A font swap changes the description every width was derived from, so the
    // next measure of the same string must go back to Pango.
    try dc.fonts.loadFonts(&[_][]const u8{"Sans"});
    _ = dc.fonts.measureTextWidth(label);
    try testing.expectEqual(@as(u32, 2), dc.fonts.measure_misses);
}

test "P2-60: distinct strings fill the cache without cross-talk" {
    const dc = try drawing.DrawContext.initImage(testing.allocator, 64, 16, 96.0);
    defer dc.deinit();

    const strings = [_][]const u8{ "a", "ab", "abc", "workspace-name" };
    for (strings) |s| _ = dc.fonts.measureTextWidth(s);
    try testing.expectEqual(@as(u32, strings.len), dc.fonts.measure_misses);

    // Every entry is independently retrievable.
    for (strings) |_| _ = dc.fonts.measureTextWidth(strings[0]);
    try testing.expectEqual(@as(u32, strings.len), dc.fonts.measure_misses);
}

test "P2-64: a segment's configured size is its own cache key" {
    const dc = try drawing.DrawContext.initImage(testing.allocator, 64, 16, 96.0);
    defer dc.deinit();

    const label = "mw";
    var at10 = bar_config.SegmentProps{};
    at10.size = 10;
    var at11 = bar_config.SegmentProps{};
    at11.size = 11;

    _ = dc.fonts.measureTextWidthStyled(label, at10);
    try testing.expectEqual(@as(u32, 1), dc.fonts.measure_misses);

    // Same text, different configured size: a different key, a real measure.
    _ = dc.fonts.measureTextWidthStyled(label, at11);
    try testing.expectEqual(@as(u32, 2), dc.fonts.measure_misses);

    // Back to the first size: served from its own entry.
    _ = dc.fonts.measureTextWidthStyled(label, at10);
    try testing.expectEqual(@as(u32, 2), dc.fonts.measure_misses);

    // The unsized measure of the same text is distinct from both.
    _ = dc.fonts.measureTextWidth(label);
    try testing.expectEqual(@as(u32, 3), dc.fonts.measure_misses);
}
