//! Opt-in performance probe. Compiled out entirely (zero overhead) unless the
//! build is configured with -Dbench.
//!
//! Counts blocking X11 round-trips issued by the bar's title/geometry
//! pre-fetch paths and times each `bar.captureStateIntoSlot` pass, so
//! before/after measurements of a change (e.g. cookie batching) can be
//! compared directly. The counters are only touched on the main thread, but
//! they are atomic anyway so the probe stays safe regardless of call site.
//!
//! A "round-trip" is counted only when a reply is NOT already in xcb's read
//! buffer (via `xcb_poll_for_reply`) and therefore forces a blocking wait on
//! the socket. Replies that were drained in an earlier read of the same batch
//! are free. When the probe is disabled, `pollReply` always reports a miss and
//! every call site falls through to its normal blocking reply — identical to
//! the non-bench build.

const std = @import("std");
const build = @import("build_options");
const xcb = @import("x11").xcb;

pub const enabled = build.bench;

var title_round_trips: std.atomic.Value(u64) = std.atomic.Value(u64).init(0);

/// Zero the round-trip counter. Call at the start of the region to be
/// measured so the per-capture report that follows is self-contained.
pub inline fn beginTitleCapture() void {
    if (comptime !enabled) return;
    _ = title_round_trips.store(0, .monotonic);
}

/// Print a one-line summary for one title pre-fetch pass: window count,
/// blocking round-trips issued on the title/geometry paths since
/// `beginTitleCapture`, and the elapsed wall time.
pub inline fn reportTitleCapture(ns: u64, windows: usize) void {
    if (comptime !enabled) return;
    std.debug.print(
        "bench: title capture: {d} windows, {d} round-trips, {d} us\n",
        .{ windows, title_round_trips.load(.monotonic), ns / 1_000 },
    );
}

/// Probe for whether the reply to request `sequence` is already available in
/// xcb's read buffer.
///
/// When it is, returns the reply pointer (consumed here — the caller must NOT
/// call the blocking `xcb_*_reply` function for this cookie again) and counts
/// no round-trip. The returned pointer is heap-allocated by xcb and must be
/// freed with `std.c.free`, exactly like a reply from the blocking path.
///
/// When it is not (or the probe is disabled), returns null after counting one
/// round-trip; the caller should proceed with its normal blocking reply call,
/// which performs the actual wait. `null` is also returned when the request
/// has already completed with an error rather than a reply — the subsequent
/// blocking call then resolves quickly to the same failure the non-bench
/// build would have seen, so behavior is unchanged.
pub inline fn pollReply(conn: *xcb.xcb_connection_t, sequence: u32) ?*anyopaque {
    if (comptime !enabled) return null;
    var reply: ?*anyopaque = null;
    _ = xcb.xcb_poll_for_reply(conn, sequence, &reply, null);
    if (reply) |r| return r;
    _ = title_round_trips.fetchAdd(1, .monotonic);
    return null;
}
