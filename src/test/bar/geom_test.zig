//! Geometry kernel tests for the title segment's split-view tiling: the
//! equal-width partition, its inverse, and the click hit-test that rides both.
//!
//! `segmentBounds` and `segmentIndexOfX` are the load-bearing pair the module
//! doc calls out: the draw and the hit-test must agree on which pixels belong
//! to which window, or a click selects a neighbour. These tests pin that
//! agreement as properties over many (width, count) shapes rather than a few
//! golden numbers.

// build-gate: seg_title

const std = @import("std");
const testing = std.testing;

const geom = @import("geom");
const vocab = @import("vocab");

const TitleEntry = vocab.TitleEntry;
const TitleSnapshot = vocab.TitleSnapshot;

fn snapOf(
    ms: *const std.AutoHashMapUnmanaged(u32, void),
    entries: []const TitleEntry,
) TitleSnapshot {
    return .{
        .focused_window = null,
        .focused_title = "",
        .minimized_title = "",
        .entries = entries,
        .minimized_set = ms,
    };
}

test "geom: segmentBounds partitions [0, total_width) exactly" {
    const widths = [_]u16{ 1, 2, 7, 99, 100, 333, 800, 1000 };
    for (widths) |w| {
        for (1..9) |n_usize| {
            const n: u32 = @intCast(n_usize);
            var sum: u32 = 0;
            var prev_end: u16 = 0;
            for (0..n_usize) |i| {
                const b = geom.segmentBounds(w, i, n);
                // Contiguous: each tile starts exactly where the last ended.
                try testing.expectEqual(prev_end, b.x);
                prev_end = b.x + b.w;
                sum += b.w;
                // No zero-width tile when the row is at least as wide as the
                // tile count (narrower rows must round some tiles to zero).
                if (w >= n) try testing.expect(b.w > 0);
            }
            // The whole row, no fractional residue.
            try testing.expectEqual(@as(u32, w), sum);
        }
    }
}

test "geom: segmentIndexOfX inverts segmentBounds" {
    const widths = [_]u16{ 7, 99, 100, 333, 800 };
    for (widths) |w| {
        for (1..9) |n_usize| {
            const n: u32 = @intCast(n_usize);
            for (0..n_usize) |i| {
                const b = geom.segmentBounds(w, i, n);
                var x: u16 = b.x;
                while (x < b.x + b.w) : (x += 1) {
                    try testing.expectEqual(i, geom.segmentIndexOfX(w, x, n));
                }
            }
            // A click past the right edge clamps into the last tile rather
            // than indexing out of the array.
            try testing.expectEqual(n_usize - 1, geom.segmentIndexOfX(w, w, n));
        }
    }
}

test "geom: hitTest resolves nothing without entries" {
    var ms: std.AutoHashMapUnmanaged(u32, void) = .{};
    defer ms.deinit(testing.allocator);

    const s = snapOf(&ms, &.{});
    try testing.expect(geom.hitTest(s, 400, 0) == null);
}

test "geom: a single window owns the whole slot at any offset" {
    var ms: std.AutoHashMapUnmanaged(u32, void) = .{};
    defer ms.deinit(testing.allocator);

    const entries = [_]TitleEntry{
        .{ .window = 41, .title = "solo", .geom = .{ .x = 0, .y = 0, .width = 400, .height = 300 } },
    };
    const s = snapOf(&ms, &entries);

    const t = geom.hitTest(s, 0, 123).?;
    try testing.expectEqual(@as(u32, 41), t.window);
    try testing.expect(!t.minimized);

    // The minimized bit is the same set lookup on the single-window path.
    try ms.put(testing.allocator, 41, {});
    const t2 = geom.hitTest(s, 50, 0).?;
    try testing.expectEqual(@as(u32, 41), t2.window);
    try testing.expect(t2.minimized);
}

test "geom: split-view clicks land in the tile of the sorted window" {
    var ms: std.AutoHashMapUnmanaged(u32, void) = .{};
    defer ms.deinit(testing.allocator);

    // Frame order is scrambled on purpose: the sort order (by x) decides the
    // tiles, not the entry order. Row is 100px over three windows, so the
    // tiles are [0,33) [33,66) [66,100).
    const entries = [_]TitleEntry{
        .{ .window = 30, .title = "c", .geom = .{ .x = 90, .y = 0, .width = 60, .height = 300 } },
        .{ .window = 10, .title = "a", .geom = .{ .x = 10, .y = 0, .width = 60, .height = 300 } },
        .{ .window = 20, .title = "b", .geom = .{ .x = 50, .y = 0, .width = 60, .height = 300 } },
    };
    const s = snapOf(&ms, &entries);

    try testing.expectEqual(@as(u32, 10), geom.hitTest(s, 100, 0).?.window);
    try testing.expectEqual(@as(u32, 10), geom.hitTest(s, 100, 32).?.window);
    try testing.expectEqual(@as(u32, 20), geom.hitTest(s, 100, 33).?.window);
    try testing.expectEqual(@as(u32, 20), geom.hitTest(s, 100, 65).?.window);
    try testing.expectEqual(@as(u32, 30), geom.hitTest(s, 100, 66).?.window);
    try testing.expectEqual(@as(u32, 30), geom.hitTest(s, 100, 99).?.window);

    // Multi-window with a zero-width reservation refuses rather than
    // dividing by zero.
    try testing.expect(geom.hitTest(s, 0, 0) == null);

    // Minimized windows sort to the end of the split view and report the bit.
    try ms.put(testing.allocator, 20, {});
    try testing.expectEqual(@as(u32, 10), geom.hitTest(s, 100, 0).?.window);
    try testing.expectEqual(@as(u32, 30), geom.hitTest(s, 100, 33).?.window);
    const t = geom.hitTest(s, 100, 66).?;
    try testing.expectEqual(@as(u32, 20), t.window);
    try testing.expect(t.minimized);
}
