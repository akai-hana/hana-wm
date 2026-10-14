//! Headless tests for the pure keymap->table transform (`input/keymap`).
//!
//! The forward table build and the readiness heuristic need a real `xkb_keymap`
//! and stay untested here, but the REVERSE INDEX is a pure function of a
//! 256-entry table of literals, and it is where the two rules that decide
//! which physical key a binding actually grabs live. Both were unreachable
//! from a test before the transform moved out of xkb.zig, so
//! they are checked here for the first time.

const std = @import("std");
const keymap = @import("keymap");

const NoSymbol = keymap.XKB_KEY_NoSymbol;

const Pair = struct { kc: u8, sym: u32 };

/// A forward table with the given (keycode, keysym) pairs, NoSymbol elsewhere.
fn tableOf(pairs: []const Pair) [keymap.x11_max_keycode]u32 {
    var t: [keymap.x11_max_keycode]u32 = [_]u32{NoSymbol} ** keymap.x11_max_keycode;
    for (pairs) |p| t[p.kc] = p.sym;
    return t;
}

/// The production lookup. This used to be a hand-copied duplicate of the
/// bisection in xkb.keysymToKeycode, so the tests below that pin the
/// ordering rules were really pinning the copy rather than the code path.
const lookup = keymap.ReverseIndex.find;

test "keymap: the reverse index is sorted by keysym and holds only real symbols" {
    const t = tableOf(&.{
        .{ .kc = 38, .sym = 0x0061 }, // a
        .{ .kc = 24, .sym = 0x0071 }, // q
        .{ .kc = 65, .sym = 0x0072 }, // z
    });
    const idx = keymap.buildReverseIndex(t);

    try std.testing.expectEqual(@as(usize, 3), idx.len);
    var i: usize = 1;
    while (i < idx.len) : (i += 1) {
        try std.testing.expect(idx.index[i - 1].keysym < idx.index[i].keysym);
    }
    try std.testing.expectEqual(@as(u8, 24), lookup(&idx, 0x0071).?);
    try std.testing.expectEqual(@as(u8, 65), lookup(&idx, 0x0072).?);
    try std.testing.expectEqual(@as(u8, 38), lookup(&idx, 0x0061).?);
    // An absent keysym is null, not a neighbouring entry.
    try std.testing.expectEqual(@as(?u8, null), lookup(&idx, 0x0078));
    try std.testing.expectEqual(@as(?u8, null), lookup(&idx, NoSymbol));
}

test "keymap: two keys carrying one keysym resolve to the LOWEST keycode" {
    // The whole point of the post-sort compaction. A scan-side dedup would
    // compare only against the last APPENDED entry, and keysyms are not
    // ordered by keycode, so kc10=X, kc11=Y, kc12=X would append both X
    // entries and let the bisection land on either -- a binding on X would
    // then grab kc12 and silently stop responding to kc10.
    const t = tableOf(&.{
        .{ .kc = 10, .sym = 0x0058 },
        .{ .kc = 11, .sym = 0x0059 },
        .{ .kc = 12, .sym = 0x0058 },
    });
    const idx = keymap.buildReverseIndex(t);

    // Both X entries collapsed into one, and the survivor is the lower keycode.
    try std.testing.expectEqual(@as(usize, 2), idx.len);
    try std.testing.expectEqual(@as(u8, 10), lookup(&idx, 0x0058).?);
    try std.testing.expectEqual(@as(u8, 11), lookup(&idx, 0x0059).?);
}

test "keymap: a run of duplicates of one keysym collapses to the lowest" {
    // More duplicates than the two-key case, and not adjacent in keycode, so a
    // dedup that only looked at the previous output entry (rather than after
    // the sort) would keep the later ones.
    var pairs: [6]Pair = undefined;
    pairs[0] = .{ .kc = 200, .sym = 0x0041 };
    pairs[1] = .{ .kc = 30, .sym = 0x0042 };
    pairs[2] = .{ .kc = 150, .sym = 0x0041 };
    pairs[3] = .{ .kc = 90, .sym = 0x0041 };
    pairs[4] = .{ .kc = 44, .sym = 0x0043 };
    pairs[5] = .{ .kc = 201, .sym = 0x0041 };
    const idx = keymap.buildReverseIndex(tableOf(&pairs));

    // 0x41 sits on keycodes 90, 150, 200 and 201 -- so the survivor is 90,
    // not the first pair in the array and not the lowest keycode overall.
    try std.testing.expectEqual(@as(usize, 3), idx.len);
    try std.testing.expectEqual(@as(u8, 90), lookup(&idx, 0x0041).?);
    try std.testing.expectEqual(@as(u8, 30), lookup(&idx, 0x0042).?);
    try std.testing.expectEqual(@as(u8, 44), lookup(&idx, 0x0043).?);
}

