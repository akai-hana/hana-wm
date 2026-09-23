//! Bounded collections.
//!
//! Shared shape used by the window module's caches, the minimize module's
//! minimized-window record, and the spawn module's pending-spawn table: a
//! fixed-capacity array plus a length, with linear-scan find, append, and
//! remove-and-compact. Plus the sorted-key binary-search store (Store) that
//! backs the model's window entries and the sync ledger.
//!
//! Layer note: xcb-free by construction, safe for model/tiling to import.

const std = @import("std");

const debug = @import("debug");

/// Generic fixed-capacity, allocation-free collection backed by a plain
/// array. Linear scan is the right tool at the counts these call sites deal
/// with (tens to low hundreds of entries): cache-local, branch-predictor-
/// friendly, no allocator, no OOM error surface.
pub fn BoundedList(comptime T: type, comptime capacity: usize) type {
    return struct {
        items: [capacity]T = undefined,
        len: usize = 0,

        const Self = @This();

        pub fn slice(self: *Self) []T {
            return self.items[0..self.len];
        }

        pub fn constSlice(self: *const Self) []const T {
            return self.items[0..self.len];
        }

        /// Returns the index of the first item for which `match(context, item)`
        /// is true, or null if none matches. `context` is typically the search
        /// key (e.g. a window ID) and `match` a plain (non-closure) function,
        /// the same context+comptime-predicate shape `std.sort.pdq` uses.
        fn indexOf(
            self: *const Self,
            context: anytype,
            comptime match: fn (@TypeOf(context), T) bool,
        ) ?usize {
            for (self.items[0..self.len], 0..) |item, i| {
                if (match(context, item)) return i;
            }
            return null;
        }

        /// Returns the index of the first item whose `.id` field equals `id`,
        /// or null. For element types keyed by a single `id` field.
        pub fn indexOfById(self: *const Self, id: u32) ?usize {
            return self.indexOfByIdField(.id, id);
        }

        /// Returns the index of the first item whose field named `field_name`
        /// equals `id`, or null. Generic over the key field name.
        pub fn indexOfByIdField(
            self: *const Self,
            comptime field_name: std.meta.FieldEnum(T),
            id: u32,
        ) ?usize {
            return self.indexOf(id, struct {
                fn match(i: u32, item: T) bool {
                    return @field(item, @tagName(field_name)) == i;
                }
            }.match);
        }

        /// Returns the index of the first item equal to `scalar`, or null.
        /// For scalar element types (e.g. u32 window-ID lists).
        pub fn indexOfScalar(self: *const Self, scalar: T) ?usize {
            return self.indexOf(scalar, struct {
                fn match(s: T, item: T) bool {
                    return item == s;
                }
            }.match);
        }

        /// Appends `item` if there's room. Returns false and leaves the
        /// collection untouched if full; callers decide whether a full
        /// collection is worth a warning or a silent fallback.
        pub fn append(self: *Self, item: T) bool {
            if (self.len >= capacity) {
                if (std.debug.runtime_safety) {
                    debug.warn("BoundedList overflow: capacity={d}", .{capacity});
                }
                return false;
            }
            self.items[self.len] = item;
            self.len += 1;
            return true;
        }

        pub fn upsertById(
            self: *Self,
            comptime field_name: std.meta.FieldEnum(T),
            key: u32,
            item: T,
        ) bool {
            if (self.indexOfByIdField(field_name, key)) |i| {
                self.items[i] = item;
                return true;
            }
            return self.append(item);
        }

        /// O(1) removal that does *not* preserve the relative order of the
        /// remaining elements: the slot at `i` is filled with the current
        /// last element. Use when ordering carries no meaning (caches, sets).
        pub fn swapRemove(self: *Self, i: usize) void {
            self.len -= 1;
            self.items[i] = self.items[self.len];
        }

        /// O(n) removal that preserves the relative order of the remaining
        /// elements. Use when insertion order is meaningful, e.g. LIFO/FIFO
        /// replay.
        pub fn orderedRemove(self: *Self, i: usize) void {
            self.len -= 1;
            std.mem.copyForwards(T, self.items[i..self.len], self.items[i + 1 .. self.len + 1]);
        }

        /// Removes the first item matching `match`, order-preserving. pub for
        /// the plugin templates (a sample provider's per-window record
        /// cleanup) and the id-keyed form below.
        pub fn removeWhere(
            self: *Self,
            context: anytype,
            comptime match: fn (@TypeOf(context), T) bool,
        ) bool {
            if (self.indexOf(context, match)) |i| {
                self.orderedRemove(i);
                return true;
            }
            return false;
        }

        /// Removes the first item whose `field_name` equals `id` (order-
        /// preserving). The id-keyed form of `removeWhere` the record stores
        /// used to hand-roll via `item.win == key` match structs.
        pub fn removeById(self: *Self, comptime field_name: std.meta.FieldEnum(T), id: u32) bool {
            return self.removeWhere(id, struct {
                fn match(key: u32, item: T) bool {
                    return @field(item, @tagName(field_name)) == key;
                }
            }.match);
        }

        /// Removes every item whose `field_name` equals `id`, compacting in
        /// place (unordered). Used when several entries share one key (e.g.
        /// every child-window cache row pointing at the same toplevel).
        pub fn removeAllById(self: *Self, comptime field_name: std.meta.FieldEnum(T), id: u32) usize {
            return self.removeAllWhere(id, struct {
                fn match(key: u32, item: T) bool {
                    return @field(item, @tagName(field_name)) == key;
                }
            }.match);
        }

        fn removeAllWhere(
            self: *Self,
            context: anytype,
            comptime match: fn (@TypeOf(context), T) bool,
        ) usize {
            var removed: usize = 0;
            var i: usize = 0;
            while (i < self.len) {
                if (match(context, self.items[i])) {
                    self.swapRemove(i);
                    removed += 1;
                } else {
                    i += 1;
                }
            }
            return removed;
        }

        /// Inserts `item` at index `i` (clamped to len), shifting the tail
        /// right. Returns false (untouched) when full; true otherwise.
        pub fn insert(self: *Self, i: usize, item: T) bool {
            if (self.len >= capacity) return false;
            const idx = @min(i, self.len);
            self.len += 1;
            std.mem.copyBackwards(
                T,
                self.items[idx + 1 .. self.len],
                self.items[idx .. self.len - 1],
            );
            self.items[idx] = item;
            return true;
        }

        /// Resets to empty without touching capacity or contents of unused slots.
        pub fn clear(self: *Self) void {
            self.len = 0;
        }
    };
}

