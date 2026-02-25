// Efficient window tracking with small-array optimisation.
//
// Storage strategy:
//   Small (<=small_cap windows): fixed inline array, cache-friendly, zero allocations.
//   Large (>small_cap windows):  ArrayList + HashSet for O(1) contains/remove.
//
// A tagged union enforces that exactly one mode is active at all times.
// Use the `Tracking` alias for the default 16-window capacity.

const std = @import("std");

/// Generic window tracker parameterised by small-store capacity.
/// Callers that need a different threshold can instantiate directly;
/// all existing call sites use the `Tracking` alias below.
pub fn TrackingType(comptime small_cap: u8) type {
    const demotion_threshold = small_cap / 2;

    const SmallStore = struct {
        items: [small_cap]u32 = undefined,
        len:   u8 = 0,
    };

    const LargeStore = struct {
        list: std.ArrayListUnmanaged(u32),
        set:  std.AutoHashMap(u32, void),
    };

    const Storage = union(enum) { small: SmallStore, large: LargeStore };

    return struct {
        storage:   Storage,
        allocator: std.mem.Allocator,

        const Self = @This();

        pub fn init(allocator: std.mem.Allocator) Self {
            return .{ .storage = .{ .small = .{} }, .allocator = allocator };
        }

        pub fn deinit(self: *Self) void {
            if (self.storage == .large) {
                self.storage.large.list.deinit(self.allocator);
                self.storage.large.set.deinit();
            }
        }

        // O(n) for small (cache-friendly scan), O(1) for large.
        pub inline fn contains(self: *const Self, win: u32) bool {
            return switch (self.storage) {
                .small => |s| std.mem.indexOfScalar(u32, s.items[0..s.len], win) != null,
                .large => |l| l.set.contains(win),
            };
        }

        pub fn add(self: *Self, win: u32) !void {
            std.debug.assert(win != 0);
            if (self.contains(win)) return;
            switch (self.storage) {
                .small => |*s| {
                    if (s.len < small_cap) {
                        s.items[s.len] = win;
                        s.len += 1;
                    } else {
                        try self.promoteToLarge();
                        // promoteToLarge reserves s.len+8 slots, so there is always room.
                        self.storage.large.list.appendAssumeCapacity(win);
                        self.storage.large.set.putAssumeCapacity(win, {});
                    }
                },
                .large => |*l| {
                    try l.list.append(self.allocator, win);
                    try l.set.put(win, {});
                },
            }
        }

        pub fn addFront(self: *Self, win: u32) !void {
            std.debug.assert(win != 0);
            if (self.contains(win)) return;
            switch (self.storage) {
                .small => |*s| {
                    if (s.len < small_cap) {
                        std.mem.copyBackwards(u32, s.items[1 .. s.len + 1], s.items[0..s.len]);
                        s.items[0] = win;
                        s.len += 1;
                    } else {
                        try self.promoteToLarge();
                        // promoteToLarge reserves s.len+8 slots; insert re-checks capacity.
                        try self.storage.large.list.insert(self.allocator, 0, win);
                        self.storage.large.set.putAssumeCapacity(win, {});
                    }
                },
                .large => |*l| {
                    try l.list.insert(self.allocator, 0, win);
                    try l.set.put(win, {});
                },
            }
        }

        // Reorder in a single pass using a caller-provided permutation of current items.
        // For large storage, also rebuilds the hash set to stay consistent.
        pub fn reorder(self: *Self, new_order: []const u32) void {
            switch (self.storage) {
                .small => |*s| {
                    const len: u8 = @intCast(@min(new_order.len, small_cap));
                    @memcpy(s.items[0..len], new_order[0..len]);
                    s.len = len;
                },
                .large => |*l| {
                    // new_order must be a permutation: same length, fits existing capacity.
                    std.debug.assert(new_order.len <= l.list.capacity);
                    // clearRetainingCapacity keeps storage, making assumeCapacity safe below.
                    l.list.clearRetainingCapacity();
                    l.set.clearRetainingCapacity();
                    for (new_order) |win| {
                        l.list.appendAssumeCapacity(win);
                        l.set.putAssumeCapacity(win, {});
                    }
                },
            }
        }

        // Ordered removal (preserves window order).
        pub fn remove(self: *Self, win: u32) bool {
            switch (self.storage) {
                .small => |*s| {
                    for (s.items[0..s.len], 0..) |w, i| {
                        if (w != win) continue;
                        s.len -= 1;
                        std.mem.copyForwards(u32, s.items[i..s.len], s.items[i + 1 .. s.len + 1]);
                        return true;
                    }
                    return false;
                },
                .large => |*l| {
                    // Find list index first; bail before touching the set if missing
                    // so both structures stay in sync.
                    const idx = std.mem.indexOfScalar(u32, l.list.items, win) orelse return false;
                    _ = l.set.remove(win);
                    _ = l.list.orderedRemove(idx);
                    // Capture len before demoteToSmall() invalidates `l`.
                    if (l.list.items.len <= demotion_threshold) self.demoteToSmall();
                    return true;
                },
            }
        }

        // Returns a slice into Self's own storage, valid for the lifetime of self.
        pub inline fn items(self: *const Self) []const u32 {
            return switch (self.storage) {
                .small => |s| s.items[0..s.len],
                .large => |l| l.list.items,
            };
        }

        // Zero-copy count: avoids materialising a full slice just to read length.
        pub inline fn count(self: *const Self) usize {
            return switch (self.storage) {
                .small => |s| s.len,
                .large => |l| l.list.items.len,
            };
        }

        pub inline fn isEmpty(self: *const Self) bool {
            return self.count() == 0;
        }

        fn promoteToLarge(self: *Self) !void {
            const s = self.storage.small;
            var list: std.ArrayListUnmanaged(u32) = .empty;
            var set = std.AutoHashMap(u32, void).init(self.allocator);
            errdefer list.deinit(self.allocator);
            errdefer set.deinit();
            try list.ensureTotalCapacity(self.allocator, s.len + 8);
            try set.ensureTotalCapacity(s.len + 8);
            for (s.items[0..s.len]) |win| {
                list.appendAssumeCapacity(win);
                set.putAssumeCapacity(win, {});
            }
            self.storage = .{ .large = .{ .list = list, .set = set } };
        }

        fn demoteToSmall(self: *Self) void {
            const l = &self.storage.large;
            var small: SmallStore = .{};
            small.len = @intCast(l.list.items.len);
            @memcpy(small.items[0..small.len], l.list.items);
            l.list.deinit(self.allocator);
            l.set.deinit();
            self.storage = .{ .small = small };
        }
    };
}

/// Default alias used by all call sites: 16-window small-array optimisation.
pub const Tracking = TrackingType(16);
