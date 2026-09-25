//! Config reader tests: readFileAlloc round-trip exactness across size
//! boundaries, the cap enforcement, and the stat-less growth path. The
//! growth path is exercised via /proc (stat.size == 0 but non-empty
//! content) - linux-only by nature, like the WM itself.
//!
//! Scratch files live in a per-process, uniquely-named directory under the
//! system temp area (see scratch.zig); each test uses a unique name and
//! cleans up after itself.

const std = @import("std");
const testing = std.testing;

// The tests deliberately exercise warn-level diagnostics (bad configs);
// src/core/utils/debug.zig silences all std.log diagnostics in test binaries,
// so this stays quiet on success.
const config = @import("config");
const scratch = @import("scratch");

fn writeAndRead(alloc: std.mem.Allocator, name: []const u8, bytes: []const u8) ![]u8 {
    const path = try scratch.scratchPath(alloc, "hana-cfgtest-", name);
    defer alloc.free(path);
    try scratch.writeScratchFile(path, bytes);
    defer scratch.cleanupScratch(path);
    return config.readFileAlloc(alloc, path);
}

test "readFileAlloc round-trips a >64KiB file exactly" {
    const alloc = testing.allocator;

    // Patterned so any truncation/reorder breaks equality (not just length).
    const big = try alloc.alloc(u8, 70_000);
    defer alloc.free(big);
    for (big, 0..) |*b, i| b.* = @truncate(i * 7 + (i % 251));

    const got = try writeAndRead(alloc, "big", big);
    defer alloc.free(got);
    try testing.expectEqualSlices(u8, big, got);
}

test "readFileAlloc accepts exactly max_file_bytes" {
    const alloc = testing.allocator;

    const exact = try alloc.alloc(u8, config.max_file_bytes);
    defer alloc.free(exact);
    @memset(exact, 'x');

    const got = try writeAndRead(alloc, "exact", exact);
    defer alloc.free(got);
    try testing.expectEqual(exact.len, got.len);
}

test "readFileAlloc rejects max_file_bytes + 1" {
    const alloc = testing.allocator;

    const over = try alloc.alloc(u8, config.max_file_bytes + 1);
    defer alloc.free(over);
    @memset(over, 'y');

    try testing.expectError(error.FileTooLarge, writeAndRead(alloc, "over", over));
}

test "readFileAlloc returns empty slice for empty file" {
    const alloc = testing.allocator;

    const got = try writeAndRead(alloc, "empty", "");
    defer alloc.free(got);
    try testing.expectEqual(@as(usize, 0), got.len);
}

test "readFileAlloc growth path handles stat-less files (/proc)" {
    const alloc = testing.allocator;
    // /proc/self/status reports stat.size == 0 with real content: forces the
    // fallback read-with-growth loop.
    const got = try config.readFileAlloc(alloc, "/proc/self/status");
    defer alloc.free(got);
    try testing.expect(got.len > 0);
    try testing.expect(std.mem.startsWith(u8, got, "Name:"));
}

// Config-load pipeline tests (loadToml -> buildConfigFromDoc)

const types = @import("types");

fn loadToml(alloc: std.mem.Allocator, name: []const u8, content: []const u8) !types.Config {
    const path = try scratch.scratchPath(alloc, "hana-cfgtest-", name);
    defer alloc.free(path);
    try scratch.writeScratchFile(path, content);
    defer scratch.cleanupScratch(path);
    return try config.loadConfig(alloc, path);
}

test "plain {kill} bind substitutes before parseAction" {
    var cfg = try loadToml(testing.allocator, "s1a",
        \\[binds]
        \\Mod = "Mod4"
        \\kill = "pkill -9"
        \\Mod+D = "{kill} ghostty"
    );
    defer cfg.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 1), cfg.keybindings.items.len);
    const kb = &cfg.keybindings.items[0];
    try testing.expect(kb.action == .exec);
    try testing.expectEqualStrings("pkill -9 ghostty", kb.action.exec);
}

