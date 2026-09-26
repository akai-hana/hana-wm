//! Round-robin index cycling.
//!
//! The one modulo-wrap in the tree, powering the round-robin focus and
//! layout-direction cycles. Extracted so those callers name the operation
//! instead of reaching into a shared grab bag for it.

/// Modulo-wraps `idx` by signed `dir` into [0, n); 0 for an empty range.
pub inline fn wrapIndex(idx: usize, dir: i32, n: usize) usize {
    if (n == 0) return 0;
    return @intCast(@mod(@as(i64, @intCast(idx)) + dir, @as(i64, @intCast(n))));
}
