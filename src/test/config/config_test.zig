//! Config reader tests: readFileAlloc round-trip exactness across size
//! boundaries, the cap enforcement, and the stat-less growth path. The
//! growth path is exercised via /proc (stat.size == 0 but non-empty
//! content) - linux-only by nature, like the WM itself.
//!
//! Scratch files use per-call `std.testing.tmpDir` (see scratch.zig); each
//! test gets its own directory and cleans up after itself.
//!
//! The re-exec snapshot block (Sandbox + the refreshSnapshot/unchanged/
//! renamed/single-file tests) lives in snapshot_test.zig; the tests that
//! stage an isolated config dir here reach the fixture through that module.

const std = @import("std");
const testing = std.testing;

// The tests deliberately exercise warn-level diagnostics (bad configs);
// src/core/pure/log.zig silences all std.log diagnostics in test binaries,
// so this stays quiet on success.
const config = @import("config");
const constants = @import("constants");
const paths = @import("paths");
const scaling = @import("scaling");
const scratch = @import("scratch");
const log = @import("log");
const snapshot_test = @import("snapshot_test");

fn writeAndRead(alloc: std.mem.Allocator, name: []const u8, bytes: []const u8) ![]u8 {
    var f = try scratch.TmpFile.init(name); // (28.5)
    defer f.deinit();
    try f.write(bytes);
    return config.readFileAlloc(alloc, f.path());
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
    var f = try scratch.TmpFile.init(name); // (28.5)
    defer f.deinit();
    try f.write(content);
    return try config.loadConfig(alloc, f.path());
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

// Re-exec config snapshot
//
// refreshSnapshot freezes the winning config so a binary-only re-exec
// (reload_hana) boots an identical config without re-reading the live tree.
// These tests pin WHICH files it freezes: only the ones the load actually
// consumed, never the rest of the (user-owned, unbounded) config directory.
//
// The environment is redirected per test because both the config search order
// (XDG_CONFIG_HOME) and the snapshot location (XDG_RUNTIME_DIR) are read from
// it. Zig's test runner runs the tests in one binary sequentially, so the cwd
// change the single-file case needs cannot race another test.

// The theme-quartet place: the window-chrome quartet's canonical
// home is [tiling] itself, and a theme included from a functional
// config.toml merges INTO that same [tiling] section (same-name
// sections merge, later files win on scalars). This shape is
// cross-file, which the single-file schema tests cannot pin.
test "theme quartet: a [tiling] theme merges over a functional [tiling] config" {
    const alloc = testing.allocator;
    var box = try snapshot_test.Sandbox.init(alloc, "theme-quartet");
    defer box.deinit(alloc);
    const env = try box.redirectEnv(alloc);
    defer alloc.free(env[0]);
    defer alloc.free(env[1]);

    try box.write("hana/config.toml",
        \\include = ["themes/akai.toml"]
        \\[tiling]
        \\enabled = true
        \\layouts = ["master-stack"]
        \\[tiling.layouts.master-stack]
        \\count = 1
        \\side = "left"
        \\width = 50%
        \\variants = "lifo"
    );
    try box.write("hana/themes/akai.toml",
        \\[tiling]
        \\gap_width = 2%
        \\border_width = 1%
        \\border_focused = "#ac3232"
        \\border_unfocused = "#52263e"
    );

    defer config.deinitGoodSource(alloc);
    var source: config.DefaultSource = .fallback;
    var cfg = try config.loadConfigDefault(alloc, &source, false);
    defer cfg.deinit(alloc);
    try testing.expectEqual(config.DefaultSource.user, source);

    // The functional knobs survive the merge...
    try testing.expect(cfg.tiling.enabled);
    try testing.expectEqual(@as(u8, 1), cfg.tiling.master_count);
    try testing.expectEqualStrings("lifo", cfg.tiling.variants.get("master").?);
    // ...and the theme's quartet lands on the tiling fields.
    try testing.expectEqual(types.ScalableValue.percentage(2.0), cfg.tiling.gap_width);
    try testing.expectEqual(types.ScalableValue.percentage(1.0), cfg.tiling.border_width);
    try testing.expectEqual(@as(u32, 0xAC3232), cfg.tiling.border_focused);
    try testing.expectEqual(@as(u32, 0x52263E), cfg.tiling.border_unfocused);
}
// ---------------------------------------------------------------------------
// 15.1 / 15.6 / 15.12: boot degradation, search policy, load ceilings
// ---------------------------------------------------------------------------

test "15.1: a config that parses but fails validate falls back at BOOT" {
    const alloc = testing.allocator;
    var box = try snapshot_test.Sandbox.init(alloc, "invalid-boot");
    defer box.deinit(alloc);
    const env = try box.redirectEnv(alloc);
    defer alloc.free(env[0]);
    defer alloc.free(env[1]);
    defer config.deinitGoodSource(alloc);

    // Valid TOML, semantically impossible: 500% is far outside the
    // [min_master_width, max_master_width] band. Before 15.1 this was the
    // config that took the WM down at boot while a typo'd key did not.
    // The `%` matters: a bare number parses as an ABSOLUTE pixel value, which
    // validation accepts (the screen width is not known here), so `500` would
    // be a perfectly good config and the test would prove nothing.
    try box.write("hana/config.toml", "[tiling]\nmaster_width = 500%\n");

    var source: config.DefaultSource = .fallback;
    var loaded = try config.loadConfigDefault(alloc, &source, true);
    defer loaded.deinit(alloc);
    // The LOAD succeeds (validate runs later, at boot) ...
    try testing.expectEqual(config.DefaultSource.user, source);
    // ... and it is the load that reports the problem, as a load always does.
    try testing.expectError(error.InvalidConfig, config.validate(&loaded));

    // `load` is the boot entry point, and it must come back with a config
    // rather than the error. Exercised for real, not simulated: the fallback
    // is loaded, validated, and returned.
    var booted = try config.load(alloc);
    defer booted.deinit(alloc);
    try config.validate(&booted);
    // The fallback's own master width (55%), not the impossible 500%.
    try testing.expect(booted.tiling.master_width.is_percentage);
    try testing.expect(scaling.asRatio(booted.tiling.master_width) <= constants.max_master_width);
}

test "15.6: an EMPTY XDG_CONFIG_HOME is treated as unset, not as cwd-relative" {
    var buf: [std.fs.max_path_bytes]u8 = undefined;

    // The regression: getenv returned a non-null empty string, so the old code
    // used "" as the config home and `path.join("", "hana")` produced the
    // RELATIVE path "hana" -- the config search silently became relative to the
    // working directory, so the same config tree gave two different WMs
    // depending on where hana was started.
    const from_empty = try paths.configHome(&buf, "", "/home/u");
    try testing.expectEqualStrings("/home/u/.config", from_empty);
    try testing.expect(std.fs.path.isAbsolute(from_empty));

    // Set and non-empty: wins over HOME, as the spec says.
    const from_xdg = try paths.configHome(&buf, "/xdg/here", "/home/u");
    try testing.expectEqualStrings("/xdg/here", from_xdg);

    // Unset, and the HOME-unset case the loader now warns about (it passes "/"
    // so the search stays absolute instead of collapsing to a bare "hana").
    const from_home = try paths.configHome(&buf, null, "/");
    try testing.expectEqualStrings("/.config", from_home);
    try testing.expect(std.fs.path.isAbsolute(from_home));
}

test "15.12: a config tree over the file ceiling is refused, not partially loaded" {
    const alloc = testing.allocator;
    var box = try snapshot_test.Sandbox.init(alloc, "toomany");
    defer box.deinit(alloc);
    const env = try box.redirectEnv(alloc);
    defer alloc.free(env[0]);
    defer alloc.free(env[1]);
    defer config.deinitGoodSource(alloc);

    // One file over the ceiling, each a valid, tiny, distinct config. A load
    // that skipped the surplus would still "succeed" and quietly drop them.
    var name_buf: [32]u8 = undefined;
    for (0..config.max_config_files + 1) |i| {
        const name = try std.fmt.bufPrint(&name_buf, "hana/c{d:0>3}.toml", .{i});
        try box.write(name, "[binds]\n");
    }

    var source: config.DefaultSource = .fallback;
    try testing.expectError(
        error.TooManyConfigFiles,
        config.loadConfigDefault(alloc, &source, false),
    );
}

// The `--check-config` mode exists because a config rejection is a log line
// nobody reads, and it only works if the loader's own warn/err sites are the
// ones being counted. That is asserted here rather than assumed: each case
// below names the SPECIFIC diagnostic it expects, so a bag that counted
// unrelated noise, or counted nothing, fails here instead of passing CI.
test "checkConfig collects the loader's own diagnostics" {
    const alloc = testing.allocator;
    var box = try snapshot_test.Sandbox.init(alloc, "checkcfg");
    defer box.deinit(alloc);
    const env = try box.redirectEnv(alloc);
    defer alloc.free(env[0]);
    defer alloc.free(env[1]);

    // A typo'd key inside a recognized section: the sweep warns, and this is
    // the whole class of mistake the mode exists to catch.
    try box.write("hana/config.toml", "[tiling]\ngap_wdth = 9\n");
    var diag: log.Collector = .{ .allocator = alloc };
    defer diag.deinit();
    try config.checkConfig(alloc, &diag);
    try testing.expect(diag.count() > 0);
    try testing.expect(diag.contains("gap_wdth"));
    // Every captured diagnostic must reconstruct into the same shape the
    // stderr path would have written -- that is what the mode prints.
    var buf: [256]u8 = undefined;
    for (diag.items.items) |d| {
        const line = try log.Collector.line(d, &buf);
        try testing.expect(line.len > "[x] ".len);
        try testing.expect(std.mem.startsWith(u8, line, "["));
    }

    // A config the loader cannot parse at all: still diagnostics, and still no
    // error return -- a broken config is a reportable RESULT, not a crash.
    try box.write("hana/config.toml", "this is not toml [[[\n");
    var bad: log.Collector = .{ .allocator = alloc };
    defer bad.deinit();
    try config.checkConfig(alloc, &bad);
    try testing.expect(bad.count() > 0);

    // The collector is restored on every path, so an installed-then-removed
    // bag cannot keep intercepting later diagnostics.
    try testing.expect(log.collector == null);

    // A load keeps the winning source alive past its own arena (the
    // snapshot re-exec needs it after the parse arena is gone), so the load
    // allocator is still the owner of those bytes until this releases them.
    config.deinitGoodSource(alloc);
}

// Every field's compare strategy is derived from its type, so the failure mode
// is no longer "a field left out of a table" -- there is no table -- but "a
// type mapped to a strategy that always says equal". That failure is silent and
// reload-only: the config parses and applies, the bar just never rebuilds. So
// each strategy gets a field that must be detected as changed here. The colour
// tweak test above covers `.direct`; these cover the rest.
test "detectChanges: meta, string_map and layouts fields all flag bar" {
    const alloc = testing.allocator;

    // .meta via ScalableValue.
    {
        var a = types.Config{};
        defer a.deinit(alloc);
        var b = types.Config{};
        defer b.deinit(alloc);
        b.bar.font_size.value = a.bar.font_size.value + 1;
        try testing.expect(config.detectChanges(&a, &b).bar);
    }
    // .meta via ?ScalableValue -- present on one side only, so it also pins
    // that null vs a value is a difference rather than a silent no-op.
    {
        var a = types.Config{};
        defer a.deinit(alloc);
        var b = types.Config{};
        defer b.deinit(alloc);
        b.bar.height = types.ScalableValue.absolute(20);
        try testing.expect(config.detectChanges(&a, &b).bar);
    }
    // .meta via ArrayList(string) -- same length, different contents, which is
    // the case a pointer-or-capacity comparison would wrongly call equal.
    {
        var a = types.Config{};
        defer a.deinit(alloc);
        var b = types.Config{};
        defer b.deinit(alloc);
        try b.bar.fonts.append(alloc, try alloc.dupe(u8, "iosevka"));
        try testing.expect(config.detectChanges(&a, &b).bar);
    }
    // .meta via ?[]const u8.
    {
        var a = types.Config{};
        defer a.deinit(alloc);
        var b = types.Config{};
        defer b.deinit(alloc);
        b.bar.volume_format = try alloc.dupe(u8, "{volume}");
        try testing.expect(config.detectChanges(&a, &b).bar);
    }
    // .string_map via StringHashMapUnmanaged(Color).
    {
        var a = types.Config{};
        defer a.deinit(alloc);
        var b = types.Config{};
        defer b.deinit(alloc);
        // Keys are owned: BarConfig.deinit frees each one, so a literal here
        // would be an invalid free.
        try b.bar.segment_fg.put(alloc, try alloc.dupe(u8, "workspace"), 0xff00ff00);
        try testing.expect(config.detectChanges(&a, &b).bar);
    }
    // .string_map via StringHashMapUnmanaged(SegmentProps) -- same key, one
    // flag differs.
    {
        var a = types.Config{};
        defer a.deinit(alloc);
        var b = types.Config{};
        defer b.deinit(alloc);
        try b.bar.segment_props.put(alloc, try alloc.dupe(u8, "clock"), .{ .bold = true });
        try testing.expect(config.detectChanges(&a, &b).bar);
    }
    // .layouts via ArrayList(BarLayout), compared element-wise.
    {
        var a = types.Config{};
        defer a.deinit(alloc);
        var b = types.Config{};
        defer b.deinit(alloc);
        try b.bar.layout.append(alloc, .{ .position = .left, .segments = .empty });
        try testing.expect(config.detectChanges(&a, &b).bar);
    }
    // And the inverse: a bar-only change must not drag tiling or keys along,
    // for the strategies that are new to this path.
    {
        var a = types.Config{};
        defer a.deinit(alloc);
        var b = types.Config{};
        defer b.deinit(alloc);
        try b.bar.layout.append(alloc, .{ .position = .right, .segments = .empty });
        const c = config.detectChanges(&a, &b);
        try testing.expect(c.bar);
        try testing.expect(!c.tiling);
        try testing.expect(!c.keys);
    }
}
