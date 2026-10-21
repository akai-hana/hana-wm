//! Config file discovery: ceiling-bounded read/merge (`include` joining one
//! level deep), the config-dir walk, and the user-config search order.
//! A config dir contributes exactly ONE file (`entry_file`) plus its
//! `include`s; other top-level `.toml` files are inert, never merged.

const std = @import("std");
const log = std.log.scoped(.discover);
const parser = @import("parser");
const composed = @import("composed");

pub const max_file_bytes = 1024 * 1024;

/// Ceilings for ONE config load. `max_file_bytes` bounds a single file; these
/// two bound the load as a whole (thousands of small files / include names all
/// stay under the per-file cap). Exceeding either FAILS the load rather than
/// warning and skipping: silently dropping config files yields a config that
/// is subtly NOT the user's. Both bounds sit far above any real config.
pub const max_config_files = 128;
const max_total_config_bytes = 8 * 1024 * 1024;

/// The files one load consumed, in merge order, plus their running byte total.
/// Both counters move in one place (`mergeAndRecord`), the choke point every
/// read passes through, so a new file-reading path cannot forget to check them.
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
pub fn readFileAlloc(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const io = std.Options.debug_io;
    const file = std.Io.Dir.openFileAbsolute(io, path, .{}) catch |err| {
        if (err == error.FileNotFound) log.info("Not found: {s}", .{path});
        return err;
    };
    defer file.close(io);
    // A successful stat reporting size 0 is as untrustworthy as a failed one:
    // procfs/sysfs/pipes report 0 while carrying content, so they take the
    // same read-with-growth path.
    const stat: ?std.Io.File.Stat = file.stat(io) catch null;
    const known_size: usize = if (stat) |st| size: {
        if (st.size > max_file_bytes) return error.FileTooLarge;
        if (st.size == 0) break :size 0;
        break :size @intCast(st.size);
    } else 0;

    const initial: usize = if (known_size > 0) known_size else read_growth_initial_bytes;
    // Single ownership throughout: the armed errdefer frees the whole buffer
    // exactly once on every error path.
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
    // Hand the caller an owned buffer of the exact size; shrinking via realloc
    // transfers ownership instead of leaking a subslice the caller would
    // double-free.
    return allocator.realloc(buf, total);
}

/// Reads and parses the .toml at `path`, returning null for an empty file.
/// `allocator` must be arena-backed: the file buffer and the parsed Document
/// alias it, released together by the caller's load-scoped arena reset.
pub fn parseTomlFile(allocator: std.mem.Allocator, path: []const u8) !?ParsedToml {
    const raw = try readFileAlloc(allocator, path);
    if (raw.len == 0) return null;
    // `raw.len`, not a stat: the count of bytes actually READ, so the load
    // ceiling cannot be evaded by a file whose stat lies.
    return .{ .doc = try parser.parse(allocator, raw, path), .bytes = raw.len };
}

/// A parsed file plus the number of bytes it came from.
pub const ParsedToml = struct { doc: parser.Document, bytes: usize };

/// warn-and-skip wrapper around parseTomlFile, the "never crash on bad
/// config" path `include` resolution takes. An entry file or a single-file
/// location deliberately does NOT: there a read failure must propagate raw
/// (see config.parseFileDoc). Failure marks the destination `had_errors`.
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

/// The ReadSet choke point: byte ceiling, tally, merge into `dst`, log and
/// path record. Every contributing file passes through here. A file that
/// fails before reaching this is not recorded, so `read` holds exactly the
/// files that contributed.
pub fn mergeAndRecord(
    allocator: std.mem.Allocator,
    dst: *parser.Document,
    read: *ReadSet,
    doc: *const parser.Document,
    bytes: usize,
    path: []const u8,
    comptime msg: []const u8,
) !void {
    if (read.bytes + bytes > max_total_config_bytes) {
        log.err("Config load exceeds {d}KB across all files (at '{s}'); refusing to continue. " ++
            "Split the config, or raise max_total_config_bytes.", .{ max_total_config_bytes / 1024, path });
        return error.TooManyConfigBytes;
    }
    read.bytes += bytes;
    try parser.mergeDocumentsInto(allocator, dst, doc);
    log.info(msg, .{path});
    try read.paths.append(allocator, path);
}

/// Read-merge-log path `include` resolution takes: refuse an over-limit tree
/// BEFORE the read it was about to do, then read (skipping a broken file with
/// `had_errors` set) and hand bookkeeping to mergeAndRecord.
fn parseAndMerge(
    allocator: std.mem.Allocator,
    dst: *parser.Document,
    read: *ReadSet,
    path: []const u8,
    comptime msg: []const u8,
) !?parser.Document {
    // Ceiling first, so a tree over the limit costs a counter check rather
    // than the read it was about to do.
    if (read.paths.items.len >= max_config_files) {
        log.err("Config load reads more than {d} files (at '{s}'); refusing to continue. " ++
            "A config dir or include list that large is almost certainly not a config.", .{ max_config_files, path });
        return error.TooManyConfigFiles;
    }
    const parsed = tryParseTomlFile(allocator, path, dst) orelse return null;
    const owned = parsed.doc;
    try mergeAndRecord(allocator, dst, read, &owned, parsed.bytes, path, msg);
    return owned;
}

