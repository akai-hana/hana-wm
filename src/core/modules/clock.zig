//! Clock segment.
//! Background thread that formats the time each second and signals the main thread to redraw.

const std = @import("std");
const types = @import("types");
const utils = @import("utils");
const drawing = @import("drawing");
const debug = @import("debug");

const c = @cImport(@cInclude("time.h"));

const ns_per_s = std.time.ns_per_s;

/// Measurement string used to pre-compute the clock segment width.
/// Wider than the default "%Y-%m-%d %H:%M:%S" format (19 chars) so that
/// typical user extensions (e.g. a day-of-week prefix) still fit without
/// the segment changing width mid-session.
pub const clock_measure_string: []const u8 = "0000-00-00 00:00:00";

/// Wake the main loop this many ms after a whole-second boundary. Must be
/// large enough for the clock thread to have formatted the new second by the
/// time the main thread drains it.
const drain_grace_ms: i64 = 10;

/// When the main thread wakes within the grace window but the dirty flag is
/// not set yet (the clock thread was descheduled past the boundary), poll
/// again after this many ms instead of sleeping to the next boundary.
const retry_ms: i64 = 25;

/// Guarded by `cache_mutex`: the clock thread publishes via
/// publishCurrentTime; the main thread reads via draw or the lazy fallback.
var cache_mutex: utils.Mutex = .{};
var last_formatted_time: [64]u8 = undefined;
var last_formatted_len: usize = 0;
var last_formatted_sec: i64 = -1;

/// Set by the clock thread after publishing a new formatted second; cleared
/// (consumed) by the main thread when it redraws the clock segment.
var clock_dirty: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);

var clock_thread: utils.CondThread = .{};

/// Format string duped from the config at startThread(); owned by this module
/// and freed at stopThread(). Only ever read by the clock thread, and only
/// written by the main thread while the thread is not running.
var clock_format_owned: []const u8 = "";

/// Null-terminated copy of the format string, built once at thread start.
/// Passed directly to strftime, avoiding a stack-buffer copy on every tick.
var clock_format_z: [:0]const u8 = "";

/// Spawns the clock thread. Call from bar.init() after the bar window exists.
/// Dupes `format`; the original need not outlive this call. The clock thread
/// never touches the DrawContext; all Pango/layout work runs on the main thread.
pub fn startThread(allocator: std.mem.Allocator, format: []const u8) void {
    const owned = allocator.dupe(u8, format) catch |e| {
        debug.err("Clock format dupe failed: {s}", .{@errorName(e)});
        return;
    };
    clock_format_owned = owned;

    const owned_z = allocator.dupeZ(u8, format) catch |e| {
        debug.err("Clock format null-terminated dupe failed: {s}", .{@errorName(e)});
        allocator.free(owned);
        clock_format_owned = "";
        return;
    };
    clock_format_z = owned_z;

    clock_thread.start(runClockThread, .{&clock_thread}) catch |e| {
        allocator.free(owned_z);
        clock_format_z = "";
        allocator.free(owned);
        clock_format_owned = "";
        debug.err("Clock thread spawn failed: {s}", .{@errorName(e)});
        return;
    };
    debug.info("Clock thread started", .{});
}

/// Signals the clock thread to exit and frees the duped format string.
/// Call before teardown; the next startThread() re-aligns from scratch
/// so reloads never phase-drift.
pub fn stopThread(allocator: std.mem.Allocator) void {
    clock_thread.stop();
    if (clock_format_z.len > 0) {
        allocator.free(clock_format_z);
        clock_format_z = "";
    }
    if (clock_format_owned.len > 0) {
        allocator.free(clock_format_owned);
        clock_format_owned = "";
    }
    debug.info("Clock thread stopped", .{});
}

fn runClockThread(t: *utils.CondThread) void {
    // Every tick re-anchors to the next whole-second wall-clock boundary via
    // sleepUntilNextSecond, rather than a flat timedWait(ns_per_s) relative
    // sleep. A flat relative sleep looked harmless but wasn't: each loop
    // iteration has a small amount of unavoidable overhead (mutex lock/
    // unlock, publishCurrentTime's cache_mutex + strftime) that happens
    // *after* the sleep and *before* the next one is scheduled, so the next
    // "1 second from now" deadline is always measured slightly later than
    // the true boundary. That overhead isn't huge on its own, but nothing
    // ever corrected it, so it compounded every single tick for as long as
    // the thread ran. Once accumulated drift pushed a tick outside
    // nextTickWaitMs()'s ~10ms detection window, the main loop's poll
    // stopped noticing new ticks in time and stalled for almost a full
    // extra second before its next boundary check - visible as the clock
    // "falling behind", repeatedly, the longer the process stayed up.
    // Re-anchoring every iteration means each tick is computed fresh from
    // the real wall clock, so drift can never accumulate past a single
    // iteration's overhead (sub-millisecond) - it resets every second
    // instead of only at reload.
    while (sleepUntilNextSecond(t)) {
        publishCurrentTime();
    }
}

