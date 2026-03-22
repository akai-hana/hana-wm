//! Configuration interpreter — loads, parses, and validates TOML config files.

const std       = @import("std");
const core      = @import("core");
const debug     = @import("debug");
const parser    = @import("parser");
const xkbcommon = @import("xkbcommon");
const constants = @import("constants");
const carousel  = @import("carousel");

const parseColor = parser.parseColor;

/// Returns `default` when the key is absent, out of range, or the wrong type.
/// Out-of-range values log a warning and return the default (not clamped).
fn get(
    comptime T: type,
    section:   *const parser.Section,
    key:       []const u8,
    default:   T,
    comptime min: ?T,
    comptime max: ?T,
) T {
    const value = switch (T) {
        bool         => section.getBool(key)   orelse return default,
        []const u8   => section.getString(key) orelse return default,
        u8, u16, u32, usize => blk: {
            const i = section.getInt(key) orelse return default;
            break :blk @as(T, @intCast(i));
        },
        else => @compileError("Unsupported type"),
    };
    if (comptime min) |m| if (value < m) { debug.warn("Value for '{s}' ({any}) below minimum ({any}), using default",  .{ key, value, m }); return default; };
    if (comptime max) |m| if (value > m) { debug.warn("Value for '{s}' ({any}) above maximum ({any}), using default",  .{ key, value, m }); return default; };
    return value;
}

/// Resolves a color from a section key, accepting `#RRGGBB`, `0xRRGGBB`, or an integer.
inline fn getColor(section: *const parser.Section, key: []const u8, default: u32) u32 {
    const value = section.get(key) orelse return default;
    if (value.asColor()) |c|   return c;
    if (value.asString()) |s|  return parseColor(s) catch {
        debug.warn("Invalid color for {s}: '{s}'", .{ key, s });
        return default;
    };
    if (value.asInt()) |i| if (i >= 0 and i <= 0xFFFFFF) return @intCast(i);
    return default;
}

inline fn validateWorkspace(ws_num: usize, max: usize, context: []const u8) bool {
    if (ws_num < 1 or ws_num > max) { debug.warn("Rule workspace {} for '{s}' exceeds count {}, skipping", .{ ws_num, context, max }); return false; }
    return true;
}

inline fn addRule(allocator: std.mem.Allocator, cfg: *core.Config, class_name: []const u8, ws_num: usize) !void {
    try cfg.workspaces.rules.append(allocator, .{
        .class_name = try allocator.dupe(u8, class_name),
        .workspace  = @intCast(ws_num - 1),
    });
}

fn initDefaultBarLayout(allocator: std.mem.Allocator, cfg: *core.Config) !void {
    const defaults = [_]struct { pos: core.BarPosition, seg: core.BarSegment }{
        .{ .pos = .left,   .seg = .workspaces },
        .{ .pos = .center, .seg = .title      },
        .{ .pos = .right,  .seg = .clock      },
    };
    for (defaults) |d| {
        var layout = core.BarLayout{ .position = d.pos, .segments = .empty };
        try layout.segments.append(allocator, d.seg);
        try cfg.bar.layout.append(allocator, layout);
    }
}

/// Maximum bytes accepted from a single .toml file (1 MiB).
const MAX_FILE_BYTES = 1024 * 1024;

/// Reads the file at `path` into a freshly allocated slice owned by the caller.
/// Returns `error.FileTooLarge` when the file exceeds `MAX_FILE_BYTES`.
fn readFileAlloc(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const io   = std.Options.debug_io;
    const file = std.Io.Dir.openFileAbsolute(io, path, .{}) catch |err| {
        if (err == error.FileNotFound) debug.info("Not found: {s}", .{path});
        return err;
    };
    defer file.close(io);
    const buf = try allocator.alloc(u8, MAX_FILE_BYTES + 1);
    errdefer allocator.free(buf);
    const n = try file.readPositionalAll(io, buf, 0);
    if (n > MAX_FILE_BYTES) { allocator.free(buf); return error.FileTooLarge; }
    return allocator.realloc(buf, n) catch buf[0..n];
}

/// Merges files listed in `include = [...]` from `src_doc` into `dst`; `dir_path` is the base for relative paths.
fn processIncludes(allocator: std.mem.Allocator, dst: *parser.Document, src_doc: *const parser.Document, dir_path: []const u8) !void {
    const inc_val = src_doc.get("include") orelse return;
    const includes = inc_val.asArray() orelse return;
    for (includes) |item| {
        const rel = item.asString() orelse continue;
        if (std.mem.indexOfScalar(u8, rel, '/') == null or !std.mem.endsWith(u8, rel, ".toml")) {
            debug.warn("include '{s}': must contain '/' and end in .toml — skipping", .{rel});
            continue;
        }
        const abs = try std.fs.path.join(allocator, &.{ dir_path, rel });
        defer allocator.free(abs);
        const raw = readFileAlloc(allocator, abs) catch |err| {
            debug.warn("include '{s}': could not read: {}", .{ abs, err });
            continue;
        };
        defer allocator.free(raw);
        if (raw.len == 0) { debug.info("include '{s}': empty, skipping", .{abs}); continue; }
        var inc_doc = parser.parse(allocator, raw) catch |err| {
            debug.warn("include '{s}': parse error: {}", .{ abs, err });
            continue;
        };
        defer inc_doc.deinit();
        try parser.mergeDocumentsInto(allocator, dst, &inc_doc);
        debug.info("Merged (include): {s}", .{abs});
    }
}