test "workspace/_N actions still resolve after the substitution hoist" {
    var cfg = try loadToml(testing.allocator, "s1b",
        \\[binds]
        \\Mod = "Mod4"
        \\kill = "pkill -9"
        \\mod+ctrl+{1-4} = "workspace"
        \\mod+alt+{1-4} = "move_to_workspace"
        \\mod+shift+{1-4} = "toggle_tag"
        \\mod+{1-4} = "{kill} term"
        \\Mod+X = "workspace_1"
    );
    defer cfg.deinit(testing.allocator);

    // 12 glob workspace binds + 4 glob exec binds + 1 direct _N bind.
    try testing.expectEqual(@as(usize, 17), cfg.keybindings.items.len);
    // The 4 exec binds carry the substituted payload, not a literal {kill}.
    for (cfg.keybindings.items[12..16]) |kb| {
        try testing.expect(kb.action == .exec);
        try testing.expectEqualStrings("pkill -9 term", kb.action.exec);
    }
    // Direct workspace_1 form resolves to 0-indexed switch_workspace 0.
    try testing.expectEqual(types.Action{ .switch_workspace = 0 }, cfg.keybindings.items[16].action);
}

test "sequence array elements containing {kill} substitute" {
    var cfg = try loadToml(testing.allocator, "s1c",
        \\[binds]
        \\Mod = "Mod4"
        \\kill = "pkill -9"
        \\Mod+A = ["{kill} alpha", "close", "kill"]
    );
    defer cfg.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 1), cfg.keybindings.items.len);
    const seq = cfg.keybindings.items[0].action.sequence;
    try testing.expectEqual(@as(usize, 3), seq.len);
    try testing.expect(seq[0] == .exec);
    try testing.expectEqualStrings("pkill -9 alpha", seq[0].exec);
    try testing.expectEqual(types.Action.close_window, seq[1]);
    try testing.expectEqual(types.Action.close_window, seq[2]);
}

test "reload chain parses as a reload_config + reload_hana sequence" {
    var cfg = try loadToml(testing.allocator, "s1e",
        \\[binds]
        \\Mod = "Mod4"
        \\Mod+Escape = ["reload_config", "reload_hana"]
    );
    defer cfg.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 1), cfg.keybindings.items.len);
    const seq = cfg.keybindings.items[0].action.sequence;
    try testing.expectEqual(@as(usize, 2), seq.len);
    try testing.expectEqual(types.Action.reload_config, seq[0]);
    try testing.expectEqual(types.Action.reload_hana, seq[1]);
}

test "a '+' batch parses as one parallel group" {
    var cfg = try loadToml(testing.allocator, "s1g",
        \\[binds]
        \\Mod = "Mod4"
        \\Mod+Escape = ["reload_config + reload_hana"]
    );
    defer cfg.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 1), cfg.keybindings.items.len);
    const par = cfg.keybindings.items[0].action.parallel;
    try testing.expectEqual(@as(usize, 2), par.len);
    try testing.expectEqual(types.Action.reload_config, par[0]);
    try testing.expectEqual(types.Action.reload_hana, par[1]);
}

test "commas sequence batches, '+' runs a batch in parallel" {
    var cfg = try loadToml(testing.allocator, "s1h",
        \\[binds]
        \\Mod = "Mod4"
        \\Mod+Escape = ["close", "reload_config + reload_hana", "dump_state"]
    );
    defer cfg.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 1), cfg.keybindings.items.len);
    const seq = cfg.keybindings.items[0].action.sequence;
    try testing.expectEqual(@as(usize, 3), seq.len);
    try testing.expectEqual(types.Action.close_window, seq[0]);
    const par = seq[1].parallel;
    try testing.expectEqual(@as(usize, 2), par.len);
    try testing.expectEqual(types.Action.reload_config, par[0]);
    try testing.expectEqual(types.Action.reload_hana, par[1]);
    try testing.expectEqual(types.Action.dump_state, seq[2]);
}

test "unspaced literal '+' in an exec command is preserved" {
    var cfg = try loadToml(testing.allocator, "s1i",
        \\[binds]
        \\Mod = "Mod4"
        \\Mod+X = "xdotool key ctrl+plus"
    );
    defer cfg.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 1), cfg.keybindings.items.len);
    const act = cfg.keybindings.items[0].action;
    try testing.expect(act == .exec);
    try testing.expectEqualStrings("xdotool key ctrl+plus", act.exec);
}

test "array filtering to zero actions yields no binding" {
    var cfg = try loadToml(testing.allocator, "s4",
        \\[binds]
        \\Mod = "Mod4"
        \\Mod+S = [1, 2, 3]
    );
    defer cfg.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 0), cfg.keybindings.items.len);
}

