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

    // FIX #3: `init` removed. `list` already defaults to `.empty` via the field
    // initializer above, so callers can write `Tracking{ .allocator = alloc }`
    // directly — the wrapper added indirection with no benefit.

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

    // FIX #1: Inlined `indexOfScalar` directly instead of calling `self.contains`.
    // The original code paid for a `contains` call (one named function dispatch +
    // indexOfScalar scan) followed by `insert` (a second scan-and-shift). Inlining
    // removes the intermediate function call overhead so the single scan result
    // drives the duplicate guard without an extra frame.
    pub fn addFront(self: *Self, win: u32) !void {
        if (std.mem.indexOfScalar(u32, self.list.items, win) != null) return;
        try self.list.insert(self.allocator, 0, win);
    }

    // FIX #2 (order-preserving path): Kept for call sites where list order is
    // semantically significant (MRU traversal, reorder, etc.).
    pub fn remove(self: *Self, win: u32) bool {
        const i = std.mem.indexOfScalar(u32, self.list.items, win) orelse return false;
        _ = self.list.orderedRemove(i);
        return true;
    }

    // FIX #2 (unordered path): O(1) removal via swap for call sites where the
    // relative order of remaining entries does not matter (e.g. tearing down a
    // workspace). Prefer this over `remove` wherever order is irrelevant.
    pub fn removeUnordered(self: *Self, win: u32) bool {
        const i = std.mem.indexOfScalar(u32, self.list.items, win) orelse return false;
        _ = self.list.swapRemove(i);
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
