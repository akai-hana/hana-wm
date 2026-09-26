//! Monotonic and wall-clock reads.
//!
//! Two distinct families, deliberately not interchangeable: `monotonic*` is
//! wall-independent and is what deadlines and frame deltas must use;
//! `realtime*` is for displayed timestamps and expiry against the wall clock.
//! Kept together so a caller picks the family deliberately.

const std = @import("std");

// clock_gettime with a best-effort fallback to the other clock id (a
// monotonic-realtime node or similar), then nanos.
fn clockNs(clock_id: std.os.linux.clockid_t) u64 {
    var ts: std.os.linux.timespec = undefined;
    if (std.os.linux.clock_gettime(clock_id, &ts) != 0) {
        const fallback_id: std.os.linux.clockid_t =
            if (clock_id == .MONOTONIC) .REALTIME else .MONOTONIC;
        if (std.os.linux.clock_gettime(fallback_id, &ts) != 0)
            ts = .{ .sec = 0, .nsec = 0 };
    }
    return @as(u64, @intCast(ts.sec)) * 1_000_000_000 + @as(u64, @intCast(ts.nsec));
}

pub inline fn monotonicNs() u64 {
    return clockNs(.MONOTONIC);
}

/// Monotonic milliseconds (wall-independent; for deltas and deadlines).
pub inline fn monotonicMs() i64 {
    return @intCast(monotonicNs() / std.time.ns_per_ms);
}

/// Wall-clock milliseconds (for timestamps/expiry, not deltas).
pub inline fn realtimeMs() i64 {
    return @intCast(realtimeNs() / std.time.ns_per_ms);
}

pub inline fn realtimeNs() u64 {
    return clockNs(.REALTIME);
}
