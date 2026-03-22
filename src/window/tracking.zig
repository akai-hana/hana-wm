//! Efficient window tracking backed by a fixed-size stack array.
//!
//! A linear scan over a small array of u32s is cache-friendly enough to
//! outperform a HashSet at any window count a window manager realistically
//! reaches. No dual-mode switching, no arbitrary promotion thresholds,
//! no heap allocation, no deinit.

const std = @import("std");

pub const Tracking = struct {
    // 64 windows is already a pathological session. A u8 len field keeps
    // the struct to 256 + 1 bytes, well within a few cache lines.
    const capacity = 64;

    buf: [capacity]u32 = undefined,
    len: u8            = 0,

    // No init needed — zero-initialise with `.{}` or `Tracking{}`.
    // No deinit — nothing to free.

    pub fn contains(self: *const Tracking, win: u32) bool {
        return std.mem.indexOfScalar(u32, self.buf[0..self.len], win) != null;
    }

    /// Returns false if win is already tracked or if the buffer is full.
    /// The capacity check is an explicit runtime guard in all build modes —
    /// not an assert — so a full buffer silently drops the add rather than
    /// corrupting the length field in release builds.
    fn prepareAdd(self: *Tracking, win: u32) bool {
        if (self.contains(win)) return false;
        if (self.len >= capacity) return false;
        return true;
    }

    /// Appends win to the back. No-op if win is already present or the
    /// buffer is full. Infallible — no allocator, no OOM path.
    pub fn add(self: *Tracking, win: u32) void {
        if (!self.prepareAdd(win)) return;
        self.buf[self.len] = win;
        self.len += 1;
    }

    /// Prepends win to the front, shifting existing entries right.
    /// No-op if win is already present or the buffer is full.
    /// Infallible — no allocator, no OOM path.
    pub fn addFront(self: *Tracking, win: u32) void {
        if (!self.prepareAdd(win)) return;
        // Shift right from the end to avoid clobbering elements.
        std.mem.copyBackwards(u32, self.buf[1 .. self.len + 1], self.buf[0..self.len]);
        self.buf[0] = win;
        self.len += 1;
    }

    /// Removes win, preserving the order of remaining entries.
    /// Use this when list order is semantically significant (e.g. MRU traversal).
    /// Returns true if win was present, false otherwise.
    pub fn remove(self: *Tracking, win: u32) bool {
        const i = std.mem.indexOfScalar(u32, self.buf[0..self.len], win) orelse return false;
        std.mem.copyForwards(u32, self.buf[i .. self.len - 1], self.buf[i + 1 .. self.len]);
        self.len -= 1;
        return true;
    }

    /// Removes win in O(1) by swapping it with the last entry.
    /// Use this over `remove` when the relative order of remaining entries
    /// does not matter (e.g. tearing down a workspace).
    /// Returns true if win was present, false otherwise.
    pub fn removeUnordered(self: *Tracking, win: u32) bool {
        const i = std.mem.indexOfScalar(u32, self.buf[0..self.len], win) orelse return false;
        self.buf[i] = self.buf[self.len - 1];
        self.len   -= 1;
        return true;
    }

    /// Reorders contents to match new_order.
    /// new_order must have the same length as the current list.
    /// In safety builds, asserts that new_order is a valid permutation of
    /// the current elements — both directions — so silent overwrites with
    /// arbitrary IDs are caught at the earliest possible moment.
    pub fn reorder(self: *Tracking, new_order: []const u32) void {
        std.debug.assert(new_order.len == self.len);
        // Permutation check: every element in new_order must exist in the
        // current list, and vice versa. O(n²) at n ≤ 64 — negligible in
        // debug builds, stripped entirely in release.
        for (new_order) |w|
            std.debug.assert(self.contains(w));
        for (self.buf[0..self.len]) |w|
            std.debug.assert(std.mem.indexOfScalar(u32, new_order, w) != null);

        @memcpy(self.buf[0..self.len], new_order);
    }

    pub fn items(self: *const Tracking) []const u32 {
        return self.buf[0..self.len];
    }
};
