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
// src/core/pure/log.zig silences all std.log diagnostics in test binaries,
// so this stays quiet on success.
const config = @import("config");
const constants = @import("constants");
const paths = @import("paths");
const scaling = @import("scaling");
const scratch = @import("scratch");
const log = @import("log");

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

// libc bindings for setenv/chdir; the 0.16 stdlib has no wrappers for them,
// mirroring the pattern restart.zig and events.zig already use.
const libc = @cImport({
    @cInclude("unistd.h");
    @cInclude("stdlib.h");
});

const snapio = std.Options.debug_io;

fn setEnv(key: [:0]const u8, value: [:0]const u8) void {
    if (libc.setenv(key.ptr, value.ptr, 1) != 0) @panic("setenv failed");
}

fn deleteTreeAbs(abs: []const u8) void {
    const base = std.fs.path.basename(abs);
    const parent = std.fs.path.dirname(abs) orelse return;
    if (base.len == 0) return;
    var d = std.Io.Dir.openDirAbsolute(snapio, parent, .{}) catch return;
    defer d.close(snapio);
    d.deleteTree(snapio, base) catch {};
}

fn lessPath(_: void, a: []u8, b: []u8) bool {
    return std.mem.lessThan(u8, a, b);
}

/// A unique scratch root with a config dir and a private runtime dir inside
/// it, so XDG_CONFIG_HOME and XDG_RUNTIME_DIR can both point into it. Every
/// path is absolute and under a fresh `/tmp` directory, so no test can touch
/// the developer's real config.
const Sandbox = struct {
    root: []u8,
    /// Stands in for XDG_RUNTIME_DIR: refreshSnapshot creates `hana-config`
    /// inside it.
    runtime: []u8,
    /// (28.5) Owns the temp tree `root`/`runtime` live in, so cleanup is a
    /// single TmpDir drop instead of two recursive deletes that can each
    /// half-succeed.
    tmp: std.testing.TmpDir,

    fn init(alloc: std.mem.Allocator, name: []const u8) !Sandbox {
        // (28.5) A per-sandbox tmpDir rather than a child of a shared
        // process-global scratch dir. Two consequences worth naming: the
        // isolation no longer depends on a PRNG argument, and
        // TmpDir.cleanup() removes the whole tree on drop, so there is no
        // separate recursive delete that can half-succeed and leave the rest.
        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const base_len = try tmp.dir.realPath(snapio, &buf);
        const root = try std.fmt.allocPrint(alloc, "{s}/{s}", .{ buf[0..base_len], name });
        errdefer alloc.free(root);
        const runtime = try std.fmt.allocPrint(alloc, "{s}-run", .{root});
        errdefer alloc.free(runtime);
        try std.Io.Dir.createDirAbsolute(snapio, root, .default_dir);
        try std.Io.Dir.createDirAbsolute(snapio, runtime, .default_dir);
        return .{ .root = root, .runtime = runtime, .tmp = tmp };
    }

    fn deinit(self: Sandbox, alloc: std.mem.Allocator) void {
        // (28.5) tmp.cleanup() removes the whole tree, root and runtime
        // included. The old deleteTreeAbs pair removed each independently and
        // ignored failures, so a partially-failed delete silently left files
        // behind with nothing left to retry with.
        var tmp = self.tmp; // cleanup takes *TmpDir; deinit() is by-value
        tmp.cleanup();
        alloc.free(self.root);
        alloc.free(self.runtime);
    }

    /// Points XDG_CONFIG_HOME and XDG_RUNTIME_DIR at this sandbox. The
    /// returned slices are the caller's to free.
    fn redirectEnv(self: Sandbox, alloc: std.mem.Allocator) !struct { [:0]u8, [:0]u8 } {
        const cfg_home = try alloc.dupeZ(u8, self.root);
        errdefer alloc.free(cfg_home);
        const runtime = try alloc.dupeZ(u8, self.runtime);
        setEnv("XDG_CONFIG_HOME", cfg_home);
        setEnv("XDG_RUNTIME_DIR", runtime);
        return .{ cfg_home, runtime };
    }

    /// Creates `rel` (with its parents) under the sandbox root and writes
    /// `content` into it.
    fn write(self: Sandbox, rel: []const u8, content: []const u8) !void {
        var d = try std.Io.Dir.openDirAbsolute(snapio, self.root, .{ .iterate = true });
        defer d.close(snapio);
        if (std.fs.path.dirname(rel)) |dir| try d.createDirPath(snapio, dir);
        const f = try d.createFile(snapio, rel, .{});
        defer f.close(snapio);
        try f.writePositionalAll(snapio, content, 0);
    }

    fn remove(self: Sandbox, rel: []const u8) void {
        var d = std.Io.Dir.openDirAbsolute(snapio, self.root, .{}) catch return;
        defer d.close(snapio);
        d.deleteFile(snapio, rel) catch {};
    }

    fn path(self: Sandbox, alloc: std.mem.Allocator, rel: []const u8) ![]u8 {
        return std.fmt.allocPrint(alloc, "{s}/{s}", .{ self.root, rel });
    }

    /// `<runtime>/hana-config`: where refreshSnapshot lands.
    fn snapshotDir(self: Sandbox, alloc: std.mem.Allocator) ![]u8 {
        return std.fmt.allocPrint(alloc, "{s}/hana-config", .{self.runtime});
    }

    /// Sorted relative paths of every file under `dir`, so a tree can be
    /// compared exactly: no extras, no omissions, order-insensitive.
    fn treeFiles(alloc: std.mem.Allocator, dir: []const u8) ![][]u8 {
        var out: std.ArrayList([]u8) = .empty;
        errdefer freeTree(alloc, out.items);
        var d = std.Io.Dir.openDirAbsolute(snapio, dir, .{ .iterate = true }) catch |err| switch (err) {
            error.FileNotFound => return out.toOwnedSlice(alloc),
            else => return err,
        };
        defer d.close(snapio);
        var w = try d.walk(alloc);
        defer w.deinit();
        while (try w.next(snapio)) |entry| {
            if (entry.kind == .directory) continue;
            try out.append(alloc, try alloc.dupe(u8, entry.path));
        }
        std.mem.sort([]u8, out.items, {}, lessPath);
        return out.toOwnedSlice(alloc);
    }
};