fn sliceLessThan(_: void, a: []u8, b: []u8) bool { return std.mem.lessThan(u8, a, b); }

/// Loads and merges all `*.toml` files directly inside `dir_path` (alphabetical order;
/// subdirectories only via explicit `include`).  Later files win on scalar conflicts;
/// arrays accumulate.
pub fn loadConfigFromDir(allocator: std.mem.Allocator, dir_path: []const u8) !core.Config {
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
        const raw = readFileAlloc(allocator, path) catch |err| {
            debug.warn("Skipping '{s}': {}", .{ path, err });
            continue;
        };
        defer allocator.free(raw);
        if (raw.len == 0) { debug.info("Skipping empty file: {s}", .{path}); continue; }
        var doc = parser.parse(allocator, raw) catch |err| {
            debug.warn("Parse error in '{s}': {}", .{ path, err });
            continue;
        };
        defer doc.deinit();
        try parser.mergeDocumentsInto(allocator, &merged, &doc);
        debug.info("Merged: {s}", .{path});
        try processIncludes(allocator, &merged, &doc, dir_path);
    }

    const cfg = try buildConfigFromDoc(allocator, &merged);
    debug.info("Loaded config from dir: {s} ({} file(s))", .{ dir_path, names.items.len });
    return cfg;
}

/// Loads config in priority order: (1) ~/.config/hana/, (2) ./config/, (3) ~/.config/hana/config.toml,
/// (4) ./config.toml, (5) embedded fallback.
pub fn loadConfigDefault(allocator: std.mem.Allocator) !core.Config {
    const home            = if (std.c.getenv("HOME")) |h| std.mem.span(h) else "./config";
    const xdg_config_home = std.c.getenv("XDG_CONFIG_HOME");
    const config_home     = if (xdg_config_home) |ch|
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
    if (loadConfig(allocator, xdg_path)) |cfg| return cfg else |_| {}
    const local = try std.fs.path.join(allocator, &.{ cwd, "config.toml" });
    defer allocator.free(local);
    if (loadConfig(allocator, local)) |cfg| return cfg else |_| {}
    debug.info("No config found, using fallback with auto-detection", .{});
    return try loadFallbackConfig(allocator);
}

/// Reads, parses, and returns the config at `path` (single-file entry point).
pub fn loadConfig(allocator: std.mem.Allocator, path: []const u8) !core.Config {
    const raw = readFileAlloc(allocator, path) catch |err| return err;
    defer allocator.free(raw);
    if (raw.len == 0) {
        debug.info("Empty config file: {s}, using fallback", .{path});
        return try loadFallbackConfig(allocator);
    }

    var doc = try parser.parse(allocator, raw);
    defer doc.deinit();
    try processIncludes(allocator, &doc, &doc, std.fs.path.dirname(path) orelse ".");
    const cfg = try buildConfigFromDoc(allocator, &doc);
    debug.info("Loaded: {s}", .{path});
    return cfg;
}

fn loadFallbackConfig(allocator: std.mem.Allocator) !core.Config {
    const fallback      = @import("fallback");
    const fallback_toml = try fallback.getFallbackToml();
    var doc = try parser.parse(allocator, fallback_toml);
    defer doc.deinit();
    var cfg = try buildConfigFromDoc(allocator, &doc);
    const terminal = fallback.detectTerminal();
    for (cfg.keybindings.items) |*kb| {
        if (kb.action == .exec and std.mem.eql(u8, kb.action.exec, "auto_terminal")) {
            allocator.free(kb.action.exec);
            kb.action.exec = try allocator.dupe(u8, terminal);
        }
    }

    if (std.mem.eql(u8, cfg.bar.font, "auto")) {
        const detected_font  = try fallback.detectFont(allocator);
        defer allocator.free(detected_font);
        const font_size_val: u16 = @intFromFloat(cfg.bar.font_size.value);
        const font_with_size = try std.fmt.allocPrint(allocator, "{s}:size={}", .{ detected_font, font_size_val });
        if (cfg.allocated_font) |old| allocator.free(old);
        cfg.allocated_font = font_with_size;
        cfg.bar.font = font_with_size;
    }

    debug.info("Loaded fallback configuration with auto-detection", .{});
    return cfg;
}

fn getDefaultConfig(allocator: std.mem.Allocator) core.Config {
    var cfg: core.Config = .{};
    const default_layout = allocator.dupe(u8, "master_left") catch "master_left";
    cfg.tiling.layouts.append(allocator, default_layout) catch |e| debug.warnOnErr(e, "default layout append");
    cfg.tiling.layout = if (cfg.tiling.layouts.items.len > 0) cfg.tiling.layouts.items[0] else default_layout;
    for (0..9) |i| {
        const icon = std.fmt.allocPrint(allocator, "{}", .{i + 1}) catch continue;
        cfg.bar.workspace_icons.append(allocator, icon) catch |e| debug.warnOnErr(e, "workspace icon append");
    }
    initDefaultBarLayout(allocator, &cfg) catch |e| debug.warnOnErr(e, "default bar layout init");
    return cfg;
}

/// Builds a Config from a parsed Document: initialises defaults then applies all sections.
fn buildConfigFromDoc(allocator: std.mem.Allocator, doc: *const parser.Document) !core.Config {
    var cfg = getDefaultConfig(allocator);
    parseWorkspaces(doc, &cfg);
    try parseKeybindings(allocator, doc, &cfg);
    try parseTiling(allocator, doc, &cfg);
    try parseBar(allocator, doc, &cfg);
    try parseRules(allocator, doc, &cfg);
    return cfg;
}