test "a document with skipped (broken) lines fails the load" {
    // "[broken header" is warn-and-skipped; buildConfigFromDoc must refuse to
    // build a partial config from a flagged Document, so reload keeps the
    // live config instead of half-applying a broken one.
    try testing.expectError(error.ConfigParseFailed, loadToml(testing.allocator, "c1",
        \\[broken header
        \\[tiling]
        \\enabled = true
    ));
}

// lowerSlice out-buffer safety

test "lowerSlice lowercases into the caller's buffer and nulls on overflow" {
    var buf8: [8]u8 = undefined;

    const out = types.lowerSlice(8, &buf8, "HeLLo").?;
    try testing.expectEqualStrings("hello", out);
    // The returned slice aliases the caller's buffer (no hidden allocation):
    // the out-buffer signature exists precisely to make this safe.
    try testing.expect(out.ptr == buf8[0..].ptr);

    // Over-length input returns null -- the fixed buffer must never be
    // written past its bound.
    var buf4: [4]u8 = undefined;
    try testing.expect(types.lowerSlice(4, &buf4, "hello") == null);
    // Exact-fit boundary still accepted.
    var buf5: [5]u8 = undefined;
    try testing.expect(types.lowerSlice(5, &buf5, "Hello") != null);

    var buf2: [2]u8 = undefined;
    const empty = types.lowerSlice(2, &buf2, "").?;
    try testing.expectEqual(@as(usize, 0), empty.len);
}

// Config reload change detection deltas

test "detectChanges: identical configs report no subsystem changes" {
    var a = types.Config{};
    var b = types.Config{};
    defer a.deinit(testing.allocator);
    defer b.deinit(testing.allocator);

    const changes = config.detectChanges(&a, &b);
    try testing.expect(!changes.bar);
    try testing.expect(!changes.tiling);
    try testing.expect(!changes.keys);
}

test "detectChanges: a bar color tweak flags only bar" {
    var a = types.Config{};
    var b = types.Config{};
    defer a.deinit(testing.allocator);
    defer b.deinit(testing.allocator);
    b.bar.bg = a.bar.bg + 1;

    const changes = config.detectChanges(&a, &b);
    try testing.expect(changes.bar);
    try testing.expect(!changes.tiling);
    try testing.expect(!changes.keys);
}

test "detectChanges: master count and workspaces count fold into tiling only" {
    var a = types.Config{};
    defer a.deinit(testing.allocator);

    // The tiling subsystem hash covers tiling params, workspaces, and the
    // fullscreen/drag/snap gates as one hot-reload unit.
    var b = types.Config{};
    defer b.deinit(testing.allocator);
    b.tiling.master_count = 2;
    const bc = config.detectChanges(&a, &b);
    try testing.expect(!bc.bar);
    try testing.expect(bc.tiling);
    try testing.expect(!bc.keys);

    var c = types.Config{};
    defer c.deinit(testing.allocator);
    c.workspaces.count = 7;
    const cc = config.detectChanges(&a, &c);
    try testing.expect(cc.tiling);
    try testing.expect(!cc.bar);
    try testing.expect(!cc.keys);
}

test "detectChanges: keys hash covers pair layout, deliberately not Actions" {
    var base = types.Config{};
    defer base.deinit(testing.allocator);
    try base.keybindings.append(testing.allocator, .{
        .modifiers = 5,
        .keysym = 0x1002,
        .action = .close_window,
    });

    // Same mods/keysym, different action: keys must NOT be reported changed,
    // so a hot-reload that only rebinds an action skips the regrab.
    var action_only = types.Config{};
    defer action_only.deinit(testing.allocator);
    try action_only.keybindings.append(testing.allocator, .{
        .modifiers = 5,
        .keysym = 0x1002,
        .action = .toggle_prompt,
    });
    const ac = config.detectChanges(&base, &action_only);
    try testing.expect(!ac.keys);
    try testing.expect(!ac.bar);
    try testing.expect(!ac.tiling);

    // Same modifiers, different keysym: keys DID change.
    var moved = types.Config{};
    defer moved.deinit(testing.allocator);
    try moved.keybindings.append(testing.allocator, .{
        .modifiers = 5,
        .keysym = 0x1003,
        .action = .close_window,
    });
    const mc = config.detectChanges(&base, &moved);
    try testing.expect(mc.keys);
    try testing.expect(!mc.bar);
    try testing.expect(!mc.tiling);

    // A keybinding added: keys changed.
    var added = types.Config{};
    defer added.deinit(testing.allocator);
    try added.keybindings.append(testing.allocator, .{
        .modifiers = 5,
        .keysym = 0x1002,
        .action = .close_window,
    });
    try added.keybindings.append(testing.allocator, .{
        .modifiers = 5,
        .keysym = 0x1004,
        .action = .dump_state,
    });
    const ec = config.detectChanges(&base, &added);
    try testing.expect(ec.keys);
}
