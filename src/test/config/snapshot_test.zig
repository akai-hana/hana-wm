//! Re-exec snapshot tests: what `config.refreshSnapshot` freezes for the
//! successor process. The Sandbox stages an isolated config tree (fresh
//! tmp dir, XDG_CONFIG_HOME/XDG_RUNTIME_DIR pointed into it) so a test
//! pins WHICH files the snapshot copies -- only the files the load
//! consumed, with an include's subdirectory preserved -- and that an
//! unchanged reload rewrites nothing, an edit is picked up, a rename
//! leaves nothing behind, and a single-file source still lands as
//! config.toml. Extracted from config_test.zig (the config load
//! pipeline), whose non-snapshot tests keep using the Sandbox fixture
//! through this module.

const std = @import("std");
const testing = std.testing;

const config = @import("config");

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

fn lessPath(_: void, a: []u8, b: []u8) bool {
    return std.mem.lessThan(u8, a, b);
}

/// A unique scratch root with a config dir and a private runtime dir inside
/// it, so XDG_CONFIG_HOME and XDG_RUNTIME_DIR can both point into it. Every
/// path is absolute and under a fresh `/tmp` directory, so no test can touch
/// the developer's real config.
pub const Sandbox = struct {
    root: []u8,
    /// Stands in for XDG_RUNTIME_DIR: refreshSnapshot creates `hana-config`
    /// inside it.
    runtime: []u8,
    /// (28.5) Owns the temp tree `root`/`runtime` live in, so cleanup is a
    /// single TmpDir drop instead of two recursive deletes that can each
    /// half-succeed.
    tmp: std.testing.TmpDir,
    /// The env values displaced by redirectEnv, restored at deinit: a sandbox
    /// that leaked its XDG overrides into the next test would have every later
    /// env-sensitive path (configHome, discovery) run against a deleted stack.
    /// null = variable was unset before redirectEnv (restored as: unset).
    prior_cfg_home: ?[:0]u8 = null,
    prior_runtime_dir: ?[:0]u8 = null,

    pub fn init(alloc: std.mem.Allocator, name: []const u8) !Sandbox {
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

    pub fn deinit(self: *Sandbox, alloc: std.mem.Allocator) void {
        // Restore the environment that redirectEnv displaced, before dropping
        // the tree: the next test (or a later X-gated one in the same binary)
        // would otherwise read the sandbox's stacked-redirected XDG paths
        // rather than the real ones.
        if (self.prior_cfg_home) |v| {
            if (v.len > 0) {
                setEnv("XDG_CONFIG_HOME", v);
                alloc.free(v);
            } else {
                _ = libc.unsetenv("XDG_CONFIG_HOME".ptr);
                alloc.free(v);
            }
        }
        if (self.prior_runtime_dir) |v| {
            if (v.len > 0) {
                setEnv("XDG_RUNTIME_DIR", v);
                alloc.free(v);
            } else {
                _ = libc.unsetenv("XDG_RUNTIME_DIR".ptr);
                alloc.free(v);
            }
        }
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
    /// returned slices are the caller's to free. The caller's prior env
    /// values are remembered on the receiver for `deinit` to restore.
    pub fn redirectEnv(self: *Sandbox, alloc: std.mem.Allocator) !struct { [:0]u8, [:0]u8 } {
        // Snapshot the current env values before overwriting them: an empty
        // slice records "variable was unset before", so deinit can unsetenv.
        self.prior_cfg_home = if (std.c.getenv("XDG_CONFIG_HOME")) |v|
            try alloc.dupeZ(u8, std.mem.span(v))
        else
            try alloc.dupeZ(u8, "");
        self.prior_runtime_dir = if (std.c.getenv("XDG_RUNTIME_DIR")) |v|
            try alloc.dupeZ(u8, std.mem.span(v))
        else
            try alloc.dupeZ(u8, "");
        const cfg_home = try alloc.dupeZ(u8, self.root);
        errdefer alloc.free(cfg_home);
        const runtime = try alloc.dupeZ(u8, self.runtime);
        errdefer alloc.free(runtime);
        setEnv("XDG_CONFIG_HOME", cfg_home);
        setEnv("XDG_RUNTIME_DIR", runtime);
        return .{ cfg_home, runtime };
    }

    /// Creates `rel` (with its parents) under the sandbox root and writes
    /// `content` into it.
    pub fn write(self: Sandbox, rel: []const u8, content: []const u8) !void {
        var d = try std.Io.Dir.openDirAbsolute(snapio, self.root, .{ .iterate = true });
        defer d.close(snapio);
        if (std.fs.path.dirname(rel)) |dir| try d.createDirPath(snapio, dir);
        const f = try d.createFile(snapio, rel, .{});
        defer f.close(snapio);
        try f.writePositionalAll(snapio, content, 0);
    }

    pub fn remove(self: Sandbox, rel: []const u8) void {
        var d = std.Io.Dir.openDirAbsolute(snapio, self.root, .{}) catch return;
        defer d.close(snapio);
        d.deleteFile(snapio, rel) catch {};
    }

    pub fn path(self: Sandbox, alloc: std.mem.Allocator, rel: []const u8) ![]u8 {
        return std.fmt.allocPrint(alloc, "{s}/{s}", .{ self.root, rel });
    }

    /// `<runtime>/hana-config`: where refreshSnapshot lands.
    pub fn snapshotDir(self: Sandbox, alloc: std.mem.Allocator) ![]u8 {
        return std.fmt.allocPrint(alloc, "{s}/hana-config", .{self.runtime});
    }

    /// Sorted relative paths of every file under `dir`, so a tree can be
    /// compared exactly: no extras, no omissions, order-insensitive.
    pub fn treeFiles(alloc: std.mem.Allocator, dir: []const u8) ![][]u8 {
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
    var box = try Sandbox.init(alloc, "only");
    defer box.deinit(alloc);
    const env = try box.redirectEnv(alloc);
    defer alloc.free(env[0]);
    defer alloc.free(env[1]);

    // What the loader actually reads: one top-level file plus an include.
    // `include` is only honoured as a ROOT key, so it has to
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
    var box = try Sandbox.init(alloc, "unchanged");
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
    var box = try Sandbox.init(alloc, "renamed");
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
    var box = try Sandbox.init(alloc, "single");
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
