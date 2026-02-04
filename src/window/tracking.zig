/// Efficient window tracking with both list and set

const std = @import("std");

pub const tracking = struct {
    list: std.ArrayList(u32),
    set: std.AutoHashMap(u32, void),
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator) tracking {
        return .{
            .list = .{},
            .set = std.AutoHashMap(u32, void).init(allocator),
            .allocator = allocator,
        };
    }
    
    pub fn deinit(self: *tracking) void {
        self.list.deinit(self.allocator);
        self.set.deinit();
    }
    
    pub inline fn contains(self: *const tracking, win: u32) bool {
        return self.set.contains(win);
    }
    
    pub fn add(self: *tracking, win: u32) !void {
        if (self.contains(win)) return;
        try self.list.append(self.allocator, win);
        try self.set.put(win, {});
    }
    
    // OPTIMIZATION: Improved addFront - use ensureUnusedCapacity to avoid reallocation
    pub fn addFront(self: *tracking, win: u32) !void {
        if (self.contains(win)) return;
        
        // OPTIMIZATION: Reserve space first to avoid multiple allocations
        try self.list.ensureUnusedCapacity(self.allocator, 1);
        
        // Shift elements manually for better performance
        const list_items = self.list.items;
        if (list_items.len > 0) {
            self.list.items.len += 1;
            var i: usize = list_items.len;
            while (i > 0) : (i -= 1) {
                self.list.items[i] = self.list.items[i - 1];
            }
            self.list.items[0] = win;
        } else {
            try self.list.append(self.allocator, win);
        }
        
        try self.set.put(win, {});
    }
    
    // OPTIMIZATION: Use orderedRemove when order matters, swapRemove when it doesn't
    pub fn remove(self: *tracking, win: u32) bool {
        if (!self.set.remove(win)) return false;
        
        if (std.mem.indexOfScalar(u32, self.list.items, win)) |idx| {
            _ = self.list.swapRemove(idx);
            return true;
        }
        return false;
    }
    
    // OPTIMIZATION: Add orderedRemove variant for when ordering matters
    pub fn removeOrdered(self: *tracking, win: u32) bool {
        if (!self.set.remove(win)) return false;
        
        if (std.mem.indexOfScalar(u32, self.list.items, win)) |idx| {
            _ = self.list.orderedRemove(idx);
            return true;
        }
        return false;
    }
    
    pub inline fn items(self: *const tracking) []const u32 {
        return self.list.items;
    }
    
    pub inline fn count(self: *const tracking) usize {
        return self.list.items.len;
    }
    
    pub inline fn clear(self: *tracking) void {
        self.list.clearRetainingCapacity();
        self.set.clearRetainingCapacity();
    }
    
    // OPTIMIZATION: Add method to get last item efficiently
    pub inline fn last(self: *const tracking) ?u32 {
        const items_slice = self.list.items;
        return if (items_slice.len > 0) items_slice[items_slice.len - 1] else null;
    }
    
    // OPTIMIZATION: Add method to get first item efficiently
    pub inline fn first(self: *const tracking) ?u32 {
        const items_slice = self.list.items;
        return if (items_slice.len > 0) items_slice[0] else null;
    }
};
