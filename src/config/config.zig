//! Configuration interpreter
//! Loads, parses, and validates TOML config files.

const std = @import("std");
const core = @import("core");
const types = @import("types");
const constants = @import("constants");
const x11_masks = @import("x11_masks");
const debug = @import("debug");
const xkbcommon = @import("xkbcommon");
const parser = @import("parser");
const schema = @import("schema");
const build_options = @import("build_options");
const bar = if (build_options.has_bar) @import("bar") else null;
const utils = @import("utils");

/// Validates a 1-based workspace number, warn-and-skip when outside 1..255 or
/// exceeding `max` (the workspace count, or constants.max_workspaces, the
/// hard ceiling behind workspaces.zig's fixed-size tables) at parse time.
fn checkWorkspaceBound(ws_1based: usize, context: []const u8, max: usize) bool {
    if (ws_1based < 1 or ws_1based > 255) {
        debug.warn("{s}: workspace {} out of range, skipping", .{ context, ws_1based });
        return false;
    }
    if (ws_1based > max) {
        debug.warn("{s}: workspace {} exceeds the {}-workspace limit, skipping", .{ context, ws_1based, max });
        return false;
    }
    return true;
}

fn addRule(allocator: std.mem.Allocator, cfg: *types.Config, class_name: []const u8, ws_num: usize) !void {
    try cfg.workspaces.rules.append(allocator, .{
        .class_name = try allocator.dupe(u8, class_name),
        .workspace = @intCast(ws_num - 1),
    });
}

fn initDefaultBarLayout(allocator: std.mem.Allocator, cfg: *types.Config) !void {
    const defaults = [_]struct { pos: types.BarSegmentAnchor, seg: types.BarSegment }{
        .{ .pos = .left, .seg = .workspaces },
        .{ .pos = .center, .seg = .title },
        .{ .pos = .right, .seg = .clock },
    };
    for (defaults) |d| {
        var layout = types.BarLayout{ .position = d.pos, .segments = .empty };
        try layout.segments.append(allocator, d.seg);
        try cfg.bar.layout.append(allocator, layout);
    }
}

pub const max_file_bytes = 1024 * 1024;

const default_tiling_layout = (types.TilingConfig{}).layout;

/// Reads `path` into a freshly allocated caller-owned slice;
/// `error.FileTooLarge` when it exceeds `max_file_bytes`. Allocates the full
/// ceiling up front and reallocs down; loading is startup/reload-only, so a
/// stat-then-allocate dance (and its TOCTOU re-check) isn't worth it.
pub fn readFileAlloc(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const io = std.Options.debug_io;
    const file = std.Io.Dir.openFileAbsolute(io, path, .{}) catch |err| {
        if (err == error.FileNotFound) debug.info("Not found: {s}", .{path});
        return err;
    };
    defer file.close(io);
    // A successful stat reporting size 0 is as untrustworthy as a failed one:
    // procfs/sysfs/pipes report 0 while carrying content, so they take the
    // same read-with-growth path (pinned by C5 in src/test/config_test.zig).
    const stat: ?std.Io.File.Stat = file.stat(io) catch null;
    const known_size: usize = if (stat) |st| size: {
        if (st.size > max_file_bytes) return error.FileTooLarge;
        if (st.size == 0) break :size 0;
        break :size @intCast(st.size);
    } else 0;

    if (stat != null and known_size > 0) {
        // Direct path: allocate the reported size, read, hand ownership to
        // the caller.
        const buf = try allocator.alloc(u8, known_size);
        errdefer allocator.free(buf);
        const n = try file.readPositionalAll(io, buf, 0);
        return if (n == buf.len) buf else (allocator.realloc(buf, n) catch buf[0..n]);
    }
    // Growth path (stat failed or reported zero). Single ownership throughout
    // — the armed errdefer frees the whole buffer exactly once on every error
    // path, and the success path hands ownership to the caller.
    var buf = try allocator.alloc(u8, 64 * 1024);
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
    return allocator.realloc(buf, total) catch buf[0..total];
}

/// Reads and parses the .toml at `path`, returning null for an empty file.
/// Read/parse errors propagate to the caller, who decides how to handle them.
fn parseTomlFile(allocator: std.mem.Allocator, path: []const u8) !?parser.Document {
    const raw = try readFileAlloc(allocator, path);
    defer allocator.free(raw);
    if (raw.len == 0) return null;
    return try parser.parse(allocator, raw);
}

/// warn-and-skip wrapper around parseTomlFile, the "never crash on bad
/// config" path shared by the directory loader and `include` resolution.
fn tryParseTomlFile(allocator: std.mem.Allocator, path: []const u8) ?parser.Document {
    const doc = parseTomlFile(allocator, path) catch |err| {
        debug.warn("Skipping '{s}': {}", .{ path, err });
        return null;
    };
    if (doc == null) debug.info("Skipping empty file: {s}", .{path});
    return doc;
}

