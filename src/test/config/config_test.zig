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

// The tests deliberately exercise warn-level diagnostics (bad configs); the
// vendored test runner (dev/test_runner.zig) captures them into the
// diagnostics bag instead of printing, so this stays quiet on success.
const config = @import("config");
const diagnostics = @import("diagnostics");
const model = @import("model");
const discover = @import("discover");
const scaling = @import("scaling");
const scratch = @import("scratch");
const snapshot_test = @import("snapshot_test");

fn writeAndRead(alloc: std.mem.Allocator, name: []const u8, bytes: []const u8) ![]u8 {
    var f = try scratch.TmpFile.init(name);
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
const composed = @import("composed");

const loadToml = scratch.loadToml;

test "plain {kill} bind substitutes before parseAction" {
    var cfg = try loadToml(testing.allocator, "s1a",
        \\[binds]
        \\Mod = "Mod4"
        \\kill = "pkill -9"
        \\Mod+D = "{kill} ghostty"
    );
    defer cfg.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 1), cfg.core.keybindings.items.len);
    const kb = &cfg.core.keybindings.items[0];
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
    try testing.expectEqual(@as(usize, 17), cfg.core.keybindings.items.len);
    // The 4 exec binds carry the substituted payload, not a literal {kill}.
    for (cfg.core.keybindings.items[12..16]) |kb| {
        try testing.expect(kb.action == .exec);
        try testing.expectEqualStrings("pkill -9 term", kb.action.exec);
    }
    // Direct workspace_1 form resolves to 0-indexed switch_workspace 0.
    try testing.expectEqual(types.Action{ .switch_workspace = 0 }, cfg.core.keybindings.items[16].action);
}

test "sequence array elements containing {kill} substitute" {
    var cfg = try loadToml(testing.allocator, "s1c",
        \\[binds]
        \\Mod = "Mod4"
        \\kill = "pkill -9"
        \\Mod+A = ["{kill} alpha", "close", "kill"]
    );
    defer cfg.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 1), cfg.core.keybindings.items.len);
    const seq = cfg.core.keybindings.items[0].action.sequence;
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

    try testing.expectEqual(@as(usize, 1), cfg.core.keybindings.items.len);
    const seq = cfg.core.keybindings.items[0].action.sequence;
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

    try testing.expectEqual(@as(usize, 1), cfg.core.keybindings.items.len);
    const par = cfg.core.keybindings.items[0].action.parallel;
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

    try testing.expectEqual(@as(usize, 1), cfg.core.keybindings.items.len);
    const seq = cfg.core.keybindings.items[0].action.sequence;
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

    try testing.expectEqual(@as(usize, 1), cfg.core.keybindings.items.len);
    const act = cfg.core.keybindings.items[0].action;
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

    try testing.expectEqual(@as(usize, 0), cfg.core.keybindings.items.len);
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

test "detectChanges: identical configs report no key changes" {
    var a = composed.Config{};
    var b = composed.Config{};
    defer a.deinit(testing.allocator);
    defer b.deinit(testing.allocator);

    const changes = config.detectChanges(&a, &b);
    try testing.expect(!changes.keys);
}

test "detectChanges: keys hash covers pair layout, deliberately not Actions" {
    var base = composed.Config{};
    defer base.deinit(testing.allocator);
    try base.core.keybindings.append(testing.allocator, .{
        .modifiers = 5,
        .keysym = 0x1002,
        .action = .close_window,
    });

    // Same mods/keysym, different action: keys must NOT be reported changed,
    // so a hot-reload that only rebinds an action skips the regrab.
    var action_only = composed.Config{};
    defer action_only.deinit(testing.allocator);
    try action_only.core.keybindings.append(testing.allocator, .{
        .modifiers = 5,
        .keysym = 0x1002,
        .action = .toggle_prompt,
    });
    const ac = config.detectChanges(&base, &action_only);
    try testing.expect(!ac.keys);

    // Same modifiers, different keysym: keys DID change.
    var moved = composed.Config{};
    defer moved.deinit(testing.allocator);
    try moved.core.keybindings.append(testing.allocator, .{
        .modifiers = 5,
        .keysym = 0x1003,
        .action = .close_window,
    });
    const mc = config.detectChanges(&base, &moved);
    try testing.expect(mc.keys);

    // A keybinding added: keys changed.
    var added = composed.Config{};
    defer added.deinit(testing.allocator);
    try added.core.keybindings.append(testing.allocator, .{
        .modifiers = 5,
        .keysym = 0x1002,
        .action = .close_window,
    });
    try added.core.keybindings.append(testing.allocator, .{
        .modifiers = 5,
        .keysym = 0x1004,
        .action = .dump_state,
    });
    const ec = config.detectChanges(&base, &added);
    try testing.expect(ec.keys);
}

