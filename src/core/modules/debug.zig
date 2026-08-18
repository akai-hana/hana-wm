//! Debug logging and error helpers
//!
//! `info` is compiled away in non-debug builds (verbose runtime tracing).
//! `warn`/`err`/`logError`/`warnOnErr` always emit regardless of build mode:
//! they carry user-facing diagnostics, config validation feedback ("value out
//! of range, using default"), load failures, non-fatal runtime errors, that
//! must reach the user in release builds too, where they are otherwise the
//! only explanation for behaviour the user didn't ask for. A silent
//! ReleaseFast fallback to config defaults with no message would be a bug.

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

inline fn infoEnabled() bool {
    return build.enable_debug_logging;
}

// Routed through std.log (rather than std.debug.print with hardcoded ANSI
// codes) so custom log handlers and compile-time log-level filtering still
// apply.
inline fn log(comptime log_fn: anytype, comptime fmt: []const u8, module: []const u8, args: anytype) void {
    log_fn("[{s}] " ++ fmt, .{module} ++ args);
}

pub inline fn err(comptime fmt: []const u8, args: anytype) void {
    log(std.log.err, fmt, moduleFromSrc(@src()), args);
}
pub inline fn warn(comptime fmt: []const u8, args: anytype) void {
    log(std.log.warn, fmt, moduleFromSrc(@src()), args);
}
pub inline fn info(comptime fmt: []const u8, args: anytype) void {
    if (!infoEnabled()) return;
    log(std.log.info, fmt, moduleFromSrc(@src()), args);
}

/// Log a structured error with an optional window ID for context.
/// Use this as the canonical pattern for operation failures:
///
///   s.windows.add(win) catch |e| { debug.logError(e, win); return; };
///   StateManager.init(...) catch |e| { debug.logError(e, null); return; };
pub inline fn logError(e: anyerror, window: ?u32) void {
    if (window) |win| {
        log(std.log.err, "Failed: {} (window: 0x{x})", moduleFromSrc(@src()), .{ e, win });
    } else {
        log(std.log.err, "Failed: {}", moduleFromSrc(@src()), .{e});
    }
}

/// Log a warning for a best-effort operation whose failure is non-fatal.
/// Use instead of bare `catch {}` when visibility in debug builds is useful:
///
///   self.geometry_cache.put(win, rect) catch |e| debug.warnOnErr(e, "geometry cache");
///
/// Truly inconsequential capacity hints (ensureTotalCapacity etc.) may keep
/// bare `catch {}`; they produce no actionable diagnostic information.
pub inline fn warnOnErr(e: anyerror, comptime context: []const u8) void {
    log(std.log.warn, "Best-effort op failed (" ++ context ++ "): {}", moduleFromSrc(@src()), .{e});
}
