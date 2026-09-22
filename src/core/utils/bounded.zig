//! Bounded collections.
//!
//! Shared shape used by the window module's caches, the minimize module's
//! minimized-window record, and the spawn module's pending-spawn table: a
//! fixed-capacity array plus a length, with linear-scan find, append, and
//! remove-and-compact.
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

        pub fn removeAllWhere(
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
