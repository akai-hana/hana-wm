//! Headless tests for pure keysym-name parsing (`input/keysyms`).
//!
//! `keysymFromName` is a pure libxkbcommon table lookup, so it runs without
//! an X connection. Config resolves every keybinding name through this path,
//! so the stable name->keysym mapping (and the NoSymbol sentinel for unknown
//! names) is load-bearing for the config tests too.

const std = @import("std");
const keysyms = @import("keysyms");

test "keysyms: well-known names resolve to their stable keysym ids" {
    try std.testing.expectEqual(@as(u32, 0x61), keysyms.keysymFromName("a"));
    try std.testing.expectEqual(@as(u32, 0xff52), keysyms.keysymFromName("Up"));
    try std.testing.expectEqual(@as(u32, 0xff53), keysyms.keysymFromName("Right"));
    try std.testing.expectEqual(@as(u32, 0xffe1), keysyms.keysymFromName("Shift_L"));
    try std.testing.expectEqual(@as(u32, 0xffeb), keysyms.keysymFromName("Super_L"));
}

test "keysyms: lookup is case-insensitive" {
    // The latin keysym names are key names ("a"), so the uppercase spelling
    // resolves to the same keysym.
    try std.testing.expectEqual(
        keysyms.keysymFromName("Super_L"),
        keysyms.keysymFromName("super_l"),
    );
    try std.testing.expectEqual(keysyms.keysymFromName("UP"), keysyms.keysymFromName("Up"));
    try std.testing.expectEqual(keysyms.keysymFromName("A"), keysyms.keysymFromName("a"));
}

test "keysyms: unknown names resolve to NoSymbol" {
    try std.testing.expectEqual(
        keysyms.XKB_KEY_NoSymbol,
        keysyms.keysymFromName("definitely-not-a-real-key-name"),
    );
    try std.testing.expectEqual(keysyms.XKB_KEY_NoSymbol, keysyms.keysymFromName(""));
}

test "keysyms: trailing NUL bytes are ignored" {
    var buf = [_]u8{ 'U', 'p', 0, 0, 0, 0 };
    try std.testing.expectEqual(keysyms.keysymFromName("Up"), keysyms.keysymFromName(&buf));
}

test "keysyms: NoSymbol is zero and distinct from real keysyms" {
    try std.testing.expectEqual(@as(u32, 0), keysyms.XKB_KEY_NoSymbol);
    const real = keysyms.keysymFromName("x");
    try std.testing.expect(real != keysyms.XKB_KEY_NoSymbol);
    try std.testing.expect(keysyms.keysymFromName("x") == 0x78);
}
