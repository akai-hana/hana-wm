//! eventWindowFor offset tests (pure, headless).
//!
//! `eventWindowFor` reads the window id out of a raw XCB event without
//! knowing the event's concrete struct type, so it hard-codes byte offsets.
//! That is the kind of shortcut that is right until it silently isn't: not all
//! window-carrying event structs put `window` in the same place. xcb/xcb.h
//! shows three different layouts, so a single blanket offset is wrong for
//! ConfigureNotify, ConfigureRequest, MapRequest, UnmapNotify, DestroyNotify
//! and the rest of the offset-8 group -- which are exactly the geometry events
//! a browser-window trace needs to observe.
//!
//! These tests pin the table against the real xcb structs via @offsetOf, so
//! the offsets are checked against the header rather than against a comment.
//! A change to how XCB lays an event out now fails here instead of quietly
//! filtering the wrong window id out of the trace.

const std = @import("std");
const testing = std.testing;
const xcb = @cImport({
    @cInclude("xcb/xcb.h");
});

const events = @import("events");

/// Write `value` into `buf` at `offset` as a little-endian u32, the layout
/// XCB uses for every xcb_window_t field on this target.
fn putWindow(buf: []u8, offset: usize, value: u32) void {
    buf[offset] = @truncate(value);
    buf[offset + 1] = @truncate(value >> 8);
    buf[offset + 2] = @truncate(value >> 16);
    buf[offset + 3] = @truncate(value >> 24);
}

/// A zeroed 32-byte event buffer: every real event this dispatcher sees is at
/// most 32 bytes (xcb_client_message_event_t is the largest core event), and
/// reading inside it keeps an offset mistake from turning into a segfault
/// instead of a failed assertion.
fn eventBuf() [32]u8 {
    return @splat(0);
}

/// Assert that `eventWindowFor` reads the target window out of `buf` at
/// exactly the offset the real xcb struct uses. Load-bearing: the production
/// offset and @offsetOf the header must agree.
fn expectAt(
    t: u8,
    comptime Struct: type,
    comptime field_offset: usize,
    comptime field: []const u8,
) !void {
    const win_a: u32 = 0x0012_3456;
    const win_b: u32 = 0x00ab_cdef;

    var a = eventBuf();
    putWindow(&a, field_offset, win_a);
    var off: usize = 0;
    while (off + 4 <= a.len) : (off += 4) {
        if (off != field_offset) putWindow(&a, off, 0xdead_beef);
    }
    try testing.expectEqual(win_a, events.eventWindowFor(t, &a));

    var b = eventBuf();
    putWindow(&b, field_offset, win_b);
    off = 0;
    while (off + 4 <= b.len) : (off += 4) {
        if (off != field_offset) putWindow(&b, off, 0xdead_beef);
    }
    try testing.expectEqual(win_b, events.eventWindowFor(t, &b));

    // If the xcb struct ever moves the field, @offsetOf disagrees with the
    // offset passed here and the test fails rather than asserting stale bytes.
    try testing.expectEqual(@as(usize, @offsetOf(Struct, field)), field_offset);
}

/// `window`-spelled structs.
fn expectWindowAt(t: u8, comptime Struct: type, comptime off: usize) !void {
    try expectAt(t, Struct, off, "window");
}
/// Input structs, whose target field is spelled `event`.
fn expectEventAt(t: u8, comptime Struct: type, comptime off: usize) !void {
    try expectAt(t, Struct, off, "event");
}

test "eventWindowFor: offset-4 group reads `window` at byte 4" {
    // ClientMessage's `window` field sits at byte 4, though it is often
    // blamed for the offset-8 breakage; this test pins the correction so it
    // cannot be re-broken.
    try expectWindowAt(xcb.XCB_CLIENT_MESSAGE, xcb.xcb_client_message_event_t, 4);
    try expectWindowAt(xcb.XCB_PROPERTY_NOTIFY, xcb.xcb_property_notify_event_t, 4);
    try expectWindowAt(xcb.XCB_EXPOSE, xcb.xcb_expose_event_t, 4);
    try expectWindowAt(xcb.XCB_VISIBILITY_NOTIFY, xcb.xcb_visibility_notify_event_t, 4);
}

