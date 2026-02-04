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
    
    pub fn addFront(self: *tracking, win: u32) !void {
        if (self.contains(win)) return;
        try self.list.insert(self.allocator, 0, win);
        try self.set.put(win, {});
    }
    
    // OPTIMIZATION: Use std.mem.indexOfScalar for cleaner code
    pub fn remove(self: *tracking, win: u32) bool {
        if (!self.set.remove(win)) return false;
        
        if (std.mem.indexOfScalar(u32, self.list.items, win)) |idx| {
            _ = self.list.swapRemove(idx);
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
};
