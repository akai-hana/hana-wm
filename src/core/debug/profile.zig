//! Rolling latency profiler: accumulates `ns` samples up to a window size,
//! then logs a summary. Shared shape across the key-dispatch and retile paths
//! (src/core/input/keys.zig, src/core/loop/pipeline.zig). Compiles out entirely
//! when `enabled` is false (callers still reference `.enabled`).
//!
//! Detached from diagnostics capture: optional instrumentation reporting
//! through a caller-supplied log function, not part of the warn/err bag.

const std = @import("std");

/// Rolling windowed latency profiler: accumulates `ns` samples up to
/// `window_size`, then logs a summary via `logFn`. Compiles out entirely when
/// `enabled_flag` is false (callers still reference `.enabled`).
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

        pub fn note(ns: i128) void {
            if (ns < min_ns) min_ns = ns;
            if (ns > max_ns) max_ns = ns;
            total_ns += ns;
            count += 1;
            if (count >= window_size) flush();
        }

        pub fn flush() void {
            const avg: f64 = @as(f64, @floatFromInt(total_ns)) / @as(f64, @floatFromInt(count));
            logFn(fmt, .{ count, avg, min_ns, max_ns });
            count = 0;
            total_ns = 0;
            min_ns = std.math.maxInt(i128);
            max_ns = 0;
        }
    };
}
