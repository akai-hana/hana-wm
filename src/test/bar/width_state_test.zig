//! The shared drawn-width rule (`scaffold.widthState`).
//!
//! systatus and slider both reserve a row span, feed it the width they actually
//! painted, and owe a redraw when that width changes. slider used to keep its
//! own `slot_w` field for this (21.4), and the copy had already drifted once:
//! the click hit-test read the raw painted width and so rejected every press
//! while it was still 0 -- the first click on a freshly laid-out slider did
//! nothing -- while the drag denominator and the row reservation fell back to
//! different values in the same frame. These tests pin the one definition all
//! three now share.

const std = @import("std");
const contract = @import("contract");
const scaffold = @import("scaffold");

/// A mutable cell a module-level `onPainted` can write, so the test can watch
/// the handback. Zig has no closures over locals, so the segment's sink is a
/// named function reading a test-owned global.
var last_reported: ?u16 = null;
fn reportToCell(w: u16) void {
    last_reported = w;
}

test "a never-painted width state reserves the declared probe, not zero" {
    // A unique comptime tag instantiates a FRESH singleton, so `cached` is the
    // 0 it starts at: this is the "no measurement yet" state.
    const W = scaffold.widthState("test:width_state:never_painted");

    try std.testing.expectEqual(@as(u16, 0), W.measured());

    // Reserving 0 here would collapse the row on the very first layout pass,
    // before the segment has had a chance to draw.
    try std.testing.expectEqual(@as(u16, 140), W.resolved(140));

    // Once painted, the measurement wins and the probe is irrelevant.
    W.store(90);
    try std.testing.expectEqual(@as(u16, 90), W.measured());
    try std.testing.expectEqual(@as(u16, 90), W.resolved(140));
}

test "a segment that painted zero is the no-measurement state, not a zero span" {
    // An absent readout (no battery, unreadable file) paints nothing. It is
    // indistinguishable from "never painted", and must not pin the row at 0
    // any more than a fresh segment does.
    const W = scaffold.widthState("test:width_state:collapsed");
    W.store(64);
    try std.testing.expectEqual(@as(u16, 64), W.resolved(20));

    W.store(0);
    try std.testing.expectEqual(@as(u16, 0), W.measured());
    try std.testing.expectEqual(@as(u16, 20), W.resolved(20));
}

test "a width change owes exactly one redraw, and re-storing does not" {
    const W = scaffold.widthState("test:width_state:redraw");
    try std.testing.expect(!W.consumeRedrawRequest());

    W.store(30);
    try std.testing.expect(W.consumeRedrawRequest());
    // The request is consumed once: leaving it set would busy-loop the bar's
    // re-request drain forever.
    try std.testing.expect(!W.consumeRedrawRequest());

    // Same width again: nothing changed, so nothing to repaint.
    W.store(30);
    try std.testing.expect(!W.consumeRedrawRequest());

    // A different width does owe one, in either direction.
    W.store(31);
    try std.testing.expect(W.consumeRedrawRequest());
    W.store(30);
    try std.testing.expect(W.consumeRedrawRequest());
}

test "each tag is its own state, so controls cannot overwrite each other" {
    // The whole reason slider keys the singleton by control name: two
    // readouts storing different widths must not share a cache.
    const A = scaffold.widthState("test:width_state:iso_a");
    const B = scaffold.widthState("test:width_state:iso_b");
    A.store(11);
    B.store(22);
    try std.testing.expectEqual(@as(u16, 11), A.measured());
    try std.testing.expectEqual(@as(u16, 22), B.measured());
}

test "the bar's post-draw step hands the width back and reports a paint (21.7)" {
    // This is the handoff the whole item is about, and it lived inside the
    // bar's draw loop -- which needs a live DrawContext and an X connection,
    // so it had no test at all. `scaffold.finishDraw` is that policy as a pure
    // function over a Segment and a Painted, so both halves are checkable
    // against a Segment built right here, with no server.
    //
    // The two directions of failure are both silent in production: no handback
    // locks a segment onto its startup width, and a bogus "it painted" answer
    // advances the row past a slot that is still empty.
    last_reported = null;
    const seg: contract.Segment = .{
        .name = "test_finish_draw",
        .onPainted = reportToCell,
    };

    const P = contract.Painted;
    try std.testing.expect(scaffold.finishDraw(&seg, P.span(100, 160)));
    try std.testing.expectEqual(@as(?u16, 60), last_reported);

    // A zero-width draw is a SUCCESS that paints nothing: no paint for the
    // row, but the width is still reported, so the segment's reservation can
    // collapse to it.
    try std.testing.expect(!scaffold.finishDraw(&seg, P.nothing(100)));
    try std.testing.expectEqual(@as(?u16, 0), last_reported);
}
