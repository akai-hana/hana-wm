//! Headless tests for identity.zig's pure WM_CLASS split,
//! lifted out of window.zig so the per-component trimming
//! rule is unit-testable without a property reply.

const std = @import("std");
const testing = std.testing;
const identity = @import("identity");

test "typical two-string WM_CLASS" {
    const wc = identity.parseWmClass("alacritty\x00Alacritty\x00").?;
    try testing.expectEqualStrings("alacritty", wc.instance);
    try testing.expectEqualStrings("Alacritty", wc.class);
}

test "empty class still yields the instance" {
    // "instance\x00\x00": the class is empty, but the instance
    // lookup must still run -- whole-buffer trimming would
    // turn this into "instance" and skip it.
    const wc = identity.parseWmClass("foo\x00\x00").?;
    try testing.expectEqualStrings("foo", wc.instance);
    try testing.expectEqualStrings("", wc.class);
}

test "class without trailing null" {
    const wc = identity.parseWmClass("inst\x00cls").?;
    try testing.expectEqualStrings("inst", wc.instance);
    try testing.expectEqualStrings("cls", wc.class);
}

test "instance without trailing null" {
    const wc = identity.parseWmClass("inst\x00").?;
    try testing.expectEqualStrings("inst", wc.instance);
    try testing.expectEqualStrings("", wc.class);
}

test "separator at start: empty instance" {
    const wc = identity.parseWmClass("\x00class\x00").?;
    try testing.expectEqualStrings("", wc.instance);
    try testing.expectEqualStrings("class", wc.class);
}

test "no separator -> null" {
    try testing.expect(identity.parseWmClass("noseparator") == null);
}

test "empty data -> null" {
    try testing.expect(identity.parseWmClass("") == null);
}
