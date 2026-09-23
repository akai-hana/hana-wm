//! Configuration interpreter
//! Loads, parses, and validates TOML config files.

const std = @import("std");
const constants = @import("constants");
const fallback = @import("fallback");
const debug = @import("debug");
const ids = @import("ids");
const keysyms = @import("keysyms");
const masks = @import("masks");
const model = @import("model");
const parser = @import("parser");
const schema = @import("schema");
const types = @import("types");
const utils = @import("utils");

/// Longest section name a mis-case warning must lower (bounded helper buffer;
/// real-world section names are far shorter, this just caps a pathological
/// line's cost).
const max_section_name_bytes = 64;
/// Longest single modifier token in a bind string, after trimming.
const max_modifier_key_bytes = 16;

/// Validates a 1-based workspace number, warn-and-skip when outside 1..255 or
/// exceeding `max` (the workspace count / constants.max_workspaces ceiling).
fn checkWorkspaceBound(ws_1based: usize, context: []const u8, max: usize) bool {
    if (ws_1based < 1 or ws_1based > constants.max_workspace_number_1based) {
        debug.warn("{s}: workspace {} out of range, skipping", .{ context, ws_1based });
        return false;
    }
    if (ws_1based > max) {
        debug.warn(
            "{s}: workspace {} exceeds the {}-workspace limit, skipping",
            .{ context, ws_1based, max },
        );
        return false;
    }
    return true;
}

/// Parses a 1-based workspace number from a bare token, with no warning or
/// bound checking (the caller owns `checkWorkspaceBound`). The pure-parse
/// core behind `tryParseWsToken`.
fn parseWsToken(tok: []const u8) ?usize {
    return std.fmt.parseInt(usize, tok, 10) catch return null;
}

/// Parses a 1-based workspace number from a bare token, warning with `fmt` on
/// a malformed token or a value outside 1..255 / `max` (the callers embed the
/// section name in `fmt`, so no separate context is needed), and returns null
/// to skip it.
fn tryParseWsToken(tok: []const u8, max: usize, comptime fmt: []const u8, args: anytype) ?usize {
    const ws_1based = parseWsToken(tok) orelse {
        debug.warn(fmt, args);
        return null;
    };
    if (ws_1based < 1 or
        ws_1based > constants.max_workspace_number_1based or
        ws_1based > max)
    {
        debug.warn(fmt, args);
        return null;
    }
    return ws_1based;
}

/// Appends one class rule. A workspace rule binds `class_name` to the
/// 1-based workspace `ws_1based`; a null `ws_1based` makes it a "float" class
/// rule instead (windows are admitted floating on the current workspace, with
/// `workspace` left 0, unused).
fn addRule(
    allocator: std.mem.Allocator,
    cfg: *types.Config,
    class_name: []const u8,
    ws_1based: ?usize,
) !void {
    try cfg.workspaces.rules.append(allocator, .{
        .class_name = try allocator.dupe(u8, class_name),
        .workspace = if (ws_1based) |w| @intCast(w - 1) else 0,
        .float = (ws_1based == null),
    });
}

/// One row of the bar-anchor table driving both the default bar layout
/// (initDefaultBarLayout) and the per-anchor `[bar.layout.<name>]` sections
/// (parseBarLayout), so the anchor set can never drift.
const BarAnchorInfo = struct {
    name: []const u8,
    position: types.BarSegmentAnchor,
    default_seg: []const u8,
};

const bar_anchors = [_]BarAnchorInfo{
    .{ .name = "left", .position = .left, .default_seg = "workspaces" },
    .{ .name = "center", .position = .center, .default_seg = "title" },
    .{ .name = "right", .position = .right, .default_seg = "clock" },
};

fn initDefaultBarLayout(allocator: std.mem.Allocator, cfg: *types.Config) !void {
    for (bar_anchors) |a| {
        var layout = types.BarLayout{ .position = a.position, .segments = .empty };
        try layout.segments.append(allocator, try allocator.dupe(u8, a.default_seg));
        try cfg.bar.layout.append(allocator, layout);
    }
}

pub const max_file_bytes = 1024 * 1024;

/// Initial allocation for the read-with-growth path (stat failed or reported
/// zero, e.g. procfs/sysfs/pipes). Doubles until the whole file is read.
const read_growth_initial_bytes = 64 * 1024;

/// Upper bound for per-workspace master counts in `[tiling.layouts.master-stack.counts]`.
const max_master_count: u8 = 10;

/// Longest keysym name the bind parser will accept raw (at that length the
/// name no longer fits a zero-terminated copy in the fixed buffer → error.KeyNameTooLong).
const max_key_name_bytes = 64;

