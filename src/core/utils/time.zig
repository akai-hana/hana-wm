//! VDSO-accelerated clock helpers (D6 split from utils.zig). xcb-free.

const std = @import("std");

// Uses the VDSO-accelerated clock_gettime on supported kernels. A failure
// here would leave `ts` undefined and poison every deadline computed from it,
// so the alternate VDSO clock is tried before giving up on a defined value.
inline fn clockTs(clock_id: std.os.linux.clockid_t) std.os.linux.timespec {
    var ts: std.os.linux.timespec = undefined;
    if (std.os.linux.clock_gettime(clock_id, &ts) != 0) {
        const fallback_id: std.os.linux.clockid_t =
            if (clock_id == .MONOTONIC) .REALTIME else .MONOTONIC;
        if (std.os.linux.clock_gettime(fallback_id, &ts) != 0)
            ts = .{ .sec = 0, .nsec = 0 };
    }
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
