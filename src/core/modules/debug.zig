
//! Debug logging and error helpers.
//!
//! All functions are no-ops in non-debug builds (controlled by the
//! `enable_debug_logging` build option). Because they are `inline`, @src()
//! inside each function captures the *call site* source location, so the
//! module tag printed in log output is always the caller's file, not debug.zig.

const std   = @import("std");
const build = @import("build_options");


fn moduleFromSrc(src: std.builtin.SourceLocation) []const u8 {
    const basename = std.fs.path.basename(src.file);
    return if (std.mem.endsWith(u8, basename, ".zig"))
        basename[0 .. basename.len - 4]
    else
        basename;
}

inline fn debugEnabled() bool {
    return build.enable_debug_logging;
}

pub inline fn err(comptime fmt: []const u8, args: anytype) void {
    if (!debugEnabled()) return;
    const module = moduleFromSrc(@src());
    std.log.err("[{s}] " ++ fmt, .{module} ++ args);
}

pub inline fn warn(comptime fmt: []const u8, args: anytype) void {
    if (!debugEnabled()) return;
    const module = moduleFromSrc(@src());
    std.log.warn("[{s}] " ++ fmt, .{module} ++ args);
}

pub inline fn info(comptime fmt: []const u8, args: anytype) void {
    if (!debugEnabled()) return;
    const module = moduleFromSrc(@src());
    std.debug.print("\x1b[32m[{s}]\x1b[0m " ++ fmt ++ "\n", .{module} ++ args);
}

pub inline fn debug(comptime fmt: []const u8, args: anytype) void {
    if (!debugEnabled()) return;
    const module = moduleFromSrc(@src());
    std.log.debug("[{s}] " ++ fmt, .{module} ++ args);
}

pub inline fn errIf(condition: bool, comptime fmt: []const u8, args: anytype) void {
    if (!debugEnabled() or !condition) return;
    const module = moduleFromSrc(@src());
    std.log.err("[{s}] " ++ fmt, .{module} ++ args);
}

pub inline fn warnIf(condition: bool, comptime fmt: []const u8, args: anytype) void {
    if (!debugEnabled() or !condition) return;
    const module = moduleFromSrc(@src());
    std.log.warn("[{s}] " ++ fmt, .{module} ++ args);
}

pub inline fn infoIf(condition: bool, comptime fmt: []const u8, args: anytype) void {
    if (!debugEnabled() or !condition) return;
    const module = moduleFromSrc(@src());
    std.debug.print("\x1b[32m[{s}]\x1b[0m " ++ fmt ++ "\n", .{module} ++ args);
}

pub inline fn debugIf(condition: bool, comptime fmt: []const u8, args: anytype) void {
    if (!debugEnabled() or !condition) return;
    const module = moduleFromSrc(@src());
    std.log.debug("[{s}] " ++ fmt, .{module} ++ args);
}

pub inline fn assert(condition: bool, comptime message: []const u8) void {
    if (!debugEnabled() or condition) return;
    const module = moduleFromSrc(@src());
    std.debug.panic("[{s}] Assertion failed: {s}", .{ module, message });
}

pub inline fn trace(comptime func_name: []const u8) void {
    if (!debugEnabled()) return;
    const module = moduleFromSrc(@src());
    std.log.debug("[{s}] -> {s}", .{ module, func_name });
}

pub inline fn print(comptime label: []const u8, value: anytype) void {
    if (!debugEnabled()) return;
    const module = moduleFromSrc(@src());
    std.log.debug("[{s}] {s} = {any}", .{ module, label, value });
}

/// Log a structured error with an optional window ID for context.
/// Use this as the canonical pattern for operation failures:
///
///   s.windows.add(win) catch |e| { debug.logError(e, win); return; };
///   StateManager.init(...) catch |e| { debug.logError(e, null); return; };
pub inline fn logError(e: anyerror, window: ?u32) void {
    if (!debugEnabled()) return;
    if (window) |win| {
        std.log.err("[error] Failed: {} (window: 0x{x})", .{ e, win });
    } else {
        std.log.err("[error] Failed: {}", .{e});
    }
}

/// Log a warning for a best-effort operation whose failure is non-fatal.
/// Use instead of bare `catch {}` when visibility in debug builds is useful:
///
///   self.geometry_cache.put(win, rect) catch |e| debug.warnOnErr(e, "geometry cache");
///
/// Truly inconsequential capacity hints (ensureTotalCapacity etc.) may keep
/// bare `catch {}` — they produce no actionable diagnostic information.
pub inline fn warnOnErr(e: anyerror, comptime context: []const u8) void {
    if (!debugEnabled()) return;
    std.log.warn("[warn] Best-effort op failed (" ++ context ++ "): {}", .{e});
}