test "detectChanges: mouse-bind pair layout changes are keys changes too" {
    var base = composed.Config{};
    defer base.deinit(testing.allocator);
    try base.core.mouse_bindings.append(testing.allocator, .{
        .modifiers = 4,
        .button = 1,
        .action = .close_window,
    });

    // Same mods/button, different action: no regrab.
    var action_only = composed.Config{};
    defer action_only.deinit(testing.allocator);
    try action_only.core.mouse_bindings.append(testing.allocator, .{
        .modifiers = 4,
        .button = 1,
        .action = .toggle_prompt,
    });
    try testing.expect(!config.detectChanges(&base, &action_only).keys);

    // Same button, different modifiers: regrab.
    var remod = composed.Config{};
    defer remod.deinit(testing.allocator);
    try remod.core.mouse_bindings.append(testing.allocator, .{
        .modifiers = 5,
        .button = 1,
        .action = .close_window,
    });
    try testing.expect(config.detectChanges(&base, &remod).keys);

    // Same modifiers, different button: regrab.
    var rebutton = composed.Config{};
    defer rebutton.deinit(testing.allocator);
    try rebutton.core.mouse_bindings.append(testing.allocator, .{
        .modifiers = 4,
        .button = 3,
        .action = .close_window,
    });
    try testing.expect(config.detectChanges(&base, &rebutton).keys);

    // A mouse binding added: regrab.
    var added = composed.Config{};
    defer added.deinit(testing.allocator);
    try added.core.mouse_bindings.append(testing.allocator, .{
        .modifiers = 4,
        .button = 1,
        .action = .close_window,
    });
    try added.core.mouse_bindings.append(testing.allocator, .{
        .modifiers = 4,
        .button = 3,
        .action = .dump_state,
    });
    try testing.expect(config.detectChanges(&base, &added).keys);
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
    try testing.expectEqual(@as(u8, 1), cfg.tiling.master_count);
    try testing.expectEqualStrings("lifo", cfg.tiling.variants.get("master").?);
    // ...and the theme's quartet lands on the tiling fields.
    try testing.expectEqual(types.ScalableValue.percentage(2.0), cfg.tiling.gap_width);
    try testing.expectEqual(types.ScalableValue.percentage(1.0), cfg.tiling.border_width);
    try testing.expectEqual(@as(u32, 0xAC3232), cfg.tiling.border_focused);
    try testing.expectEqual(@as(u32, 0x52263E), cfg.tiling.border_unfocused);
}

// The entry-file rule: a config dir contributes its `config.toml` plus that
// file's `include`s, and nothing else. This pins BOTH halves of it on one
// sibling file -- the drop-in that must stay inert (and say so) until it is
// named, and the same file named in `include`, which then loads as always.
test "a sibling .toml loads only when config.toml includes it" {
    const alloc = testing.allocator;
    var box = try snapshot_test.Sandbox.init(alloc, "sibling");
    defer box.deinit(alloc);
    const env = try box.redirectEnv(alloc);
    defer alloc.free(env[0]);
    defer alloc.free(env[1]);
    defer config.deinitGoodSource(alloc);

    try box.write("hana/sibling.toml", "[workspaces]\ncount = 33\n");

    // Not named by config.toml: the file never reaches the parser, so its
    // knob cannot land -- and the loader REPORTS the inert file rather than
    // dropping it in silence.
    try box.write("hana/config.toml", "[tiling]\nenabled = true\n");
    var inert: diagnostics.Diagnostics = .{ .allocator = alloc };
    defer inert.deinit();
    try config.checkConfig(alloc, &inert);
    try testing.expect(inert.count() > 0);
    try testing.expect(inert.contains("sibling.toml"));

    var source: config.DefaultSource = .fallback;
    var cfg = try config.loadConfigDefault(alloc, &source, false);
    defer cfg.deinit(alloc);
    try testing.expectEqual(config.DefaultSource.user, source);
    try testing.expectEqual(@as(u8, types.default_workspace_count), cfg.workspaces.count);

    // Named in `include`: the same file is read, merged, and stops being
    // reported -- one line in config.toml is the whole switch.
    try box.write("hana/config.toml", "include = [\"sibling.toml\"]\n");
    var clean: diagnostics.Diagnostics = .{ .allocator = alloc };
    defer clean.deinit();
    try config.checkConfig(alloc, &clean);
    try testing.expect(!clean.contains("sibling.toml"));

    var cfg2 = try config.loadConfigDefault(alloc, &source, false);
    defer cfg2.deinit(alloc);
    try testing.expectEqual(config.DefaultSource.user, source);
    try testing.expectEqual(@as(u8, 33), cfg2.workspaces.count);
}

