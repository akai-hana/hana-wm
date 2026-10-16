//! Motion-run collapse tests (pure, headless).
//!
//! `collapseMotionRun` is the shared coalescing kernel behind both drain
//! paths: a run of MotionNotify events collapses to its LAST member before
//! dispatch (drag paths only need the freshest pointer position). It frees
//! every superseded motion, charges each drained motion into `budget` exactly
//! once, and stashes the terminating non-motion UNDELIVERED and UNCHARGED so
//! the caller re-pulls it (or dispatches it as the cap-hit tail).
//!
//! Those three properties -- newest-wins, single-charge, pause-undelivered --
//! are order-sensitive and free-sensitive, so they are pinned with synthetic
//! heap events and a scripted pull. No display, no model, no dispatcher: the
//! only global this touches is the test's own pull queue.

const std = @import("std");
const testing = std.testing;
const core = @import("core");
const events = @import("events");
const xcb = core.xcb;

/// Scripted pull queue. `collapseMotionRun` takes `pull` as a comptime
/// anytype, so a plain fn reading a file-scope queue stands in for the
/// real xcb_poll_for_event; `conn` is forwarded but unused here.
var q_events: [8]?*xcb.xcb_generic_event_t = undefined;
var q_len: usize = 0;
var q_pos: usize = 0;

fn testPull(_: core.Connection) ?*xcb.xcb_generic_event_t {
    if (q_pos >= q_len) return null;
    const e = q_events[q_pos].?;
    q_pos += 1;
    return e;
}

fn makeEvent(code: u8) !*xcb.xcb_generic_event_t {
    const raw = std.c.malloc(@sizeOf(xcb.xcb_generic_event_t)) orelse return error.OutOfMemory;
    const e: *xcb.xcb_generic_event_t = @ptrCast(@alignCast(raw));
    @memset(std.mem.asBytes(e), 0);
    // byte 0 is response_type; the masked code is what isMotion compares.
    @as(*u8, @ptrCast(e)).* = code;
    return e;
}

fn queue(events_in: []const *xcb.xcb_generic_event_t) void {
    q_events = undefined;
    q_len = events_in.len;
    q_pos = 0;
    for (events_in, 0..) |e, i| q_events[i] = e;
}

test "collapseMotionRun: a motion run collapses to the newest, freeing superseded" {
    // M1 M2 M3 then a key press. Caller owns M1 (charged it), collapse frees
    // M1 and M2 as they are superseded and adopts M3; K is stashed undelivered.
    const m1 = try makeEvent(xcb.XCB_MOTION_NOTIFY);
    const m2 = try makeEvent(xcb.XCB_MOTION_NOTIFY);
    const m3 = try makeEvent(xcb.XCB_MOTION_NOTIFY);
    const k = try makeEvent(xcb.XCB_KEY_PRESS);
    defer std.c.free(m3);
    defer std.c.free(k);
    // m1 is the caller's already-pulled event; the queue holds what is AHEAD.
    queue(&.{ m2, m3, k });

    var newest = m1; // caller-charged, caller-owned
    var budget: usize = 1;
    var pause: ?*xcb.xcb_generic_event_t = null;
    events.collapseMotionRun(&newest, &pause, undefined, &budget, 16, testPull);

    try testing.expectEqual(m3, newest);
    try testing.expectEqual(k, pause);
    // M2 and M3 charged by the collapse; M1 by the caller; K not at all.
    try testing.expectEqual(@as(usize, 3), budget);
    // m1 and m2 were freed inside; every queued event was pulled.
    try testing.expectEqual(@as(usize, 3), q_pos);
}

test "collapseMotionRun: the cap stops the collapse without stashing" {
    // budget at cap-1: one more motion fits and is charged to exactly cap;
    // the loop then stops WITHOUT pulling the trailing key press, so pause
    // stays null and the caller dispatches whatever it already has.
    const m1 = try makeEvent(xcb.XCB_MOTION_NOTIFY);
    const m2 = try makeEvent(xcb.XCB_MOTION_NOTIFY);
    const k = try makeEvent(xcb.XCB_KEY_PRESS);
    // m1 is freed by the collapse when m2 supersedes it; the test owns m2+k.
    defer std.c.free(m2);
    defer std.c.free(k);
    queue(&.{ m2, k });

    var newest = m1;
    var budget: usize = 1; // caller charged m1
    var pause: ?*xcb.xcb_generic_event_t = null;
    events.collapseMotionRun(&newest, &pause, undefined, &budget, 2, testPull);

    try testing.expectEqual(m2, newest);
    try testing.expect(pause == null);
    try testing.expectEqual(@as(usize, 2), budget);
    // k was never pulled: the collapse stopped at the cap, not at the tail.
    try testing.expectEqual(@as(usize, 1), q_pos);
}

test "collapseMotionRun: a non-motion first pull stashes immediately" {
    // The run is empty: the first pull is the terminating non-motion, which
    // is stashed undelivered and uncharged, and newest is untouched.
    const m1 = try makeEvent(xcb.XCB_MOTION_NOTIFY);
    const k = try makeEvent(xcb.XCB_KEY_PRESS);
    defer std.c.free(m1);
    defer std.c.free(k);
    queue(&.{k});

    var newest = m1;
    var budget: usize = 1;
    var pause: ?*xcb.xcb_generic_event_t = null;
    events.collapseMotionRun(&newest, &pause, undefined, &budget, 16, testPull);

    try testing.expectEqual(m1, newest);
    try testing.expectEqual(k, pause);
    try testing.expectEqual(@as(usize, 1), budget);
    try testing.expectEqual(@as(usize, 1), q_pos);
}
