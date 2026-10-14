//! Unit tests for the slider core's pure geometry helpers (slider.zig).
//! The multi-slot reference implementation lives HERE (slider is single-slot
//! per segment in production; the reference type + hit-tester exist only to
//! exercise the mapping logic).
//! These are state-free so they run against the real registry without
//! touching state; the subprocess-free paths avoid touching devices.

// build-gate: seg_slider, meter

const std = @import("std");
const slider = @import("slider");
const meter = @import("meter");
const types = @import("types");
const drawing = @import("drawing");
const testing = std.testing;

// (28.8) A test-local `Slot` + `slotAt` hit-test used to live here, with two
// tests covering them. Deleted, because they tested NOTHING in hana: `Slot`
// existed only in this file, `slotAt` was never called by production, and the
// caller that IS real (`slider.pctFromSlot`) takes the already-resolved
// (slot_x, slot_w) rather than a slot list. So the oracle was a second
// implementation of a concept the test invented, and it could only ever
// confirm that the test agreed with itself. The production behaviour those
// tests appeared to cover -- a zero-width slot mapping an offset rather than
// dividing by zero -- is asserted directly against pctFromSlot just below.

test "a zero-width slot still maps an offset instead of dividing by zero" {
    // The first-click case (26.3): before the segment's first draw there is
    // no painted width, so the mapping must still be defined and monotonic.
    // pctFromSlot clamps the denominator to 1, so any offset saturates rather
    // than wrapping or trapping.
    try testing.expectEqual(@as(u8, 0), slider.pctFromSlot(0, 0, 0));
    try testing.expectEqual(@as(u8, 100), slider.pctFromSlot(0, 0, 1));
    try testing.expectEqual(@as(u8, 100), slider.pctFromSlot(0, 0, 99));
}

test "pctFromSlot is the same mapping the click hit-test bounds" {
    // The hit-test rejects `offset >= bound` and the mapping saturates at
    // offset == bound, so no in-range click can land outside 0-100 and no
    // out-of-range click is accepted.
    const bound: u16 = 80;
    for (0..@as(u32, bound) * 2) |raw| {
        const off: u16 = @intCast(raw);
        if (off >= bound) continue;
        const pct = slider.pctFromSlot(0, bound, off);
        try testing.expect(pct <= 100);
    }
    try testing.expectEqual(@as(u8, 0), slider.pctFromSlot(0, bound, 0));
    try testing.expectEqual(@as(u8, 100), slider.pctFromSlot(0, bound, bound));
}

test "a slider's reservation follows the width the bar reports (21.7)" {
    // Same handoff as the systatus case, on the other consumer: the bar feeds
    // the painted width back through onPainted, and it lands in the control's
    // width state -- the single value naturalWidth, the click hit-test bound
    // and the drag denominator all read. The store is the shared one from
    // [21.4], so "changed -> owes a re-layout" is not re-implemented here.
    inline for (0..slider.subs.len) |i| {
        const seg = slider.segmentFor(i);
        // Wired for EVERY control, present or not: a control that is absent
        // today can come back on the next poll, and its hook must already be
        // feeding the same width state.
        const report = seg.onPainted orelse return error.TestUnexpectedResult;
        report(73);

        // Presence is a live device probe (no sound card in a test runner),
        // and an absent control reserves 0 by definition -- so only assert the
        // width for a control that is actually there.
        const present = slider.subPresent(slider.subs[i]);
        if (present) {
            // The reported width IS the reservation.
            try std.testing.expectEqual(@as(u16, 73), seg.naturalWidth.?(undefined, 4242));
            // Reporting 0 means "nothing painted", which is the
            // never-measured state: the reservation falls back to the
            // control's declared probe, NOT to 0 and not to the last painted
            // width. [21.4]'s rule, reached through [21.7]'s handoff.
            report(0);
            try std.testing.expectEqual(
                slider.subs[i].probeNaturalWidth,
                seg.naturalWidth.?(undefined, 4242),
            );
        }
    }
}

