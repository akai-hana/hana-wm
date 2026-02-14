/// Efficient window tracking with small-array optimisation.
///
/// Storage strategy:
/// - Small (≤16 windows): fixed inline array — cache-friendly, zero allocations.
/// - Large  (>16 windows): ArrayList + HashSet for O(1) contains/remove.
///
/// A tagged union enforces that exactly one mode is active at all times.
/// The old two-optional design allowed the impossible state (both null / both
/// non-null) and caused items() to return a slice into a stack-allocated copy.

const std = @import("std");

const SMALL_THRESHOLD    = 16;
const DEMOTION_THRESHOLD = SMALL_THRESHOLD / 2;

const SmallStore = struct {
    items: [SMALL_THRESHOLD]u32 = [_]u32{0} ** SMALL_THRESHOLD,
    len:   u8 = 0,
};

const LargeStore = struct {
    list: std.ArrayListUnmanaged(u32),
    set:  std.AutoHashMap(u32, void),
};

const Storage = union(enum) { small: SmallStore, large: LargeStore };

pub const Tracking = struct {
    storage:   Storage,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) Tracking {
        return .{ .storage = .{ .small = .{} }, .allocator = allocator };
    }

    pub fn deinit(self: *Tracking) void {
        if (self.storage == .large) {
            self.storage.large.list.deinit(self.allocator);
            self.storage.large.set.deinit();
        }
    }

    /// O(n) for small (cache-friendly), O(1) for large.
    pub inline fn contains(self: *const Tracking, win: u32) bool {
        return switch (self.storage) {
            .small => |*s| std.mem.indexOfScalar(u32, s.items[0..s.len], win) != null,
            .large => |*l| l.set.contains(win),
        };
    }

    pub fn add(self: *Tracking, win: u32) !void {
        std.debug.assert(win != 0);
        if (self.contains(win)) return;
        switch (self.storage) {
            .small => |*s| {
                if (s.len < SMALL_THRESHOLD) {
                    s.items[s.len] = win;
                    s.len += 1;
                } else {
                    try self.promoteToLarge();
                    try self.storage.large.list.append(self.allocator, win);
                    try self.storage.large.set.put(win, {});
                }
            },
            .large => |*l| {
                try l.list.append(self.allocator, win);
                try l.set.put(win, {});
            },
        }
    }

    pub fn addFront(self: *Tracking, win: u32) !void {
        if (self.contains(win)) return;
        switch (self.storage) {
            .small => |*s| {
                if (s.len < SMALL_THRESHOLD) {
                    var i: u8 = s.len;
                    while (i > 0) : (i -= 1) s.items[i] = s.items[i - 1];
                    s.items[0] = win;
                    s.len += 1;
                } else {
                    try self.promoteToLarge();
                    try self.storage.large.list.insert(self.allocator, 0, win);
                    try self.storage.large.set.put(win, {});
                }
            },
            .large => |*l| {
                try l.list.insert(self.allocator, 0, win);
                try l.set.put(win, {});
            },
        }
    }

    /// Ordered removal (preserves window order — use this by default).
    pub fn remove(self: *Tracking, win: u32) bool {
        return self.removeImpl(win, true);
    }

    /// Unordered removal (swap-remove — use when order is irrelevant).
    pub fn removeUnordered(self: *Tracking, win: u32) bool {
        return self.removeImpl(win, false);
    }

    fn removeImpl(self: *Tracking, win: u32, comptime ordered: bool) bool {
        switch (self.storage) {
            .small => |*s| {
                for (s.items[0..s.len], 0..) |w, i| {
                    if (w != win) continue;
                    var j: u8 = @intCast(i);
                    while (j < s.len - 1) : (j += 1) s.items[j] = s.items[j + 1];
                    s.len -= 1;
                    return true;
                }
                return false;
            },
            .large => |*l| {
                if (!l.set.remove(win)) return false;
                const idx = std.mem.indexOfScalar(u32, l.list.items, win) orelse return false;
                if (ordered) _ = l.list.orderedRemove(idx) else _ = l.list.swapRemove(idx);
                // Capture the condition before demoteToSmall() invalidates `l`.
                if (l.list.items.len <= DEMOTION_THRESHOLD) self.demoteToSmall();
                return true;
            },
        }
    }

    /// Returns a slice into Tracking's own storage — valid for the lifetime of self.
    pub inline fn items(self: *const Tracking) []const u32 {
        return switch (self.storage) {
            .small => |*s| s.items[0..s.len],
            .large => |*l| l.list.items,
        };
    }

    pub inline fn count(self: *const Tracking) usize {
        return switch (self.storage) {
            .small => |s| s.len,
            .large => |*l| l.list.items.len,
        };
    }

    pub inline fn clear(self: *Tracking) void {
        switch (self.storage) {
            .small => |*s| s.len = 0,
            .large => |*l| {
                l.list.clearRetainingCapacity();
                l.set.clearRetainingCapacity();
            },
        }
    }

    pub inline fn first(self: *const Tracking) ?u32 {
        const s = self.items();
        return if (s.len > 0) s[0] else null;
    }

    pub inline fn last(self: *const Tracking) ?u32 {
        const s = self.items();
        return if (s.len > 0) s[s.len - 1] else null;
    }

    fn promoteToLarge(self: *Tracking) !void {
        const s = self.storage.small;
        var list: std.ArrayListUnmanaged(u32) = .empty;
        var set = std.AutoHashMap(u32, void).init(self.allocator);
        try list.ensureTotalCapacity(self.allocator, s.len + 8);
        try set.ensureTotalCapacity(s.len + 8);
        for (s.items[0..s.len]) |win| {
            list.appendAssumeCapacity(win);
            try set.put(win, {});
        }
        self.storage = .{ .large = .{ .list = list, .set = set } };
    }

    fn demoteToSmall(self: *Tracking) void {
        const l = &self.storage.large;
        if (l.list.items.len > SMALL_THRESHOLD) return;
        var small: SmallStore = .{};
        small.len = @intCast(l.list.items.len);
        @memcpy(small.items[0..small.len], l.list.items);
        l.list.deinit(self.allocator);
        l.set.deinit();
        self.storage = .{ .small = small };
    }
};
