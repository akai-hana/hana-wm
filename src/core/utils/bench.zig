//! Bench probe for the bar's X11 title pre-fetch path.
//! Counts blocking round-trips and wall time so callers can compare
//! before/after measurements when optimising cookie batching.

const std = @import("std");
const build = @import("build_options");
const xcb = @import("x11").xcb;

pub const enabled = build.bench;

var title_round_trips: std.atomic.Value(u64) = std.atomic.Value(u64).init(0);

/// Call before `reportTitleCapture` to reset the round-trip counter so
/// the subsequent report reflects only the current capture pass.
pub inline fn beginTitleCapture() void {
    if (comptime !enabled) return;
    _ = title_round_trips.store(0, .monotonic);
}

/// Output the wall time, window count, and blocking round-trip count
/// accumulated since the matching `beginTitleCapture` call.
pub inline fn reportTitleCapture(ns: u64, windows: usize) void {
    if (comptime !enabled) return;
    std.debug.print(
        "bench: title capture: {d} windows, {d} round-trips, {d} us\n",
        .{ windows, title_round_trips.load(.monotonic), ns / 1_000 },
    );
}

/// Non-blocking check for whether the reply to `sequence` is already in
/// xcb's read buffer.
///
/// Returns the heap-allocated reply pointer and counts zero round-trips
/// when the reply is available. The caller owns the pointer and must free
/// it with `std.c.free`. Having consumed the cookie the caller must NOT
/// call the corresponding blocking `xcb_*_reply` function.
///
/// Returns null and counts one round-trip when the reply is not yet
/// available, signaling the caller to fall through to its normal blocking
/// reply call. Also returns null when the request completed with an error;
/// the subsequent blocking call then resolves to the same failure the
/// non-bench build would have seen, so behavior is unchanged.
///
/// When the probe is disabled the function always returns null and counts
/// one round-trip, making every call site execute its normal blocking
/// path, identical to a non-bench build.
pub inline fn pollReply(conn: *xcb.xcb_connection_t, sequence: u32) ?*anyopaque {
    if (comptime !enabled) return null;
    var reply: ?*anyopaque = null;
    _ = xcb.xcb_poll_for_reply(conn, sequence, &reply, null);
    if (reply) |r| return r;
    _ = title_round_trips.fetchAdd(1, .monotonic);
    return null;
}
