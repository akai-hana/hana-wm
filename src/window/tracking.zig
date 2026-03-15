//! Efficient window tracking backed by a contiguous array.
//!
//! A linear scan over a small array of u32s is cache-friendly enough to
//! outperform a HashSet at any window count a window manager realistically
//! reaches. No dual-mode switching, no arbitrary promotion thresholds.

const std = @import("std");

pub const Tracking = struct {
    list:      std.ArrayListUnmanaged(u32) = .empty,
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{ .list = .empty, .allocator = allocator };
    }

    pub fn deinit(self: *Self) void {
        self.list.deinit(self.allocator);
    }

    pub fn contains(self: *const Self, win: u32) bool {
        return std.mem.indexOfScalar(u32, self.list.items, win) != null;
    }

    pub fn add(self: *Self, win: u32) !void {
        if (self.contains(win)) return;
        try self.list.append(self.allocator, win);
    }

    pub fn addFront(self: *Self, win: u32) !void {
        if (self.contains(win)) return;
        try self.list.insert(self.allocator, 0, win);
    }

    pub fn remove(self: *Self, win: u32) bool {
        const i = std.mem.indexOfScalar(u32, self.list.items, win) orelse return false;
        _ = self.list.orderedRemove(i);
        return true;
    }

    /// Reorders contents to match new_order, which must be a permutation of
    /// the current items — same elements, no additions or removals.
    pub fn reorder(self: *Self, new_order: []const u32) void {
        std.debug.assert(new_order.len == self.list.items.len);
        @memcpy(self.list.items, new_order);
    }

    pub fn items(self: *const Self) []const u32 { return self.list.items; }
    pub fn count(self: *const Self) usize { return self.list.items.len; }
    pub fn isEmpty(self: *const Self) bool { return self.list.items.len == 0; }
};