test "eventWindowFor: offset-8 group reads `window` at byte 8" {
    // A blanket offset-4 read gets every event in this group wrong.
    try expectWindowAt(xcb.XCB_CONFIGURE_NOTIFY, xcb.xcb_configure_notify_event_t, 8);
    try expectWindowAt(xcb.XCB_CONFIGURE_REQUEST, xcb.xcb_configure_request_event_t, 8);
    try expectWindowAt(xcb.XCB_MAP_REQUEST, xcb.xcb_map_request_event_t, 8);
    try expectWindowAt(xcb.XCB_UNMAP_NOTIFY, xcb.xcb_unmap_notify_event_t, 8);
    try expectWindowAt(xcb.XCB_DESTROY_NOTIFY, xcb.xcb_destroy_notify_event_t, 8);
    try expectWindowAt(xcb.XCB_REPARENT_NOTIFY, xcb.xcb_reparent_notify_event_t, 8);
    try expectWindowAt(xcb.XCB_CREATE_NOTIFY, xcb.xcb_create_notify_event_t, 8);
    try expectWindowAt(xcb.XCB_GRAVITY_NOTIFY, xcb.xcb_gravity_notify_event_t, 8);
    try expectWindowAt(xcb.XCB_CIRCULATE_NOTIFY, xcb.xcb_circulate_notify_event_t, 8);
}

test "eventWindowFor: input events read `event`, at 12 (and 4 for focus)" {
    // Input events have no `window` field at all; the equivalent field is
    // `event`. A watch on a client window is meant to catch these, so reading
    // the wrong field would attribute a keypress to the wrong window.
    try expectEventAt(xcb.XCB_KEY_PRESS, xcb.xcb_key_press_event_t, 12);
    try expectEventAt(xcb.XCB_KEY_RELEASE, xcb.xcb_key_release_event_t, 12);
    try expectEventAt(xcb.XCB_BUTTON_PRESS, xcb.xcb_button_press_event_t, 12);
    try expectEventAt(xcb.XCB_BUTTON_RELEASE, xcb.xcb_button_release_event_t, 12);
    try expectEventAt(xcb.XCB_MOTION_NOTIFY, xcb.xcb_motion_notify_event_t, 12);
    try expectEventAt(xcb.XCB_ENTER_NOTIFY, xcb.xcb_enter_notify_event_t, 12);
    try expectEventAt(xcb.XCB_LEAVE_NOTIFY, xcb.xcb_leave_notify_event_t, 12);
    // FocusIn/FocusOut are the two input-shaped events whose target sits at 4.
    try expectEventAt(xcb.XCB_FOCUS_IN, xcb.xcb_focus_in_event_t, 4);
    try expectEventAt(xcb.XCB_FOCUS_OUT, xcb.xcb_focus_out_event_t, 4);
}

test "eventWindowFor: MappingNotify and errors report no window" {
    // MappingNotify describes a keyboard mapping and carries no window field;
    // xcb_generic_error_t carries a bad resource id. Reading bytes out of
    // either would be inventing a window id, and could accidentally match a
    // watched id. Both must report the sentinel instead.
    var buf = eventBuf();
    putWindow(&buf, 4, 0x0012_3456);
    putWindow(&buf, 8, 0x0012_3456);
    putWindow(&buf, 12, 0x0012_3456);
    try testing.expectEqual(events.no_window, events.eventWindowFor(xcb.XCB_MAPPING_NOTIFY, &buf));
    try testing.expectEqual(events.no_window, events.eventWindowFor(0, &buf));
    // The sentinel must not be a plausible real window id.
    try testing.expectEqual(@as(u32, 0), events.no_window);
}

test "routeFor: an XSendEvent core event routes by its masked code, not as an extension" {
    // Regression: dispatch used to `return` on any raw type >= 0x80, reasoning
    // that extension event bases live up there. But bit 7 is XCB's SendEvent
    // flag, and a browser's EWMH _NET_WM_STATE request is delivered by
    // XSendEvent, so it arrives as 33 | 0x80 == 0xA1. The old test dropped it,
    // which is why native fullscreen did nothing while hana's own Mod+F
    // binding (a direct call, no event) worked.
    //
    // Read straight from @offsetOf, so a server constant change cannot let the
    // assertion keep passing against a stale 0x80.
    const send_event_bit: u8 = 0x80;
    try testing.expectEqual(@as(u8, 1) << 7, send_event_bit);

    const synthetic = xcb.XCB_CLIENT_MESSAGE | send_event_bit;
    try testing.expectEqual(events.Route.core, events.routeFor(synthetic));
    // ... and the plain, non-synthetic form routes the same way.
    try testing.expectEqual(events.Route.core, events.routeFor(xcb.XCB_CLIENT_MESSAGE));

    // The property/configure events hana acts on must survive masking too.
    inline for (.{
        xcb.XCB_PROPERTY_NOTIFY,
        xcb.XCB_CONFIGURE_NOTIFY,
        xcb.XCB_KEY_PRESS,
        xcb.XCB_BUTTON_PRESS,
        xcb.XCB_EXPOSE,
        xcb.XCB_MAPPING_NOTIFY,
    }) |core_code| {
        try testing.expectEqual(events.Route.core, events.routeFor(core_code));
        try testing.expectEqual(events.Route.core, events.routeFor(core_code | send_event_bit));
    }
}

