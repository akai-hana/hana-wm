//! The last-good config source and the re-exec snapshot. On every
//! successful load/reload the winning user config source is frozen
//! into a snapshot dir, and a re-exec (`reload_hana`) boots from that
//! snapshot via `HANA_CONFIG_DIR`. A re-exec therefore swaps ONLY the
//! binary; config file edits land exclusively through `reload_config`.
//! Because the snapshot is refreshed only on *successful* loads, it is
//! the last-known-good config: a mid-edit (or outright broken) config
//! tree at re-exec time cannot take the successor down with it.

const std = @import("std");
const log = @import("log");

/// Where a default-config load came from. Reported by loadConfigDefault so the
/// reload path can distinguish "loaded the user config" from "fell back to the
/// embedded fallback" without re-probing the filesystem (they resolve to
/// the same Config value otherwise).
pub const DefaultSource = enum {
    /// One of the user locations at priority (1)-(4) supplied the config.
    user,
    /// None of the user locations produced a config; the embedded fallback
    /// was returned (boot-only semantics; reload rejects it).
    fallback,
};

/// Re-exec config hand-off: on every successful load/reload the winning user
/// config source is frozen into a snapshot dir, and a re-exec (`reload_hana`)
/// boots from that snapshot via `HANA_CONFIG_DIR`. A re-exec therefore swaps
/// ONLY the binary; config file edits land exclusively through
/// `reload_config`. Because the snapshot is refreshed only on *successful*
/// loads, it is the last-known-good config: a mid-edit (or outright broken)
/// config tree at re-exec time cannot take the successor down with it.
const GoodSource = struct {
    /// Heap-allocated copy of the winning search location (a dir or a file).
    path: []u8,
    is_dir: bool,
    /// The config files the winning load actually read, in merge order, each
    /// owned by the same allocator as `path`. The snapshot copies exactly
    /// these rather than the whole tree: the config dir is a user-owned
    /// location that also holds plenty hana never reads (a vendored
    /// `.opencode` tree, a `node_modules`, VCS metadata), and freezing all of
    /// it turned a three-file config into a thousands-of-files tmpfs copy on
    /// every boot.
    files: [][]u8,
    /// Size and mtime of each entry in `files` as of the last successful
    /// refresh, or null when the snapshot is not known to mirror the source.
    /// An unchanged reload compares these and writes nothing at all.
    stamps: ?[]FileStamp,
};

/// One resolved config file's identity, captured when it is snapshotted.
const FileStamp = struct { size: u64, mtime: i96 };

/// Backing storage for the resolved-config file set of the most recent load.
/// Module-level because the set must outlive the load-scoped parse arena (it
/// is consumed at snapshot time, after the load has returned), and because
/// discarding it wholesale is then one arena reset instead of per-path free
/// bookkeeping. `publishReadFiles` installs a FRESH arena per load and frees
/// the previous one, so a set is never released by a different load's
/// allocator.
var read_files_arena: ?std.heap.ArenaAllocator = null;

/// The config files the most recent successful load consumed, in merge order.
/// Read (never owned) by `rememberGoodSource` at the end of a winning load.
var load_read_files: [][]const u8 = &.{};

/// Publishes this load's resolved file set, releasing the previous load's.
pub fn publishReadFiles(items: []const []const u8) !void {
    if (read_files_arena) |arena| arena.deinit();
    read_files_arena = null;
    load_read_files = &.{};
    var fresh: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    errdefer fresh.deinit();
    const a = fresh.allocator();
    var out: std.ArrayList([]const u8) = .empty;
    try out.ensureTotalCapacity(a, items.len);
    // Copy the bytes, not just the slice headers: `items` aliases the
    // load-scoped parse arena, which the caller resets as soon as this load
    // returns, long before refreshSnapshot reads the set.
    for (items) |p| try out.append(a, try a.dupe(u8, p));
    read_files_arena = fresh;
    load_read_files = out.items;
}

/// Dupe `items` into a freshly allocated list owned by `allocator`; released
/// with `freeFileList`. An empty input yields a zero-length slice, which
/// `freeFileList` releases as a no-op.
fn dupeFileList(allocator: std.mem.Allocator, items: []const []const u8) ![][]u8 {
    const out = try allocator.alloc([]u8, items.len);
    errdefer allocator.free(out);
    for (items, 0..) |item, i| {
        out[i] = allocator.dupe(u8, item) catch |err| {
            for (out[0..i]) |done| allocator.free(done);
            return err;
        };
    }
    return out;
}

fn freeFileList(allocator: std.mem.Allocator, files: [][]u8) void {
    for (files) |f| allocator.free(f);
    allocator.free(files);
}

/// The most recently loaded-and-validated user config location. Mutated by
/// every successful load/reload; read by refreshSnapshot at re-exec time.
/// Allocated with the caller's (c_allocator) arena semantics, process-lifetime
/// after the winning load holds it.
var last_good_source: ?GoodSource = null;

/// True when two resolved file lists name the same files in the same order.
/// The lists are merge-ordered, so a positional compare is exact.
fn sameFileList(a: []const []u8, b: []const []u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (!std.mem.eql(u8, x, y)) return false;
    }
    return true;
}

