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
/// Tri-state (ND-18): `xcb_poll_for_reply` consumes the cookie on BOTH
/// success and error, so a plain "null means block" contract was unsound —
/// blocking on a consumed-error cookie has undefined XCB semantics. Callers
/// must treat `.error_consumed` as a terminal failure, never fall through to
/// `xcb_*_reply`.
pub const PollOutcome = union(enum) {
    /// Reply available; caller owns the pointer and must free it with
    /// `std.c.free`. The cookie is consumed — do NOT block on it.
    ready: *anyopaque,
    /// Reply not yet buffered; the cookie was NOT consumed. Fall through to
    /// the normal blocking reply call.
    pending,
    /// The request completed with an X error, which the poll consumed
    /// (freed here). Skip straight to the caller's error path.
    error_consumed,
};

/// When the probe is disabled the function always returns `.pending`,
/// making every call site execute its normal blocking path, identical to a
/// non-bench build (the round-trip counter still ticks for parity).
pub inline fn pollReply(conn: *xcb.xcb_connection_t, sequence: u32) PollOutcome {
    if (comptime !enabled) return .pending;
    var reply: ?*anyopaque = null;
    var err: ?*xcb.xcb_generic_error_t = null;
    _ = xcb.xcb_poll_for_reply(conn, sequence, &reply, &err);
    if (reply) |r| return .{ .ready = r };
    _ = title_round_trips.fetchAdd(1, .monotonic);
    if (err) |e| {
        std.c.free(e);
        return .error_consumed;
    }
    return .pending;
}
