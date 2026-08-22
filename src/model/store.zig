//! Bounded window store. INVARIANT(I8): a full-store put refuses BEFORE any
//! mutation. Iteration order = insertion order (decision C-D5).
const std = @import("std");

pub fn Store(comptime K: type, comptime V: type, comptime capacity: usize) type {
    return struct {
        const Self = @This();
        pub const Error = error{StoreFull};

        keys: [capacity]K = undefined,
        vals: [capacity]V = undefined,
        /// slot indices in insertion sequence; order[i] < len for i < len.
        order: [capacity]usize = undefined,
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
            self.order[s] = s;
            self.len += 1;
            return &self.vals[s];
        }

        /// Swap-remove keeping order[] consistent: when the last live element
        /// moves into the freed slot, its index inside order[] is rewritten.
        pub fn remove(self: *Self, k: K) bool {
            var i: usize = 0;
            while (i < self.len) : (i += 1) {
                if (self.keys[i] == k) {
                    const last = self.len - 1;
                    if (i != last) {
                        var p: usize = 0;
                        while (p <= last) : (p += 1) {
                            if (self.order[p] == last) {
                                self.order[p] = i;
                                break;
                            }
                        }
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

        /// seq must be < count(). Iterates in insertion order.
        pub fn at(self: *const Self, seq: usize) Item {
            const s = self.order[seq];
            return .{ .key = self.keys[s], .val = &self.vals[s] };
        }

        pub fn count(self: *const Self) usize {
            return self.len;
        }
    };
}
