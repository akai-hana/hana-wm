//! Headless tests for utils.IdMap, the fixed-capacity window-ID hash map that
//! backs the ICCCM focus-property cache.
//!
//! The map's probing/tombstone/compaction paths are easy to get subtly wrong
//! (an infinite probe, a lost entry after a delete-heavy workload), so these
//! pin the observable contract: get/put/remove, overwrite, wrap-around probing,
//! capacity saturation, tombstone reclamation, and clear.

const std = @import("std");
const testing = std.testing;

const IdMap = @import("idmap").IdMap;

test "IdMap: put/get/overwrite/remove round-trip" {
    var m = IdMap(u32, 8){};
    try testing.expect(m.get(1) == null);
    try testing.expect(m.put(1, 11));
    try testing.expect(m.put(2, 22));
    try testing.expectEqual(@as(?u32, 11), m.get(1));
    try testing.expectEqual(@as(?u32, 22), m.get(2));
    try testing.expect(m.contains(1));

    try testing.expect(m.put(1, 111));
    try testing.expectEqual(@as(?u32, 111), m.get(1));
    try testing.expectEqual(@as(usize, 2), m.count());

    try testing.expect(m.remove(1));
    try testing.expect(!m.contains(1));
    try testing.expect(m.get(1) == null);
    try testing.expectEqual(@as(?u32, 22), m.get(2));
    try testing.expectEqual(@as(usize, 1), m.count());

    try testing.expect(!m.remove(999));
}

test "IdMap: distinct keys never collide into one another" {
    var m = IdMap(u32, 64){};
    var id: u32 = 1;
    while (id <= 64) : (id += 1) try testing.expect(m.put(id, id * 3));
    id = 1;
    while (id <= 64) : (id += 1) try testing.expectEqual(@as(?u32, id * 3), m.get(id));
    try testing.expectEqual(@as(usize, 64), m.count());
    // The 65th live entry is refused and leaves the map untouched.
    try testing.expect(!m.put(65, 0));
    try testing.expect(!m.contains(65));
    try testing.expectEqual(@as(usize, 64), m.count());
}

test "IdMap: tombstones are reclaimed and do not lose live entries" {
    var m = IdMap(u32, 16){};
    // Churn the same key far past the slot count: every insert after a remove
    // must reuse a tombstone (or trigger an in-place rehash), never grow len.
    var round: u32 = 0;
    while (round < 200) : (round += 1) {
        try testing.expect(m.put(0xABC, round));
        try testing.expectEqual(@as(?u32, round), m.get(0xABC));
        try testing.expect(m.remove(0xABC));
    }
    try testing.expectEqual(@as(usize, 0), m.count());

    // A mixed live/tombstone mix stays fully reachable.
    for (1..16) |k| try testing.expect(m.put(@intCast(k), @intCast(k)));
    for (1..16) |k| try testing.expect(m.remove(@intCast(k)));
    for (1..16) |k| try testing.expect(m.put(@intCast(k), @intCast(k * 10)));
    for (1..16) |k| try testing.expectEqual(@as(?u32, @intCast(k * 10)), m.get(@intCast(k)));
}

test "IdMap: clear drops live entries and tombstones" {
    var m = IdMap(u32, 8){};
    try testing.expect(m.put(7, 70));
    try testing.expect(m.remove(7));
    try testing.expect(m.put(8, 80));
    m.clear();
    try testing.expectEqual(@as(usize, 0), m.count());
    try testing.expect(m.get(8) == null);
    try testing.expect(m.put(9, 90));
    try testing.expectEqual(@as(?u32, 90), m.get(9));
}
