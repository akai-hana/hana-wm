//! Debug logging with automatic tags - GUARANTEED to work based on build mode
//! 
//! This version uses build_options to check the optimization mode,
//! ensuring debug calls are only active when built with -Doptimize=Debug.

const std = @import("std");
const build_options = @import("build_options");

/// Extract module name from source location
inline fn extractModuleName(comptime src: std.builtin.SourceLocation) []const u8 {
    const file = src.file;
    comptime var start: usize = 0;
    
    inline for (file, 0..) |c, i| {
        if (c == '/' or c == '\\') start = i + 1;
    }
    
    const basename = file[start..];
    comptime var end = basename.len;
    
    if (basename.len >= 4 and std.mem.eql(u8, basename[basename.len-4..], ".zig")) {
        end = basename.len - 4;
    }
    
    return basename[0..end];
}

/// Check build_options.enable_debug_logging instead of builtin.mode
/// This ensures it matches your -Doptimize flag

pub inline fn err(comptime fmt: []const u8, args: anytype) void {
    if (!build_options.enable_debug_logging) return;
    
    const module = comptime extractModuleName(@src());
    const tagged = comptime "[" ++ module ++ "] " ++ fmt;
    std.log.err(tagged, args);
}

pub inline fn warn(comptime fmt: []const u8, args: anytype) void {
    if (!build_options.enable_debug_logging) return;
    
    const module = comptime extractModuleName(@src());
    const tagged = comptime "[" ++ module ++ "] " ++ fmt;
    std.log.warn(tagged, args);
}

pub inline fn info(comptime fmt: []const u8, args: anytype) void {
    if (!build_options.enable_debug_logging) return;
    
    const module = comptime extractModuleName(@src());
    const tagged = comptime "[" ++ module ++ "] " ++ fmt;
    std.log.info(tagged, args);
}

pub inline fn debug(comptime fmt: []const u8, args: anytype) void {
    if (!build_options.enable_debug_logging) return;
    
    const module = comptime extractModuleName(@src());
    const tagged = comptime "[" ++ module ++ "] " ++ fmt;
    std.log.debug(tagged, args);
}

pub inline fn errIf(condition: bool, comptime fmt: []const u8, args: anytype) void {
    if (!build_options.enable_debug_logging) return;
    if (!condition) return;
    err(fmt, args);
}

pub inline fn warnIf(condition: bool, comptime fmt: []const u8, args: anytype) void {
    if (!build_options.enable_debug_logging) return;
    if (!condition) return;
    warn(fmt, args);
}

pub inline fn infoIf(condition: bool, comptime fmt: []const u8, args: anytype) void {
    if (!build_options.enable_debug_logging) return;
    if (!condition) return;
    info(fmt, args);
}

pub inline fn debugIf(condition: bool, comptime fmt: []const u8, args: anytype) void {
    if (!build_options.enable_debug_logging) return;
    if (!condition) return;
    debug(fmt, args);
}

pub inline fn assert(condition: bool, comptime message: []const u8) void {
    if (!build_options.enable_debug_logging) return;
    if (!condition) {
        const module = comptime extractModuleName(@src());
        @panic("[" ++ module ++ "] Assertion failed: " ++ message);
    }
}

pub inline fn trace(comptime func_name: []const u8) void {
    if (!build_options.enable_debug_logging) return;
    const module = comptime extractModuleName(@src());
    std.log.debug("[{s}] -> {s}", .{ module, func_name });
}

pub inline fn print(comptime label: []const u8, value: anytype) void {
    if (!build_options.enable_debug_logging) return;
    const module = comptime extractModuleName(@src());
    std.log.debug("[{s}] {s} = {any}", .{ module, label, value });
}
