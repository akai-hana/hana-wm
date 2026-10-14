//! `parseKeybindings` unit tests: bind-string grammar (modifier aliases,
//! keysym names, error skips), the Mod/kill placeholders, `{...}` glob
//! expansion for non-workspace actions, `+`-linked parallel batches inside
//! sequences, mouse bindings, and value-shape skips. The document lives in a
//! per-test arena; the Config and every action payload use testing.allocator
//! so leaks fail the test. (config_test covers the {kill} hoist and the
//! workspace globs through the full load pipeline -- not repeated here.)

const std = @import("std");
const testing = std.testing;

const binds = @import("binds");
const keysyms = @import("keysyms");
const masks = @import("masks");
const parser = @import("parser");
const types = @import("types");

fn load(a: std.mem.Allocator, cfg: *types.Config, src: []const u8) !void {
    var doc = try parser.parse(a, src, "<binds-test>");
    try binds.parseKeybindings(testing.allocator, &doc, cfg);
}

fn ks(name: []const u8) u32 {
    return keysyms.keysymFromName(name);
}

test "plain bind: modifier mask, keysym, exec fallback payload" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var cfg: types.Config = .{};
    defer cfg.deinit(testing.allocator);
    try load(arena.allocator(), &cfg,
        \\[binds]
        \\Super+Return = "spawn terminal"
    );

    try testing.expectEqual(@as(usize, 1), cfg.keybindings.items.len);
    try testing.expectEqual(@as(usize, 0), cfg.mouse_bindings.items.len);
    const kb = &cfg.keybindings.items[0];
    try testing.expectEqual(@as(u16, masks.mod_super), kb.modifiers);
    try testing.expectEqual(ks("Return"), kb.keysym);
    try testing.expect(kb.action == .exec);
    try testing.expectEqualStrings("spawn terminal", kb.action.exec);
}

test "modifier spellings fold onto the same masks (case-insensitive)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var cfg: types.Config = .{};
    defer cfg.deinit(testing.allocator);
    try load(arena.allocator(), &cfg,
        \\[binds]
        \\control+Alt+t = "close_window"
        \\CTRL+y = "close_window"
        \\mod4+z = "close_window"
        \\alt+shift+a = "close_window"
    );

    try testing.expectEqual(@as(usize, 4), cfg.keybindings.items.len);
    const expected = [_]u16{
        masks.mod_control | masks.mod_alt,
        masks.mod_control,
        masks.mod_super,
        masks.mod_alt | masks.mod_shift,
    };
    for (cfg.keybindings.items, 0..) |kb, i| {
        try testing.expectEqual(expected[i], kb.modifiers);
        try testing.expect(kb.action == .close_window);
    }
    try testing.expectEqual(ks("t"), cfg.keybindings.items[0].keysym);
    try testing.expectEqual(ks("y"), cfg.keybindings.items[1].keysym);
    try testing.expectEqual(ks("z"), cfg.keybindings.items[2].keysym);
    try testing.expectEqual(ks("a"), cfg.keybindings.items[3].keysym);
}

test "Mod placeholder substitutes into keys but never becomes a binding itself" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var cfg: types.Config = .{};
    defer cfg.deinit(testing.allocator);
    try load(arena.allocator(), &cfg,
        \\[binds]
        \\Mod = "Mod4"
        \\Mod+w = "close_window"
        \\Mod+Return = "spawn foot"
    );

    // The Mod= and kill-style helper lines are consumed, not bound: 2 binds.
    try testing.expectEqual(@as(usize, 2), cfg.keybindings.items.len);
    for (cfg.keybindings.items) |kb| {
        try testing.expectEqual(@as(u16, masks.mod_super), kb.modifiers);
    }
    try testing.expectEqual(ks("w"), cfg.keybindings.items[0].keysym);
    try testing.expectEqual(ks("Return"), cfg.keybindings.items[1].keysym);
}

test "kill placeholder absent: an unresolved {kill} execs verbatim" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var cfg: types.Config = .{};
    defer cfg.deinit(testing.allocator);
    try load(arena.allocator(), &cfg,
        \\[binds]
        \\Super+q = "{kill} foo"
    );

    try testing.expectEqual(@as(usize, 1), cfg.keybindings.items.len);
    const kb = &cfg.keybindings.items[0];
    try testing.expect(kb.action == .exec);
    try testing.expectEqualStrings("{kill} foo", kb.action.exec);
}

test "glob range and comma tokens expand; each bind parses on its own" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var cfg: types.Config = .{};
    defer cfg.deinit(testing.allocator);
    try load(arena.allocator(), &cfg,
        \\[binds]
        \\Mod = "Mod4"
        \\Mod+{1-3} = "close_window"
        \\Mod+{a,b} = "toggle_bar_visibility"
    );

    // 3 range entries + 2 comma entries; non-workspace actions replicate
    // unchanged (no index suffix), so all five carry the same action tag.
    try testing.expectEqual(@as(usize, 5), cfg.keybindings.items.len);
    const names = [_][]const u8{ "1", "2", "3", "a", "b" };
    for (cfg.keybindings.items, 0..) |kb, i| {
        try testing.expectEqual(@as(u16, masks.mod_super), kb.modifiers);
        try testing.expectEqual(ks(names[i]), kb.keysym);
        const tag: std.meta.Tag(@TypeOf(kb.action)) = if (i < 3) .close_window else .toggle_bar_visibility;
        try testing.expectEqual(tag, std.meta.activeTag(kb.action));
    }
}

