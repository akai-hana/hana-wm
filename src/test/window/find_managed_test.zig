//! P1-36: bounding tests for the child->toplevel walk on the dispatch path.
//!
//! `findManagedWindow` runs on every EnterNotify for Electron/Qt/GTK clients
//! and pays one BLOCKING xcb_query_tree round trip per tree level (2-3 for
//! Electron). The bound that keeps hover/dispatch latency sane is therefore a
//! contract, not an accident of the loop: at most `max_window_tree_depth`
//! queries per cold walk, ZERO on both fast paths (direct managed hit, cache
//! hit). Nothing on a live server proves the zero-query side (a faster tree
//! walk still passes), so the walk core sits behind the injectable
//! `findManagedWindowWith` seam and these tests count steps against a fake
//! tree. Fail/stop/exhaust walks return the START window untouched -- that
//! fallback is what makes a cache miss or a dead window cost only the walk it
//! would have paid anyway.
//!
//! Headless (no fixture, no X): the seam takes the parent query as a
//! function pointer, so the suite proves the bound without a display.

const std = @import("std");
const testing = std.testing;

const window = @import("window");

/// The fake tree: `parents[from] = to` ascends one level, `stop_nodes` are
/// windows whose parent is the root (walk stops, returns start), an unlisted
/// window or `fail_on` fails the query. Every step is counted in `queries`.
const FakeTree = struct {
    parents: std.AutoHashMapUnmanaged(u32, u32) = .{},
    stop_nodes: std.AutoHashMapUnmanaged(u32, void) = .{},
    fail_on: ?u32 = null,
    queries: usize = 0,

    fn deinit(self: *FakeTree) void {
        self.parents.deinit(testing.allocator);
        self.stop_nodes.deinit(testing.allocator);
    }

    /// `nodes[0]` is the start; each ascends to the next; the last is
    /// registered as reaching the root (`stop`), which is only observed if a
    /// walk queries it (i.e. it was never managed).
    fn chain(self: *FakeTree, nodes: []const u32) !void {
        for (nodes[0 .. nodes.len - 1], nodes[1..]) |from, to| {
            try self.parents.put(testing.allocator, from, to);
        }
        try self.stop_nodes.put(testing.allocator, nodes[nodes.len - 1], {});
    }

    fn step(raw: *anyopaque, node: u32) window.ParentStep {
        const self: *FakeTree = @ptrCast(@alignCast(raw));
        self.queries += 1;
        if (self.fail_on) |n| if (n == node) return .fail;
        if (self.stop_nodes.contains(node)) return .stop;
        if (self.parents.get(node)) |p| return .{ .parent = p };
        return .fail;
    }

    fn walk(
        self: *FakeTree,
        start: u32,
        is_managed: *const fn (u32) bool,
    ) u32 {
        return window.findManagedWindowWith(start, is_managed, self, &step);
    }
};

fn managed(comptime id: u32) *const fn (u32) bool {
    return struct {
        fn f(w: u32) bool {
            return w == id;
        }
    }.f;
}

fn neverManaged(_: u32) bool {
    return false;
}

/// Hermetic cache: these tests seed and assert on the module-global child
/// cache, so each one starts and leaves it empty.
fn fresh() void {
    window.reset();
}

test "managed start window: zero queries" {
    fresh();
    defer fresh();

    var t = FakeTree{};
    defer t.deinit();

    try testing.expectEqual(@as(u32, 7), t.walk(7, managed(7)));
    try testing.expectEqual(@as(usize, 0), t.queries);
}

test "cache hit: zero queries, stale entry falls through to the walk" {
    fresh();
    defer fresh();

    // Valid cache entry: child 55 resolves to managed toplevel 9.
    window.put(55, 9);
    {
        var t = FakeTree{};
        defer t.deinit();
        try testing.expectEqual(@as(u32, 9), t.walk(55, managed(9)));
        try testing.expectEqual(@as(usize, 0), t.queries);
    }

    // Stale entry (9 no longer managed): validation fails and the walk runs,
    // re-caching under the new resolution.
    window.put(55, 9);
    {
        var t = FakeTree{};
        defer t.deinit();
        try t.chain(&.{ 55, 8 });
        try testing.expectEqual(@as(u32, 8), t.walk(55, managed(8)));
        try testing.expectEqual(@as(usize, 1), t.queries);
        try testing.expectEqual(@as(?u32, 8), window.get(55));
    }
}

