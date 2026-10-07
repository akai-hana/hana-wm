//! Config file discovery: the ceiling-bounded read/merge machinery
//! (per-file read with growth, parse, arena merge, `include` joining
//! one level deep), the config-dir walk, and the user-config search
//! order. Everything here answers "which files make up this load, and
//! what did they merge into" -- turning paths into an arena-backed
//! TOML document; the orchestrator (config.zig) turns that document
//! into a Config.

const std = @import("std");
const log = @import("log");
const paths_mod = @import("paths");
const parser = @import("parser");
const types = @import("types");

pub const max_file_bytes = 1024 * 1024;

/// Ceilings for ONE config load. `max_file_bytes` bounds a single file, which
/// on its own leaves the load itself unbounded: a config dir holding thousands
/// of small files, or an `include` list naming the same file a few thousand
/// times, all stay under the per-file cap and still cost thousands of reads,
/// parses and arena merges before boot finishes. These two bound the load as a
/// whole.
///
/// Exceeding either fails the load (`TooManyConfigFiles` / `TooManyConfigBytes`)
/// rather than warning and skipping: silently dropping config files yields a
/// config that is subtly NOT the user's, which is the failure mode this module
/// spends the most comments defending against. Both bounds sit far above any
/// real config (the reference set is 6 files, ~30KB).
pub const max_config_files = 128;
pub const max_total_config_bytes = 8 * 1024 * 1024;

/// The files one load consumed, in merge order, plus their running byte total.
/// The list is what the re-exec snapshot freezes; the total is the half of the
/// load ceiling that a file COUNT cannot express. Both counters move in one
/// place (`parseAndMerge`), the single choke point every read passes through, so
/// a new file-reading path cannot forget to check them.
pub const ReadSet = struct {
    paths: std.ArrayList([]const u8) = .empty,
    bytes: usize = 0,
};

/// Initial allocation for the read-with-growth path (stat failed or reported
/// zero, e.g. procfs/sysfs/pipes). Doubles until the whole file is read.
const read_growth_initial_bytes = 64 * 1024;

/// Reads `path`, returning `error.FileTooLarge` when it exceeds
/// `max_file_bytes`. The returned slice may alias a larger allocation (loading
/// is arena-backed, so all ownership is released together by the arena reset).
/// Growth-path rationale sits inline below.
pub fn readFileAlloc(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const io = std.Options.debug_io;
    const file = std.Io.Dir.openFileAbsolute(io, path, .{}) catch |err| {
        if (err == error.FileNotFound) log.info("Not found: {s}", .{path});
        return err;
    };
    defer file.close(io);
    // A successful stat reporting size 0 is as untrustworthy as a failed one:
    // procfs/sysfs/pipes report 0 while carrying content, so they take the
    // same read-with-growth path (pinned by config_test).
    const stat: ?std.Io.File.Stat = file.stat(io) catch null;
    const known_size: usize = if (stat) |st| size: {
        if (st.size > max_file_bytes) return error.FileTooLarge;
        if (st.size == 0) break :size 0;
        break :size @intCast(st.size);
    } else 0;

    const initial: usize = if (known_size > 0) known_size else read_growth_initial_bytes;
    // Single ownership throughout: the armed errdefer frees the whole buffer
    // exactly once on every error path, and the success path hands ownership
    // (possibly after a shrinking realloc) to the caller.
    var buf = try allocator.alloc(u8, initial);
    errdefer allocator.free(buf);
    var total: usize = 0;
    while (true) {
        if (total == buf.len) {
            if (buf.len > max_file_bytes) return error.FileTooLarge;
            buf = try allocator.realloc(buf, buf.len * 2);
        }
        const n = try file.readPositionalAll(io, buf[total..], total);
        if (n == 0) break; // EOF
        total += n;
    }
    if (total > max_file_bytes) return error.FileTooLarge;
    if (total == buf.len) return buf;
    // Hand the caller an owned buffer of the exact size (the growth buffer was
    // oversized); shrinking via realloc transfers ownership instead of leaking
    // a subslice the caller would double-free.
    return allocator.realloc(buf, total);
}

/// Reads and parses the .toml at `path`, returning null for an empty file.
/// Read/parse errors propagate to the caller, who decides how to handle them.
/// `allocator` must be arena-backed: the file buffer and the parsed Document
/// alias it, released together by the caller's load-scoped arena reset.
pub fn parseTomlFile(allocator: std.mem.Allocator, path: []const u8) !?ParsedToml {
    const raw = try readFileAlloc(allocator, path);
    if (raw.len == 0) return null;
    // `raw.len`, not a stat: it is the count of bytes actually READ, so the load
    // ceiling cannot be evaded by a file whose stat lies (the growth path
    // already covers a stat that reports 0 or fails outright).
    return .{ .doc = try parser.parse(allocator, raw, path), .bytes = raw.len };
}

