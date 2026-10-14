//! Configuration interpreter
//! Loads, parses, and validates TOML config files.

const std = @import("std");
const fallback = @import("fallback");
const log = @import("log");
const parser = @import("parser");
const composed = @import("composed");
const types = @import("types");
const layout_names = @import("layout_names");
const snapshot_mod = @import("snapshot");
const discover = @import("discover");

// Re-exports: `config` stays the single import surface for callers
// (main.zig, events.zig, session.zig, the tests); the re-exports below
// are where the code now lives.
pub const canonicalLayoutName = layout_names.canonicalLayoutName;
pub const isLayoutName = layout_names.isLayoutName;
pub const layout_name_grammar = layout_names.layout_name_grammar;
pub const DefaultSource = snapshot_mod.DefaultSource;
pub const deinitGoodSource = snapshot_mod.deinitGoodSource;
pub const reexecSnapshotPathZ = snapshot_mod.reexecSnapshotPathZ;
pub const refreshSnapshot = snapshot_mod.refreshSnapshot;
pub const readFileAlloc = discover.readFileAlloc;
pub const max_file_bytes = discover.max_file_bytes;
pub const max_config_files = discover.max_config_files;

/// Longest section name a mis-case warning must lower (bounded helper buffer;
/// real-world section names are far shorter, this just caps a pathological
/// line's cost).
const max_section_name_bytes = 64;

/// Loads and merges all `*.toml` files directly inside `dir_path` (alphabetical order;
/// subdirectories only via explicit `include`).  Later files win on scalar conflicts;
/// arrays accumulate (enforced by the parser's Value getters: scalar reads resolve to
/// the last declaration, array reads see every one).
fn loadConfigFromDir(allocator: std.mem.Allocator, dir_path: []const u8) !composed.Config {
    var names = try discover.discoverDirNames(allocator, dir_path);
    defer {
        for (names.items) |n| allocator.free(n);
        names.deinit(allocator);
    }
    const cfg = try parseAndBuild(allocator, discover.parseDirDoc, discover.DirInput{ .dir_path = dir_path, .names = names.items });
    log.info("Loaded config from dir: {s} ({} file(s))", .{ dir_path, names.items.len });
    return cfg;
}