// P1-43 acceptance: a typo in an INCLUDED file is attributed to that file
// (file:line), not to the entry config.toml -- the whole point of Entry.file.
// Real files through the real load: config.toml includes theme.toml, the
// typo'd key lives on theme.toml's line 2, and the captured warn says so.
test "a typo in an included file is reported against THAT file" {
    const alloc = testing.allocator;
    var box = try snapshot_test.Sandbox.init(alloc, "include-typo");
    defer box.deinit(alloc);
    const env = try box.redirectEnv(alloc);
    defer alloc.free(env[0]);
    defer alloc.free(env[1]);
    defer config.deinitGoodSource(alloc);

    try box.write("hana/config.toml", "include = [\"theme.toml\"]\n");
    try box.write("hana/theme.toml", "[bar]\nheigth = 24\n");

    var bag: diagnostics.Diagnostics = .{ .allocator = alloc };
    defer bag.deinit();
    try config.checkConfig(alloc, &bag);

    // The unconsumed-key warning names theme.toml AND its line (heigth is
    // line 2 there). The include line in config.toml is consumed, so no
    // config.toml:... attribution exists for this typo.
    try testing.expect(bag.contains("theme.toml:2"));
    try testing.expect(!bag.contains("config.toml:"));
}

// ---------------------------------------------------------------------------
// Boot degradation, search policy, load ceilings
// ---------------------------------------------------------------------------

test "A config that fails fragment validate falls back at BOOT" {
    const alloc = testing.allocator;
    var box = try snapshot_test.Sandbox.init(alloc, "invalid-boot");
    defer box.deinit(alloc);
    const env = try box.redirectEnv(alloc);
    defer alloc.free(env[0]);
    defer alloc.free(env[1]);
    defer config.deinitGoodSource(alloc);

    // Valid TOML, semantically impossible: 500% is far outside the
    // [min_master_width, max_master_width] band. This is the config that
    // takes the WM down at boot while a typo'd key does not.
    // The `%` matters: a bare number parses as an ABSOLUTE pixel value, which
    // validation accepts (the screen width is not known here), so `500` would
    // be a perfectly good config and the test would prove nothing.
    try box.write("hana/config.toml", "[tiling]\nmaster_width = 500%\n");

    // The load FAILS inside composed.parse (tiling_config.validate returns
    // error.InvalidConfig), and that is a fatal search error (see
    // discover.isFatalLoadError): it propagates out of loadConfigDefault
    // rather than warn-and-skipping to the next search path.
    var source: config.DefaultSource = .fallback;
    try testing.expectError(error.InvalidConfig, config.loadConfigDefault(alloc, &source, true));

    // `load` is the boot entry point, and it must come back with a config
    // rather than the error: the catch in loadFor swaps in the embedded
    // fallback. Exercised for real, not simulated.
    var booted = try config.load(alloc);
    defer booted.deinit(alloc);
    // The fallback's own master width (55%), not the impossible 500%.
    try testing.expect(booted.tiling.master_width.is_percentage);
    try testing.expect(scaling.asRatio(booted.tiling.master_width) <= model.max_master_width);
}

test "An EMPTY XDG_CONFIG_HOME is treated as unset, not as cwd-relative" {
    var buf: [std.fs.max_path_bytes]u8 = undefined;

    // The regression: getenv returned a non-null empty string, so the old code
    // used "" as the config home and `path.join("", "hana")` produced the
    // RELATIVE path "hana" -- the config search silently became relative to the
    // working directory, so the same config tree gave two different WMs
    // depending on where hana was started.
    const from_empty = try discover.configHome(&buf, "", "/home/u");
    try testing.expectEqualStrings("/home/u/.config", from_empty);
    try testing.expect(std.fs.path.isAbsolute(from_empty));

    // Set and non-empty: wins over HOME, as the spec says.
    const from_xdg = try discover.configHome(&buf, "/xdg/here", "/home/u");
    try testing.expectEqualStrings("/xdg/here", from_xdg);

    // Unset, and the HOME-unset case the loader now warns about (it passes "/"
    // so the search stays absolute instead of collapsing to a bare "hana").
    const from_home = try discover.configHome(&buf, null, "/");
    try testing.expectEqualStrings("/.config", from_home);
    try testing.expect(std.fs.path.isAbsolute(from_home));
}