/// Merges files listed in `include = [...]` from `src_doc` into `dst`; `dir_path` is the base for relative paths.
/// Includes resolve one level deep only: an included file's own `include` is
/// skipped, keeping the graph cycle-free by construction (no cycle-detection
/// machinery) at the cost of no chained includes.
fn processIncludes(allocator: std.mem.Allocator, dst: *parser.Document, src_doc: *parser.Document, dir_path: []const u8) !void {
    // The `include` key is copied into `dst` by mergeDocumentsInto, so mark it
    // consumed there as well: otherwise warnUnconsumed would flag it as a typo.
    dst.root.markConsumed("include");
    const inc_val = src_doc.get("include") orelse return;
    const includes = inc_val.asArray() orelse return;
    for (includes) |item| {
        const rel = item.asString() orelse continue;
        if (!std.mem.endsWith(u8, rel, ".toml")) {
            debug.warn("include '{s}': path must end in .toml; skipping", .{rel});
            continue;
        }
        const abs = try std.fs.path.join(allocator, &.{ dir_path, rel });
        defer allocator.free(abs);
        var inc_doc = tryParseTomlFile(allocator, abs) orelse continue;
        defer inc_doc.deinit();
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
    var merged = parser.Document.init(allocator);
    defer merged.deinit();
    for (names.items) |name| {
        const path = try std.fs.path.join(allocator, &.{ dir_path, name });
        defer allocator.free(path);
        var doc = tryParseTomlFile(allocator, path) orelse continue;
        defer doc.deinit();
        try parser.mergeDocumentsInto(allocator, &merged, &doc);
        debug.info("Merged: {s}", .{path});
        try processIncludes(allocator, &merged, &doc, dir_path);
    }

    const cfg = try buildConfigFromDoc(allocator, &merged);
    debug.info("Loaded config from dir: {s} ({} file(s))", .{ dir_path, names.items.len });
    return cfg;
}

/// Attempt to load a single config file at `path`.
/// Returns the config on success, null on FileNotFound, and prints a warning
/// then returns null for any other error, eliminating the repeated
/// try/print/fall-through pattern in loadConfigDefault.
fn tryLoadConfig(allocator: std.mem.Allocator, path: []const u8) ?types.Config {
    return loadConfig(allocator, path) catch |err| {
        if (err != error.FileNotFound)
            debug.warn(
                "hana: config file '{s}' found but failed to load: {}; falling back\n",
                .{ path, err },
            );
        return null;
    };
}

/// Loads config in priority order: (1) ~/.config/hana/, (2) ./config/, (3) ~/.config/hana/config.toml,
/// (4) ./config.toml, (5) embedded fallback.
pub fn loadConfigDefault(allocator: std.mem.Allocator) !types.Config {
    const home = if (std.c.getenv("HOME")) |h| std.mem.span(h) else "./config";
    const xdg_config_home = std.c.getenv("XDG_CONFIG_HOME");
    const config_home = if (xdg_config_home) |ch|
        std.mem.span(ch)
    else
        try std.fmt.allocPrint(allocator, "{s}/.config", .{home});
    const xdg_dir = try std.fs.path.join(allocator, &.{ config_home, "hana" });

    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    _ = std.c.getcwd(&cwd_buf, cwd_buf.len) orelse return error.CurrentWorkingDirectoryUnlinked;
    const cwd = std.mem.sliceTo(&cwd_buf, 0);
    const local_dir = try std.fs.path.join(allocator, &.{ cwd, "config" });

    // Try directories first (contain multiple .toml files), then single files.
    // `else |_| {}` intentionally swallows errors: FileNotFound/NotDir are
    // expected when a path doesn't exist, and OOM is already caught at the
    // `try` level above; remaining errors are non-fatal (e.g. a corrupt .toml
    // in a config dir) and we simply try the next candidate.
    const dir_attempts = [_][]const u8{ xdg_dir, local_dir };
    for (dir_attempts) |dir| {
        if (loadConfigFromDir(allocator, dir)) |cfg| return cfg else |_| {}
    }

    const xdg_path = try std.fs.path.join(allocator, &.{ xdg_dir, "config.toml" });
    const local = try std.fs.path.join(allocator, &.{ cwd, "config.toml" });
    const file_attempts = [_][]const u8{ xdg_path, local };
    for (file_attempts) |path| {
        if (tryLoadConfig(allocator, path)) |cfg| return cfg;
    }

    debug.info("No config found, using fallback with auto-detection", .{});
    return try loadFallbackConfig(allocator);
}

/// Validates domain invariants on a freshly loaded config.
pub fn validate(cfg: *const types.Config) !void {
    if (cfg.tiling.master_count == 0) {
        debug.err("Invalid config: master_count must be > 0, keeping old", .{});
        return error.InvalidConfig;
    }
    // master_width is a ScalableValue: percentages validate as a
    // [min_master_width, max_master_width] ratio; pixels only as >= 0, since
    // the screen width for a ratio isn't available here and the runtime clamps:
    // a pixel-vs-ratio check would wrongly refuse `master_width = 600`.
    const mw = cfg.tiling.master_width;
    if (mw.is_percentage) {
        const mw_ratio: f32 = utils.scaling.asRatio(mw);
        if (mw_ratio < constants.min_master_width or mw_ratio > constants.max_master_width) {
            debug.err("Invalid config: master_width {d:.0}% out of [{d:.0}%, {d:.0}%], keeping old", .{ mw_ratio * 100.0, constants.min_master_width * 100.0, constants.max_master_width * 100.0 });
            return error.InvalidConfig;
        }
    } else if (mw.value < 0.0) {
        debug.err("Invalid config: master_width {d}px must be >= 0, keeping old", .{mw.value});
        return error.InvalidConfig;
    }
    if (cfg.workspaces.count < 1) {
        debug.err("Invalid config: workspace count must be >= 1, keeping old", .{});
        return error.InvalidConfig;
    }
}

/// Reads, parses, and returns the config at `path` (single-file entry point).
pub fn loadConfig(allocator: std.mem.Allocator, path: []const u8) !types.Config {
    var doc = try parseTomlFile(allocator, path) orelse {
        debug.info("Empty config file: {s}, using fallback", .{path});
        return try loadFallbackConfig(allocator);
    };
    defer doc.deinit();
    try processIncludes(allocator, &doc, &doc, std.fs.path.dirname(path) orelse ".");
    const cfg = try buildConfigFromDoc(allocator, &doc);
    debug.info("Loaded: {s}", .{path});
    return cfg;
}

fn loadFallbackConfig(allocator: std.mem.Allocator) !types.Config {
    const fallback = @import("fallback");
    const fallback_toml = fallback.getFallbackToml() orelse return error.FallbackMissing;
    var doc = try parser.parse(allocator, fallback_toml);
    defer doc.deinit();
    var cfg = try buildConfigFromDoc(allocator, &doc);
    // If the terminal detection/dupe below errors, free the built config
    // rather than leaking it (the `try` above means buildConfigFromDoc's own
    // errdefer already handled its internal failures).
    errdefer cfg.deinit(allocator);
    const terminal = fallback.detectTerminal();
    for (cfg.keybindings.items) |*kb| {
        if (kb.action == .exec and std.mem.eql(u8, kb.action.exec, "auto_terminal")) {
            allocator.free(kb.action.exec);
            kb.action.exec = try allocator.dupe(u8, terminal);
        }
    }

    debug.info("Loaded fallback configuration with auto-detection", .{});
    return cfg;
}

/// Builds the built-in default Config: every scalar knob comes from
/// schema.applyDefaults (the one table; schema_test.zig pins it to
/// types.Config's field initializers), plus heap-dup'd non-scalar seed data
/// so deinit can free every owned field unconditionally, and one `layouts`
/// entry so the layout cycle always has something to rotate. OOM propagates;
/// the errdefer tears down the partial Config, never leaving string literals
/// for deinit to free.
fn getDefaultConfig(allocator: std.mem.Allocator) !types.Config {
    var cfg: types.Config = .{};
    errdefer cfg.deinit(allocator);
    schema.applyDefaults(&cfg);
    // Canonical layout_table name (the .master entry), so the default resolves
    // via layoutFromString in workspaces.zig and stringToEnum in tiling.zig;
    // the old "master_left" matched neither and worked only via `orelse`.
    const default_layout = try allocator.dupe(u8, "master-stack");
    try cfg.tiling.layouts.append(allocator, default_layout);
    cfg.tiling.layout = cfg.tiling.layouts.items[0];
    const default_icons = [_][]const u8{ "1", "2", "3", "4", "5", "6", "7", "8", "9" };
    for (default_icons) |icon| {
        try cfg.bar.workspace_icons.append(allocator, try allocator.dupe(u8, icon));
    }
    try initDefaultBarLayout(allocator, &cfg);
    return cfg;
}

fn buildConfigFromDoc(allocator: std.mem.Allocator, doc: *parser.Document) !types.Config {
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
    try parseBar(allocator, doc, &cfg);
    try parseRules(allocator, doc, &cfg);
    warnUnconsumedSections(doc);
    return cfg;
}

/// Warns about keys no parse function examined, to surface typos the parser
/// would otherwise accept silently.
fn warnUnconsumedSections(doc: *parser.Document) void {
    doc.root.warnUnconsumed("<root>");
    var iter = doc.sections.iterator();
    while (iter.next()) |entry|
        entry.value_ptr.warnUnconsumed(entry.key_ptr.*);
}

const mod_map = std.StaticStringMap(u16).initComptime(.{
    .{ "super", x11_masks.mod_super },
    .{ "mod4", x11_masks.mod_super },
    .{ "alt", x11_masks.mod_alt },
    .{ "mod1", x11_masks.mod_alt },
    .{ "control", x11_masks.mod_control },
    .{ "ctrl", x11_masks.mod_control },
    .{ "shift", x11_masks.mod_shift },
});

const mouse_button_map = std.StaticStringMap(u8).initComptime(.{
    .{ "button1", 1 }, .{ "left_click", 1 },   .{ "leftclick", 1 },
    .{ "button2", 2 }, .{ "middle_click", 2 }, .{ "middleclick", 2 },
    .{ "button3", 3 }, .{ "right_click", 3 },  .{ "rightclick", 3 },
    .{ "button4", 4 }, .{ "scroll_up", 4 },    .{ "scrollup", 4 },
    .{ "button5", 5 }, .{ "scroll_down", 5 },  .{ "scrolldown", 5 },
});

fn mouseButtonFromName(name: []const u8) ?u8 {
    return switch (types.lowerStringCI(16, name)) {
        .too_long => null,
        .ok => |r| mouse_button_map.get(r.slice()),
    };
}

/// D7: mechanically derived from `types.Action`'s tag names — every action
/// is addressable by its own tag name without a hand-maintained entry. Only
/// genuine ALIASES are listed by hand. Adding an Action union member now
/// requires exactly one edit (the union); forgetting an intended alias fails
/// the parser's unknown-action typo detection instead of silently unparsable.
const action_aliases = [_]struct { key: []const u8, tag: std.meta.Tag(types.Action) }{
    .{ .key = "close", .tag = .close_window },
    .{ .key = "kill", .tag = .close_window },
    .{ .key = "reload", .tag = .reload_config },
    .{ .key = "stack_top", .tag = .grow_stack_top },
    .{ .key = "stack_bottom", .tag = .grow_stack_bottom },
    .{ .key = "fullscreen", .tag = .toggle_fullscreen },
    .{ .key = "minimize", .tag = .minimize_window },
    .{ .key = "cycle_variants", .tag = .cycle_layout_variants },
    .{ .key = "prompt", .tag = .toggle_prompt },
    .{ .key = "focus_next", .tag = .focus_next_window },
    .{ .key = "focus_prev", .tag = .focus_prev_window },
    .{ .key = "scroll_left", .tag = .scroll_view_left },
    .{ .key = "scroll_right", .tag = .scroll_view_right },
};

const action_map: std.StaticStringMap(types.Action) = blk: {
    @setEvalBranchQuota(10000);
    const fields = @typeInfo(types.Action).@"union".fields;
    var kvs: [fields.len + action_aliases.len]struct { []const u8, types.Action } = undefined;
    var n: usize = 0;
    // Tag names first; aliases must not shadow them (checked below).
    for (fields) |f| {
        if (f.type == void) {
            kvs[n] = .{ f.name, @field(types.Action, f.name) };
            n += 1;
        }
    }
    for (action_aliases) |a| {
        for (kvs[0..n]) |kv| {
            if (std.mem.eql(u8, kv[0], a.key)) @compileError("alias shadows an Action tag name: " ++ a.key);
        }
        kvs[n] = .{ a.key, @field(types.Action, @tagName(a.tag)) };
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

/// Expands `{...}` glob patterns in a keybind key (e.g. `Mod+{1-4,Q}` -> 5 entries,
/// comma-separated tokens and single-char ranges supported).  Workspace actions get a
/// 1-based index appended; other actions are replicated unchanged.
/// Returns a single unowned entry when no glob is present.
fn expandGlobKeys(allocator: std.mem.Allocator, key_pattern: []const u8) ![]GlobEntry {
    const lbrace = std.mem.indexOfScalar(u8, key_pattern, '{') orelse return singleGlobEntry(allocator, key_pattern);
    const rbrace = std.mem.indexOfScalarPos(u8, key_pattern, lbrace + 1, '}') orelse {
        debug.warn("Keybind glob missing closing '}}\' in '{s}', treating as literal", .{key_pattern});
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
        if (t.len == 3 and t[1] == '-') {
            var ch = t[0];
            const end = t[2];
            if (ch > end) {
                debug.warn("Keybind glob '{s}': descending range '{c}-{c}', skipping", .{ key_pattern, ch, end });
                continue;
            }
            while (ch <= end) : (ch += 1) {
                if (entries.items.len >= max_glob_expansion) break;
                try entries.append(allocator, .{
                    .key = try std.fmt.allocPrint(allocator, "{s}{c}{s}", .{ prefix, ch, suffix }),
                    .ws_idx = @intCast(entries.items.len + 1),
                    .owned = true,
                });
            }
        } else {
            if (entries.items.len >= max_glob_expansion) break;
            try entries.append(allocator, .{
                .key = try std.fmt.allocPrint(allocator, "{s}{s}{s}", .{ prefix, t, suffix }),
                .ws_idx = @intCast(entries.items.len + 1),
                .owned = true,
            });
        }
    }
    if (entries.items.len == 0) {
        entries.deinit(allocator);
        return singleGlobEntry(allocator, key_pattern);
    }
    return try entries.toOwnedSlice(allocator);
}

const workspace_action_bases = std.StaticStringMap(void).initComptime(.{
    .{ "workspace", {} }, .{ "move_to_workspace", {} }, .{ "toggle_tag", {} },
});

fn resolveAndParseAction(allocator: std.mem.Allocator, cmd: []const u8, ws_idx: u16, kill_placeholder: ?[]const u8) !types.Action {
    const ws_str: ?[]u8 = if (ws_idx > 0 and workspace_action_bases.has(cmd))
        try std.fmt.allocPrint(allocator, "{s}_{d}", .{ cmd, ws_idx })
    else
        null;
    defer if (ws_str) |s| allocator.free(s);
    const after_ws = ws_str orelse cmd;
    if (kill_placeholder) |kp| {
        if (std.mem.indexOf(u8, after_ws, "{kill}") != null) {
            const final = try std.mem.replaceOwned(u8, allocator, after_ws, "{kill}", kp);
            defer allocator.free(final);
            return parseAction(allocator, final);
        }
    }
    return parseAction(allocator, after_ws);
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
            if (arr.items.len == 1) {
                const cmd = arr.items[0].asString() orelse return null;
                return try resolveAndParseAction(allocator, cmd, ws_idx, kill);
            }
            var acts: std.ArrayList(types.Action) = .empty;
            errdefer {
                for (acts.items) |*a| a.deinit(allocator);
                acts.deinit(allocator);
            }
            for (arr.items) |elem| {
                const cmd = elem.asString() orelse continue;
                try acts.append(allocator, try resolveAndParseAction(allocator, cmd, ws_idx, kill));
            }
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
fn resolveModPlaceholder(allocator: std.mem.Allocator, key: []const u8, mod_placeholder: ?[]const u8) ![]const u8 {
    if (mod_placeholder) |mod| {
        if (std.ascii.startsWithIgnoreCase(key, "mod+")) {
            return try std.fmt.allocPrint(allocator, "{s}+{s}", .{ mod, key["mod+".len..] });
        }
    }
    return key;
}

fn parseKeybindings(allocator: std.mem.Allocator, doc: *parser.Document, cfg: *types.Config) !void {
    const section = doc.getSection("binds") orelse doc.getSection("Keybindings") orelse return;
    var mod_placeholder: ?[]const u8 = null;
    var kill_placeholder: ?[]const u8 = null;
    var iter = section.orderedIterator();
    while (iter.next()) |entry| {
        if (std.ascii.eqlIgnoreCase(entry.key, "Mod")) {
            mod_placeholder = entry.value.asString();
            section.markConsumed(entry.key);
            continue;
        }
        if (std.ascii.eqlIgnoreCase(entry.key, "kill")) {
            kill_placeholder = entry.value.asString();
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
                .mouse => |mb| try cfg.mouse_bindings.append(allocator, .{
                    .modifiers = mb.modifiers,
                    .button = mb.button,
                    .action = action,
                }),
                .keyboard => |kb| try cfg.keybindings.append(allocator, .{
                    .modifiers = kb.modifiers,
                    .keysym = kb.keysym,
                    .action = action,
                }),
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
        // Normalise to lowercase (modifiers are case-insensitive) via the same
        // bounded helper mouseButtonFromName uses: an overlong token comes
        // back as `.too_long` instead of overflowing a fixed buffer.
        const mod: ?u16 = switch (types.lowerStringCI(16, trimmed)) {
            .too_long => null,
            .ok => |r| mod_map.get(r.slice()),
        };
        if (mod) |m| {
            modifiers |= m;
        } else if (mouseButtonFromName(trimmed)) |btn| {
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
    const keysym = xkbcommon.xkb_keysym_from_name(@ptrCast(&buf), xkbcommon.xkb_keysym_case_insensitive);
    return if (keysym == xkbcommon.XKB_KEY_NoSymbol) error.UnknownKeyName else keysym;
}

fn tryParseWorkspace(command: []const u8, prefix: []const u8) ?u8 {
    if (!std.mem.startsWith(u8, command, prefix)) return null;
    const num = std.fmt.parseInt(usize, command[prefix.len..], 10) catch return null;
    if (num < 1 or num > 256) return null;
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

fn parseAction(allocator: std.mem.Allocator, cmd: []const u8) !types.Action {
    if (action_map.get(cmd)) |a| return a;
    if (tryParseWorkspace(cmd, "workspace_")) |ws| return .{ .switch_workspace = ws };
    if (tryParseWorkspace(cmd, "move_to_workspace_")) |ws| return .{ .move_to_workspace = ws };
    if (tryParseWorkspace(cmd, "toggle_tag_")) |ws| return .{ .toggle_tag = ws };
    // The fallback is exec so any shell command can be bound, but a bare word
    // resembling a built-in action is almost always a typo, and running it as
    // an exec (which fails or does nothing) hides the mistake, so warn.
    if (looksLikeActionWord(cmd))
        debug.warn("Unrecognized action '{s}': running it as an exec command: check the spelling (action names are matched exactly)", .{cmd});
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
pub fn load(allocator: std.mem.Allocator, screen: core.Screen, xkb_state: *xkbcommon.XkbState) !types.Config {
    var cfg = try loadConfigDefault(allocator);
    errdefer cfg.deinit(allocator);
    try validate(&cfg);
    cfg.keybind_resolver.build(cfg.keybindings.items, xkb_state, allocator);
    finalizeConfig(&cfg, screen);
    return cfg;
}

/// Tiling's NON-scalar structures: the layouts array (cycle order +
/// per-workspace overrides), per-layout variant preferences, and
/// master-stack counts. Every tiling SCALAR ([tiling] flags, aesthetics,
/// master trio) is driven by schema.applyAll; like parseTiling always did,
/// all of it stays gated on the [tiling] section existing.
fn parseTilingStructures(allocator: std.mem.Allocator, doc: *parser.Document, cfg: *types.Config) !void {
    const section = doc.getSection("tiling") orelse return;
    types.freeStrings(&cfg.tiling.layouts, allocator, true);
    cfg.tiling.workspace_layout_overrides.clearRetainingCapacity();
    if (section.getArray("layouts")) |arr| {
        try parseLayoutsArray(allocator, arr, cfg);
        if (cfg.tiling.layouts.items.len > 0) cfg.tiling.layout = cfg.tiling.layouts.items[0];
    } else {
        // Single-layout path: clear the getDefaultConfig default. The "layout"
        // fallback is (types.TilingConfig{}).layout, NOT cfg.tiling.layout:
        // that aliases layouts.items[0], freed below, so using it would read
        // freed memory when the key is absent.
        const layout_str = schema.getInRange([]const u8, section, "layout", default_tiling_layout, null, null);
        try cfg.tiling.layouts.append(allocator, try allocator.dupe(u8, layout_str));
        cfg.tiling.layout = cfg.tiling.layouts.items[0];
    }
    parseTilingVariants(doc, cfg);
    try parseMasterStackCounts(allocator, doc, cfg);
}

/// Per-workspace master count overrides: [tiling.layouts.master-stack.counts]
/// workspace_number (1-based) = count. Only meaningful when global_layout = false.
fn parseMasterStackCounts(allocator: std.mem.Allocator, doc: *parser.Document, cfg: *types.Config) !void {
    const counts_sec = doc.getSection("tiling.layouts.master-stack.counts") orelse return;
    cfg.tiling.workspace_master_count_overrides.clearRetainingCapacity();
    var iter = counts_sec.orderedIterator();
    while (iter.next()) |entry| {
        counts_sec.markConsumed(entry.key);
        const ws_1based = std.fmt.parseInt(usize, entry.key, 10) catch {
            debug.warn("master-stack.counts: invalid workspace key '{s}', skipping", .{entry.key});
            continue;
        };
        if (!checkWorkspaceBound(ws_1based, "master-stack.counts", constants.max_workspaces)) continue;
        const count_val = entry.value.asInt() orelse {
            debug.warn("master-stack.counts: non-integer count for workspace {}, skipping", .{ws_1based});
            continue;
        };
        if (count_val < 0 or count_val > 10) {
            debug.warn("master-stack.counts: count {} for workspace {} out of range [0,10], skipping", .{ count_val, ws_1based });
            continue;
        }
        try cfg.tiling.workspace_master_count_overrides.append(allocator, .{
            .workspace_idx = @intCast(ws_1based - 1),
            .count = @intCast(count_val),
        });
    }
}

/// Reads `variants` from `section` into `field`; warns on unknown values.
fn tryParseVariant(
    comptime T: type,
    section: *parser.Section,
    layout_name: []const u8,
    field: *T,
) void {
    const v = section.getString("variants") orelse return;
    field.* = std.meta.stringToEnum(T, v) orelse {
        debug.warn("Unknown {s} variants '{s}', using default", .{ layout_name, v });
        return;
    };
}

fn parseTilingVariants(doc: *parser.Document, cfg: *types.Config) void {
    inline for (types.variant_layouts) |e| {
        const section_name = "tiling.layouts." ++ e.name;
        if (doc.getSection(section_name)) |ms| {
            tryParseVariant(e.variant, ms, e.name, &@field(cfg.tiling, e.field));
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

/// Canonicalises a layout name via types.layout_table's aliases (e.g. "master"
/// -> "master-stack"), case-insensitively. Returns null for names that are
/// overlong or match no entry; the caller distinguishes the two for its warning.
fn canonicalLayout(name: []const u8) ?[]const u8 {
    const lowered = switch (types.lowerStringCI(32, name)) {
        .too_long => return null,
        .ok => |r| r.slice(),
    };
    for (types.layout_table) |entry| {
        if (std.mem.eql(u8, lowered, entry.name)) return entry.name;
        for (entry.aliases) |alias| {
            if (std.mem.eql(u8, lowered, alias)) return entry.name;
        }
    }
    return null;
}

/// Parses a variants string for the given layout name into a LayoutVariantOverride.
/// Returns null and emits a warning when the string is not valid for that layout.
fn parseLayoutVariant(layout_name: []const u8, variants_str: []const u8) ?types.LayoutVariantOverride {
    // A named local (not a switch-arm capture) so `lowered.ok.buf` outlives
    // the expression: lower_layout borrows from it later in this function.
    const lowered = types.lowerStringCI(32, layout_name);
    if (lowered == .too_long) {
        // Distinguished from "unknown layout" below so a genuinely overlong
        // name gets a message pointing at the real problem, not a plain typo.
        debug.warn("layouts array: layout name '{s}' too long to match against a variant type, ignoring variants '{s}'", .{ layout_name, variants_str });
        return null;
    }
    const lower_layout = lowered.ok.slice();
    inline for (types.variant_layouts) |entry| {
        if (std.mem.eql(u8, lower_layout, entry.name)) {
            const v = std.meta.stringToEnum(entry.variant, variants_str) orelse {
                debug.warn("Unknown {s} variants '{s}' in layouts array, ignoring", .{ entry.name, variants_str });
                return null;
            };
            return @unionInit(types.LayoutVariantOverride, entry.tag, v);
        }
    }
    return null;
}

/// Parses a comma-separated workspace list string (e.g. "1,3,5") and appends
/// one WorkspaceLayoutOverride per valid workspace to `overrides`.
fn parseWorkspaceListInto(
    allocator: std.mem.Allocator,
    ws_str: []const u8,
    layout_name: []const u8,
    layout_idx: u8,
    variant: ?types.LayoutVariantOverride,
    overrides: *std.ArrayList(types.WorkspaceLayoutOverride),
) !void {
    var ws_iter = std.mem.splitScalar(u8, ws_str, ',');
    while (ws_iter.next()) |ws_tok| {
        const trimmed = std.mem.trim(u8, ws_tok, " \t");
        const ws_1based = std.fmt.parseInt(usize, trimmed, 10) catch {
            debug.warn("layouts array: invalid workspace number '{s}' for layout '{s}', skipping", .{ trimmed, layout_name });
            continue;
        };
        if (!checkWorkspaceBound(ws_1based, "layouts array", constants.max_workspaces)) continue;
        try overrides.append(allocator, .{
            .workspace_idx = @intCast(ws_1based - 1),
            .layout_idx = layout_idx,
            .variant = variant,
        });
    }
}

/// Parses the `layouts` TOML array.  A known layout name starts a new group; the
/// optional next element is a variants word or a workspace list ("1,3,5"); a third
/// may follow as a workspace list when the second was a variants.
/// Plain single-name format ("master-stack") is fully backward-compatible.
fn parseLayoutsArray(
    allocator: std.mem.Allocator,
    arr: []const parser.Value,
    cfg: *types.Config,
) !void {
    var i: usize = 0;
    while (i < arr.len) : (i += 1) {
        const name_str = arr[i].asString() orelse {
            debug.warn("layouts array: expected a string at index {}, skipping", .{i});
            continue;
        };
        const canonical = canonicalLayout(name_str) orelse {
            if (name_str.len > 32) {
                debug.warn("layouts array: layout name '{s}' at index {} is longer than the 32-byte limit, skipping", .{ name_str, i });
            } else {
                debug.warn("layouts array: unknown layout name '{s}' at index {}, skipping", .{ name_str, i });
            }
            continue;
        };
        var already_present = false;
        for (cfg.tiling.layouts.items) |existing| {
            if (std.mem.eql(u8, existing, canonical)) {
                already_present = true;
                break;
            }
        }
        if (already_present) {
            debug.warn("layouts array: duplicate layout '{s}' at index {}, skipping", .{ canonical, i });
            continue;
        }
        const layout_idx: u8 = @intCast(cfg.tiling.layouts.items.len);
        try cfg.tiling.layouts.append(allocator, try allocator.dupe(u8, canonical));

        var variants: ?types.LayoutVariantOverride = null;
        var ws_list_str: ?[]const u8 = null;
        if (i + 1 >= arr.len) continue;
        const peek = arr[i + 1].asString() orelse continue;

        if (isWorkspaceList(peek)) {
            ws_list_str = peek;
            i += 1;
        } else if (canonicalLayout(peek) == null) {
            variants = parseLayoutVariant(canonical, peek);
            i += 1;
            if (i + 1 < arr.len) {
                if (arr[i + 1].asString()) |peek2| {
                    if (isWorkspaceList(peek2)) {
                        ws_list_str = peek2;
                        i += 1;
                    }
                }
            }
        }

        if (ws_list_str) |ws_str| {
            try parseWorkspaceListInto(allocator, ws_str, canonical, layout_idx, variants, &cfg.tiling.workspace_layout_overrides);
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
    if (section.getArray("fonts")) |arr| {
        types.freeStrings(&cfg.bar.fonts, allocator, true);
        for (arr) |item| if (item.asString()) |name|
            try cfg.bar.fonts.append(allocator, try allocator.dupe(u8, name));
        debug.info("Loaded {} fonts for bar", .{cfg.bar.fonts.items.len});
    }
    // indicator_focused/unfocused: if only one is set, the other mirrors it.
    // A pair interaction, so it stays bespoke rather than joining the table.
    const raw_focused = section.getString("indicator_focused");
    const raw_unfocused = section.getString("indicator_unfocused");
    const focused_val = raw_focused orelse raw_unfocused;
    const unfocused_val = raw_unfocused orelse raw_focused;
    if (focused_val) |v| try schema.assignStr(allocator, &cfg.bar.indicator_focused, v);
    if (unfocused_val) |v| try schema.assignStr(allocator, &cfg.bar.indicator_unfocused, v);
    try parseWorkspaceIcons(allocator, section, cfg);
    try parseBarLayout(allocator, doc, cfg);
}

fn parseWorkspaceIcons(allocator: std.mem.Allocator, section: *parser.Section, cfg: *types.Config) !void {
    types.freeStrings(&cfg.bar.workspace_icons, allocator, true);
    if (section.getArray("icons")) |arr| {
        for (arr) |item| {
            if (item.asString()) |s| {
                try cfg.bar.workspace_icons.append(allocator, try allocator.dupe(u8, s));
            } else if (item.asInt()) |n| {
                var num_buf: [20]u8 = undefined;
                const s = std.fmt.bufPrint(&num_buf, "{}", .{n}) catch continue;
                try cfg.bar.workspace_icons.append(allocator, try allocator.dupe(u8, s));
            }
        }
    } else if (section.getString("icons")) |str| {
        var ch_buf: [1]u8 = undefined;
        for (str) |ch| {
            ch_buf[0] = ch;
            try cfg.bar.workspace_icons.append(allocator, try allocator.dupe(u8, &ch_buf));
        }
    }

    while (cfg.bar.workspace_icons.items.len < cfg.workspaces.count) {
        var num_buf: [3]u8 = undefined;
        const s = std.fmt.bufPrint(&num_buf, "{}", .{cfg.bar.workspace_icons.items.len + 1}) catch break;
        try cfg.bar.workspace_icons.append(allocator, try allocator.dupe(u8, s));
    }
}

fn parseBarLayout(allocator: std.mem.Allocator, doc: *parser.Document, cfg: *types.Config) !void {
    for (cfg.bar.layout.items) |*item| item.deinit(allocator);
    cfg.bar.layout.clearRetainingCapacity();
    const positions = [_]struct { name: []const u8, pos: types.BarSegmentAnchor }{
        .{ .name = "bar.layout.left", .pos = .left },
        .{ .name = "bar.layout.center", .pos = .center },
        .{ .name = "bar.layout.right", .pos = .right },
    };
    for (positions) |p| {
        const layout_section = doc.getSection(p.name) orelse continue;
        var bar_layout = types.BarLayout{ .position = p.pos, .segments = .empty };
        if (layout_section.getArray("segments")) |seg_arr|
            for (seg_arr) |item| if (item.asString()) |s|
                if (std.meta.stringToEnum(types.BarSegment, s)) |segment|
                    try bar_layout.segments.append(allocator, segment)
                else
                    debug.warn("Unknown bar segment '{s}', skipping", .{s});
        if (bar_layout.segments.items.len > 0) {
            try cfg.bar.layout.append(allocator, bar_layout);
        } else {
            bar_layout.deinit(allocator);
        }
    }

    if (cfg.bar.layout.items.len == 0) try initDefaultBarLayout(allocator, cfg);
}

fn parseRules(allocator: std.mem.Allocator, doc: *parser.Document, cfg: *types.Config) !void {
    // [workspace.rules]: key is either a class name (value = ws int) or
    // a workspace number (value = class array). Both directions call addRule.
    if (doc.getSection("workspace.rules")) |rules_section| {
        try parseWorkspaceRuleSection(allocator, cfg, rules_section);
    }

    // [rules]: simple class -> workspace mapping (key = class, value = ws int).
    if (doc.getSection("rules")) |rules_section| {
        var iter = rules_section.orderedIterator();
        while (iter.next()) |entry| {
            rules_section.markConsumed(entry.key);
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
        const ws_str = if (std.mem.startsWith(u8, name, "workspace.rules."))
            name["workspace.rules.".len..]
        else if (std.mem.startsWith(u8, name, "rules."))
            name["rules.".len..]
        else
            continue;
        const ws_num = std.fmt.parseInt(usize, ws_str, 10) catch continue;
        if (!checkWorkspaceBound(ws_num, name, cfg.workspaces.count)) continue;
        var iter = entry.value_ptr.orderedIterator();
        while (iter.next()) |class_entry| {
            entry.value_ptr.markConsumed(class_entry.key);
            try addRule(allocator, cfg, class_entry.key, ws_num);
        }
    }
}

/// Parses `value` as a workspace int and, if valid, adds a rule mapping
/// `class_name` to that workspace. Shared by the class-keyed direction of
/// [workspace.rules] and by [rules], which is always class-keyed.
fn tryAddClassRule(allocator: std.mem.Allocator, cfg: *types.Config, class_name: []const u8, value: parser.Value) !void {
    const ws_num = value.asInt() orelse {
        debug.warn("Rule for '{s}' has non-integer value, skipping", .{class_name});
        return;
    };
    if (ws_num < 1) {
        debug.warn("Rule workspace {d} for '{s}' below minimum 1, skipping", .{ ws_num, class_name });
        return;
    }
    const ws: usize = @intCast(ws_num);
    if (!checkWorkspaceBound(ws, class_name, cfg.workspaces.count)) return;
    try addRule(allocator, cfg, class_name, ws);
}

/// Handle the [workspace.rules] section where the key may be a class name
/// (integer value -> workspace) or a workspace number (array value -> classes).
fn parseWorkspaceRuleSection(
    allocator: std.mem.Allocator,
    cfg: *types.Config,
    rules_section: *parser.Section,
) !void {
    var iter = rules_section.orderedIterator();
    while (iter.next()) |entry| {
        rules_section.markConsumed(entry.key);
        const ws_num = std.fmt.parseInt(usize, entry.key, 10) catch {
            try tryAddClassRule(allocator, cfg, entry.key, entry.value);
            continue;
        };
        if (!checkWorkspaceBound(ws_num, entry.key, cfg.workspaces.count)) continue;
        if (entry.value.asArray()) |arr| {
            for (arr) |item| {
                if (item.asString()) |class_name| try addRule(allocator, cfg, class_name, ws_num);
            }
        }
    }
}
