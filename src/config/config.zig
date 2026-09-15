//! Configuration interpreter
//! Loads, parses, and validates TOML config files.

const std = @import("std");
const constants = @import("constants");
const core = @import("core");
const debug = @import("debug");
const masks = @import("masks");
const model = @import("model");
const parser = @import("parser");
const schema = @import("schema");
const types = @import("types");
const utils = @import("utils");
const xkbcommon = @import("xkbcommon");

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

fn tryParseWs1Based(tok: []const u8, max: usize, ctx: []const u8, comptime fmt: ?[]const u8, args: anytype) ?usize {
    const ws_1based = std.fmt.parseInt(usize, tok, 10) catch {
        if (fmt) |f| debug.warn(f, args);
        return null;
    };
    if (!checkWorkspaceBound(ws_1based, ctx, max)) return null;
    return ws_1based;
}

fn addRule(
    allocator: std.mem.Allocator,
    cfg: *types.Config,
    class_name: []const u8,
    ws_num: usize,
) !void {
    try cfg.workspaces.rules.append(allocator, .{
        .class_name = try allocator.dupe(u8, class_name),
        .workspace = @intCast(ws_num - 1),
    });
}

/// "float" class rule: windows whose WM_CLASS matches `class_name` are
/// admitted floating on the current workspace. `workspace` is left 0 (unused).
fn addFloatRule(allocator: std.mem.Allocator, cfg: *types.Config, class_name: []const u8) !void {
    try cfg.workspaces.rules.append(allocator, .{
        .class_name = try allocator.dupe(u8, class_name),
        .workspace = 0,
        .float = true,
    });
}

fn initDefaultBarLayout(allocator: std.mem.Allocator, cfg: *types.Config) !void {
    const defaults = [_]struct { pos: types.BarSegmentAnchor, seg: []const u8 }{
        .{ .pos = .left, .seg = "workspaces" },
        .{ .pos = .center, .seg = "title" },
        .{ .pos = .right, .seg = "clock" },
    };
    for (defaults) |d| {
        var layout = types.BarLayout{ .position = d.pos, .segments = .empty };
        try layout.segments.append(allocator, try allocator.dupe(u8, d.seg));
        try cfg.bar.layout.append(allocator, layout);
    }
}

pub const max_file_bytes = 1024 * 1024;

/// Initial allocation for the read-with-growth path (stat failed or reported
/// zero, e.g. procfs/sysfs/pipes). Doubles until the whole file is read.
const read_growth_initial_bytes = 64 * 1024;

const default_tiling_layout = (types.TilingConfig{}).layout;

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
/// `had_errors` so the caller can propagate error.ConfigParseFailed (C1).
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
/// loader and include resolution: the parse/merge/log tail is the same in both
/// (C2).
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
    const inc_val = src_doc.get("include") orelse return;
    const includes = inc_val.asArray() orelse return;
    for (includes) |item| {
        const rel = item.asScalar([]const u8) orelse continue;
        if (!std.mem.endsWith(u8, rel, ".toml")) {
            debug.warn("include '{s}': path must end in .toml; skipping", .{rel});
            continue;
        }
        const abs = try std.fs.path.join(allocator, &.{ dir_path, rel });
        var inc_doc = tryParseTomlFile(allocator, abs, dst) orelse continue;
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
    // One load-scoped arena hosts every parsed Document (and its aliased file
    // buffers); documents share strings through it, and the reset below
    // reclaims them all once the Config has been built (Config dupes its own
    // strings from the general `allocator`).
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

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
    var merged = parser.Document.init(a);
    for (names.items) |name| try mergeOneFile(a, &merged, dir_path, name);

    const cfg = try buildConfigFromDoc(allocator, &merged);
    debug.info("Loaded config from dir: {s} ({} file(s))", .{ dir_path, names.items.len });
    return cfg;
}

fn tryLoadOrWarn(
    comptime loader: anytype,
    allocator: std.mem.Allocator,
    path: []const u8,
    comptime err_msg: []const u8,
    comptime silent: []const anyerror,
) ?types.Config {
    return loader(allocator, path) catch |err| {
        for (silent) |e| if (err == e) return null;
        debug.warn(err_msg, .{ path, err });
        return null;
    };
}