// A directory with `.toml` files but no `config.toml` is not a config
// source: the search skips it and moves on, and that skip must be REPORTED
// -- booting whatever location answers next without a word would leave a
// whole file on disk that hana never read.
test "A config dir without config.toml is skipped, and says so" {
    const alloc = testing.allocator;
    var box = try snapshot_test.Sandbox.init(alloc, "entryless");
    defer box.deinit(alloc);
    const env = try box.redirectEnv(alloc);
    defer alloc.free(env[0]);
    defer alloc.free(env[1]);
    defer config.deinitGoodSource(alloc);

    // An unknown knob: were this file ever parsed, its name would surface as
    // an unrecognized-key diagnostic. Its ABSENCE below is therefore the
    // proof the directory contributed nothing to the load.
    try box.write("hana/stray.toml", "[tiling]\nzzz_stray_knob = 1\n");

    var diag: diagnostics.Diagnostics = .{ .allocator = alloc };
    defer diag.deinit();
    try config.checkConfig(alloc, &diag);

    try testing.expect(diag.count() > 0);
    try testing.expect(diag.contains("has no config.toml"));
    try testing.expect(!diag.contains("zzz_stray_knob"));
}

test "A config tree over the file ceiling is refused, not partially loaded" {
    const alloc = testing.allocator;
    var box = try snapshot_test.Sandbox.init(alloc, "toomany");
    defer box.deinit(alloc);
    const env = try box.redirectEnv(alloc);
    defer alloc.free(env[0]);
    defer alloc.free(env[1]);
    defer config.deinitGoodSource(alloc);

    // One file over the ceiling, each a valid, tiny, distinct config. A load
    // that skipped the surplus would still "succeed" and quietly drop them.
    // The tree grows through the entry file's include list, which is the only
    // way a config dir holds more than its one file now: config.toml itself,
    // plus max_config_files + 1 includes.
    var include_list: std.ArrayList(u8) = .empty;
    defer include_list.deinit(alloc);
    try include_list.appendSlice(alloc, "include = [");
    var path_buf: [32]u8 = undefined;
    var rel_buf: [16]u8 = undefined;
    for (0..config.max_config_files + 1) |i| {
        const rel = try std.fmt.bufPrint(&rel_buf, "c{d:0>3}.toml", .{i});
        const path = try std.fmt.bufPrint(&path_buf, "hana/{s}", .{rel});
        try box.write(path, "[binds]\n");
        if (i != 0) try include_list.appendSlice(alloc, ", ");
        try include_list.print(alloc, "\"{s}\"", .{rel});
    }
    try include_list.appendSlice(alloc, "]\n");
    try box.write("hana/config.toml", include_list.items);

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
    var diag: diagnostics.Diagnostics = .{ .allocator = alloc };
    defer diag.deinit();
    try config.checkConfig(alloc, &diag);
    try testing.expect(diag.count() > 0);
    try testing.expect(diag.contains("gap_wdth"));
    // Every captured diagnostic must reconstruct into the same shape the
    // stderr path would have written -- that is what the mode prints.
    var buf: [256]u8 = undefined;
    for (diag.items.items) |d| {
        const line = diagnostics.Diagnostics.line(d, &buf);
        try testing.expect(line.text.len > "[x] ".len);
        try testing.expect(std.mem.startsWith(u8, line.text, "["));
    }

    // A config the loader cannot parse at all: still diagnostics, and still no
    // error return -- a broken config is a reportable RESULT, not a crash.
    try box.write("hana/config.toml", "this is not toml [[[\n");
    var bad: diagnostics.Diagnostics = .{ .allocator = alloc };
    defer bad.deinit();
    try config.checkConfig(alloc, &bad);
    try testing.expect(bad.count() > 0);

    // The collector is restored on every path, so an installed-then-removed
    // bag cannot keep intercepting later diagnostics.
    try testing.expect(diagnostics.diagnostics == null);

    // A load keeps the winning source alive past its own arena (the
    // snapshot re-exec needs it after the parse arena is gone), so the load
    // allocator is still the owner of those bytes until this releases them.
    config.deinitGoodSource(alloc);
}

