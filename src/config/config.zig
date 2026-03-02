//! Configuration interpreter — loads, parses, and validates TOML config files.

const std       = @import("std");
const defs      = @import("defs");
const debug     = @import("debug");
const parser    = @import("parser");
const xkbcommon = @import("xkbcommon");

const parseColor = parser.parseColor;

// Typed value getters

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

    if (comptime min) |m| {
        if (value < m) {
            debug.warn("Value for '{s}' ({any}) below minimum ({any}), using default", .{ key, value, m });
            return default;
        }
    }
    if (comptime max) |m| {
        if (value > m) {
            debug.warn("Value for '{s}' ({any}) above maximum ({any}), using default", .{ key, value, m });
            return default;
        }
    }
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

// Rule helpers

inline fn validateWorkspace(ws_num: usize, max: usize, context: []const u8) bool {
    if (ws_num < 1 or ws_num > max) {
        debug.warn("Rule workspace {} for '{s}' exceeds count {}, skipping", .{ ws_num, context, max });
        return false;
    }
    return true;
}

inline fn addRule(allocator: std.mem.Allocator, cfg: *defs.Config, class_name: []const u8, ws_num: usize) !void {
    try cfg.workspaces.rules.append(allocator, .{
        .class_name = try allocator.dupe(u8, class_name),
        .workspace  = @intCast(ws_num - 1),
    });
}

// Default bar layout

fn initDefaultBarLayout(allocator: std.mem.Allocator, cfg: *defs.Config) !void {
    const defaults = [_]struct { pos: defs.BarPosition, seg: defs.BarSegment }{
        .{ .pos = .left,   .seg = .workspaces },
        .{ .pos = .center, .seg = .title      },
        .{ .pos = .right,  .seg = .clock      },
    };
    for (defaults) |d| {
        var layout = defs.BarLayout{ .position = d.pos, .segments = std.ArrayList(defs.BarSegment){} };
        try layout.segments.append(allocator, d.seg);
        try cfg.bar.layout.append(allocator, layout);
    }
}

// Config loading

/// Loads config from XDG path, CWD, or the embedded fallback — whichever succeeds first.
pub fn loadConfigDefault(allocator: std.mem.Allocator) !defs.Config {
    const home            = if (std.c.getenv("HOME")) |h| std.mem.span(h) else ".";
    const xdg_config_home = std.c.getenv("XDG_CONFIG_HOME");
    const config_home     = if (xdg_config_home) |ch|
        std.mem.span(ch)
    else
        try std.fmt.allocPrint(allocator, "{s}/.config", .{home});
    defer if (xdg_config_home == null) allocator.free(config_home);

    const xdg_path = try std.Io.Dir.path.join(allocator, &.{ config_home, "hana", "config.toml" });
    defer allocator.free(xdg_path);

    if (loadConfig(allocator, xdg_path)) |cfg| return cfg else |_| {}

    const cwd   = try std.process.getCwdAlloc(allocator);
    defer allocator.free(cwd);
    const local = try std.Io.Dir.path.join(allocator, &.{ cwd, "config.toml" });
    defer allocator.free(local);

    if (loadConfig(allocator, local)) |cfg| return cfg else |_| {}

    debug.info("No config.toml found, using fallback with auto-detection", .{});
    return try loadFallbackConfig(allocator);
}

/// Reads, parses, and returns the config at `path`.
pub fn loadConfig(allocator: std.mem.Allocator, path: []const u8) !defs.Config {
    // Config loading is synchronous and runs before the event loop, so
    // std.options.debug_io (the global blocking Io instance) is appropriate here.
    const io = std.Options.debug_io;
    const file = std.Io.Dir.openFileAbsolute(io, path, .{}) catch |err| {
        if (err == error.FileNotFound) debug.info("Not found: {s}", .{path});
        return err;
    };
    defer file.close(io);

    // Allocate max+1 bytes so readPositionalAll can detect oversized files without
    // a streaming loop: if it fills the whole buffer the file exceeded the limit.
    const max = 1024 * 1024;
    const buf = try allocator.alloc(u8, max + 1);
    defer allocator.free(buf);
    const n = try file.readPositionalAll(io, buf, 0);
    if (n > max) return error.FileTooLarge;
    const content = buf[0..n];

    if (content.len == 0) {
        debug.info("Empty config file: {s}, using fallback", .{path});
        return try loadFallbackConfig(allocator);
    }

    var doc = try parser.parse(allocator, content);
    defer doc.deinit();

    var cfg = getDefaultConfig(allocator);
    try parseConfigSections(allocator, &doc, &cfg);
    debug.info("Loaded: {s}", .{path});
    return cfg;
}

