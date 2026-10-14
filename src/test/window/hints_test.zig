//! Headless tests for hints.zig's pure WM_NORMAL_HINTS parse:
//! the flags -> field-offset -> model.SizeHints derivation,
//! lifted out of window.zig so the ICCCM field walk is
//! unit-testable without a connection or a live reply.

const std = @import("std");
const testing = std.testing;
const hints = @import("hints");

/// Zeroes `arr`, sets the flags word, then writes `values` into
/// fields[1..] (the caller owns the storage, so the many-item
/// pointer the parse takes stays valid).
fn fill18(arr: *[18]u32, comptime flags: u32, comptime values: anytype) void {
    arr.* = @splat(0);
    arr[0] = flags;
    inline for (values, 0..) |v, i| arr[i + 1] = v;
}

test "no constraint flag set -> null" {
    var arr: [18]u32 = undefined;
    fill18(&arr, 0, .{});
    try testing.expect(hints.parse(&arr, 18) == null);
}

test "PMinSize only" {
    // PMinSize pair lives at fields[5..6] -> value index 4..5.
    var arr: [18]u32 = undefined;
    fill18(&arr, 0x10, .{ 0, 0, 0, 0, 100, 200 });
    const h = hints.parse(&arr, 18).?;
    try testing.expectEqual(@as(u16, 100), h.min_width);
    try testing.expectEqual(@as(u16, 200), h.min_height);
    try testing.expectEqual(@as(u16, 0), h.max_width);
    try testing.expectEqual(@as(u16, 0), h.max_height);
    try testing.expectEqual(@as(u16, 0), h.inc_width);
    try testing.expectEqual(@as(u16, 0), h.inc_height);
    try testing.expectEqual(@as(f32, 0.0), h.min_aspect);
    try testing.expectEqual(@as(f32, 0.0), h.max_aspect);
}

test "PMinSize + PBaseSize: effective floor is the larger" {
    // min at fields[5..6] (idx 4..5), base at fields[15..16] (idx 14..15).
    var arr: [18]u32 = undefined;
    fill18(&arr, 0x10 | 0x100, .{ 0, 0, 0, 0, 50, 50, 0, 0, 0, 0, 0, 0, 0, 0, 80, 60 });
    const h = hints.parse(&arr, 18).?;
    try testing.expectEqual(@as(u16, 80), h.min_width);
    try testing.expectEqual(@as(u16, 60), h.min_height);
}

test "PMaxSize + PResizeInc" {
    // max at fields[7..8] (idx 6..7), inc at fields[9..10] (idx 8..9).
    var arr: [18]u32 = undefined;
    fill18(&arr, 0x20 | 0x40, .{ 0, 0, 0, 0, 0, 0, 1920, 1080, 8, 8 });
    const h = hints.parse(&arr, 18).?;
    try testing.expectEqual(@as(u16, 1920), h.max_width);
    try testing.expectEqual(@as(u16, 1080), h.max_height);
    try testing.expectEqual(@as(u16, 8), h.inc_width);
    try testing.expectEqual(@as(u16, 8), h.inc_height);
}

test "PAspect dwm convention: min = y/x, max = x/y" {
    // aspect at fields[11..14] (idx 10..13): min.x, min.y, max.x, max.y.
    var arr: [18]u32 = undefined;
    fill18(&arr, 0x80, .{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 2, 3, 9, 3 });
    const h = hints.parse(&arr, 18).?;
    try testing.expectEqual(@as(f32, 1.5), h.min_aspect);
    try testing.expectEqual(@as(f32, 3.0), h.max_aspect);
}

test "flag set but truncated reply yields zero pairs" {
    // PMaxSize declared but only fields[0..7] present: fields[8] missing.
    var arr: [8]u32 = @splat(0);
    arr[0] = 0x20;
    arr[7] = 500;
    const h = hints.parse(&arr, 8).?;
    try testing.expectEqual(@as(u16, 0), h.max_width);
    try testing.expectEqual(@as(u16, 0), h.max_height);
}

test "aspect zero denominators clamp to 0.0" {
    // min_aspect.x = 0 -> min 0.0; max_aspect.y = 0 -> max 0.0.
    var arr: [18]u32 = undefined;
    fill18(&arr, 0x80, .{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 3, 9, 0 });
    const h = hints.parse(&arr, 18).?;
    try testing.expectEqual(@as(f32, 0.0), h.min_aspect);
    try testing.expectEqual(@as(f32, 0.0), h.max_aspect);
}