/// Merges files listed in `include = [...]` from `src_doc` into `dst`;
/// `dir_path` is the base for relative paths. Includes resolve one level deep
/// only: an included file's own `include` is skipped, keeping the graph
/// cycle-free by construction (no cycle-detection machinery).
pub fn mergeIncludes(
    allocator: std.mem.Allocator,
    dst: *parser.Document,
    src_doc: *parser.Document,
    read: *ReadSet,
    dir_path: []const u8,
) !void {
    // Each included file is merged into `dst` while we walk `src_doc`'s
    // `include` list; the arena never moves an existing allocation, so the
    // `includes` slice stays valid. The `include` key is copied into `dst` by
    // mergeDocumentsInto, so mark it consumed there too (warnUnconsumed
    // would otherwise flag it as a typo).
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
/// embedded `fallback.toml`. The caller owns the returned list and strings.
/// Does NOT decide what loads -- that is `entry_file` plus its `include`s --
/// it is the inventory the two reports below are written against.
fn discoverDirNames(allocator: std.mem.Allocator, dir_path: []const u8) !std.ArrayList([]u8) {
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
    std.sort.heap([]u8, names.items, {}, sliceLessThan);
    return names;
}

/// The one file a config directory auto-loads, relative to the directory
/// root. Everything else is inert until this file names it in `include`.
/// Also the name the single-file search locations resolve, so "the entry
/// file" is spelled once for both branches.
pub const entry_file = "config.toml";

/// Reports every top-level `*.toml` in `dir_path` the load did NOT consume.
/// A dropped-in file is inert until an `include` names it -- and an inert
/// file the user meant to be live is the silent-drop failure this module's
/// ceilings exist to prevent. Membership is checked against `read` (what was
/// actually read), so a named-but-broken file is reported beside its own
/// parse warning. Intended for the load's arena allocator.
pub fn warnInertSiblings(allocator: std.mem.Allocator, dir_path: []const u8, read: *const ReadSet) void {
    var names = discoverDirNames(allocator, dir_path) catch return;
    defer {
        for (names.items) |n| allocator.free(n);
        names.deinit(allocator);
    }
    for (names.items) |name| {
        if (std.mem.eql(u8, name, entry_file)) continue;
        const abs = std.fs.path.join(allocator, &.{ dir_path, name }) catch continue;
        defer allocator.free(abs);
        var consumed = false;
        for (read.paths.items) |p| {
            if (std.mem.eql(u8, p, abs)) {
                consumed = true;
                break;
            }
        }
        if (consumed) continue;
        log.warn("'{s}' is not loaded; add it to {s}'s include list", .{ abs, entry_file });
    }
}

/// Reports a config dir that holds `.toml` files but no `entry_file`: the
/// search skips such a directory, and skipping it SILENTLY would boot
/// whatever config answers next with nothing on stderr to explain the tree on
/// disk. No report when there is nothing to skip -- an absent or empty
/// directory is the ordinary "no config here" the search walks past.
pub fn warnEntrylessDir(allocator: std.mem.Allocator, dir_path: []const u8) void {
    var names = discoverDirNames(allocator, dir_path) catch return;
    defer {
        for (names.items) |n| allocator.free(n);
        names.deinit(allocator);
    }
    log.warn("Config dir '{s}' has no {s}; ignoring its {d} .toml file(s)", .{ dir_path, entry_file, names.items.len });
}

/// Errors that mean "nothing to load HERE", so the search moves on without a
/// warning. One list shared by the dir and file loops so they cannot drift.
/// (NotDir is inert for a single-file path, which is why one set fits both.)
///
/// The pinned-snapshot branch in `loadConfigDefault` keeps its own switch on
/// purpose: there a parse failure is ALSO non-fatal -- a broken snapshot must
/// not swap the embedded fallback over an otherwise-fine user config --
/// opposite of the search, where a parse failure must reach the caller.
const silent_missing = [_]anyerror{ error.FileNotFound, error.NotDir };

/// Load failures that mean "this config cannot be used", as opposed to "there
/// is nothing here". Handled identically at both ends: `load` (boot) falls
/// back to the embedded config; the reload path lets them propagate so the
/// live config is kept. Named so the search's hard-fail list and boot's
/// fallback list cannot drift apart -- same policy, spelled twice.
fn isFatalLoadError(err: anyerror) bool {
    return switch (err) {
        // InvalidConfig is part of the list: a fragment's validate fails
        // inside composed.parse, so an out-of-range value must propagate
        // exactly like a TOML parse failure rather than warn-and-skip.
        error.ConfigParseFailed, error.TooManyConfigFiles, error.TooManyConfigBytes, error.InvalidConfig => true,
        else => false,
    };
}

pub fn tryLoadOrWarn(
    loader: LoadFn,
    allocator: std.mem.Allocator,
    path: []const u8,
    comptime err_msg: []const u8,
) !?composed.Config {
    return loader(allocator, path) catch |err| {
        // A parse error must reach the caller: on reload it makes the swap
        // fail so the live config is kept; at boot `load` falls back to the
        // embedded config. Swallowing it here would silently install the
        // fallback over a user's typo'd config.
        if (isFatalLoadError(err)) return err;
        for (silent_missing[0..]) |e| if (err == e) return null;
        log.warn(err_msg, .{ path, err });
        return null;
    };
}

/// The directory and single-file locations searched for a user config, in
/// priority order. Single source of truth shared by the loader
/// (loadConfigDefault) so the search order cannot drift; loadConfigDefault
/// also reports which source supplied the config, so the reload path needs
/// no separate existence probe.
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

/// The shape every search location's loader has: both the dir and
/// single-file loaders take exactly (allocator, path).
pub const LoadFn = *const fn (std.mem.Allocator, []const u8) anyerror!composed.Config;

/// The user-config search order, declared ONCE. Adding a location is a new
/// enum tag plus one line in `loadConfigDefault`'s switch; the priority order,
/// loader, "nothing here" error set and warn wording all follow the tag.
pub const search_order = [_]SearchLoc{
    .xdg_dir,
    .local_dir,
    .xdg_file,
    .local_file,
};

pub const SearchLoc = enum { xdg_dir, local_dir, xdg_file, local_file };

/// One resolved search location: where to look, how to read it, and whether
/// the source is a directory (which the re-exec snapshot records). Built per
/// tag inside `loadConfigDefault`.
pub const SearchAttempt = struct {
    path: []const u8,
    load: LoadFn,
    is_dir: bool,
};

/// XDG config-home resolution, the one place that policy lives.
///
/// `$XDG_CONFIG_HOME` wins when set AND non-empty; otherwise `$HOME/.config`.
/// An EMPTY value counts as unset, per the XDG spec and for a concrete
/// reason: joining `""` with the app name yields a RELATIVE path, so
/// `XDG_CONFIG_HOME=""` would silently redirect the search to the cwd -- a
/// config that boots differently depending on where hana was started.
pub fn configHome(buf: []u8, xdg: ?[]const u8, home: []const u8) ![]const u8 {
    if (xdg) |x| {
        if (x.len != 0) return std.fmt.bufPrint(buf, "{s}", .{x}) catch error.NameTooLong;
    }
    // The caller passes "/" for an unset HOME (so the result stays absolute);
    // a bare "{s}/.config" would then be "//.config" -- harmless, but it
    // leaks into every warning and path comparison that mentions the config
    // home. Join semantics, not string concatenation.
    if (home.len != 0 and home[home.len - 1] == '/')
        return std.fmt.bufPrint(buf, "{s}.config", .{home}) catch error.NameTooLong;
    return std.fmt.bufPrint(buf, "{s}/.config", .{home}) catch error.NameTooLong;
}

pub fn searchPaths(allocator: std.mem.Allocator) !SearchPaths {
    // An unset or empty HOME taken as "/" with no word to the user would
    // silently become `/.config/hana` and then `./config/` -- a WM that came
    // up with a different config than every other launch. Name the
    // substitution instead.
    const home: []const u8 = if (std.c.getenv("HOME")) |h| blk: {
        const s = std.mem.span(h);
        break :blk if (s.len == 0) "/" else s;
    } else blk: {
        log.warn("HOME is unset; the config search falls back to /.config/hana and ./config", .{});
        break :blk "/";
    };
    const xdg_config_home: ?[]const u8 = if (std.c.getenv("XDG_CONFIG_HOME")) |ch| blk: {
        const s = std.mem.span(ch);
        // Empty means unset (XDG spec) -- see configHome. Passing it on
        // as-is would make the config dir relative to the cwd.
        break :blk if (s.len == 0) null else s;
    } else null;
    var ch_buf: [std.fs.max_path_bytes]u8 = undefined;
    const config_home = try configHome(&ch_buf, xdg_config_home, home);
    // Joined through a stack buffer and duped once: `fs.path.join` allocates
    // its result in the arena, and this is an intermediate (the owned copy
    // below is what SearchPaths returns) -- an arena-allocated join would be
    // freed only by the arena reset, a leak the load-scoped-arena tests catch.
    var xdg_buf: [std.fs.max_path_bytes]u8 = undefined;
    const xdg_dir = try allocator.dupe(u8, try std.fmt.bufPrint(&xdg_buf, "{s}/hana", .{config_home}));
    errdefer allocator.free(xdg_dir);

    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    _ = std.c.getcwd(&cwd_buf, cwd_buf.len) orelse return error.CurrentWorkingDirectoryUnlinked;
    const cwd = std.mem.sliceTo(&cwd_buf, 0);
    const local_dir = try std.fs.path.join(allocator, &.{ cwd, "config" });
    errdefer allocator.free(local_dir);

    const xdg_file = try std.fs.path.join(allocator, &.{ xdg_dir, entry_file });
    errdefer allocator.free(xdg_file);
    const local_file = try std.fs.path.join(allocator, &.{ cwd, entry_file });
    return .{
        .xdg_dir = xdg_dir,
        .local_dir = local_dir,
        .xdg_file = xdg_file,
        .local_file = local_file,
    };
}
