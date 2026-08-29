//! Clock bar segment.
//!
//! Renders wall-clock time and schedules its own repaints: the event loop
//! asks bar.pollTimeoutMs() for the nearest timer deadline (this segment
//! contributes the ms-to-next-boundary value) and wakes exactly at
//! whole-second boundaries; `bar.updateClock` then redraws this segment when
//! its on-screen content has gone stale (second rolled over, or a config
//! reload changed the format). Single-threaded by construction -- all state
//! lives on the main thread, so there are no locks, flags, or drain races
//! (docs/clock-plan.md).

const std = @import("std");
const types = @import("types");
const utils = @import("utils");
const drawing = @import("drawing");

const c = @cImport(@cInclude("time.h"));

const ns_per_s = std.time.ns_per_s;

/// Measurement string used to pre-compute the clock segment width.
/// Wider than the default "%Y-%m-%d %H:%M:%S" format (19 chars) so that
/// typical user extensions (e.g. a day-of-week prefix) still fit without
/// the segment changing width mid-session.
pub const clock_measure_string: []const u8 = "0000-00-00 00:00:00";

/// What is currently on screen: the epoch second last rendered and the
/// format string used for it. Plain vars -- only the main thread touches
/// them. Comparing the format pointer catches config reloads that change
/// the format mid-second (a spurious extra reformat on equal content is
/// harmless); comparing the second catches the passage of time.
var rendered_sec: i64 = -1;
var rendered_fmt: []const u8 = "";

fn stale(sec: i64, fmt: []const u8) bool {
    return sec != rendered_sec or fmt.ptr != rendered_fmt.ptr;
}

/// True when the segment on screen no longer matches (sec, fmt).
/// Callers pass the active format so reloads invalidate without a separate
/// flag. Drawing clears staleness as a side effect of rendering; a failed
/// draw leaves it stale so the next boundary retries.
pub fn secondElapsed(fmt: []const u8) bool {
    return stale(currentEpochSeconds(), fmt);
}

/// Deadline arithmetic, factored out pure so tests can drive the clock.
/// ms from `now_ms` to the next whole-second wall-clock boundary: always in
/// [1, 1000]. poll()'s timeout is only a lower bound (POSIX), so the wake
/// lands at or after the boundary -- no grace padding is needed because
/// nothing must drain a producer's output before rendering; the render
/// itself happens lazily in draw().
pub fn deadlineFromMs(now_ms: i64) i32 {
    return @intCast(1000 - @mod(now_ms, 1000));
}

/// ms until the next whole-second boundary, contributed via bar.pollTimeoutMs().
pub fn tickDeadlineMs() i32 {
    return deadlineFromMs(realtimeMs());
}

// Drawing

/// Draws the current time at `start_x`, formatting lazily: the strftime run
/// happens at most once per wall-second (or after a format change), right
/// here on the main thread.
pub fn draw(dc: *drawing.DrawContext, config: types.BarConfig, height: u16, start_x: u16) !u16 {
    var buf: [64]u8 = undefined;
    const sec = currentEpochSeconds();
    const fmt = config.clock_format orelse types.default_clock_format;
    const str = try formatTime(&buf, sec, fmt);
    // Record the attempt before rendering: a persistent render failure
    // (e.g. fonts unavailable) must degrade to one retry per boundary --
    // the legacy thread's cadence -- never to a per-event-batch retry storm.
    // A genuine transient miss simply shows the previous second for up to
    // one extra second, exactly as the old design did.
    rendered_sec = sec;
    rendered_fmt = fmt;
    return dc.drawSegment(start_x, height, str, config.scaledSegmentPadding(height), config.bg, config.fg);
}

fn currentEpochSeconds() i64 {
    return @intCast(utils.realtimeNs() / ns_per_s);
}

fn realtimeMs() i64 {
    return @intCast(utils.realtimeNs() / std.time.ns_per_ms);
}

/// Formats `sec` (seconds since the Unix epoch) into `buf` using `fmt` as a
/// strftime(3) format string. Uses localtime_r for the local timezone, falling
/// back to gmtime_r when timezone data is unavailable. Both are POSIX-guaranteed
/// reentrant.
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
