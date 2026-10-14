//! Modifier/mask constant tests (pure, headless).
//!
//! masks.zig is the single place the WM folds the X protocol modifier and
//! event masks (spelled as literals, so the pure shelf stays xcb-free) into
//! the binding mask, the lock-key subset table, and the modifier-keysym band;
//! these tests pin the derived values so an accidental bit change (a keybind
//! that would fire through CapsLock, a dropped lock combo from the grab set)
//! fails loudly instead of changing grab/input behavior silently. The first
//! two tests additionally pin every literal against its XCB name -- the
//! reason the literals are trustworthy at all.

const std = @import("std");
const testing = std.testing;

const masks = @import("masks");
const xcb = @import("xcb").xcb;

test "modifier literals match the XCB protocol names" {
    try testing.expectEqual(@as(u16, xcb.XCB_MOD_MASK_SHIFT), masks.mod_shift);
    try testing.expectEqual(@as(u16, xcb.XCB_MOD_MASK_LOCK), masks.mod_capslock);
    try testing.expectEqual(@as(u16, xcb.XCB_MOD_MASK_CONTROL), masks.mod_control);
    try testing.expectEqual(@as(u16, xcb.XCB_MOD_MASK_1), masks.mod_alt);
    try testing.expectEqual(@as(u16, xcb.XCB_MOD_MASK_2), masks.mod_numlock);
    try testing.expectEqual(@as(u16, xcb.XCB_MOD_MASK_3), masks.mod_scrolllock);
    try testing.expectEqual(@as(u16, xcb.XCB_MOD_MASK_4), masks.mod_super);
}

test "event-mask literals match the XCB protocol names" {
    try testing.expectEqual(
        @as(u32, xcb.XCB_EVENT_MASK_SUBSTRUCTURE_REDIRECT |
            xcb.XCB_EVENT_MASK_SUBSTRUCTURE_NOTIFY |
            xcb.XCB_EVENT_MASK_KEY_PRESS |
            xcb.XCB_EVENT_MASK_KEY_RELEASE |
            xcb.XCB_EVENT_MASK_BUTTON_PRESS |
            xcb.XCB_EVENT_MASK_BUTTON_RELEASE |
            xcb.XCB_EVENT_MASK_POINTER_MOTION |
            xcb.XCB_EVENT_MASK_ENTER_WINDOW |
            xcb.XCB_EVENT_MASK_LEAVE_WINDOW |
            xcb.XCB_EVENT_MASK_STRUCTURE_NOTIFY |
            xcb.XCB_EVENT_MASK_PROPERTY_CHANGE),
        masks.EventMasks.root_window,
    );
    try testing.expectEqual(
        @as(u32, xcb.XCB_EVENT_MASK_ENTER_WINDOW |
            xcb.XCB_EVENT_MASK_FOCUS_CHANGE |
            xcb.XCB_EVENT_MASK_PROPERTY_CHANGE |
            xcb.XCB_EVENT_MASK_STRUCTURE_NOTIFY),
        masks.EventMasks.managed_window,
    );
}

test "binding mask is exactly the four non-lock modifiers" {
    // normalizeModifiers is the live producer of the binding mask (the u16
    // `mod_mask_binding` const it replaced is gone); it must keep every real
    // modifier key and drop CapsLock/NumLock/ScrollLock, which are wired up
    // separately via lock_modifiers grabs.
    const binding = masks.toMask(masks.normalizeModifiers(0xffff));
    try testing.expect(masks.mod_shift != 0);
    try testing.expect(masks.mod_control != 0);
    try testing.expect(masks.mod_alt != 0);
    try testing.expect(masks.mod_super != 0);
    // The equality already excludes every lock bit: the right side is the four
    // binding modifiers only.
    try testing.expectEqual(
        masks.mod_shift | masks.mod_control | masks.mod_alt | masks.mod_super,
        binding,
    );
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
