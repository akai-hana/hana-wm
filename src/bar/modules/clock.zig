//! Clock segment — displays the current time and manages the update timer.
//! The timer is dynamically enabled/disabled to reduce idle CPU usage.

const std     = @import("std");
const core    = @import("core");
const drawing = @import("drawing");
const bar     = @import("bar");
const debug   = @import("debug");

const c = @cImport(@cInclude("time.h"));

pub const SAMPLE_STRING: []const u8 = "0000-00-00 00:00:00";

var timer_enabled:       bool    = false;
var last_formatted_time: [20]u8  = undefined;
var last_formatted_sec:  i64     = -1;

fn shouldClockRun() bool {
    return bar.isVisible() and bar.hasClockSegment();
}

fn setTimerState(enable: bool) void {
    if (enable != timer_enabled) {
        timer_enabled = enable;
        debug.info("Clock timer {s}", .{if (enable) "enabled" else "disabled"});
    }
}

/// Returns the number of milliseconds until the next whole-second boundary,
/// or -1 if the clock is disabled (telling poll to block indefinitely).
pub fn pollTimeoutMs() i32 {
    if (!timer_enabled) return -1;
    var now_ts: std.os.linux.timespec = undefined;
    switch (std.posix.errno(std.os.linux.clock_gettime(.REALTIME, &now_ts))) {
        .SUCCESS => {},
        else     => return 1000,
    }
    const ns_remaining: u64 = @intCast(std.time.ns_per_s - now_ts.nsec);
    // Round up to the nearest millisecond so we never fire slightly early.
    return @intCast((ns_remaining + 999_999) / 1_000_000);
}

pub fn updateTimerState() void {
    setTimerState(shouldClockRun());
}

pub fn draw(dc: *drawing.DrawContext, config: core.BarConfig, height: u16, start_x: u16) !u16 {
    // Derive seconds from clock_gettime(REALTIME); sub-second precision is not needed for display.
    var now_ts: std.os.linux.timespec = undefined;
    _ = std.os.linux.clock_gettime(.REALTIME, &now_ts);
    const sec: i64 = now_ts.sec;
    const time_str = if (sec == last_formatted_sec)
        last_formatted_time[0..19]
    else blk: {
        const str = try formatTime(&last_formatted_time, sec);
        last_formatted_sec = sec;
        break :blk str;
    };
    return dc.drawSegment(start_x, height, time_str, config.scaledSegmentPadding(height), config.bg, config.fg);
}

// localtime_r() is tried first; if it returns null we fall back to inline UTC arithmetic.
// Parameter is plain i64 seconds since the epoch — derived from std.time.nanoTimestamp()
// by the callers above.
// localtime_r is POSIX-guaranteed reentrant (output goes into caller-supplied tm_buf),
// making this function safe to call from the bar render thread.
fn formatTime(buf: []u8, sec: i64) ![]const u8 {
    var raw_sec: c.time_t = @intCast(sec);
    var tm_buf: c.struct_tm = undefined;
    if (c.localtime_r(&raw_sec, &tm_buf)) |local_ts| {
        return try std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2}", .{
            @as(u32, @intCast(local_ts.*.tm_year + 1900)),
            @as(u32, @intCast(local_ts.*.tm_mon  + 1)),
            @as(u32, @intCast(local_ts.*.tm_mday)),
            @as(u32, @intCast(local_ts.*.tm_hour)),
            @as(u32, @intCast(local_ts.*.tm_min)),
            @as(u32, @intCast(local_ts.*.tm_sec)),
        });
    }

    // UTC fallback — localtime_r() returned null (timezone data unavailable).
    const epoch_day = @divFloor(sec, std.time.s_per_day);
    const day_sec   = @mod(sec, std.time.s_per_day);
    const civil_day = std.time.epoch.EpochDay{ .day = @intCast(epoch_day) };
    const year_day  = civil_day.calculateYearDay();
    const month_day = year_day.calculateMonthDay();

    const hour: u32 = @intCast(@divFloor(day_sec, std.time.s_per_hour));
    const min:  u32 = @intCast(@divFloor(@mod(day_sec, std.time.s_per_hour), std.time.s_per_min));
    const secs: u32 = @intCast(@mod(day_sec, std.time.s_per_min));

    return try std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2}", .{
        year_day.year, month_day.month.numeric(), month_day.day_index + 1, hour, min, secs,
    });
}