// (22.1/25.3) The value span the painter is handed. The paint that consumes
// it cannot run headlessly (Pango + cairo + a display), so the boundary
// arithmetic -- the part where an off-by-one hides -- is pure and tested here.
// (22.1) M13 shrinks the PAINTED range by one byte and passes the whole suite,
// so these cases are what make the DECISION checkable even though the paint is
// not. (25.3) The span is explicit offsets, not a subslice, so the tests say
// "at 4, length 2" instead of handing over a slice.

test "valueRange accepts an explicit span" {
    const t = "CPU 42%";
    const r = drawing.valueRange(t, 4, 2).?;
    try std.testing.expectEqual(@as(usize, 4), r.start);
    try std.testing.expectEqual(@as(usize, 2), r.len);
    // The span must land on the numeral, not one byte either side of it.
    try std.testing.expectEqualStrings("42", t[r.start..][0..r.len]);
}

test "valueRange is positional, so a repeated numeral resolves independently" {
    // "44/44" contains the same two bytes twice. A content-based check would
    // resolve both to the first; offsets address the span directly.
    const t = "44/44";
    const first = drawing.valueRange(t, 0, 2).?;
    const second = drawing.valueRange(t, 3, 2).?;
    try std.testing.expectEqual(@as(usize, 0), first.start);
    try std.testing.expectEqual(@as(usize, 3), second.start);
    try std.testing.expectEqual(@as(usize, 2), first.len);
    try std.testing.expectEqualStrings("44", t[second.start..][0..second.len]);
}

test "valueRange rejects an out-of-range span rather than clamping it" {
    // A bad span used to be a subslice check; it is now offsets, and an offset
    // past the end must be refused rather than trimmed, or the painter would
    // colour the wrong characters.
    const t = "CPU 42%";
    try std.testing.expect(drawing.valueRange(t, 6, 4) == null); // past the end
    try std.testing.expect(drawing.valueRange(t, 99, 1) == null); // start past the end
    try std.testing.expect(drawing.valueRange(t, 0, 99) == null); // longer than the text
}

test "valueRange rejects an empty span but accepts a whole-string one" {
    // An empty span would colour nothing, so it collapses to the single-colour
    // path. A whole-string span is legal: a value-only display (a slider whose
    // format is just "{pct}") wants its number tinted. That case was rejected
    // before 25.3, when the span was a subslice and a caller handing over the
    // whole text by accident looked identical to one meaning it.
    const t = "CPU 42%";
    try std.testing.expect(drawing.valueRange(t, 2, 0) == null);
    const all = drawing.valueRange(t, 0, t.len).?;
    try std.testing.expectEqual(@as(usize, 0), all.start);
    try std.testing.expectEqual(t.len, all.len);
}

test "valueRange covers a span at the very start and the very end" {
    // Off-by-one guard: the first and last legal byte positions both resolve,
    // and neither gains a byte it was not given.
    const t = "42% and 7%";
    const head = drawing.valueRange(t, 0, 2).?;
    try std.testing.expectEqual(@as(usize, 0), head.start);
    try std.testing.expectEqual(@as(usize, 2), head.len);
    const tail = drawing.valueRange(t, 8, 1).?;
    try std.testing.expectEqual(@as(usize, 8), tail.start);
    try std.testing.expectEqual(@as(usize, 1), tail.len);
    try std.testing.expectEqualStrings("7", t[tail.start..][0..tail.len]);
}

test "valueRange accepts a span ending exactly at the last byte" {
    // The exclusive upper bound is len, so start + len == text.len is legal.
    // This is the boundary most likely to be written as >= by mistake.
    const t = "RAM 42%";
    const r = drawing.valueRange(t, 4, 3).?;
    try std.testing.expectEqual(@as(usize, 4), r.start);
    try std.testing.expectEqual(@as(usize, 3), r.len);
    try std.testing.expectEqualStrings("42%", t[r.start..][0..r.len]);
}