/// Loads config in priority order: (1) ~/.config/hana/, (2) ./config/,
/// (3) ~/.config/hana/config.toml, (4) ./config.toml, (5) embedded fallback.
/// `source` receives where the config actually came from (user vs fallback),
/// so callers with different boot/reload semantics (see reload.handleConfigReload)
/// need no separate existence probe. `allow_pinned_snapshot` admits the one
/// boot-only win over that order: a re-exec successor (reload_hana,
/// restart.execNext) pinning HANA_CONFIG_DIR to the frozen last-good snapshot.
/// The in-place reload path MUST pass false -- HANA_CONFIG_DIR stays set for
/// the process lifetime after the first re-exec, so honoring it there would
/// re-read the frozen snapshot instead of the user's live config files, and
/// bind/theme edits would never hot-reload.
pub fn loadConfigDefault(allocator: std.mem.Allocator, source: *DefaultSource, allow_pinned_snapshot: bool) !composed.Config {
    const paths = try discover.searchPaths(allocator);
    defer paths.deinit(allocator);

    // A re-exec hand-off (reload_hana, restart.execNext) pins HANA_CONFIG_DIR
    // to the frozen last-good snapshot, so the successor boots an identical
    // config WITHOUT re-reading the live config tree. Any failure falls
    // through to the normal search (a broken snapshot must not silently swap
    // in the embedded fallback over an otherwise-fine user config).
    if (allow_pinned_snapshot) {
        if (std.c.getenv("HANA_CONFIG_DIR")) |env_z| {
            const env = std.mem.span(env_z);
            if (loadConfigFromDir(allocator, env)) |cfg| {
                snapshot_mod.rememberGoodSource(allocator, env, true);
                source.* = .user;
                return cfg;
            } else |err| switch (err) {
                error.FileNotFound, error.NotDir, error.ConfigParseFailed => {
                    log.warn("Re-exec config snapshot {s} unusable ({s}); falling back to the user's config", .{ env, @errorName(err) });
                },
                else => return err,
            }
        }
    }

    // Try directories first (they can hold several .toml files), then single
    // files. The order comes from `discover.search_order`; each tag resolves its path,
    // loader, provenance and wording in one switch, so a new location cannot
    // be added with a missing or mismatched field.
    inline for (discover.search_order) |loc| {
        const at: discover.SearchAttempt = switch (loc) {
            .xdg_dir => .{ .path = paths.xdg_dir, .load = loadConfigFromDir, .is_dir = true },
            .local_dir => .{ .path = paths.local_dir, .load = loadConfigFromDir, .is_dir = true },
            .xdg_file => .{ .path = paths.xdg_file, .load = loadConfig, .is_dir = false },
            .local_file => .{ .path = paths.local_file, .load = loadConfig, .is_dir = false },
        };
        // `loc` is comptime (inline for), so the log format stays comptime-known
        // -- which is why it is chosen from the tag rather than carried in
        // `at`, where the runtime path would make the whole struct runtime.
        const err_msg = switch (loc) {
            .xdg_dir, .local_dir => "Config load error from {s}: {}",
            .xdg_file, .local_file => "hana: config file '{s}' found but failed to load: {}; falling back",
        };
        // `orelse continue` would read better, but a labeled-`inline for` body
        // rejects it (comptime control flow in a runtime block); the explicit
        // `if` is the same thing and costs one line.
        if (try discover.tryLoadOrWarn(at.load, allocator, at.path, err_msg)) |cfg| {
            snapshot_mod.rememberGoodSource(allocator, at.path, at.is_dir);
            source.* = .user;
            return cfg;
        }
    }

    log.info("No config found, using fallback with auto-detection", .{});
    source.* = .fallback;
    return try loadFallbackConfig(allocator);
}

/// Reads, parses, and returns the config at `path` (single-file entry point).
pub fn loadConfig(allocator: std.mem.Allocator, path: []const u8) !composed.Config {
    const cfg = parseAndBuild(allocator, parseFileDoc, FileInput{ .path = path, .base_dir = std.fs.path.dirname(path) orelse "." }) catch |err| switch (err) {
        error.ConfigEmpty => {
            log.info("Empty config file: {s}, using fallback", .{path});
            return try loadFallbackConfig(allocator);
        },
        else => return err,
    };
    log.info("Loaded: {s}", .{path});
    return cfg;
}

/// Parse inputs for `parseFileDoc`: the single config file and its include
/// resolution base directory.
const FileInput = struct { path: []const u8, base_dir: []const u8 };

/// Parses one config file plus its `include`s into an arena document,
/// recording the file and every consumed include in `read` via the same
/// choke point as every other contributing file (discover.mergeAndRecord).
/// The read itself is NOT wrapped in tryParseTomlFile: a missing or
/// unreadable file must propagate its raw error so the search-order skip
/// (silent_missing) and reload's keep-live still see FileNotFound, not
/// had_errors. The count ceiling starts at zero here, so only the byte
/// ceiling (covered: one file <= max_file_bytes) can apply to this file;
/// its includes go through parseAndMerge, which checks the count too.
fn parseFileDoc(a: std.mem.Allocator, read: *discover.ReadSet, in: FileInput) !parser.Document {
    var merged = parser.Document.init(a);
    var parsed = try discover.parseTomlFile(a, in.path) orelse return error.ConfigEmpty;
    try discover.mergeAndRecord(a, &merged, read, &parsed.doc, parsed.bytes, in.path, "Merged: {s}");
    try discover.mergeIncludes(a, &merged, &parsed.doc, read, in.base_dir);
    return merged;
}

