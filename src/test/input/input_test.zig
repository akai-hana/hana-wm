//! Pure input-path tests (headless, no X connection).
//!
//! The key dispatch path mixes two concerns: folding a raw X event's modifier
//! state into the binding mask, and resolving (modifiers, keysym) to an
//! Action. Both are pure functions/structures that the X-facing halves
//! (`handleKeyPress`, `XkbState`) merely feed. These tests pin the folding and
//! the resolver map so a mask bit or map-key change fails here instead of
//! silently altering which keybindings fire.

const std = @import("std");
const testing = std.testing;

const types = @import("types");
const keybind = @import("keybind");
const utils = @import("utils");
const masks = @import("masks");

fn actionTag(a: *const types.Action) std.meta.Tag(types.Action) {
    return std.meta.activeTag(a.*);
}

test "normalizeModifiers keeps real modifiers, strips lock and button bits" {
    // Every bit outside the binding mask (lock keys, pointer buttons, odd
    // high bits X may set) must be masked away so matching is stable.
    try testing.expectEqual(masks.mod_shift, utils.normalizeModifiers(masks.mod_shift | masks.mod_capslock));
    try testing.expectEqual(
        masks.mod_control | masks.mod_super,
        utils.normalizeModifiers(masks.mod_control | masks.mod_super | masks.mod_numlock | masks.mod_scrolllock | 0x0100),
    );
    // All-ones folds to exactly the binding mask, never wider.
    try testing.expectEqual(masks.mod_mask_binding, utils.normalizeModifiers(0xffff));
    try testing.expectEqual(@as(u16, 0), utils.normalizeModifiers(masks.mod_capslock | masks.mod_numlock));
}

test "KeybindResolver resolves (mods, keysym) and rejects non-matches" {
    var resolver = keybind.KeybindResolver{};
    defer resolver.deinit(testing.allocator);

    var binds = [_]types.Keybind{
        .{ .modifiers = masks.mod_super, .keysym = 0x0071, .action = .{ .close_window = {} } },
        .{ .modifiers = masks.mod_super, .keysym = 0x0072, .action = .{ .dump_state = {} } },
        .{ .modifiers = masks.mod_super | masks.mod_shift, .keysym = 0x0071, .action = .{ .toggle_fullscreen = {} } },
    };
    resolver.rebuildDispatchMap(&binds, testing.allocator);

    try testing.expectEqual(types.Action.close_window, actionTag(resolver.lookup(masks.mod_super, 0x0071).?));
    try testing.expectEqual(types.Action.dump_state, actionTag(resolver.lookup(masks.mod_super, 0x0072).?));
    try testing.expectEqual(types.Action.toggle_fullscreen, actionTag(resolver.lookup(masks.mod_super | masks.mod_shift, 0x0071).?));

    // Modifiers and keysym are both part of the key: changing either misses.
    try testing.expect(resolver.lookup(masks.mod_super | masks.mod_control, 0x0071) == null);
    try testing.expect(resolver.lookup(0, 0x0071) == null);
    try testing.expect(resolver.lookup(masks.mod_super, 0x0099) == null);
}

test "KeybindResolver: a later binding on the same key wins" {
    var resolver = keybind.KeybindResolver{};
    defer resolver.deinit(testing.allocator);

    var binds = [_]types.Keybind{
        .{ .modifiers = masks.mod_super, .keysym = 0x0071, .action = .{ .close_window = {} } },
        .{ .modifiers = masks.mod_super, .keysym = 0x0071, .action = .{ .dump_state = {} } },
    };
    resolver.rebuildDispatchMap(&binds, testing.allocator);

    try testing.expectEqual(types.Action.dump_state, actionTag(resolver.lookup(masks.mod_super, 0x0071).?));
}

test "KeybindResolver: lookup returns a pointer into the live binding slice" {
    var resolver = keybind.KeybindResolver{};
    defer resolver.deinit(testing.allocator);

    var binds = [_]types.Keybind{
        .{ .modifiers = masks.mod_super, .keysym = 0x0071, .action = .{ .close_window = {} } },
    };
    resolver.rebuildDispatchMap(&binds, testing.allocator);

    const found = resolver.lookup(masks.mod_super, 0x0071).?;
    try testing.expect(found == &binds[0].action);

    // Rebuilding with a new slice re-points the map at the new actions.
    var replacement = [_]types.Keybind{
        .{ .modifiers = masks.mod_super, .keysym = 0x0071, .action = .{ .dump_state = {} } },
    };
    resolver.rebuildDispatchMap(&replacement, testing.allocator);
    try testing.expect(resolver.lookup(masks.mod_super, 0x0071).? == &replacement[0].action);
}