const MOD_MAP = std.StaticStringMap(u16).initComptime(.{
    .{ "Super",   constants.MOD_SUPER   },
    .{ "Mod4",    constants.MOD_SUPER   },
    .{ "Alt",     constants.MOD_ALT     },
    .{ "Mod1",    constants.MOD_ALT     },
    .{ "Control", constants.MOD_CONTROL },
    .{ "Ctrl",    constants.MOD_CONTROL },
    .{ "Shift",   constants.MOD_SHIFT   },
});

const MOUSE_BUTTON_MAP = std.StaticStringMap(u8).initComptime(.{
    .{ "button1", 1 }, .{ "left_click",   1 }, .{ "leftclick",   1 }, .{ "left",   1 },
    .{ "button2", 2 }, .{ "middle_click", 2 }, .{ "middleclick", 2 }, .{ "middle", 2 },
    .{ "button3", 3 }, .{ "right_click",  3 }, .{ "right",       3 },
    .{ "button4", 4 }, .{ "scroll_up",    4 }, .{ "scrollup",    4 },
    .{ "button5", 5 }, .{ "scroll_down",  5 }, .{ "scrolldown",  5 },
});

inline fn mouseButtonFromName(name: []const u8) ?u8 {
    var buf: [16]u8 = undefined;
    if (name.len > buf.len) return null;
    return MOUSE_BUTTON_MAP.get(std.ascii.lowerString(&buf, name));
}

const ACTION_MAP = std.StaticStringMap(core.Action).initComptime(.{
    .{ "close",                  .close_window           },
    .{ "close_window",           .close_window           },
    .{ "kill",                   .close_window           },
    .{ "reload",                 .reload_config          },
    .{ "reload_config",          .reload_config          },
    .{ "toggle_layout",          .toggle_layout          },
    .{ "toggle_layout_reverse",  .toggle_layout_reverse  },
    .{ "toggle_bar_visibility",  .toggle_bar_visibility  },
    .{ "toggle_bar_position",    .toggle_bar_position    },
    .{ "increase_master",        .increase_master        },
    .{ "decrease_master",        .decrease_master        },
    .{ "increase_master_count",  .increase_master_count  },
    .{ "decrease_master_count",  .decrease_master_count  },
    .{ "toggle_floating",         .toggle_floating         },
    .{ "toggle_fullscreen",      .toggle_fullscreen      },
    .{ "fullscreen",             .toggle_fullscreen      },
    .{ "swap_master",            .swap_master            },
    .{ "swap_master_focus_swap", .swap_master_focus_swap },
    .{ "dump_state",             .dump_state             },
    .{ "minimize_window",        .minimize_window        },
    .{ "minimize",               .minimize_window        },
    .{ "unminimize_lifo",        .unminimize_lifo        },
    .{ "unminimize_fifo",        .unminimize_fifo        },
    .{ "unminimize_all",         .unminimize_all         },
    .{ "cycle_layout_variants", .cycle_layout_variants },
    .{ "cycle_variants",        .cycle_layout_variants },
    .{ "toggle_prompt",          .toggle_prompt          },
    .{ "drun",                   .toggle_prompt          },
    .{ "toggle_float",           .toggle_floating        },
    .{ "float",                  .toggle_floating        },
});

const GlobEntry = struct {
    key:    []const u8,
    ws_idx: u8,   // 1-based position in the expanded list; 0 when there is no glob
    owned:  bool, // true when key was heap-allocated and must be freed by the caller
};