/// Parse inputs for `parseFallbackDoc`: the embedded fallback TOML text.
const FallbackInput = struct { toml: []const u8 };

/// Parses the embedded fallback TOML into an arena document. The fallback
/// lives in the binary, so it contributes no files to the snapshot.
fn parseFallbackDoc(a: std.mem.Allocator, read: *discover.ReadSet, in: FallbackInput) !parser.Document {
    _ = read;
    return try parser.parse(a, in.toml, "<embedded fallback>");
}

/// Shared tail of the config load pipelines: one load-scoped arena hosts the
/// parsed Document(s) (and their aliased file buffers) while `parse` fills a
/// document from the arena allocator; `buildConfigFromDoc` then dupes every
/// owned Config string from the backing `allocator` before the arena reset
/// reclaims the documents. `parse` also fills `read` with the config files it
/// consumed, which is republished into module state (see snapshot_mod.publishReadFiles)
/// because the re-exec snapshot needs it after this arena dies.
fn parseAndBuild(
    allocator: std.mem.Allocator,
    comptime parse: anytype,
    in: anytype,
) !composed.Config {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var read: discover.ReadSet = .{};
    var doc = try parse(a, &read, in);
    var cfg = try buildConfigFromDoc(allocator, &doc);
    snapshot_mod.publishReadFiles(read.paths.items) catch |err| {
        cfg.deinit(allocator);
        return err;
    };
    return cfg;
}

fn loadFallbackConfig(allocator: std.mem.Allocator) !composed.Config {
    // The embedded fallback is the FLOOR, not a dependency: if it is somehow
    // absent (a build that did not embed it, a truncated binary), returning a
    // boot-fatal error here made a missing convenience file take the WM down
    // with it. `composed.parse` on an EMPTY document is the same defaults the
    // embedded TOML encodes -- every fragment self-seeds its owned non-scalars
    // and its scalars come from field initializers -- so the floor holds even
    // with nothing embedded. The only thing lost is the fallback's own tuned
    // values, and that is reported rather than hidden.
    const fallback_toml = fallback.getFallbackToml() orelse {
        log.warn("Embedded fallback config missing; using the code defaults instead", .{});
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        var empty = parser.Document.init(arena.allocator());
        return try composed.parse(allocator, &empty);
    };
    // The auto_terminal substitution happens in parseAction, so the embedded
    // fallback and a user config go through the identical path.
    const cfg = try parseAndBuild(allocator, parseFallbackDoc, FallbackInput{ .toml = fallback_toml });

    log.info("Loaded fallback configuration with auto-detection", .{});
    return cfg;
}

fn buildConfigFromDoc(allocator: std.mem.Allocator, doc: *parser.Document) !composed.Config {
    // A broken TOML (warn-and-skipped line, or a whole file skipped during
    // the merge) must not silently produce a partially-applied config: fail
    // the load so reload keeps the live config. Boot falls through to
    // the embedded fallback via loadConfigDefault's warn-and-skip.
    if (doc.had_errors) return error.ConfigParseFailed;
    // The composed facade assembles core + every discovered fragment (each
    // self-seeding its defaults); a fragment's `validate` may fail the load
    // with error.InvalidConfig, which loadFor and isFatalLoadError treat like
    // a parse failure (boot falls back; reload keeps live). The lint tail
    // below is read-only, so it runs on the finished document either way.
    const cfg = try composed.parse(allocator, doc);
    lintDocument(doc);
    return cfg;
}

/// The load's diagnostics tail: every read-only observation about the finished
/// document, in reading order -- mis-cased known section headers (a case-only
/// miss silently drops the section), section families whose parent is missing
/// (their knobs parse but do nothing), then every key no parse function claimed
/// (almost always a typo, named with its source line). None of the three
/// depends on parse results, so they run together here instead of being
/// sprinkled across the parse steps.
fn lintDocument(doc: *parser.Document) void {
    warnMisCasedSections(doc);
    warnInertSectionFamilies(doc);
    doc.root.warnUnconsumed("<root>");
    var iter = doc.sections.iterator();
    while (iter.next()) |entry|
        entry.value_ptr.warnUnconsumed(entry.key_ptr.*);
}

