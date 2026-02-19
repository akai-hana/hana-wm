//! Clock segment — displays the current time and manages the update timer.
//! The timer is dynamically enabled/disabled to reduce idle CPU usage.

const std     = @import("std");
const defs    = @import("defs");
const drawing = @import("drawing");
const bar     = @import("bar");
const debug   = @import("debug");

const c = @cImport(@cInclude("time.h"));

// Matches the width of the longest possible clock output, used for pre-sizing the segment.
const TIME_FORMAT = "{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2}";

var last_formatted_time: [20]u8 = undefined;
var last_formatted_sec:  i64    = -1;

var global_timer_fd: i32 = 0;
var timer_enabled:   bool = false;

/// Registers the timerfd file descriptor. Must be called once during initialisation.
pub fn setTimerFd(fd: i32) void {
    global_timer_fd = fd;
    timer_enabled   = false;
}

/// Returns true when the clock timer should be running.
fn shouldClockRun() bool {
    return bar.isVisible() and bar.hasClockSegment();
}

/// Enables or disables the timerfd, aligning the first tick to the next second boundary.
fn setTimerState(enable: bool) void {
    if (enable == timer_enabled) return;

    const spec: std.os.linux.itimerspec = if (enable) blk: {
        const ts = std.posix.clock_gettime(std.posix.CLOCK.REALTIME) catch {
            debug.warn("Failed to get time for timer alignment", .{});
            return;
        };
        break :blk .{
            .it_interval = .{ .sec = 1, .nsec = 0 },
            // Fire on the next second boundary, then every second after.
            .it_value = .{ .sec = 0, .nsec = @intCast(std.time.ns_per_s - @as(u64, @intCast(ts.nsec))) },
        };
    } else .{
        .it_interval = .{ .sec = 0, .nsec = 0 },
        .it_value    = .{ .sec = 0, .nsec = 0 },
    };

    if (std.os.linux.timerfd_settime(@intCast(global_timer_fd), .{}, &spec, null) >= 0) {
        timer_enabled = enable;
        debug.info("Clock timer {s}", .{if (enable) "enabled" else "disabled"});
    }
}

/// Recalculates whether the timer should run and applies the change.
/// Call when bar visibility changes or the config is reloaded.
pub fn updateTimerState(_: *defs.WM) void {
    setTimerState(shouldClockRun());
}

/// Draws the clock segment at `start_x`, returning the next X position.
pub fn draw(dc: *drawing.DrawContext, config: defs.BarConfig, height: u16, start_x: u16) !u16 {
    const ts = try std.posix.clock_gettime(std.posix.CLOCK.REALTIME);
    const time_str = if (ts.sec == last_formatted_sec)
        last_formatted_time[0..19]
    else blk: {
        const str = try formatTime(&last_formatted_time);
        last_formatted_sec = ts.sec;
        break :blk str;
    };
    return dc.drawSegment(start_x, height, time_str, config.scaledPadding(), config.bg, config.fg);
}

/// Formats the current local time into `buf`. Falls back to UTC on `localtime` failure.
fn formatTime(buf: []u8) ![]const u8 {
    const ts = std.posix.clock_gettime(std.posix.CLOCK.REALTIME) catch
        return try std.fmt.bufPrint(buf, "????-??-?? ??:??:??", .{});

    var raw_sec: c.time_t = @intCast(ts.sec);
    const local_ts = c.localtime(&raw_sec) orelse return formatUtc(buf, ts.sec);

    return try std.fmt.bufPrint(buf, TIME_FORMAT, .{
        @as(u32, @intCast(local_ts.*.tm_year + 1900)),
        @as(u32, @intCast(local_ts.*.tm_mon  + 1)),
        @as(u32, @intCast(local_ts.*.tm_mday)),
        @as(u32, @intCast(local_ts.*.tm_hour)),
        @as(u32, @intCast(local_ts.*.tm_min)),
        @as(u32, @intCast(local_ts.*.tm_sec)),
    });
}

/// Formats `epoch_sec` as UTC when local time is unavailable.
fn formatUtc(buf: []u8, epoch_sec: i64) ![]const u8 {
    const epoch_day  = @divFloor(epoch_sec, std.time.s_per_day);
    const day_sec    = @mod(epoch_sec, std.time.s_per_day);
    const civil_day  = std.time.epoch.EpochDay{ .day = @intCast(epoch_day) };
    const year_day   = civil_day.calculateYearDay();
    const month_day  = year_day.calculateMonthDay();

    const hour: u32 = @intCast(@divFloor(day_sec, std.time.s_per_hour));
    const min:  u32 = @intCast(@divFloor(@mod(day_sec, std.time.s_per_hour), std.time.s_per_min));
    const sec:  u32 = @intCast(@mod(day_sec, std.time.s_per_min));

    return try std.fmt.bufPrint(buf, TIME_FORMAT, .{
        year_day.year, month_day.month.numeric(), month_day.day_index + 1, hour, min, sec,
    });
}