pub fn rememberGoodSource(allocator: std.mem.Allocator, path: []const u8, is_dir: bool) void {
    // OOM is silent: the snapshot just keeps the previous good source.
    const duped = allocator.dupe(u8, path) catch return;
    const files = dupeFileList(allocator, load_read_files) catch {
        allocator.free(duped);
        return;
    };
    var kept_stamps: ?[]FileStamp = null;
    if (last_good_source) |g| {
        // Carry the stamps over when this load resolved the very same source
        // to the very same files. That is what lets a no-op reload take the
        // "nothing changed" fast path instead of re-freezing the snapshot on
        // every SIGHUP. The stamps are parallel to `files`, so reusing them
        // against an identical list is index-for-index correct.
        const same = g.is_dir == is_dir and std.mem.eql(u8, g.path, path) and sameFileList(g.files, files);
        if (same) kept_stamps = g.stamps;
        // The freshly duped path/files supersede the old pair either way, so
        // the old ones are always released here; the stamps are the only state
        // that can survive into the new record.
        allocator.free(g.path);
        freeFileList(allocator, g.files);
        if (!same) {
            if (g.stamps) |s| allocator.free(s);
        }
    }
    last_good_source = .{ .path = duped, .is_dir = is_dir, .files = files, .stamps = kept_stamps };
}

/// Releases the good-source state. In a running hana this lives for the whole
/// process in a long-lived arena and is only ever replaced, never torn down;
/// tests call this so the DebugAllocator can account for every byte.
pub fn deinitGoodSource(allocator: std.mem.Allocator) void {
    if (last_good_source) |g| {
        allocator.free(g.path);
        freeFileList(allocator, g.files);
        if (g.stamps) |s| allocator.free(s);
    }
    last_good_source = null;
}

/// Snapshot dir a re-exec boots from. XDG_RUNTIME_DIR is already per-user, so
/// no uid suffix is needed there; the /tmp fallback carries the uid, mirroring
/// persist.zig. Caller owns the returned slice.
fn snapshotDirPath(allocator: std.mem.Allocator) ![]u8 {
    if (std.c.getenv("XDG_RUNTIME_DIR")) |dir| {
        return std.fmt.allocPrint(allocator, "{s}/hana-config", .{std.mem.span(dir)});
    }
    return std.fmt.allocPrint(allocator, "/tmp/hana-config-{d}", .{std.os.linux.getuid()});
}

/// NUL-terminated snapshot path on c_allocator for `setenv`, or null when no
/// snapshot has ever been written (nothing to hand a re-exec). One-shot: the
/// result is intentionally leaked -- it rides the execv environ to the end of
/// the process, mirroring restart.mustDupeZ.
pub fn reexecSnapshotPathZ() ?[:0]const u8 {
    const snap = snapshotDirPath(std.heap.c_allocator) catch return null;
    defer std.heap.c_allocator.free(snap);
    const io = std.Options.debug_io;
    const d = std.Io.Dir.openDirAbsolute(io, snap, .{ .iterate = true }) catch return null;
    defer d.close(io);
    var it = d.iterate();
    if ((it.next(io) catch null) == null) return null;
    return std.heap.c_allocator.dupeZ(u8, snap) catch null;
}

/// Removes `abs_path` and everything under it. `deleteTree` is a Dir method
/// with no absolute-path variant, so this splits off the parent and deletes
/// the final component by name.
fn deleteTreeAbsolute(io: std.Io, abs_path: []const u8) void {
    const base = std.fs.path.basename(abs_path);
    const parent = std.fs.path.dirname(abs_path) orelse return;
    if (base.len == 0) return;
    var d = std.Io.Dir.openDirAbsolute(io, parent, .{}) catch return;
    defer d.close(io);
    d.deleteTree(io, base) catch {};
}

/// One resolved config file paired with the path it takes inside the snapshot.
const SnapFile = struct { rel: []const u8 };

/// `path` relative to `root`, or null when it does not live under it. An
/// `include` may point outside the config dir (`../shared.toml`), and such a
/// file is deliberately not snapshotted: the tree walk this replaced never
/// copied it either, so the successor resolves it the same way the original
/// load did.
fn relativeTo(allocator: std.mem.Allocator, root: []const u8, path: []const u8) !?[]const u8 {
    if (!std.mem.startsWith(u8, path, root)) return null;
    var rel = path[root.len..];
    while (rel.len != 0 and std.fs.path.isSep(rel[0])) rel = rel[1..];
    if (rel.len == 0) return null;
    return try allocator.dupe(u8, rel);
}