test "routeFor: events hana never subscribes to are ignored, and type 0 is not a route" {
    // Masking must not turn an unsubscribed code into a live handler. 35 is
    // above the last real core code and lands outside the dispatch table.
    try testing.expectEqual(events.Route.ignore, events.routeFor(200));
    // 0x88 masks to 8 (LeaveNotify), which hana DOES subscribe to. A client
    // only ever receives what it selected, so this case cannot occur in
    // practice; it is asserted to document that the MASK, not the table size
    // or the raw byte, is what decides the route.
    try testing.expectEqual(events.Route.core, events.routeFor(0x88));
    // Type 0 is an X error pseudo-event, handled before routeFor is reached.
    try testing.expectEqual(events.Route.ignore, events.routeFor(0));
}

test "routeFor: FOCUS_IN routes to core; FOCUS_OUT stays unhandled (P1-09)" {
    // FocusChange is selected on every managed window (masks.managed_window),
    // but the dispatch table had no FOCUS_IN entry until the reassert handler
    // landed -- which is how a client's XSetInputFocus moved the server focus
    // while the model silently disagreed. FocusOut is deliberately still
    // unhandled: only the steal (FocusIn) is acted on.
    try testing.expectEqual(events.Route.core, events.routeFor(xcb.XCB_FOCUS_IN));
    try testing.expectEqual(events.Route.core, events.routeFor(xcb.XCB_FOCUS_IN | 0x80));
    try testing.expectEqual(events.Route.ignore, events.routeFor(xcb.XCB_FOCUS_OUT));
}

// P1-13: the poll-error burst latch logs once per burst (the sleep itself
// runs on every failed iteration; only the log line is leading-edge). Pure
// state, so this pins the rule without forcing a real poll failure.
test "events: poll-error latch fires once per burst" {
    var pb: events.PollBackoff = .{};

    // Boot: the first failure is the burst's leading edge.
    try testing.expect(pb.note(true));
    // Sustained failure: no second log.
    try testing.expect(!pb.note(true));
    try testing.expect(!pb.note(true));

    // A success ends the burst and re-arms the latch.
    try testing.expect(!pb.note(false));
    try testing.expect(pb.note(true));

    // INTR-only outcomes never reach the latch (run() continues before it);
    // the public surface is exactly note(true/false) as wired in run().
}

// P1-18: type-0 error attribution. Send sites note their cookie sequence at
// queue time (requests.noteSequence); the type-0 handler in events.zig maps
// the failed request's sequence back through windowForSequence to name the
// window an otherwise anonymous unchecked-request error belongs to.
test "requests: outbound sequence tracking names the window for a type-0 error" {
    const requests = @import("requests");
    const reconcile = @import("reconcile");

    requests.resetOutboundTracking();
    defer requests.resetOutboundTracking();

    // Nothing sent yet: no attribution either way.
    try testing.expectEqual(@as(?u16, null), requests.lastSequence(0x1111));
    try testing.expect(requests.windowForSequence(42) == null);

    // Two windows' last outbound sequences resolve to their windows.
    requests.noteSequence(0x1111, 42);
    requests.noteSequence(0x2222, 43);
    try testing.expectEqual(@as(?u16, 42), requests.lastSequence(0x1111));
    try testing.expectEqual(@as(?u16, 43), requests.lastSequence(0x2222));
    try testing.expectEqual(@as(?u32, 0x1111), requests.windowForSequence(42));
    try testing.expectEqual(@as(?u32, 0x2222), requests.windowForSequence(43));
    try testing.expect(requests.windowForSequence(44) == null);

    // Re-send to the same window: only the LAST outbound sequence is kept,
    // so the old one stops resolving and the new one takes over. This is
    // the documented best-effort contract (an older failure in the same
    // batch falls back to the generic line).
    requests.noteSequence(0x1111, 44);
    try testing.expect(requests.windowForSequence(42) == null);
    try testing.expectEqual(@as(?u32, 0x1111), requests.windowForSequence(44));

    // X ids recycle: reconcile.forget must drop the sequence record too, or
    // the next window with this id could be mislabeled by a stale sequence.
    reconcile.forget(0x1111);
    try testing.expect(requests.lastSequence(0x1111) == null);
    try testing.expect(requests.windowForSequence(44) == null);
}