test "descending glob range falls back to a literal key that fails to parse" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var cfg: types.Config = .{};
    defer cfg.deinit(testing.allocator);
    // Range {3-1} is warned and skipped, so the glob degenerates to the
    // literal key "Mod4+{3-1}" whose final token is no keysym -> bind dropped
    // (and its action freed -- leak-checked by the testing allocator).
    try load(arena.allocator(), &cfg,
        \\[binds]
        \\Mod = "Mod4"
        \\Mod+{3-1} = "close_window"
    );

    try testing.expectEqual(@as(usize, 0), cfg.keybindings.items.len);
}

test "mouse bindings: buttons, aliases, and modifier masks" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var cfg: types.Config = .{};
    defer cfg.deinit(testing.allocator);
    try load(arena.allocator(), &cfg,
        \\[binds]
        \\Super+button1 = "close_window"
        \\Super+scroll_up = "toggle_bar_visibility"
        \\rightclick = "reload_config"
    );

    try testing.expectEqual(@as(usize, 0), cfg.keybindings.items.len);
    try testing.expectEqual(@as(usize, 3), cfg.mouse_bindings.items.len);
    try testing.expectEqual(@as(u16, masks.mod_super), cfg.mouse_bindings.items[0].modifiers);
    try testing.expectEqual(@as(u8, 1), cfg.mouse_bindings.items[0].button);
    try testing.expect(cfg.mouse_bindings.items[0].action == .close_window);
    try testing.expectEqual(@as(u8, 4), cfg.mouse_bindings.items[1].button);
    try testing.expectEqual(@as(u16, 0), cfg.mouse_bindings.items[2].modifiers);
    try testing.expectEqual(@as(u8, 3), cfg.mouse_bindings.items[2].button);
}

test "mouse and keysym in one bind: ambiguous, dropped without leaking" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var cfg: types.Config = .{};
    defer cfg.deinit(testing.allocator);
    try load(arena.allocator(), &cfg,
        \\[binds]
        \\Super+button2+x = "close_window"
        \\Super+notakeysym = "reload_config"
    );

    try testing.expectEqual(@as(usize, 0), cfg.keybindings.items.len);
    try testing.expectEqual(@as(usize, 0), cfg.mouse_bindings.items.len);
}

test "parallel batch: whitespace-bounded + splits, literal plus does not" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var cfg: types.Config = .{};
    defer cfg.deinit(testing.allocator);
    try load(arena.allocator(), &cfg,
        \\[binds]
        \\Super+p = "reload_config + dump_state"
        \\Super+shift+p = "xdotool key ctrl+plus"
    );

    try testing.expectEqual(@as(usize, 2), cfg.keybindings.items.len);
    const par = cfg.keybindings.items[0].action;
    try testing.expect(par == .parallel);
    try testing.expectEqual(@as(usize, 2), par.parallel.len);
    try testing.expect(par.parallel[0] == .reload_config);
    try testing.expect(par.parallel[1] == .dump_state);
    // `ctrl+plus` has no whitespace at the '+', so the exec stays one command.
    const single = cfg.keybindings.items[1].action;
    try testing.expect(single == .exec);
    try testing.expectEqualStrings("xdotool key ctrl+plus", single.exec);
}

test "array values: sequence, parallel-inside-sequence, unwrap, skips" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var cfg: types.Config = .{};
    defer cfg.deinit(testing.allocator);
    try load(arena.allocator(), &cfg,
        \\[binds]
        \\Mod = "Mod4"
        \\Mod+1 = ["toggle_bar_visibility", "reload_config"]
        \\Mod+2 = ["close_window"]
        \\Mod+3 = []
        \\Mod+4 = ["reload_config", "dump_state + close_window"]
        \\Mod+5 = 42
    );

    // 42 (non-string), [] (empty), and the other skips produce no binds:
    // only the sequence, the unwrap, and the mixed list land.
    try testing.expectEqual(@as(usize, 3), cfg.keybindings.items.len);

    const seq = cfg.keybindings.items[0].action;
    try testing.expect(seq == .sequence);
    try testing.expectEqual(@as(usize, 2), seq.sequence.len);
    try testing.expect(seq.sequence[0] == .toggle_bar_visibility);
    try testing.expect(seq.sequence[1] == .reload_config);

    // One-element arrays unwrap to the sole action instead of a sequence.
    try testing.expect(cfg.keybindings.items[1].action == .close_window);

    // `[a, b + c]`: a runs alone, then b and c as one parallel step.
    const mixed = cfg.keybindings.items[2].action;
    try testing.expect(mixed == .sequence);
    try testing.expectEqual(@as(usize, 2), mixed.sequence.len);
    const step = mixed.sequence[1];
    try testing.expect(step == .parallel);
    try testing.expectEqual(@as(usize, 2), step.parallel.len);
    try testing.expect(step.parallel[0] == .dump_state);
    try testing.expect(step.parallel[1] == .close_window);
}

test "the alternate [Keybindings] section name binds identically" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var cfg: types.Config = .{};
    defer cfg.deinit(testing.allocator);
    try load(arena.allocator(), &cfg,
        \\[Keybindings]
        \\Super+F1 = "close_window"
    );

    try testing.expectEqual(@as(usize, 1), cfg.keybindings.items.len);
    const kb = &cfg.keybindings.items[0];
    try testing.expectEqual(ks("F1"), kb.keysym);
    try testing.expect(kb.action == .close_window);
}

test "a sectionless document binds nothing" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var cfg: types.Config = .{};
    defer cfg.deinit(testing.allocator);
    try load(arena.allocator(), &cfg,
        \\[bar]
        \\height = 30
    );

    try testing.expectEqual(@as(usize, 0), cfg.keybindings.items.len);
    try testing.expectEqual(@as(usize, 0), cfg.mouse_bindings.items.len);
}
