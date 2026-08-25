//! Bounded window store. A full-store put refuses BEFORE any mutation.
//!
//! Iteration order = SLOT order: `remove` swap-removes, so the last live
//! element moves into the freed slot. Deterministic but not
//! insertion-ordered.
const std = @import("std");

pub fn Store(comptime K: type, comptime V: type, comptime capacity: usize) type {
    return struct {
        const Self = @This();
        pub const Error = error{StoreFull};

        keys: [capacity]K = undefined,
        vals: [capacity]V = undefined,
        len: usize = 0,

        pub fn getPtr(self: *Self, k: K) ?*V {
            var i: usize = 0;
            while (i < self.len) : (i += 1) {
                if (self.keys[i] == k) return &self.vals[i];
            }
            return null;
        }

        pub fn get(self: *const Self, k: K) ?V {
            var i: usize = 0;
            while (i < self.len) : (i += 1) {
                if (self.keys[i] == k) return self.vals[i];
            }
            return null;
        }

        pub fn has(self: *const Self, k: K) bool {
            var i: usize = 0;
            while (i < self.len) : (i += 1) {
                if (self.keys[i] == k) return true;
            }
            return false;
        }

        pub fn put(self: *Self, k: K, v: V) Error!*V {
            if (self.getPtr(k)) |slot| {
                slot.* = v;
                return slot;
            }
            if (self.len == capacity) return Error.StoreFull;
            const s = self.len;
            self.keys[s] = k;
            self.vals[s] = v;
            self.len += 1;
            return &self.vals[s];
        }

        /// Swap-remove: the last live element moves into the freed slot.
        /// O(1); iteration order after removal is slot order.
        pub fn remove(self: *Self, k: K) bool {
            var i: usize = 0;
            while (i < self.len) : (i += 1) {
                if (self.keys[i] == k) {
                    const last = self.len - 1;
                    if (i != last) {
                        self.keys[i] = self.keys[last];
                        self.vals[i] = self.vals[last];
                    }
                    self.len = last;
                    return true;
                }
            }
            return false;
        }

        pub const Item = struct { key: K, val: *const V };

        /// seq must be < count(). Iterates in slot order.
        pub fn at(self: *const Self, seq: usize) Item {
            std.debug.assert(seq < self.len);
            return .{ .key = self.keys[seq], .val = &self.vals[seq] };
        }

        pub fn count(self: *const Self) usize {
            return self.len;
        }
    };
}