/// A parsed file plus the number of bytes it came from.
pub const ParsedToml = struct { doc: parser.Document, bytes: usize };

/// warn-and-skip wrapper around parseTomlFile, the "never crash on bad
/// config" path shared by the directory loader and `include` resolution.
/// On read or parse failure, marks the destination merged document's
/// `had_errors` so the caller can propagate error.ConfigParseFailed.
/// An empty file returns null without setting `had_errors`.
fn tryParseTomlFile(
    allocator: std.mem.Allocator,
    path: []const u8,
    dst: *parser.Document,
) ?ParsedToml {
    const parsed = parseTomlFile(allocator, path) catch |err| {
        dst.had_errors = true;
        log.warn("Skipping '{s}': {}", .{ path, err });
        return null;
    };
    if (parsed == null) log.info("Skipping empty file: {s}", .{path});
    return parsed;
}

/// Parses and merges one config file (path = `dir_path` + `name`) into `dst`,
/// then resolves its own `include`s via mergeIncludes.
fn mergeOneFile(
    allocator: std.mem.Allocator,
    dst: *parser.Document,
    read: *ReadSet,
    dir_path: []const u8,
    name: []const u8,
) !void {
    const path = try std.fs.path.join(allocator, &.{ dir_path, name });
    var doc = (try parseAndMerge(allocator, dst, read, path, "Merged: {s}")) orelse return;
    try mergeIncludes(allocator, dst, &doc, read, dir_path);
}

/// Parse-merge-log tail shared by mergeOneFile and mergeIncludes. A file that
/// parses and merges is appended to `read`, which is how the re-exec snapshot
/// learns what the load actually consumed; a file that fails returns before
/// recording, so `read` ends up holding exactly the files that contributed.
fn parseAndMerge(
    allocator: std.mem.Allocator,
    dst: *parser.Document,
    read: *ReadSet,
    path: []const u8,
    comptime msg: []const u8,
) !?parser.Document {
    // Ceilings first, so a tree over the limit costs a counter check rather
    // than the read it was about to do.
    if (read.paths.items.len >= max_config_files) {
        log.err("Config load reads more than {d} files (at '{s}'); refusing to continue. " ++
            "A config dir or include list that large is almost certainly not a config.", .{ max_config_files, path });
        return error.TooManyConfigFiles;
    }
    const doc = tryParseTomlFile(allocator, path, dst) orelse return null;
    if (read.bytes + doc.bytes > max_total_config_bytes) {
        log.err("Config load exceeds {d}KB across all files (at '{s}'); refusing to continue. " ++
            "Split the config, or raise max_total_config_bytes.", .{ max_total_config_bytes / 1024, path });
        return error.TooManyConfigBytes;
    }
    read.bytes += doc.bytes;
    var owned = doc.doc;
    try parser.mergeDocumentsInto(allocator, dst, &owned);
    log.info(msg, .{path});
    try read.paths.append(allocator, path);
    return owned;
}

/// Merges files listed in `include = [...]` from `src_doc` into `dst`;
/// `dir_path` is the base for relative paths. Includes resolve one level deep
/// only: an included file's own `include` is skipped, keeping the graph
/// cycle-free by construction (no cycle-detection machinery) at the cost of
/// no chained includes. `allocator` is the load's arena allocator.
pub fn mergeIncludes(
    allocator: std.mem.Allocator,
    dst: *parser.Document,
    src_doc: *parser.Document,
    read: *ReadSet,
    dir_path: []const u8,
) !void {
    // `src_doc` and `dst` are the SAME document on the parseFileDoc path, and
    // that is the intent: each included file is merged into the document whose
    // `include` list we are walking. It is safe because the arena never moves
    // an existing allocation, so the `includes` slice below stays valid while
    // the loop merges into it.
    //
    // The `include` key is copied into `dst` by mergeDocumentsInto, so mark it
    // consumed there as well: otherwise warnUnconsumed would flag it as a typo.
    dst.root.markConsumed("include");
    const inc_val = src_doc.root.get("include") orelse return;
    const includes = inc_val.asArray() orelse return;
    for (includes) |item| {
        const rel = item.asScalar([]const u8) orelse continue;
        if (!std.mem.endsWith(u8, rel, ".toml")) {
            log.warn("include '{s}': path must end in .toml; skipping", .{rel});
            continue;
        }
        const abs = try std.fs.path.join(allocator, &.{ dir_path, rel });
        var inc_doc = (try parseAndMerge(allocator, dst, read, abs, "Merged (include): {s}")) orelse continue;
        if (inc_doc.root.get("include")) |_| {
            log.warn("{s}: nested 'include' inside an included file is not " ++ "supported; its include list is skipped", .{abs});
        }
    }
}

