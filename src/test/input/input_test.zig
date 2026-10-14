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
const grabs = @import("grabs");
const masks = @import("masks");
const log = @import("log");
const constants = @import("constants");
const input = @import("input");

/// Stand-in config generation for the resolver tests. Any value works: what
/// they pin is that a table built at generation N only answers for N.
const test_gen: u32 = 0;

fn actionTag(a: *const types.Action) std.meta.Tag(types.Action) {
    return std.meta.activeTag(a.*);
}

test "normalizeModifiers keeps real modifiers, strips lock and button bits" {
    // Every bit outside the binding mask (lock keys, pointer buttons, odd
    // high bits X may set) must be masked away so matching is stable. The
    // expectations are written as u16 masks because that is what a config
    // stores and what the mouse-bind path compares against -- not because
    // that is what normalizeModifiers returns.
    try testing.expectEqual(masks.mod_shift, masks.toMask(masks.normalizeModifiers(masks.mod_shift | masks.mod_capslock)));
    try testing.expectEqual(
        masks.mod_control | masks.mod_super,
        masks.toMask(masks.normalizeModifiers(masks.mod_control | masks.mod_super | masks.mod_numlock | masks.mod_scrolllock | 0x0100)),
    );
    // All-ones folds to exactly the binding mask, never wider.
    try testing.expectEqual(
        masks.mod_shift | masks.mod_control | masks.mod_alt | masks.mod_super,
        masks.toMask(masks.normalizeModifiers(0xffff)),
    );
    try testing.expectEqual(@as(u16, 0), masks.toMask(masks.normalizeModifiers(masks.mod_capslock | masks.mod_numlock)));
}

test "KeybindResolver resolves (mods, keysym) and rejects non-matches" {
    var resolver = keybind.KeybindResolver{};
    defer resolver.deinit(testing.allocator);

    var binds = [_]types.Keybind{
        .{ .modifiers = masks.mod_super, .keysym = 0x0071, .action = .{ .close_window = {} } },
        .{ .modifiers = masks.mod_super, .keysym = 0x0072, .action = .{ .dump_state = {} } },
        .{ .modifiers = masks.mod_super | masks.mod_shift, .keysym = 0x0071, .action = .{ .toggle_fullscreen = {} } },
    };
    resolver.rebuildDispatchMap(&binds, testing.allocator, test_gen);

    try testing.expectEqual(types.Action.close_window, actionTag(resolver.lookup(.{ .super = true }, 0x0071, test_gen).?));
    try testing.expectEqual(types.Action.dump_state, actionTag(resolver.lookup(.{ .super = true }, 0x0072, test_gen).?));
    try testing.expectEqual(types.Action.toggle_fullscreen, actionTag(resolver.lookup(.{ .super = true, .shift = true }, 0x0071, test_gen).?));

    // Modifiers and keysym are both part of the key: changing either misses.
    try testing.expect(resolver.lookup(.{ .super = true, .control = true }, 0x0071, test_gen) == null);
    try testing.expect(resolver.lookup(.{}, 0x0071, test_gen) == null);
    try testing.expect(resolver.lookup(.{ .super = true }, 0x0099, test_gen) == null);
}

test "KeybindResolver: a later binding on the same key wins" {
    var resolver = keybind.KeybindResolver{};
    defer resolver.deinit(testing.allocator);

    var binds = [_]types.Keybind{
        .{ .modifiers = masks.mod_super, .keysym = 0x0071, .action = .{ .close_window = {} } },
        .{ .modifiers = masks.mod_super, .keysym = 0x0071, .action = .{ .dump_state = {} } },
    };
    resolver.rebuildDispatchMap(&binds, testing.allocator, test_gen);

    try testing.expectEqual(types.Action.dump_state, actionTag(resolver.lookup(.{ .super = true }, 0x0071, test_gen).?));
}