fn freeTree(alloc: std.mem.Allocator, files: [][]u8) void {
    for (files) |p| alloc.free(p);
    alloc.free(files);
}

test "refreshSnapshot freezes only the config files the load consumed" {
    const alloc = testing.allocator;
    const box = try Sandbox.init(alloc, "only");
    defer box.deinit(alloc);
    const env = try box.redirectEnv(alloc);
    defer alloc.free(env[0]);
    defer alloc.free(env[1]);

    // What the loader actually reads: one top-level file plus an include.
    // `include` is only honoured as a ROOT key (parser.zig:230), so it has to
    // sit above the first table header.
    try box.write("hana/config.toml",
        \\include = ["themes/akai.toml"]
        \\[binds]
        \\Mod = "Mod4"
    );
    try box.write("hana/themes/akai.toml",
        \\[bar]
        \\visible = true
    );
    // Everything below also lives in the user's config directory but is NOT
    // config: the tree a package-manager drop leaves behind. This is the case
    // that made every boot copy thousands of unrelated files into tmpfs.
    try box.write("hana/themes/.opencode/package.json", "{\"name\":\"vendored\"}");
    try box.write("hana/themes/.opencode/node_modules/dep/index.js", "module.exports=1;");
    try box.write("hana/themes/.opencode/node_modules/dep/lib/deep.js", "module.exports=2;");
    try box.write("hana/.git/config", "[core]\n");
    try box.write("hana/notes.txt", "not config");

    // The good-source state is process-lifetime in production; hand it back
    // so the DebugAllocator sees a clean slate.
    defer config.deinitGoodSource(alloc);
    var source: config.DefaultSource = .fallback;
    var cfg = try config.loadConfigDefault(alloc, &source, false);
    defer cfg.deinit(alloc);
    try testing.expectEqual(config.DefaultSource.user, source);
    config.refreshSnapshot(alloc);

    const snap = try box.snapshotDir(alloc);
    defer alloc.free(snap);
    const got = try Sandbox.treeFiles(alloc, snap);
    defer freeTree(alloc, got);

    // Exactly the two files the load merged, with the include's subdirectory
    // preserved (the successor resolves includes against the snapshot dir).
    try testing.expectEqual(@as(usize, 2), got.len);
    try testing.expectEqualStrings("config.toml", got[0]);
    try testing.expectEqualStrings("themes/akai.toml", got[1]);

    // And the contents match, so the successor boots an identical config.
    const snap_cfg = try std.fs.path.join(alloc, &.{ snap, "config.toml" });
    defer alloc.free(snap_cfg);
    const cfg_text = try config.readFileAlloc(alloc, snap_cfg);
    defer alloc.free(cfg_text);
    try testing.expect(std.mem.indexOf(u8, cfg_text, "Mod4") != null);

    const snap_theme = try std.fs.path.join(alloc, &.{ snap, "themes/akai.toml" });
    defer alloc.free(snap_theme);
    const theme_text = try config.readFileAlloc(alloc, snap_theme);
    defer alloc.free(theme_text);
    try testing.expect(std.mem.indexOf(u8, theme_text, "visible") != null);
}

