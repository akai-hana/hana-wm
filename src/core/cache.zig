//! Unified caching layer for bar system
//! Centralizes all caching mechanisms with smart invalidation

const std = @import("std");
const defs = @import("defs");
const drawing = @import("drawing");

/// RGB color representation for caching
pub const RGBColor = struct {
    r: f64,
    g: f64,
    b: f64,
};

/// Key for segment width cache
const SegmentKey = struct {
    segment: defs.BarSegment,
    config_hash: u64,
    
    pub fn hash(self: SegmentKey) u64 {
        var h = std.hash.Wyhash.init(0);
        h.update(std.mem.asBytes(&self.segment));
        h.update(std.mem.asBytes(&self.config_hash));
        return h.final();
    }
};

/// Workspace label cache entry
pub const WorkspaceLabelCache = struct {
    label_widths: [20]u16 = [_]u16{0} ** 20,
    valid: bool = false,
    
    pub fn invalidate(self: *WorkspaceLabelCache) void {
        self.valid = false;
    }
};

/// Cache type for selective invalidation
pub const CacheType = enum {
    layout,
    colors,
    widths,
    all,
};

/// Centralized cache manager
pub const CacheManager = struct {
    allocator: std.mem.Allocator,
    
    // Color conversion cache
    colors: std.AutoHashMap(u32, RGBColor),
    
    // Workspace label widths cache
    workspace_labels: WorkspaceLabelCache,
    
    // Configuration hash for detecting config changes
    last_config_hash: u64,
    
    dirty_flags: struct {
        layout: bool = true,
        colors: bool = true,
        widths: bool = true,
    },
    
    pub fn init(allocator: std.mem.Allocator) !*CacheManager {
        const cm = try allocator.create(CacheManager);
        cm.* = .{
            .allocator = allocator,
            .colors = std.AutoHashMap(u32, RGBColor).init(allocator),
            .workspace_labels = .{},
            .last_config_hash = 0,
            .dirty_flags = .{},
        };
        return cm;
    }
    
    pub fn deinit(self: *CacheManager) void {
        self.colors.deinit();
        self.allocator.destroy(self);
    }
    
    /// Mark specific cache as dirty
    pub fn markDirty(self: *CacheManager, cache_type: CacheType) void {
        switch (cache_type) {
            .layout => {
                self.dirty_flags.layout = true;
            },
            .colors => {
                self.dirty_flags.colors = true;
                self.colors.clearRetainingCapacity();
            },
            .widths => {
                self.dirty_flags.widths = true;
                self.workspace_labels.invalidate();
            },
            .all => {
                self.dirty_flags = .{ .layout = true, .colors = true, .widths = true };
                self.clearAll();
            },
        }
    }
    
    /// Clear all caches
    pub fn clearAll(self: *CacheManager) void {
        self.colors.clearRetainingCapacity();
        self.workspace_labels.invalidate();
        self.last_config_hash = 0;
    }
    
    /// Get cached RGB color or compute and cache it
    pub fn getColor(self: *CacheManager, color: u32) !RGBColor {
        if (self.colors.get(color)) |rgb| return rgb;
        
        const rgb = RGBColor{
            .r = @as(f64, @floatFromInt((color >> 16) & 0xFF)) / 255.0,
            .g = @as(f64, @floatFromInt((color >> 8) & 0xFF)) / 255.0,
            .b = @as(f64, @floatFromInt(color & 0xFF)) / 255.0,
        };
        
        try self.colors.put(color, rgb);
        return rgb;
    }
    
    /// Update workspace label cache if invalid
    pub fn updateWorkspaceLabels(self: *CacheManager, dc: *drawing.DrawContext, config: *const defs.BarConfig) !void {
        if (self.workspace_labels.valid) return;
        
        const static_numbers = [_][]const u8{ "1", "2", "3", "4", "5", "6", "7", "8", "9", "10" };
        
        for (&self.workspace_labels.label_widths, 0..) |*width, i| {
            const label = if (i < config.workspace_icons.items.len)
                config.workspace_icons.items[i]
            else if (i < static_numbers.len)
                static_numbers[i]
            else
                "?";
            width.* = dc.textWidth(label);
        }
        
        self.workspace_labels.valid = true;
    }
    
    /// Get cached workspace label width
    pub fn getWorkspaceLabelWidth(self: *CacheManager, index: usize) u16 {
        if (!self.workspace_labels.valid or index >= 20) return 0;
        return self.workspace_labels.label_widths[index];
    }
    
    /// Compute simple hash of configuration for change detection
    pub fn computeConfigHash(config: *const defs.BarConfig) u64 {
        var h = std.hash.Wyhash.init(0);
        h.update(std.mem.asBytes(&config.bg));
        h.update(std.mem.asBytes(&config.fg));
        h.update(std.mem.asBytes(&config.font_size));
        h.update(std.mem.asBytes(&config.padding));
        h.update(std.mem.asBytes(&config.segment_spacing));
        // Add more fields as needed for cache invalidation
        return h.final();
    }
    
    /// Check if config has changed and invalidate caches if needed
    pub fn checkConfigChange(self: *CacheManager, config: *const defs.BarConfig) void {
        const new_hash = computeConfigHash(config);
        if (new_hash != self.last_config_hash) {
            self.markDirty(.all);
            self.last_config_hash = new_hash;
        }
    }
};
