//! Clock segment
//! Displays the current time on the status bar. A background thread aligns
//! itself to the next whole-second boundary, then wakes once a second to
//! format the time string and flag the main WM thread to redraw the segment.
//! Pango/layout work always runs on the main thread (bar.updateClock →
//! drawClockOnly); the clock thread never touches the DrawContext.
//!
//! Thread lifecycle
//! ----------------
//!   startThread(allocator, format) — call from bar.init() after the bar
//!                                    window exists. Dupes `format` for the
//!                                    thread's own use.
//!   stopThread(allocator)           — call before bar teardown (deinit and
//!                                     reload). Returns almost immediately:
//!                                     it signals the condition variable the
//!                                     thread is sleeping on, so the thread
//!                                     wakes and exits instead of letting the
//!                                     current sleep run out. The next
//!                                     startThread() re-aligns from scratch,
//!                                     so a reload never leaves the tick
//!                                     phase-drifted.
//!
//! Cross-thread wakeup
//! -------------------
//! The main event loop polls with a deadline of clock.nextTickWaitMs() (the
//! ms until the next whole-second boundary, plus a grace period) so it wakes
//! shortly after each tick, then drains the clock_dirty flag via
//! bar.updateClock(). It also drains the flag after every XCB event batch, so
//! a busy main loop that never lets a poll timeout expire still repaints the
//! clock in time.

const std = @import("std");
const types = @import("types");
const utils = @import("utils");
const drawing = @import("drawing");
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

/// Wake the main loop this many ms after a whole-second boundary. Must be
/// large enough for the clock thread to have formatted the new second by the
/// time the main thread drains it.
const DRAIN_GRACE_MS: i64 = 10;

/// When the main thread wakes within the grace window but the dirty flag is
/// not set yet (the clock thread was descheduled past the boundary), poll
/// again after this many ms instead of sleeping to the next boundary.
const RETRY_MS: i64 = 25;

/// Cached formatted time, keyed by the epoch second it was formatted for.
/// Guarded by `cache_mutex` so the clock thread (publishCurrentTime) and the
/// main thread (draw, lazy fallback) can share it without racing.
var cache_mutex: utils.Mutex = .{};
var last_formatted_time: [64]u8 = undefined;
var last_formatted_len: usize = 0;
var last_formatted_sec: i64 = -1;

/// Set by the clock thread after publishing a new formatted second; cleared
/// (consumed) by the main thread when it redraws the clock segment.
var clock_dirty: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);

var clock_mutex: utils.Mutex = .{};
var clock_cond: utils.Condition = .{};
var clock_quit: bool = false;
var clock_thread: ?std.Thread = null;

/// Format string duped from the config at startThread(); owned by this module
/// and freed at stopThread(). Only ever read by the clock thread, and only
/// written by the main thread while the thread is not running.
var clock_format_owned: []const u8 = "";

pub fn startThread(allocator: std.mem.Allocator, format: []const u8) void {
    const owned = allocator.dupe(u8, format) catch |e| {
        debug.err("Clock format dupe failed: {s}", .{@errorName(e)});
        return;
    };
    clock_format_owned = owned;
    // timedWait uses a CLOCK_MONOTONIC deadline; safe to re-init on every
    // call (init/reload) since the thread is never running while this fires.
    clock_cond.initMonotonic();
    clock_mutex.lock();
    clock_quit = false;
    clock_mutex.unlock();
    clock_thread = std.Thread.spawn(.{}, runClockThread, .{}) catch |e| {
        allocator.free(owned);
        clock_format_owned = "";
        debug.err("Clock thread spawn failed: {s}", .{@errorName(e)});
        return;
    };
    debug.info("Clock thread started", .{});
}

pub fn stopThread(allocator: std.mem.Allocator) void {
    clock_mutex.lock();
    clock_quit = true;
    clock_cond.signal();
    clock_mutex.unlock();
    if (clock_thread) |t| {
        t.join();
        clock_thread = null;
    }
    if (clock_format_owned.len > 0) {
        allocator.free(clock_format_owned);
        clock_format_owned = "";
    }
    debug.info("Clock thread stopped", .{});
}

fn runClockThread() void {
    // One-time alignment: sleep just long enough to land on the next whole
    // second, so the periodic loop below starts in phase with the real
    // clock instead of ticking at whatever offset the thread happened to
    // spawn at. Uses the interruptible timedWait so stopThread() returns
    // immediately even if it fires during alignment.
    if (!sleepUntilNextSecond()) return;

    // Plain periodic loop from here on. No re-anchoring: a fixed 1s sleep
    // per iteration can accumulate a little scheduling drift over a very
    // long uptime, but a reload (which re-runs the alignment above) resets
    // it, so it never compounds indefinitely.
    while (true) {
        clock_mutex.lock();
        if (clock_quit) {
            clock_mutex.unlock();
            return;
        }
        clock_cond.timedWait(&clock_mutex, ns_per_s) catch {};
        const quit = clock_quit;
        clock_mutex.unlock();
        if (quit) return;
        // Pango-free: format the time string into the shared cache and flag
        // the main thread to redraw the segment. No DrawContext access here.
        publishCurrentTime();
    }
}

