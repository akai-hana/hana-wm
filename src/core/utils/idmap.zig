//! Fixed-capacity, allocation-free open-addressed map keyed by u32 window ID.
//!
//! Why a hash map: the ICCCM focus-property cache is probed on every focus
//! change over a table sized for the worst case (`max_window_cache`), so a
//! linear `indexOfById` scan is O(n) on the hot path. This keeps the same
//! allocation-free, fixed-capacity contract as `BoundedList` but makes lookups
//! O(1) with a small constant.
//!
//! Deletion uses tombstones (reclaimed by an in-place rehash once the table
//! first fills); entries are never moved, so a `get` result is stable across
//! unrelated inserts/removes. `capacity` bounds live entries; the slot array is
//! a power of two strictly larger than `capacity`, so linear probing always
//! terminates at an empty slot.
//!
//! Layer note: xcb-free by construction, safe for model/tiling to import.

const std = @import("std");

pub fn IdMap(comptime V: type, comptime capacity: usize) type {
    comptime {
        if (capacity == 0) @compileError("IdMap capacity must be > 0");
    }
    return struct {
        const Self = @This();

        /// Slot count is a power of two > capacity so the load factor stays
        /// below 1 and probing always finds an empty slot.
        const slots = std.math.ceilPowerOfTwo(usize, capacity + 1) catch unreachable;
        const slot_mask = slots - 1;

        /// Window IDs are never 0, so it is the "never used" sentinel.
        const empty: u32 = 0;
        /// Marks a deleted slot that probing must step over.
        const tomb: u32 = std.math.maxInt(u32);

        keys: [slots]u32 = @splat(empty),
        vals: [slots]V = undefined,
        len: usize = 0,
        tombstones: usize = 0,

        fn home(id: u32) usize {
            // Fibonacci hashing spreads sequential XIDs across the table.
            const h = @as(u64, id) *% 0x9E3779B97F4A7C15;
            return @as(usize, @intCast(h >> 32)) & slot_mask;
        }

        /// Slot holding `id`, or null when absent. Stops at the first empty
        /// slot (tombstones are stepped over).
        fn find(self: *const Self, id: u32) ?usize {
            var i = home(id);
            while (true) {
                const k = self.keys[i];
                if (k == empty) return null;
                if (k == id) return i;
                i = (i + 1) & slot_mask;
            }
        }

        pub fn get(self: *const Self, id: u32) ?V {
            const i = self.find(id) orelse return null;
            return self.vals[i];
        }

        pub fn contains(self: *const Self, id: u32) bool {
            return self.find(id) != null;
        }

        /// Inserts or overwrites. Returns false (table untouched) when
        /// `capacity` live entries are already held; callers fall back to the
        /// live path.
        pub fn put(self: *Self, id: u32, value: V) bool {
            if (self.find(id)) |i| {
                self.vals[i] = value;
                return true;
            }
            // No empty slot left because tombstones consumed it: reclaim them
            // before deciding the table is full.
            if (self.len + self.tombstones == slots) self.rehash();
            if (self.len == capacity) return false;

            var i = home(id);
            var first_tomb: ?usize = null;
            while (true) {
                const k = self.keys[i];
                if (k == empty) {
                    const slot = first_tomb orelse i;
                    if (first_tomb != null) self.tombstones -= 1;
                    self.keys[slot] = id;
                    self.vals[slot] = value;
                    self.len += 1;
                    return true;
                }
                if (k == tomb and first_tomb == null) first_tomb = i;
                i = (i + 1) & slot_mask;
            }
        }

        pub fn remove(self: *Self, id: u32) bool {
            const i = self.find(id) orelse return false;
            self.keys[i] = tomb;
            self.vals[i] = undefined;
            self.len -= 1;
            self.tombstones += 1;
            return true;
        }

        pub fn count(self: *const Self) usize {
            return self.len;
        }

        pub fn clear(self: *Self) void {
            self.keys = @splat(empty);
            self.vals = undefined;
            self.len = 0;
            self.tombstones = 0;
        }

        /// Drops tombstones in place by re-inserting the live entries.
        fn rehash(self: *Self) void {
            const old_keys = self.keys;
            const old_vals = self.vals;
            self.keys = @splat(empty);
            self.len = 0;
            self.tombstones = 0;
            for (old_keys, old_vals) |k, v| {
                if (k == empty or k == tomb) continue;
                var i = home(k);
                while (self.keys[i] != empty) i = (i + 1) & slot_mask;
                self.keys[i] = k;
                self.vals[i] = v;
                self.len += 1;
            }
        }
    };
}
