//! configure_window wire-encoding tests (pure, headless).
//!
//! `xcb_configure_window` takes a flat value array whose slots are consumed in
//! the order the mask bits imply: X, Y, WIDTH, HEIGHT, BORDER_WIDTH,
//! STACK_MODE. Nothing in the type system pins that order, and X does not
//! validate it either -- a request with WIDTH in the HEIGHT slot is perfectly
//! legal and silently renders every window at the wrong shape. So the assembly
//! is pulled out of the sink shim into `sink.configureWire` and pinned here
//! with values chosen so that any two slots being swapped fails.
//!
//! Also pinned: an absent part contributes NO mask bit (so a border-width-only
//! change cannot drag a geometry along), and the empty configure is mask 0,
//! which the shim drops rather than sending.

const std = @import("std");
const testing = std.testing;

const sink = @import("sink");
const xcb = @import("xcb").xcb;

// All-distinct so a transposed slot cannot compare equal by accident.
const rect = model_rect(11, 22, 33, 44);
const bw: u16 = 55;

fn model_rect(x: i32, y: i32, w: u16, h: u16) @import("model").Rect {
    return .{ .x = x, .y = y, .width = w, .height = h };
}

test "rect alone sets exactly the four geometry bits, in protocol slot order" {
    const w = sink.configureWire(.{ .rect = rect });
    try testing.expectEqual(
        @as(u16, xcb.XCB_CONFIG_WINDOW_X | xcb.XCB_CONFIG_WINDOW_Y |
            xcb.XCB_CONFIG_WINDOW_WIDTH | xcb.XCB_CONFIG_WINDOW_HEIGHT),
        w.mask,
    );
    try testing.expectEqual(@as(u32, 11), w.values[0]); // X
    try testing.expectEqual(@as(u32, 22), w.values[1]); // Y
    try testing.expectEqual(@as(u32, 33), w.values[2]); // WIDTH
    try testing.expectEqual(@as(u32, 44), w.values[3]); // HEIGHT
    try testing.expectEqual(@as(u32, 0), w.values[4]); // untouched bw slot
    try testing.expectEqual(@as(u32, 0), w.values[5]); // untouched stack slot
}

test "border width alone touches no geometry bit" {
    const w = sink.configureWire(.{ .bw = bw });
    try testing.expectEqual(@as(u16, xcb.XCB_CONFIG_WINDOW_BORDER_WIDTH), w.mask);
    try testing.expectEqual(@as(u32, bw), w.values[4]);
    // The whole point of the optionals: a bw-only configure must not also
    // assert X/Y/W/H, which would move/resize a window the WM never recomputed.
    try testing.expectEqual(@as(u32, 0), w.values[0]);
    try testing.expectEqual(@as(u32, 0), w.values[1]);
    try testing.expectEqual(@as(u32, 0), w.values[2]);
    try testing.expectEqual(@as(u32, 0), w.values[3]);
}

test "stack alone lands in the STACK_MODE slot" {
    const w = sink.configureWire(.{ .stack = .above });
    try testing.expectEqual(@as(u16, xcb.XCB_CONFIG_WINDOW_STACK_MODE), w.mask);
    try testing.expectEqual(@as(u32, xcb.XCB_STACK_MODE_ABOVE), w.values[5]);
    try testing.expectEqual(@as(u32, 0), w.values[4]);
}

test "all three parts coexist in one request, each in its own slot" {
    // This is the case the merged `configure` slot exists for: the old
    // geom+geom_bordered pair could not express it as one request at all.
    const w = sink.configureWire(.{ .rect = rect, .bw = bw, .stack = .above });
    try testing.expectEqual(
        @as(u16, xcb.XCB_CONFIG_WINDOW_X | xcb.XCB_CONFIG_WINDOW_Y |
            xcb.XCB_CONFIG_WINDOW_WIDTH | xcb.XCB_CONFIG_WINDOW_HEIGHT |
            xcb.XCB_CONFIG_WINDOW_BORDER_WIDTH | xcb.XCB_CONFIG_WINDOW_STACK_MODE),
        w.mask,
    );
    try testing.expectEqual(@as(u32, 11), w.values[0]);
    try testing.expectEqual(@as(u32, 22), w.values[1]);
    try testing.expectEqual(@as(u32, 33), w.values[2]);
    try testing.expectEqual(@as(u32, 44), w.values[3]);
    try testing.expectEqual(@as(u32, bw), w.values[4]);
    try testing.expectEqual(@as(u32, xcb.XCB_STACK_MODE_ABOVE), w.values[5]);
}

test "an empty configure is mask 0, so the shim drops it" {
    try testing.expectEqual(@as(u16, 0), sink.configureWire(.{}).mask);
}
