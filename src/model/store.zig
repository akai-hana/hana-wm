//! Bounded, stack-allocated key-value collection with sorted-key binary search.
//!
//! The Store is parameterised by key type, value type, and a hard capacity
//! ceiling (stack-allocated arrays, no heap allocation).  Keys are kept in
//! sorted order at all times: lookups (get, getPtr, has) use O(log n) binary
//! search; put and remove use binary search for the position and then shift
//! arrays to maintain sorted order.
//!
//! Threading model: single-threaded, no locking needed; all access occurs
//! on the event-loop thread.
//!
//! When the capacity is reached, put returns error.StoreFull; there is no
//! eviction or overflow, the ceiling is absolute.
const std = @import("std");

pub fn Store(comptime K: type, comptime V: type, comptime capacity: usize) type {
    return struct {
        const Self = @This();
        pub const Error = error{StoreFull};

        keys: [capacity]K = undefined,
        vals: [capacity]V = undefined,
        len: usize = 0,

        fn binarySearch(
            self: *const Self,
            comptime mode: enum { exact, lower_bound },
            k: K,
        ) if (mode == .exact) ?usize else usize {
            var lo: usize = 0;
            var hi: usize = self.len;
            while (lo < hi) {
                const mid = lo + (hi - lo) / 2;
                if (mode == .exact and self.keys[mid] == k) return mid;
                if (self.keys[mid] < k) {
                    lo = mid + 1;
                } else {
                    hi = mid;
                }
            }
            return if (mode == .exact) null else lo;
        }

        pub fn getPtr(self: *Self, k: K) ?*V {
            if (self.binarySearch(.exact, k)) |i| return &self.vals[i];
            return null;
        }

        // Pointer-relocation contract: the Store is a contiguous array, so a
        // *V returned by getPtr/put remains valid across get/put/remove of
        // OTHER keys (those shift slots but never reallocate). It is
        // invalidated ONLY by put(k) on a different entry, remove(k), or
        // clear() -- each of which may move the slot that k occupies -- or by
        // a reload into self.keys/self.vals wholesale. Callers must not cache
        // a *V across such an operation on its own key.

        pub fn get(self: *const Self, k: K) ?V {
            if (self.binarySearch(.exact, k)) |i| return self.vals[i];
            return null;
        }

        pub fn has(self: *const Self, k: K) bool {
            return self.binarySearch(.exact, k) != null;
        }

        pub fn put(self: *Self, k: K, v: V) Error!*V {
            if (self.binarySearch(.exact, k)) |i| {
                self.vals[i] = v;
                return &self.vals[i];
            }
            if (self.len == capacity) return Error.StoreFull;
            const pos = self.binarySearch(.lower_bound, k);
            var i = self.len;
            while (i > pos) : (i -= 1) {
                self.keys[i] = self.keys[i - 1];
                self.vals[i] = self.vals[i - 1];
            }
            self.keys[pos] = k;
            self.vals[pos] = v;
            self.len += 1;
            return &self.vals[pos];
        }

        /// Sorted-shift-remove: elements after `i` shift left to fill the gap.
        /// O(n); iteration order stays sorted-by-key.
        pub fn remove(self: *Self, k: K) bool {
            if (self.binarySearch(.exact, k)) |i| {
                const last = self.len - 1;
                var j = i;
                while (j < last) : (j += 1) {
                    self.keys[j] = self.keys[j + 1];
                    self.vals[j] = self.vals[j + 1];
                }
                self.len = last;
                return true;
            }
            return false;
        }

        pub const Item = struct { key: K, val: *const V };

        /// seq must be < count(). Iterates in sorted-key order.
        pub fn at(self: *const Self, seq: usize) Item {
            std.debug.assert(seq < self.len);
            return .{ .key = self.keys[seq], .val = &self.vals[seq] };
        }

        pub fn count(self: *const Self) usize {
            return self.len;
        }

        pub fn clear(self: *Self) void {
            self.len = 0;
        }
    };
}