test "keymap: an empty table yields an empty index, not a garbage one" {
    // len == 0 is the case the bisection must survive: hi == lo on entry, so
    // it must return null without reading the uninitialized tail.
    const t: [keymap.x11_max_keycode]u32 = [_]u32{NoSymbol} ** keymap.x11_max_keycode;
    const idx = keymap.buildReverseIndex(t);
    try std.testing.expectEqual(@as(usize, 0), idx.len);
    try std.testing.expectEqual(@as(?u8, null), lookup(&idx, 0x0061));
}

test "keymap: keycodes below the X11 floor are never indexed" {
    // 0..7 are reserved. A table with a symbol at keycode 3 must not surface
    // it: those keycodes are not deliverable, so a binding resolved to one
    // could never fire.
    var t: [keymap.x11_max_keycode]u32 = [_]u32{NoSymbol} ** keymap.x11_max_keycode;
    t[3] = 0x0061;
    t[8] = 0x0062;
    const idx = keymap.buildReverseIndex(t);

    try std.testing.expectEqual(@as(usize, 1), idx.len);
    try std.testing.expectEqual(@as(u8, 8), lookup(&idx, 0x0062).?);
    try std.testing.expectEqual(@as(?u8, null), lookup(&idx, 0x0061));
}

test "keymap: reverse_capacity matches the keycode range the index covers" {
    // The index is stack-allocated at exactly this size with no allocator, so
    // the constant has to be exactly the number of keycodes that can carry a
    // symbol. If it were smaller, buildReverseIndex would overflow; if larger,
    // every XkbState would carry dead bytes.
    try std.testing.expectEqual(
        @as(usize, keymap.x11_max_keycode - keymap.x11_min_keycode),
        keymap.reverse_capacity,
    );
    try std.testing.expectEqual(@as(usize, 248), keymap.reverse_capacity);
}

// ---------------------------------------------------------------------------
// Keysym-name parsing (merged from keysyms_test.zig). `keysymFromName` is a
// pure libxkbcommon table lookup, so it runs without an X connection. Config
// resolves every keybinding name through this path, so the stable
// name->keysym mapping (and the NoSymbol sentinel for unknown names) is
// load-bearing for the config tests too.
// ---------------------------------------------------------------------------

test "keymap: well-known keysym names resolve to their stable ids" {
    try std.testing.expectEqual(@as(u32, 0x61), keymap.keysymFromName("a"));
    try std.testing.expectEqual(@as(u32, 0xff52), keymap.keysymFromName("Up"));
    try std.testing.expectEqual(@as(u32, 0xff53), keymap.keysymFromName("Right"));
    try std.testing.expectEqual(@as(u32, 0xffe1), keymap.keysymFromName("Shift_L"));
    try std.testing.expectEqual(@as(u32, 0xffeb), keymap.keysymFromName("Super_L"));
}

test "keymap: keysym name lookup is case-insensitive" {
    // The latin keysym names are key names ("a"), so the uppercase spelling
    // resolves to the same keysym.
    try std.testing.expectEqual(
        keymap.keysymFromName("Super_L"),
        keymap.keysymFromName("super_l"),
    );
    try std.testing.expectEqual(keymap.keysymFromName("UP"), keymap.keysymFromName("Up"));
    try std.testing.expectEqual(keymap.keysymFromName("A"), keymap.keysymFromName("a"));
}

test "keymap: unknown keysym names resolve to NoSymbol" {
    try std.testing.expectEqual(
        NoSymbol,
        keymap.keysymFromName("definitely-not-a-real-key-name"),
    );
    try std.testing.expectEqual(NoSymbol, keymap.keysymFromName(""));
}

test "keymap: trailing NUL bytes in a keysym name are ignored" {
    var buf = [_]u8{ 'U', 'p', 0, 0, 0, 0 };
    try std.testing.expectEqual(keymap.keysymFromName("Up"), keymap.keysymFromName(&buf));
}

test "keymap: NoSymbol is zero and distinct from real keysyms" {
    try std.testing.expectEqual(@as(u32, 0), NoSymbol);
    const real = keymap.keysymFromName("x");
    try std.testing.expect(real != NoSymbol);
    try std.testing.expect(keymap.keysymFromName("x") == 0x78);
}
