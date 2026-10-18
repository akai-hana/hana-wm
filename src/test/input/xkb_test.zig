//! Headless tests for `core/input/xkb`'s pure surface (P1-28): the
//! keycode<->keysym lookups over a table built here rather than from a live
//! server, and the rebuild guards that must hold before any X traffic
//! exists. The live-server half (initXkb's retry ladder, the extension
//! negotiation) needs a display and stays with the e2e boot scenarios.

const std = @import("std");
const testing = std.testing;
const xkb = @import("xkb");
const keymap = @import("keymap");

const NoSymbol = keymap.XKB_KEY_NoSymbol;

const Pair = struct { kc: u8, sym: u32 };

/// An XkbState over a synthetic table, with a real libxkbcommon context
/// owning the lifetime the production init path would have owned (headless:
/// xkbcommon contexts need no X server). The table/reverse pair is built the
/// same way `XkbState.init` builds it, so the lookups below exercise the
/// production wiring rather than a re-implementation.
fn stateOf(pairs: []const Pair) !xkb.XkbState {
    var table: [keymap.x11_max_keycode]u32 = [_]u32{NoSymbol} ** keymap.x11_max_keycode;
    for (pairs) |p| table[p.kc] = p.sym;
    const ctx = keymap.xkb.xkb_context_new(keymap.xkb.XKB_CONTEXT_NO_FLAGS) orelse
        return error.XkbContextFailed;
    return .{
        .context = ctx,
        .keysym_by_keycode = table,
        .reverse = keymap.buildReverseIndex(table),
    };
}

test "xkb: keycodeToKeysym / keysymToKeycode round-trip a synthetic table" {
    var st = try stateOf(&.{
        .{ .kc = 24, .sym = 0x0071 }, // q
        .{ .kc = 25, .sym = 0x0077 }, // w
        .{ .kc = 38, .sym = 0x0061 }, // a
    });
    defer st.deinit();

    // The flat table is indexed by RAW keycode; unmapped keycodes read
    // NoSymbol, never a neighbour's symbol.
    try testing.expectEqual(@as(u32, 0x0071), st.keycodeToKeysym(24));
    try testing.expectEqual(@as(u32, 0x0061), st.keycodeToKeysym(38));
    try testing.expectEqual(@as(u32, NoSymbol), st.keycodeToKeysym(0));
    try testing.expectEqual(@as(u32, NoSymbol), st.keycodeToKeysym(100));

    // The reverse lookup is the one config parsing and the live grab path
    // both resolve through; an absent keysym is null, not a near miss.
    try testing.expectEqual(@as(u8, 24), st.keysymToKeycode(0x0071).?);
    try testing.expectEqual(@as(u8, 38), st.keysymToKeycode(0x0061).?);
    try testing.expectEqual(@as(?u8, null), st.keysymToKeycode(0x0078));
    try testing.expectEqual(@as(?u8, null), st.keysymToKeycode(NoSymbol));
}

test "xkb: rebuildKeymap never rebuilds for modifier-map/pointer remaps" {
    // The MappingNotify half-contract: only MappingKeyboard events rebuild.
    // `false` must bail before any state or connection touch -- xmodmap
    // routinely emits the other two kinds, and rebuilding for them would
    // storm the grab path over a change that cannot have affected a binding.
    try testing.expect(!xkb.rebuildKeymap(false));
}

test "xkb: rebuildKeymap(true) fails closed before initXkb" {
    // Fresh test binary: the module-owned state is null. The mapping-change
    // path must return false rather than unwrap it, so a MappingNotify
    // arriving in the boot window is a no-op instead of a crash.
    try testing.expect(!xkb.rebuildKeymap(true));
}
