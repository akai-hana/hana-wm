// Simplified logging.zig - Remove redundant wrapper functions
const std = @import("std");
const builtin = @import("builtin");
const colors = @import("colors");

// CORE PATTERN: Use std.log directly instead of wrappers
// Replace all debugPrint() calls with std.log.debug()
// Replace all specific debug functions with direct std.log calls

// Example transformation:
// OLD:
// pub fn debugWindowModuleInit() void {
//     debugPrint("[window] Module initialized\n", .{});
// }
// 
// NEW - just use directly in code:
// std.log.debug("[window] Module initialized", .{});

// Keep only the generic helper for conditional compilation
pub inline fn isDebug() bool {
    return builtin.mode == .Debug;
}

// Single unified logging function for formatted output with colors
pub fn logColored(
    comptime level: std.log.Level,
    comptime color: []const u8,
    comptime fmt: []const u8,
    args: anytype
) void {
    const prefix = switch (level) {
        .err => "ERROR",
        .warn => "WARN",
        .info => "INFO",
        .debug => "DEBUG",
    };
    std.log.scoped(.hana).log(
        level,
        color ++ "[" ++ prefix ++ "]" ++ colors.RESET ++ " " ++ fmt,
        args
    );
}

// Specialized validators that return bool for inline usage
pub fn validateRange(
    comptime T: type,
    value: T,
    min: T,
    max: T,
    comptime field: []const u8,
) bool {
    if (value < min or value > max) {
        std.log.warn("[config] {s} {} out of range ({}-{})", .{field, value, min, max});
        return false;
    }
    return true;
}

pub fn validateColor(color: u32, comptime field: []const u8) bool {
    if (color > 0xFFFFFF) {
        std.log.warn("[config] {s} 0x{x} exceeds RGB range", .{field, color});
        return false;
    }
    return true;
}