/// Expands `{…}` glob patterns in a keybind key (e.g. `Mod+{1-4,Q}` -> 5 entries,
/// comma-separated tokens and single-char ranges supported).  Workspace actions get a
/// 1-based index appended; other actions are replicated unchanged.
/// Returns a single unowned entry when no glob is present.
fn expandGlobKeys(allocator: std.mem.Allocator, key_pattern: []const u8) ![]GlobEntry {
    const literal = struct {
        fn one(a: std.mem.Allocator, key: []const u8) ![]GlobEntry {
            const e = try a.alloc(GlobEntry, 1);
            e[0] = .{ .key = key, .ws_idx = 0, .owned = false };
            return e;
        }
    };
    const lbrace = std.mem.indexOfScalar(u8, key_pattern, '{') orelse return literal.one(allocator, key_pattern);
    const rbrace = std.mem.indexOfScalarPos(u8, key_pattern, lbrace + 1, '}') orelse {
        debug.warn("Keybind glob missing closing '}}\' in '{s}', treating as literal", .{key_pattern});
        return literal.one(allocator, key_pattern);
    };
    const prefix = key_pattern[0..lbrace];
    const suffix = key_pattern[rbrace + 1..];
    const inner  = key_pattern[lbrace + 1..rbrace];
    var keys: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (keys.items) |k| allocator.free(k);
        keys.deinit(allocator);
    }

    var it = std.mem.splitScalar(u8, inner, ',');
    while (it.next()) |token| {
        const t = std.mem.trim(u8, token, " \t");
        if (t.len == 0) continue;
        if (t.len == 3 and t[1] == '-') {
            var c = t[0];
            const end = t[2];
            while (c <= end) : (c += 1)
                                try keys.append(allocator, try std.fmt.allocPrint(allocator, "{s}{c}{s}", .{ prefix, c, suffix }));
        } else {
            try keys.append(allocator, try std.fmt.allocPrint(allocator, "{s}{s}{s}", .{ prefix, t, suffix }));
        }
    }

    if (keys.items.len == 0) {
        keys.deinit(allocator);
        return literal.one(allocator, key_pattern);
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

fn resolveAndParseAction(allocator: std.mem.Allocator, cmd: []const u8, ws_idx: u8, kill_placeholder: ?[]const u8) !core.Action {
    const ws_str: ?[]u8 = if (ws_idx > 0 and WORKSPACE_ACTION_BASES.has(cmd))
        try std.fmt.allocPrint(allocator, "{s}_{d}", .{ cmd, ws_idx }) else null;
    defer if (ws_str) |s| allocator.free(s);
    const after_ws = ws_str orelse cmd;
    if (kill_placeholder) |kp| if (std.mem.indexOf(u8, after_ws, "{kill}") != null) {
        const final = try std.mem.replaceOwned(u8, allocator, after_ws, "{kill}", kp);
        defer allocator.free(final);
        return parseAction(allocator, final);
    };
    return parseAction(allocator, after_ws);
}

fn parseKeybindings(allocator: std.mem.Allocator, doc: *const parser.Document, cfg: *core.Config) !void {
    const section          = doc.getSection("binds") orelse doc.getSection("Keybindings") orelse return;
    const mod_placeholder  = section.getString("Mod");
    const kill_placeholder = section.getString("kill");
    var iter = section.pairs.iterator();
    while (iter.next()) |entry| {
        if (std.mem.eql(u8, entry.key_ptr.*, "Mod"))  continue;
        if (std.mem.eql(u8, entry.key_ptr.*, "kill")) continue;
        const glob_entries = try expandGlobKeys(allocator, entry.key_ptr.*);
        defer {
            for (glob_entries) |ge| if (ge.owned) allocator.free(ge.key);
            allocator.free(glob_entries);
        }
        for (glob_entries) |ge| {
            const keybind_str: []const u8 = blk: {
                if (mod_placeholder) |mod| if (std.mem.startsWith(u8, ge.key, "Mod+"))
                    break :blk try std.fmt.allocPrint(allocator, "{s}+{s}", .{ mod, ge.key["Mod+".len..] });
                break :blk ge.key;
            };
            defer if (keybind_str.ptr != ge.key.ptr) allocator.free(keybind_str);
                        const action: core.Action = act: {
                            if (entry.value_ptr.*.asArray()) |arr| {
                                var acts: std.ArrayList(core.Action) = .empty;
                                errdefer {
                                    for (acts.items) |*a| a.deinit(allocator);
                                    acts.deinit(allocator);
                                }
                                for (arr) |elem| {
                                    const cmd = elem.asString() orelse continue;
                                    try acts.append(allocator, try resolveAndParseAction(allocator, cmd, ge.ws_idx, kill_placeholder));
                                }
                                if (acts.items.len == 0) { acts.deinit(allocator); continue; }
                                if (acts.items.len == 1) {
                                    const only = acts.items[0];
                                    acts.deinit(allocator);
                                    break :act only;
                                }
                                break :act .{ .sequence = try acts.toOwnedSlice(allocator) };
                            } else if (entry.value_ptr.*.asString()) |command| {
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
                                .button    = mb.button,
                                .action    = action,
                            }),
                            .keyboard => |kb| try cfg.keybindings.append(allocator, .{
                                .modifiers = kb.modifiers,
                                .keysym    = kb.keysym,
                                .action    = action,
                            }),
                        }
        }
    }
}

const BindResult = union(enum) {
    keyboard: struct { modifiers: u16, keysym: u32 },
    mouse:    struct { modifiers: u16, button: u8  },
};