fn sliceLessThan(_: void, a: []u8, b: []u8) bool {
    return std.mem.lessThan(u8, a, b);
}

/// Collects the `*.toml` files directly inside `dir_path` (alphabetical
/// order; subdirectories only via explicit `include`), excluding the
/// embedded `fallback.toml`. The caller owns the returned list and its
/// strings.
pub fn discoverDirNames(allocator: std.mem.Allocator, dir_path: []const u8) !std.ArrayList([]u8) {
    var names: std.ArrayList([]u8) = .empty;
    errdefer {
        for (names.items) |n| allocator.free(n);
        names.deinit(allocator);
    }
    {
        const io = std.Options.debug_io;
        var dir = std.Io.Dir.openDirAbsolute(io, dir_path, .{ .iterate = true }) catch |err| {
            if (err == error.FileNotFound or err == error.NotDir)
                log.info("Config dir not found: {s}", .{dir_path});
            return err;
        };
        defer dir.close(io);
        var it = dir.iterate();
        while (try it.next(io)) |entry| {
            if (entry.kind == .directory) continue;
            if (!std.mem.endsWith(u8, entry.name, ".toml")) continue;
            if (std.mem.eql(u8, entry.name, "fallback.toml")) continue;
            try names.append(allocator, try allocator.dupe(u8, entry.name));
        }
    }
    if (names.items.len == 0) {
        log.info("No .toml files in config dir: {s}", .{dir_path});
        return error.FileNotFound;
    }
    std.mem.sort([]u8, names.items, {}, sliceLessThan);
    return names;
}

/// Merge inputs for `parseDirDoc`: a sorted file list plus the directory they
/// live in, for `mergeOneFile`'s path join.
pub const DirInput = struct { dir_path: []const u8, names: []const []u8 };

/// Merges every file named in `in.names` (directory-loading order) into one
/// arena document, recording each consumed file in `read`.
pub fn parseDirDoc(a: std.mem.Allocator, read: *ReadSet, in: DirInput) !parser.Document {
    var merged = parser.Document.init(a);
    for (in.names) |name| try mergeOneFile(a, &merged, read, in.dir_path, name);
    return merged;
}

/// Errors that mean "nothing to load HERE", so the search moves on without a
/// warning. One list for the search: the previous spelling had the dir loop and
/// the file loop pass their own inline set each, so the two could drift without
/// anything noticing, and a typo'd entry is a warning that never fires.
/// (NotDir is inert for a single-file path, which is why one set fits both.)
///
/// The pinned-snapshot branch in `loadConfigDefault` keeps its own switch on
/// purpose: there a parse failure is ALSO non-fatal -- a broken snapshot must
/// not swap the embedded fallback over an otherwise-fine user config -- which
/// is the opposite of the search, where a parse failure must reach the caller.
const silent_missing = [_]anyerror{ error.FileNotFound, error.NotDir };

/// Load failures that mean "this config cannot be used", as opposed to "there
/// is nothing here". All of them are handled identically at both ends: `load`
/// (boot) falls back to the embedded config, and the reload path lets them
/// propagate so the live config is kept. The set is named so the search's
/// hard-fail list and boot's fallback list cannot drift apart -- they are the
/// same policy, spelled twice, and the ceilings (15.12) joined both.
fn isFatalLoadError(err: anyerror) bool {
    return switch (err) {
        error.ConfigParseFailed, error.TooManyConfigFiles, error.TooManyConfigBytes => true,
        else => false,
    };
}

pub fn tryLoadOrWarn(
    loader: LoadFn,
    allocator: std.mem.Allocator,
    path: []const u8,
    comptime err_msg: []const u8,
) !?types.Config {
    return loader(allocator, path) catch |err| {
        // A parse error must reach the caller. On reload it makes the
        // swap fail so the live config is kept (see reload.handleConfigReload);
        // at boot `load` catches it and falls back to the embedded config.
        // Swallowing it here is what silently installed the fallback over a
        // user's typo'd config.
        if (isFatalLoadError(err)) return err;
        for (silent_missing[0..]) |e| if (err == e) return null;
        log.warn(err_msg, .{ path, err });
        return null;
    };
}