test "KeybindResolver: lookup returns a pointer into the live binding slice" {
    var resolver = keybind.KeybindResolver{};
    defer resolver.deinit(testing.allocator);

    var binds = [_]types.Keybind{
        .{ .modifiers = masks.mod_super, .keysym = 0x0071, .action = .{ .close_window = {} } },
    };
    resolver.rebuildDispatchMap(&binds, testing.allocator, test_gen);

    const found = resolver.lookup(.{ .super = true }, 0x0071, test_gen).?;
    try testing.expect(found == &binds[0].action);

    // Rebuilding with a new slice re-points the map at the new actions.
    var replacement = [_]types.Keybind{
        .{ .modifiers = masks.mod_super, .keysym = 0x0071, .action = .{ .dump_state = {} } },
    };
    resolver.rebuildDispatchMap(&replacement, testing.allocator, test_gen);
    try testing.expect(resolver.lookup(.{ .super = true }, 0x0071, test_gen).? == &replacement[0].action);
}

// A `[binds]` mouse entry that the root grab cannot deliver is the config
// surface's worst failure mode: it parses, the config loads, the bar draws,
// and the key simply does nothing. The rule is pure and takes the grab as
// data, so every unreachable shape is pinned here without an X server.
test "mouse binds the root grab cannot deliver are identifiable" {
    const grab: grabs.MouseGrabSpec = .{
        .buttons = &[_]u8{ 1, 2, 3, 4, 5 },
        .modifiers = masks.mod_super,
        .lock_bits = masks.lock_bits,
    };
    const never_delivered = [_]struct { mods: u16, button: u8 }{
        // No Super: the click goes to the client, the WM never sees it.
        .{ .mods = 0, .button = 1 },
        // A different modifier: never grabbed, and dispatch compares exactly.
        .{ .mods = masks.mod_super | masks.mod_shift, .button = 1 },
        .{ .mods = masks.mod_control, .button = 1 },
        // A button the grab does not cover.
        .{ .mods = masks.mod_super, .button = 8 },
    };
    for (never_delivered) |u| {
        const mb: types.MouseBind = .{ .modifiers = u.mods, .button = u.button, .action = .{ .close_window = {} } };
        if (grabs.undeliverableMouseBindReason(mb, grab) == null) {
            std.debug.print("mods=0x{x} button={} was reported reachable\n", .{ u.mods, u.button });
            return error.UnreachableBindNotDetected;
        }
    }
    // Everything the grab DOES deliver must stay silent, including the lock
    // combinations: those are grabbed 2^3 ways and masked off before dispatch,
    // so treating them as unreachable would make the check cry wolf.
    const reachable = [_]struct { mods: u16, button: u8 }{
        .{ .mods = masks.mod_super, .button = 1 },
        .{ .mods = masks.mod_super, .button = 5 },
        .{ .mods = masks.mod_super | masks.lock_bits, .button = 3 },
        .{ .mods = masks.mod_super | masks.mod_numlock, .button = 2 },
    };
    for (reachable) |r| {
        const mb: types.MouseBind = .{ .modifiers = r.mods, .button = r.button, .action = .{ .close_window = {} } };
        if (grabs.undeliverableMouseBindReason(mb, grab)) |why| {
            std.debug.print("mods=0x{x} button={} wrongly rejected: {s}\n", .{ r.mods, r.button, why });
            return error.ReachableBindRejected;
        }
    }
}

