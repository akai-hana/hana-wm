//! Debug logging and error helpers; user-facing diagnostics routed through
//! std.log.

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
/// One captured diagnostic. `module` and `message` are owned by the
/// `Collector`.
pub const Diagnostic = struct {
    level: std.log.Level,
    module: []const u8,
    message: []const u8,
};

/// Collects warn/err diagnostics that the `log` wrappers below would otherwise
/// only write to stderr, so a non-interactive check can COUNT them instead of
/// scraping text: `hana --check-config` reports the count and exits non-zero
/// when it is above zero, which is what makes config validation usable in CI.
///
/// Installed through the module-level `collector` pointer, never passed down
/// the call chain: the sixty-odd warn sites in the config loader are exactly
/// the ones this exists to cover, and threading a bag through each of them is
/// the maintenance burden that made the idea unattractive. When it is null --
/// the normal case -- nothing about the log path changes.
pub const Collector = struct {
    allocator: std.mem.Allocator,
    items: std.ArrayList(Diagnostic) = .empty,

    pub fn deinit(self: *Collector) void {
        for (self.items.items) |d| {
            self.allocator.free(d.module);
            self.allocator.free(d.message);
        }
        self.items.deinit(self.allocator);
        self.* = undefined;
    }

    /// Number of warn/err diagnostics captured so far.
    pub fn count(self: *const Collector) usize {
        return self.items.items.len;
    }

    /// Whether any captured message contains `needle`. Lets a test assert a
    /// SPECIFIC rejection happened without matching a whole file's text.
    pub fn contains(self: *const Collector, needle: []const u8) bool {
        for (self.items.items) |d| {
            if (std.mem.indexOf(u8, d.message, needle) != null) return true;
        }
        return false;
    }

    /// The same "[module] message" line the stderr path would have written.
    pub fn line(d: Diagnostic, buf: []u8) ![]const u8 {
        return std.fmt.bufPrint(buf, "[{s}] {s}", .{ d.module, d.message });
    }
};

/// Non-null while a `Collector` is installed. Checked BEFORE the test-silence
/// rule below, so a test can assert on captured diagnostics without opening the
/// stderr hatch (which the 0.16 test runner treats as a failing step).
pub var collector: ?*Collector = null;

inline fn capture(c: *Collector, level: std.log.Level, module: []const u8, comptime fmt: []const u8, args: anytype) void {
    // `fmt` is comptime but `module` is a runtime slice, so the module tag is
    // stored beside the message rather than composed into the format string;
    // `Collector.line` puts it back for printing.
    const message = std.fmt.allocPrint(c.allocator, fmt, args) catch {
        c.items.append(c.allocator, .{
            .level = level,
            .module = c.allocator.dupe(u8, "log") catch return,
            .message = c.allocator.dupe(u8, "(diagnostic text could not be allocated)") catch return,
        }) catch return;
        return;
    };
    const tag = c.allocator.dupe(u8, module) catch {
        c.allocator.free(message);
        return;
    };
    c.items.append(c.allocator, .{ .level = level, .module = tag, .message = message }) catch {
        c.allocator.free(message);
    };
}

inline fn log(
    comptime log_fn: anytype,
    level: std.log.Level,
    comptime fmt: []const u8,
    module: []const u8,
    args: anytype,
) void {
    // Silence diagnostics inside test binaries: the 0.16 test runner treats
    // any stderr from a passing test step as a failure ("failed command:"),
    // and our tests deliberately exercise recoverable, warn-inducing paths.
    // Production builds are unaffected (is_test == false).
    // A test that needs to observe a log-emitting path (e.g. a recoverable
    // overflow it wants to assert was reported) opens the hatch; by default
    // the runner's "any stderr fails the step" rule still holds.
    if (collector) |c| {
        // Only the failure levels are collected: `info`/`debug` are progress
        // chatter, and a check that failed on them could never pass.
        if (level != .warn and level != .err) return;
        capture(c, level, module, fmt, args);
    }
    if (@import("builtin").is_test and !test_emit) return;
    log_fn("[{s}] " ++ fmt, .{module} ++ args);
}

/// Test-only override for the silence-above rule (see `log`). False (the
/// default) keeps every test binary silent.
pub var test_emit: bool = false;

pub inline fn err(comptime fmt: []const u8, args: anytype) void {
    log(std.log.err, .err, fmt, moduleFromSrc(@src()), args);
}
pub inline fn warn(comptime fmt: []const u8, args: anytype) void {
    log(std.log.warn, .warn, fmt, moduleFromSrc(@src()), args);
}
pub inline fn info(comptime fmt: []const u8, args: anytype) void {
    log(std.log.info, .info, fmt, moduleFromSrc(@src()), args);
}
/// Compile-out-gated verbose trace: empty under the default `.info` log level
/// (ReleaseFast), so hot-path per-event logging costs nothing in production.
pub inline fn debug(comptime fmt: []const u8, args: anytype) void {
    log(std.log.debug, .debug, fmt, moduleFromSrc(@src()), args);
}

/// Log a warning for a best-effort operation whose failure is non-fatal.
pub inline fn warnOnErr(e: anyerror, comptime context: []const u8) void {
    log(std.log.warn, .warn, "Best-effort op failed (" ++ context ++ "): {}", moduleFromSrc(@src()), .{e});
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