/// Parses a `Mods+Key` or `Mods+ButtonName` string into a typed BindResult.
/// Returns an error when any token is unrecognised.
fn parseBindString(str: []const u8) !BindResult {
    var modifiers: u16 = 0;
    var keysym:    ?u32 = null;
    var button:    ?u8  = null;
    var parts = std.mem.splitScalar(u8, str, '+');
    while (parts.next()) |part| {
        const trimmed = std.mem.trim(u8, part, " \t");
        if (MOD_MAP.get(trimmed)) |mod| {
            modifiers |= mod;
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

fn parseAction(allocator: std.mem.Allocator, cmd: []const u8) !core.Action {
    if (ACTION_MAP.get(cmd))                         |a| return a;
    if (tryParseWorkspace(cmd, "workspace_"))         |ws| return .{ .switch_workspace  = ws };
    if (tryParseWorkspace(cmd, "move_to_workspace_")) |ws| return .{ .move_to_workspace = ws };
    if (tryParseWorkspace(cmd, "toggle_tag_"))        |ws| return .{ .toggle_tag        = ws };
    return .{ .exec = try allocator.dupe(u8, cmd) };
}

/// Scales font size and other DPI-dependent fields. Call once the screen is available.
pub inline fn finalizeConfig(cfg: *core.Config, screen: *core.xcb.xcb_screen_t) void {
    const scale_module = @import("scale");
    cfg.bar.scaled_font_size = scale_module.scaleFontSize(cfg.bar.font_size, screen);
}

/// Resolves keysyms to keycodes and warns about duplicate bindings.
pub fn resolveKeybindings(keybindings: anytype, xkb_state: *xkbcommon.XkbState, allocator: std.mem.Allocator) void {
    for (keybindings) |*kb| kb.keycode = xkb_state.keysymToKeycode(kb.keysym);
    var seen = std.AutoHashMap(u64, usize).init(allocator);
    defer seen.deinit();
    for (keybindings, 0..) |*kb, i| {
        const keycode = kb.keycode orelse continue;
        const key: u64 = (@as(u64, kb.modifiers) << 32) | keycode;
        if (seen.get(key)) |first| {
            debug.warn("Keybinding conflict: #{} and #{} share mods=0x{x:0>4} key={} — second wins",
                .{ first + 1, i + 1, kb.modifiers, keycode });
        } else {
            seen.put(key, i) catch |e| debug.warnOnErr(e, "keybind dedup");
        }
    }
}

/// Canonical startup/reload entry point: load, resolve keybindings, finalize.
pub fn load(allocator: std.mem.Allocator, screen: *core.xcb.xcb_screen_t, xkb_state: *xkbcommon.XkbState) !core.Config {
    var cfg = try loadConfigDefault(allocator);
    resolveKeybindings(cfg.keybindings.items, xkb_state, allocator);
    finalizeConfig(&cfg, screen);
    return cfg;
}

fn parseWorkspaces(doc: *const parser.Document, cfg: *core.Config) void {
    const section = doc.getSection("bar.modules.workspaces") orelse doc.getSection("workspaces") orelse return;
    cfg.workspaces.count = get(u8, section, "count", 9, 1, null);
}

fn parseTiling(allocator: std.mem.Allocator, doc: *const parser.Document, cfg: *core.Config) !void {
    const section = doc.getSection("tiling") orelse return;
    cfg.tiling.enabled = get(bool, section, "enabled", true, null, null);
    if (section.get("layouts")) |layouts_value| {
        if (layouts_value.asArray()) |arr| {
            for (cfg.tiling.layouts.items) |layout| allocator.free(layout);
            cfg.tiling.layouts.clearRetainingCapacity();
            cfg.tiling.workspace_layout_overrides.clearRetainingCapacity();
            try parseLayoutsArray(allocator, arr, cfg);
            if (cfg.tiling.layouts.items.len > 0) cfg.tiling.layout = cfg.tiling.layouts.items[0];
        }
    } else {
        const layout_str = get([]const u8, section, "layout", "master_left", null, null);
        cfg.allocated_layout = try allocator.dupe(u8, layout_str);
        cfg.tiling.layout    = cfg.allocated_layout.?;
        try cfg.tiling.layouts.append(allocator, try allocator.dupe(u8, layout_str));
    }

    const aesthetic_src = doc.getSection("tiling.aesthetics") orelse section;

    cfg.tiling.gap_width = aesthetic_src.getScalable("gap_width")    orelse parser.ScalableValue.absolute(10.0);
    cfg.tiling.border_width = aesthetic_src.getScalable("border_width") orelse parser.ScalableValue.absolute(2.0);
    cfg.tiling.border_focused = getColor(aesthetic_src, "border_focused",   0x5294E2);
    cfg.tiling.border_unfocused = getColor(aesthetic_src, "border_unfocused", 0x383C4A);
    const master_src = doc.getSection("tiling.layouts.master-stack") orelse section;
    const dedicated = master_src != section; // true when [tiling.layouts.master-stack] exists
    cfg.tiling.master_count = get(u8, master_src, if (dedicated) "count" else "master_count", 1, 1, null);
    if (master_src.getString(if (dedicated) "side"  else "master_side"))  |s| cfg.tiling.master_side = core.MasterSide.fromStringWithAlias(s) orelse .left;
    cfg.tiling.master_width = master_src.getScalable(if (dedicated) "width" else "master_width") orelse parser.ScalableValue.percentage(50.0);
    parseTilingVariants(doc, cfg);
    cfg.tiling.global_layout = get(bool, section, "global_layout", false, null, null);
}

/// Reads `variants` from `section` into `field`; warns on unknown values.
inline fn tryParseVariant(
    comptime T:   type,
    section:      *const parser.Section,
    layout_name:  []const u8,
    field:        *T,
) void {
    const v = section.getString("variants") orelse return;
    field.* = std.meta.stringToEnum(T, v) orelse {
        debug.warn("Unknown {s} variants '{s}', using default", .{ layout_name, v });
        return;
    };
}

inline fn tryParseIndicator(section: *const parser.Section, field: *?[3]u8) void {
    if (section.getString("indicator")) |raw| field.* = parseIndicator(raw);
}

fn parseTilingVariants(doc: *const parser.Document, cfg: *core.Config) void {
    inline for (.{
        .{ "tiling.layouts.master-stack", core.MasterVariant,  "master-stack", "master_variant",  "master_indicator"  },
        .{ "tiling.layouts.monocle",      core.MonocleVariant, "monocle",      "monocle_variant", "monocle_indicator" },
        .{ "tiling.layouts.grid",         core.GridVariant,    "grid",         "grid_variant",    "grid_indicator"    },
    }) |e| if (doc.getSection(e[0])) |ms| {
        tryParseVariant(e[1], ms, e[2], &@field(cfg.tiling, e[3]));
        tryParseIndicator(ms, &@field(cfg.tiling, e[4]));
    };
}

inline fn parseIndicator(raw: []const u8) [3]u8 {
    var ind: [3]u8 = "   ".*;
    const n = @min(raw.len, 3);
    @memcpy(ind[0..n], raw[0..n]);
    return ind;
}

const KNOWN_LAYOUT_SET = std.StaticStringMap(void).initComptime(.{
    .{ "master-stack", {} }, .{ "monocle", {} }, .{ "grid", {} }, .{ "fibonacci", {} },
});

/// Returns true if `name` (case-insensitive) is a recognised layout name.
inline fn isKnownLayout(name: []const u8) bool {
    var buf: [32]u8 = undefined;
    if (name.len > buf.len) return false;
    return KNOWN_LAYOUT_SET.has(std.ascii.lowerString(&buf, name));
}

/// Returns true if `s` looks like a workspace-number list: only digits, commas, spaces,
/// and contains at least one digit.
inline fn isWorkspaceList(s: []const u8) bool {
    if (s.len == 0) return false;
    var has_digit = false;
    for (s) |c| {
        if (std.ascii.isDigit(c)) { has_digit = true; continue; }
        if (c != ',' and c != ' ') return false;
    }
    return has_digit;
}

/// Canonicalises a layout name to the plain lowercase form used in the layouts list.
/// "master_stack" and "master" both become "master-stack".
inline fn canonicalLayout(name: []const u8, buf: []u8) []const u8 {
    const lower = std.ascii.lowerString(buf[0..name.len], name);
    if (std.mem.eql(u8, lower, "master_stack") or std.mem.eql(u8, lower, "master"))
        return "master-stack";
    return lower;
}

/// Parses a variants string for the given layout name into a LayoutVariantOverride.
/// Returns null and emits a warning when the string is not valid for that layout.
fn parseLayoutVariant(layout_name: []const u8, variants_str: []const u8) ?core.LayoutVariantOverride {
    var buf: [32]u8 = undefined;
    if (layout_name.len > buf.len) return null;
    const lower_layout = std.ascii.lowerString(buf[0..layout_name.len], layout_name);
    const typed_layouts = .{
        .{ "master-stack", core.MasterVariant,  "master"  },
        .{ "monocle",      core.MonocleVariant, "monocle" },
        .{ "grid",         core.GridVariant,    "grid"    },
    };
    inline for (typed_layouts) |entry| {
        if (std.mem.eql(u8, lower_layout, entry[0])) {
            const v = std.meta.stringToEnum(entry[1], variants_str) orelse {
                debug.warn("Unknown {s} variants '{s}' in layouts array, ignoring", .{ entry[0], variants_str });
                return null;
            };
            return @unionInit(core.LayoutVariantOverride, entry[2], v);
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
    arr:       []const parser.Value,
    cfg:       *core.Config,
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
            debug.warn("layouts array: unknown layout name '{s}' at index {}, skipping", .{ name_str, i });
            continue;
        }
        const layout_idx: u8 = @intCast(cfg.tiling.layouts.items.len);
        try cfg.tiling.layouts.append(allocator, try allocator.dupe(u8, canonical));
        var variants: ?core.LayoutVariantOverride = null;
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
                            if (isWorkspaceList(peek2)) { ws_list_str = peek2; i += 1; };
                    }
                }
            }
        }
        if (ws_list_str) |ws_str| {
            var ws_iter = std.mem.splitScalar(u8, ws_str, ',');
            while (ws_iter.next()) |ws_tok| {
                const trimmed = std.mem.trim(u8, ws_tok, " \t");
                const ws_1based = std.fmt.parseInt(usize, trimmed, 10) catch {
                    debug.warn("layouts array: invalid workspace number '{s}' for layout '{s}', skipping",
                        .{ trimmed, canonical });
                    continue;
                };
                if (ws_1based < 1 or ws_1based > 255) {
                    debug.warn("layouts array: workspace {} out of range for layout '{s}', skipping",
                        .{ ws_1based, canonical });
                    continue;
                }
                const ws_idx: u8 = @intCast(ws_1based - 1);
                try cfg.tiling.workspace_layout_overrides.append(allocator, .{
                    .workspace_idx = ws_idx,
                    .layout_idx    = layout_idx,
                    .variant       = variants,
                });
            }
        }
    }
}