// The mouse routing rule decides three things at once -- what happens, and
// what happens to the grab -- and the grab half is the one that bites: a path
// that never calls allow_events leaves BOTH the keyboard and the pointer
// frozen, with no error and no window to touch. Ordering is the other half:
// scroll binds must precede the managed-window guard (they do not target a
// window, so they have to work over the desktop and the bar), and focus must
// precede the bind lookup.
test "mouse press classification orders its branches and settles the grab" {
    const L = constants.mouse_button_left;
    const R = constants.mouse_button_right;
    const M = constants.mouse_button_middle;
    const UP = constants.mouse_button_scroll_up;
    const DOWN = constants.mouse_button_scroll_down;

    // (super, button, target_managed, bind_fired) -> expected intent
    const cases = [_]struct {
        f: input.MousePress,
        want: std.meta.Tag(input.MouseIntent),
    }{
        // Scroll binds precede the managed guard: over the desktop (no
        // managed target) an unbound Super+scroll still releases rather than
        // being dropped as unmanaged.
        .{ .f = .{ .super_held = true, .button = UP, .target_managed = false, .bind_fired = false }, .want = .scroll_bind },
        .{ .f = .{ .super_held = true, .button = DOWN, .target_managed = true, .bind_fired = false }, .want = .scroll_bind },
        // A fired scroll bind shares the already-released intent.
        .{ .f = .{ .super_held = true, .button = UP, .target_managed = false, .bind_fired = true }, .want = .bound_action },
        // Without Super, a scroll button is an ordinary click: no scroll bind.
        .{ .f = .{ .super_held = false, .button = UP, .target_managed = true, .bind_fired = false }, .want = .focus_click },
        // Root / unmanaged.
        .{ .f = .{ .super_held = false, .button = L, .target_managed = false, .bind_fired = false }, .want = .unmanaged },
        .{ .f = .{ .super_held = true, .button = L, .target_managed = false, .bind_fired = false }, .want = .unmanaged },
        // Plain click on a managed window focuses, and never consults a bind
        // (which is why `bind_fired` is false however the caller set the others).
        .{ .f = .{ .super_held = false, .button = L, .target_managed = true, .bind_fired = false }, .want = .focus_click },
        .{ .f = .{ .super_held = false, .button = M, .target_managed = true, .bind_fired = false }, .want = .focus_click },
        // Super+drag buttons, bound and unbound.
        .{ .f = .{ .super_held = true, .button = L, .target_managed = true, .bind_fired = false }, .want = .start_drag },
        .{ .f = .{ .super_held = true, .button = R, .target_managed = true, .bind_fired = false }, .want = .start_drag },
        .{ .f = .{ .super_held = true, .button = L, .target_managed = true, .bind_fired = true }, .want = .bound_action },
        // Super+anything else, unbound: the replay that thaws both devices.
        .{ .f = .{ .super_held = true, .button = M, .target_managed = true, .bind_fired = false }, .want = .replay },
    };
    for (cases) |c| {
        const got = input.classifyMousePress(c.f);
        if (std.meta.activeTag(got) != c.want) {
            std.debug.print(
                "super={} button={} managed={} bound={} -> {s}, want {s}\n",
                .{ c.f.super_held, c.f.button, c.f.target_managed, c.f.bind_fired, @tagName(got), @tagName(c.want) },
            );
            return error.MisroutedPress;
        }
    }
}

// The dispatch table holds pointers into the live config's keybindings, and the
// config box is freed at the next reload. The generation check is what turns
// "rebuild before the swap, tear down before shutdown" from a comment into a
// checked invariant: a stale table must fail CLOSED (the key does nothing) and
// say so exactly once, never dereference a freed Action.
test "dispatch map refuses a config generation it was not built against" {
    var resolver: keybind.KeybindResolver = .{};
    defer resolver.deinit(testing.allocator);
    var binds = [_]types.Keybind{
        .{ .modifiers = masks.mod_super, .keysym = 0x0071, .action = .{ .dump_state = {} } },
    };
    resolver.rebuildDispatchMap(&binds, testing.allocator, 7);
    // Same generation: resolves.
    try testing.expect(resolver.lookup(.{ .super = true }, 0x0071, 7) != null);

    // The config was replaced and freed; the old table is now dangling.
    resolver.rebuildDispatchMap(&binds, testing.allocator, 7);
    try testing.expect(resolver.lookup(.{ .super = true }, 0x0071, 8) == null);
    // Reported once, not per keystroke: the latch survives the first miss.
    try testing.expect(resolver.stale_reported);
    try testing.expect(resolver.lookup(.{ .super = true }, 0x0071, 8) == null);
    try testing.expect(resolver.stale_reported);

    // Rebuilding against the new generation restores dispatch and re-arms the
    // latch, so a later regression is reported rather than swallowed.
    resolver.rebuildDispatchMap(&binds, testing.allocator, 8);
    try testing.expect(!resolver.stale_reported);
    try testing.expect(resolver.lookup(.{ .super = true }, 0x0071, 8) != null);
}