/// Known section names hana recognizes (case-sensitively) at their exact
/// spelling. A section header that differs from one of these only by case is
/// almost certainly a typo that silently drops the whole section.
const known_sections = std.StaticStringMap(void).initComptime(.{
    .{ types.section_binds, {} },                                   .{ types.section_binds_alt, {} },
    .{ types.section_workspace_rules, {} },                         .{ types.section_rules, {} },
    .{ types.section_drag, {} },                                    .{ types.section_fullscreen, {} },
    .{ types.section_display, {} },                                 .{ types.section_tiling, {} },
    .{ types.section_workspaces, {} },                              .{ types.section_bar, {} },
    .{ types.section_bar_properties, {} },                          .{ types.section_prefix_bar_layout ++ "left", {} },
    .{ types.section_prefix_bar_layout ++ "center", {} },           .{ types.section_prefix_bar_layout ++ "right", {} },
    .{ types.section_bar_modules_workspaces, {} },                  .{ types.section_tiling_layouts_master_stack, {} },
    .{ types.section_prefix_tiling_layouts ++ "master_stack", {} },
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
            log.warn("Section [{s}] is mis-cased; hana recognizes [{s}], ignoring the section", .{ name, lowered });
            continue;
        }
        for (known_section_prefixes) |pfx| {
            if (name.len > pfx.len and std.ascii.startsWithIgnoreCase(name, pfx) and
                !std.mem.startsWith(u8, name, pfx))
            {
                log.warn("Section [{s}] is mis-cased; hana recognizes the [{s}...] family (all lowercase), ignoring", .{ name, pfx });
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
                log.warn("[tiling.*] sections present but bare [tiling] is missing; their knobs are inert", .{});
                break;
            }
        }
    }
    if (doc.getSection(types.section_bar) == null and doc.getSection(types.section_bar_properties) != null)
        log.warn("[bar.properties] present but [bar] is missing; its knobs are inert", .{});
}

/// Canonical startup entry point: load. Re-exec successors find
/// their pinned config snapshot via `loadConfigDefault(true)`; the in-place
/// reload path (reload.handleConfigReload) loads live configs itself instead.
///
/// Note: keybind resolution (keysym -> keycode + dispatch map) is an input
/// concern and happens separately via `keybinds.buildKeybinds` once the config
/// is live; see `core/input/keybinds.zig`. DPI-scaled bar metrics are derived by the
/// bar itself (see bar/metrics.zig) rather than stored on the config.
/// Domain invariants (master_width's ratio band) and the warn-only checks
/// (bar.font_size) live with their fragments -- `composed.parse` runs each
/// fragment's `validate` right after its `parse`, and error.InvalidConfig
/// degrades exactly like a parse failure (see `loadFor` / `isFatalLoadError`).
///
/// Loads the default config with every warn/err diagnostic CAPTURED into
/// `collector` instead of only reaching stderr, then throws the config away.
///
/// This is the whole of `hana --check-config`: a config problem the WM merely
/// warns about at boot is invisible to anyone not reading the log, and
/// "validate my hana.conf" is a question worth answering without an X server,
/// without spawning a window manager, and with an exit code a CI job can read.
/// It runs the REAL load path -- same search order, same fallback, same
/// warn-and-continue decisions -- so a check that passes means the config the
/// WM would actually take is the config that was checked.
///
/// The collector is installed here rather than passed down: see
/// `log.Collector`. Restored on every exit path, including the error path, so
/// a failed check cannot leave later diagnostics pointing at a dead bag.
pub fn checkConfig(allocator: std.mem.Allocator, collector: *log.Collector) !void {
    const saved = log.collector;
    log.collector = collector;
    defer log.collector = saved;
    // `snapshot = false`: a check must not WRITE the re-exec hand-off state.
    // It runs the same load, but leaving a snapshot behind would be a
    // validation run with a side effect -- and one that leaks by design, since
    // the snapshot path is intentionally kept alive for the execv environ.
    var cfg = try loadFor(allocator, false);
    cfg.deinit(allocator);
}