const BAR_COLOR_FIELDS = [_]struct { name: []const u8, default: u32 }{
    .{ .name = "bg",           .default = 0x222222 },
    .{ .name = "fg",           .default = 0xBBBBBB },
    .{ .name = "selected_bg",  .default = 0x005577 },
    .{ .name = "selected_fg",  .default = 0xEEEEEE },
    .{ .name = "occupied_fg",  .default = 0xEEEEEE },
    .{ .name = "urgent_bg",    .default = 0xFF0000 },
    .{ .name = "urgent_fg",    .default = 0xFFFFFF },
    .{ .name = "accent_color", .default = 0x61AFEF },
};

/// Parses bar transparency from integers (0–100), decimals (0.0–1.0),
/// percentages (`50%`), or quoted strings. Returns a [0.0, 1.0] opacity value.
fn parseTransparency(value: parser.Value) f32 {
    if (value.asInt()) |i| {
        if (i == 0) return 0.0;
        if (i >= 2 and i <= 100) return @as(f32, @floatFromInt(i)) / 100.0;
        if (i == 1) debug.info("Transparency set to 1 (fully opaque)", .{})
        else        debug.warn("Invalid transparency value {} (must be 0–100), using default", .{i});
        return 1.0;
    }
    if (value.asScalable()) |s| return if (s.is_percentage) s.value / 100.0 else s.value;
    if (value.asString()) |str| {
        const trimmed = std.mem.trim(u8, str, " \t");
        const f = std.fmt.parseFloat(f32, trimmed) catch {
            debug.warn("Invalid transparency value '{s}', using default", .{trimmed});
            return 1.0;
        };
        if (f >= 0.0 and f < 1.0)   return f;
        if (f > 1.0 and f <= 100.0) return f / 100.0;
        if (f == 1.0) debug.info("Transparency set to 1.0 (fully opaque)", .{})
        else          debug.warn("Invalid transparency value {d} (must be 0.0–1.0 or 0–100), using default", .{f});
        return 1.0;
    }
    return 1.0;
}

