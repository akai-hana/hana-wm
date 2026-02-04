/// Configuration validation and sanitization
/// Prevents runtime crashes from invalid configuration values

const std = @import("std");
const defs = @import("defs");

pub const ValidationError = error{
    InvalidMasterWidth,
    InvalidBorderWidth,
    InvalidGaps,
    InvalidWorkspaceCount,
};

pub const ValidationResult = struct {
    valid: bool,
    warnings: std.ArrayList([]const u8),
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator) ValidationResult {
        return .{
            .valid = true,
            .warnings = .{},
            .allocator = allocator,
        };
    }
    
    pub fn deinit(self: *ValidationResult) void {
        for (self.warnings.items) |warn| {
            self.allocator.free(warn);
        }
        self.warnings.deinit(self.allocator);
    }
    
    pub fn addWarning(self: *ValidationResult, warning: []const u8) !void {
        const owned = try self.allocator.dupe(u8, warning);
        try self.warnings.append(self.allocator, owned);
    }
};

/// Validate and sanitize configuration
/// Clamps values to safe ranges and logs warnings
pub fn validateAndSanitize(config: *defs.Config, allocator: std.mem.Allocator) !ValidationResult {
    var result = ValidationResult.init(allocator);
    
    // Validate master width factor
    if (config.tiling.master_width_factor < defs.MIN_MASTER_WIDTH or
        config.tiling.master_width_factor > defs.MAX_MASTER_WIDTH) {
        
        var buf: [256]u8 = undefined;
        const msg = try std.fmt.bufPrint(&buf,
            "master_width_factor {d:.2} out of range [{d:.2}, {d:.2}], clamping",
            .{ config.tiling.master_width_factor, defs.MIN_MASTER_WIDTH, defs.MAX_MASTER_WIDTH });
        try result.addWarning(msg);
        
        config.tiling.master_width_factor = std.math.clamp(
            config.tiling.master_width_factor,
            defs.MIN_MASTER_WIDTH,
            defs.MAX_MASTER_WIDTH
        );
    }
    
    // Validate border width
    if (config.tiling.border_width > defs.MAX_BORDER_WIDTH) {
        var buf: [256]u8 = undefined;
        const msg = try std.fmt.bufPrint(&buf,
            "border_width {} exceeds maximum {}, clamping",
            .{ config.tiling.border_width, defs.MAX_BORDER_WIDTH });
        try result.addWarning(msg);
        config.tiling.border_width = defs.MAX_BORDER_WIDTH;
    }
    
    // Validate gaps
    if (config.tiling.gaps > defs.MAX_GAPS) {
        var buf: [256]u8 = undefined;
        const msg = try std.fmt.bufPrint(&buf,
            "gaps {} exceeds maximum {}, clamping",
            .{ config.tiling.gaps, defs.MAX_GAPS });
        try result.addWarning(msg);
        config.tiling.gaps = defs.MAX_GAPS;
    }
    
    // Validate workspace count
    if (config.workspaces.count < defs.MIN_WORKSPACES or
        config.workspaces.count > defs.MAX_WORKSPACES) {
        
        var buf: [256]u8 = undefined;
        const msg = try std.fmt.bufPrint(&buf,
            "workspace count {} out of range [{}, {}], clamping",
            .{ config.workspaces.count, defs.MIN_WORKSPACES, defs.MAX_WORKSPACES });
        try result.addWarning(msg);
        
        config.workspaces.count = std.math.clamp(
            config.workspaces.count,
            defs.MIN_WORKSPACES,
            defs.MAX_WORKSPACES
        );
    }
    
    // Validate master count is at least 1
    if (config.tiling.master_count < 1) {
        var buf: [256]u8 = undefined;
        const msg = try std.fmt.bufPrint(&buf,
            "master_count cannot be 0, setting to 1", .{});
        try result.addWarning(msg);
        config.tiling.master_count = 1;
    }
    
    return result;
}

/// Log all validation warnings
pub fn logWarnings(result: *const ValidationResult) void {
    if (result.warnings.items.len > 0) {
        std.log.warn("[config] Configuration validation warnings:", .{});
        for (result.warnings.items) |warning| {
            std.log.warn("  - {s}", .{warning});
        }
    }
}