pub fn load(allocator: std.mem.Allocator) !composed.Config {
    return loadFor(allocator, true);
}

/// `load` with the one state-writing step made explicit. `snapshot` false is
/// for read-only callers (`checkConfig`), which want the identical load
/// decision -- same search order, same fallback, same warn-and-continue -- with
/// none of the writes.
fn loadFor(allocator: std.mem.Allocator, snapshot: bool) !composed.Config {
    var source: DefaultSource = .fallback;
    // A user config that will not START is one the WM must not die on. A
    // parse error, a load ceiling, and a fragment's InvalidConfig all mean
    // "this config is not usable", so boot degrades the same way for all
    // three: the embedded fallback. (InvalidConfig used to be a separate
    // post-load `validate` step whose failure behaved differently from a
    // parse error for no defensible reason; it now fails inside
    // `composed.parse`, so the two classes share one path.)
    const cfg = loadConfigDefault(allocator, &source, true) catch |err| switch (err) {
        // On reload the same errors propagate instead, so the live config is
        // kept -- `isFatalLoadError` in discover.zig is the shared list.
        error.ConfigParseFailed, error.TooManyConfigFiles, error.TooManyConfigBytes, error.InvalidConfig => blk2: {
            log.warn("Unusable config at startup ({s}); using the embedded fallback", .{@errorName(err)});
            break :blk2 try loadFallbackConfig(allocator);
        },
        else => return err,
    };
    // A successful boot config becomes the re-exec hand-off snapshot (binary-
    // only reload). Guarded to a valid config so a parse-error or
    // validation-error fallback never overwrites the previous good snapshot
    // (both now reach here through the same path, see above).
    if (snapshot) refreshSnapshot(allocator);
    return cfg;
}

// ---------------------------------------------------------------------------
// Reload change detection (former persist/diff.zig, merged 2026-10-10):
// whether the key PAIR layout changed, so an unchanged reload can skip the
// regrab. Bar and tiling deliberately have NO detector -- their rebuilds run
// on every reload; a skip would leave borrowed state pointing at the box the
// swap is about to release, and the rebuilds are idempotent.
// ---------------------------------------------------------------------------

pub const ConfigChanges = struct {
    keys: bool = false,
};

/// Keys-subsystem content: the pair layout — (modifiers, keysym) per keyboard
/// binding and (modifiers, button) per mouse binding. Action is deliberately
/// excluded: two keybindings that differ only in their action (e.g. a changed
/// command string) still share a pair, so no regrab is needed.
fn keysChanged(old: *const composed.Config, new: *const composed.Config) bool {
    if (old.core.keybindings.items.len != new.core.keybindings.items.len) return true;
    for (old.core.keybindings.items, new.core.keybindings.items) |a, b| {
        if (a.modifiers != b.modifiers or a.keysym != b.keysym) return true;
    }
    if (old.core.mouse_bindings.items.len != new.core.mouse_bindings.items.len) return true;
    for (old.core.mouse_bindings.items, new.core.mouse_bindings.items) |a, b| {
        if (a.modifiers != b.modifiers or a.button != b.button) return true;
    }
    return false;
}

/// Compares old and new configs for the one subsystem whose rebuild is
/// skipped on an unchanged pair layout (the regrab). Gate the regrab on
/// `.keys`; everything else rebuilds unconditionally.
pub fn detectChanges(old: *const composed.Config, new: *const composed.Config) ConfigChanges {
    return .{ .keys = keysChanged(old, new) };
}
