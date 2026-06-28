//! Clock segment
//! Displays the current time on the status bar.
//!
//! The clock tick is driven by a dedicated thread that sleeps to the next
//! whole-second REALTIME boundary, fires a tick, then sleeps exactly one
//! second per subsequent tick.  This is independent of the main event loop,
//! so the displayed time never skips a second when the WM is busy.
//!
//! Thread lifecycle
//! ----------------
//!   startThread()  — call from bar.init() after the bar render thread starts.
//!   stopThread()   — call before bar thread teardown (deinit and reload).
//!
//! The sleep uses a pthread condition variable so stopThread() returns
//! promptly (typically < 1 ms) rather than waiting up to one full second.

const std = @import("std");
const core = @import("core");
const types = @import("types");
const drawing = @import("drawing");
const bar = @import("bar");
const debug = @import("debug");

const c = @cImport(@cInclude("time.h"));

/// Measurement string used to pre-compute the clock segment width.
/// Chosen to be wider than the default "%Y-%m-%d %H:%M:%S" format (19 chars)
/// so that typical user extensions (e.g., adding a day-of-week prefix) still
/// fit without the segment changing width mid-session.
pub const CLOCK_MEASURE_STRING: []const u8 = "0000-00-00 00:00:00";

/// Internal buffer for the formatted time string.  64 bytes accommodates
/// common custom strftime formats without heap allocation.
var last_formatted_time: [64]u8 = undefined;
/// Length of the valid slice in `last_formatted_time`, or 0 when uncached.
var last_formatted_len: usize = 0;
var last_formatted_sec: i64 = -1;

// Thread state

// clock_mutex / clock_cond protect clock_quit and provide the interruptible
// sleep primitive.  Zero-initialised (.{}) is PTHREAD_MUTEX/COND_INITIALIZER
// on Linux; no explicit init call is required.  The default cond clock is
// CLOCK_REALTIME, which is exactly what we want for second-aligned deadlines.
var clock_mutex: std.c.pthread_mutex_t = .{};
var clock_cond: std.c.pthread_cond_t = .{};
var clock_quit: bool = false;
var clock_thread: ?std.Thread = null;

// Helpers

/// Returns the current CLOCK_REALTIME timespec.
/// Analogous to `monotonicTs()` in utils.zig; centralises the two-line
/// clock_gettime call that previously appeared three times in this file.
inline fn realtimeTs() std.os.linux.timespec {
    var ts: std.os.linux.timespec = undefined;
    _ = std.os.linux.clock_gettime(.REALTIME, &ts);
    return ts;
}

// Public lifecycle API

/// Spawns the dedicated clock thread.
/// Safe to call after a preceding stopThread().
pub fn startThread() void {
    // Hold the mutex when clearing clock_quit so that this write is consistent
    // with all other accesses (stopThread, runClockThread).  The thread has not
    // started yet, so no contention occurs — the lock is purely for invariant
    // correctness and TSan visibility.
    _ = std.c.pthread_mutex_lock(&clock_mutex);
    clock_quit = false;
    _ = std.c.pthread_mutex_unlock(&clock_mutex);
    clock_thread = std.Thread.spawn(.{}, runClockThread, .{}) catch |e| {
        debug.err("Clock thread spawn failed: {s}", .{@errorName(e)});
        return;
    };
    debug.info("Clock thread started", .{});
}

/// Signals the clock thread to exit and blocks until it has joined.
/// Typically returns in < 1 ms regardless of where the thread is in its
/// sleep cycle.
pub fn stopThread() void {
    _ = std.c.pthread_mutex_lock(&clock_mutex);
    clock_quit = true;
    _ = std.c.pthread_cond_signal(&clock_cond);
    _ = std.c.pthread_mutex_unlock(&clock_mutex);
    if (clock_thread) |t| {
        t.join();
        clock_thread = null;
    }
    debug.info("Clock thread stopped", .{});
}

// Compatibility stubs (call sites in main.zig, events.zig, setBarState)

/// No-op: the thread runs continuously while the bar is alive; it does not
/// need to be toggled when bar visibility changes because checkClockUpdate()
/// performs the is_visible check before signalling the render thread.
pub fn updateTimerState() void {}

/// No-op: the clock thread drives ticks directly and no longer participates
/// in the main event loop's poll() timeout calculation.
pub fn pollTimeoutMs() i32 {
    return -1;
}