test "an unchanged reload rewrites nothing, and an edit is picked up" {
    const alloc = testing.allocator;
    const box = try Sandbox.init(alloc, "unchanged");
    defer box.deinit(alloc);
    const env = try box.redirectEnv(alloc);
    defer alloc.free(env[0]);
    defer alloc.free(env[1]);

    try box.write("hana/config.toml",
        \\[binds]
        \\Mod = "Mod4"
    );

    // The good-source state is process-lifetime in production; hand it back
    // so the DebugAllocator sees a clean slate.
    defer config.deinitGoodSource(alloc);
    var source: config.DefaultSource = .fallback;
    var cfg = try config.loadConfigDefault(alloc, &source, false);
    defer cfg.deinit(alloc);
    config.refreshSnapshot(alloc);

    const snap = try box.snapshotDir(alloc);
    defer alloc.free(snap);
    const snap_cfg = try std.fs.path.join(alloc, &.{ snap, "config.toml" });
    defer alloc.free(snap_cfg);

    const statOf = struct {
        fn go(p: []const u8) !std.Io.File.Stat {
            const f = try std.Io.Dir.openFileAbsolute(snapio, p, .{});
            defer f.close(snapio);
            return f.stat(snapio);
        }
    }.go;

    const first = try statOf(snap_cfg);
    // A second load+refresh of an untouched config must do no writes at all:
    // same inode, same mtime.
    var source2: config.DefaultSource = .fallback;
    var cfg2 = try config.loadConfigDefault(alloc, &source2, false);
    defer cfg2.deinit(alloc);
    config.refreshSnapshot(alloc);
    const second = try statOf(snap_cfg);
    try testing.expectEqual(first.inode, second.inode);
    try testing.expectEqual(first.mtime.nanoseconds, second.mtime.nanoseconds);

    // Editing the source must invalidate it: the snapshot follows the config.
    try box.write("hana/config.toml",
        \\[binds]
        \\Mod = "Mod4"
        \\Mod+Q = "close"
    );
    var source3: config.DefaultSource = .fallback;
    var cfg3 = try config.loadConfigDefault(alloc, &source3, false);
    defer cfg3.deinit(alloc);
    config.refreshSnapshot(alloc);
    const edited = try config.readFileAlloc(alloc, snap_cfg);
    defer alloc.free(edited);
    try testing.expect(std.mem.indexOf(u8, edited, "Mod+Q") != null);
}