/// Sleeps until the next whole-second boundary, returning false when quit
/// was requested mid-sleep. A spurious early wakeup (or a quit signal that
/// somehow raced past the check above) recomputes the remaining time and
/// keeps sleeping, so the periodic loop always starts in phase with the
/// wall clock rather than offset by however long the interruption was.
fn sleepUntilNextSecond() bool {
    var ts: Timespec = undefined;
    _ = c.clock_gettime(c.CLOCK_REALTIME, @ptrCast(&ts));
    var remaining: i64 = ns_per_s - ts.tv_nsec;
    while (remaining > 0) {
        clock_mutex.lock();
        if (clock_quit) {
            clock_mutex.unlock();
            return false;
        }
        // error.Timeout means the full `remaining` elapsed: we've reached
        // the boundary. A normal return is a signal (quit) or spurious wake.
        const timed_out = if (clock_cond.timedWait(&clock_mutex, @intCast(remaining))) |_|
            false
        else |err|
            err == error.Timeout;
        const quit = clock_quit;
        clock_mutex.unlock();
        if (quit) return false;
        if (timed_out) return true;
        _ = c.clock_gettime(c.CLOCK_REALTIME, @ptrCast(&ts));
        remaining = ns_per_s - ts.tv_nsec;
        if (remaining < 0) remaining = 0;
    }
    return true;
}

/// Formats the current wall-clock time into the shared cache (no Pango, no
/// draw_mutex) and publishes it for the main thread to draw.
fn publishCurrentTime() void {
    const sec = currentEpochSeconds();
    cache_mutex.lock();
    defer cache_mutex.unlock();
    if (sec == last_formatted_sec) return;
    const str = formatTime(&last_formatted_time, sec, clock_format_owned) catch return;
    last_formatted_len = str.len;
    last_formatted_sec = sec;
    clock_dirty.store(true, .release);
}

// Cross-thread handshake

/// Returns true and clears the flag when the clock thread has published a new
/// formatted second for the main thread to draw.
pub fn consumeClockDirty() bool {
    return clock_dirty.swap(false, .acq_rel);
}

/// ms until the next whole-second boundary (CLOCK_REALTIME) plus a grace
/// period, so a poll() with this deadline wakes shortly after the clock
/// thread's tick. If we're already inside the grace window and the dirty flag
/// is still clear (the thread was descheduled past the boundary), returns a
/// short retry instead so the main loop keeps waking until the thread
/// publishes.
pub fn nextTickWaitMs() i64 {
    const now_ms = realtimeMs();
    const m = @mod(now_ms, 1000);
    if (m <= DRAIN_GRACE_MS and !clock_dirty.load(.acquire)) return RETRY_MS;
    const to_boundary = if (m == 0) 1000 else 1000 - m;
    return to_boundary + DRAIN_GRACE_MS;
}

// Drawing

/// Draws the current time string on the bar. Returns the x position after the segment.
pub fn draw(dc: *drawing.DrawContext, config: types.BarConfig, height: u16, start_x: u16) !u16 {
    // Snapshot the cached time string into a local buffer under the cache
    // lock, then render it after releasing the lock: the clock thread may be
    // formatting the next second concurrently, and dc.drawSegment must never
    // read a torn mid-format string.
    var buf: [64]u8 = undefined;
    var time_str: []const u8 = "";
    const sec = currentEpochSeconds();
    cache_mutex.lock();
    defer cache_mutex.unlock();
    if (sec == last_formatted_sec) {
        const n = last_formatted_len;
        @memcpy(buf[0..n], last_formatted_time[0..n]);
        time_str = buf[0..n];
    } else {
        // Fallback format path (e.g. before the clock thread's first tick):
        // same guarded cache, so a concurrent publishCurrentTime can't race.
        const str = try formatTime(&last_formatted_time, sec, config.clock_format);
        last_formatted_len = str.len;
        last_formatted_sec = sec;
        const n = str.len;
        @memcpy(buf[0..n], str);
        time_str = buf[0..n];
    }
    return dc.drawSegment(start_x, height, time_str, config.scaledSegmentPadding(height), config.bg, config.fg);
}

fn currentEpochSeconds() i64 {
    var ts: Timespec = undefined;
    _ = c.clock_gettime(c.CLOCK_REALTIME, @ptrCast(&ts));
    return ts.tv_sec;
}

fn realtimeMs() i64 {
    var ts: Timespec = undefined;
    _ = c.clock_gettime(c.CLOCK_REALTIME, @ptrCast(&ts));
    return ts.tv_sec * 1000 + @divTrunc(ts.tv_nsec, 1_000_000);
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
