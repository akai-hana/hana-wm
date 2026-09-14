//! XCB modifier/mask constant tests (pure, headless).
//!
//! masks.zig is the single place the WM folds the raw XCB modifier masks into
//! the binding mask, the lock-key subset table, and the modifier-keysym band;
//! these tests pin the derived values so an accidental bit change (a keybind
//! that would fire through CapsLock, a dropped lock combo from the grab set)
//! fails loudly instead of changing grab/input behavior silently.

const std = @import("std");
const testing = std.testing;

const masks = @import("masks");

test "binding mask is exactly the four non-lock modifiers" {
    // mod_mask_binding must strip CapsLock/NumLock/ScrollLock (they are wired
    // up separately via lock_modifiers grabs) while keeping every real
    // modifier key.
    try testing.expect(masks.mod_shift != 0);
    try testing.expect(masks.mod_control != 0);
    try testing.expect(masks.mod_alt != 0);
    try testing.expect(masks.mod_super != 0);
    try testing.expectEqual(
        masks.mod_shift | masks.mod_control | masks.mod_alt | masks.mod_super,
        masks.mod_mask_binding,
    );
    try testing.expect(masks.mod_mask_binding & masks.mod_capslock == 0);
    try testing.expect(masks.mod_mask_binding & masks.mod_numlock == 0);
    try testing.expect(masks.mod_mask_binding & masks.mod_scrolllock == 0);
}

test "lock modifiers: all 8 subsets, folded in 0/singles/pairs/triple order" {
    try testing.expectEqual(@as(usize, 8), masks.lock_modifiers.len);

    const caps = masks.mod_capslock;
    const num = masks.mod_numlock;
    const scr = masks.mod_scrolllock;

    const expected = [8]u16{
        0,
        caps,
        num,
        scr,
        caps | num,
        caps | scr,
        num | scr,
        caps | num | scr,
    };
    try testing.expectEqualSlices(u16, &expected, &masks.lock_modifiers);
}

test "lock modifiers: every entry is a subset of the three locks, all distinct" {
    const all_locks = masks.mod_capslock | masks.mod_numlock | masks.mod_scrolllock;
    for (masks.lock_modifiers) |lm| {
        // No bit outside the three lock masks (no stray shift/ctrl/etc.).
        try testing.expectEqual(@as(u16, 0), lm & ~all_locks);
    }

    // All 8 combinations present, none duplicated (pairwise check is fine for
    // an 8-element comptime table).
    var i: usize = 0;
    while (i < masks.lock_modifiers.len) : (i += 1) {
        var j = i + 1;
        while (j < masks.lock_modifiers.len) : (j += 1) {
            try testing.expect(masks.lock_modifiers[i] != masks.lock_modifiers[j]);
        }
    }
}

test "modifier keysym band is a 16-wide window at the top of the special range" {
    // X11 reserves XK_Shift_L..XK_Hyper_R (0xFFE1..0xFFEE) for modifier keys;
    // the check widens that band one key on each side. The band must cover
    // every modifier key without bleeding into editing/navigation keysyms.
    try testing.expect(masks.modifier_keysym_lo <= masks.modifier_keysym_hi);
    try testing.expectEqual(@as(u32, 16), masks.modifier_keysym_hi - masks.modifier_keysym_lo + 1);
    try testing.expectEqual(@as(u32, 0xFFE0), masks.modifier_keysym_lo);
    try testing.expectEqual(@as(u32, 0xFFEF), masks.modifier_keysym_hi);
}