/// Loads config in priority order: (1) ~/.config/hana/, (2) ./config/,
/// (3) ~/.config/hana/config.toml, (4) ./config.toml, (5) embedded fallback.
pub fn loadConfigDefault(allocator: std.mem.Allocator) !types.Config {
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
    defer allocator.free(xdg_dir);

    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    _ = std.c.getcwd(&cwd_buf, cwd_buf.len) orelse return error.CurrentWorkingDirectoryUnlinked;
    const cwd = std.mem.sliceTo(&cwd_buf, 0);
    const local_dir = try std.fs.path.join(allocator, &.{ cwd, "config" });
    defer allocator.free(local_dir);

    // Try directories first (contain multiple .toml files), then single files.
    const dir_attempts = [_][]const u8{ xdg_dir, local_dir };
    for (dir_attempts) |dir|
        if (tryLoadOrWarn(loadConfigFromDir, allocator, dir, "Config load error from {s}: {}", &.{ error.FileNotFound, error.NotDir })) |cfg| return cfg;

    const xdg_path = try std.fs.path.join(allocator, &.{ xdg_dir, "config.toml" });
    defer allocator.free(xdg_path);
    const local = try std.fs.path.join(allocator, &.{ cwd, "config.toml" });
    defer allocator.free(local);
    const file_attempts = [_][]const u8{ xdg_path, local };
    for (file_attempts) |path|
        if (tryLoadOrWarn(loadConfig, allocator, path, "hana: config file '{s}' found but failed to load: {}; falling back\n", &.{error.FileNotFound})) |cfg| return cfg;

    debug.info("No config found, using fallback with auto-detection", .{});
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
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var doc = try parseTomlFile(a, path) orelse {
        debug.info("Empty config file: {s}, using fallback", .{path});
        return try loadFallbackConfig(allocator);
    };
    try mergeIncludes(a, &doc, &doc, std.fs.path.dirname(path) orelse ".");
    const cfg = try buildConfigFromDoc(allocator, &doc);
    debug.info("Loaded: {s}", .{path});
    return cfg;
}

fn loadFallbackConfig(allocator: std.mem.Allocator) !types.Config {
    const fallback = @import("fallback");
    const fallback_toml = fallback.getFallbackToml() orelse return error.FallbackMissing;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var doc = try parser.parse(a, fallback_toml, "<embedded fallback>");
    var cfg = try buildConfigFromDoc(allocator, &doc);
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
    // Canonical default name: it resolves to the "master" module at seed
    // time; every stored name is canonical.
    const default_layout = try allocator.dupe(u8, "master");
    try cfg.tiling.layouts.append(allocator, default_layout);
    cfg.tiling.layout = cfg.tiling.layouts.items[0];
    try padWorkspaceIcons(allocator, &cfg);
    try initDefaultBarLayout(allocator, &cfg);
    return cfg;
}