/// Sleeps until the next whole-second boundary, returning false if quit was
/// requested mid-sleep. A spurious early wakeup or racing quit signal just
/// recomputes the remaining time and keeps sleeping, so the periodic loop
/// always starts in phase with the wall clock.
fn sleepUntilNextSecond(t: *utils.CondThread) bool {
    var remaining: i64 = @intCast(ns_per_s - utils.realtimeNs() % ns_per_s);
    while (remaining > 0) {
        t.mutex.lock();
        if (t.quit) {
            t.mutex.unlock();
            return false;
        }
        // error.Timeout means the full `remaining` elapsed: we've reached
        // the boundary. A normal return is a signal (quit) or spurious wake.
        const timed_out = if (t.cond.timedWait(&t.mutex, @intCast(remaining))) |_|
            false
        else |err|
            err == error.Timeout;
        const quit = t.quit;
        t.mutex.unlock();
        if (quit) return false;
        if (timed_out) return true;
        remaining = @intCast(ns_per_s - utils.realtimeNs() % ns_per_s);
    }
    return true;
}

/// Returns the formatted time string for `sec` from the cache, formatting it
/// with `fmt` on a cache miss. Caller must hold `cache_mutex`.
fn getOrFormatTime(sec: i64, fmt: []const u8) ![]const u8 {
    if (sec == last_formatted_sec) return last_formatted_time[0..last_formatted_len];
    const str = try formatTime(&last_formatted_time, sec, fmt);
    last_formatted_len = str.len;
    last_formatted_sec = sec;
    return str;
}

/// Formats the current wall-clock second into the shared cache and signals
/// the main thread to redraw.
fn publishCurrentTime() void {
    const sec = currentEpochSeconds();
    cache_mutex.lock();
    defer cache_mutex.unlock();
    if (sec == last_formatted_sec) {
        // Someone else (draw()'s fallback path, from an unrelated full-bar
        // redraw) already formatted this second into the cache before we
        // got here. The string is correct, but the main loop hasn't been
        // told: nextTickWaitMs()'s grace/retry window is only ~35ms wide,
        // so if we return silently here the poll deadline falls through to
        // waiting for the *next* whole-second boundary and the clock stalls
        // for almost a full extra second. Flag dirty anyway so the drain
        // path still runs this tick.
        clock_dirty.store(true, .release);
        return;
    }
    const str = formatTimeZ(&last_formatted_time, sec, clock_format_z) catch return;
    last_formatted_len = str.len;
    last_formatted_sec = sec;
    clock_dirty.store(true, .release);
}

// Cross-thread handshake

/// Consumes the dirty flag set by the clock thread.
/// Returns true if the main thread should redraw the clock segment.
pub fn consumeClockDirty() bool {
    return clock_dirty.swap(false, .acq_rel);
}

/// ms until the next whole-second boundary (CLOCK_REALTIME) plus a grace
/// period, so a poll() with this deadline wakes shortly after the tick. If
/// already inside the grace window with the dirty flag still clear (thread
/// descheduled past the boundary), returns a short retry instead so the main
/// loop keeps waking until the thread publishes.
pub fn nextTickWaitMs() i64 {
    const now_ms = realtimeMs();
    const m = @mod(now_ms, 1000);
    if (m <= drain_grace_ms and !clock_dirty.load(.acquire)) return retry_ms;
    const to_boundary = 1000 - m;
    return to_boundary + drain_grace_ms;
}

// Drawing

/// Draws the current time on the bar segment at `start_x`.
/// Acquires `cache_mutex` internally; callers must not hold it.
pub fn draw(dc: *drawing.DrawContext, config: types.BarConfig, height: u16, start_x: u16) !u16 {
    // The cache lock covers rendering: the clock thread may be formatting the
    // next second concurrently, so drawSegment must not read a torn string.
    const sec = currentEpochSeconds();
    cache_mutex.lock();
    defer cache_mutex.unlock();
    const str = try getOrFormatTime(sec, config.clock_format orelse types.default_clock_format);
    return dc.drawSegment(start_x, height, str, config.scaledSegmentPadding(height), config.bg, config.fg);
}

fn currentEpochSeconds() i64 {
    return @intCast(utils.realtimeNs() / ns_per_s);
}

fn realtimeMs() i64 {
    return @intCast(utils.realtimeNs() / 1_000_000);
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

    var fmt_z: [128]u8 = undefined;
    if (fmt.len >= fmt_z.len) return error.FormatTooLong;
    @memcpy(fmt_z[0..fmt.len], fmt);
    fmt_z[fmt.len] = 0;

    const n = c.strftime(buf.ptr, buf.len, &fmt_z, tm_ptr);
    if (n == 0) return error.StrftimeFailed;
    return buf[0..n];
}

/// Like `formatTime` but accepts a pre null-terminated format string,
/// skipping the stack-buffer copy. Used by the clock thread's hot path.
fn formatTimeZ(buf: []u8, sec: i64, fmt: [:0]const u8) ![]const u8 {
    var raw_sec: c.time_t = @intCast(sec);
    var tm_buf: c.struct_tm = undefined;
    const tm_ptr = c.localtime_r(&raw_sec, &tm_buf) orelse
        c.gmtime_r(&raw_sec, &tm_buf);
    if (tm_ptr == null) return error.TimeFailed;

    const n = c.strftime(buf.ptr, buf.len, fmt.ptr, tm_ptr);
    if (n == 0) return error.StrftimeFailed;
    return buf[0..n];
}
