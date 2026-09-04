//! Debug logging and error helpers.
//! User-facing diagnostics and verbose tracing, routed through std.log.

const std = @import("std");

// Extracts the bare filename without ".zig" extension so the module tag is
// short enough for log lines like "[module] message".
inline fn moduleFromSrc(src: std.builtin.SourceLocation) []const u8 {
    const basename = std.fs.path.basename(src.file);
    return if (std.mem.endsWith(u8, basename, ".zig"))
        basename[0 .. basename.len - 4]
    else
        basename;
}

// Routed through std.log (rather than std.debug.print with hardcoded ANSI
// codes) so custom log handlers and compile-time log-level filtering still
// apply.
inline fn log(
    comptime log_fn: anytype,
    comptime fmt: []const u8,
    module: []const u8,
    args: anytype,
) void {
    log_fn("[{s}] " ++ fmt, .{module} ++ args);
}

pub inline fn err(comptime fmt: []const u8, args: anytype) void {
    log(std.log.err, fmt, moduleFromSrc(@src()), args);
}
pub inline fn warn(comptime fmt: []const u8, args: anytype) void {
    log(std.log.warn, fmt, moduleFromSrc(@src()), args);
}
pub inline fn info(comptime fmt: []const u8, args: anytype) void {
    log(std.log.info, fmt, moduleFromSrc(@src()), args);
}
/// Compile-out-gated verbose trace: empty under the default `.info` log level
/// (ReleaseFast), so hot-path per-event logging costs nothing in production.
pub inline fn debug(comptime fmt: []const u8, args: anytype) void {
    log(std.log.debug, fmt, moduleFromSrc(@src()), args);
}

/// Log a warning for a best-effort operation whose failure is non-fatal.
pub inline fn warnOnErr(e: anyerror, comptime context: []const u8) void {
    log(std.log.warn, "Best-effort op failed (" ++ context ++ "): {}", moduleFromSrc(@src()), .{e});
}
