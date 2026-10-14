//! Unit tests for the ICCCM 4.1.7 focus-model resolution over the
//! focus-property cache (owned by focus.zig since the merge from
//! icccm.zig): the (take_focus × accepts_input) matrix, the cache-miss
//! contract, and the provisional fallback. The queries themselves are
//! X-gated and covered by the admission/focus integration paths; this pins
//! the pure verdict half they all share.

const std = @import("std");
const testing = std.testing;

const focus = @import("focus");

test "peek on an empty cache is a miss (never a blocking query)" {
    focus.reset();
    defer focus.reset();
    try testing.expect(focus.peekInputModelResolved(42) == null);
}

test "ICCCM 4.1.7 matrix: take_focus × accepts_input selects the delivery model" {
    focus.reset();
    defer focus.reset();

    // (take_focus, accepts_input) → model, per §4.1.7.
    const Case = struct { take_focus: bool, accepts_input: bool, model: focus.InputModel };
    const cases = [_]Case{
        .{ .take_focus = false, .accepts_input = false, .model = .no_input },
        .{ .take_focus = false, .accepts_input = true, .model = .passive },
        .{ .take_focus = true, .accepts_input = true, .model = .locally_active },
        .{ .take_focus = true, .accepts_input = false, .model = .globally_active },
    };

    for (cases, 0..) |c, i| {
        const win: u32 = @intCast(100 + i);
        focus.put(win, .{
            .accepts_input = c.accepts_input,
            .wm_delete = false,
            .take_focus = c.take_focus,
        });
        const r = focus.peekInputModelResolved(win);
        try testing.expect(r != null);
        try testing.expectEqual(c.model, r.?.model);
        try testing.expectEqual(c.take_focus, r.?.take_focus);
    }
}

test "provisionalResolution is the documented miss-path verdict" {
    // The focus hot path resolves a cache miss as passive-without-TAKE_FOCUS
    // (dwm-style provisional focus), never a live query; the next map or
    // property refresh corrects it.
    const r = focus.provisionalResolution();
    try testing.expectEqual(focus.InputModel.passive, r.model);
    try testing.expect(!r.take_focus);
}

test "cache eviction puts a window back on the miss path" {
    focus.reset();
    defer focus.reset();

    focus.put(7, .{ .accepts_input = true, .wm_delete = true, .take_focus = true });
    try testing.expect(focus.peekInputModelResolved(7) != null);
    focus.evict(7);
    try testing.expect(focus.peekInputModelResolved(7) == null);
}
