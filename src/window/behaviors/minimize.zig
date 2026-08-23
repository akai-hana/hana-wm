//! Window minimization — model-backed queries (WP6).
//!
//! Minimize state lives in the model (`Entry.mode == .minimized`); the legacy
//! side buffer this module once owned was orphaned when actions.minimize took
//! over the entry path and is gone. What remains are read-side helpers for
//! the bar and focus/fullscreen predicates.

const std = @import("std");
const pipeline = @import("pipeline");

pub fn init() void {}

pub fn deinit() void {}

/// True when `win` currently holds a minimized record in the model.
pub fn isMinimized(win: u32) bool {
    const m = pipeline.model();
    const e = m.store.get(win) orelse return false;
    return e.mode == .minimized;
}

/// Fills `set` with every currently minimized window ID, replacing any prior contents.
/// Called by bar.zig to build the per-frame BarSnapshot.minimized_set.
pub fn collectMinimizedIntoSet(
    set: *std.AutoHashMapUnmanaged(u32, void),
    allocator: std.mem.Allocator,
) !void {
    set.clearRetainingCapacity();
    const m = pipeline.model();
    var seq: usize = 0;
    while (seq < m.store.count()) : (seq += 1) {
        const item = m.store.at(seq);
        if (item.val.mode == .minimized)
            try set.put(allocator, item.key, {});
    }
}
