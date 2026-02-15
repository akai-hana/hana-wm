//! Clock segment
//! Timer management for bar clock updates
//! Dynamic timer control to reduce idle CPU to near-zero

const std     = @import("std");
const defs    = @import("defs");
const drawing = @import("drawing");
const bar     = @import("bar");
const debug   = @import("debug");

const c = @cImport(@cInclude("time.h"));

// Time formatting constant
const TIME_FORMAT = "{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2}";

// Timer state ─

// Cached clock formatting to avoid redundant formatting
var last_formatted_time: [20]u8 = undefined;
var last_formatted_sec: i64 = -1;

// Timer state for dynamic enable/disable to reduce idle CPU
var global_timer_fd: i32 = 0;
var timer_enabled: bool = false;

/// Set the timer file descriptor (called once during initialization)
pub fn setTimerFd(fd: i32) void {
    global_timer_fd = fd;
    timer_enabled = false;
}

/// Check if clock should be running based on bar state
fn shouldClockRun() bool {
    // Don't run timer if bar is hidden (fullscreen)
    if (!bar.isVisible()) return false;

    // Use cached clock segment detection - O(1) instead of O(n*m)
    return bar.hasClockSegment();
}

/// Set timer state (enable or disable)
fn setTimerState(enable: bool) void {
    if (enable == timer_enabled) return;
    
    if (enable) {
        // Calculate nanoseconds until next second boundary
        const ts = std.posix.clock_gettime(std.posix.CLOCK.REALTIME) catch {
            debug.warn("Failed to get time for timer alignment", .{});
            return;
        };
        
        // Calculate nanoseconds remaining in current second
        const nsec_remaining = std.time.ns_per_s - @as(u64, @intCast(ts.nsec));
        
        // Set timer to fire at next second boundary, then every 1 second
        const spec = std.os.linux.itimerspec{
            .it_interval = .{ .sec = 1, .nsec = 0 },  // Fire every 1 second after initial
            .it_value    = .{ .sec = 0, .nsec = @intCast(nsec_remaining) },  // Fire when second changes
        };
        
        if (std.os.linux.timerfd_settime(@intCast(global_timer_fd), .{}, &spec, null) >= 0) {
            timer_enabled = true;
            debug.info("Clock timer enabled (aligned to second boundary)", .{});
        }
    } else {
        // Disable timer
        const spec = std.os.linux.itimerspec{
            .it_interval = .{ .sec = 0, .nsec = 0 },
            .it_value    = .{ .sec = 0, .nsec = 0 },
        };
        
        if (std.os.linux.timerfd_settime(@intCast(global_timer_fd), .{}, &spec, null) >= 0) {
            timer_enabled = false;
            debug.info("Clock timer disabled", .{});
        }
    }
}

/// Update timer state based on current WM configuration.
/// Called when bar visibility changes or config is reloaded.
pub fn updateTimerState(_: *defs.WM) void {
    setTimerState(shouldClockRun());
}

// Drawing

pub fn draw(dc: *drawing.DrawContext, config: defs.BarConfig, height: u16, start_x: u16) !u16 {
    const ts = try std.posix.clock_gettime(std.posix.CLOCK.REALTIME);
    
    // Use cached formatting if still the same second
    const time_str = if (ts.sec == last_formatted_sec)
        last_formatted_time[0..19]
    else blk: {
        const str = try formatTime(&last_formatted_time);
        last_formatted_sec = ts.sec;
        break :blk str;
    };
    
    return dc.drawSegment(start_x, height, time_str, config.scaledPadding(), config.bg, config.fg);
}

fn formatTime(buf: []u8) ![]const u8 {
    const ts = std.posix.clock_gettime(std.posix.CLOCK.REALTIME) catch
        return try std.fmt.bufPrint(buf, "????-??-?? ??:??:??", .{});

    var raw_sec: c.time_t = @intCast(ts.sec);
    const local_ts = c.localtime(&raw_sec) orelse return formatUtc(buf, ts.sec);

    return try std.fmt.bufPrint(buf, TIME_FORMAT, .{
        @as(u32, @intCast(local_ts.*.tm_year + 1900)),
        @as(u32, @intCast(local_ts.*.tm_mon + 1)),
        @as(u32, @intCast(local_ts.*.tm_mday)),
        @as(u32, @intCast(local_ts.*.tm_hour)),
        @as(u32, @intCast(local_ts.*.tm_min)),
        @as(u32, @intCast(local_ts.*.tm_sec)),
    });
}

fn formatUtc(buf: []u8, epoch_sec: i64) ![]const u8 {
    const epoch_day = @divFloor(epoch_sec, std.time.s_per_day);
    const day_sec = @mod(epoch_sec, std.time.s_per_day);
    const civil_day = std.time.epoch.EpochDay{ .day = @intCast(epoch_day) };
    const year_day = civil_day.calculateYearDay();
    const month_day = year_day.calculateMonthDay();

    const hour: u32 = @intCast(@divFloor(day_sec, std.time.s_per_hour));
    const min: u32 = @intCast(@divFloor(@mod(day_sec, std.time.s_per_hour), std.time.s_per_min));
    const sec: u32 = @intCast(@mod(day_sec, std.time.s_per_min));

    return try std.fmt.bufPrint(buf, TIME_FORMAT, .{
        year_day.year, month_day.month.numeric(), month_day.day_index + 1, hour, min, sec,
    });
}
