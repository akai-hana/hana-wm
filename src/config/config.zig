//! Configuration interpreter
//! Loads, parses, and validates TOML config files.

const std = @import("std");
const fallback = @import("fallback");
const log = @import("log");
const parser = @import("parser");
const schema = @import("schema");
const types = @import("types");
const validate_mod = @import("validate");
const layout_names = @import("layout_names");
const diff = @import("diff");
const snapshot_mod = @import("snapshot");
const discover = @import("discover");
const binds = @import("binds");
const sections = @import("sections");
const rules = @import("rules");

// Re-exports: `config` stays the single import surface for callers
// (main.zig, events.zig, persist.zig, the tests); the seams below
// are where the code now lives.
pub const validate = validate_mod.validate;
pub const canonicalLayoutName = layout_names.canonicalLayoutName;
pub const isLayoutName = layout_names.isLayoutName;
pub const layout_name_grammar = layout_names.layout_name_grammar;
pub const detectChanges = diff.detectChanges;
pub const ConfigChanges = diff.ConfigChanges;
pub const DefaultSource = snapshot_mod.DefaultSource;
pub const deinitGoodSource = snapshot_mod.deinitGoodSource;
pub const reexecSnapshotPathZ = snapshot_mod.reexecSnapshotPathZ;
pub const refreshSnapshot = snapshot_mod.refreshSnapshot;
pub const readFileAlloc = discover.readFileAlloc;
pub const max_file_bytes = discover.max_file_bytes;
pub const max_config_files = discover.max_config_files;

// Internal names the orchestrator still uses unqualified.
const normalizeLayoutName = layout_names.normalizeLayoutName;
const max_layout_name = layout_names.max_layout_name;
const rememberGoodSource = snapshot_mod.rememberGoodSource;
const publishReadFiles = snapshot_mod.publishReadFiles;
const ReadSet = discover.ReadSet;
const parseTomlFile = discover.parseTomlFile;
const ParsedToml = discover.ParsedToml;
const mergeIncludes = discover.mergeIncludes;
const searchPaths = discover.searchPaths;
const SearchPaths = discover.SearchPaths;
const search_order = discover.search_order;
const SearchAttempt = discover.SearchAttempt;
const SearchLoc = discover.SearchLoc;
const silent_missing = discover.silent_missing;
const tryLoadOrWarn = discover.tryLoadOrWarn;
const discoverDirNames = discover.discoverDirNames;
const parseDirDoc = discover.parseDirDoc;
const DirInput = discover.DirInput;
const parseKeybindings = binds.parseKeybindings;
const parseTilingStructures = sections.parseTilingStructures;
const parseBar = sections.parseBar;
const parseRules = rules.parseRules;
const padWorkspaceIcons = sections.padWorkspaceIcons;
const initDefaultBarLayout = sections.initDefaultBarLayout;

/// Longest section name a mis-case warning must lower (bounded helper buffer;
/// real-world section names are far shorter, this just caps a pathological
/// line's cost).
const max_section_name_bytes = 64;