// The scaffold property is declared once, on the action. Half of that
// contract is enforced by `dispatch.grafted`'s comptime gate (grafting an
// undeclared tag does not compile). The other half cannot be: a tag declared
// as needing the scaffold, dispatched through a plain arm, is invisible from
// the helper. This pins the declaration against the dispatcher's grafted set
// so the two cannot drift.
test "tiling scaffold table matches the dispatcher's grafted set" {
    // The tags whose arms route through `dispatch.grafted`, spelled out. If a
    // tag is added to `types.needsTilingFocusScaffold` this list is where it
    // gets named, and the assertion below is what makes the naming mandatory.
    const grafted_tags = [_]std.meta.Tag(types.Action){
        .toggle_floating_window,
        .cycle_layout,
        .cycle_variants,
    };

    inline for (grafted_tags) |tag| {
        try testing.expect(types.needsTilingFocusScaffold(tag));
    }

    // And the converse: every tag the declaration claims is scaffolded is
    // actually grafted at the dispatch site. Enumerated from the tag enum by
    // index rather than by name, so `tag` is comptime-known without paying
    // `stringToEnum`'s linear scan once per field.
    const fields = @typeInfo(types.Action).@"union".fields;
    inline for (0..fields.len) |i| {
        const tag: std.meta.Tag(types.Action) = @enumFromInt(i);
        var claimed = false;
        inline for (grafted_tags) |g| {
            if (g == tag) claimed = true;
        }
        if (types.needsTilingFocusScaffold(tag) != claimed) {
            std.debug.print(
                "action '{s}': needsTilingFocusScaffold={} but grafted={}\n",
                .{ fields[i].name, types.needsTilingFocusScaffold(tag), claimed },
            );
            return error.TilingScaffoldDeclarationMismatch;
        }
    }
}

// A mouse binding that can never fire is a config bug the user cannot see.
// The keyboard table reported those; the mouse scan used to take the first
// match in silence, so `Super+Button1` bound twice meant the second entry was
// simply dead with no diagnostic, and the winning entry depended on file order
// in one trigger path but not the other. This pins the unified policy: last
// wins, and each shadowed entry says so through the shared reporter.
test "mouse bind shadowing: last entry wins and every shadowed entry is reported" {
    const B1 = 1;
    const binds = [_]types.MouseBind{
        .{ .modifiers = masks.mod_super, .button = B1, .action = .{ .close_window = {} } },
        .{ .modifiers = masks.mod_super, .button = B1, .action = .{ .dump_state = {} } },
        .{ .modifiers = masks.mod_super, .button = B1, .action = .{ .reload_config = {} } },
        // A different button never participates in the conflict.
        .{ .modifiers = masks.mod_super, .button = 3, .action = .{ .minimize_window = {} } },
    };

    var diag: log.Collector = .{ .allocator = testing.allocator };
    defer diag.deinit();
    const prev = log.collector;
    log.collector = &diag;
    defer log.collector = prev;

    const found = input.findMouseBind(&binds, masks.mod_super, B1).?;
    try testing.expectEqual(types.Action.reload_config, found.action);

    // Two shadowed entries (#2 and #3, 1-based), so two reports -- not one per
    // lookup, and not one total.
    try testing.expectEqual(@as(usize, 2), diag.count());
    try testing.expect(diag.contains("Mouse binding conflict"));
    try testing.expect(diag.contains("button=0x1"));

    // An unmatched trigger is silent: absence of a binding is not a conflict.
    const seen = diag.count();
    try testing.expect(input.findMouseBind(&binds, masks.mod_super, 2) == null);
    try testing.expectEqual(seen, diag.count());
    // And a modifier mismatch misses even though the button exists.
    try testing.expect(input.findMouseBind(&binds, masks.mod_alt, B1) == null);
    try testing.expectEqual(seen, diag.count());
}
