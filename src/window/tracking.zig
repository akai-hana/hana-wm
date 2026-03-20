//! Efficient window tracking backed by a contiguous array.
//!
//! A linear scan over a small array of u32s is cache-friendly enough to
//! outperform a HashSet at any window count a window manager realistically
//! reaches. No dual-mode switching, no arbitrary promotion thresholds.

const std = @import("std");

pub const Tracking = struct {
    list:      std.ArrayListUnmanaged(u32) = .empty,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) Tracking {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Tracking) void {
        self.list.deinit(self.allocator);
    }

    pub fn contains(self: *const Tracking, win: u32) bool {
        return std.mem.indexOfScalar(u32, self.list.items, win) != null;
    }

    pub fn add(self: *Tracking, win: u32) !void {
        if (self.contains(win)) return;
        try self.list.append(self.allocator, win);
    }

    pub fn addFront(self: *Tracking, win: u32) !void {
        if (self.contains(win)) return;
        try self.list.insert(self.allocator, 0, win);
    }

    /// Removes win, preserving the order of remaining entries.
    /// Use this when list order is semantically significant (e.g. MRU traversal).
    /// Returns true if win was present, false otherwise.
    pub fn remove(self: *Tracking, win: u32) bool {
        const i = std.mem.indexOfScalar(u32, self.list.items, win) orelse return false;
        _ = self.list.orderedRemove(i);
        return true;
    }

    /// Removes win in O(1) by swapping it with the last entry.
    /// Use this over `remove` when the relative order of remaining entries
    /// does not matter (e.g. tearing down a workspace).
    /// Returns true if win was present, false otherwise.
    pub fn removeUnordered(self: *Tracking, win: u32) bool {
        const i = std.mem.indexOfScalar(u32, self.list.items, win) orelse return false;
        _ = self.list.swapRemove(i);
        return true;
    }

    /// Reorders contents to match new_order.
    /// new_order must have the same length as the current list.
    /// Note: only the length is checked; element validity is the caller's responsibility.
    pub fn reorder(self: *Tracking, new_order: []const u32) void {
        std.debug.assert(new_order.len == self.list.items.len);
        @memcpy(self.list.items, new_order);
    }

    pub fn items(self: *const Tracking) []const u32 {
        return self.list.items;
    }

    pub fn count(self: *const Tracking) usize {
        return self.list.items.len;
    }

    pub fn isEmpty(self: *const Tracking) bool {
        return self.count() == 0;
    }
};
