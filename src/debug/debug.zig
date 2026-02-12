//! Debug logging with automatic tags
//! Using build_options to check optimization mode,
//! for debug calls to only be active when built with -Doptimize=Debug.

const std = @import("std");
const build_options = @import("build_options");

/// Extract module name from source location
fn getModuleName() []const u8 {
    const src = @src();
    const file = src.file;
    var start: usize = 0;
    for (file, 0..) |c, i| {
        if (c == '/' or c == '\\') start = i + 1;
    }
    const basename = file[start..];
    var end = basename.len;
    if (basename.len >= 4 and std.mem.eql(u8, basename[basename.len-4..], ".zig")) {
        end = basename.len - 4;
    }
    return basename[0..end];
}

/// Check if debug logging is enabled
inline fn debug_enabled() bool {
    return build_options.enable_debug_logging;
}

pub inline fn err(comptime fmt: []const u8, args: anytype) void {
    if (!debug_enabled()) return;
    const module = getModuleName();
    std.log.err("[" ++ module ++ "] " ++ fmt, args);
}

pub inline fn warn(comptime fmt: []const u8, args: anytype) void {
    if (!debug_enabled()) return;
    const module = getModuleName();
    std.log.warn("[" ++ module ++ "] " ++ fmt, args);
}

pub inline fn info(comptime fmt: []const u8, args: anytype) void {
    if (!debug_enabled()) return;
    const module = getModuleName();
    std.log.info("[" ++ module ++ "] " ++ fmt, args);
}

pub inline fn debug(comptime fmt: []const u8, args: anytype) void {
    if (!debug_enabled()) return;
    const module = getModuleName();
    std.log.debug("[" ++ module ++ "] " ++ fmt, args);
}

pub inline fn errIf(condition: bool, comptime fmt: []const u8, args: anytype) void {
    if (!debug_enabled() or !condition) return;
    const module = getModuleName();
    std.log.err("[" ++ module ++ "] " ++ fmt, args);
}

pub inline fn warnIf(condition: bool, comptime fmt: []const u8, args: anytype) void {
    if (!debug_enabled() or !condition) return;
    const module = getModuleName();
    std.log.warn("[" ++ module ++ "] " ++ fmt, args);
}

pub inline fn infoIf(condition: bool, comptime fmt: []const u8, args: anytype) void {
    if (!debug_enabled() or !condition) return;
    const module = getModuleName();
    std.log.info("[" ++ module ++ "] " ++ fmt, args);
}

pub inline fn debugIf(condition: bool, comptime fmt: []const u8, args: anytype) void {
    if (!debug_enabled() or !condition) return;
    const module = getModuleName();
    std.log.debug("[" ++ module ++ "] " ++ fmt, args);
}

pub inline fn assert(condition: bool, comptime message: []const u8) void {
    if (!debug_enabled() or condition) return;
    const module = getModuleName();
    @panic("[" ++ module ++ "] Assertion failed: " ++ message);
}

pub inline fn trace(comptime func_name: []const u8) void {
    if (!debug_enabled()) return;
    const module = getModuleName();
    std.log.debug("[{s}] -> {s}", .{ module, func_name });
}

pub inline fn print(comptime label: []const u8, value: anytype) void {
    if (!debug_enabled()) return;
    const module = getModuleName();
    std.log.debug("[{s}] {s} = {any}", .{ module, label, value });
}