fn loadFallbackConfig(allocator: std.mem.Allocator) !defs.Config {
    const fallback      = @import("fallback");
    const fallback_toml = fallback.getFallbackToml();

    var doc = try parser.parse(allocator, fallback_toml);
    defer doc.deinit();

    var cfg = getDefaultConfig(allocator);
    try parseConfigSections(allocator, &doc, &cfg);

    // Iter 3: detectTerminal no longer needs an allocator (pure PATH scan).
    const terminal = try fallback.detectTerminal();
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

fn getDefaultConfig(allocator: std.mem.Allocator) defs.Config {
    var cfg = defs.Config.init(allocator);

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

fn parseConfigSections(allocator: std.mem.Allocator, doc: *const parser.Document, cfg: *defs.Config) !void {
    parseWorkspaces(doc, cfg);
    try parseKeybindings(allocator, doc, cfg);
    try parseTiling(allocator, doc, cfg);
    try parseBar(allocator, doc, cfg);
    try parseRules(allocator, doc, cfg);
}

// Keybinding parsing

const MOD_MAP = std.StaticStringMap(u16).initComptime(.{
    .{ "Super",   defs.MOD_SUPER   },
    .{ "Mod4",    defs.MOD_SUPER   },
    .{ "Alt",     defs.MOD_ALT     },
    .{ "Mod1",    defs.MOD_ALT     },
    .{ "Control", defs.MOD_CONTROL },
    .{ "Ctrl",    defs.MOD_CONTROL },
    .{ "Shift",   defs.MOD_SHIFT   },
});

/// Case-insensitive map from button name → XCB button number.
/// Supports both the generic "ButtonN" form and descriptive aliases.
const MOUSE_BUTTON_MAP = std.StaticStringMap(u8).initComptime(.{
    .{ "button1",     1 }, .{ "leftclick",   1 }, .{ "left",   1 },
    .{ "button2",     2 }, .{ "middleclick", 2 }, .{ "middle", 2 },
    .{ "button3",     3 }, .{ "rightclick",  3 }, .{ "right",  3 },
    .{ "button4",     4 }, .{ "scrollup",    4 },
    .{ "button5",     5 }, .{ "scrolldown",  5 },
});

/// Returns the XCB button number for `name`, or null if it's not a mouse button token.
inline fn mouseButtonFromName(name: []const u8) ?u8 {
    var buf: [16]u8 = undefined;
    if (name.len > buf.len) return null;
    return MOUSE_BUTTON_MAP.get(std.ascii.lowerString(&buf, name));
}

/// If `str` is a valid `Mods+ButtonName` combination, returns the parsed
/// modifiers and button number. Returns null when any token is unrecognised
/// (caller should fall through to normal keybind parsing).
fn tryParseMouseBind(str: []const u8) ?struct { modifiers: u16, button: u8 } {
    var modifiers: u16 = 0;
    var button:    ?u8 = null;
    var parts = std.mem.splitScalar(u8, str, '+');
    while (parts.next()) |part| {
        const trimmed = std.mem.trim(u8, part, " \t");
        if (MOD_MAP.get(trimmed)) |mod| {
            modifiers |= mod;
        } else if (mouseButtonFromName(trimmed)) |btn| {
            if (button != null) return null; // refuse two buttons
            button = btn;
        } else {
            return null; // unknown token → not a mouse bind
        }
    }
    return if (button) |b| .{ .modifiers = modifiers, .button = b } else null;
}

const ACTION_MAP = std.StaticStringMap(defs.Action).initComptime(.{
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
    .{ "toggle_tiling",          .toggle_tiling          },
    .{ "toggle_fullscreen",      .toggle_fullscreen      },
    .{ "fullscreen",             .toggle_fullscreen      },
    .{ "swap_master",            .swap_master            },
    .{ "dump_state",             .dump_state             },
    .{ "emergency_recover",      .emergency_recover      },
    .{ "minimize_window",        .minimize_window        },
    .{ "minimize",               .minimize_window        },
    .{ "unminimize_lifo",        .unminimize_lifo        },
    .{ "unminimize_fifo",        .unminimize_fifo        },
    .{ "unminimize_all",         .unminimize_all         },
    .{ "cycle_layout_variation", .cycle_layout_variation },
    .{ "cycle_variation",        .cycle_layout_variation },
    .{ "drun_toggle",            .drun_toggle            },
    .{ "drun",                   .drun_toggle            },
    .{ "toggle_float",           .toggle_float           },
    .{ "float",                  .toggle_float           },
});

fn parseKeybindings(allocator: std.mem.Allocator, doc: *const parser.Document, cfg: *defs.Config) !void {
    // Support both [binds] (current) and [Keybindings] (legacy).
    const section         = doc.getSection("binds") orelse doc.getSection("Keybindings") orelse return;
    const mod_placeholder = section.getString("Mod");
    // Optional: if set, `{kill}` in exec commands is replaced with this string.
    const kill_placeholder = section.getString("kill");

    var iter = section.pairs.iterator();
    while (iter.next()) |entry| {
        if (std.mem.eql(u8, entry.key_ptr.*, "Mod"))  continue;
        if (std.mem.eql(u8, entry.key_ptr.*, "kill")) continue;

        const command = entry.value_ptr.*.asString() orelse continue;

        const keybind_str = if (mod_placeholder) |mod|
            try substituteModVariable(allocator, entry.key_ptr.*, mod)
        else
            entry.key_ptr.*;
        defer if (mod_placeholder != null) allocator.free(keybind_str);

        // Substitute {kill} only when the kill placeholder is defined in config.
        const final_command: []const u8 = if (kill_placeholder) |kp|
            if (std.mem.indexOf(u8, command, "{kill}") != null)
                try std.mem.replaceOwned(u8, allocator, command, "{kill}", kp)
            else
                command
        else
            command;
        defer if (final_command.ptr != command.ptr) allocator.free(final_command);

        // Try mouse bind first (e.g. "Super+MiddleClick").  If the key string
        // contains a known button token it cannot be a valid keysym, so we
        // never fall through to parseKeybindString for it.
        if (tryParseMouseBind(keybind_str)) |mb| {
            try cfg.mouse_bindings.append(allocator, .{
                .modifiers = mb.modifiers,
                .button    = mb.button,
                .action    = try parseAction(allocator, final_command),
            });
            continue;
        }

        const parts = parseKeybindString(keybind_str) catch |err| {
            debug.warn("Failed to parse keybind '{s}': {}", .{ keybind_str, err });
            continue;
        };

        try cfg.keybindings.append(allocator, .{
            .modifiers = parts.modifiers,
            .keysym    = parts.keysym,
            .action    = try parseAction(allocator, final_command),
        });
    }
}

inline fn substituteModVariable(allocator: std.mem.Allocator, keybind: []const u8, mod: []const u8) ![]const u8 {
    if (std.mem.startsWith(u8, keybind, "Mod+"))
        return try std.fmt.allocPrint(allocator, "{s}+{s}", .{ mod, keybind["Mod+".len..] });
    return try allocator.dupe(u8, keybind);
}

fn parseKeybindString(str: []const u8) !struct { modifiers: u16, keysym: u32 } {
    var modifiers: u16 = 0;
    var keysym:   ?u32 = null;

    var parts = std.mem.splitScalar(u8, str, '+');
    while (parts.next()) |part| {
        const trimmed = std.mem.trim(u8, part, " \t");
        if (MOD_MAP.get(trimmed)) |mod| {
            modifiers |= mod;
        } else {
            if (keysym != null) return error.MultipleKeys;
            keysym = try keyNameToKeysym(trimmed);
        }
    }
    return .{ .modifiers = modifiers, .keysym = keysym orelse return error.NoKeysym };
}

fn keyNameToKeysym(name: []const u8) !u32 {
    if (name.len >= 64) return error.KeyNameTooLong;
    var buf: [64]u8 = undefined;
    @memcpy(buf[0..name.len], name);
    buf[name.len] = 0;
    const keysym = xkbcommon.xkb_keysym_from_name(@ptrCast(&buf), xkbcommon.XKB_KEYSYM_CASE_INSENSITIVE);
    return if (keysym == xkbcommon.XKB_KEY_NoSymbol) error.UnknownKeyName else keysym;
}

/// Extracts a workspace index from commands like `"workspace_3"` or `"move_to_workspace_2"`.
inline fn tryParseWorkspace(command: []const u8, prefix: []const u8) ?u8 {
    if (!std.mem.startsWith(u8, command, prefix)) return null;
    const num = std.fmt.parseInt(usize, command[prefix.len..], 10) catch return null;
    if (num < 1 or num > 256) return null;
    return @intCast(num - 1);
}

fn parseAction(allocator: std.mem.Allocator, cmd: []const u8) !defs.Action {
    if (ACTION_MAP.get(cmd))                         |a| return a;
    if (tryParseWorkspace(cmd, "workspace_"))         |ws| return .{ .switch_workspace  = ws };
    if (tryParseWorkspace(cmd, "move_to_workspace_")) |ws| return .{ .move_to_workspace = ws };
    if (tryParseWorkspace(cmd, "tag_toggle_"))        |ws| return .{ .tag_toggle        = ws };
    if (tryParseWorkspace(cmd, "tag_additive_"))      |ws| return .{ .tag_additive      = ws };
    return .{ .exec = try allocator.dupe(u8, cmd) };
}

// Public post-load helpers

/// Scales font size and other DPI-dependent fields. Call once the screen is available.
pub inline fn finalizeConfig(cfg: *defs.Config, screen: *defs.xcb.xcb_screen_t) void {
    const dpi_module = @import("dpi");
    cfg.bar.scaled_font_size = dpi_module.scaleFontSize(cfg.bar.font_size, screen);
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

// Section parsers

fn parseWorkspaces(doc: *const parser.Document, cfg: *defs.Config) void {
    // Support both [bar.modules.workspaces] (current) and [workspaces] (legacy).
    const section = doc.getSection("bar.modules.workspaces") orelse doc.getSection("workspaces") orelse return;
    cfg.workspaces.count = get(u8, section, "count", 9, 1, null);
}

fn parseTiling(allocator: std.mem.Allocator, doc: *const parser.Document, cfg: *defs.Config) !void {
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
        // Fallback to single "layout" field.
        const layout_str = get([]const u8, section, "layout", "master_left", null, null);
        cfg.allocated_layout = try allocator.dupe(u8, layout_str);
        cfg.tiling.layout    = cfg.allocated_layout.?;
        try cfg.tiling.layouts.append(allocator, try allocator.dupe(u8, layout_str));
    }

    const aesthetic_src = doc.getSection("tiling.aesthetics") orelse section;
    cfg.tiling.gaps         = aesthetic_src.getScalable("gaps")         orelse parser.ScalableValue.absolute(10.0);
    cfg.tiling.border_width = aesthetic_src.getScalable("border_width") orelse parser.ScalableValue.absolute(2.0);
    cfg.tiling.border_focused   = getColor(aesthetic_src, "border_focused",   0x5294E2);
    cfg.tiling.border_unfocused = getColor(aesthetic_src, "border_unfocused", 0x383C4A);

    const master_src = doc.getSection("tiling.layouts.master-stack") orelse section;
    const dedicated  = master_src != section; // true when [tiling.layouts.master-stack] exists

    cfg.tiling.master_count = get(u8, master_src, if (dedicated) "count" else "master_count", 1, 1, null);
    if (master_src.getString(if (dedicated) "side"  else "master_side"))  |s| cfg.tiling.master_side  = defs.MasterSide.fromStringWithAlias(s) orelse .left;
    cfg.tiling.master_width = master_src.getScalable(if (dedicated) "width" else "master_width") orelse parser.ScalableValue.percentage(50.0);

    parseTilingVariations(doc, cfg);

    cfg.tiling.global_layout = get(bool, section, "global_layout", false, null, null);
}

// Iter 2: extracted shared variation-parse and indicator-parse helpers to
// replace four near-identical copy-paste blocks in parseTilingVariations.

/// Parses a `variation = "..."` key from `section` as type T.
/// Leaves `field` unchanged and warns if the value is not a valid T tag.
inline fn tryParseVariation(
    comptime T:   type,
    section:      *const parser.Section,
    layout_name:  []const u8,
    field:        *T,
) void {
    const v = section.getString("variation") orelse return;
    field.* = std.meta.stringToEnum(T, v) orelse {
        debug.warn("Unknown {s} variation '{s}', using default", .{ layout_name, v });
        return;
    };
}

/// Parses an `indicator = "..."` key from `section` into a ?[3]u8 field.
inline fn tryParseIndicator(section: *const parser.Section, field: *?[3]u8) void {
    if (section.getString("indicator")) |raw| field.* = parseIndicator(raw);
}

/// Parses per-layout variation and indicator settings from [tiling.layouts.*] sections.
fn parseTilingVariations(doc: *const parser.Document, cfg: *defs.Config) void {
    if (doc.getSection("tiling.layouts.master-stack")) |ms| {
        tryParseVariation(defs.MasterVariation,   ms, "master-stack", &cfg.tiling.master_variation);
        tryParseIndicator(ms, &cfg.tiling.master_indicator);
    }

    if (doc.getSection("tiling.layouts.monocle")) |ms| {
        tryParseVariation(defs.MonocleVariation,  ms, "monocle",      &cfg.tiling.monocle_variation);
        tryParseIndicator(ms, &cfg.tiling.monocle_indicator);
    }

    if (doc.getSection("tiling.layouts.grid")) |ms| {
        tryParseVariation(defs.GridVariation,     ms, "grid",         &cfg.tiling.grid_variation);
        tryParseIndicator(ms, &cfg.tiling.grid_indicator);
    }

    if (doc.getSection("tiling.layouts.fibonacci")) |ms| {
        if (ms.getString("variation")) |v|
            if (!std.mem.eql(u8, v, "default"))
                debug.warn("fibonacci does not support variation '{s}' (ignored)", .{v});
        if (ms.getString("indicator")) |raw| cfg.tiling.fibonacci_indicator = parseIndicator(raw);
    }
}

// Layout-array helpers

/// Copies up to 3 bytes of `raw` into a fixed [3]u8, padding with spaces.
inline fn parseIndicator(raw: []const u8) [3]u8 {
    var ind: [3]u8 = "   ".*;
    const n = @min(raw.len, 3);
    @memcpy(ind[0..n], raw[0..n]);
    return ind;
}

const KNOWN_LAYOUT_SET = std.StaticStringMap(void).initComptime(.{
    .{ "master-stack", {} }, .{ "master_stack", {} }, .{ "master", {} },
    .{ "monocle", {} }, .{ "grid", {} }, .{ "fibonacci", {} },
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

/// Parses a variation string for the given layout name into a LayoutVariationOverride.
/// Returns null and emits a warning when the string is not valid for that layout.
fn parseLayoutVariation(layout_name: []const u8, variation_str: []const u8) ?defs.LayoutVariationOverride {
    var buf: [32]u8 = undefined;
    if (layout_name.len > buf.len) return null;
    const lower_layout = std.ascii.lowerString(buf[0..layout_name.len], layout_name);

    const typed_layouts = .{
        .{ "master-stack", defs.MasterVariation,  "master"   },
        .{ "monocle",      defs.MonocleVariation, "monocle"  },
        .{ "grid",         defs.GridVariation,    "grid"     },
    };
    inline for (typed_layouts) |entry| {
        if (std.mem.eql(u8, lower_layout, entry[0])) {
            const v = std.meta.stringToEnum(entry[1], variation_str) orelse {
                debug.warn("Unknown {s} variation '{s}' in layouts array, ignoring", .{ entry[0], variation_str });
                return null;
            };
            return @unionInit(defs.LayoutVariationOverride, entry[2], v);
        }
    }
    if (std.mem.eql(u8, lower_layout, "fibonacci")) {
        if (!std.mem.eql(u8, variation_str, "default"))
            debug.warn("fibonacci does not support variation '{s}' in layouts array, ignoring", .{variation_str});
        return .{ .fibonacci = .default };
    }
    return null;
}

/// Parses the `layouts` TOML array. Supports an extended grouping format:
///
///   layouts = [
///       "master-stack",
///       "monocle", "gapless", "4,8",   -- variation then workspace list
///       "grid", "3,6",                  -- just workspace list, no variation
///       "fibonacci",
///   ]
///
/// A known layout name starts a new group. The next element (if not a layout name) is
/// treated as a variation override if it is a variation word, or a workspace list if it
/// consists only of digits and commas. A third element may follow as the workspace list
/// when the second was a variation. The plain single-name format is fully backward-compatible.
fn parseLayoutsArray(
    allocator: std.mem.Allocator,
    arr:       []const parser.Value,
    cfg:       *defs.Config,
) !void {
    var i: usize = 0;
    while (i < arr.len) : (i += 1) {
        const name_str = arr[i].asString() orelse {
            debug.warn("layouts array: expected a string at index {}, skipping", .{i});
            continue;
        };

        if (!isKnownLayout(name_str)) {
            debug.warn("layouts array: unknown layout name '{s}' at index {}, skipping", .{ name_str, i });
            continue;
        }

        var name_buf: [32]u8 = undefined;
        const canonical = canonicalLayout(name_str, &name_buf);
        const layout_idx: u8 = @intCast(cfg.tiling.layouts.items.len);
        try cfg.tiling.layouts.append(allocator, try allocator.dupe(u8, canonical));

        // Look ahead for optional variation and/or workspace-list elements.
        var variation: ?defs.LayoutVariationOverride = null;
        var ws_list_str: ?[]const u8 = null;

        if (i + 1 < arr.len) {
            if (arr[i + 1].asString()) |peek| {
                if (!isKnownLayout(peek)) {
                    if (isWorkspaceList(peek)) {
                        ws_list_str = peek;
                        i += 1;
                    } else {
                        variation = parseLayoutVariation(canonical, peek);
                        i += 1;
                        // After a variation, also peek for an optional workspace list.
                        if (i + 1 < arr.len) {
                            if (arr[i + 1].asString()) |peek2| {
                                if (isWorkspaceList(peek2)) {
                                    ws_list_str = peek2;
                                    i += 1;
                                }
                            }
                        }
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
                    .variation     = variation,
                });
            }
        }
    }
}

// Iter 1: removed `field_name` from BarColorField — it was always equal to `name`,
// so storing both was pure duplication. The inline for now uses `field.name` for both
// the TOML key lookup and the struct field pointer.
const BarColorField = struct { name: []const u8, default: u32 };

const BAR_COLOR_FIELDS = [_]BarColorField{
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
        if (i == 1) { debug.info("Transparency set to 1 (fully opaque)", .{}); return 1.0; }
        if (i >= 2 and i <= 100) return @as(f32, @floatFromInt(i)) / 100.0;
        debug.warn("Invalid transparency value {} (must be 0–100), using default", .{i});
        return 1.0;
    }
    if (value.asScalable()) |s| return if (s.is_percentage) s.value / 100.0 else s.value;
    if (value.asString()) |str| {
        const trimmed = std.mem.trim(u8, str, " \t");
        const f = std.fmt.parseFloat(f32, trimmed) catch {
            debug.warn("Invalid transparency value '{s}', using default", .{trimmed});
            return 1.0;
        };
        if (f == 1.0) { debug.info("Transparency set to 1.0 (fully opaque)", .{}); return 1.0; }
        if (f >= 0.0 and f < 1.0)   return f;
        if (f > 1.0 and f <= 100.0) return f / 100.0;
        debug.warn("Invalid transparency value {d} (must be 0.0–1.0 or 0–100), using default", .{f});
        return 1.0;
    }
    return 1.0;
}

fn parseBar(allocator: std.mem.Allocator, doc: *const parser.Document, cfg: *defs.Config) !void {
    const section = doc.getSection("bar") orelse return;
    cfg.bar.enabled = get(bool, section, "enabled", true, null, null);

    if (section.getString("position")) |pos_str|
        cfg.bar.vertical_position = defs.BarVerticalPosition.fromString(pos_str) orelse .top;

    // height accepts a raw pixel value or a percentage of screen height.
    // Null = auto-calculate from font metrics. Resolution happens at bar-init time.
    cfg.bar.height = section.getScalable("height");

    const font_str = get([]const u8, section, "font", "monospace:size=10", null, null);
    cfg.allocated_font = try allocator.dupe(u8, font_str);
    cfg.bar.font       = cfg.allocated_font.?;

    if (section.get("fonts")) |value| {
        if (value.asArray()) |arr| {
            for (cfg.bar.fonts.items) |font| allocator.free(font);
            cfg.bar.fonts.clearRetainingCapacity();
            for (arr) |item| {
                if (item.asString()) |name|
                    try cfg.bar.fonts.append(allocator, try allocator.dupe(u8, name));
            }
            debug.info("Loaded {} fonts for bar", .{cfg.bar.fonts.items.len});
        }
    }

    cfg.bar.font_size     = section.getScalable("font_size") orelse parser.ScalableValue.percentage(10.0);
    cfg.bar.spacing       = section.getScalable("segment_spacing") orelse parser.ScalableValue.absolute(12.0);

    // Iter 1: `field_name` removed from BarColorField; use `field.name` for both key and field.
    inline for (BAR_COLOR_FIELDS) |field|
        @field(cfg.bar, field.name) = getColor(section, field.name, field.default);

    cfg.bar.workspaces_accent       = getColor(section, "workspaces_accent",       cfg.bar.accent_color);
    cfg.bar.title_accent_color      = getColor(section, "title_accent_color",      cfg.bar.accent_color);
    cfg.bar.title_unfocused_accent  = getColor(section, "title_unfocused_accent",  cfg.bar.bg);
    cfg.bar.clock_accent            = getColor(section, "clock_accent",            cfg.bar.accent_color);

    const clock_fmt = get([]const u8, section, "clock_format", "%Y-%m-%d %H:%M:%S", null, null);
    cfg.allocated_clock_format = try allocator.dupe(u8, clock_fmt);
    cfg.bar.clock_format       = cfg.allocated_clock_format.?;

    const drun_prompt = get([]const u8, section, "drun_prompt", "run: ", null, null);
    cfg.allocated_drun_prompt = try allocator.dupe(u8, drun_prompt);
    cfg.bar.drun_prompt       = cfg.allocated_drun_prompt.?;

    cfg.bar.indicator_size      = section.getScalable("indicator_size")      orelse parser.ScalableValue.percentage(20.0);
    cfg.bar.workspace_tag_width = section.getScalable("workspace_tag_width") orelse parser.ScalableValue.percentage(100.0);

    if (section.getString("indicator_location")) |loc_str| {
        cfg.bar.indicator_location = defs.IndicatorLocation.fromString(loc_str) orelse blk: {
            debug.warn("Unknown indicator_location '{s}', using default 'up-left'", .{loc_str});
            break :blk .up_left;
        };
    }

    // indicator_padding: percentage (e.g. "10%") or decimal (e.g. "0.1") → stored as 0.0–1.0
    if (section.get("indicator_padding")) |val| {
        const f: f32 = if (val.asScalable()) |sv|
            if (sv.is_percentage) sv.value / 100.0 else sv.value
        else if (val.asInt()) |i|
            @as(f32, @floatFromInt(i)) / 100.0
        else
            0.1;
        cfg.bar.indicator_padding = std.math.clamp(f, 0.0, 1.0);
    }

    // indicator_focused / indicator_unfocused: if only one is set, the other mirrors it.
    const raw_focused   = section.getString("indicator_focused");
    const raw_unfocused = section.getString("indicator_unfocused");
    if (raw_focused orelse raw_unfocused) |_| {
        cfg.allocated_indicator_focused   = try allocator.dupe(u8, raw_focused   orelse raw_unfocused.?);
        cfg.allocated_indicator_unfocused = try allocator.dupe(u8, raw_unfocused orelse raw_focused.?);
        cfg.bar.indicator_focused   = cfg.allocated_indicator_focused.?;
        cfg.bar.indicator_unfocused = cfg.allocated_indicator_unfocused.?;
    }

    // indicator_color (optional; null = inherit workspace fg)
    if (section.get("indicator_color")) |_|
        cfg.bar.indicator_color = getColor(section, "indicator_color", cfg.bar.fg);

    if (section.get("transparency")) |value|
        cfg.bar.transparency = std.math.clamp(parseTransparency(value), 0.0, 1.0);

    try parseWorkspaceIcons(allocator, section, cfg);
    try parseBarLayout(allocator, doc, cfg);

    // Iter 3: use BarConfig accessor methods as defaults instead of repeating
    // the `orelse cfg.bar.accent_color` fallback that the accessors already encode.
    if (doc.getSection("bar.colors")) |colors| {
        cfg.bar.workspaces_accent      = getColor(colors, "workspaces",      cfg.bar.getWorkspaceAccent());
        cfg.bar.title_accent_color     = getColor(colors, "title",           cfg.bar.getTitleAccent());
        cfg.bar.title_unfocused_accent = getColor(colors, "title_unfocused", cfg.bar.getTitleUnfocusedAccent());
        cfg.bar.title_minimized_accent = getColor(colors, "title_minimized", cfg.bar.getTitleMinimizedAccent());
        cfg.bar.clock_accent           = getColor(colors, "clock",           cfg.bar.getClockAccent());
        if (colors.get("drun_bg"))           |_| cfg.bar.drun_bg           = getColor(colors, "drun_bg",           cfg.bar.getDrunBg());
        if (colors.get("drun_fg"))           |_| cfg.bar.drun_fg           = getColor(colors, "drun_fg",           cfg.bar.getDrunFg());
        if (colors.get("drun_prompt_color")) |_| cfg.bar.drun_prompt_color = getColor(colors, "drun_prompt_color", cfg.bar.getDrunPromptColor());
    }
}

fn parseWorkspaceIcons(allocator: std.mem.Allocator, section: *const parser.Section, cfg: *defs.Config) !void {
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

fn parseBarLayout(allocator: std.mem.Allocator, doc: *const parser.Document, cfg: *defs.Config) !void {
    for (cfg.bar.layout.items) |*item| item.deinit(allocator);
    cfg.bar.layout.clearRetainingCapacity();

    const positions = [_]struct { name: []const u8, pos: defs.BarPosition }{
        .{ .name = "bar.layout.left",   .pos = .left   },
        .{ .name = "bar.layout.center", .pos = .center },
        .{ .name = "bar.layout.right",  .pos = .right  },
    };

    for (positions) |p| {
        const layout_section = doc.getSection(p.name) orelse continue;
        var bar_layout = defs.BarLayout{ .position = p.pos, .segments = std.ArrayList(defs.BarSegment){} };

        if (layout_section.get("segments")) |seg_value| {
            if (seg_value.asArray()) |seg_arr| {
                for (seg_arr) |item| {
                    if (item.asString()) |s| {
                        if (defs.BarSegment.fromString(s)) |segment|
                            try bar_layout.segments.append(allocator, segment);
                    }
                }
            }
        }

        if (bar_layout.segments.items.len > 0) {
            try cfg.bar.layout.append(allocator, bar_layout);
        } else {
            bar_layout.deinit(allocator);
        }
    }

    if (cfg.bar.layout.items.len == 0) try initDefaultBarLayout(allocator, cfg);
}

fn parseRules(allocator: std.mem.Allocator, doc: *const parser.Document, cfg: *defs.Config) !void {
    if (doc.getSection("workspace.rules")) |rules_section| {
        var iter = rules_section.pairs.iterator();
        while (iter.next()) |entry| {
            const ws_num = std.fmt.parseInt(usize, entry.key_ptr.*, 10) catch {
                // Not a number — treat as a class name with the value as workspace index.
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

    // Legacy [rules] section.
    if (doc.getSection("rules")) |rules_section| {
        var iter = rules_section.pairs.iterator();
        while (iter.next()) |entry| {
            const ws_num = entry.value_ptr.*.asInt() orelse continue;
            if (!validateWorkspace(@intCast(ws_num), cfg.workspaces.count, entry.key_ptr.*)) continue;
            try addRule(allocator, cfg, entry.key_ptr.*, @intCast(ws_num));
        }
    }

    // Per-workspace sections: [workspace.rules.N] or [rules.N].
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