test "valueRange rejects offsets that would overflow the bounds check" {
    // ReleaseFast does not trap on integer overflow, so `start + len` can wrap
    // to a small value and slip past a naive bounds check. These two guards are
    // what stop that, and removing either one is caught only by this test.
    const t = "CPU 42%";
    const huge = std.math.maxInt(usize);
    try std.testing.expect(drawing.valueRange(t, huge - 1, 2) == null);
    try std.testing.expect(drawing.valueRange(t, huge, 1) == null);
    try std.testing.expect(drawing.valueRange(t, 1, huge) == null);
    try std.testing.expect(drawing.valueRange(t, 0, huge) == null);
}

// A control the test can answer for, so presence and level are exercised in
// BOTH directions. Every real control is absent headless (no sound card, no
// backlight device), so a test reading `subs` can only ever confirm the
// "absent" branch -- and would agree with an implementation that ignored the
// level hook entirely. These fakes are what make the other half checkable.
var g_fake_answer: ?u8 = null;

fn fakeLevel() ?u8 {
    return g_fake_answer;
}

const FakeLevel = struct {
    fn levelHook() ?u8 {
        return g_fake_answer;
    }
    fn noop(_: slider.Write, _: u8) void {}
    fn yes() bool {
        return true;
    }
    fn noRead() bool {
        return false;
    }
    fn label(_: types.BarConfig, _: []u8) slider.Label {
        return .{ .text = "", .value_start = 0, .value_len = 0 };
    }
};

fn fakeSub(answer: ?u8) slider.Sub {
    g_fake_answer = answer;
    return .{
        .name = "fake",
        .level = FakeLevel.levelHook,
        .writable = FakeLevel.yes,
        .read = FakeLevel.noRead,
        .write = FakeLevel.noop,
        .commit_cost = struct {
            fn cost() slider.CommitCost {
                return .immediate;
            }
        }.cost,
        .label = FakeLevel.label,
    };
}

test "subPresent and subLevel read a control that HAS an answer" {
    const sub = fakeSub(42);
    try std.testing.expect(slider.subPresent(sub));
    try std.testing.expectEqual(@as(?u8, 42), slider.subLevel(sub));
    // A 0 % answer is an answer: presence must not be confused with a
    // nonzero level, or a muted control would vanish.
    try std.testing.expect(slider.subPresent(fakeSub(0)));
    try std.testing.expectEqual(@as(?u8, 0), slider.subLevel(fakeSub(0)));
}

test "subPresent and subLevel read a control that has NOT answered" {
    const sub = fakeSub(null);
    try std.testing.expect(!slider.subPresent(sub));
    try std.testing.expectEqual(@as(?u8, null), slider.subLevel(sub));
    // The consumers do not branch on the optional, they take the fallback. It
    // must be 0 -- the level an empty slider would have drawn -- and not an
    // arbitrary non-zero value that would fill a control that has no backend.
    try std.testing.expectEqual(@as(u8, 0), slider.subLevelOrZero(sub));
}

test "a control with no level hook is always present at 0" {
    // Null hook is the "always present" case, and it must not read as absent:
    // that would reserve no slot for a control that never needed a probe.
    const sub = fakeSub(50);
    var always = sub;
    always.level = null;
    try std.testing.expect(slider.subPresent(always));
    try std.testing.expectEqual(@as(?u8, 0), slider.subLevel(always));
    try std.testing.expectEqual(@as(u8, 0), slider.subLevelOrZero(always));
}

test "the slider re-export of the meter mapping is the same function" {
    // slider.pctFromSlot is now an alias for meter.pctFromSlot. A test of the
    // meter alone would not notice if the core's alias pointed somewhere else,
    // so check the alias against the real thing across both edge cases.
    const cases = [_][3]u16{
        .{ 10, 100, 10 }, .{ 10, 100, 60 }, .{ 10, 100, 110 },
        .{ 10, 100, 11 }, .{ 10, 100, 0 },  .{ 0, 0, 0 },
        .{ 0, 0, 40 },    .{ 0, 1, 3 },     .{ 65535, 65535, 40000 },
    };
    for (cases) |c| {
        try std.testing.expectEqual(
            meter.pctFromSlot(c[0], c[1], c[2]),
            slider.pctFromSlot(c[0], c[1], c[2]),
        );
    }
}
