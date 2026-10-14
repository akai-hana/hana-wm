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
const paths = @import("paths");

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

/// The winning user config source of a load: its location plus the files it
/// read, recorded at the end of a winning load so the snapshot can freeze
/// exactly what the successor should boot from.
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
    /// every boot. Each entry carries its own size/mtime stamp (null when the
    /// snapshot is not known to mirror the source): the stamp rides beside
    /// the path it describes, so there is no second slice to keep
    /// index-for-index in step and no ownership transfer across a no-op
    /// reload.
    files: []SourceFile,
};

/// One resolved config file: its identity (path, owned) plus the size/mtime
/// captured at the last successful refresh, or null when the snapshot is not
/// known to mirror the source. An unchanged reload compares these and writes
/// nothing at all. Stamps are set together -- a fresh record starts null and
/// `refreshSnapshot` stamps every entry after a successful freeze -- so the
/// per-entry optional never carries a partial state in practice.
const SourceFile = struct {
    path: []u8,
    stamp: ?FileStamp = null,
};

/// One resolved config file's identity, captured when it is snapshotted.
const FileStamp = struct { size: u64, mtime: i96 };

/// The config files the most recent successful load consumed, in merge order,
/// paired with the arena that owns their bytes. Module-level because the set
/// must outlive the load-scoped parse arena (it is consumed at snapshot time,
/// after the load has returned), and because discarding it wholesale is then
/// one arena reset instead of per-path free bookkeeping. `publishReadFiles`
/// installs a FRESH pair per load and frees the previous one, so a set is
/// never released by a different load's allocator and the two halves can
/// never move out of step. Read (never owned) by `rememberGoodSource` at the end
/// of a winning load.
var read_files: ?struct {
    arena: std.heap.ArenaAllocator,
    paths: []const []const u8,
} = null;

/// Publishes this load's resolved file set, releasing the previous load's.
pub fn publishReadFiles(items: []const []const u8) !void {
    if (read_files) |*rf| rf.arena.deinit();
    read_files = null;
    var fresh: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    errdefer fresh.deinit();
    const a = fresh.allocator();
    var out: std.ArrayList([]const u8) = .empty;
    try out.ensureTotalCapacity(a, items.len);
    // Copy the bytes, not just the slice headers: `items` aliases the
    // load-scoped parse arena, which the caller resets as soon as this load
    // returns, long before refreshSnapshot reads the set.
    for (items) |p| try out.append(a, try a.dupe(u8, p));
    read_files = .{ .arena = fresh, .paths = out.items };
}

/// Dupe `items` into a freshly allocated `SourceFile` list owned by
/// `allocator`; released with `freeSourceFiles`. An empty input yields a
/// zero-length slice, which `freeSourceFiles` releases as a no-op. Stamps
/// start null: a fresh record is not known to mirror any prior snapshot.
fn dupeSourceFiles(allocator: std.mem.Allocator, items: []const []const u8) ![]SourceFile {
    const out = try allocator.alloc(SourceFile, items.len);
    errdefer allocator.free(out);
    for (items, 0..) |item, i| {
        out[i] = .{
            .path = allocator.dupe(u8, item) catch |err| {
                for (out[0..i]) |done| allocator.free(done.path);
                return err;
            },
        };
    }
    return out;
}

fn freeSourceFiles(allocator: std.mem.Allocator, files: []SourceFile) void {
    for (files) |f| allocator.free(f.path);
    allocator.free(files);
}

/// The most recently loaded-and-validated user config location. Mutated by
/// every successful load/reload; read by refreshSnapshot at re-exec time.
/// Allocated with the caller's (c_allocator) arena semantics, process-lifetime
/// after the winning load holds it.
var last_good_source: ?GoodSource = null;

/// True when two resolved file lists name the same files in the same order.
/// The lists are merge-ordered, so a positional compare is exact.
fn sameSourceList(a: []const SourceFile, b: []const SourceFile) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (!std.mem.eql(u8, x.path, y.path)) return false;
    }
    return true;
}