test "checkConfig reports the lint warns (mis-cased section, inert family)" {
    // The three lint observations in lintDocument run inside the same load
    // the mode counts diagnostics from; each case below names the SPECIFIC
    // warn it expects, so a bag that counted only the unconsumed-key sweep
    // (already covered above) cannot make these pass by noise.
    const alloc = testing.allocator;
    var box = try snapshot_test.Sandbox.init(alloc, "checkcfglint");
    defer box.deinit(alloc);
    const env = try box.redirectEnv(alloc);
    defer alloc.free(env[0]);
    defer alloc.free(env[1]);

    // Case-only miss on a known section header: the section would otherwise
    // parse with zero content and look like an empty config.
    try box.write("hana/config.toml", "[Tiling]\ngap = 9\n");
    var mis: diagnostics.Diagnostics = .{ .allocator = alloc };
    defer mis.deinit();
    try config.checkConfig(alloc, &mis);
    try testing.expect(mis.count() > 0);
    try testing.expect(mis.contains("[Tiling]"));
    try testing.expect(mis.contains("mis-cased"));
    config.deinitGoodSource(alloc);

    // A tiling.* family section without its bare [tiling] parent: the knobs
    // parse but do nothing, which is silent without this warn.
    try box.write("hana/config.toml", "[tiling.foo]\nwhatever = 1\n");
    var inert: diagnostics.Diagnostics = .{ .allocator = alloc };
    defer inert.deinit();
    try config.checkConfig(alloc, &inert);
    try testing.expect(inert.count() > 0);
    try testing.expect(inert.contains("inert"));
    config.deinitGoodSource(alloc);

    // The same for [bar.properties] without [bar].
    try box.write("hana/config.toml", "[bar.properties]\nfont_size = 12\n");
    var bar_inert: diagnostics.Diagnostics = .{ .allocator = alloc };
    defer bar_inert.deinit();
    try config.checkConfig(alloc, &bar_inert);
    try testing.expect(bar_inert.count() > 0);
    try testing.expect(bar_inert.contains("[bar.properties]"));
    try testing.expect(bar_inert.contains("inert"));
    config.deinitGoodSource(alloc);

    // The rule-table families (D13 extension, P2-50): [rules.*] without
    // [rules], and [workspace.rules.*] without [workspace.rules], warn the
    // same way the tiling family does.
    try box.write("hana/config.toml", "[rules.foo]\nbogus = 1\n");
    var rules_inert: diagnostics.Diagnostics = .{ .allocator = alloc };
    defer rules_inert.deinit();
    try config.checkConfig(alloc, &rules_inert);
    try testing.expect(rules_inert.count() > 0);
    try testing.expect(rules_inert.contains("[rules.*]"));
    try testing.expect(rules_inert.contains("inert"));
    config.deinitGoodSource(alloc);

    try box.write("hana/config.toml", "[workspace.rules.2]\nbogus = 1\n");
    var ws_inert: diagnostics.Diagnostics = .{ .allocator = alloc };
    defer ws_inert.deinit();
    try config.checkConfig(alloc, &ws_inert);
    try testing.expect(ws_inert.count() > 0);
    try testing.expect(ws_inert.contains("[workspace.rules.*]"));
    try testing.expect(ws_inert.contains("inert"));
    config.deinitGoodSource(alloc);

    // The collector is restored on every path (same invariant the main
    // checkConfig test pins).
    try testing.expect(diagnostics.diagnostics == null);
}

test "checkConfig: duplicate-accumulate exemptions come from the fragments (D13)" {
    // A duplicated scalar key NOT on any fragment's exemption list warns
    // "later wins"; the fragment-declared pairs (here [tiling] layouts,
    // from tiling_config) accumulate silently. The install path is
    // buildConfigFromDoc -> composed.parse, so this test pins the plumbing,
    // not just the table.
    const alloc = testing.allocator;
    var box = try snapshot_test.Sandbox.init(alloc, "checkcfgdup");
    defer box.deinit(alloc);
    const env = try box.redirectEnv(alloc);
    defer alloc.free(env[0]);
    defer alloc.free(env[1]);

    try box.write("hana/config.toml", "[display]\ndpi = 96\ndpi = 100\n");
    var dup: diagnostics.Diagnostics = .{ .allocator = alloc };
    defer dup.deinit();
    try config.checkConfig(alloc, &dup);
    try testing.expect(dup.contains("Duplicate key"));
    try testing.expect(dup.contains("dpi"));
    config.deinitGoodSource(alloc);

    try box.write("hana/config.toml", "[tiling]\nlayouts = master-stack\nlayouts = master-stack\n");
    var tiling_dup: diagnostics.Diagnostics = .{ .allocator = alloc };
    defer tiling_dup.deinit();
    try config.checkConfig(alloc, &tiling_dup);
    try testing.expect(!tiling_dup.contains("Duplicate key 'layouts'"));
    config.deinitGoodSource(alloc);
    try testing.expect(diagnostics.diagnostics == null);
}

