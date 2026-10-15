//! configure_window wire-encoding tests (pure, headless).
//!
//! `xcb_configure_window` takes a flat value list consumed in mask-bit order
//! (X, Y, WIDTH, HEIGHT, BORDER_WIDTH, STACK_MODE), but as PACKED values, not
//! absolute slots: a mask with only WIDTH|HEIGHT set reads values[0] as width.
//! Nothing in the type system pins that packing, and X does not validate it
//! either -- a request that packs at absolute slots sends zeros for a partial
//! mask (width 0 is BadValue) and never resizes. So the assembly is pulled out
//! of the sink shim into `sink.configureWire` and pinned here with values
//! chosen so that any two packed positions being swapped fails.
//!
//! Also pinned: an absent part contributes NO mask bit (so a border-width-only
//! change cannot drag a geometry along), and the empty configure is mask 0,
//! which the shim drops rather than sending.
//!
//! Encoding rule (the reason these are positional): X does NOT index the value
//! list by mask bit -- it consumes slots SEQUENTIALLY, lowest set bit first.
//! So a lone WIDTH|HEIGHT mask reads values[0] as width, and a lone
//! STACK_MODE reads values[0] as the mode. Packing at absolute protocol slots
//! instead of packed order sends zeros and gets rejected (width/height 0 is
//! BadValue), which is exactly the bug the park shim already exposed: it uses
//! mask X|STACK_MODE with a 2-element list. The assertions below pin packed
//! order, not absolute slots.

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

fn model_dims(w: u16, h: u16) @import("model").Dims {
    return .{ .width = w, .height = h };
}

// The resize-while-parked shape: size-only, so X/Y must stay OUT of the mask
// (setting them would slide the parked window back over the live workspace).
test "size alone sets only the WIDTH/HEIGHT bits, leaving X/Y unset" {
    const w = sink.configureWire(.{ .size = model_dims(33, 44) });
    try testing.expectEqual(
        @as(u16, xcb.XCB_CONFIG_WINDOW_WIDTH | xcb.XCB_CONFIG_WINDOW_HEIGHT),
        w.mask,
    );
    try testing.expectEqual(@as(u32, 33), w.values[0]); // WIDTH (packed first)
    try testing.expectEqual(@as(u32, 44), w.values[1]); // HEIGHT
    try testing.expectEqual(@as(u32, 0), w.values[2]); // tail slot, unconsumed
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
    try testing.expectEqual(@as(u32, bw), w.values[0]); // bw packed first
    // The whole point of the optionals: a bw-only configure must not also
    // assert X/Y/W/H, which would move/resize a window the WM never recomputed.
    // (mask carries only BORDER_WIDTH, so X never reads the tail slots.)
}

test "stack alone lands as the first (only) packed value" {
    const w = sink.configureWire(.{ .stack = .above });
    try testing.expectEqual(@as(u16, xcb.XCB_CONFIG_WINDOW_STACK_MODE), w.mask);
    try testing.expectEqual(@as(u32, xcb.XCB_STACK_MODE_ABOVE), w.values[0]);
}

test "all three parts coexist in one request, each in its own slot" {
    // This is the case the merged `configure` slot exists for: rect, border
    // width and stack mode are wanted in ONE request.
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
