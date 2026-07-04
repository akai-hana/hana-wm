//! Debug logging and error helpers
//! Provides logging utilities that are compiled away entirely in non-debug builds.

const std = @import("std");
const build = @import("build_options");

/// Strips the directory and ".zig" extension from a source file path, returning a short module tag.
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
// Use std.log.info so that all log levels go through the same handler
// (respecting any custom log handler the embedder installs and compile-time
// log-level filtering). Previously this used std.debug.print with hardcoded
// ANSI escape codes, which bypassed log routing entirely.
pub inline fn info(comptime fmt: []const u8, args: anytype) void {
    if (!debugEnabled()) return;
    const module = moduleFromSrc(@src());
    std.log.info("[{s}] " ++ fmt, .{module} ++ args);
}
pub inline fn debug(comptime fmt: []const u8, args: anytype) void {
    if (!debugEnabled()) return;
    const module = moduleFromSrc(@src());
    std.log.debug("[{s}] " ++ fmt, .{module} ++ args);
}

/// Panics with a module-tagged message when `condition` is false, in debug builds only.
pub inline fn assert(condition: bool, comptime message: []const u8) void {
    if (!debugEnabled() or condition) return;
    const module = moduleFromSrc(@src());
    std.debug.panic("[{s}] Assertion failed: {s}", .{ module, message });
}

/// Emits a debug-level line showing `label = value` with the caller's module tag.
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
