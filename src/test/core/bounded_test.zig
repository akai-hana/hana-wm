//! Headless tests for the shared bounded collections (`core/pure/bounded`).
//!
//! `BoundedList` backs the window caches, minimize records, and the spawn
//! pending table, so its cap/evict/scan semantics are load-bearing but were
//! previously only exercised indirectly through those call sites. These tests
//! pin the contract: full-capped append, linear find, both removal flavors,
//! insert clamping, and the id-keyed remove helpers.

const std = @import("std");
const bounded = @import("bounded");

const Row = struct {
    win: u32,
    value: u8,
};

test "bounded: append caps at capacity and is a no-op when full" {
    var list = bounded.BoundedList(u32, 3){};
    try std.testing.expectEqual(@as(usize, 0), list.len);

    try std.testing.expect(list.append(10));
    try std.testing.expect(list.append(20));
    try std.testing.expect(list.append(30));
    try std.testing.expectEqual(@as(usize, 3), list.len);

    try std.testing.expect(!list.append(40));
    try std.testing.expectEqual(@as(usize, 3), list.len);
    try std.testing.expectEqualSlices(u32, &.{ 10, 20, 30 }, list.constSlice());
}

test "bounded: indexOfScalar finds by value, indexOfByIdField by key field" {
    var scalars = bounded.BoundedList(u32, 4){};
    _ = scalars.append(7);
    _ = scalars.append(9);
    try std.testing.expectEqual(@as(?usize, 1), scalars.indexOfScalar(9));
    try std.testing.expectEqual(@as(?usize, null), scalars.indexOfScalar(8));

    var rows = bounded.BoundedList(Row, 4){};
    _ = rows.append(.{ .win = 1, .value = 11 });
    _ = rows.append(.{ .win = 2, .value = 22 });
    try std.testing.expectEqual(@as(?usize, 1), rows.indexOfByIdField(.win, 2));
    try std.testing.expectEqual(@as(?usize, null), rows.indexOfByIdField(.win, 3));
}

test "bounded: swapRemove drops order, orderedRemove preserves it" {
    var list = bounded.BoundedList(u32, 4){};
    _ = list.append(1);
    _ = list.append(2);
    _ = list.append(3);
    _ = list.append(4);

    list.swapRemove(1);
    try std.testing.expectEqualSlices(u32, &.{ 1, 4, 3 }, list.constSlice());

    list.orderedRemove(0);
    try std.testing.expectEqualSlices(u32, &.{ 4, 3 }, list.constSlice());
}

test "bounded: insert clamps index and refuses when full" {
    var list = bounded.BoundedList(u32, 3){};
    _ = list.append(10);
    try std.testing.expect(list.insert(0, 5));
    try std.testing.expectEqualSlices(u32, &.{ 5, 10 }, list.constSlice());

    try std.testing.expect(list.insert(999, 20));
    try std.testing.expectEqualSlices(u32, &.{ 5, 10, 20 }, list.constSlice());

    try std.testing.expect(!list.insert(0, 1));
    try std.testing.expectEqualSlices(u32, &.{ 5, 10, 20 }, list.constSlice());
}

test "bounded: removeById acts on the key field" {
    var rows = bounded.BoundedList(Row, 4){};
    _ = rows.append(.{ .win = 1, .value = 1 });
    _ = rows.append(.{ .win = 2, .value = 2 });
    _ = rows.append(.{ .win = 3, .value = 3 });

    try std.testing.expect(rows.removeById(.win, 2));
    try std.testing.expect(!rows.removeById(.win, 2));
    try std.testing.expectEqual(@as(usize, 2), rows.len);
    try std.testing.expectEqual(@as(u32, 1), rows.constSlice()[0].win);
    try std.testing.expectEqual(@as(u32, 3), rows.constSlice()[1].win);
}
