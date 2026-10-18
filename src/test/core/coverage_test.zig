//! Coverage-skew gate (P1-28): the tracked allowlist in
//! `dev/test-coverage-allowlist.txt` names every production stem no test
//! file directly `@import`s. This test recomputes both directions from the
//! tree on disk and requires exact agreement, so the list cannot rot: a new
//! untested production stem fails here until it gains a direct test or a
//! listed rationale, and a listed stem some test has since imported fails
//! here until the entry is dropped. Repo-root cwd (the suite's standing
//! assumption, shared with the config tests that read config/*.toml).

const std = @import("std");
const testing = std.testing;
const io = std.testing.io;

const allowlist_path = "dev/test-coverage-allowlist.txt";

/// Production stems: every `src/**/*.zig` that is not a test file itself.
/// Build-generated modules (surfaces, composed, tiling_seam, ...) are not
/// files under src/ and never appear; the vendored runner lives under dev/.
fn collectProductionStems(alloc: std.mem.Allocator) !std.StringHashMap(void) {
    var set: std.StringHashMap(void) = .init(alloc);
    errdefer {
        var it = set.keyIterator();
        while (it.next()) |k| alloc.free(k.*);
        set.deinit();
    }
    var dir = try std.Io.Dir.cwd().openDir(io, "src", .{ .iterate = true });
    defer dir.close(io);
    var walker = try dir.walk(alloc);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.path, ".zig")) continue;
        if (std.mem.endsWith(u8, entry.path, "_test.zig")) continue;
        if (std.mem.startsWith(u8, entry.path, "test/")) continue;
        const name = try alloc.dupe(u8, std.fs.path.stem(entry.path));
        const gop = try set.getOrPut(name);
        if (gop.found_existing) alloc.free(name) else gop.key_ptr.* = name;
    }
    return set;
}

/// The set of stems named by an `@import("...")` anywhere under src/test/.
/// Non-module imports (std, builtin, ...) simply never match a production
/// stem, so they need no filtering here.
fn collectTestImportedStems(alloc: std.mem.Allocator) !std.StringHashMap(void) {
    var set: std.StringHashMap(void) = .init(alloc);
    errdefer {
        var it = set.keyIterator();
        while (it.next()) |k| alloc.free(k.*);
        set.deinit();
    }
    var dir = try std.Io.Dir.cwd().openDir(io, "src/test", .{ .iterate = true });
    defer dir.close(io);
    var walker = try dir.walk(alloc);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.path, ".zig")) continue;
        const rel = try std.fmt.allocPrint(alloc, "src/test/{s}", .{entry.path});
        defer alloc.free(rel);
        const bytes = try std.Io.Dir.cwd().readFileAlloc(io, rel, alloc, .limited(4 << 20));
        defer alloc.free(bytes);
        var pos: usize = 0;
        while (std.mem.indexOfPos(u8, bytes, pos, "@import(\"")) |at| {
            const start = at + "@import(\"".len;
            const end = std.mem.indexOfScalarPos(u8, bytes, start, '"') orelse break;
            pos = end + 1;
            if (start == end) continue;
            // Dupe: `bytes` dies with this iteration, the set outlives it.
            // A repeated stem (every file imports std) must free its dupe:
            // put would discard the new key and leak it.
            const name = try alloc.dupe(u8, bytes[start..end]);
            const gop = try set.getOrPut(name);
            if (gop.found_existing) alloc.free(name) else gop.key_ptr.* = name;
        }
    }
    return set;
}

/// Stems listed in the allowlist file: first whitespace-delimited token of
/// each non-comment, non-empty line.
fn loadAllowlist(alloc: std.mem.Allocator) !std.StringHashMap(void) {
    var set: std.StringHashMap(void) = .init(alloc);
    errdefer {
        var it = set.keyIterator();
        while (it.next()) |k| alloc.free(k.*);
        set.deinit();
    }
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, allowlist_path, alloc, .limited(1 << 20));
    defer alloc.free(bytes);
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0 or trimmed[0] == '#') continue;
        const end = std.mem.indexOfScalar(u8, trimmed, ' ') orelse trimmed.len;
        const name = try alloc.dupe(u8, trimmed[0..end]);
        const gop = try set.getOrPut(name);
        if (gop.found_existing) alloc.free(name) else gop.key_ptr.* = name;
    }
    return set;
}

test "coverage allowlist matches the tree exactly (P1-28)" {
    const alloc = testing.allocator;
    var prod = try collectProductionStems(alloc);
    defer {
        var it = prod.keyIterator();
        while (it.next()) |k| alloc.free(k.*);
        prod.deinit();
    }
    var imported = try collectTestImportedStems(alloc);
    defer {
        var it = imported.keyIterator();
        while (it.next()) |k| alloc.free(k.*);
        imported.deinit();
    }
    var allow = try loadAllowlist(alloc);
    defer {
        var it = allow.keyIterator();
        while (it.next()) |k| alloc.free(k.*);
        allow.deinit();
    }

    // Bidirectional exactness: unlisted-untested and listed-but-now-tested
    // both fail, and the message names the stem and the fix either way.
    var missing: std.ArrayList([]const u8) = .empty; // untested, not listed
    defer missing.deinit(alloc);
    var stale: std.ArrayList([]const u8) = .empty; // listed, but imported (or gone)
    defer stale.deinit(alloc);

    var pit = prod.keyIterator();
    while (pit.next()) |sp| {
        if (imported.contains(sp.*)) continue;
        if (!allow.contains(sp.*)) try missing.append(alloc, sp.*);
    }
    var ait = allow.keyIterator();
    while (ait.next()) |sp| {
        if (!prod.contains(sp.*) or imported.contains(sp.*)) try stale.append(alloc, sp.*);
    }

    if (missing.items.len > 0 or stale.items.len > 0) {
        const less = struct {
            fn f(_: void, a: []const u8, b: []const u8) bool {
                return std.mem.lessThan(u8, a, b);
            }
        }.f;
        std.mem.sort([]const u8, missing.items, {}, less);
        std.mem.sort([]const u8, stale.items, {}, less);
        if (missing.items.len > 0) {
            std.debug.print(
                "coverage: {d} production stem(s) untested and NOT in {s}:\n",
                .{ missing.items.len, allowlist_path },
            );
            for (missing.items) |s| std.debug.print("  unlisted: {s}\n", .{s});
            std.debug.print("  -> add a direct test, or list the stem with a rationale (P1-28)\n", .{});
        }
        if (stale.items.len > 0) {
            std.debug.print(
                "coverage: {s} lists {d} stale stem(s) (now tested, or no longer production):\n",
                .{ allowlist_path, stale.items.len },
            );
            for (stale.items) |s| std.debug.print("  stale: {s}\n", .{s});
            std.debug.print("  -> drop the entries (P1-28)\n", .{});
        }
        return error.CoverageAllowlistMismatch;
    }
}
