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

/// Generic validation and clamping function
/// Reduces code duplication while maintaining clarity
fn validateAndClamp(
    comptime T: type,
    value: *T,
    min: T,
    max: T,
    name: []const u8,
    result: *ValidationResult,
) !void {
    if (value.* < min or value.* > max) {
        var buf: [256]u8 = undefined;
        const msg = switch (T) {
            f32 => try std.fmt.bufPrint(&buf,
                "{s} {d:.2} out of range [{d:.2}, {d:.2}], clamping",
                .{ name, value.*, min, max }),
            else => try std.fmt.bufPrint(&buf,
                "{s} {} out of range [{}, {}], clamping",
                .{ name, value.*, min, max }),
        };
        try result.addWarning(msg);
        value.* = std.math.clamp(value.*, min, max);
    }
}

/// Validate and sanitize configuration
/// Clamps values to safe ranges and logs warnings
pub fn validateAndSanitize(config: *defs.Config, allocator: std.mem.Allocator) !ValidationResult {
    var result = ValidationResult.init(allocator);
    
    // Validate all numeric ranges using generic function
    try validateAndClamp(f32, &config.tiling.master_width_factor,
        defs.MIN_MASTER_WIDTH, defs.MAX_MASTER_WIDTH, "master_width_factor", &result);
    
    try validateAndClamp(u16, &config.tiling.border_width,
        0, defs.MAX_BORDER_WIDTH, "border_width", &result);
    
    try validateAndClamp(u16, &config.tiling.gaps,
        0, defs.MAX_GAPS, "gaps", &result);
    
    try validateAndClamp(usize, &config.workspaces.count,
        defs.MIN_WORKSPACES, defs.MAX_WORKSPACES, "workspace_count", &result);
    
    // Special case: master_count has minimum of 1 (no maximum)
    if (config.tiling.master_count < 1) {
        try result.addWarning("master_count cannot be 0, setting to 1");
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
