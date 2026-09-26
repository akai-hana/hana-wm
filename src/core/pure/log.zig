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
    // Silence diagnostics inside test binaries: the 0.16 test runner treats
    // any stderr from a passing test step as a failure ("failed command:"),
    // and our tests deliberately exercise recoverable, warn-inducing paths.
    // Production builds are unaffected (is_test == false).
    if (@import("builtin").is_test) return;
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

/// Rolling windowed latency profiler sharing one shape across the key-dispatch
/// and retile paths: accumulates `ns` samples up to `window_size`, then logs a
/// summary via `logFn(fmt, .{ count, avg_ns, min_ns, max_ns })`. Compiles out
/// entirely when `enabled` is false (callers still reference `.enabled`).
///
/// Diagnostics, so it lives beside the log sink it reports through rather
/// than in a general-purpose utility module.
pub fn WindowedProfiler(
    comptime enabled_flag: bool,
    comptime fmt: []const u8,
    comptime logFn: anytype,
) type {
    return struct {
        pub const enabled = enabled_flag;
        var count: u64 = 0;
        var total_ns: i128 = 0;
        var min_ns: i128 = std.math.maxInt(i128);
        var max_ns: i128 = 0;
        const window_size: u64 = 200;

        fn note(ns: i128) void {
            if (ns < min_ns) min_ns = ns;
            if (ns > max_ns) max_ns = ns;
            total_ns += ns;
            count += 1;
            if (count >= window_size) flush();
        }

        fn flush() void {
            const avg: f64 = @as(f64, @floatFromInt(total_ns)) / @as(f64, @floatFromInt(count));
            logFn(fmt, .{ count, avg, min_ns, max_ns });
            count = 0;
            total_ns = 0;
            min_ns = std.math.maxInt(i128);
            max_ns = 0;
        }
    };
}
