//! Efficient window tracking with small-array optimisation.
//!
//! Storage strategy:
//!   Small (<=small_cap windows): fixed inline array, cache-friendly, zero allocations.
//!   Large (>small_cap windows):  ArrayList + HashSet for O(1) contains/remove.
//!
//! A tagged union enforces that exactly one mode is active at all times.
//! Use the `Tracking` alias for the default 16-window capacity.

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

    // Both fields are now Unmanaged so ownership is uniform: every alloc/free
    // goes through an explicit allocator parameter.  The previous LargeStore
    // embedded the allocator inside AutoHashMap, which made deinit, promote,
    // and demote inconsistent — some paths called set.deinit() with no
    // argument while list.deinit required one.
    const LargeStore = struct {
        list: std.ArrayListUnmanaged(u32),
        set:  std.AutoHashMapUnmanaged(u32, void),
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
                self.storage.large.set.deinit(self.allocator); // uniform: allocator required
            }
        }

        // O(n) for small (cache-friendly scan), O(1) for large.
        pub inline fn contains(self: *const Self, win: u32) bool {
            return switch (self.storage) {
                .small => |s| std.mem.indexOfScalar(u32, s.items[0..s.len], win) != null,
                .large => |l| l.set.contains(win),
            };
        }

        // Shared implementation for add (front=false) and addFront (front=true).
        // Every branch is identical except the list-mutation: append vs insert-at-0.
        // Single getOrPut probe on the large path covers both duplicate check and
        // insertion; set entry is rolled back if the list mutation fails.
        fn addImpl(self: *Self, win: u32, comptime front: bool) !void {
            std.debug.assert(win != 0);
            switch (self.storage) {
                .small => |*s| {
                    if (std.mem.indexOfScalar(u32, s.items[0..s.len], win) != null) return;
                    if (s.len < small_cap) {
                        if (front) {
                            std.mem.copyBackwards(u32, s.items[1 .. s.len + 1], s.items[0..s.len]);
                            s.items[0] = win;
                        } else {
                            s.items[s.len] = win;
                        }
                        s.len += 1;
                    } else {
                        try self.promoteToLarge();
                        // promoteToLarge reserves s.len+8 slots, so assumeCapacity is safe.
                        if (front) {
                            try self.storage.large.list.insert(self.allocator, 0, win);
                        } else {
                            self.storage.large.list.appendAssumeCapacity(win);
                        }
                        self.storage.large.set.putAssumeCapacity(win, {});
                    }
                },
                .large => |*l| {
                    const gop = try l.set.getOrPut(self.allocator, win);
                    if (gop.found_existing) return;
                    const list_err = if (front) l.list.insert(self.allocator, 0, win)
                                    else        l.list.append(self.allocator, win);
                    list_err catch |err| { _ = l.set.remove(win); return err; };
                },
            }
        }

        pub fn add(self: *Self, win: u32) !void      { return self.addImpl(win, false); }
        pub fn addFront(self: *Self, win: u32) !void { return self.addImpl(win, true);  }

        // Reorder in a single pass using a caller-provided permutation of current items.
        // For large storage, also rebuilds the hash set to stay consistent.
        pub fn reorder(self: *Self, new_order: []const u32) void {
            switch (self.storage) {
                .small => |*s| {
                    // Debug: verify the caller is passing a true permutation.
                    std.debug.assert(new_order.len == s.len);
                    const len: u8 = @intCast(@min(new_order.len, small_cap));
                    @memcpy(s.items[0..len], new_order[0..len]);
                    s.len = len;
                },
                .large => |*l| {
                    // Debug: verify length and that new_order is a permutation
                    // of the current items.  A mismatch here means the caller
                    // passed a stale or incorrect window list; catching it early
                    // prevents silent list/set divergence.
                    std.debug.assert(new_order.len == l.list.items.len);
                    std.debug.assert(new_order.len <= l.list.capacity);
                    if (std.debug.runtime_safety) {
                        for (new_order) |win| std.debug.assert(l.set.contains(win));
                    }
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
                    // Check and remove from the set first (O(1)).  If absent we
                    // bail before touching the list, keeping both structures in sync.
                    // When present we know the list must also contain the entry, so
                    // the subsequent indexOfScalar is guaranteed to succeed — the
                    // .? is safe.
                    if (!l.set.remove(win)) return false;
                    const idx = std.mem.indexOfScalar(u32, l.list.items, win).?;
                    _ = l.list.orderedRemove(idx);
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
            var set:  std.AutoHashMapUnmanaged(u32, void) = .{};
            errdefer list.deinit(self.allocator);
            errdefer set.deinit(self.allocator); // unmanaged: explicit allocator
            try list.ensureTotalCapacity(self.allocator, s.len + 8);
            try set.ensureTotalCapacity(self.allocator, s.len + 8); // unmanaged form
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
            l.set.deinit(self.allocator); // unmanaged: explicit allocator
            self.storage = .{ .small = small };
        }
    };
}

/// Default alias used by all call sites: 16-window small-array optimisation.
pub const Tracking = TrackingType(16);