// Thread body

/// Sleeps up to `ns` nanoseconds, waking early if clock_quit is set.
/// Must NOT be called with clock_mutex held.
fn sleepInterruptible(ns: u64) void {
    // Compute an absolute REALTIME deadline for pthread_cond_timedwait.
    var deadline: std.os.linux.timespec = realtimeTs();
    const new_nsec = @as(u64, @intCast(deadline.nsec)) + ns;
    deadline.sec += @intCast(new_nsec / std.time.ns_per_s);
    deadline.nsec = @intCast(new_nsec % std.time.ns_per_s);

    _ = std.c.pthread_mutex_lock(&clock_mutex);
    while (!clock_quit) {
        const rc = std.c.pthread_cond_timedwait(&clock_cond, &clock_mutex, @ptrCast(&deadline));
        if (rc == std.posix.E.TIMEDOUT) break;
        // Spurious wakeup or signal: recheck clock_quit from the top of the loop.
    }
    _ = std.c.pthread_mutex_unlock(&clock_mutex);
}

fn runClockThread() void {
    // ── Align first tick to the next whole-second REALTIME boundary ────────
    // This ensures the displayed time is never stale by up to a full second
    // immediately after the bar starts.
    {
        const now_ts = realtimeTs();
        // ns_per_s - now_ts.nsec is always in (0, 1_000_000_000].
        const ns_to_boundary: u64 = @intCast(std.time.ns_per_s - now_ts.nsec);
        sleepInterruptible(ns_to_boundary);
    }

    while (true) {
        // Check quit before firing so we never send a spurious tick after
        // stopThread() has been called (e.g. during bar deinit or reload).
        _ = std.c.pthread_mutex_lock(&clock_mutex);
        const quit = clock_quit;
        _ = std.c.pthread_mutex_unlock(&clock_mutex);
        if (quit) return;

        // checkClockUpdate() guards against invisible / unconfigured bars
        // internally, so no extra check is needed here.
        _ = bar.checkClockUpdate();

        sleepInterruptible(std.time.ns_per_s);
    }
}

// Drawing (unchanged)

/// Draws the current time string on the bar. Returns the x position after the segment.
pub fn draw(dc: *drawing.DrawContext, config: types.BarConfig, height: u16, start_x: u16) !u16 {
    // Derive seconds from clock_gettime(REALTIME); sub-second precision is not needed for display.
    const now_ts = realtimeTs();
    const sec: i64 = now_ts.sec;

    // Re-use the cached string when the second hasn't changed; format otherwise.
    const time_str = if (sec == last_formatted_sec)
        last_formatted_time[0..last_formatted_len]
    else blk: {
        const str = try formatTime(&last_formatted_time, sec, config.clock_format);
        last_formatted_len = str.len;
        last_formatted_sec = sec;
        break :blk str;
    };
    return dc.drawSegment(start_x, height, time_str, config.scaledSegmentPadding(height), config.bg, config.fg);
}

/// Formats `sec` (seconds since the Unix epoch) into `buf` using `fmt` as a
/// strftime(3) format string.  Uses localtime_r for the local timezone, falling
/// back to gmtime_r when timezone data is unavailable.  Both are POSIX-guaranteed
/// reentrant, making this safe to call from the bar render thread.
///
/// Returns a slice into `buf` containing the formatted string (without the
/// trailing NUL that strftime writes).  Returns an error when `fmt` is too long
/// for the internal stack buffer, or when strftime produces an empty output.
fn formatTime(buf: []u8, sec: i64, fmt: []const u8) ![]const u8 {
    var raw_sec: c.time_t = @intCast(sec);
    var tm_buf: c.struct_tm = undefined;
    const tm_ptr = c.localtime_r(&raw_sec, &tm_buf) orelse
        c.gmtime_r(&raw_sec, &tm_buf);
    if (tm_ptr == null) return error.TimeFailed;

    // Build a null-terminated copy of the format string on the stack.
    var fmt_z: [128]u8 = undefined;
    if (fmt.len >= fmt_z.len) return error.FormatTooLong;
    @memcpy(fmt_z[0..fmt.len], fmt);
    fmt_z[fmt.len] = 0;

    const n = c.strftime(buf.ptr, buf.len, &fmt_z, tm_ptr);
    if (n == 0) return error.StrftimeFailed;
    return buf[0..n];
}