/// Reads `path`, returning `error.FileTooLarge` when it exceeds
/// `max_file_bytes`. The returned slice may alias a larger allocation
/// (loading is arena-backed, so all ownership is released together by the
/// arena reset; a bare caller's free of the slice frees the whole buffer).
///
/// One read loop for both the size-known fast path and the stat-less/zero
/// growth path (procfs/sysfs/pipes): the initial buffer is the positive
/// stat-reported size when there is one (allocating exactly that much and
/// reading once), otherwise `read_growth_initial_bytes` with doubling until
/// EOF. A stat result of 0 is as untrustworthy as a failed stat, so both
/// take the growth path. Routing the stat'd case through the same loop also
/// closes the stat-then-read race: if the file grew after stat, the overflow
/// beyond the first known_size bytes is picked up by the growth machinery
/// instead of being silently dropped. The buffer is realloc'd down to the
/// exact size before ownership is handed to the caller.
pub fn readFileAlloc(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const io = std.Options.debug_io;
    const file = std.Io.Dir.openFileAbsolute(io, path, .{}) catch |err| {
        if (err == error.FileNotFound) debug.info("Not found: {s}", .{path});
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

    const initial: usize = if (stat != null and known_size > 0) known_size else read_growth_initial_bytes;
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
fn parseTomlFile(allocator: std.mem.Allocator, path: []const u8) !?parser.Document {
    const raw = try readFileAlloc(allocator, path);
    if (raw.len == 0) return null;
    return try parser.parse(allocator, raw, path);
}

/// warn-and-skip wrapper around parseTomlFile, the "never crash on bad
/// config" path shared by the directory loader and `include` resolution.
/// On read or parse failure, marks the destination merged document's
/// `had_errors` so the caller can propagate error.ConfigParseFailed.
/// An empty file returns null without setting `had_errors`.
fn tryParseTomlFile(
    allocator: std.mem.Allocator,
    path: []const u8,
    dst: *parser.Document,
) ?parser.Document {
    const doc = parseTomlFile(allocator, path) catch |err| {
        dst.had_errors = true;
        debug.warn("Skipping '{s}': {}", .{ path, err });
        return null;
    };
    if (doc == null) debug.info("Skipping empty file: {s}", .{path});
    return doc;
}

/// Parses and merges one config file (path = `dir_path` + `name`) into `dst`,
/// then resolves its own `include`s via mergeIncludes. Shared by the directory
/// loader and include resolution: the parse/merge/log tail is the same in both.
fn mergeOneFile(
    allocator: std.mem.Allocator,
    dst: *parser.Document,
    dir_path: []const u8,
    name: []const u8,
) !void {
    const path = try std.fs.path.join(allocator, &.{ dir_path, name });
    var doc = tryParseTomlFile(allocator, path, dst) orelse return;
    try parser.mergeDocumentsInto(allocator, dst, &doc);
    debug.info("Merged: {s}", .{path});
    try mergeIncludes(allocator, dst, &doc, dir_path);
}

/// Merges files listed in `include = [...]` from `src_doc` into `dst`;
/// `dir_path` is the base for relative paths. Includes resolve one level deep
/// only: an included file's own `include` is skipped, keeping the graph
/// cycle-free by construction (no cycle-detection machinery) at the cost of
/// no chained includes. `allocator` is the load's arena allocator.
fn mergeIncludes(
    allocator: std.mem.Allocator,
    dst: *parser.Document,
    src_doc: *parser.Document,
    dir_path: []const u8,
) !void {
    // The `include` key is copied into `dst` by mergeDocumentsInto, so mark it
    // consumed there as well: otherwise warnUnconsumed would flag it as a typo.
    dst.root.markConsumed("include");
    const inc_val = src_doc.root.get("include") orelse return;
    const includes = inc_val.asArray() orelse return;
    for (includes) |item| {
        const rel = item.asScalar([]const u8) orelse continue;
        if (!std.mem.endsWith(u8, rel, ".toml")) {
            debug.warn("include '{s}': path must end in .toml; skipping", .{rel});
            continue;
        }
        const abs = try std.fs.path.join(allocator, &.{ dir_path, rel });
        var inc_doc = tryParseTomlFile(allocator, abs, dst) orelse continue;
        if (inc_doc.root.get("include")) |_| {
            debug.warn("{s}: nested 'include' inside an included file is not " ++ "supported; its include list is skipped", .{abs});
        }
        try parser.mergeDocumentsInto(allocator, dst, &inc_doc);
        debug.info("Merged (include): {s}", .{abs});
    }
}

fn sliceLessThan(_: void, a: []u8, b: []u8) bool {
    return std.mem.lessThan(u8, a, b);
}

/// Loads and merges all `*.toml` files directly inside `dir_path` (alphabetical order;
/// subdirectories only via explicit `include`).  Later files win on scalar conflicts;
/// arrays accumulate (enforced by the parser's Value getters: scalar reads resolve to
/// the last declaration, array reads see every one).
pub fn loadConfigFromDir(allocator: std.mem.Allocator, dir_path: []const u8) !types.Config {
    var names: std.ArrayList([]u8) = .empty;
    defer {
        for (names.items) |n| allocator.free(n);
        names.deinit(allocator);
    }

    {
        const io = std.Options.debug_io;
        var dir = std.Io.Dir.openDirAbsolute(io, dir_path, .{ .iterate = true }) catch |err| {
            if (err == error.FileNotFound or err == error.NotDir)
                debug.info("Config dir not found: {s}", .{dir_path});
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
        debug.info("No .toml files in config dir: {s}", .{dir_path});
        return error.FileNotFound;
    }

    std.mem.sort([]u8, names.items, {}, sliceLessThan);
    const cfg = try parseAndBuild(allocator, parseDirDoc, DirInput{ .dir_path = dir_path, .names = names.items });
    debug.info("Loaded config from dir: {s} ({} file(s))", .{ dir_path, names.items.len });
    return cfg;
}

/// Merge inputs for `parseDirDoc`: a sorted file list plus the directory they
/// live in, for `mergeOneFile`'s path join.
const DirInput = struct { dir_path: []const u8, names: []const []u8 };

/// Merges every file named in `in.names` (directory-loading order) into one
/// arena document.
fn parseDirDoc(a: std.mem.Allocator, in: DirInput) !parser.Document {
    var merged = parser.Document.init(a);
    for (in.names) |name| try mergeOneFile(a, &merged, in.dir_path, name);
    return merged;
}

fn tryLoadOrWarn(
    comptime loader: anytype,
    allocator: std.mem.Allocator,
    path: []const u8,
    comptime err_msg: []const u8,
    comptime silent: []const anyerror,
) !?types.Config {
    return loader(allocator, path) catch |err| {
        // A parse error must reach the caller. On reload it makes the
        // swap fail so the live config is kept (see events.handleConfigReload);
        // at boot `load` catches it and falls back to the embedded config.
        // Swallowing it here is what silently installed the fallback over a
        // user's typo'd config.
        if (err == error.ConfigParseFailed) return err;
        for (silent) |e| if (err == e) return null;
        debug.warn(err_msg, .{ path, err });
        return null;
    };
}

/// The directory and single-file locations searched for a user config, in
/// priority order. Single source of truth shared by the loader
/// (loadConfigDefault) so the search order cannot drift; loadConfigDefault also
/// reports which source supplied the config, so the reload path needs no
/// separate existence probe.
const SearchPaths = struct {
    xdg_dir: []u8,
    local_dir: []u8,
    xdg_file: []u8,
    local_file: []u8,

    fn deinit(self: SearchPaths, allocator: std.mem.Allocator) void {
        allocator.free(self.xdg_dir);
        allocator.free(self.local_dir);
        allocator.free(self.xdg_file);
        allocator.free(self.local_file);
    }
};

fn searchPaths(allocator: std.mem.Allocator) !SearchPaths {
    const home = if (std.c.getenv("HOME")) |h| std.mem.span(h) else "/";
    const xdg_config_home = std.c.getenv("XDG_CONFIG_HOME");
    // Always dupe and always free: the arena makes the extra dupe of the
    // ~20-byte path negligible, and ownership never has to be tracked.
    const config_home = if (xdg_config_home) |ch|
        try allocator.dupe(u8, std.mem.span(ch))
    else
        try std.fmt.allocPrint(allocator, "{s}/.config", .{home});
    defer allocator.free(config_home);
    const xdg_dir = try std.fs.path.join(allocator, &.{ config_home, "hana" });
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

/// Where a default-config load came from. Reported by loadConfigDefault so the
/// reload path can distinguish "loaded the user config" from "fell back to the
/// embedded fallback" without re-probing the filesystem (they resolve to the
/// same Config value otherwise).
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
};

/// The most recently loaded-and-validated user config location. Mutated by
/// every successful load/reload; read by refreshSnapshot at re-exec time.
/// Allocated with the caller's (c_allocator) arena semantics, process-lifetime
/// after the winning load holds it.
var last_good_source: ?GoodSource = null;

fn rememberGoodSource(allocator: std.mem.Allocator, path: []const u8, is_dir: bool) void {
    if (allocator.dupe(u8, path)) |duped| {
        if (last_good_source) |g| allocator.free(g.path);
        last_good_source = .{ .path = duped, .is_dir = is_dir };
    } else |_| {}
}

/// Snapshot dir a re-exec boots from. XDG_RUNTIME_DIR is already per-user, so
/// no uid suffix is needed there; the /tmp fallback carries the uid, mirroring
/// persist.zig. Caller owns the returned slice.
pub fn snapshotDirPath(allocator: std.mem.Allocator) ![]u8 {
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

/// Best-effort empty of `d`'s immediate entries (recursive via deleteTree), so
/// a refresh that lost a file never leaves a stale copy behind.
fn clearDir(io: std.Io, d: std.Io.Dir) void {
    var it = d.iterate();
    while (it.next(io) catch return) |entry| {
        d.deleteTree(io, entry.name) catch {};
    }
}

/// Freezes the last-good config source into the snapshot dir, so a re-exec
/// boots an identical config without re-reading the live config tree.
/// Best-effort: a failed copy keeps the previous snapshot, still self-consistent.
pub fn refreshSnapshot(allocator: std.mem.Allocator) void {
    const g = last_good_source orelse return;
    const io = std.Options.debug_io;
    const snap = snapshotDirPath(allocator) catch return;
    defer allocator.free(snap);
    // A re-exec boot whose own source IS the snapshot has nothing to copy.
    if (std.mem.eql(u8, g.path, snap)) return;

    var dest = std.Io.Dir.openDirAbsolute(io, snap, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => blk: {
            std.Io.Dir.createDirAbsolute(io, snap, std.Io.File.Permissions.default_dir) catch return;
            break :blk std.Io.Dir.openDirAbsolute(io, snap, .{ .iterate = true }) catch return;
        },
        else => return,
    };
    defer dest.close(io);
    clearDir(io, dest);

    if (g.is_dir) {
        const src = std.Io.Dir.openDirAbsolute(io, g.path, .{ .iterate = true }) catch return;
        defer src.close(io);
        var w = src.walk(allocator) catch return;
        defer w.deinit();
        while (w.next(io) catch return) |entry| {
            // createDirPath for the entry's parents is implied by make_path.
            if (entry.kind == .directory) continue;
            // Every file is copied (not just .toml): includes resolve relative
            // to the config dir and may reference non-.toml assets.
            std.Io.Dir.copyFile(src, entry.path, dest, entry.path, io, .{ .make_path = true, .replace = true }) catch {};
        }
    } else {
        // A single-file config becomes <snapshot>/config.toml, which the
        // directory loader picks up (fallback.toml is skipped by name).
        std.Io.Dir.copyFile(std.Io.Dir.cwd(), g.path, dest, "config.toml", io, .{ .replace = true }) catch return;
    }
}

/// Loads config in priority order: (1) ~/.config/hana/, (2) ./config/,
/// (3) ~/.config/hana/config.toml, (4) ./config.toml, (5) embedded fallback.
/// `source` receives where the config actually came from (user vs fallback),
/// so callers with different boot/reload semantics (see events.handleConfigReload)
/// need no separate existence probe.
pub fn loadConfigDefault(allocator: std.mem.Allocator, source: *DefaultSource) !types.Config {
    const paths = try searchPaths(allocator);
    defer paths.deinit(allocator);

    // A re-exec hand-off (reload_hana, restart.execNext) pins HANA_CONFIG_DIR
    // to the frozen last-good snapshot, so the successor boots an identical
    // config WITHOUT re-reading the live config tree. Any failure falls
    // through to the normal search (a broken snapshot must not silently swap
    // in the embedded fallback over an otherwise-fine user config).
    if (std.c.getenv("HANA_CONFIG_DIR")) |env_z| {
        const env = std.mem.span(env_z);
        if (loadConfigFromDir(allocator, env)) |cfg| {
            rememberGoodSource(allocator, env, true);
            source.* = .user;
            return cfg;
        } else |err| switch (err) {
            error.FileNotFound, error.NotDir, error.ConfigParseFailed => {
                debug.warn("Re-exec config snapshot {s} unusable ({s}); falling back to the user's config", .{ env, @errorName(err) });
            },
            else => return err,
        }
    }

    // Try directories first (contain multiple .toml files), then single files.
    const dir_attempts = [_][]const u8{ paths.xdg_dir, paths.local_dir };
    for (dir_attempts) |dir|
        if (try tryLoadOrWarn(loadConfigFromDir, allocator, dir, "Config load error from {s}: {}", &.{ error.FileNotFound, error.NotDir })) |cfg| {
            rememberGoodSource(allocator, dir, true);
            source.* = .user;
            return cfg;
        };

    const file_attempts = [_][]const u8{ paths.xdg_file, paths.local_file };
    for (file_attempts) |path|
        if (try tryLoadOrWarn(loadConfig, allocator, path, "hana: config file '{s}' found but failed to load: {}; falling back", &.{error.FileNotFound})) |cfg| {
            rememberGoodSource(allocator, path, false);
            source.* = .user;
            return cfg;
        };

    debug.info("No config found, using fallback with auto-detection", .{});
    source.* = .fallback;
    return try loadFallbackConfig(allocator);
}

/// Validates domain invariants on a freshly loaded config.
fn invalid(comptime fmt: []const u8, args: anytype) error{InvalidConfig} {
    debug.err("Invalid config: " ++ fmt ++ ", keeping old", args);
    return error.InvalidConfig;
}

pub fn validate(cfg: *const types.Config) !void {
    // master_width is a ScalableValue: percentages validate as a
    // [min_master_width, max_master_width] ratio; pixels only as >= 0, since
    // the screen width for a ratio isn't available here and the runtime clamps:
    // a pixel-vs-ratio check would wrongly refuse `master_width = 600`.
    const mw = cfg.tiling.master_width;
    if (mw.is_percentage) {
        const mw_ratio: f32 = utils.scaling.asRatio(mw);
        if (mw_ratio < constants.min_master_width or mw_ratio > constants.max_master_width)
            return invalid("master_width {d:.0}% out of [{d:.0}%, {d:.0}%]", .{
                mw_ratio * 100.0,
                constants.min_master_width * 100.0,
                constants.max_master_width * 100.0,
            });
    } else if (mw.value < 0.0) {
        return invalid("master_width {d}px must be >= 0", .{mw.value});
    }
}

/// Reads, parses, and returns the config at `path` (single-file entry point).
pub fn loadConfig(allocator: std.mem.Allocator, path: []const u8) !types.Config {
    const cfg = parseAndBuild(allocator, parseFileDoc, FileInput{ .path = path, .base_dir = std.fs.path.dirname(path) orelse "." }) catch |err| switch (err) {
        error.ConfigEmpty => {
            debug.info("Empty config file: {s}, using fallback", .{path});
            return try loadFallbackConfig(allocator);
        },
        else => return err,
    };
    debug.info("Loaded: {s}", .{path});
    return cfg;
}

/// Parse inputs for `parseFileDoc`: the single config file and its include
/// resolution base directory.
const FileInput = struct { path: []const u8, base_dir: []const u8 };

/// Parses one config file plus its `include`s into an arena document.
fn parseFileDoc(a: std.mem.Allocator, in: FileInput) !parser.Document {
    var doc = try parseTomlFile(a, in.path) orelse return error.ConfigEmpty;
    try mergeIncludes(a, &doc, &doc, in.base_dir);
    return doc;
}

/// Parse inputs for `parseFallbackDoc`: the embedded fallback TOML text.
const FallbackInput = struct { toml: []const u8 };

/// Parses the embedded fallback TOML into an arena document.
fn parseFallbackDoc(a: std.mem.Allocator, in: FallbackInput) !parser.Document {
    return try parser.parse(a, in.toml, "<embedded fallback>");
}

/// Shared tail of the config load pipelines: one load-scoped arena hosts the
/// parsed Document(s) (and their aliased file buffers) while `parse` fills a
/// document from the arena allocator; `buildConfigFromDoc` then dupes every
/// owned Config string from the backing `allocator` before the arena reset
/// reclaims the documents.
fn parseAndBuild(
    allocator: std.mem.Allocator,
    comptime parse: anytype,
    in: anytype,
) !types.Config {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var doc = try parse(a, in);
    return buildConfigFromDoc(allocator, &doc);
}

fn loadFallbackConfig(allocator: std.mem.Allocator) !types.Config {
    const fallback_toml = fallback.getFallbackToml() orelse return error.FallbackMissing;
    var cfg = try parseAndBuild(allocator, parseFallbackDoc, FallbackInput{ .toml = fallback_toml });
    // If the terminal detection/dupe below errors, free the built config
    // rather than leaking it (the `try` above means buildConfigFromDoc's own
    // errdefer already handled its internal failures).
    errdefer cfg.deinit(allocator);
    const terminal = fallback.detectTerminal();
    for (cfg.keybindings.items) |*kb| {
        if (kb.action == .exec and std.mem.eql(u8, kb.action.exec, "auto_terminal")) {
            // Dupe BEFORE freeing the old string: if the dupe throws (OOM),
            // the `try` propagates and the `errdefer cfg.deinit(allocator)`
            // above frees kb.action.exec — which must still point at the live
            // "auto_terminal" allocation, not an already-freed pointer.
            const new_exec = try allocator.dupe(u8, terminal);
            allocator.free(kb.action.exec);
            kb.action.exec = new_exec;
        }
    }

    debug.info("Loaded fallback configuration with auto-detection", .{});
    return cfg;
}

/// Builds the built-in default Config: every scalar knob seeds from
/// types.Config's field initializers (the single source of truth), plus
/// heap-dup'd non-scalar seed data so deinit can free every owned field
/// unconditionally, and one `layouts` entry so the layout cycle always has
/// something to rotate. OOM propagates; the errdefer tears down the partial
/// Config, never leaving string literals for deinit to free.
fn getDefaultConfig(allocator: std.mem.Allocator) !types.Config {
    var cfg: types.Config = .{};
    errdefer cfg.deinit(allocator);
    // Canonical default name: it resolves to the canonical master module at
    // seed time; every stored name is canonical.
    const default_layout = try allocator.dupe(u8, types.canon_master_layout);
    try cfg.tiling.layouts.append(allocator, default_layout);
    cfg.tiling.layout = cfg.tiling.layouts.items[0];
    try padWorkspaceIcons(allocator, &cfg);
    try initDefaultBarLayout(allocator, &cfg);
    return cfg;
}

fn buildConfigFromDoc(allocator: std.mem.Allocator, doc: *parser.Document) !types.Config {
    // A broken TOML (warn-and-skipped line, or a whole file skipped during
    // the merge) must not silently produce a partially-applied config: fail
    // the load so reload keeps the live config. Boot falls through to
    // the embedded fallback via loadConfigDefault's warn-and-skip.
    if (doc.had_errors) return error.ConfigParseFailed;
    // Mis-cased KNOWN section headers ([Bar], [TILING], ...) are otherwise
    // silently dropped; call them out once each.
    warnMisCasedSections(doc);
    var cfg = try getDefaultConfig(allocator);
    // If any parse step below errors (OOM), free the partial Config so the
    // half-applied section doesn't leak. Only armed after getDefaultConfig
    // succeeded, so its own errdefer handled the earlier failure.
    errdefer cfg.deinit(allocator);
    try parseKeybindings(allocator, doc, &cfg);
    try parseTilingStructures(allocator, doc, &cfg);
    // Every scalar knob ([drag], [fullscreen], [workspaces], [tiling]
    // flags/aesthetics/master trio, all of [bar] incl. [bar.properties])
    // in one table-driven pass; must precede parseBar so icon padding sees
    // the freshly parsed workspaces.count.
    try schema.applyAll(doc, allocator, &cfg);
    // A `tiling.*`/`bar.properties` family without its parent section is
    // inert (applyAll and the parse functions both gate on it); warn once.
    warnInertSectionFamilies(doc);
    try parseBar(allocator, doc, &cfg);
    try parseRules(allocator, doc, &cfg);
    doc.root.warnUnconsumed("<root>");
    var iter = doc.sections.iterator();
    while (iter.next()) |entry|
        entry.value_ptr.warnUnconsumed(entry.key_ptr.*);
    return cfg;
}

/// Known section names hana recognizes (case-sensitively) at their exact
/// spelling. A section header that differs from one of these only by case is
/// almost certainly a typo that silently drops the whole section.
const known_sections = std.StaticStringMap(void).initComptime(.{
    .{ types.section_binds, {} },             .{ types.section_binds_alt, {} },
    .{ types.section_workspace_rules, {} },   .{ types.section_rules, {} },
    .{ types.section_drag, {} },              .{ types.section_fullscreen, {} },
    .{ types.section_tiling, {} },            .{ types.section_workspaces, {} },
    .{ types.section_bar, {} },               .{ types.section_bar_properties, {} },
    .{ "bar.layout.left", {} },               .{ "bar.layout.center", {} },
    .{ "bar.layout.right", {} },              .{ types.section_bar_modules_workspaces, {} },
    .{ types.section_tiling_aesthetics, {} }, .{ types.section_tiling_layouts_master_stack, {} },
    .{ "tiling.layouts.master_stack", {} },
});

/// Section families whose parent section must exist for their knobs to do
/// anything; a mis-cased or missing parent leaves them inert.
const known_section_prefixes = [_][]const u8{ types.section_prefix_tiling_layouts, types.section_prefix_workspace_rules, types.section_prefix_rules };

fn warnMisCasedSections(doc: *parser.Document) void {
    var iter = doc.sections.iterator();
    while (iter.next()) |entry| {
        const name = entry.key_ptr.*;
        if (known_sections.has(name)) continue;
        var buf: [max_section_name_bytes]u8 = undefined;
        const lowered = types.lowerSlice(buf.len, &buf, name) orelse continue;
        if (!std.mem.eql(u8, lowered, name) and known_sections.has(lowered)) {
            debug.warn("Section [{s}] is mis-cased; hana recognizes [{s}], ignoring the section", .{ name, lowered });
            continue;
        }
        for (known_section_prefixes) |pfx| {
            if (name.len > pfx.len and std.ascii.startsWithIgnoreCase(name, pfx) and
                !std.mem.startsWith(u8, name, pfx))
            {
                debug.warn("Section [{s}] is mis-cased; hana recognizes the [{s}...] family (all lowercase), ignoring", .{ name, pfx });
                break;
            }
        }
    }
}

/// Warns once when a section family that requires a parent section is present
/// without it, which leaves its knobs silently inert.
fn warnInertSectionFamilies(doc: *parser.Document) void {
    if (doc.getSection(types.section_tiling) == null) {
        var iter = doc.sections.iterator();
        while (iter.next()) |entry| {
            if (std.mem.startsWith(u8, entry.key_ptr.*, types.section_prefix_tiling)) {
                debug.warn("[tiling.*] sections present but bare [tiling] is missing; their knobs are inert", .{});
                break;
            }
        }
    }
    if (doc.getSection(types.section_bar) == null and doc.getSection(types.section_bar_properties) != null)
        debug.warn("[bar.properties] present but [bar] is missing; its knobs are inert", .{});
}

const mod_map = std.StaticStringMap(u16).initComptime(.{
    .{ "super", masks.mod_super },
    .{ "mod4", masks.mod_super },
    .{ "alt", masks.mod_alt },
    .{ "mod1", masks.mod_alt },
    .{ "control", masks.mod_control },
    .{ "ctrl", masks.mod_control },
    .{ "shift", masks.mod_shift },
});

const mouse_button_map = std.StaticStringMap(u8).initComptime(.{
    .{ "button1", 1 }, .{ "left_click", 1 },   .{ "leftclick", 1 },
    .{ "button2", 2 }, .{ "middle_click", 2 }, .{ "middleclick", 2 },
    .{ "button3", 3 }, .{ "right_click", 3 },  .{ "rightclick", 3 },
    .{ "button4", 4 }, .{ "scroll_up", 4 },    .{ "scrollup", 4 },
    .{ "button5", 5 }, .{ "scroll_down", 5 },  .{ "scrolldown", 5 },
});

/// Every action key, as one hand-maintained table: the `Action` union's
/// void tag names are usable verbatim (auto-derived below), and these
/// entries add the aliases / payload-carrying spellings. Adding an Action
/// union member requires only the union edit for its tag name; forgetting an
/// intended alias fails the parser's unknown-action typo detection instead
/// of silently unparsable.
const action_entries = [_]struct { key: []const u8, action: types.Action }{
    // Void-variant aliases (old tag names → renamed void variants).
    .{ .key = "close", .action = .{ .close_window = {} } },
    .{ .key = "kill", .action = .{ .close_window = {} } },
    .{ .key = "fullscreen", .action = .{ .toggle_fullscreen = {} } },
    .{ .key = "minimize", .action = .{ .minimize_window = {} } },
    .{ .key = "prompt", .action = .{ .toggle_prompt = {} } },
    // Payload variant spellings (one enum payload each).
    .{ .key = "toggle_layout", .action = .{ .cycle_layout = .forward } },
    .{ .key = "toggle_layout_reverse", .action = .{ .cycle_layout = .reverse } },
    .{ .key = "increase_master", .action = .{ .set_master_width = .forward } },
    .{ .key = "decrease_master", .action = .{ .set_master_width = .reverse } },
    .{ .key = "increase_master_count", .action = .{ .set_master_count = .forward } },
    .{ .key = "decrease_master_count", .action = .{ .set_master_count = .reverse } },
    .{ .key = "stack_top", .action = .{ .grow_stack = .forward } },
    .{ .key = "stack_bottom", .action = .{ .grow_stack = .reverse } },
    .{ .key = "swap_master", .action = .{ .swap_master = .normal } },
    .{ .key = "swap_master_focus_swap", .action = .{ .swap_master = .focus_swap } },
    .{ .key = "cycle_layout_variants", .action = .{ .cycle_variants = .forward } },
    .{ .key = "cycle_layout_variants_reverse", .action = .{ .cycle_variants = .reverse } },
    .{ .key = "cycle_variants", .action = .{ .cycle_variants = .forward } },
    .{ .key = "focus_next_window", .action = .{ .cycle_focus = .forward } },
    .{ .key = "focus_prev_window", .action = .{ .cycle_focus = .reverse } },
    .{ .key = "scroll_view_left", .action = .{ .scroll_view = .reverse } },
    .{ .key = "scroll_view_right", .action = .{ .scroll_view = .forward } },
    .{ .key = "unminimize_lifo", .action = .{ .unminimize = .lifo } },
    .{ .key = "unminimize_fifo", .action = .{ .unminimize = .fifo } },
};

const action_map: std.StaticStringMap(types.Action) = blk: {
    @setEvalBranchQuota(10000);
    const fields = @typeInfo(types.Action).@"union".fields;
    var kvs: [fields.len + action_entries.len]struct { []const u8, types.Action } = undefined;
    var n: usize = 0;
    // Void tag names auto-generated from union fields.
    for (fields) |f| {
        if (f.type == void) {
            kvs[n] = .{ f.name, @field(types.Action, f.name) };
            n += 1;
        }
    }
    // Hand entries, checked against everything already in the table.
    for (action_entries) |a| {
        for (kvs[0..n]) |kv| {
            if (std.mem.eql(u8, kv[0], a.key))
                @compileError("action key shadows a union tag name: " ++ a.key);
        }
        kvs[n] = .{ a.key, a.action };
        n += 1;
    }
    break :blk .initComptime(kvs[0..n]);
};

const GlobEntry = struct {
    key: []const u8,
    ws_idx: u16, // 1-based position in the expanded list; 0 when there is no glob
    owned: bool, // true when key was heap-allocated and must be freed by the caller
};

/// Maximum number of keys a single `{...}` glob may expand to. Workspace
/// indices only reach 256 (see tryParseWorkspace), and a larger glob could
/// only ever produce unreachable exec fallbacks, so expansion stops there.
const max_glob_expansion: usize = 256;

/// Wraps `key` as the single unowned GlobEntry returned when a keybind key
/// has no `{...}` glob (or an unusable one) to expand.
fn singleGlobEntry(allocator: std.mem.Allocator, key: []const u8) ![]GlobEntry {
    const e = try allocator.alloc(GlobEntry, 1);
    e[0] = .{ .key = key, .ws_idx = 0, .owned = false };
    return e;
}

/// Appends one expanded entry for a plain (non-range) comma token, enforcing
/// `max_glob_expansion`. The token is substituted verbatim into the key.
fn appendExpandedEntry(
    allocator: std.mem.Allocator,
    entries: *std.ArrayList(GlobEntry),
    prefix: []const u8,
    suffix: []const u8,
    token: []const u8,
) !void {
    if (entries.items.len >= max_glob_expansion) return;
    const k = try std.fmt.allocPrint(allocator, "{s}{s}{s}", .{ prefix, token, suffix });
    try entries.append(allocator, .{ .key = k, .ws_idx = @intCast(entries.items.len + 1), .owned = true });
}

/// Expands a single-char range token (e.g. "1-4"), appending one entry per
/// char, enforcing `max_glob_expansion`. A descending range is skipped with a
/// warning rather than expanded.
fn expandRangeToken(
    allocator: std.mem.Allocator,
    entries: *std.ArrayList(GlobEntry),
    key_pattern: []const u8,
    prefix: []const u8,
    suffix: []const u8,
    t: []const u8,
) !void {
    var ch = t[0];
    const end = t[2];
    if (ch > end) {
        debug.warn("Keybind glob '{s}': descending range '{c}-{c}', skipping", .{ key_pattern, ch, end });
        return;
    }
    while (ch <= end) : (ch += 1) try appendExpandedEntry(allocator, entries, prefix, suffix, &.{ch});
}

/// Expands `{...}` glob patterns in a keybind key (e.g. `Mod+{1-4,Q}` -> 5 entries,
/// comma-separated tokens and single-char ranges supported).  Workspace actions get a
/// 1-based index appended; other actions are replicated unchanged.
/// Returns a single unowned entry when no glob is present.
fn expandGlobKeys(allocator: std.mem.Allocator, key_pattern: []const u8) ![]GlobEntry {
    const lbrace = std.mem.indexOfScalar(u8, key_pattern, '{') orelse
        return singleGlobEntry(allocator, key_pattern);
    const rbrace = std.mem.indexOfScalarPos(u8, key_pattern, lbrace + 1, '}') orelse {
        debug.warn("Keybind glob missing closing '}}' in '{s}', treating as literal", .{key_pattern});
        return singleGlobEntry(allocator, key_pattern);
    };
    const prefix = key_pattern[0..lbrace];
    const suffix = key_pattern[rbrace + 1 ..];
    const inner = key_pattern[lbrace + 1 .. rbrace];

    var entries: std.ArrayList(GlobEntry) = .empty;
    errdefer {
        for (entries.items) |e| if (e.owned) allocator.free(e.key);
        entries.deinit(allocator);
    }

    var it = std.mem.splitScalar(u8, inner, ',');
    while (it.next()) |token| {
        const t = std.mem.trim(u8, token, " \t");
        if (t.len == 0) continue;
        if (t.len == 3 and t[1] == '-') try expandRangeToken(allocator, &entries, key_pattern, prefix, suffix, t) else try appendExpandedEntry(allocator, &entries, prefix, suffix, t);
    }
    if (entries.items.len == 0) {
        entries.deinit(allocator);
        return singleGlobEntry(allocator, key_pattern);
    }
    return try entries.toOwnedSlice(allocator);
}

/// Workspace-scoped actions: one spec per base name, the single source of
/// truth shared by resolveAndParseAction (which checks glob expansion against
/// `workspace_action_bases`) and parseAction (which parses the direct
/// `NAME_N` form into a payload-bearing action via `make`).
const workspace_action_specs = [_]struct {
    base: []const u8,
    make: *const fn (u8) types.Action,
}{
    .{ .base = "workspace", .make = workspaceSwitchTo },
    .{ .base = "move_to_workspace", .make = workspaceMoveTo },
    .{ .base = "toggle_tag", .make = workspaceToggleTag },
};

fn workspaceSwitchTo(ws: u8) types.Action {
    return .{ .switch_workspace = ws };
}
fn workspaceMoveTo(ws: u8) types.Action {
    return .{ .move_to_workspace = ws };
}
fn workspaceToggleTag(ws: u8) types.Action {
    return .{ .toggle_tag = ws };
}

/// Membership set of the workspace-action base names, derived from
/// `workspace_action_specs` so the two stay in sync.
const workspace_action_bases = std.StaticStringMap(void).initComptime(block: {
    var kvs: [workspace_action_specs.len]struct { []const u8, void } = undefined;
    for (workspace_action_specs, 0..) |spec, i| kvs[i] = .{ spec.base, {} };
    break :block kvs;
});

fn resolveAndParseAction(
    allocator: std.mem.Allocator,
    cmd: []const u8,
    ws_idx: u16,
    kill_placeholder: ?[]const u8,
) !types.Action {
    // Substitute {kill} FIRST, for ANY action string, before the
    // workspace-branch check and before parseAction. Previously the
    // substitution only ran for glob-expanded workspace actions, so every
    // ordinary `{kill} foo` bind exec'd a literal, broken shell command.
    const effective: []const u8 = if (kill_placeholder) |kp| blk: {
        if (std.mem.indexOf(u8, cmd, "{kill}") != null)
            break :blk try std.mem.replaceOwned(u8, allocator, cmd, "{kill}", kp);
        break :blk cmd;
    } else cmd;
    // Free only our own substitution; `cmd` is caller-owned when unchanged.
    defer if (effective.ptr != cmd.ptr) allocator.free(effective);
    if (ws_idx > 0 and workspace_action_bases.has(effective)) {
        const ws_str = try std.fmt.allocPrint(allocator, "{s}_{d}", .{ effective, ws_idx });
        defer allocator.free(ws_str);
        return parseAction(allocator, ws_str);
    }
    return parseAction(allocator, effective);
}

/// Resolves one `binds` value into a single Action, or null when the entry
/// should be skipped (empty array, or a value that is neither string nor
/// array). A one-element array unwraps to its sole action; a multi-element
/// array becomes a `.sequence`. Within an element a `+` links a parallel
/// batch (`[a, b + c, d]` = a, then b and c together, then d).
fn actionFromValue(
    allocator: std.mem.Allocator,
    value: parser.Value,
    ws_idx: u16,
    kill: ?[]const u8,
) !?types.Action {
    return switch (value) {
        .array => |arr| {
            if (arr.items.len == 0) return null;
            var acts: std.ArrayList(types.Action) = .empty;
            errdefer {
                for (acts.items) |*a| a.deinit(allocator);
                acts.deinit(allocator);
            }
            for (arr.items) |elem|
                if (elem.asScalar([]const u8)) |cmd|
                    try acts.append(allocator, try resolveElement(allocator, cmd, ws_idx, kill));
            // A non-empty array whose elements were all non-strings
            // filters down to zero actions; return null (no binding) instead
            // of a dead empty sequence.
            if (acts.items.len == 0) {
                acts.deinit(allocator);
                return null;
            }
            if (acts.items.len == 1) {
                const only = acts.items[0];
                acts.deinit(allocator);
                return only;
            }
            return .{ .sequence = try acts.toOwnedSlice(allocator) };
        },
        .string => |command| try resolveElement(allocator, command, ws_idx, kill),
        else => null,
    };
}

/// A `+` is a parallel separator only when whitespace sits on at least one
/// side, so literal plus signs in exec commands (`xdotool key ctrl+plus`)
/// are never split.
fn parallelSepAt(cmd: []const u8, i: usize) bool {
    if (cmd[i] != '+') return false;
    if (i > 0 and (cmd[i - 1] == ' ' or cmd[i - 1] == '\t')) return true;
    if (i + 1 < cmd.len and (cmd[i + 1] == ' ' or cmd[i + 1] == '\t')) return true;
    return false;
}

/// Splits `cmd` on parallel separators, appending the trimmed, non-empty
/// fragments to `out`. Slices alias `cmd` (no copies).
fn splitParallel(allocator: std.mem.Allocator, cmd: []const u8, out: *std.ArrayList([]const u8)) !void {
    var start: usize = 0;
    for (cmd, 0..) |c, i| if (c == '+' and parallelSepAt(cmd, i)) {
        const frag = std.mem.trim(u8, cmd[start..i], " \t");
        if (frag.len > 0) try out.append(allocator, frag);
        start = i + 1;
    };
    const tail = std.mem.trim(u8, cmd[start..], " \t");
    if (tail.len > 0) try out.append(allocator, tail);
}

/// Resolves one config-list element (or a lone string value) into its Action.
/// A `+`-linked batch becomes a `.parallel` group; without separators the
/// result is a single action (byte-for-byte the previous element behavior).
fn resolveElement(
    allocator: std.mem.Allocator,
    cmd: []const u8,
    ws_idx: u16,
    kill: ?[]const u8,
) !types.Action {
    var has_sep = false;
    for (cmd, 0..) |c, i| if (c == '+' and parallelSepAt(cmd, i)) {
        has_sep = true;
        break;
    };
    if (!has_sep) return resolveAndParseAction(allocator, cmd, ws_idx, kill);

    var frags: std.ArrayList([]const u8) = .empty;
    defer frags.deinit(allocator);
    try splitParallel(allocator, cmd, &frags);
    if (frags.items.len <= 1)
        return resolveAndParseAction(allocator, if (frags.items.len == 1) frags.items[0] else cmd, ws_idx, kill);

    var group: std.ArrayList(types.Action) = .empty;
    errdefer {
        for (group.items) |*a| a.deinit(allocator);
        group.deinit(allocator);
    }
    for (frags.items) |frag| try group.append(allocator, try resolveAndParseAction(allocator, frag, ws_idx, kill));
    return .{ .parallel = try group.toOwnedSlice(allocator) };
}

/// Resolves the `Mod+` placeholder in a keybind key: when `mod_placeholder` is
/// set and the key starts with `mod+` (case-insensitive), substitutes the real
/// modifier. Otherwise returns the key unchanged (no allocation).
fn resolveModPlaceholder(
    allocator: std.mem.Allocator,
    key: []const u8,
    mod_placeholder: ?[]const u8,
) ![]const u8 {
    if (mod_placeholder) |mod|
        if (std.ascii.startsWithIgnoreCase(key, "mod+"))
            return try std.fmt.allocPrint(allocator, "{s}+{s}", .{ mod, key["mod+".len..] });
    return key;
}

fn parseKeybindings(allocator: std.mem.Allocator, doc: *parser.Document, cfg: *types.Config) !void {
    const section = doc.getSection(types.section_binds) orelse doc.getSection(types.section_binds_alt) orelse return;
    var mod_placeholder: ?[]const u8 = null;
    var kill_placeholder: ?[]const u8 = null;
    var iter = section.orderedIterator();
    while (iter.next()) |entry| {
        section.markConsumed(entry.key);
        if (std.ascii.eqlIgnoreCase(entry.key, "Mod")) {
            mod_placeholder = entry.value.asScalar([]const u8);
            continue;
        }
        if (std.ascii.eqlIgnoreCase(entry.key, "kill")) {
            kill_placeholder = entry.value.asScalar([]const u8);
            continue;
        }
        const glob_entries = try expandGlobKeys(allocator, entry.key);
        defer {
            for (glob_entries) |ge| if (ge.owned) allocator.free(ge.key);
            allocator.free(glob_entries);
        }
        for (glob_entries) |ge| {
            const keybind_str: []const u8 = try resolveModPlaceholder(allocator, ge.key, mod_placeholder);
            defer if (keybind_str.ptr != ge.key.ptr) allocator.free(keybind_str);
            var action = try actionFromValue(allocator, entry.value, ge.ws_idx, kill_placeholder) orelse continue;
            const bind = parseBindString(keybind_str) catch |err| {
                debug.warn("Failed to parse keybind '{s}': {}", .{ keybind_str, err });
                // The action just built owns heap strings; it isn't stored
                // anywhere on this path, so free it before skipping the bind.
                action.deinit(allocator);
                continue;
            };
            switch (bind) {
                .mouse => |mb| try cfg.mouse_bindings.append(allocator, .{ .modifiers = mb.modifiers, .button = mb.button, .action = action }),
                .keyboard => |kb| try cfg.keybindings.append(allocator, .{ .modifiers = kb.modifiers, .keysym = kb.keysym, .action = action }),
            }
        }
    }
}

const BindResult = union(enum) {
    keyboard: struct { modifiers: u16, keysym: u32 },
    mouse: struct { modifiers: u16, button: u8 },
};

/// Parses a `Mods+Key` or `Mods+ButtonName` string into a typed BindResult.
/// Returns an error when any token is unrecognised.
fn parseBindString(str: []const u8) !BindResult {
    var modifiers: u16 = 0;
    var keysym: ?u32 = null;
    var button: ?u8 = null;
    var parts = std.mem.splitScalar(u8, str, '+');
    while (parts.next()) |part| {
        const trimmed = std.mem.trim(u8, part, " \t");
        // Normalise to lowercase (modifiers are case-insensitive) via a bounded
        // helper; overlong tokens → null.
        var lowered_buf: [max_modifier_key_bytes]u8 = undefined;
        const lowered = types.lowerSlice(max_modifier_key_bytes, &lowered_buf, trimmed);
        const mod: ?u16 = if (lowered) |l| mod_map.get(l) else null;
        if (mod) |m| {
            modifiers |= m;
        } else if (mouse_button_map.get(lowered orelse "")) |btn| {
            if (button != null) return error.MultipleButtons;
            button = btn;
        } else {
            if (button != null) return error.AmbiguousBinding;
            if (keysym != null) return error.MultipleKeys;
            keysym = try keyNameToKeysym(trimmed);
        }
    }
    if (button) |b| {
        if (keysym != null) return error.AmbiguousBinding;
        return .{ .mouse = .{ .modifiers = modifiers, .button = b } };
    }
    return .{ .keyboard = .{ .modifiers = modifiers, .keysym = keysym orelse return error.NoKeysym } };
}

fn keyNameToKeysym(name: []const u8) !u32 {
    if (name.len >= max_key_name_bytes) return error.KeyNameTooLong;
    var buf: [max_key_name_bytes]u8 = undefined;
    @memcpy(buf[0..name.len], name);
    buf[name.len] = 0;
    const keysym = keysyms.keysymFromName(&buf);
    return if (keysym == keysyms.XKB_KEY_NoSymbol) error.UnknownKeyName else keysym;
}

fn tryParseWorkspace(command: []const u8, prefix: []const u8) ?u8 {
    if (!std.mem.startsWith(u8, command, prefix)) return null;
    const num = std.fmt.parseInt(usize, command[prefix.len..], 10) catch return null;
    if (num < 1 or num > constants.max_workspace_command_1based) return null;
    return @intCast(num - 1);
}

/// Action verb stems used to spot a keybind action that was *meant* to be one
/// of hana's built-in actions but is spelled wrong. Anything not matching one
/// of these and not containing a shell metacharacter is treated as an ordinary
/// exec command and left alone (e.g. "firefox", "foot", "/usr/bin/emacs").
const action_verb_prefixes = [_][]const u8{
    "toggle_",     "increase_", "decrease_", "grow_",      "stack_", "swap_",
    "move_",       "move_to_",  "focus_",    "close_",     "kill_",  "minimize_",
    "unminimize_", "cycle_",    "scroll_",   "workspace_", "all_",   "dump_",
    "pin_",
};

/// True when `cmd` is a bare identifier (letters, digits, underscores only,
/// nothing a real shell command would need) that starts with a known action
/// verb stem, i.e. it looks like a misspelled built-in action rather than a
/// legitimate external program.
fn looksLikeActionWord(cmd: []const u8) bool {
    if (cmd.len == 0) return false;
    for (cmd) |c| {
        if (!(std.ascii.isAlphanumeric(c) or c == '_')) return false;
    }
    for (action_verb_prefixes) |p| {
        if (std.mem.startsWith(u8, cmd, p)) return true;
    }
    return false;
}

/// True when `cmd` still carries a `{kill}` token or a `{...}` placeholder
/// fragment. After the hoisted substitution this should never be true for a
/// config action; it is a defensive guard so an unresolved placeholder can
/// never be handed to the shell verbatim.
fn hasPlaceholderFragment(cmd: []const u8) bool {
    if (std.mem.indexOf(u8, cmd, "{kill}") != null) return true;
    const lbrace = std.mem.indexOfScalar(u8, cmd, '{') orelse return false;
    return std.mem.indexOfScalarPos(u8, cmd, lbrace + 1, '}') != null;
}

fn parseAction(allocator: std.mem.Allocator, cmd: []const u8) !types.Action {
    if (action_map.get(cmd)) |a| return a;
    inline for (workspace_action_specs) |spec| {
        if (tryParseWorkspace(cmd, spec.base ++ "_")) |ws| return spec.make(ws);
    }
    // The fallback is exec so any shell command can be bound, but a bare word
    // resembling a built-in action is almost always a typo, and running it as
    // an exec (which fails or does nothing) hides the mistake, so warn.
    if (looksLikeActionWord(cmd))
        debug.warn("Unrecognized action '{s}': running it as an exec command: " ++
            "check the spelling (action names are matched exactly)", .{cmd});
    // Never let an unresolved `{...}` placeholder reach the shell verbatim.
    if (hasPlaceholderFragment(cmd))
        debug.warn("Action '{s}' still contains a '{{...}}' placeholder; executing it verbatim", .{cmd});
    return .{ .exec = try allocator.dupe(u8, cmd) };
}

/// Canonical startup/reload entry point: load, validate.
///
/// Note: keybinding resolution (keysym -> keycode + dispatch map) is an input
/// concern and happens separately via `input.buildKeybinds` once the config is
/// live; see `input/keybind.zig`. DPI-scaled bar metrics are derived by the
/// bar itself (see bar/metrics.zig) rather than stored on the config.
pub fn load(allocator: std.mem.Allocator) !types.Config {
    var source: DefaultSource = .fallback;
    var cfg = loadConfigDefault(allocator, &source) catch |err| switch (err) {
        // A malformed user config at BOOT falls back to the embedded
        // config (the WM must still start). On reload the parse error
        // propagates instead, so the live config is kept.
        error.ConfigParseFailed => blk: {
            debug.warn("Config parse error at startup; using the embedded fallback", .{});
            break :blk try loadFallbackConfig(allocator);
        },
        else => return err,
    };
    errdefer cfg.deinit(allocator);
    try validate(&cfg);
    // A successful boot config becomes the re-exec hand-off snapshot (binary-
    // only reload). Guarded to a valid config so a parse-error fallback never
    // overwrites the previous good snapshot.
    refreshSnapshot(allocator);
    return cfg;
}

/// Canonicalizes the layout-name aliases accepted from config: "master-stack"
/// and "master_stack" (any case) fold onto the registry module's canonical
/// name "master". Every config-sourced layout name passes through here so
/// downstream resolution (engine.layoutByName,
/// which is exact-on-canonical) needs no alias handling. Returns `name`
/// unchanged otherwise; never allocates, and the returned slice aliases the
/// input whenever it is not the canonical literal.
pub fn canonicalLayoutName(name: []const u8) []const u8 {
    if (std.ascii.eqlIgnoreCase(name, "master-stack") or
        std.ascii.eqlIgnoreCase(name, "master_stack"))
        return types.canon_master_layout;
    return name;
}

/// Tiling's NON-scalar structures: the layouts array (cycle order +
/// per-workspace overrides), per-layout variant preferences, and
/// master-stack counts. Every tiling SCALAR ([tiling] flags, aesthetics,
/// master trio) is driven by schema.applyAll; like parseTiling always did,
/// all of it stays gated on the [tiling] section existing.
fn parseTilingStructures(
    allocator: std.mem.Allocator,
    doc: *parser.Document,
    cfg: *types.Config,
) !void {
    const section = doc.getSection(types.section_tiling) orelse return;
    types.freeStrings(&cfg.tiling.layouts, allocator, types.keep_capacity);
    cfg.tiling.workspace_layout_overrides.clearRetainingCapacity();
    types.freeStringMap(&cfg.tiling.variants, allocator, types.keep_capacity);
    // Single-layout path clears the getDefaultConfig default; the "layout"
    // fallback is (types.TilingConfig{}).layout, NOT cfg.tiling.layout (which
    // aliases layouts.items[0], freed below, so using it would read freed
    // memory when the key is absent).
    if (section.getAs([]const parser.Value, "layouts")) |arr| try parseLayoutsArray(allocator, arr, cfg) else {
        const layout_str = schema.getInRange([]const u8, section, "layout", types.canon_master_layout, null, null);
        try cfg.tiling.layouts.append(allocator, try allocator.dupe(u8, canonicalLayoutName(layout_str)));
    }
    if (cfg.tiling.layouts.items.len > 0) cfg.tiling.layout = cfg.tiling.layouts.items[0];
    try parseTilingLayoutSubtables(allocator, doc, cfg);
}

/// The flat `[tiling] master_variant/monocle_variant/grid_variant` keys
/// map onto their canonical layout names.
const flat_variant_keys = [_]struct { key: []const u8, canon: []const u8 }{
    .{ .key = "master_variant", .canon = types.canon_master_layout },
    .{ .key = "monocle_variant", .canon = "monocle" },
    .{ .key = "grid_variant", .canon = "grid" },
};

/// Stores `value` into tiling.variants under canonical key `canon`, duping
/// both so the map owns its storage independent of the parsed document (which
/// is freed after buildConfigFromDoc). Last override wins: any prior value
/// for the same key is freed first.
fn setTilingVariant(
    allocator: std.mem.Allocator,
    cfg: *types.Config,
    canon: []const u8,
    value: []const u8,
) !void {
    if (cfg.tiling.variants.fetchRemove(canon)) |kv| {
        allocator.free(kv.key);
        allocator.free(kv.value);
    }
    const key = try allocator.dupe(u8, canon);
    errdefer allocator.free(key);
    const val = try allocator.dupe(u8, value);
    try cfg.tiling.variants.put(allocator, key, val);
}

/// The `[tiling.layouts.*]` sub-table family, scanned in one pass: a bare
/// `[tiling.layouts.<name>]` table carries a per-layout `variants` string; a
/// `[tiling.layouts.<name>.counts]` one carries per-workspace master-count
/// overrides (workspace_number (1-based) = count; only meaningful with
/// global_layout = false, and only the master family can carry counts). Keys
/// canonicalize so master alias spellings resolve the same table; the flat
/// `[tiling] *_variant` keys feed the map too, and no validity check happens
/// on variant strings (layout modules own their meaning at seed time).
fn parseTilingLayoutSubtables(
    allocator: std.mem.Allocator,
    doc: *parser.Document,
    cfg: *types.Config,
) !void {
    if (doc.getSection(types.section_tiling)) |sec| for (flat_variant_keys) |fk|
        if (sec.getAs([]const u8, fk.key)) |v| try setTilingVariant(allocator, cfg, fk.canon, v);

    const prefix = types.section_prefix_tiling_layouts;
    const suffix = ".counts";
    var iter = doc.sections.iterator();
    while (iter.next()) |entry| {
        const sec_name = entry.key_ptr.*;
        if (!std.mem.startsWith(u8, sec_name, prefix)) continue;
        // Only direct "<prefix><name>[.counts]" tables qualify (no deeper
        // nesting); the counts table is master-family only, and its keys are
        // 1-based workspace numbers -> in-[0,max_master_count] master counts.
        const tail = sec_name[prefix.len..];
        if (std.mem.endsWith(u8, tail, suffix)) {
            const seg = tail[0 .. tail.len - suffix.len];
            if (std.mem.eql(u8, canonicalLayoutName(seg), types.canon_master_layout)) {
                const counts_sec = entry.value_ptr;
                cfg.tiling.workspace_master_count_overrides.clearRetainingCapacity();
                var inner = counts_sec.orderedIterator();
                while (inner.next()) |p| {
                    counts_sec.markConsumed(p.key);
                    if (tryParseWsToken(p.key, constants.max_workspaces, "master-stack.counts: invalid workspace key '{s}', skipping", .{p.key})) |ws_1based| {
                        const count_val = p.value.asScalar(i64) orelse {
                            debug.warn("master-stack.counts: non-integer count for workspace {}, skipping", .{ws_1based});
                            continue;
                        };
                        if (count_val < 0 or count_val > max_master_count)
                            debug.warn("master-stack.counts: count {} for workspace {} out of range [0,{d}], skipping", .{ count_val, ws_1based, max_master_count })
                        else
                            try cfg.tiling.workspace_master_count_overrides.append(allocator, .{
                                .workspace_idx = ids.WorkspaceId.fromIndex(@intCast(ws_1based - 1)),
                                .count = @intCast(count_val),
                            });
                    }
                }
            }
        } else if (std.mem.indexOfScalar(u8, tail, '.') == null) {
            // Direct "<prefix><name>" keys canonicalize so master alias
            // spellings resolve the same variant entry.
            if (entry.value_ptr.getAs([]const u8, "variants")) |v|
                try setTilingVariant(allocator, cfg, canonicalLayoutName(tail), v);
        }
    }
}

fn isWorkspaceList(s: []const u8) bool {
    if (s.len == 0) return false;
    var has_digit = false;
    for (s) |c| {
        if (std.ascii.isDigit(c)) {
            has_digit = true;
            continue;
        }
        if (c != ',' and c != ' ') return false;
    }
    return has_digit;
}

/// Known layout-name spellings, used ONLY to disambiguate the `layouts`
/// array grammar at parse time: a following token that names a layout starts
/// a new group rather than being consumed as a variants word. This is
/// grammar, not an authoritative registry — layout names resolve to
/// `tiling_modules` registry indices at seed time (engine.layoutByName), and
/// unknown names pass through so third-party addon layouts keep working.
const layout_name_grammar = std.StaticStringMap(void).initComptime(.{
    .{ "master", {} },  .{ "master-stack", {} }, .{ "master_stack", {} },
    .{ "monocle", {} }, .{ "grid", {} },         .{ "fibonacci", {} },
    .{ "leaf", {} },    .{ "scroll", {} },
});

/// Maximum bytes a config layout name may occupy after normalization. Longer
/// names are warned-and-skipped by the layouts-array and variants-word parses
/// below.
const max_layout_name = types.max_config_name;

/// Layout-name normalization shared by isLayoutName, parseLayoutVariant and
/// parseLayoutsArray: lowercases `name` into `buf`, returning null when it
/// exceeds `max_layout_name` bytes so the caller can warn-and-skip (mirroring
/// types.lowerSlice's caller-buffer semantics). Canonicalization of the
/// master-stack aliases stays with the storage sites, which need it.
fn normalizeLayoutName(buf: *[max_layout_name]u8, name: []const u8) ?[]const u8 {
    return types.lowerSlice(max_layout_name, buf, name);
}

/// Whether `name` is one of the known layout-name spellings (grammar test).
fn isLayoutName(name: []const u8) bool {
    var buf: [max_layout_name]u8 = undefined;
    const lowered = normalizeLayoutName(&buf, name) orelse return false;
    return layout_name_grammar.has(lowered);
}

/// Handles a layouts-array "variants word" for the given layout. The
/// value-string is stored into `cfg.tiling.variants` under the canonical
/// layout name (registry-driven: no typed per-layout enums, no enum fold), and
/// returned for per-workspace overrides (see parseWorkspaceListInto). Validity
/// of the string is checked against the active module's `variant_parse` at
/// seed time, not here.
fn parseLayoutVariant(
    allocator: std.mem.Allocator,
    cfg: *types.Config,
    layout_name: []const u8,
    variants_str: []const u8,
) !?[]const u8 {
    var buf: [max_layout_name]u8 = undefined;
    const lowered = normalizeLayoutName(&buf, layout_name) orelse {
        debug.warn("layouts array: layout name '{s}' too long to match against a " ++
            "variant type, ignoring variants '{s}'", .{ layout_name, variants_str });
        return null;
    };
    const canon = canonicalLayoutName(lowered);
    try setTilingVariant(allocator, cfg, canon, variants_str);
    return variants_str;
}

/// Parses a comma-separated workspace list string (e.g. "1,3,5") and appends
/// one WorkspaceLayoutOverride per valid workspace to `overrides`. Each
/// override owns a heap-dupe of the (possibly null) variant value-string, so
/// it outlives the parsed document.
fn parseWorkspaceListInto(
    allocator: std.mem.Allocator,
    ws_str: []const u8,
    layout_name: []const u8,
    layout_idx: u8,
    variant: ?[]const u8,
    overrides: *std.ArrayList(types.WorkspaceLayoutOverride),
) !void {
    var ws_iter = std.mem.splitScalar(u8, ws_str, ',');
    while (ws_iter.next()) |ws_tok| {
        const trimmed = std.mem.trim(u8, ws_tok, " \t");
        const ws_1based = tryParseWsToken(trimmed, constants.max_workspaces, "layouts array: invalid workspace number '{s}' for layout '{s}', skipping", .{ trimmed, layout_name }) orelse continue;
        const variant_copy: ?[]const u8 = if (variant) |v| try allocator.dupe(u8, v) else null;
        try overrides.append(allocator, .{ .workspace_idx = ids.WorkspaceId.fromIndex(@intCast(ws_1based - 1)), .layout_idx = layout_idx, .variant = variant_copy });
    }
}

/// Hard ceiling on the number of distinct layouts the cycle ring can hold.
/// The canonical value lives in the model (it bounds the u8 registry `kind`
/// index and WorkspaceLayoutOverride.layout_idx alike); the @intCast below
/// relies on it so a 256th entry can't trap in ReleaseFast. Names past the
/// cap warn-and-skip.
const max_layouts = model.max_layouts;

/// Parses the `layouts` TOML array. A layout name (any string; registry
/// resolution happens at seed time) starts a new group; the optional next
/// element is a variants word or a workspace list ("1,3,5"); a third may
/// follow as a workspace list when the second was a variants. Plain
/// single-name format ("master-stack") is fully backward-compatible. Names
/// are stored lowercased and de-duplicated case-insensitively; an overlong
/// name is skipped with a warning (resolution, not spelling, is authoritative).
/// The optional trailing group after an appended layout name: a workspace
/// list and/or a variants word, consumed in either order. A variants word
/// feeds both the per-layout map (`parseLayoutVariant`) and, when a
/// workspace list follows, the per-workspace overrides. `i` advanced past
/// every consumed token; null when the trailing token is another layout
/// name or nothing (a malformed variants word also yields null, leaving the
/// word for the caller's warn-and-skip).
fn parseLayoutTrailing(
    allocator: std.mem.Allocator,
    cfg: *types.Config,
    name_lower: []const u8,
    arr: []const parser.Value,
    i: *usize,
) !?struct { variants: ?[]const u8, ws_list: ?[]const u8 } {
    if (i.* + 1 >= arr.len) return null;
    const peek = arr[i.* + 1].asScalar([]const u8) orelse return null;
    if (isWorkspaceList(peek)) {
        i.* += 1;
        return .{ .variants = null, .ws_list = peek };
    }
    if (isLayoutName(peek)) return null;
    const variants = (try parseLayoutVariant(allocator, cfg, name_lower, peek)) orelse return null;
    i.* += 1;
    if (i.* + 1 < arr.len) {
        if (arr[i.* + 1].asScalar([]const u8)) |peek2| {
            if (isWorkspaceList(peek2)) {
                i.* += 1;
                return .{ .variants = variants, .ws_list = peek2 };
            }
        }
    }
    return .{ .variants = variants, .ws_list = null };
}

fn parseLayoutsArray(
    allocator: std.mem.Allocator,
    arr: []const parser.Value,
    cfg: *types.Config,
) !void {
    var i: usize = 0;
    while (i < arr.len) : (i += 1) {
        const raw_name = arr[i].asScalar([]const u8) orelse {
            debug.warn("layouts array: expected a string at index {}, skipping", .{i});
            continue;
        };
        var name_lower_buf: [max_layout_name]u8 = undefined;
        const name_lower = normalizeLayoutName(&name_lower_buf, raw_name) orelse {
            debug.warn("layouts array: layout name '{s}' at index {} is longer than the {d}-byte limit, skipping", .{ raw_name, i, max_layout_name });
            continue;
        };
        const is_dup = for (cfg.tiling.layouts.items) |existing| {
            if (std.mem.eql(u8, existing, name_lower)) break true;
        } else false;
        if (is_dup) {
            debug.warn("layouts array: duplicate layout '{s}' at index {}, skipping", .{ name_lower, i });
            continue;
        }
        // Stored canonical (config.canonicalLayoutName) so every downstream
        // resolution -- the global default, per-workspace overrides, and the
        // cycle ring -- sees the registry's canonical spelling. The cycle
        // ring is capped at max_layouts (the overrides index into it via a
        // u8), checked BEFORE the cast so an overlong config can't trap in
        // ReleaseFast.
        if (cfg.tiling.layouts.items.len >= max_layouts) {
            debug.warn("layouts array: maximum of {d} unique layouts reached, skipping '{s}'", .{ max_layouts, raw_name });
            continue;
        }
        const layout_idx: u8 = @intCast(cfg.tiling.layouts.items.len);
        try cfg.tiling.layouts.append(allocator, try allocator.dupe(u8, canonicalLayoutName(name_lower)));

        // Optional trailing group: a workspace list and/or variants word.
        if (try parseLayoutTrailing(allocator, cfg, name_lower, arr, &i)) |trail| {
            if (trail.ws_list) |ws_str| {
                try parseWorkspaceListInto(allocator, ws_str, name_lower, layout_idx, trail.variants, &cfg.tiling.workspace_layout_overrides);
            }
        }
    }
}

/// `appendDupedStrings`'s comptime `warn` argument meanings: the bar segment
/// list warns on a stray non-string entry (a typo should be called out), the
/// fonts list silently ignores it.
const warn_bad_segment_entries = true;
const ignore_bad_font_entries = false;

/// Dupe-appends every string element of `items` into `dst`. Non-string
/// entries are skipped; with `warn` set they also surface a warning (the bar
/// segment list, where a typo should be called out, vs. the fonts list, where
/// a stray non-string is simply ignored).
fn appendDupedStrings(
    comptime warn: bool,
    allocator: std.mem.Allocator,
    items: []const parser.Value,
    dst: *std.ArrayList([]const u8),
) !void {
    for (items) |item| {
        if (item.asScalar([]const u8)) |s| {
            try dst.append(allocator, try allocator.dupe(u8, s));
        } else if (warn) {
            debug.warn("Non-string entry in bar segment list, skipping", .{});
        }
    }
}

/// Bar's NON-scalar structures: fonts, indicator glyph mirroring, workspace
/// icons, and the bar columns. Every bar SCALAR (flags, scalables, height,
/// colors incl. the [bar.properties] fallback chains, strings, enums, ratios)
/// is driven by schema.applyAll; like parseBar always did, everything here
/// stays gated on the [bar] section existing.
fn parseBar(allocator: std.mem.Allocator, doc: *parser.Document, cfg: *types.Config) !void {
    const section = doc.getSection(types.section_bar) orelse return;
    if (section.getAs([]const parser.Value, "fonts")) |arr| {
        types.freeStrings(&cfg.bar.fonts, allocator, types.keep_capacity);
        try appendDupedStrings(ignore_bad_font_entries, allocator, arr, &cfg.bar.fonts);
        debug.info("Loaded {} fonts for bar", .{cfg.bar.fonts.items.len});
    }
    // indicator_focused/unfocused: if only one is set, the other mirrors it.
    // A pair interaction, so it stays bespoke rather than joining the table.
    const raw_focused = section.getAs([]const u8, "indicator_focused");
    const raw_unfocused = section.getAs([]const u8, "indicator_unfocused");
    const focused_val = raw_focused orelse raw_unfocused;
    const unfocused_val = raw_unfocused orelse raw_focused;
    if (focused_val) |v| try schema.assignStr(allocator, &cfg.bar.indicator_focused, v);
    if (unfocused_val) |v| try schema.assignStr(allocator, &cfg.bar.indicator_unfocused, v);
    try parseWorkspaceIcons(allocator, section, cfg);
    try parseBarLayout(allocator, doc, cfg);
}

fn padWorkspaceIcons(allocator: std.mem.Allocator, cfg: *types.Config) !void {
    while (cfg.bar.workspace_icons.items.len < cfg.workspaces.count) {
        try cfg.bar.workspace_icons.append(allocator, try dupeNum(allocator, cfg.bar.workspace_icons.items.len + 1));
    }
}

/// Formats integer `n` as decimal and dupes it to a string, the "int ->
/// string icon" step shared by parseWorkspaceIcons and padWorkspaceIcons.
fn dupeNum(allocator: std.mem.Allocator, n: anytype) ![]u8 {
    return std.fmt.allocPrint(allocator, "{}", .{n});
}

fn parseWorkspaceIcons(
    allocator: std.mem.Allocator,
    section: *parser.Section,
    cfg: *types.Config,
) !void {
    types.freeStrings(&cfg.bar.workspace_icons, allocator, types.keep_capacity);
    if (section.getAs([]const parser.Value, "icons")) |arr| {
        for (arr) |item| {
            if (item.asScalar([]const u8)) |s|
                try cfg.bar.workspace_icons.append(allocator, try allocator.dupe(u8, s));
            if (item.asScalar(i64)) |n|
                try cfg.bar.workspace_icons.append(allocator, try dupeNum(allocator, n));
        }
    } else if (section.getAs([]const u8, "icons")) |str| {
        var ch_buf: [1]u8 = undefined;
        for (str) |ch| {
            ch_buf[0] = ch;
            try cfg.bar.workspace_icons.append(allocator, try allocator.dupe(u8, &ch_buf));
        }
    }

    try padWorkspaceIcons(allocator, cfg);
}

fn parseBarLayout(allocator: std.mem.Allocator, doc: *parser.Document, cfg: *types.Config) !void {
    types.freeBarLayouts(&cfg.bar.layout, allocator, types.keep_capacity);
    const max_anchor_name_len = comptime blk: {
        var longest: usize = 0;
        for (bar_anchors) |a| longest = @max(longest, a.name.len);
        break :blk longest;
    };
    var section_buf: [types.section_prefix_bar_layout.len + max_anchor_name_len]u8 = undefined;
    for (bar_anchors) |a| {
        const layout_section = doc.getSection(std.fmt.bufPrint(&section_buf, "{s}{s}", .{ types.section_prefix_bar_layout, a.name }) catch unreachable) orelse continue;
        var bar_layout = types.BarLayout{ .position = a.position, .segments = .empty };
        if (layout_section.getAs([]const parser.Value, "segments")) |seg_arr|
            try appendDupedStrings(warn_bad_segment_entries, allocator, seg_arr, &bar_layout.segments);
        if (bar_layout.segments.items.len > 0) try cfg.bar.layout.append(allocator, bar_layout) else bar_layout.deinit(allocator);
    }

    if (cfg.bar.layout.items.len == 0) try initDefaultBarLayout(allocator, cfg);
}

fn parseRules(allocator: std.mem.Allocator, doc: *parser.Document, cfg: *types.Config) !void {
    // [workspace.rules]: key is either a class name (value = ws int) or a
    // workspace number (value = class array). Both directions call addRule.
    if (doc.getSection(types.section_workspace_rules)) |s| try parseWorkspaceRuleSection(allocator, cfg, s);
    // [rules]: simple class -> workspace mapping (key = class, value = ws int).
    if (doc.getSection(types.section_rules)) |s| {
        var iter = s.orderedIterator();
        while (iter.next()) |entry| {
            s.markConsumed(entry.key);
            try tryAddClassRule(allocator, cfg, entry.key, entry.value);
        }
    }
    try parseNumberedRuleSections(allocator, doc, cfg);
}

/// Processes numbered rule sub-sections (e.g. [workspace.rules.1], [rules.3]).
/// Each section's keys are class names; the section name suffix is the workspace
/// number. Shared by both "workspace.rules.*" and "rules.*" prefixes.
fn parseNumberedRuleSections(
    allocator: std.mem.Allocator,
    doc: *parser.Document,
    cfg: *types.Config,
) !void {
    var section_iter = doc.sections.iterator();
    while (section_iter.next()) |entry| {
        const name = entry.key_ptr.*;
        const suffix_len = if (std.mem.startsWith(u8, name, types.section_prefix_workspace_rules)) types.section_prefix_workspace_rules.len else if (std.mem.startsWith(u8, name, types.section_prefix_rules)) types.section_prefix_rules.len else continue;
        const ws_num = parseWsToken(name[suffix_len..]) orelse {
            debug.warn("Section [{s}]: workspace suffix is not a number, skipping", .{name});
            continue;
        };
        if (!checkWorkspaceBound(ws_num, name, cfg.workspaces.count)) continue;
        var iter = entry.value_ptr.orderedIterator();
        while (iter.next()) |class_entry| {
            entry.value_ptr.markConsumed(class_entry.key);
            try addRule(allocator, cfg, class_entry.key, ws_num);
        }
    }
}

/// Parses `value` as a workspace int or the "float" marker and, if valid, adds
/// a rule mapping `class_name` accordingly. Shared by the class-keyed
/// direction of [workspace.rules] and by [rules], which are always class-keyed.
fn tryAddClassRule(allocator: std.mem.Allocator, cfg: *types.Config, class_name: []const u8, value: parser.Value) !void {
    if (value.asScalar([]const u8)) |s| {
        if (std.mem.eql(u8, s, "float")) {
            try addRule(allocator, cfg, class_name, null);
            return;
        }
        debug.warn("Rule for '{s}' has string value '{s}', only integer or \"float\" supported, skipping", .{ class_name, s });
        return;
    }
    const ws_num = value.asScalar(i64) orelse {
        debug.warn("Rule for '{s}' has non-integer value, skipping", .{class_name});
        return;
    };
    if (ws_num < 1)
        debug.warn("Rule workspace {d} for '{s}' below minimum 1, skipping", .{ ws_num, class_name })
    else if (checkWorkspaceBound(@intCast(ws_num), class_name, cfg.workspaces.count))
        try addRule(allocator, cfg, class_name, @as(usize, @intCast(ws_num)));
}

/// Length of the leading run of ASCII digits in `s` (0 when it starts with
/// any other character).
fn countLeadingDigits(s: []const u8) usize {
    var n: usize = 0;
    while (n < s.len and std.ascii.isDigit(s[n])) n += 1;
    return n;
}

/// Handle the [workspace.rules] section where the key may be a class name
/// (integer value -> workspace) or a workspace number (array value -> classes).
/// Distinguish by the LEADING NUMERIC RUN, not by an all-key parseInt: a
/// numeric-prefixed class like "12x" is parsed as a probability-1 class rule
/// (warned), never silently coerced by a catch; only all-digit keys are
/// workspace numbers.
fn parseWorkspaceRuleSection(
    allocator: std.mem.Allocator,
    cfg: *types.Config,
    rules_section: *parser.Section,
) !void {
    var iter = rules_section.orderedIterator();
    while (iter.next()) |entry| {
        rules_section.markConsumed(entry.key);
        const digit_run = countLeadingDigits(entry.key);
        if (digit_run == 0) {
            try tryAddClassRule(allocator, cfg, entry.key, entry.value);
            continue;
        }
        if (digit_run != entry.key.len) {
            debug.warn("[workspace.rules]: key '{s}' starts with a digit but isn't a workspace number, treating it as a class name", .{entry.key});
            try tryAddClassRule(allocator, cfg, entry.key, entry.value);
            continue;
        }
        // All-digits: an oversized value is a genuine parse error (never a
        // plausible workspace number), so warn-and-skip rather than coerce
        // into a class rule.
        const ws_num = std.fmt.parseInt(usize, entry.key, 10) catch {
            debug.warn("[workspace.rules]: workspace number '{s}' is too large, skipping", .{entry.key});
            continue;
        };
        if (!checkWorkspaceBound(ws_num, entry.key, cfg.workspaces.count)) continue;
        if (entry.value.asArray()) |arr|
            for (arr) |item|
                if (item.asScalar([]const u8)) |class_name| try addRule(allocator, cfg, class_name, ws_num);
    }
}

// ── Per-subsystem change detection ──────────────────────────────────
// Content-based comparisons for handleConfigReload so it can skip
// teardown/rebuild work when a subsystem didn't actually change (e.g. a bar
// color tweak should not regrab keybindings). std containers are compared
// through their logical items/entries -- never their internal capacity/
// bookkeeping bytes, which would make a reload comparison depend on append
// history, and never by pointer identity.

/// Bar layouts are compared logically; the segments ArrayList's capacity is
/// bookkeeping that append history must never make read as different.
fn eqlBarLayouts(a: []const types.BarLayout, b: []const types.BarLayout) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (x.position != y.position) return false;
        if (!std.meta.eql(x.segments.items, y.segments.items)) return false;
    }
    return true;
}

/// Unordered string-keyed map comparison, shared by the variant map and the
/// segment-color maps: append history must never make two identical maps read
/// as different, and `std.meta.eql` on StringHashMapUnmanaged would trip on
/// internal bookkeeping. Values compare via `std.meta.eql` (slice or scalar).
fn eqlStringMap(comptime V: type, a: *const std.StringHashMapUnmanaged(V), b: *const std.StringHashMapUnmanaged(V)) bool {
    if (a.count() != b.count()) return false;
    var it = a.iterator();
    while (it.next()) |entry| {
        const v = b.get(entry.key_ptr.*) orelse return false;
        if (!std.meta.eql(entry.value_ptr.*, v)) return false;
    }
    return true;
}

pub const ConfigChanges = struct {
    bar: bool = false,
    tiling: bool = false,
    keys: bool = false,
};

/// The three detectors below compare per-subsystem content summaries. They
/// deliberately stay hand-maintained field lists rather than being derived
/// from `schema.knobs` (which declares every scalar knob once):
///
///   * keysChanged is entirely bespoke: keybindings/mouse_bindings have no
///     knob entries, and their equality is pair-based (modifiers + keysym /
///     button, action deliberately excluded) -- not field equality.
///   * bar/tiling carry non-knob content anyway (fonts, workspace icons,
///     per-segment color overrides, layout/override tables, workspace rules)
///     that a knob scan could not see, so a derivation would replace these
///     plain scalar comparisons with reflection plus a second hand-built
///     overlay -- more machinery for a residual list.
///
/// The per-shape comparators were already consolidated (std.meta.eql for
/// unit/map/rule/string/override shapes, eqlStringMap and eqlBarLayouts for
/// the two compound shapes), which keeps the lists drift-resistant without a
/// reflection layer.
/// Bar-subsystem content: every field of BarConfig compared logically
/// (arrays by items, optionals by inner value, strings by contents).
fn barChanged(old: *const types.BarConfig, new: *const types.BarConfig) bool {
    return old.enabled != new.enabled or
        old.vim_mode != new.vim_mode or
        old.bar_position != new.bar_position or
        !std.meta.eql(old.height, new.height) or
        !std.meta.eql(old.fonts.items, new.fonts.items) or
        !std.meta.eql(old.font_size, new.font_size) or
        !std.meta.eql(old.spacing, new.spacing) or
        old.bg != new.bg or
        old.fg != new.fg or
        old.selected_bg != new.selected_bg or
        old.selected_fg != new.selected_fg or
        old.primary_color != new.primary_color or
        old.secondary_color != new.secondary_color or
        old.alternative_color != new.alternative_color or
        old.text_color != new.text_color or
        old.title_accent_color != new.title_accent_color or
        old.title_unfocused_accent != new.title_unfocused_accent or
        old.title_minimized_accent != new.title_minimized_accent or
        !std.meta.eql(old.workspace_icons.items, new.workspace_icons.items) or
        !std.meta.eql(old.indicator_size, new.indicator_size) or
        !std.meta.eql(old.workspace_tag_width, new.workspace_tag_width) or
        old.indicator_location != new.indicator_location or
        old.indicator_padding != new.indicator_padding or
        !std.meta.eql(old.indicator_focused, new.indicator_focused) or
        !std.meta.eql(old.indicator_unfocused, new.indicator_unfocused) or
        old.indicator_color != new.indicator_color or
        !std.meta.eql(old.clock_format, new.clock_format) or
        !std.meta.eql(old.volume_format, new.volume_format) or
        !std.meta.eql(old.volume_muted_format, new.volume_muted_format) or
        !std.meta.eql(old.brightness_format, new.brightness_format) or
        !std.meta.eql(old.brightness_device, new.brightness_device) or
        old.carousel_enabled != new.carousel_enabled or
        old.carousel_speed_px_s != new.carousel_speed_px_s or
        old.drun_bg != new.drun_bg or
        old.drun_fg != new.drun_fg or
        old.drun_prompt_color != new.drun_prompt_color or
        !std.meta.eql(old.drun_prompt, new.drun_prompt) or
        !eqlStringMap(types.Color, &old.segment_fg, &new.segment_fg) or
        !eqlStringMap(types.Color, &old.segment_value_fg, &new.segment_value_fg) or
        !eqlStringMap(types.SegmentProps, &old.segment_props, &new.segment_props) or
        !eqlBarLayouts(old.layout.items, new.layout.items) or
        old.transparency != new.transparency;
}

/// Tiling-subsystem content: TilingConfig, plus the workspaces/fullscreen/
/// drag/snap gates the reload handler rebuilds together with tiling state.
fn tilingChanged(old: *const types.Config, new: *const types.Config) bool {
    return old.tiling.enabled != new.tiling.enabled or
        !std.meta.eql(old.tiling.layout, new.tiling.layout) or
        !std.meta.eql(old.tiling.layouts.items, new.tiling.layouts.items) or
        old.tiling.master_side != new.tiling.master_side or
        !std.meta.eql(old.tiling.master_width, new.tiling.master_width) or
        old.tiling.master_count != new.tiling.master_count or
        !std.meta.eql(old.tiling.gap_width, new.tiling.gap_width) or
        !std.meta.eql(old.tiling.border_width, new.tiling.border_width) or
        old.tiling.border_focused != new.tiling.border_focused or
        old.tiling.border_unfocused != new.tiling.border_unfocused or
        old.tiling.min_window_dim != new.tiling.min_window_dim or
        !eqlStringMap([]const u8, &old.tiling.variants, &new.tiling.variants) or
        !std.meta.eql(old.tiling.workspace_layout_overrides.items, new.tiling.workspace_layout_overrides.items) or
        !std.meta.eql(old.tiling.workspace_master_count_overrides.items, new.tiling.workspace_master_count_overrides.items) or
        old.tiling.global_layout != new.tiling.global_layout or
        old.workspaces.enabled != new.workspaces.enabled or
        old.workspaces.count != new.workspaces.count or
        !std.meta.eql(old.workspaces.rules.items, new.workspaces.rules.items) or
        old.fullscreen_enabled != new.fullscreen_enabled or
        old.drag_enabled != new.drag_enabled or
        !std.meta.eql(old.snap_distance, new.snap_distance);
}

/// Keys-subsystem content: the pair layout — (modifiers, keysym) per keyboard
/// binding and (modifiers, button) per mouse binding. Action is deliberately
/// excluded: two keybinds that differ only in their action (e.g. a changed
/// command string) still share a pair, so no regrab is needed.
fn keysChanged(old: *const types.Config, new: *const types.Config) bool {
    if (old.keybindings.items.len != new.keybindings.items.len) return true;
    for (old.keybindings.items, new.keybindings.items) |a, b| {
        if (a.modifiers != b.modifiers or a.keysym != b.keysym) return true;
    }
    if (old.mouse_bindings.items.len != new.mouse_bindings.items.len) return true;
    for (old.mouse_bindings.items, new.mouse_bindings.items) |a, b| {
        if (a.modifiers != b.modifiers or a.button != b.button) return true;
    }
    return false;
}

/// Compares old and new configs at a coarse per-subsystem level, returning
/// which subsystems changed. Gate each reload step on its flag so, e.g.,
/// a color tweak doesn't regrab keybindings.
pub fn detectChanges(old: *const types.Config, new: *const types.Config) ConfigChanges {
    return .{
        .bar = barChanged(&old.bar, &new.bar),
        .tiling = tilingChanged(old, new),
        .keys = keysChanged(old, new),
    };
}