fn parseBar(allocator: std.mem.Allocator, doc: *const parser.Document, cfg: *core.Config) !void {
    // Dupes `val` into `slot` and points `view` at the result.
    const set = struct {
        fn str(a: std.mem.Allocator, slot: *?[]const u8, view: *[]const u8, val: []const u8) !void {
            slot.* = try a.dupe(u8, val);
            view.* = slot.*.?;
        }
    };
    const section = doc.getSection("bar") orelse return;
    cfg.bar.enabled = get(bool, section, "enabled", true, null, null);
    if (section.getString("position")) |pos_str|
        cfg.bar.vertical_position = std.meta.stringToEnum(core.BarVerticalPosition, pos_str) orelse .top;
    cfg.bar.height = section.getScalable("height"); // null = auto from font metrics
    try set.str(allocator, &cfg.allocated_font, &cfg.bar.font,
        get([]const u8, section, "font", "monospace:size=10", null, null));
    if (section.get("fonts")) |v| if (v.asArray()) |arr| {
        for (cfg.bar.fonts.items) |font| allocator.free(font);
        cfg.bar.fonts.clearRetainingCapacity();
        for (arr) |item| if (item.asString()) |name|
            try cfg.bar.fonts.append(allocator, try allocator.dupe(u8, name));
        debug.info("Loaded {} fonts for bar", .{cfg.bar.fonts.items.len});
    };
    cfg.bar.font_size = section.getScalable("font_size") orelse parser.ScalableValue.percentage(10.0);
    cfg.bar.spacing   = section.getScalable("segment_spacing") orelse parser.ScalableValue.absolute(12.0);
    inline for (BAR_COLOR_FIELDS) |field|
        @field(cfg.bar, field.name) = getColor(section, field.name, field.default);
    try set.str(allocator, &cfg.allocated_clock_format, &cfg.bar.clock_format,
        get([]const u8, section, "clock_format", "%Y-%m-%d %H:%M:%S", null, null));
    try set.str(allocator, &cfg.allocated_drun_prompt, &cfg.bar.drun_prompt,
        get([]const u8, section, "drun_prompt", "run: ", null, null));
    cfg.bar.indicator_size      = section.getScalable("indicator_size")      orelse parser.ScalableValue.percentage(20.0);
    cfg.bar.workspace_tag_width = section.getScalable("workspace_tag_width") orelse parser.ScalableValue.percentage(100.0);
    if (section.getString("indicator_location")) |loc_str| {
        cfg.bar.indicator_location = core.IndicatorLocation.fromString(loc_str) orelse blk: {
            debug.warn("Unknown indicator_location '{s}', using default 'up-left'", .{loc_str});
            break :blk .up_left;
        };
    }

    if (section.get("indicator_padding")) |val| {
        const f: f32 = if (val.asScalable()) |sv|
            if (sv.is_percentage) sv.value / 100.0 else sv.value
            else if (val.asInt()) |i|
                @as(f32, @floatFromInt(i)) / 100.0
            else
                0.1;
        cfg.bar.indicator_padding = std.math.clamp(f, 0.0, 1.0);
    }
    // indicator_focused/unfocused: if only one is set, the other mirrors it.
    const raw_focused   = section.getString("indicator_focused");
    const raw_unfocused = section.getString("indicator_unfocused");
    if (raw_focused orelse raw_unfocused) |_| {
        cfg.allocated_indicator_focused   = try allocator.dupe(u8, raw_focused   orelse raw_unfocused.?);
        cfg.allocated_indicator_unfocused = try allocator.dupe(u8, raw_unfocused orelse raw_focused.?);
        cfg.bar.indicator_focused   = cfg.allocated_indicator_focused.?;
        cfg.bar.indicator_unfocused = cfg.allocated_indicator_unfocused.?;
    }

    if (section.get("indicator_color")) |_|   // null = inherit workspace fg
        cfg.bar.indicator_color = getColor(section, "indicator_color", cfg.bar.fg);
    if (section.get("transparency")) |value|
        cfg.bar.transparency = std.math.clamp(parseTransparency(value), 0.0, 1.0);
    try parseWorkspaceIcons(allocator, section, cfg);
    try parseBarLayout(allocator, doc, cfg);
    // Segment accent colors from [bar.colors], falling back to accent_color / bg.
    const colors = doc.getSection("bar.colors");
    const ACCENT_FIELDS = [_]struct { field: []const u8, key: []const u8, fallback: []const u8 }{
        .{ .field = "workspaces_accent",      .key = "workspaces",      .fallback = "accent_color" },
        .{ .field = "title_accent_color",     .key = "title",           .fallback = "accent_color" },
        .{ .field = "title_unfocused_accent", .key = "title_unfocused", .fallback = "bg"           },
        .{ .field = "title_minimized_accent", .key = "title_minimized", .fallback = "accent_color" },
        .{ .field = "clock_accent",           .key = "clock",           .fallback = "accent_color" },
    };
    inline for (ACCENT_FIELDS) |f|
        @field(cfg.bar, f.field) = if (colors) |c|
        getColor(c, f.key, @field(cfg.bar, f.fallback))
    else
        @field(cfg.bar, f.fallback);
    if (colors) |c| {
        const DRUN_COLOR_FIELDS = [_]struct { key: []const u8, fallback: []const u8 }{
            .{ .key = "drun_bg",           .fallback = "bg"           },
            .{ .key = "drun_fg",           .fallback = "fg"           },
            .{ .key = "drun_prompt_color", .fallback = "accent_color" },
        };
        inline for (DRUN_COLOR_FIELDS) |f| {
            if (c.get(f.key)) |_|
                @field(cfg.bar, f.key) = getColor(c, f.key, @field(cfg.bar, f.fallback));
        }
    }
    // Carousel: enabled flag, scroll_speed (px/s, min 1), carousel_refresh_rate (Hz, 0 = auto-detect via RandR).
    carousel.setCarouselEnabled(get(bool, section, "carousel_enabled", true, null, null));
    carousel.setScrollSpeed(@as(f64, @floatFromInt(
                get(u16, section, "scroll_speed", 125, 1, null)
    )));
    carousel.setRefreshRateOverride(@as(f64, @floatFromInt(
                get(u16, section, "carousel_refresh_rate", 0, null, null)
    )));
}