/// True when the snapshot already holds exactly `files` and the source files
/// are untouched since the last successful refresh -- the no-op-reload fast
/// path, so a reload that changes nothing does no writes at all. Contents are
/// compared as an exact set (not just presence), so a source that was RENAMED
/// cannot leave its old name behind in the snapshot for the successor to load
/// as a config file the user deleted.
fn snapshotCurrent(
    io: std.Io,
    allocator: std.mem.Allocator,
    snap: []const u8,
    files: []const SnapFile,
    prev: ?[]const FileStamp,
    now: []const FileStamp,
) bool {
    const old = prev orelse return false;
    if (old.len != now.len or files.len != now.len) return false;
    for (old, now) |a, b| {
        if (a.size != b.size or a.mtime != b.mtime) return false;
    }
    var d = std.Io.Dir.openDirAbsolute(io, snap, .{ .iterate = true }) catch return false;
    defer d.close(io);
    var w = d.walk(allocator) catch return false;
    defer w.deinit();
    var seen: std.ArrayList([]const u8) = .empty;
    while (w.next(io) catch return false) |entry| {
        if (entry.kind == .directory) continue;
        seen.append(allocator, entry.path) catch return false;
    }
    if (seen.items.len != files.len) return false;
    for (files) |f| {
        var found = false;
        for (seen.items) |s| {
            if (std.mem.eql(u8, s, f.rel)) {
                found = true;
                break;
            }
        }
        if (!found) return false;
    }
    return true;
}

/// Freezes the last-good config's resolved file set into the snapshot dir, so
/// a re-exec boots an identical config without re-reading the live config tree.
/// Only the files the load actually consumed are copied (see `GoodSource.files`
/// for why the whole tree is not), and the new snapshot is assembled beside the
/// old one and swapped in, so a copy that fails part-way leaves the previous
/// snapshot intact. Best-effort: a failed refresh keeps the previous snapshot,
/// still self-consistent.
pub fn refreshSnapshot(allocator: std.mem.Allocator) void {
    const g = last_good_source orelse return;
    const io = std.Options.debug_io;
    const snap = snapshotDirPath(allocator) catch return;
    defer allocator.free(snap);
    // A re-exec boot whose own source IS the snapshot has nothing to copy.
    if (std.mem.eql(u8, g.path, snap)) return;
    if (g.files.len == 0) return;

    // Scratch for the resolved-to-snapshot path mapping; outlives no call here.
    var scratch = std.heap.ArenaAllocator.init(allocator);
    defer scratch.deinit();
    const sa = scratch.allocator();

    // Snapshot destinations are relative to the source ROOT: for a directory
    // source that is the config dir itself, for a single-file source the file's
    // own directory -- so the file lands as `config.toml` and its includes keep
    // the subdirectory the loader will resolve them against.
    const root = if (g.is_dir) g.path else (std.fs.path.dirname(g.path) orelse ".");
    var files: std.ArrayList(SnapFile) = .empty;
    for (g.files) |f| {
        const rel = (relativeTo(sa, root, f) catch return) orelse {
            log.warn("Snapshot: '{s}' is outside '{s}'; not freezing it", .{ f, root });
            continue;
        };
        files.append(sa, .{ .rel = rel }) catch return;
    }
    if (files.items.len == 0) return;

    const src = std.Io.Dir.openDirAbsolute(io, root, .{ .iterate = true }) catch return;
    defer src.close(io);

    const stamps = allocator.alloc(FileStamp, files.items.len) catch return;
    defer allocator.free(stamps);
    for (files.items, 0..) |f, i| {
        const st = src.statFile(io, f.rel, .{}) catch return;
        stamps[i] = .{ .size = st.size, .mtime = st.mtime.nanoseconds };
    }
    if (snapshotCurrent(io, sa, snap, files.items, g.stamps, stamps)) return;

    const staging = std.fmt.allocPrint(sa, "{s}.new", .{snap}) catch return;
    deleteTreeAbsolute(io, staging);
    if (!writeSnapshot(io, src, snap, staging, files.items)) {
        deleteTreeAbsolute(io, staging);
        return;
    }
    deleteTreeAbsolute(io, snap);
    std.Io.Dir.renameAbsolute(staging, snap, io) catch {
        deleteTreeAbsolute(io, staging);
        return;
    };

    // Remember what was frozen so the next unchanged reload can skip all of it.
    const kept = allocator.dupe(FileStamp, stamps) catch return;
    if (last_good_source) |cur| {
        if (cur.stamps) |old| allocator.free(old);
    }
    last_good_source.?.stamps = kept;
}

/// Assembles the complete snapshot under `staging`. Returns false (leaving
/// `staging` to the caller to remove) if any file fails to copy, so a partial
/// snapshot is never swapped into place.
fn writeSnapshot(
    io: std.Io,
    src: std.Io.Dir,
    snap: []const u8,
    staging: []const u8,
    files: []const SnapFile,
) bool {
    _ = snap;
    std.Io.Dir.createDirAbsolute(io, staging, .default_dir) catch return false;
    var dest = std.Io.Dir.openDirAbsolute(io, staging, .{ .iterate = true }) catch return false;
    defer dest.close(io);
    for (files) |f| {
        // make_path for the entry's parents is implied by an include's
        // `themes/...` subdirectory.
        std.Io.Dir.copyFile(src, f.rel, dest, f.rel, io, .{ .make_path = true, .replace = true }) catch return false;
    }
    return true;
}