pub fn rememberGoodSource(allocator: std.mem.Allocator, path: []const u8, is_dir: bool) void {
    // OOM is silent: the snapshot just keeps the previous good source.
    const duped = allocator.dupe(u8, path) catch return;
    const files = dupeSourceFiles(allocator, if (read_files) |*rf| rf.paths else &.{}) catch {
        allocator.free(duped);
        return;
    };
    if (last_good_source) |g| {
        // Carry the stamps over when this load resolved the very same source
        // to the very same files. That is what lets a no-op reload take the
        // "nothing changed" fast path instead of re-freezing the snapshot on
        // every SIGHUP. The stamps live ON each new entry, so carrying them
        // is a per-entry copy against an identical list -- index-for-index
        // correct by construction, with no second slice to own.
        const same = g.is_dir == is_dir and std.mem.eql(u8, g.path, path) and sameSourceList(g.files, files);
        if (same) {
            for (files, g.files) |*nf, of| nf.stamp = of.stamp;
        }
        // The freshly duped path/files supersede the old record either way.
        allocator.free(g.path);
        freeSourceFiles(allocator, g.files);
    }
    last_good_source = .{ .path = duped, .is_dir = is_dir, .files = files };
}

/// Releases the good-source state. In a running hana this lives for the whole
/// process in a long-lived arena and is only ever replaced, never torn down;
/// tests call this so the DebugAllocator can account for every byte.
pub fn deinitGoodSource(allocator: std.mem.Allocator) void {
    if (last_good_source) |g| {
        allocator.free(g.path);
        freeSourceFiles(allocator, g.files);
    }
    last_good_source = null;
}

/// Snapshot dir a re-exec boots from; the shared XDG-/tmp-uid policy lives
/// in paths.runtimeFile. Caller owns the returned slice.
fn snapshotDirPath(allocator: std.mem.Allocator) ![]u8 {
    return paths.runtimeFile(allocator, "hana-config", "");
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

/// One resolved config file paired with the path it takes inside the snapshot
/// and the stat taken when the freeze reached it. AoS so the stamp travels
/// with the entry it describes -- no parallel arrays to keep index-for-index
/// in step.
const SnapFile = struct { rel: []const u8, stamp: FileStamp };

/// `path` relative to `root`, or null when it does not live under it. An
/// `include` may point outside the config dir (`../shared.toml`), and such a
/// file is deliberately not snapshotted, so the successor resolves it the
/// same way the original load did.
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
    prev: []const SourceFile,
) bool {
    if (prev.len != files.len) return false;
    for (prev, files) |p, f| {
        // Null stamp: the snapshot is not known to mirror this record.
        const a = p.stamp orelse return false;
        if (a.size != f.stamp.size or a.mtime != f.stamp.mtime) return false;
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
        const rel = (relativeTo(sa, root, f.path) catch return) orelse {
            log.warn("Snapshot: '{s}' is outside '{s}'; not freezing it", .{ f.path, root });
            continue;
        };
        files.append(sa, .{ .rel = rel, .stamp = undefined }) catch return;
    }
    if (files.items.len == 0) return;

    const src = std.Io.Dir.openDirAbsolute(io, root, .{ .iterate = true }) catch return;
    defer src.close(io);

    for (files.items) |*f| {
        const st = src.statFile(io, f.rel, .{}) catch return;
        f.stamp = .{ .size = st.size, .mtime = st.mtime.nanoseconds };
    }
    if (snapshotCurrent(io, sa, snap, files.items, g.files)) return;

    const staging = std.fmt.allocPrint(sa, "{s}.new", .{snap}) catch return;
    deleteTreeAbsolute(io, staging);
    if (!writeSnapshot(io, src, staging, files.items)) {
        deleteTreeAbsolute(io, staging);
        return;
    }
    deleteTreeAbsolute(io, snap);
    std.Io.Dir.renameAbsolute(staging, snap, io) catch {
        deleteTreeAbsolute(io, staging);
        return;
    };

    // Remember what was frozen so the next unchanged reload can skip all of
    // it. `g.files` shares its backing with `last_good_source`, so stamping
    // through it records the freeze without a second allocation.
    for (g.files, files.items) |*sf, f| sf.stamp = f.stamp;
}

/// Assembles the complete snapshot under `staging`. Returns false (leaving
/// `staging` to the caller to remove) if any file fails to copy, so a partial
/// snapshot is never swapped into place.
fn writeSnapshot(
    io: std.Io,
    src: std.Io.Dir,
    staging: []const u8,
    files: []const SnapFile,
) bool {
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
