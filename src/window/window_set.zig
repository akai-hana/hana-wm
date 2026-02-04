/// Efficient window tracking with both list and set
/// Replaces duplicate code in workspaces and tiling modules

const std = @import("std");

/// Dual data structure for efficient window tracking
/// Maintains both ordered list and hash set for O(1) lookups
pub const WindowSet = struct {
    list: std.ArrayList(u32),
    set: std.AutoHashMap(u32, void),
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator) WindowSet {
        return .{
            .list = .{},
            .set = std.AutoHashMap(u32, void).init(allocator),
            .allocator = allocator,
        };
    }
    
    pub fn deinit(self: *WindowSet) void {
        self.list.deinit(self.allocator);
        self.set.deinit();
    }
    
    pub inline fn contains(self: *const WindowSet, win: u32) bool {
        return self.set.contains(win);
    }
    
    /// Add window to end of list
    pub fn add(self: *WindowSet, win: u32) !void {
        if (self.contains(win)) return;
        try self.list.append(self.allocator, win);
        try self.set.put(win, {});
    }
    
    /// Add window to front of list (for focus ordering)
    pub fn addFront(self: *WindowSet, win: u32) !void {
        if (self.contains(win)) return;
        try self.list.insert(self.allocator, 0, win);
        try self.set.put(win, {});
    }
    
    /// Remove window from both structures
    /// Returns true if window was found and removed
    pub fn remove(self: *WindowSet, win: u32) bool {
        if (!self.set.remove(win)) return false;
        
        for (self.list.items, 0..) |w, i| {
            if (w == win) {
                _ = self.list.swapRemove(i);
                return true;
            }
        }
        return false;
    }
    
    pub inline fn items(self: *const WindowSet) []const u32 {
        return self.list.items;
    }
    
    pub inline fn count(self: *const WindowSet) usize {
        return self.list.items.len;
    }
    
    pub fn clear(self: *WindowSet) void {
        self.list.clearRetainingCapacity();
        self.set.clearRetainingCapacity();
    }
};
