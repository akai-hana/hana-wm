//! VDSO-accelerated clock helpers (D6 split from utils.zig). xcb-free.

const std = @import("std");

// Uses the VDSO-accelerated clock_gettime on supported kernels.
inline fn clockTs(clock_id: std.os.linux.clockid_t) std.os.linux.timespec {
    var ts: std.os.linux.timespec = undefined;
    _ = std.os.linux.clock_gettime(clock_id, &ts);
    return ts;
}

pub fn clockNs(clock_id: std.os.linux.clockid_t) u64 {
    const ts = clockTs(clock_id);
    return @as(u64, @intCast(ts.sec)) * 1_000_000_000 + @as(u64, @intCast(ts.nsec));
}

pub inline fn monotonicNs() u64 {
    return clockNs(.MONOTONIC);
}

pub inline fn realtimeNs() u64 {
    return clockNs(.REALTIME);
}