fn parseWorkspaceIcons(allocator: std.mem.Allocator, section: *const parser.Section, cfg: *core.Config) !void {
    for (cfg.bar.workspace_icons.items) |icon| allocator.free(icon);
    cfg.bar.workspace_icons.clearRetainingCapacity();
    if (section.get("icons")) |value| {
        if (value.asArray()) |arr| {
            for (arr) |item| {
                if (item.asString()) |s| {
                    try cfg.bar.workspace_icons.append(allocator, try allocator.dupe(u8, s));
                } else if (item.asInt()) |n| {
                    try cfg.bar.workspace_icons.append(allocator, try std.fmt.allocPrint(allocator, "{}", .{n}));
                }
            }
        } else if (value.asString()) |str| {
            for (str) |ch|
                try cfg.bar.workspace_icons.append(allocator, try std.fmt.allocPrint(allocator, "{c}", .{ch}));
        }
    }

    while (cfg.bar.workspace_icons.items.len < cfg.workspaces.count) {
        try cfg.bar.workspace_icons.append(allocator,
            try std.fmt.allocPrint(allocator, "{}", .{cfg.bar.workspace_icons.items.len + 1}));
    }
}

fn parseBarLayout(allocator: std.mem.Allocator, doc: *const parser.Document, cfg: *core.Config) !void {
    for (cfg.bar.layout.items) |*item| item.deinit(allocator);
    cfg.bar.layout.clearRetainingCapacity();
    const positions = [_]struct { name: []const u8, pos: core.BarPosition }{
        .{ .name = "bar.layout.left",   .pos = .left   },
        .{ .name = "bar.layout.center", .pos = .center },
        .{ .name = "bar.layout.right",  .pos = .right  },
    };
    for (positions) |p| {
        const layout_section = doc.getSection(p.name) orelse continue;
        var bar_layout = core.BarLayout{ .position = p.pos, .segments = .empty };
        if (layout_section.get("segments")) |sv| if (sv.asArray()) |seg_arr|
            for (seg_arr) |item| if (item.asString()) |s|
                if (std.meta.stringToEnum(core.BarSegment, s)) |segment|
                    try bar_layout.segments.append(allocator, segment);
        if (bar_layout.segments.items.len > 0) {
            try cfg.bar.layout.append(allocator, bar_layout);
        } else {
            bar_layout.deinit(allocator);
        }
    }

    if (cfg.bar.layout.items.len == 0) try initDefaultBarLayout(allocator, cfg);
}

fn parseRules(allocator: std.mem.Allocator, doc: *const parser.Document, cfg: *core.Config) !void {
    if (doc.getSection("workspace.rules")) |rules_section| {
        var iter = rules_section.pairs.iterator();
        while (iter.next()) |entry| {
            const ws_num = std.fmt.parseInt(usize, entry.key_ptr.*, 10) catch {
                const ws = entry.value_ptr.*.asInt() orelse continue;
                if (!validateWorkspace(@intCast(ws), cfg.workspaces.count, entry.key_ptr.*)) continue;
                try addRule(allocator, cfg, entry.key_ptr.*, @intCast(ws));
                continue;
            };
            if (!validateWorkspace(ws_num, cfg.workspaces.count, entry.key_ptr.*)) continue;
            if (entry.value_ptr.*.asArray()) |arr| {
                for (arr) |item| {
                    if (item.asString()) |class_name| try addRule(allocator, cfg, class_name, ws_num);
                }
            }
        }
    }

    if (doc.getSection("rules")) |rules_section| {
        var iter = rules_section.pairs.iterator();
        while (iter.next()) |entry| {
            const ws_num = entry.value_ptr.*.asInt() orelse continue;
            if (!validateWorkspace(@intCast(ws_num), cfg.workspaces.count, entry.key_ptr.*)) continue;
            try addRule(allocator, cfg, entry.key_ptr.*, @intCast(ws_num));
        }
    }

    var section_iter = doc.sections.iterator();
    while (section_iter.next()) |entry| {
        const name   = entry.key_ptr.*;
        const ws_str = if (std.mem.startsWith(u8, name, "workspace.rules."))
            name["workspace.rules.".len..]
        else if (std.mem.startsWith(u8, name, "rules."))
            name["rules.".len..]
        else
            continue;
        const ws_num = std.fmt.parseInt(usize, ws_str, 10) catch continue;
        if (!validateWorkspace(ws_num, cfg.workspaces.count, name)) continue;
        var iter = entry.value_ptr.pairs.iterator();
        while (iter.next()) |class_entry|
            try addRule(allocator, cfg, class_entry.key_ptr.*, ws_num);
    }
}