fn buildConfigFromDoc(allocator: std.mem.Allocator, doc: *parser.Document) !types.Config {
    // A broken TOML (warn-and-skipped line, or a whole file skipped during
    // the merge) must not silently produce a partially-applied config: fail
    // the load so reload keeps the live config (C1). Boot falls through to
    // the embedded fallback via loadConfigDefault's warn-and-skip.
    if (doc.had_errors) return error.ConfigParseFailed;
    // Mis-cased KNOWN section headers ([Bar], [TILING], ...) are otherwise
    // silently dropped; call them out once each (C6).
    warnMisCasedSections(doc);
    var cfg = try getDefaultConfig(allocator);
    // If any parse step below errors (OOM), free the partial Config so the
    // half-applied section doesn't leak. Only armed after getDefaultConfig
    // succeeded, so its own errdefer handled the earlier failure.
    errdefer cfg.deinit(allocator);
    try parseKeybindings(allocator, doc, &cfg);
    try parseTilingStructures(allocator, doc, &cfg);
    // Every scalar knob ([drag], [fullscreen], [workspaces], [tiling]
    // flags/aesthetics/master trio, all of [bar] incl. [bar.colors]) in one
    // table-driven pass; must precede parseBar so icon padding sees the
    // freshly parsed workspaces.count.
    try schema.applyAll(doc, allocator, &cfg);
    // A `tiling.*`/`bar.colors` family without its parent section is inert
    // (applyAll and the parse functions both gate on it); warn once (C9).
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
/// almost certainly a typo that silently drops the whole section (C6).
const known_sections = std.StaticStringMap(void).initComptime(.{
    .{ "binds", {} },                       .{ "Keybindings", {} },
    .{ "workspace.rules", {} },             .{ "rules", {} },
    .{ "drag", {} },                        .{ "fullscreen", {} },
    .{ "tiling", {} },                      .{ "workspaces", {} },
    .{ "bar", {} },                         .{ "bar.colors", {} },
    .{ "bar.layout.left", {} },             .{ "bar.layout.center", {} },
    .{ "bar.layout.right", {} },            .{ "bar.modules.workspaces", {} },
    .{ "tiling.aesthetics", {} },           .{ "tiling.layouts.master-stack", {} },
    .{ "tiling.layouts.master_stack", {} },
});

/// Section families whose parent section must exist for their knobs to do
/// anything; a mis-cased or missing parent leaves them inert (C9).
const known_section_prefixes = [_][]const u8{ "tiling.layouts.", "workspace.rules.", "rules." };

fn warnMisCasedSections(doc: *parser.Document) void {
    var iter = doc.sections.iterator();
    while (iter.next()) |entry| {
        const name = entry.key_ptr.*;
        if (known_sections.has(name)) continue;
        var buf: [64]u8 = undefined;
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
/// without it, which leaves its knobs silently inert (C9).
fn warnInertSectionFamilies(doc: *parser.Document) void {
    if (doc.getSection("tiling") == null) {
        var iter = doc.sections.iterator();
        while (iter.next()) |entry| {
            if (std.mem.startsWith(u8, entry.key_ptr.*, "tiling.")) {
                debug.warn("[tiling.*] sections present but bare [tiling] is missing; their knobs are inert", .{});
                break;
            }
        }
    }
    if (doc.getSection("bar") == null and doc.getSection("bar.colors") != null)
        debug.warn("[bar.colors] present but [bar] is missing; its knobs are inert", .{});
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

/// Mechanically derived from `types.Action`'s tag names, so every action
/// is addressable by its own tag name without a hand-maintained entry. Only
/// genuine ALIASES are listed by hand. Adding an Action union member now
/// requires exactly one edit (the union); forgetting an intended alias fails
/// the parser's unknown-action typo detection instead of silently unparsable.
const action_aliases = [_]struct { key: []const u8, tag: std.meta.Tag(types.Action) }{
    .{ .key = "close", .tag = .close_window },
    .{ .key = "kill", .tag = .close_window },
    .{ .key = "reload", .tag = .reload_config },
    .{ .key = "fullscreen", .tag = .toggle_fullscreen },
    .{ .key = "minimize", .tag = .minimize_window },
    .{ .key = "prompt", .tag = .toggle_prompt },
};

const action_map: std.StaticStringMap(types.Action) = blk: {
    @setEvalBranchQuota(10000);
    const fields = @typeInfo(types.Action).@"union".fields;
    const direction_entries = [_]struct { key: []const u8, action: types.Action }{
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
    const total = fields.len + action_aliases.len + direction_entries.len;
    var kvs: [total]struct { []const u8, types.Action } = undefined;
    var n: usize = 0;
    // Void tag names auto-generated from union fields.
    for (fields) |f| {
        if (f.type == void) {
            kvs[n] = .{ f.name, @field(types.Action, f.name) };
            n += 1;
        }
    }
    // Hand-written void aliases.
    for (action_aliases) |a| {
        for (kvs[0..n]) |kv| {
            if (std.mem.eql(u8, kv[0], a.key))
                @compileError("alias shadows an Action tag name: " ++ a.key);
        }
        kvs[n] = .{ a.key, @field(types.Action, @tagName(a.tag)) };
        n += 1;
    }
    // Payload-bearing aliases (old tag names → merged variant with payload).
    for (direction_entries) |de| {
        for (kvs[0..n]) |kv| {
            if (std.mem.eql(u8, kv[0], de.key))
                @compileError("direction entry shadows existing action key: " ++ de.key);
        }
        kvs[n] = .{ de.key, de.action };
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
    // S1: substitute {kill} FIRST, for ANY action string, before the
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
/// array becomes a `.sequence`.
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
                    try acts.append(allocator, try resolveAndParseAction(allocator, cmd, ws_idx, kill));
            // S4: a non-empty array whose elements were all non-strings
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
        .string => |command| try resolveAndParseAction(allocator, command, ws_idx, kill),
        else => null,
    };
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
    const section = doc.getSection("binds") orelse doc.getSection("Keybindings") orelse return;
    var mod_placeholder: ?[]const u8 = null;
    var kill_placeholder: ?[]const u8 = null;
    var iter = section.orderedIterator();
    while (iter.next()) |entry| {
        if (std.ascii.eqlIgnoreCase(entry.key, "Mod")) {
            mod_placeholder = entry.value.asScalar([]const u8);
            section.markConsumed(entry.key);
            continue;
        }
        if (std.ascii.eqlIgnoreCase(entry.key, "kill")) {
            kill_placeholder = entry.value.asScalar([]const u8);
            section.markConsumed(entry.key);
            continue;
        }
        section.markConsumed(entry.key);
        const glob_entries = try expandGlobKeys(allocator, entry.key);
        defer {
            for (glob_entries) |ge| if (ge.owned) allocator.free(ge.key);
            allocator.free(glob_entries);
        }
        for (glob_entries) |ge| {
            const keybind_str: []const u8 = try resolveModPlaceholder(allocator, ge.key, mod_placeholder);
            defer if (keybind_str.ptr != ge.key.ptr) allocator.free(keybind_str);
            const action = try actionFromValue(allocator, entry.value, ge.ws_idx, kill_placeholder) orelse continue;
            const bind = parseBindString(keybind_str) catch |err| {
                debug.warn("Failed to parse keybind '{s}': {}", .{ keybind_str, err });
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
        var lowered_buf: [16]u8 = undefined;
        const lowered = types.lowerSlice(16, &lowered_buf, trimmed);
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
    if (name.len >= 64) return error.KeyNameTooLong;
    var buf: [64]u8 = undefined;
    @memcpy(buf[0..name.len], name);
    buf[name.len] = 0;
    const keysym = xkbcommon.xkb_keysym_from_name(
        @ptrCast(&buf),
        xkbcommon.xkb_keysym_case_insensitive,
    );
    return if (keysym == xkbcommon.XKB_KEY_NoSymbol) error.UnknownKeyName else keysym;
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
/// fragment. After S1's hoisted substitution this should never be true for a
/// config action; it is a defensive guard so an unresolved placeholder can
/// never be handed to the shell verbatim (C7).
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

/// Scales font size and other DPI-dependent fields. Call once the screen is available.
pub fn finalizeConfig(cfg: *types.Config, screen: core.Screen) void {
    const scale_module = @import("scale");
    cfg.bar.scaled_font_size = scale_module.scaleFontSize(cfg.bar.font_size, screen);
}

/// O(1) keybinding lookup for the hot key-press path; returns a pointer into
/// the current config's keybindings slice, or null. Delegates to the config's
/// embedded `keybind_resolver` (see KeybindResolver in types.zig) rather than
/// a module-level global, so input.zig needn't spell out the lookup.
pub inline fn lookupKeybinding(mods: u16, keysym: u32) ?*const types.Action {
    return core.getState().config.keybind_resolver.lookup(mods, keysym);
}

/// Canonical startup/reload entry point: load, validate, resolve keybindings, finalize.
pub fn load(
    allocator: std.mem.Allocator,
    screen: core.Screen,
    xkb_state: *xkbcommon.XkbState,
) !types.Config {
    var cfg = try loadConfigDefault(allocator);
    errdefer cfg.deinit(allocator);
    try validate(&cfg);
    cfg.keybind_resolver.build(cfg.keybindings.items, xkb_state, allocator);
    finalizeConfig(&cfg, screen);
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
        return "master";
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
    const section = doc.getSection("tiling") orelse return;
    types.freeStrings(&cfg.tiling.layouts, allocator, true);
    cfg.tiling.workspace_layout_overrides.clearRetainingCapacity();
    types.freeStringMap(&cfg.tiling.variants, allocator, true);
    // Single-layout path clears the getDefaultConfig default; the "layout"
    // fallback is (types.TilingConfig{}).layout, NOT cfg.tiling.layout (which
    // aliases layouts.items[0], freed below, so using it would read freed
    // memory when the key is absent).
    if (section.getAs([]const parser.Value, "layouts")) |arr| try parseLayoutsArray(allocator, arr, cfg) else {
        const layout_str = schema.getInRange([]const u8, section, "layout", default_tiling_layout, null, null);
        try cfg.tiling.layouts.append(allocator, try allocator.dupe(u8, canonicalLayoutName(layout_str)));
    }
    if (cfg.tiling.layouts.items.len > 0) cfg.tiling.layout = cfg.tiling.layouts.items[0];
    try parseTilingLayoutSubtables(allocator, doc, cfg);
}

/// The flat `[tiling] master_variant/monocle_variant/grid_variant` keys
/// map onto their canonical layout names.
const flat_variant_keys = [_]struct { key: []const u8, canon: []const u8 }{
    .{ .key = "master_variant", .canon = "master" },
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
    if (doc.getSection("tiling")) |sec| for (flat_variant_keys) |fk|
        if (sec.getAs([]const u8, fk.key)) |v| try setTilingVariant(allocator, cfg, fk.canon, v);

    const prefix = "tiling.layouts.";
    const suffix = ".counts";
    var iter = doc.sections.iterator();
    while (iter.next()) |entry| {
        const sec_name = entry.key_ptr.*;
        if (!std.mem.startsWith(u8, sec_name, prefix)) continue;
        // Only direct "<prefix><name>[.counts]" tables qualify (no deeper
        // nesting); the counts table is master-family only, and its keys are
        // 1-based workspace numbers -> in-[0,10] master counts.
        const tail = sec_name[prefix.len..];
        if (std.mem.endsWith(u8, tail, suffix)) {
            const seg = tail[0 .. tail.len - suffix.len];
            if (std.mem.eql(u8, canonicalLayoutName(seg), "master")) {
                const counts_sec = entry.value_ptr;
                cfg.tiling.workspace_master_count_overrides.clearRetainingCapacity();
                var inner = counts_sec.orderedIterator();
                while (inner.next()) |p| {
                    counts_sec.markConsumed(p.key);
                    if (tryParseWs1Based(p.key, constants.max_workspaces, "master-stack.counts", "master-stack.counts: invalid workspace key '{s}', skipping", .{p.key})) |ws_1based| {
                        const count_val = p.value.asScalar(i64) orelse {
                            debug.warn("master-stack.counts: non-integer count for workspace {}, skipping", .{ws_1based});
                            continue;
                        };
                        if (count_val < 0 or count_val > 10)
                            debug.warn("master-stack.counts: count {} for workspace {} out of range [0,10], skipping", .{ count_val, ws_1based })
                        else
                            try cfg.tiling.workspace_master_count_overrides.append(allocator, .{
                                .workspace_idx = @intCast(ws_1based - 1),
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
const max_layout_name = 32;

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
        const ws_1based = tryParseWs1Based(trimmed, constants.max_workspaces, "layouts array", "layouts array: invalid workspace number '{s}' for layout '{s}', skipping", .{ trimmed, layout_name }) orelse continue;
        const variant_copy: ?[]const u8 = if (variant) |v| try allocator.dupe(u8, v) else null;
        try overrides.append(allocator, .{ .workspace_idx = @intCast(ws_1based - 1), .layout_idx = layout_idx, .variant = variant_copy });
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
        // ReleaseFast (S2).
        if (cfg.tiling.layouts.items.len >= max_layouts) {
            debug.warn("layouts array: maximum of {d} unique layouts reached, skipping '{s}'", .{ max_layouts, raw_name });
            continue;
        }
        const layout_idx: u8 = @intCast(cfg.tiling.layouts.items.len);
        try cfg.tiling.layouts.append(allocator, try allocator.dupe(u8, canonicalLayoutName(name_lower)));

        if (i + 1 >= arr.len) continue;
        const peek = arr[i + 1].asScalar([]const u8) orelse continue;
        var variants: ?[]const u8 = null;
        var ws_list_str: ?[]const u8 = null;
        if (isWorkspaceList(peek)) {
            ws_list_str = peek;
            i += 1;
        } else if (!isLayoutName(peek)) {
            // A variants word feeds both the per-layout map and, when a
            // workspace list follows, the per-workspace overrides.
            variants = (try parseLayoutVariant(allocator, cfg, name_lower, peek)) orelse continue;
            i += 1;
            if (i + 1 < arr.len) {
                if (arr[i + 1].asScalar([]const u8)) |peek2| {
                    if (isWorkspaceList(peek2)) {
                        ws_list_str = peek2;
                        i += 1;
                    }
                }
            }
        }
        if (ws_list_str) |ws_str| try parseWorkspaceListInto(allocator, ws_str, name_lower, layout_idx, variants, &cfg.tiling.workspace_layout_overrides);
    }
}

/// Dupe-appends every string element of `items` into `dst`; non-string
/// entries are skipped silently (the fonts list, where a stray non-string
/// is simply ignored).
fn appendDupedStrings(
    allocator: std.mem.Allocator,
    items: []const parser.Value,
    dst: *std.ArrayList([]const u8),
) !void {
    for (items) |item| {
        if (item.asScalar([]const u8)) |s|
            try dst.append(allocator, try allocator.dupe(u8, s));
    }
}

/// Dupe-appends every string element of `items` into `dst`, warning on
/// non-string entries (the bar segment list, where a typo should surface).
fn appendDupedStringsWarned(
    allocator: std.mem.Allocator,
    items: []const parser.Value,
    dst: *std.ArrayList([]const u8),
) !void {
    for (items) |item| {
        if (item.asScalar([]const u8)) |s| {
            try dst.append(allocator, try allocator.dupe(u8, s));
        } else {
            debug.warn("Non-string entry in bar segment list, skipping", .{});
        }
    }
}

/// Bar's NON-scalar structures: fonts, indicator glyph mirroring, workspace
/// icons, and the bar columns. Every bar SCALAR (flags, scalables, height,
/// colors incl. the [bar.colors] fallback chains, strings, enums, ratios)
/// is driven by schema.applyAll; like parseBar always did, everything here
/// stays gated on the [bar] section existing.
fn parseBar(allocator: std.mem.Allocator, doc: *parser.Document, cfg: *types.Config) !void {
    const section = doc.getSection("bar") orelse return;
    if (section.getAs([]const parser.Value, "fonts")) |arr| {
        types.freeStrings(&cfg.bar.fonts, allocator, true);
        try appendDupedStrings(allocator, arr, &cfg.bar.fonts);
        debug.info("Loaded {} fonts for bar", .{cfg.bar.fonts.items.len});
    }
    // status_items: the system-status widget's item whitelist (render order);
    // unknown items are left to the segment to skip silently.
    if (section.getAs([]const parser.Value, "status_items")) |arr| {
        types.freeStrings(&cfg.bar.status_items, allocator, true);
        try appendDupedStrings(allocator, arr, &cfg.bar.status_items);
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
    types.freeStrings(&cfg.bar.workspace_icons, allocator, true);
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
    types.freeBarLayouts(&cfg.bar.layout, allocator, true);
    const positions = [_]struct { name: []const u8, pos: types.BarSegmentAnchor }{
        .{ .name = "bar.layout.left", .pos = .left },
        .{ .name = "bar.layout.center", .pos = .center },
        .{ .name = "bar.layout.right", .pos = .right },
    };
    for (positions) |p| {
        const layout_section = doc.getSection(p.name) orelse continue;
        var bar_layout = types.BarLayout{ .position = p.pos, .segments = .empty };
        if (layout_section.getAs([]const parser.Value, "segments")) |seg_arr|
            try appendDupedStringsWarned(allocator, seg_arr, &bar_layout.segments);
        if (bar_layout.segments.items.len > 0) try cfg.bar.layout.append(allocator, bar_layout) else bar_layout.deinit(allocator);
    }

    if (cfg.bar.layout.items.len == 0) try initDefaultBarLayout(allocator, cfg);
}

fn parseRules(allocator: std.mem.Allocator, doc: *parser.Document, cfg: *types.Config) !void {
    // [workspace.rules]: key is either a class name (value = ws int) or a
    // workspace number (value = class array). Both directions call addRule.
    if (doc.getSection("workspace.rules")) |s| try parseWorkspaceRuleSection(allocator, cfg, s);
    // [rules]: simple class -> workspace mapping (key = class, value = ws int).
    if (doc.getSection("rules")) |s| {
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
        const suffix_len = if (std.mem.startsWith(u8, name, "workspace.rules.")) "workspace.rules.".len else if (std.mem.startsWith(u8, name, "rules.")) "rules.".len else continue;
        const ws_num = tryParseWs1Based(name[suffix_len..], cfg.workspaces.count, name, null, .{}) orelse continue;
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
            try addFloatRule(allocator, cfg, class_name);
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
        try addRule(allocator, cfg, class_name, @intCast(ws_num));
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

fn eqlStrings(a: []const []const u8, b: []const []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| if (!std.mem.eql(u8, x, y)) return false;
    return true;
}

fn eqlOptionalString(a: ?[]const u8, b: ?[]const u8) bool {
    if (a) |x| return if (b) |y| std.mem.eql(u8, x, y) else false;
    return b == null;
}

fn eqlScalableOpt(a: ?parser.ScalableValue, b: ?parser.ScalableValue) bool {
    if (a) |x| return if (b) |y| eqlScalable(x, y) else false;
    return b == null;
}

/// ScalableValue is a bare struct (no `==` operator), so compare its fields.
fn eqlScalable(a: parser.ScalableValue, b: parser.ScalableValue) bool {
    return a.value == b.value and a.is_percentage == b.is_percentage;
}

fn eqlBarLayouts(a: []const types.BarLayout, b: []const types.BarLayout) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (x.position != y.position) return false;
        if (!eqlStrings(x.segments.items, y.segments.items)) return false;
    }
    return true;
}

fn eqlLayoutOverrides(a: []const types.WorkspaceLayoutOverride, b: []const types.WorkspaceLayoutOverride) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (x.workspace_idx != y.workspace_idx or x.layout_idx != y.layout_idx) return false;
        if (!eqlOptionalString(x.variant, y.variant)) return false;
    }
    return true;
}

fn eqlMasterCountOverrides(a: []const types.WorkspaceMasterCountOverride, b: []const types.WorkspaceMasterCountOverride) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (x.workspace_idx != y.workspace_idx or x.count != y.count) return false;
    }
    return true;
}

/// Variant maps are compared by (key, value) content, unordered: append
/// history must never make two identical maps read as different.
fn eqlVariantMap(a: *const std.StringHashMapUnmanaged([]const u8), b: *const std.StringHashMapUnmanaged([]const u8)) bool {
    if (a.count() != b.count()) return false;
    var it = a.iterator();
    while (it.next()) |entry| {
        const v = b.get(entry.key_ptr.*) orelse return false;
        if (!std.mem.eql(u8, entry.value_ptr.*, v)) return false;
    }
    return true;
}

fn eqlRules(a: []const types.Rule, b: []const types.Rule) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (x.workspace != y.workspace) return false;
        if (!std.mem.eql(u8, x.class_name, y.class_name)) return false;
    }
    return true;
}

pub const ConfigChanges = struct {
    bar: bool = false,
    tiling: bool = false,
    keys: bool = false,
};

/// Bar-subsystem content: every field of BarConfig compared logically
/// (arrays by items, optionals by inner value, strings by contents).
fn barChanged(old: *const types.BarConfig, new: *const types.BarConfig) bool {
    return old.enabled != new.enabled or
        old.vim_mode != new.vim_mode or
        old.bar_position != new.bar_position or
        !eqlScalableOpt(old.height, new.height) or
        !eqlStrings(old.fonts.items, new.fonts.items) or
        !eqlScalable(old.font_size, new.font_size) or
        old.scaled_font_size != new.scaled_font_size or
        !eqlScalable(old.spacing, new.spacing) or
        old.bg != new.bg or
        old.fg != new.fg or
        old.selected_bg != new.selected_bg or
        old.selected_fg != new.selected_fg or
        old.accent_color != new.accent_color or
        old.title_accent_color != new.title_accent_color or
        old.title_unfocused_accent != new.title_unfocused_accent or
        old.title_minimized_accent != new.title_minimized_accent or
        !eqlStrings(old.workspace_icons.items, new.workspace_icons.items) or
        !eqlScalable(old.indicator_size, new.indicator_size) or
        !eqlScalable(old.workspace_tag_width, new.workspace_tag_width) or
        old.indicator_location != new.indicator_location or
        old.indicator_padding != new.indicator_padding or
        !eqlOptionalString(old.indicator_focused, new.indicator_focused) or
        !eqlOptionalString(old.indicator_unfocused, new.indicator_unfocused) or
        old.indicator_color != new.indicator_color or
        !eqlOptionalString(old.clock_format, new.clock_format) or
        !eqlOptionalString(old.volume_format, new.volume_format) or
        !eqlOptionalString(old.volume_muted_format, new.volume_muted_format) or
        !eqlStrings(old.status_items.items, new.status_items.items) or
        old.carousel_enabled != new.carousel_enabled or
        old.carousel_speed_px_s != new.carousel_speed_px_s or
        old.drun_bg != new.drun_bg or
        old.drun_fg != new.drun_fg or
        old.drun_prompt_color != new.drun_prompt_color or
        !eqlOptionalString(old.drun_prompt, new.drun_prompt) or
        !eqlBarLayouts(old.layout.items, new.layout.items) or
        old.transparency != new.transparency;
}

/// Tiling-subsystem content: TilingConfig, plus the workspaces/fullscreen/
/// drag/snap gates the reload handler rebuilds together with tiling state.
fn tilingChanged(old: *const types.Config, new: *const types.Config) bool {
    return old.tiling.enabled != new.tiling.enabled or
        !std.mem.eql(u8, old.tiling.layout, new.tiling.layout) or
        !eqlStrings(old.tiling.layouts.items, new.tiling.layouts.items) or
        old.tiling.master_side != new.tiling.master_side or
        !eqlScalable(old.tiling.master_width, new.tiling.master_width) or
        old.tiling.master_count != new.tiling.master_count or
        !eqlScalable(old.tiling.gap_width, new.tiling.gap_width) or
        !eqlScalable(old.tiling.border_width, new.tiling.border_width) or
        old.tiling.border_focused != new.tiling.border_focused or
        old.tiling.border_unfocused != new.tiling.border_unfocused or
        old.tiling.min_window_dim != new.tiling.min_window_dim or
        !eqlVariantMap(&old.tiling.variants, &new.tiling.variants) or
        !eqlLayoutOverrides(old.tiling.workspace_layout_overrides.items, new.tiling.workspace_layout_overrides.items) or
        !eqlMasterCountOverrides(old.tiling.workspace_master_count_overrides.items, new.tiling.workspace_master_count_overrides.items) or
        old.tiling.global_layout != new.tiling.global_layout or
        old.workspaces.enabled != new.workspaces.enabled or
        old.workspaces.count != new.workspaces.count or
        !eqlRules(old.workspaces.rules.items, new.workspaces.rules.items) or
        old.fullscreen_enabled != new.fullscreen_enabled or
        old.drag_enabled != new.drag_enabled or
        !eqlScalable(old.snap_distance, new.snap_distance);
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
