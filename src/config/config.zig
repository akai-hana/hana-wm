//! Configuration interpreter
//! Loads, parses, and validates TOML config files.

const std = @import("std");
const core = @import("core");
const types = @import("types");
const constants = @import("constants");
const debug = @import("debug");
const xkbcommon = @import("xkbcommon");
const parser = @import("parser");
const carousel = @import("carousel");
const utils = @import("utils");

/// Returns `default` when the key is absent, the wrong type, or out of range
/// (values are warn-and-revert, not clamped).
fn getInRange(
    comptime T: type,
    section: *parser.Section,
    key: []const u8,
    default: T,
    comptime min: ?T,
    comptime max: ?T,
) T {
    const value = switch (T) {
        bool => section.getBool(key) orelse return default,
        []const u8 => section.getString(key) orelse return default,
        u8, u16, u32, usize => blk: {
            const i = section.getInt(key) orelse return default;
            // A negative int would trap on the @intCast below; warn-and-default
            // it here so the out-of-range contract holds for negatives too.
            if (i < 0) {
                debug.warn("Value for '{s}' ({d}) below minimum (0), using default", .{ key, i });
                return default;
            }
            // Guard the type's own range before the cast: an int larger than T
            // can hold would trap on @intCast even when no explicit max is set.
            // (For u64/usize the comparison is comptime-folded away.)
            if (std.math.maxInt(T) < std.math.maxInt(i64) and i > std.math.maxInt(T)) {
                debug.warn("Value for '{s}' ({d}) above maximum ({d}), using default", .{ key, i, std.math.maxInt(T) });
                return default;
            }
            break :blk @as(T, @intCast(i));
        },
        else => @compileError("Unsupported type"),
    };
    if (comptime min) |m| if (value < m) {
        debug.warn("Value for '{s}' ({any}) below minimum ({any}), using default", .{ key, value, m });
        return default;
    };
    if (comptime max) |m| if (value > m) {
        debug.warn("Value for '{s}' ({any}) above maximum ({any}), using default", .{ key, value, m });
        return default;
    };
    return value;
}

/// Resolves a color from a section key, accepting `#RRGGBB`, `0xRRGGBB`, or an integer.
inline fn getColor(section: *parser.Section, key: []const u8, default: u32) u32 {
    const value = section.get(key) orelse return default;
    if (value.asColor()) |c| return c;
    if (value.asString()) |s| return parser.parseColor(s) catch {
        debug.warn("Invalid color for {s}: '{s}'", .{ key, s });
        return default;
    };
    if (value.asInt()) |i| if (i >= 0 and i <= 0xFFFFFF) return @intCast(i);
    return default;
}

/// Like getInRange, but for ScalableValue fields. Only enforces a lower bound
/// on the raw `.value` (percentages and absolute pixels share no meaningful
/// ceiling) — enough to reject a negative like `gap_width = -50`. Returns
/// `default` unclamped, with a warning, matching getInRange.
fn getScalableInRange(
    section: *parser.Section,
    key: []const u8,
    default: parser.ScalableValue,
    comptime min: f32,
) parser.ScalableValue {
    const value = section.getScalable(key) orelse return default;
    if (value.value < min) {
        debug.warn("Value for '{s}' ({d}) below minimum ({d}), using default", .{ key, value.value, min });
        return default;
    }
    return value;
}