test "the shipped example config loads cleanly through the real pipeline" {
    // The repo's config/ tree is the documented user experience (README
    // points at it): if config.toml / binds.toml / themes/akai.toml drift
    // into something the loader rejects, this is the test that says so --
    // the same load a user's first run performs, includes and merge order
    // included, not a hand-picked fragment. This is the CI gate P1-26 asks
    // for; `--check-config` is the heavier manual cousin (it needs a
    // -Dconfig-warn build to see warns).
    const alloc = testing.allocator;
    var box = try snapshot_test.Sandbox.init(alloc, "shipped");
    defer box.deinit(alloc);
    const env = try box.redirectEnv(alloc);
    defer alloc.free(env[0]);
    defer alloc.free(env[1]);

    // Stage the three shipped files at the paths config.toml's include list
    // names (includes resolve relative to the entry file's dir). Only these:
    // config/ may hold files the loader must NOT see, and the entry-file
    // rule means anything else there is inert by design.
    const io = std.Options.debug_io;
    inline for (.{ "config.toml", "binds.toml", "themes/akai.toml" }) |rel| {
        const src_path = try std.Io.Dir.cwd().realPathFileAlloc(io, "config/" ++ rel, alloc);
        defer alloc.free(src_path);
        const bytes = try config.readFileAlloc(alloc, src_path);
        defer alloc.free(bytes);
        try box.write("hana/" ++ rel, bytes);
    }

    var source: config.DefaultSource = .fallback;
    var cfg = try config.loadConfigDefault(alloc, &source, false);
    defer cfg.deinit(alloc);

    // Loaded from the user tree (not the fallback), the include merged
    // binds.toml in, and the theme's [bar] bg won the merge -- one assert
    // per contributing file, so a dropped include fails on the file that
    // went missing rather than only on the overall parse.
    try testing.expectEqual(config.DefaultSource.user, source);
    try testing.expect(cfg.core.keybindings.items.len > 0);
    try testing.expectEqual(@as(u32, 0x0d0d14), cfg.bar.bg);
    try testing.expectEqual(@as(u16, 50), cfg.tiling.min_window_dim);

    config.deinitGoodSource(alloc);
}

test "Diagnostics.line clips an over-long diagnostic instead of erroring" {
    // bufPrint refuses rather than truncating; line() must swallow that and
    // report it, because --check-config printing a >1KiB diagnostic used to
    // abort the whole check with a propagated NoSpaceLeft.
    const long_msg = "y" ** 4096;
    const d: diagnostics.Diagnostic = .{
        .level = .warn,
        .module = "mod",
        .message = long_msg,
    };
    var buf: [64]u8 = undefined;
    const clipped = diagnostics.Diagnostics.line(d, &buf);
    try testing.expect(clipped.truncated);
    try testing.expectEqual(buf.len, clipped.text.len);
    try testing.expect(std.mem.startsWith(u8, clipped.text, "[mod] "));

    // A line that fits EXACTLY is not marked truncated (the old
    // len == buf.len heuristic would have been).
    var exact_buf: [7]u8 = undefined;
    const exact: diagnostics.Diagnostic = .{ .level = .warn, .module = "m", .message = "abc" };
    const whole = diagnostics.Diagnostics.line(exact, &exact_buf);
    try testing.expect(!whole.truncated);
    try testing.expectEqualStrings("[m] abc", whole.text);

    // An empty buffer yields an empty, truncated result -- no panic, no
    // write out of bounds.
    var empty: [0]u8 = undefined;
    const none = diagnostics.Diagnostics.line(exact, &empty);
    try testing.expect(none.truncated);
    try testing.expectEqual(@as(usize, 0), none.text.len);
}
