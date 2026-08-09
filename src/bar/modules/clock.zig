//! Clock segment
//! Displays the current time on the status bar. A background thread aligns
//! itself to the next whole-second boundary, then wakes once a second to
//! ask the bar to redraw the clock segment.
//!
//! Thread lifecycle
//! ----------------
//!   startThread() — call from bar.init() after the bar window exists.
//!   stopThread()  — call before bar teardown (deinit and reload). Can
//!                   block up to ~1s: the thread only checks for quit
//!                   between sleeps, and it's mid-sleep most of the time.
//!                   The next startThread() re-aligns from scratch, so a
//!                   reload never leaves the tick phase-drifted.

const std = @import("std");
const types = @import("types");
const drawing = @import("drawing");
const bar = @import("bar");
const debug = @import("debug");

const c = @cImport(@cInclude("time.h"));

/// Mirrors the ABI of C's `struct timespec` (two word-sized fields on
/// every LP64 target this bar runs on). We can't use `c.timespec`
/// directly: recent glibc headers define it with endian-conditional
/// anonymous bitfield padding that zig's C translator can't represent,
/// so `c.timespec` comes through as an opaque type with no known size.
/// This struct has the same layout, so a pointer to it is safe to hand
/// across the C boundary via `@ptrCast`.
const Timespec = extern struct {
    tv_sec: i64,
    tv_nsec: i64,
};

const ns_per_s: i64 = 1_000_000_000;

/// Measurement string used to pre-compute the clock segment width.
/// Wider than the default "%Y-%m-%d %H:%M:%S" format (19 chars) so that
/// typical user extensions (e.g. a day-of-week prefix) still fit without
/// the segment changing width mid-session.
pub const CLOCK_MEASURE_STRING: []const u8 = "0000-00-00 00:00:00";

/// Cached formatted time. Valid when the current second equals
/// `last_formatted_sec`, avoiding a strftime call on every redraw.
var last_formatted_time: [64]u8 = undefined;
var last_formatted_len: usize = 0;
var last_formatted_sec: i64 = -1;

var clock_quit: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);
var clock_thread: ?std.Thread = null;

pub fn startThread() void {
    clock_quit.store(false, .seq_cst);
    clock_thread = std.Thread.spawn(.{}, runClockThread, .{}) catch |e| {
        debug.err("Clock thread spawn failed: {s}", .{@errorName(e)});
        return;
    };
    debug.info("Clock thread started", .{});
}

pub fn stopThread() void {
    clock_quit.store(true, .seq_cst);
    if (clock_thread) |t| {
        t.join();
        clock_thread = null;
    }
    debug.info("Clock thread stopped", .{});
}

fn runClockThread() void {
    // One-time alignment: sleep just long enough to land on the next whole
    // second, so the periodic loop below starts in phase with the real
    // clock instead of ticking at whatever offset the thread happened to
    // spawn at.
    {
        var ts: Timespec = undefined;
        _ = c.clock_gettime(c.CLOCK_REALTIME, @ptrCast(&ts));
        var req: Timespec = .{ .tv_sec = 0, .tv_nsec = ns_per_s - ts.tv_nsec };
        _ = c.nanosleep(@ptrCast(&req), null);
    }

    // Plain periodic loop from here on. No re-anchoring: a fixed 1s sleep
    // per iteration can accumulate a little scheduling drift over a very
    // long uptime, but a reload (which re-runs the alignment above) resets
    // it, so it never compounds indefinitely.
    while (!clock_quit.load(.seq_cst)) {
        var req: Timespec = .{ .tv_sec = 1, .tv_nsec = 0 };
        _ = c.nanosleep(@ptrCast(&req), null);
        bar.checkClockUpdate();
    }
}

// Drawing

/// Draws the current time string on the bar. Returns the x position after the segment.
pub fn draw(dc: *drawing.DrawContext, config: types.BarConfig, height: u16, start_x: u16) !u16 {
    const sec = currentEpochSeconds();

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

fn currentEpochSeconds() i64 {
    var ts: Timespec = undefined;
    _ = c.clock_gettime(c.CLOCK_REALTIME, @ptrCast(&ts));
    return ts.tv_sec;
}

/// Formats `sec` (seconds since the Unix epoch) into `buf` using `fmt` as a
/// strftime(3) format string. Uses localtime_r for the local timezone, falling
/// back to gmtime_r when timezone data is unavailable. Both are POSIX-guaranteed
/// reentrant, making this safe to call from any thread.
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