test "a renamed config file is not left behind in the snapshot" {
    const alloc = testing.allocator;
    const box = try Sandbox.init(alloc, "renamed");
    defer box.deinit(alloc);
    const env = try box.redirectEnv(alloc);
    defer alloc.free(env[0]);
    defer alloc.free(env[1]);

    try box.write("hana/aaa.toml", "[binds]\nMod = \"Mod4\"\n");
    // The good-source state is process-lifetime in production; hand it back
    // so the DebugAllocator sees a clean slate.
    defer config.deinitGoodSource(alloc);
    var source: config.DefaultSource = .fallback;
    var cfg = try config.loadConfigDefault(alloc, &source, false);
    defer cfg.deinit(alloc);
    config.refreshSnapshot(alloc);

    // The user renames their file. A refresh that only ADDED the new name
    // would leave the old one behind, and the successor would then load a
    // config file the user had deleted.
    try box.write("hana/zzz.toml", "[binds]\nMod = \"Mod4\"\n");
    box.remove("hana/aaa.toml");

    var source2: config.DefaultSource = .fallback;
    var cfg2 = try config.loadConfigDefault(alloc, &source2, false);
    defer cfg2.deinit(alloc);
    config.refreshSnapshot(alloc);

    const snap = try box.snapshotDir(alloc);
    defer alloc.free(snap);
    const got = try Sandbox.treeFiles(alloc, snap);
    defer freeTree(alloc, got);
    try testing.expectEqual(@as(usize, 1), got.len);
    try testing.expectEqualStrings("zzz.toml", got[0]);
}

test "a single-file config source still snapshots as config.toml" {
    const alloc = testing.allocator;
    const box = try Sandbox.init(alloc, "single");
    defer box.deinit(alloc);
    const env = try box.redirectEnv(alloc);
    defer alloc.free(env[0]);
    defer alloc.free(env[1]);

    // Only a single-file location may match, so the directory branch of the
    // search is taken out of the running: the cwd is pointed at an empty
    // scratch dir, because `local_dir` is `<cwd>/config` and the repo root
    // has a real one.
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    _ = std.c.getcwd(&cwd_buf, cwd_buf.len) orelse return error.CwdUnavailable;
    const orig_cwd = try alloc.dupeZ(u8, std.mem.sliceTo(&cwd_buf, 0));
    defer alloc.free(orig_cwd);
    const empty = try box.path(alloc, "elsewhere");
    defer alloc.free(empty);
    try std.Io.Dir.createDirAbsolute(snapio, empty, .default_dir);
    if (libc.chdir(empty.ptr) != 0) return error.ChdirFailed;
    defer _ = libc.chdir(orig_cwd.ptr);

    // `local_file` is `<cwd>/config.toml` and its `local_dir` sibling
    // (`<cwd>/config`) is absent, so the loader takes the single-file branch.
    // The XDG pair is unreachable here on purpose: `xdg_file` lives INSIDE
    // `xdg_dir`, so a file there would always be found by the directory
    // branch first.
    try box.write("elsewhere/config.toml", "[binds]\nMod = \"Mod4\"\n");
    // The good-source state is process-lifetime in production; hand it back
    // so the DebugAllocator sees a clean slate.
    defer config.deinitGoodSource(alloc);
    var source: config.DefaultSource = .fallback;
    var cfg = try config.loadConfigDefault(alloc, &source, false);
    defer cfg.deinit(alloc);
    try testing.expectEqual(config.DefaultSource.user, source);
    config.refreshSnapshot(alloc);

    // The directory loader picks the frozen file up by this exact name.
    const snap = try box.snapshotDir(alloc);
    defer alloc.free(snap);
    const got = try Sandbox.treeFiles(alloc, snap);
    defer freeTree(alloc, got);
    try testing.expectEqual(@as(usize, 1), got.len);
    try testing.expectEqualStrings("config.toml", got[0]);
}

// ---------------------------------------------------------------------------
// 15.1 / 15.6 / 15.12: boot degradation, search policy, load ceilings
// ---------------------------------------------------------------------------

test "15.1: a config that parses but fails validate falls back at BOOT" {
    const alloc = testing.allocator;
    const box = try Sandbox.init(alloc, "invalid-boot");
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
    const box = try Sandbox.init(alloc, "toomany");
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
    var box = try Sandbox.init(alloc, "checkcfg");
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