test "cold walk: finds the toplevel, caches it, second hover is free" {
    fresh();
    defer fresh();

    var t = FakeTree{};
    defer t.deinit();
    try t.chain(&.{ 400, 300, 200, 9 });

    try testing.expectEqual(@as(u32, 9), t.walk(400, managed(9)));
    try testing.expectEqual(@as(usize, 3), t.queries);
    try testing.expectEqual(@as(?u32, 9), window.get(400));

    // The put above is the contract with the fast path: a repeat hover on the
    // same child must not pay the walk again.
    var again = FakeTree{};
    defer again.deinit();
    try testing.expectEqual(@as(u32, 9), again.walk(400, managed(9)));
    try testing.expectEqual(@as(usize, 0), again.queries);
}

test "depth bound: exactly max_window_tree_depth queries, start returned" {
    fresh();
    defer fresh();

    // Nothing managed anywhere in a chain deeper than the bound: the loop
    // exhausts at exactly max_window_tree_depth steps and returns start.
    var deep = FakeTree{};
    defer deep.deinit();
    var nodes: [window.max_window_tree_depth + 2]u32 = undefined;
    for (&nodes, 0..) |*n, i| n.* = 1000 - @as(u32, @intCast(i));
    try deep.chain(&nodes);

    try testing.expectEqual(nodes[0], deep.walk(nodes[0], neverManaged));
    try testing.expectEqual(window.max_window_tree_depth, deep.queries);
}

test "depth boundary: managed at the last reachable hop wins, one deeper is missed" {
    fresh();
    defer fresh();

    // Managed at hop == max_window_tree_depth: found on the final iteration.
    {
        var t = FakeTree{};
        defer t.deinit();
        // 1000->999->...->990: ten ascents; 990 is managed, so it is never
        // queried itself.
        var i: usize = 0;
        while (i < 10) : (i += 1) {
            const from = 1000 - @as(u32, @intCast(i));
            const to = 1000 - @as(u32, @intCast(i + 1));
            try t.parents.put(testing.allocator, from, to);
        }
        try testing.expectEqual(@as(u32, 990), t.walk(1000, managed(990)));
        try testing.expectEqual(window.max_window_tree_depth, t.queries);
    }

    // Managed ONE hop beyond the bound: never reached, start returned, and
    // the failed walk still costs exactly the bound (never more).
    {
        var t = FakeTree{};
        defer t.deinit();
        var i: usize = 0;
        while (i < 10) : (i += 1) {
            const from = 2000 - @as(u32, @intCast(i));
            const to = 2000 - @as(u32, @intCast(i + 1));
            try t.parents.put(testing.allocator, from, to);
        }
        // 2000->...->1990 queried; 1989 (managed) sits at hop 11,
        // unreachable.
        try testing.expectEqual(@as(u32, 2000), t.walk(2000, managed(1989)));
        try testing.expectEqual(window.max_window_tree_depth, t.queries);
    }
}

test "query failure and root-parent stop: start returned, walk abandoned" {
    fresh();
    defer fresh();

    // Failure at the first hop (dead window, null reply).
    {
        var t = FakeTree{};
        defer t.deinit();
        t.fail_on = 500;
        try t.parents.put(testing.allocator, 500, 499);
        try testing.expectEqual(@as(u32, 500), t.walk(500, managed(499)));
        try testing.expectEqual(@as(usize, 1), t.queries);
    }

    // Failure mid-walk: one hop paid, the second query fails, abandoned to
    // the start window.
    {
        var t = FakeTree{};
        defer t.deinit();
        t.fail_on = 500;
        try t.chain(&.{ 510, 500, 499, 498 });
        try testing.expectEqual(@as(u32, 510), t.walk(510, managed(498)));
        try testing.expectEqual(@as(usize, 2), t.queries);
    }

    // Parent is the root (stop): also falls back to start.
    {
        var t = FakeTree{};
        defer t.deinit();
        try t.chain(&.{ 610, 600 });
        try testing.expectEqual(@as(u32, 610), t.walk(610, managed(599)));
        try testing.expectEqual(@as(usize, 2), t.queries);
    }

    // Unmanaged start, no cache, no walk data: query fails, start returned.
    {
        var t = FakeTree{};
        defer t.deinit();
        try testing.expectEqual(@as(u32, 710), t.walk(710, neverManaged));
        try testing.expectEqual(@as(usize, 1), t.queries);
    }
}