/// Validates a 1-based workspace number, warn-and-skip (returns false) when it
/// is outside the syntactic 1..255 range or exceeds `max` — the configured
/// workspace count for window rules, or constants.MAX_WORKSPACES (the hard
/// ceiling behind workspaces.zig's fixed-size override lookup tables) for
/// per-workspace overrides. Checking that ceiling at parse time reports an
/// override that can never take effect immediately, instead of silently
/// dropping it later when workspaces.init() builds its tables.
inline fn checkWorkspaceBound(ws_1based: usize, context: []const u8, max: usize) bool {
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

inline fn addRule(allocator: std.mem.Allocator, cfg: *types.Config, class_name: []const u8, ws_num: usize) !void {
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

/// Maximum bytes accepted from a single .toml file (1 MiB).
const MAX_FILE_BYTES = 1024 * 1024;

/// Reads the file at `path` into a freshly allocated slice owned by the caller.
/// Returns `error.FileTooLarge` when the file exceeds `MAX_FILE_BYTES`.
///
/// Allocates the full MAX_FILE_BYTES + 1 ceiling up front, then reallocs down
/// — config loading is startup/reload-only, so it's not worth a stat-then-
/// allocate dance (and its TOCTOU re-check) for a cost this low-frequency.
fn readFileAlloc(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const io = std.Options.debug_io;
    const file = std.Io.Dir.openFileAbsolute(io, path, .{}) catch |err| {
        if (err == error.FileNotFound) debug.info("Not found: {s}", .{path});
        return err;
    };
    defer file.close(io);
    const buf = try allocator.alloc(u8, MAX_FILE_BYTES + 1);
    errdefer allocator.free(buf);
    const n = try file.readPositionalAll(io, buf, 0);
    if (n > MAX_FILE_BYTES) {
        allocator.free(buf);
        return error.FileTooLarge;
    }
    return allocator.realloc(buf, n) catch buf[0..n];
}

/// Reads and parses the .toml at `path`, returning null for an empty file.
/// Read/parse errors propagate to the caller, who decides how to handle them.
fn parseTomlFile(allocator: std.mem.Allocator, path: []const u8) !?parser.Document {
    const raw = try readFileAlloc(allocator, path);
    defer allocator.free(raw);
    if (raw.len == 0) return null;
    return try parser.parse(allocator, raw);
}

/// warn-and-skip wrapper around parseTomlFile — the "never crash on bad
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
///
/// Includes are resolved one level deep only — an included file's own
/// `include` directive is intentionally not processed. This keeps the include
/// graph cycle-free by construction (no cycle-detection machinery needed) at
/// the cost of no chained includes.
fn processIncludes(allocator: std.mem.Allocator, dst: *parser.Document, src_doc: *parser.Document, dir_path: []const u8) !void {
    // The `include` key is copied into `dst` by mergeDocumentsInto, so mark it
    // consumed there as well — otherwise warnUnconsumed would flag it as a typo.
    dst.root.markConsumed("include");
    const inc_val = src_doc.get("include") orelse return;
    const includes = inc_val.asArray() orelse return;
    for (includes) |item| {
        const rel = item.asString() orelse continue;
        if (!std.mem.endsWith(u8, rel, ".toml")) {
            debug.warn("include '{s}': path must end in .toml — skipping", .{rel});
            continue;
        }
        const abs = try std.fs.path.join(allocator, &.{ dir_path, rel });
        defer allocator.free(abs);
        var inc_doc = tryParseTomlFile(allocator, abs) orelse continue;
        defer inc_doc.deinit();
        // Note: inc_doc's own `include` array (if any) is intentionally NOT
        // processed here — see the doc comment above.
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
/// then returns null for any other error — eliminating the repeated
/// try/print/fall-through pattern in loadConfigDefault.
inline fn tryLoadConfig(allocator: std.mem.Allocator, path: []const u8) ?types.Config {
    return loadConfig(allocator, path) catch |err| {
        if (err != error.FileNotFound)
            std.debug.print(
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
    defer if (xdg_config_home == null) allocator.free(config_home);
    const xdg_dir = try std.fs.path.join(allocator, &.{ config_home, "hana" });
    defer allocator.free(xdg_dir);
    if (loadConfigFromDir(allocator, xdg_dir)) |cfg| return cfg else |_| {}
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    _ = std.c.getcwd(&cwd_buf, cwd_buf.len) orelse return error.CurrentWorkingDirectoryUnlinked;
    const cwd = try allocator.dupe(u8, std.mem.sliceTo(&cwd_buf, 0));
    defer allocator.free(cwd);
    const local_dir = try std.fs.path.join(allocator, &.{ cwd, "config" });
    defer allocator.free(local_dir);
    if (loadConfigFromDir(allocator, local_dir)) |cfg| return cfg else |_| {}
    const xdg_path = try std.fs.path.join(allocator, &.{ xdg_dir, "config.toml" });
    defer allocator.free(xdg_path);
    if (tryLoadConfig(allocator, xdg_path)) |cfg| return cfg;
    const local = try std.fs.path.join(allocator, &.{ cwd, "config.toml" });
    defer allocator.free(local);
    if (tryLoadConfig(allocator, local)) |cfg| return cfg;
    debug.info("No config found, using fallback with auto-detection", .{});
    return try loadFallbackConfig(allocator);
}

/// Validates domain invariants on a freshly loaded config.
pub fn validate(cfg: *const types.Config) !void {
    if (cfg.tiling.master_count == 0) {
        debug.err("Invalid config: master_count must be > 0, keeping old", .{});
        return error.InvalidConfig;
    }
    // master_width is stored as a ScalableValue. Percentages are validated as
    // a [MIN_MASTER_WIDTH, MAX_MASTER_WIDTH] ratio (the runtime never lets the
    // master consume the full screen — the same cap the increase_master_width
    // action and the pixel->ratio conversion clamp to). Absolute pixel values
    // are checked as pixels (>= 0 only): converting them to a ratio needs the
    // screen width, which isn't available here, and the runtime clamps the
    // resulting fraction into range itself — so rejecting them outright (the
    // old behaviour, which compared raw pixels against the ratio bounds) would
    // wrongly refuse a perfectly valid `master_width = 600`.
    const mw = cfg.tiling.master_width;
    if (mw.is_percentage) {
        const mw_ratio: f32 = utils.scaling.asRatio(mw);
        if (mw_ratio < constants.MIN_MASTER_WIDTH or mw_ratio > constants.MAX_MASTER_WIDTH) {
            debug.err("Invalid config: master_width {d:.0}% out of [{d:.0}%, {d:.0}%], keeping old", .{ mw_ratio * 100.0, constants.MIN_MASTER_WIDTH * 100.0, constants.MAX_MASTER_WIDTH * 100.0 });
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

/// Builds the built-in default Config: heap-dup'd strings so deinit can free
/// every owned field unconditionally, plus one entry in `layouts` so the
/// layout cycle always has something to rotate. Fallible: an OOM propagates
/// and the partially-built Config is torn down by the errdefer, never left
/// holding string literals that a later deinit would free.
fn getDefaultConfig(allocator: std.mem.Allocator) !types.Config {
    var cfg: types.Config = .{};
    errdefer cfg.deinit(allocator);
    // Canonical LAYOUT_TABLE name (types.LAYOUT_TABLE's .master entry), so the
    // default is resolvable by layoutFromString in workspaces.zig and falls
    // through to .master in tiling.zig's stringToEnum check — the historical
    // "master_left" matched neither and only worked via `orelse` fallbacks.
    const default_layout = try allocator.dupe(u8, "master-stack");
    try cfg.tiling.layouts.append(allocator, default_layout);
    cfg.tiling.layout = cfg.tiling.layouts.items[0];
    // Dupe the four BarConfig string fields parseBar may rewrite, so
    // Config.deinit can free each unconditionally (assignStr's ownership
    // transfer keeps the rewrite path leak-free).
    const defaults = [_]struct { view: *[]const u8, literal: []const u8 }{
        .{ .view = &cfg.bar.clock_format, .literal = "%Y-%m-%d %H:%M:%S" },
        .{ .view = &cfg.bar.drun_prompt, .literal = "run: " },
        .{ .view = &cfg.bar.indicator_focused, .literal = "■" },
        .{ .view = &cfg.bar.indicator_unfocused, .literal = "□" },
    };
    for (defaults) |d| d.view.* = try allocator.dupe(u8, d.literal);
    for (0..9) |i| {
        const icon = try std.fmt.allocPrint(allocator, "{}", .{i + 1});
        try cfg.bar.workspace_icons.append(allocator, icon);
    }
    try initDefaultBarLayout(allocator, &cfg);
    return cfg;
}

/// Builds a Config from a parsed Document: initialises defaults then applies all sections.
fn buildConfigFromDoc(allocator: std.mem.Allocator, doc: *parser.Document) !types.Config {
    var cfg = try getDefaultConfig(allocator);
    // If any parse step below errors (OOM), free the partial Config so the
    // half-applied section doesn't leak. Only armed after getDefaultConfig
    // succeeded, so its own errdefer handled the earlier failure.
    errdefer cfg.deinit(allocator);
    parseWorkspaces(doc, &cfg);
    try parseKeybindings(allocator, doc, &cfg);
    try parseTiling(allocator, doc, &cfg);
    try parseBar(allocator, doc, &cfg);
    try parseRules(allocator, doc, &cfg);
    parseDrag(doc, &cfg);
    parseEnabledFlag(doc, "fullscreen", &cfg.fullscreen_enabled);
    parseEnabledFlag(doc, "minimize", &cfg.minimize_enabled);
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

const MOD_MAP = std.StaticStringMap(u16).initComptime(.{
    .{ "super", constants.MOD_SUPER },
    .{ "mod4", constants.MOD_SUPER },
    .{ "alt", constants.MOD_ALT },
    .{ "mod1", constants.MOD_ALT },
    .{ "control", constants.MOD_CONTROL },
    .{ "ctrl", constants.MOD_CONTROL },
    .{ "shift", constants.MOD_SHIFT },
});

const MOUSE_BUTTON_MAP = std.StaticStringMap(u8).initComptime(.{
    .{ "button1", 1 },      .{ "left_click", 1 },   .{ "leftclick", 1 },
    .{ "button2", 2 },      .{ "middle_click", 2 }, .{ "middleclick", 2 },
    .{ "button3", 3 },      .{ "right_click", 3 },  .{ "rightclick", 3 },
    .{ "button4", 4 },      .{ "scroll_up", 4 },    .{ "scrollup", 4 },
    .{ "button5", 5 },      .{ "scroll_down", 5 },  .{ "scrolldown", 5 },
});

inline fn mouseButtonFromName(name: []const u8) ?u8 {
    return switch (types.lowerStringCI(16, name)) {
        .too_long => null,
        .ok => |r| MOUSE_BUTTON_MAP.get(r.slice()),
    };
}

const ACTION_MAP = std.StaticStringMap(types.Action).initComptime(.{
    .{ "close", .close_window },
    .{ "close_window", .close_window },
    .{ "kill", .close_window },
    .{ "reload", .reload_config },
    .{ "reload_config", .reload_config },
    .{ "toggle_layout", .toggle_layout },
    .{ "toggle_layout_reverse", .toggle_layout_reverse },
    .{ "toggle_bar_visibility", .toggle_bar_visibility },
    .{ "toggle_bar_position", .toggle_bar_position },
    .{ "increase_master", .increase_master },
    .{ "decrease_master", .decrease_master },
    .{ "increase_master_count", .increase_master_count },
    .{ "decrease_master_count", .decrease_master_count },
    .{ "grow_stack_top", .grow_stack_top },
    .{ "stack_top", .grow_stack_top }, // short alias
    .{ "grow_stack_bottom", .grow_stack_bottom },
    .{ "stack_bottom", .grow_stack_bottom }, // short alias
    .{ "toggle_floating_window", .toggle_floating_window },
    .{ "toggle_fullscreen", .toggle_fullscreen },
    .{ "fullscreen", .toggle_fullscreen },
    .{ "swap_master", .swap_master },
    .{ "swap_master_focus_swap", .swap_master_focus_swap },
    .{ "dump_state", .dump_state },
    .{ "minimize_window", .minimize_window },
    .{ "minimize", .minimize_window },
    .{ "unminimize_lifo", .unminimize_lifo },
    .{ "unminimize_fifo", .unminimize_fifo },
    .{ "unminimize_all", .unminimize_all },
    .{ "cycle_layout_variants", .cycle_layout_variants },
    .{ "cycle_variants", .cycle_layout_variants },
    .{ "toggle_prompt", .toggle_prompt },
    .{ "prompt", .toggle_prompt },
    .{ "all_workspaces", .all_workspaces },
    .{ "move_to_all_workspaces", .move_to_all_workspaces },
    .{ "toggle_tag_all", .toggle_tag_all },
    .{ "focus_next_window", .focus_next_window },
    .{ "focus_next", .focus_next_window },
    .{ "focus_prev_window", .focus_prev_window },
    .{ "focus_prev", .focus_prev_window },
    .{ "move_window_next", .move_window_next },
    .{ "move_window_prev", .move_window_prev },
    .{ "scroll_view_left", .scroll_view_left },
    .{ "scroll_view_right", .scroll_view_right },
    .{ "scroll_left", .scroll_view_left }, // short alias
    .{ "scroll_right", .scroll_view_right }, // short alias
});

const GlobEntry = struct {
    key: []const u8,
    ws_idx: u16, // 1-based position in the expanded list; 0 when there is no glob
    owned: bool, // true when key was heap-allocated and must be freed by the caller
};

/// Maximum number of keys a single `{…}` glob may expand to. Workspace
/// indices only reach 256 (see tryParseWorkspace), and a larger glob could
/// only ever produce unreachable exec fallbacks — so expansion stops there.
const MAX_GLOB_EXPANSION: usize = 256;

/// Wraps `key` as the single unowned GlobEntry returned when a keybind key
/// has no `{…}` glob (or an unusable one) to expand.
fn singleGlobEntry(allocator: std.mem.Allocator, key: []const u8) ![]GlobEntry {
    const e = try allocator.alloc(GlobEntry, 1);
    e[0] = .{ .key = key, .ws_idx = 0, .owned = false };
    return e;
}

/// Expands `{…}` glob patterns in a keybind key (e.g. `Mod+{1-4,Q}` -> 5 entries,
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
    var keys: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (keys.items) |k| allocator.free(k);
        keys.deinit(allocator);
    }

    var it = std.mem.splitScalar(u8, inner, ',');
    outer: while (it.next()) |token| {
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
                if (keys.items.len >= MAX_GLOB_EXPANSION) {
                    debug.warn("Keybind glob '{s}': expansion exceeds {} keys, truncating", .{ key_pattern, MAX_GLOB_EXPANSION });
                    break :outer;
                }
                try keys.append(allocator, try std.fmt.allocPrint(allocator, "{s}{c}{s}", .{ prefix, ch, suffix }));
            }
        } else {
            if (keys.items.len >= MAX_GLOB_EXPANSION) {
                debug.warn("Keybind glob '{s}': expansion exceeds {} keys, truncating", .{ key_pattern, MAX_GLOB_EXPANSION });
                break :outer;
            }
            try keys.append(allocator, try std.fmt.allocPrint(allocator, "{s}{s}{s}", .{ prefix, t, suffix }));
        }
    }

    if (keys.items.len == 0) {
        keys.deinit(allocator);
        return singleGlobEntry(allocator, key_pattern);
    }

    const entries = try allocator.alloc(GlobEntry, keys.items.len);
    for (keys.items, 0..) |k, i|
        entries[i] = .{ .key = k, .ws_idx = @intCast(i + 1), .owned = true };
    keys.deinit(allocator);
    return entries;
}

const WORKSPACE_ACTION_BASES = std.StaticStringMap(void).initComptime(.{
    .{ "workspace", {} }, .{ "move_to_workspace", {} }, .{ "toggle_tag", {} },
});

fn resolveAndParseAction(allocator: std.mem.Allocator, cmd: []const u8, ws_idx: u16, kill_placeholder: ?[]const u8) !types.Action {
    const ws_str: ?[]u8 = if (ws_idx > 0 and WORKSPACE_ACTION_BASES.has(cmd))
        try std.fmt.allocPrint(allocator, "{s}_{d}", .{ cmd, ws_idx })
    else
        null;
    defer if (ws_str) |s| allocator.free(s);
    const after_ws = ws_str orelse cmd;
    if (kill_placeholder) |kp| if (std.mem.indexOf(u8, after_ws, "{kill}") != null) {
        const final = try std.mem.replaceOwned(u8, allocator, after_ws, "{kill}", kp);
        defer allocator.free(final);
        return parseAction(allocator, final);
    };
    return parseAction(allocator, after_ws);
}

fn parseKeybindings(allocator: std.mem.Allocator, doc: *parser.Document, cfg: *types.Config) !void {
    const section = doc.getSection("binds") orelse doc.getSection("Keybindings") orelse return;
    // Find Mod and kill placeholders with a single pass over the pairs so that
    // casing in the config file doesn't matter (e.g. "mod", "Mod", "MOD" all work).
    var mod_placeholder: ?[]const u8 = null;
    var kill_placeholder: ?[]const u8 = null;
    {
        var scan = section.orderedIterator();
        while (scan.next()) |e| {
            if (std.ascii.eqlIgnoreCase(e.key, "Mod")) {
                mod_placeholder = e.value.asString();
                section.markConsumed(e.key);
            } else if (std.ascii.eqlIgnoreCase(e.key, "kill")) {
                kill_placeholder = e.value.asString();
                section.markConsumed(e.key);
            }
        }
    }
    var iter = section.orderedIterator();
    while (iter.next()) |entry| {
        if (std.ascii.eqlIgnoreCase(entry.key, "Mod")) continue;
        if (std.ascii.eqlIgnoreCase(entry.key, "kill")) continue;
        section.markConsumed(entry.key);
        const glob_entries = try expandGlobKeys(allocator, entry.key);
        defer {
            for (glob_entries) |ge| if (ge.owned) allocator.free(ge.key);
            allocator.free(glob_entries);
        }
        for (glob_entries) |ge| {
            const keybind_str: []const u8 = blk: {
                if (mod_placeholder) |mod| if (std.ascii.startsWithIgnoreCase(ge.key, "mod+"))
                    break :blk try std.fmt.allocPrint(allocator, "{s}+{s}", .{ mod, ge.key["mod+".len..] });
                break :blk ge.key;
            };
            defer if (keybind_str.ptr != ge.key.ptr) allocator.free(keybind_str);
            const action: types.Action = act: {
                if (entry.value.asArray()) |arr| {
                    var acts: std.ArrayList(types.Action) = .empty;
                    errdefer {
                        for (acts.items) |*a| a.deinit(allocator);
                        acts.deinit(allocator);
                    }
                    for (arr) |elem| {
                        const cmd = elem.asString() orelse continue;
                        try acts.append(allocator, try resolveAndParseAction(allocator, cmd, ge.ws_idx, kill_placeholder));
                    }
                    if (acts.items.len == 0) {
                        acts.deinit(allocator);
                        continue;
                    }
                    if (acts.items.len == 1) {
                        const only = acts.items[0];
                        acts.deinit(allocator);
                        break :act only;
                    }
                    break :act .{ .sequence = try acts.toOwnedSlice(allocator) };
                } else if (entry.value.asString()) |command| {
                    break :act try resolveAndParseAction(allocator, command, ge.ws_idx, kill_placeholder);
                } else continue;
            };
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
        // Normalise to lowercase so modifier names are case-insensitive, via
        // the same bounded helper mouseButtonFromName uses below — an
        // overlong token (longer than any modifier name we recognise) comes
        // back as `.too_long` instead of overflowing a fixed buffer.
        const mod: ?u16 = switch (types.lowerStringCI(16, trimmed)) {
            .too_long => null,
            .ok => |r| MOD_MAP.get(r.slice()),
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
    const keysym = xkbcommon.xkb_keysym_from_name(@ptrCast(&buf), xkbcommon.XKB_KEYSYM_CASE_INSENSITIVE);
    return if (keysym == xkbcommon.XKB_KEY_NoSymbol) error.UnknownKeyName else keysym;
}

inline fn tryParseWorkspace(command: []const u8, prefix: []const u8) ?u8 {
    if (!std.mem.startsWith(u8, command, prefix)) return null;
    const num = std.fmt.parseInt(usize, command[prefix.len..], 10) catch return null;
    if (num < 1 or num > 256) return null;
    return @intCast(num - 1);
}

/// Action verb stems used to spot a keybind action that was *meant* to be one
/// of hana's built-in actions but is spelled wrong. Anything not matching one
/// of these and not containing a shell metacharacter is treated as an ordinary
/// exec command and left alone (e.g. "firefox", "foot", "/usr/bin/emacs").
const ACTION_VERB_PREFIXES = [_][]const u8{
    "toggle_", "increase_", "decrease_", "grow_", "stack_", "swap_",
    "move_", "move_to_", "focus_", "close_", "kill_", "minimize_",
    "unminimize_", "cycle_", "scroll_", "workspace_", "all_", "dump_",
};

/// True when `cmd` is a bare identifier (letters, digits, underscores only —
/// nothing a real shell command would need) that starts with a known action
/// verb stem, i.e. it looks like a misspelled built-in action rather than a
/// legitimate external program.
fn looksLikeActionWord(cmd: []const u8) bool {
    if (cmd.len == 0) return false;
    for (cmd) |c| {
        if (!(std.ascii.isAlphanumeric(c) or c == '_')) return false;
    }
    for (ACTION_VERB_PREFIXES) |p| {
        if (std.mem.startsWith(u8, cmd, p)) return true;
    }
    return false;
}

fn parseAction(allocator: std.mem.Allocator, cmd: []const u8) !types.Action {
    if (ACTION_MAP.get(cmd)) |a| return a;
    if (tryParseWorkspace(cmd, "workspace_")) |ws| return .{ .switch_workspace = ws };
    if (tryParseWorkspace(cmd, "move_to_workspace_")) |ws| return .{ .move_to_workspace = ws };
    if (tryParseWorkspace(cmd, "toggle_tag_")) |ws| return .{ .toggle_tag = ws };
    // The fallback is exec so any shell command can be bound as an action —
    // but a bare word that resembles a built-in action name is almost always
    // a typo, and silently running it as an exec command (which then fails or
    // does nothing) hides the mistake. Warn in that case.
    if (looksLikeActionWord(cmd))
        debug.warn("Unrecognized action '{s}': running it as an exec command — check the spelling (action names are matched exactly)", .{cmd});
    return .{ .exec = try allocator.dupe(u8, cmd) };
}

/// Scales font size and other DPI-dependent fields. Call once the screen is available.
pub inline fn finalizeConfig(cfg: *types.Config, screen: *core.xcb.xcb_screen_t) void {
    const scale_module = @import("scale");
    cfg.bar.scaled_font_size = scale_module.scaleFontSize(cfg.bar.font_size, screen);
}

/// O(1) keybinding lookup for use on the hot key-press path.
/// Returns a pointer into the current config's keybindings slice, or null.
///
/// This delegates to the current config's embedded `keybind_resolver`
/// (core.getState().config.keybind_resolver — see KeybindResolver in
/// types.zig) rather than reading a bare module-level global. Kept as a free
/// function — rather than requiring every call site to spell out
/// `core.getState().config.keybind_resolver.lookup(...)` — because it's
/// called from the hot key-press path in src/core/input/input.zig.
pub inline fn lookupKeybinding(mods: u16, keysym: u32) ?*const types.Action {
    return core.getState().config.keybind_resolver.lookup(mods, keysym);
}

/// Canonical startup/reload entry point: load, validate, resolve keybindings, finalize.
pub fn load(allocator: std.mem.Allocator, screen: *core.xcb.xcb_screen_t, xkb_state: *xkbcommon.XkbState) !types.Config {
    var cfg = try loadConfigDefault(allocator);
    errdefer cfg.deinit(allocator);
    try validate(&cfg);
    cfg.keybind_resolver.build(cfg.keybindings.items, xkb_state, allocator);
    finalizeConfig(&cfg, screen);
    applyCarouselSettings(&cfg);
    return cfg;
}

/// Pushes the config's staged carousel settings onto the carousel's live
/// globals. Called only from load() — i.e. at startup and, via
/// handleConfigReload, AFTER the fully-validated config has been swapped in —
/// so carousel settings can never leak into effect from a config that failed
/// validation and was discarded.
pub fn applyCarouselSettings(cfg: *const types.Config) void {
    carousel.setCarouselEnabled(cfg.bar.carousel_enabled);
    carousel.setScrollSpeed(@as(f64, @floatFromInt(cfg.bar.scroll_speed)));
    carousel.setRefreshRateOverride(@as(f64, @floatFromInt(cfg.bar.carousel_refresh_rate)));
}

fn parseDrag(doc: *parser.Document, cfg: *types.Config) void {
    const section = doc.getSection("drag") orelse return;
    cfg.drag_enabled = getInRange(bool, section, "enabled", cfg.drag_enabled, null, null);
    // Reading the current value as the default avoids duplicating the struct
    // default from types.zig; getScalableInRange also rejects a negative
    // snap_distance.
    cfg.snap_distance = getScalableInRange(section, "snap_distance", cfg.snap_distance, 0.0);
}

fn parseWorkspaces(doc: *parser.Document, cfg: *types.Config) void {
    const section = doc.getSection("bar.modules.workspaces") orelse doc.getSection("workspaces") orelse return;
    cfg.workspaces.enabled = getInRange(bool, section, "enabled", cfg.workspaces.enabled, null, null);
    // Cap at MAX_WORKSPACES: tracking's u64 workspace bitmask and the
    // fixed-size override/fullscreen lookup tables can't represent more, and
    // tracking.setWorkspaceCount asserts the same ceiling — so a larger count
    // would trip that assert in Debug and index out of bounds in release.
    cfg.workspaces.count = getInRange(u8, section, "count", cfg.workspaces.count, 1, @intCast(constants.MAX_WORKSPACES));
}

/// Reads `section_name.enabled` (default true) into `field`. Used for
/// subsystems that are always compiled in and only toggled on/off, like
/// [fullscreen] and [minimize].
fn parseEnabledFlag(doc: *parser.Document, section_name: []const u8, field: *bool) void {
    const section = doc.getSection(section_name) orelse return;
    // Read the already-initialised value back as the default so this helper
    // can't drift out of sync with the field's default in types.zig.
    field.* = getInRange(bool, section, "enabled", field.*, null, null);
}

fn parseTiling(allocator: std.mem.Allocator, doc: *parser.Document, cfg: *types.Config) !void {
    const section = doc.getSection("tiling") orelse return;
    cfg.tiling.enabled = getInRange(bool, section, "enabled", cfg.tiling.enabled, null, null);
    if (section.getArray("layouts")) |arr| {
        for (cfg.tiling.layouts.items) |layout| allocator.free(layout);
        cfg.tiling.layouts.clearRetainingCapacity();
        cfg.tiling.workspace_layout_overrides.clearRetainingCapacity();
        try parseLayoutsArray(allocator, arr, cfg);
        if (cfg.tiling.layouts.items.len > 0) cfg.tiling.layout = cfg.tiling.layouts.items[0];
    } else {
        // Single-layout path: clear the getDefaultConfig default so layouts
        // holds exactly the user's one choice. `cfg.tiling.layout` points into
        // layouts[0]; TilingConfig.deinit frees it.
        //
        // The "layout" default is (types.TilingConfig{}).layout, NOT
        // cfg.tiling.layout — the latter aliases layouts.items[0], which is
        // freed on the next line, so using it as the fallback would read
        // freed memory when the key is absent.
        for (cfg.tiling.layouts.items) |l| allocator.free(l);
        cfg.tiling.layouts.clearRetainingCapacity();
        const layout_str = getInRange([]const u8, section, "layout", (types.TilingConfig{}).layout, null, null);
        try cfg.tiling.layouts.append(allocator, try allocator.dupe(u8, layout_str));
        cfg.tiling.layout = cfg.tiling.layouts.items[0];
    }

    const aesthetic_src = doc.getSection("tiling.aesthetics") orelse section;

    // ScalableValue fields: getScalableInRange rejects a bare negative like
    // `gap_width = -50`. Safe to read the current value as default here —
    // unlike the "layout" string above, nothing frees it first.
    cfg.tiling.gap_width = getScalableInRange(aesthetic_src, "gap_width", cfg.tiling.gap_width, 0.0);
    cfg.tiling.border_width = getScalableInRange(aesthetic_src, "border_width", cfg.tiling.border_width, 0.0);
    cfg.tiling.border_focused = getColor(aesthetic_src, "border_focused", cfg.tiling.border_focused);
    cfg.tiling.border_unfocused = getColor(aesthetic_src, "border_unfocused", cfg.tiling.border_unfocused);
    cfg.tiling.min_window_dim = getInRange(u16, section, "min_window_dim", cfg.tiling.min_window_dim, 1, null);
    const master_src = doc.getSection("tiling.layouts.master-stack") orelse section;
    const dedicated = master_src != section; // true when [tiling.layouts.master-stack] exists
    cfg.tiling.master_count = getInRange(u8, master_src, if (dedicated) "count" else "master_count", cfg.tiling.master_count, 1, null);
    if (master_src.getString(if (dedicated) "side" else "master_side")) |s| cfg.tiling.master_side = types.MasterSide.fromString(s) orelse .left;
    // master_width has its own ratio check in validate(); only leave-alone-
    // when-absent is needed here, not getScalableInRange.
    if (master_src.getScalable(if (dedicated) "width" else "master_width")) |v| cfg.tiling.master_width = v;
    parseTilingVariants(doc, cfg);
    cfg.tiling.global_layout = getInRange(bool, section, "global_layout", cfg.tiling.global_layout, null, null);

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
        if (!checkWorkspaceBound(ws_1based, "master-stack.counts", constants.MAX_WORKSPACES)) continue;
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
inline fn tryParseVariant(
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
    inline for (.{
        .{ "tiling.layouts.master-stack", types.MasterVariant, "master-stack", "master_variant" },
        .{ "tiling.layouts.monocle", types.MonocleVariant, "monocle", "monocle_variant" },
        .{ "tiling.layouts.grid", types.GridVariant, "grid", "grid_variant" },
    }) |e| if (doc.getSection(e[0])) |ms| {
        tryParseVariant(e[1], ms, e[2], &@field(cfg.tiling, e[3]));
    };
}

/// Returns true if `name` (case-insensitive) is a recognised layout name in
/// types.LAYOUT_TABLE.
inline fn isKnownLayout(name: []const u8) bool {
    return switch (types.lowerStringCI(32, name)) {
        .too_long => false,
        .ok => |r| blk: {
            const lower = r.slice();
            for (types.LAYOUT_TABLE) |entry| {
                if (std.mem.eql(u8, lower, entry.name)) break :blk true;
            }
            break :blk false;
        },
    };
}

/// Returns true if `s` looks like a workspace-number list: only digits, commas, spaces,
/// and contains at least one digit.
inline fn isWorkspaceList(s: []const u8) bool {
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

/// Canonicalises a layout name via types.LAYOUT_TABLE's aliases (e.g. "master"
/// -> "master-stack"). Unmatched names come back lowercased, unchanged;
/// isKnownLayout rejects those at the call site.
inline fn canonicalLayout(name: []const u8, buf: *[32]u8) []const u8 {
    // An overlong name (see lowerStringCI) is returned unchanged: the caller
    // immediately passes the result through isKnownLayout, which also uses
    // lowerStringCI and so also reports `.too_long` (as `false`) for it,
    // correctly routing an oversized name into the "unknown layout name"
    // warning path instead of crashing or silently truncating.
    switch (types.lowerStringCI(32, name)) {
        .too_long => return name,
        .ok => |r| {
            const lower = r.slice();
            for (types.LAYOUT_TABLE) |entry| {
                if (std.mem.eql(u8, lower, entry.name)) return entry.name;
                for (entry.aliases) |alias| {
                    if (std.mem.eql(u8, lower, alias)) return entry.name;
                }
            }
            @memcpy(buf[0..lower.len], lower);
            return buf[0..lower.len];
        },
    }
}

/// Parses a variants string for the given layout name into a LayoutVariantOverride.
/// Returns null and emits a warning when the string is not valid for that layout.
fn parseLayoutVariant(layout_name: []const u8, variants_str: []const u8) ?types.LayoutVariantOverride {
    // Named local (rather than capturing inside a switch/if expression) so
    // `lowered.ok.buf` unambiguously lives for the rest of this function —
    // lower_layout borrows from it below and is used well past the point a
    // switch-arm-scoped capture would be.
    const lowered = types.lowerStringCI(32, layout_name);
    if (lowered == .too_long) {
        // Distinguished from "not a known variant-typed layout" (below) so a
        // config with a genuinely too-long layout name gets a message that
        // points at the actual problem, instead of looking identical to a
        // plain typo.
        debug.warn("layouts array: layout name '{s}' too long to match against a variant type, ignoring variants '{s}'", .{ layout_name, variants_str });
        return null;
    }
    const lower_layout = lowered.ok.slice();
    const typed_layouts = .{
        .{ "master-stack", types.MasterVariant, "master" },
        .{ "monocle", types.MonocleVariant, "monocle" },
        .{ "grid", types.GridVariant, "grid" },
    };
    inline for (typed_layouts) |entry| {
        if (std.mem.eql(u8, lower_layout, entry[0])) {
            const v = std.meta.stringToEnum(entry[1], variants_str) orelse {
                debug.warn("Unknown {s} variants '{s}' in layouts array, ignoring", .{ entry[0], variants_str });
                return null;
            };
            return @unionInit(types.LayoutVariantOverride, entry[2], v);
        }
    }
    return null;
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
        var name_buf: [32]u8 = undefined;
        const canonical = canonicalLayout(name_str, &name_buf);
        if (!isKnownLayout(canonical)) {
            if (name_str.len > name_buf.len) {
                debug.warn("layouts array: layout name '{s}' at index {} is longer than the {}-byte limit, skipping", .{ name_str, i, name_buf.len });
            } else {
                debug.warn("layouts array: unknown layout name '{s}' at index {}, skipping", .{ name_str, i });
            }
            continue;
        }
        // Deduplicate: skip if this exact canonical name is already in the list.
        // Prevents pointless cycle entries when the user lists the same layout
        // twice, while still allowing distinct variant entries for the same layout
        // through separate [tiling.layouts.*] sections.
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
        if (i + 1 < arr.len) {
            if (arr[i + 1].asString()) |peek| {
                if (!isKnownLayout(peek)) {
                    if (isWorkspaceList(peek)) {
                        ws_list_str = peek;
                        i += 1;
                    } else {
                        variants = parseLayoutVariant(canonical, peek);
                        i += 1;
                        if (i + 1 < arr.len) if (arr[i + 1].asString()) |peek2|
                            if (isWorkspaceList(peek2)) {
                                ws_list_str = peek2;
                                i += 1;
                            };
                    }
                }
            }
        }
        if (ws_list_str) |ws_str| {
            var ws_iter = std.mem.splitScalar(u8, ws_str, ',');
            while (ws_iter.next()) |ws_tok| {
                const trimmed = std.mem.trim(u8, ws_tok, " \t");
                const ws_1based = std.fmt.parseInt(usize, trimmed, 10) catch {
                    debug.warn("layouts array: invalid workspace number '{s}' for layout '{s}', skipping", .{ trimmed, canonical });
                    continue;
                };
                if (!checkWorkspaceBound(ws_1based, "layouts array", constants.MAX_WORKSPACES)) continue;
                const ws_idx: u8 = @intCast(ws_1based - 1);
                try cfg.tiling.workspace_layout_overrides.append(allocator, .{
                    .workspace_idx = ws_idx,
                    .layout_idx = layout_idx,
                    .variant = variants,
                });
            }
        }
    }
}

// Field names only — no duplicated default literal; getColor's default is
// the already-initialised cfg.bar value (leave-alone semantics), so types.zig
// stays the single place each default is written.
const BAR_COLOR_FIELDS = [_][]const u8{
    "bg", "fg", "selected_bg", "selected_fg", "accent_color",
};

/// Parses bar transparency from integers (0–100), decimals (0.0–1.0),
/// or percentages (`50%`). Returns a [0.0, 1.0] opacity value, working
/// purely off asInt()/asScalable() since the parser already recognises
/// bare decimal literals as well as percentages.
///
/// Bare integers are ALWAYS percentages (0–100), so `transparency = 50`
/// is 50% opacity — identical in meaning to `50%`. The one colliding case
/// is a bare `1`: `= 1` means 1% opacity while `= 1.0`/`= 100%` mean fully
/// opaque. The ambiguity is resolved as 1% (consistent with the other
/// integer-percent fields such as indicator_padding) and an explicit
/// warning is emitted so a user who meant "fully opaque" notices.
///
/// A *quoted* transparency value (e.g. `transparency = "0.5"`) is not
/// specially unwrapped; it falls to the default with an explicit warning.
fn parseTransparency(value: parser.Value) f32 {
    if (value.asInt()) |i| {
        if (i == 0) return 0.0;
        if (i >= 2 and i <= 100) return @as(f32, @floatFromInt(i)) / 100.0;
        if (i == 1) {
            // `transparency = 1` is ambiguous: it could mean 1% opacity (like
            // every other bare integer, a percentage of 100) or the
            // floating-point 1.0 (fully opaque).  Per the "bare integers are
            // percentages" rule it resolves to 1% opacity, but we warn so a
            // user who meant fully opaque can write `1.0` or `100%` instead.
            debug.warn("Transparency value 1 is ambiguous (1% opacity or 1.0 fully opaque?); " ++
                "treating as 1% opacity. Use '1.0' or '100%' for fully opaque.", .{});
            return 0.01;
        } else {
            debug.warn("Invalid transparency value {} (must be 0–100), using default", .{i});
        }
        return 1.0;
    }
    if (value.asScalable()) |s| {
        const f = utils.scaling.asRatio(s);
        if (f < 0.0 or f > 1.0) {
            debug.warn("Invalid transparency value {d} (must be 0.0–1.0 or 0–100%), using default", .{f});
            return 1.0;
        }
        return f;
    }
    if (value.asString()) |str|
        debug.warn("Transparency value '{s}' is quoted; write it unquoted (e.g. transparency = 0.5), using default", .{str});
    return 1.0;
}

/// Dupes `val` into `*view`, freeing the previous value first.
///
/// `*view` must already hold a heap allocation (getDefaultConfig dupes the
/// defaults), so this transfers ownership and Config.deinit can free every
/// BarConfig string field unconditionally.
///
/// The duplicate is taken BEFORE the old allocation is freed: in the
/// "key absent" fallback path (assignStrKey) `val` IS the current `view.*`,
/// so freeing first would read freed memory.
fn assignStr(a: std.mem.Allocator, view: *[]const u8, val: []const u8) !void {
    const copy = try a.dupe(u8, val);
    a.free(view.*);
    view.* = copy;
}

/// Reads `section.key` (falling back to `view`'s current value when absent)
/// and assigns the result into `view` via assignStr.
fn assignStrKey(a: std.mem.Allocator, section: *parser.Section, key: []const u8, view: *[]const u8) !void {
    try assignStr(a, view, getInRange([]const u8, section, key, view.*, null, null));
}

fn parseBar(allocator: std.mem.Allocator, doc: *parser.Document, cfg: *types.Config) !void {
    const section = doc.getSection("bar") orelse return;
    cfg.bar.enabled = getInRange(bool, section, "enabled", cfg.bar.enabled, null, null);
    cfg.bar.vim_mode = getInRange(bool, section, "vim_mode", cfg.bar.vim_mode, null, null);
    if (section.getString("position")) |pos_str|
        cfg.bar.bar_position = std.meta.stringToEnum(types.BarScreenPosition, pos_str) orelse .top;
    // height: null = auto-calculate from font metrics alone (see the BarConfig
    // field doc comment). A negative explicit height makes no sense either, so
    // it is rejected (with a warning) back to that same auto behavior rather
    // than being passed through to rendering code.
    cfg.bar.height = height_blk: {
        const h = section.getScalable("height") orelse break :height_blk null;
        if (h.value < 0.0) {
            debug.warn("Value for 'height' ({d}) below minimum (0), using auto", .{h.value});
            break :height_blk null;
        }
        break :height_blk h;
    };
    if (section.getArray("fonts")) |arr| {
        for (cfg.bar.fonts.items) |font| allocator.free(font);
        cfg.bar.fonts.clearRetainingCapacity();
        for (arr) |item| if (item.asString()) |name|
            try cfg.bar.fonts.append(allocator, try allocator.dupe(u8, name));
        debug.info("Loaded {} fonts for bar", .{cfg.bar.fonts.items.len});
    }
    cfg.bar.font_size = getScalableInRange(section, "font_size", cfg.bar.font_size, 0.0);
    cfg.bar.spacing = getScalableInRange(section, "segment_spacing", cfg.bar.spacing, 0.0);
    inline for (BAR_COLOR_FIELDS) |field_name|
        @field(cfg.bar, field_name) = getColor(section, field_name, @field(cfg.bar, field_name));
    try assignStrKey(allocator, section, "clock_format", &cfg.bar.clock_format);
    try assignStrKey(allocator, section, "drun_prompt", &cfg.bar.drun_prompt);
    // Reads the already-initialised value as default so the struct default in
    // types.zig can't drift; also rejects negative values like the other
    // ScalableValue fields.
    cfg.bar.indicator_size = getScalableInRange(section, "indicator_size", cfg.bar.indicator_size, 0.0);
    cfg.bar.workspace_tag_width = getScalableInRange(section, "workspace_tag_width", cfg.bar.workspace_tag_width, 0.0);
    if (section.getString("indicator_location")) |loc_str| {
        cfg.bar.indicator_location = types.IndicatorLocation.fromString(loc_str) orelse blk: {
            debug.warn("Unknown indicator_location '{s}', using default 'up-left'", .{loc_str});
            break :blk .up_left;
        };
    }

    if (section.get("indicator_padding")) |val| {
        // Bare integers are always a percentage (0–100), matching transparency;
        // fractional/decimal values are a 0.0–1.0 ratio directly. `= 1` resolves
        // to 1% padding (a bare integer, per the rule) with an explicit warning
        // because `= 1.0` would mean 100% — same collision as transparency.
        const f: f32 = if (val.asInt()) |i| blk: {
            if (i == 1)
                debug.warn("indicator_padding value 1 is ambiguous (1% or 1.0 ratio?); " ++
                    "treating as 1%. Use '1.0' or '100%' for 100%.", .{});
            break :blk @as(f32, @floatFromInt(i)) / 100.0;
        } else if (val.asScalable()) |sv|
            utils.scaling.asRatio(sv)
        else
            0.1;
        cfg.bar.indicator_padding = std.math.clamp(f, 0.0, 1.0);
    }
    // indicator_focused/unfocused: if only one is set, the other mirrors it.
    // Always duped (even the literal defaults) so deinit can free unconditionally.
    const raw_focused = section.getString("indicator_focused");
    const raw_unfocused = section.getString("indicator_unfocused");
    try assignStr(allocator, &cfg.bar.indicator_focused, raw_focused orelse raw_unfocused orelse cfg.bar.indicator_focused);
    try assignStr(allocator, &cfg.bar.indicator_unfocused, raw_unfocused orelse raw_focused orelse cfg.bar.indicator_unfocused);

    if (section.get("indicator_color")) |_| // null = inherit workspace fg
        cfg.bar.indicator_color = getColor(section, "indicator_color", cfg.bar.fg);
    if (section.get("transparency")) |value|
        cfg.bar.transparency = std.math.clamp(parseTransparency(value), 0.0, 1.0);
    try parseWorkspaceIcons(allocator, section, cfg);
    try parseBarLayout(allocator, doc, cfg);
    // Segment accent colors from [bar.colors], falling back to accent_color / bg.
    const colors = doc.getSection("bar.colors");
    const ACCENT_FIELDS = [_]struct { field: []const u8, key: []const u8, fallback: []const u8 }{
        .{ .field = "title_accent_color", .key = "title", .fallback = "accent_color" },
        .{ .field = "title_unfocused_accent", .key = "title_unfocused", .fallback = "bg" },
        .{ .field = "title_minimized_accent", .key = "title_minimized", .fallback = "accent_color" },
    };
    inline for (ACCENT_FIELDS) |f|
        @field(cfg.bar, f.field) = if (colors) |c|
            getColor(c, f.key, @field(cfg.bar, f.fallback))
        else
            @field(cfg.bar, f.fallback);
    if (colors) |c| {
        const DRUN_COLOR_FIELDS = [_]struct { key: []const u8, fallback: []const u8 }{
            .{ .key = "drun_bg", .fallback = "bg" },
            .{ .key = "drun_fg", .fallback = "fg" },
            .{ .key = "drun_prompt_color", .fallback = "accent_color" },
        };
        inline for (DRUN_COLOR_FIELDS) |f| {
            if (c.get(f.key)) |_|
                @field(cfg.bar, f.key) = getColor(c, f.key, @field(cfg.bar, f.fallback));
        }
    }
    // Carousel: enabled flag, scroll_speed (px/s, min 1), carousel_refresh_rate
    // (Hz, 0 = auto-detect via RandR). These are staged on the config struct;
    // applyCarouselSettings() pushes them onto the carousel's live globals only
    // after a fully-validated config is swapped in (see load()), so a rejected
    // reload cannot leak them into effect.
    cfg.bar.carousel_enabled = getInRange(bool, section, "carousel_enabled", true, null, null);
    cfg.bar.scroll_speed = getInRange(u16, section, "scroll_speed", 125, 1, null);
    cfg.bar.carousel_refresh_rate = getInRange(u16, section, "carousel_refresh_rate", 0, null, null);
}

fn parseWorkspaceIcons(allocator: std.mem.Allocator, section: *parser.Section, cfg: *types.Config) !void {
    for (cfg.bar.workspace_icons.items) |icon| allocator.free(icon);
    cfg.bar.workspace_icons.clearRetainingCapacity();
    if (section.getArray("icons")) |arr| {
        for (arr) |item| {
            if (item.asString()) |s| {
                try cfg.bar.workspace_icons.append(allocator, try allocator.dupe(u8, s));
            } else if (item.asInt()) |n| {
                try cfg.bar.workspace_icons.append(allocator, try std.fmt.allocPrint(allocator, "{}", .{n}));
            }
        }
    } else if (section.getString("icons")) |str| {
        for (str) |ch|
            try cfg.bar.workspace_icons.append(allocator, try std.fmt.allocPrint(allocator, "{c}", .{ch}));
    }

    while (cfg.bar.workspace_icons.items.len < cfg.workspaces.count) {
        try cfg.bar.workspace_icons.append(allocator, try std.fmt.allocPrint(allocator, "{}", .{cfg.bar.workspace_icons.items.len + 1}));
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

    // [rules]: simple class → workspace mapping (key = class, value = ws int).
    if (doc.getSection("rules")) |rules_section| {
        try parseSimpleRuleSection(allocator, cfg, rules_section);
    }

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
/// (integer value → workspace) or a workspace number (array value → classes).
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

/// Handle the [rules] section: each entry maps a class name to a workspace int.
fn parseSimpleRuleSection(
    allocator: std.mem.Allocator,
    cfg: *types.Config,
    rules_section: *parser.Section,
) !void {
    var iter = rules_section.orderedIterator();
    while (iter.next()) |entry| {
        rules_section.markConsumed(entry.key);
        try tryAddClassRule(allocator, cfg, entry.key, entry.value);
    }
}