/// Loads and merges all `*.toml` files directly inside `dir_path` (alphabetical order;
/// subdirectories only via explicit `include`).  Later files win on scalar conflicts;
/// arrays accumulate (enforced by the parser's Value getters: scalar reads resolve to
/// the last declaration, array reads see every one).
pub fn loadConfigFromDir(allocator: std.mem.Allocator, dir_path: []const u8) !types.Config {
    var names = try discoverDirNames(allocator, dir_path);
    defer {
        for (names.items) |n| allocator.free(n);
        names.deinit(allocator);
    }
    const cfg = try parseAndBuild(allocator, parseDirDoc, DirInput{ .dir_path = dir_path, .names = names.items });
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
pub fn loadConfigDefault(allocator: std.mem.Allocator, source: *DefaultSource, allow_pinned_snapshot: bool) !types.Config {
    const paths = try searchPaths(allocator);
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
                rememberGoodSource(allocator, env, true);
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
    // files. The order comes from `search_order`; each tag resolves its path,
    // loader, provenance and wording in one switch, so a new location cannot
    // be added with a missing or mismatched field.
    inline for (search_order) |loc| {
        const at: SearchAttempt = switch (loc) {
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
        if (try tryLoadOrWarn(at.load, allocator, at.path, err_msg, &silent_missing)) |cfg| {
            rememberGoodSource(allocator, at.path, at.is_dir);
            source.* = .user;
            return cfg;
        }
    }

    log.info("No config found, using fallback with auto-detection", .{});
    source.* = .fallback;
    return try loadFallbackConfig(allocator);
}

/// Reads, parses, and returns the config at `path` (single-file entry point).
pub fn loadConfig(allocator: std.mem.Allocator, path: []const u8) !types.Config {
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
/// recording the file and every consumed include in `read`.
fn parseFileDoc(a: std.mem.Allocator, read: *ReadSet, in: FileInput) !parser.Document {
    var parsed = try parseTomlFile(a, in.path) orelse return error.ConfigEmpty;
    // This path cannot breach either ceiling by itself -- one file, already
    // bounded by max_file_bytes, which is under max_total_config_bytes, and the
    // count starts at zero -- so it only records. Its `include`s go through
    // parseAndMerge, which does check both.
    read.bytes += parsed.bytes;
    try read.paths.append(a, in.path);
    try mergeIncludes(a, &parsed.doc, &parsed.doc, read, in.base_dir);
    return parsed.doc;
}

/// Parse inputs for `parseFallbackDoc`: the embedded fallback TOML text.
const FallbackInput = struct { toml: []const u8 };

/// Parses the embedded fallback TOML into an arena document. The fallback
/// lives in the binary, so it contributes no files to the snapshot.
fn parseFallbackDoc(a: std.mem.Allocator, read: *ReadSet, in: FallbackInput) !parser.Document {
    _ = read;
    return try parser.parse(a, in.toml, "<embedded fallback>");
}

/// Shared tail of the config load pipelines: one load-scoped arena hosts the
/// parsed Document(s) (and their aliased file buffers) while `parse` fills a
/// document from the arena allocator; `buildConfigFromDoc` then dupes every
/// owned Config string from the backing `allocator` before the arena reset
/// reclaims the documents. `parse` also fills `read` with the config files it
/// consumed, which is republished into module state (see publishReadFiles)
/// because the re-exec snapshot needs it after this arena dies.
fn parseAndBuild(
    allocator: std.mem.Allocator,
    comptime parse: anytype,
    in: anytype,
) !types.Config {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var read: ReadSet = .{};
    var doc = try parse(a, &read, in);
    var cfg = try buildConfigFromDoc(allocator, &doc);
    publishReadFiles(read.paths.items) catch |err| {
        cfg.deinit(allocator);
        return err;
    };
    return cfg;
}

fn loadFallbackConfig(allocator: std.mem.Allocator) !types.Config {
    // The embedded fallback is the FLOOR, not a dependency: if it is somehow
    // absent (a build that did not embed it, a truncated binary), returning a
    // boot-fatal error here made a missing convenience file take the WM down
    // with it. `getDefaultConfig` is the same defaults the embedded TOML
    // encodes -- it seeds every scalar from `types.Config`'s field
    // initializers -- so the floor holds even with nothing embedded. The only
    // thing lost is the fallback's own tuned values, and that is reported
    // rather than hidden.
    const fallback_toml = fallback.getFallbackToml() orelse {
        log.warn("Embedded fallback config missing; using the code defaults instead", .{});
        return getDefaultConfig(allocator);
    };
    // The auto_terminal substitution happens in parseAction, so the embedded
    // fallback and a user config go through the identical path.
    const cfg = try parseAndBuild(allocator, parseFallbackDoc, FallbackInput{ .toml = fallback_toml });

    log.info("Loaded fallback configuration with auto-detection", .{});
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
    .{ types.section_binds, {} },                  .{ types.section_binds_alt, {} },
    .{ types.section_workspace_rules, {} },        .{ types.section_rules, {} },
    .{ types.section_drag, {} },                   .{ types.section_fullscreen, {} },
    .{ types.section_display, {} },                .{ types.section_tiling, {} },
    .{ types.section_workspaces, {} },             .{ types.section_bar, {} },
    .{ types.section_bar_properties, {} },         .{ "bar.layout.left", {} },
    .{ "bar.layout.center", {} },                  .{ "bar.layout.right", {} },
    .{ types.section_bar_modules_workspaces, {} }, .{ types.section_tiling_layouts_master_stack, {} },
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

/// Canonical startup entry point: load, validate. Re-exec successors find
/// their pinned config snapshot via `loadConfigDefault(true)`; the in-place
/// reload path (reload.handleConfigReload) loads live configs itself instead.
///
/// Note: keybinding resolution (keysym -> keycode + dispatch map) is an input
/// concern and happens separately via `input.buildKeybinds` once the config is
/// live; see `input/keybind.zig`. DPI-scaled bar metrics are derived by the
/// bar itself (see bar/metrics.zig) rather than stored on the config.
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

pub fn load(allocator: std.mem.Allocator) !types.Config {
    return loadFor(allocator, true);
}

/// `load` with the one state-writing step made explicit. `snapshot` false is
/// for read-only callers (`checkConfig`), which want the identical load
/// decision -- same search order, same fallback, same warn-and-continue -- with
/// none of the writes.
fn loadFor(allocator: std.mem.Allocator, snapshot: bool) !types.Config {
    var source: DefaultSource = .fallback;
    // A user config that will not START is one the WM must not die on, and
    // `validate` failing is exactly that condition -- so it degrades the same
    // way a parse error already does. It used to propagate, which made the two
    // failure classes behave differently for no defensible reason: a typo'd
    // key survived boot and a semantically impossible value did not, even
    // though the second is the one the user cannot see without reading the
    // log. Both are now "this config is not usable, fall back".
    //
    // `errdefer` is scoped to the labeled block so each `loaded` is released
    // exactly once: on the fallback path explicitly (the block then yields the
    // REPLACEMENT config), and on any error return from inside it.
    const cfg = blk: {
        var loaded = loadConfigDefault(allocator, &source, true) catch |err| switch (err) {
            // A config that is broken, out of range, or over a load ceiling is
            // not usable, so boot falls back to the embedded config (the WM must
            // still start). On reload the same errors propagate instead, so the
            // live config is kept -- `isFatalLoadError` is the shared list.
            error.ConfigParseFailed, error.TooManyConfigFiles, error.TooManyConfigBytes => blk2: {
                log.warn("Unusable config at startup ({s}); using the embedded fallback", .{@errorName(err)});
                break :blk2 try loadFallbackConfig(allocator);
            },
            else => return err,
        };
        // `loaded_freed` guards against the double deinit: the InvalidConfig
        // arm frees `loaded` explicitly below, and if the fallback load then
        // errors, this errdefer would otherwise fire its deinit a second time.
        var loaded_freed = false;
        errdefer if (!loaded_freed) loaded.deinit(allocator);
        validate(&loaded) catch |err| switch (err) {
            error.InvalidConfig => {
                log.warn("Config failed validation at startup; using the embedded fallback", .{});
                loaded.deinit(allocator);
                loaded_freed = true;
                break :blk try loadFallbackConfig(allocator);
            },
        };
        break :blk loaded;
    };
    // A successful boot config becomes the re-exec hand-off snapshot (binary-
    // only reload). Guarded to a valid config so a parse-error or
    // validation-error fallback never overwrites the previous good snapshot
    // (both now reach here through the same path, see above).
    if (snapshot) refreshSnapshot(allocator);
    return cfg;
}