/// The directory and single-file locations searched for a user config, in
/// priority order. Single source of truth shared by the loader
/// (loadConfigDefault) so the search order cannot drift; loadConfigDefault also
/// reports which source supplied the config, so the reload path needs no
/// separate existence probe.
pub const SearchPaths = struct {
    xdg_dir: []u8,
    local_dir: []u8,
    xdg_file: []u8,
    local_file: []u8,

    pub fn deinit(self: SearchPaths, allocator: std.mem.Allocator) void {
        allocator.free(self.xdg_dir);
        allocator.free(self.local_dir);
        allocator.free(self.xdg_file);
        allocator.free(self.local_file);
    }
};

/// The shape every search location's loader has: both the dir loader and the
/// single-file loader take exactly (allocator, path).
pub const LoadFn = *const fn (std.mem.Allocator, []const u8) anyerror!types.Config;

/// The user-config search order, declared ONCE. Adding a location (a second
/// per-user dir, a system-wide `/etc/hana`) is a new enum tag plus one line in
/// `loadConfigDefault`'s switch; the priority order, the loader, the
/// "nothing here" error set and the warn wording are all decided by the tag
/// rather than by the order the loops happen to be written in.
pub const search_order = [_]SearchLoc{
    .xdg_dir,
    .local_dir,
    .xdg_file,
    .local_file,
};

pub const SearchLoc = enum { xdg_dir, local_dir, xdg_file, local_file };

/// One resolved search location: where to look, how to read it, and whether
/// the source is a directory (which the re-exec snapshot records). Built per
/// tag inside `loadConfigDefault`; the failure wording comes from the tag too.
pub const SearchAttempt = struct {
    path: []const u8,
    load: LoadFn,
    is_dir: bool,
};

pub fn searchPaths(allocator: std.mem.Allocator) !SearchPaths {
    // An unset or empty HOME used to be taken as "/" with no word to the user,
    // so the search silently became `/.config/hana` and then `./config/` -- a
    // WM that came up with a different config than every other launch, with
    // nothing on stderr to say so. Name the substitution instead.
    const home: []const u8 = if (std.c.getenv("HOME")) |h| blk: {
        const s = std.mem.span(h);
        break :blk if (s.len == 0) "/" else s;
    } else blk: {
        log.warn("HOME is unset; the config search falls back to /.config/hana and ./config", .{});
        break :blk "/";
    };
    const xdg_config_home: ?[]const u8 = if (std.c.getenv("XDG_CONFIG_HOME")) |ch| blk: {
        const s = std.mem.span(ch);
        // Empty means unset (XDG spec) -- see paths.configHome. Passing it on
        // as-is would make the config dir relative to the cwd.
        break :blk if (s.len == 0) null else s;
    } else null;
    var ch_buf: [std.fs.max_path_bytes]u8 = undefined;
    const config_home = try paths_mod.configHome(&ch_buf, xdg_config_home, home);
    // Joined through a stack buffer and duped once: `fs.path.join` allocates its
    // result in the arena, and this is an intermediate (the owned copy below is
    // what SearchPaths returns), so an arena-allocated join would be freed only
    // by the arena reset -- a leak the load-scoped-arena tests correctly catch.
    var xdg_buf: [std.fs.max_path_bytes]u8 = undefined;
    const xdg_dir = try allocator.dupe(u8, try std.fmt.bufPrint(&xdg_buf, "{s}/hana", .{config_home}));
    errdefer allocator.free(xdg_dir);

    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    _ = std.c.getcwd(&cwd_buf, cwd_buf.len) orelse return error.CurrentWorkingDirectoryUnlinked;
    const cwd = std.mem.sliceTo(&cwd_buf, 0);
    const local_dir = try std.fs.path.join(allocator, &.{ cwd, "config" });
    errdefer allocator.free(local_dir);

    const xdg_file = try std.fs.path.join(allocator, &.{ xdg_dir, "config.toml" });
    errdefer allocator.free(xdg_file);
    const local_file = try std.fs.path.join(allocator, &.{ cwd, "config.toml" });
    return .{
        .xdg_dir = xdg_dir,
        .local_dir = local_dir,
        .xdg_file = xdg_file,
        .local_file = local_file,
    };
}