/// Bounded, allocation-free key-value collection with sorted-key binary
/// search. Parameterised by key type, value type, and a hard capacity
/// ceiling (stack-allocated arrays). Keys stay sorted at all times: get /
/// getPtr / has use O(log n) binary search; put and remove shift arrays to
/// keep sorted order. Single-threaded like BoundedList (event-loop thread).
/// Capacity is absolute: put returns error.StoreFull once full, no eviction.
///
/// The backing arrays are contiguous, so a *V from getPtr/put stays valid as
/// long as its key's slot does not move; slots move only on remove(k), a
/// wholesale reload, or inserting a NEW key before k (updating an existing
/// key rewrites in place).
pub fn Store(comptime K: type, comptime V: type, comptime capacity: usize) type {
    return struct {
        const Self = @This();

        keys: [capacity]K = undefined,
        vals: [capacity]V = undefined,
        len: usize = 0,

        fn exactAt(self: *const Self, k: K) ?usize {
            const pos = self.lowerBound(k);
            if (pos < self.len and self.keys[pos] == k) return pos;
            return null;
        }

        fn lowerBound(self: *const Self, k: K) usize {
            var lo: usize = 0;
            var hi: usize = self.len;
            while (lo < hi) {
                const mid = lo + (hi - lo) / 2;
                if (self.keys[mid] < k) {
                    lo = mid + 1;
                } else {
                    hi = mid;
                }
            }
            return lo;
        }

        pub fn getPtr(self: *Self, k: K) ?*V {
            if (self.exactAt(k)) |i| return &self.vals[i];
            return null;
        }

        pub fn get(self: *const Self, k: K) ?V {
            if (self.exactAt(k)) |i| return self.vals[i];
            return null;
        }

        pub fn has(self: *const Self, k: K) bool {
            return self.exactAt(k) != null;
        }

        pub fn put(self: *Self, k: K, v: V) error{StoreFull}!*V {
            // One lowerBound for both the in-place update and the insertion
            // position (exactAt would re-scan after the miss).
            const pos = self.lowerBound(k);
            if (pos < self.len and self.keys[pos] == k) {
                self.vals[pos] = v;
                return &self.vals[pos];
            }
            if (self.len == capacity) return error.StoreFull;
            std.mem.copyBackwards(K, self.keys[pos + 1 .. self.len + 1], self.keys[pos..self.len]);
            std.mem.copyBackwards(V, self.vals[pos + 1 .. self.len + 1], self.vals[pos..self.len]);
            self.keys[pos] = k;
            self.vals[pos] = v;
            self.len += 1;
            return &self.vals[pos];
        }

        /// Sorted-shift-remove: elements after `i` shift left to fill the gap.
        /// O(n); iteration order stays sorted-by-key.
        pub fn remove(self: *Self, k: K) bool {
            if (self.exactAt(k)) |i| {
                const last = self.len - 1;
                std.mem.copyForwards(K, self.keys[i..last], self.keys[i + 1 .. self.len]);
                std.mem.copyForwards(V, self.vals[i..last], self.vals[i + 1 .. self.len]);
                self.len = last;
                return true;
            }
            return false;
        }

        pub const Item = struct { key: K, val: *const V };

        /// Sorted-key row iterator: yields every stored (key, value) in order,
        /// so scans never hand-roll the `0..count()`/`, at(k)` bounds dance.
        /// The row pointer is valid until the store mutates (see the pointer
        /// contract on getPtr). Early-exit mid-iteration is safe.
        pub const Iterator = struct {
            store: *const Self,
            pos: usize = 0,
            pub fn next(self: *Iterator) ?Item {
                if (self.pos >= self.store.len) return null;
                const i = self.pos;
                self.pos += 1;
                return .{ .key = self.store.keys[i], .val = &self.store.vals[i] };
            }
        };
        pub fn iterator(self: *const Self) Iterator {
            return .{ .store = self };
        }

        /// Indexed accessor: `seq` beyond count() clamps to the
        /// last stored row (real check, not a debug-only assert), so an
        /// off-by-one index can't OOB the backing arrays in ReleaseFast.
        /// Empty map → row 0 of the fixed-capacity storage (always
        /// addressable, capacity >= 1).
        pub fn at(self: *const Self, seq: usize) Item {
            const idx = @min(seq, self.len -| 1);
            return .{ .key = self.keys[idx], .val = &self.vals[idx] };
        }

        pub fn count(self: *const Self) usize {
            return self.len;
        }

        /// Index of the entry keyed `k`, or null when absent.
        pub inline fn indexOf(self: *const Self, k: K) ?usize {
            return self.exactAt(k);
        }
    };
}
