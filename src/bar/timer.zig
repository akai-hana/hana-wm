//! Timer management for bar clock updates
//! OPTIMIZATION: Dynamic timer control to reduce idle CPU to near-zero

const std = @import("std");
const defs = @import("defs");
const bar = @import("bar");
const debug = @import("debug");

// Timer state for dynamic enable/disable to reduce idle CPU
var global_timer_fd: i32 = 0;
var timer_enabled: bool = false;

/// Set the timer file descriptor (called once during initialization)
pub fn setTimerFd(fd: i32) void {
    global_timer_fd = fd;
    timer_enabled = false;
}

/// Check if clock should be running based on bar state
fn shouldClockRun(wm: *defs.WM) bool {
    // Don't run timer if bar is disabled
    if (!wm.config.bar.enable) return false;
    
    // Don't run timer if bar is hidden (fullscreen)
    if (!bar.isVisible()) return false;
    
    // Check if clock segment exists in layout
    for (wm.config.bar.layout.items) |layout| {
        for (layout.segments.items) |seg| {
            if (seg == .clock) return true;
        }
    }
    return false;
}

/// Enable the timer (starts 1Hz ticks)
fn enableTimer() void {
    if (timer_enabled) return;
    
    const spec = std.os.linux.itimerspec{
        .it_interval = .{ .sec = 1, .nsec = 0 },
        .it_value = .{ .sec = 1, .nsec = 0 }
    };
    
    if (std.os.linux.timerfd_settime(@intCast(global_timer_fd), .{}, &spec, null) >= 0) {
        timer_enabled = true;
        debug.info("Clock timer enabled", .{});
    }
}

/// Disable the timer (stops ticks, reduces idle CPU)
fn disableTimer() void {
    if (!timer_enabled) return;
    
    const spec = std.os.linux.itimerspec{
        .it_interval = .{ .sec = 0, .nsec = 0 },
        .it_value = .{ .sec = 0, .nsec = 0 }
    };
    
    if (std.os.linux.timerfd_settime(@intCast(global_timer_fd), .{}, &spec, null) >= 0) {
        timer_enabled = false;
        debug.info("Clock timer disabled (idle CPU optimization)", .{});
    }
}

/// Update timer state based on current WM configuration
/// Called when bar visibility changes or config is reloaded
pub fn updateTimerState(wm: *defs.WM) void {
    const should_run = shouldClockRun(wm);
    if (should_run and !timer_enabled) {
        enableTimer();
    } else if (!should_run and timer_enabled) {
        disableTimer();
    }
}
