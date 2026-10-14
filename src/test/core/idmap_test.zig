//! Headless tests for idmap.IdMap, the fixed-capacity window-ID hash map that
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

test "IdMap: filled-to-capacity churn never strands a tombstone that hangs find" {
    var m = IdMap(u32, 7){};
    // slots = 8, so capacity 7 leaves exactly one empty slot. Filling,
    // removing three (3 tombstones), and re-inserting three FRESH ids used to
    // be able to land the insert on the surviving empty slot while a tombstone
    // remained: len + tombstones == slots with NO empty slot, so the next
    // get()/contains() spun forever. The post-insert rehash must always
    // restore an empty slot.
    var next: u32 = 1;
    var round: u32 = 0;
    while (round < 50) : (round += 1) {
        var live: [7]u32 = undefined;
        for (&live) |*w| {
            w.* = next;
            next += 1;
            try testing.expect(m.put(w.*, w.*));
        }
        try testing.expect(!m.put(next, 0)); // at capacity: report full
        next += 1;
        try testing.expect(m.remove(live[0]));
        try testing.expect(m.remove(live[2]));
        try testing.expect(m.remove(live[4]));
        try testing.expect(m.put(next, next));
        next += 1;
        try testing.expect(m.put(next, next));
        next += 1;
        try testing.expect(m.put(next, next));
        next += 1;
        // Every absent probe must terminate, and live entries stay reachable.
        try testing.expect(m.get(0xDEAD_0000 + round) == null);
        try testing.expect(!m.contains(0xDEAD_0000 + round));
        try testing.expectEqual(@as(?u32, live[1]), m.get(live[1]));
        try testing.expectEqual(@as(?u32, live[3]), m.get(live[3]));
        try testing.expectEqual(@as(?u32, live[5]), m.get(live[5]));
        try testing.expectEqual(@as(?u32, next - 1), m.get(next - 1));
        m.clear();
    }
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

test "idmap iterator visits every live entry" {
    var m = IdMap(u32, 8){};
    // Scattered ids: put hashes them across the table, so a forward scan of
    // keys[0..len] would read unoccupied slots and stop early.
    const keys = [_]u32{ 101, 202, 303, 404, 505 };
    for (keys, 0..) |k, v| try std.testing.expect(m.put(k, @as(u32, @intCast(v))));

    var seen: std.AutoHashMap(u32, u32) = .init(std.testing.allocator);
    defer seen.deinit();
    var it = m.iterator();
    while (it.next()) |item| try seen.put(item.key, item.val.*);

    try std.testing.expectEqual(keys.len, seen.count());
    for (keys, 0..) |k, v| try std.testing.expectEqual(@as(u32, @intCast(v)), seen.get(k).?);
}
