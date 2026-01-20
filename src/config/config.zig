//! Streamlined configuration parser with minimal boilerplate
const std = @import("std");
const defs = @import("defs");
const parser = @import("parser");
const xkb = @import("xkbcommon");
const log = @import("logging");

// VALIDATION HELPERS

fn inRange(comptime T: type, val: T, min: T, max: T) bool {
    return val >= min and val <= max;
}

fn isValidColor(val: u32) bool {
    return val <= 0xFFFFFF;
}

/// Generic config getter with validation
fn get(
    comptime T: type,
    section: *const parser.Section,
    key: []const u8,
    default: T,
    comptime validator: ?fn (T) bool,
) T {
    const value = switch (T) {
        bool => section.getBool(key) orelse return default,
        []const u8 => section.getString(key) orelse return default,
        f32 => blk: {
            if (section.getInt(key)) |i| {
                break :blk @as(f32, @floatFromInt(i)) / 100.0;
            }
            return default;
        },
        u16, u32, usize => blk: {
            const i = section.getInt(key) orelse return default;
            break :blk @as(T, @intCast(i));
        },
        else => @compileError("Unsupported type"),
    };

    if (validator) |v| {
        if (!v(value)) {
            std.log.warn("[config] Invalid {s}: using default", .{key});
            return default;
        }
    }

    return value;
}

pub fn loadConfigDefault(allocator: std.mem.Allocator) !defs.Config {
    // Try local ./config.toml first
    const cwd = try std.process.getCwdAlloc(allocator);
    defer allocator.free(cwd);

    const local = try std.fs.path.join(allocator, &.{ cwd, "config.toml" });
    defer allocator.free(local);

    if (loadConfig(allocator, local)) |config| {
        return config;
    } else |_| {
        // Fallback to XDG config
        const home = if (std.c.getenv("HOME")) |h| std.mem.span(h) else ".";
        const config_home = if (std.c.getenv("XDG_CONFIG_HOME")) |ch|
            std.mem.span(ch)
        else
            try std.fmt.allocPrint(allocator, "{s}/.config", .{home});
        defer if (std.c.getenv("XDG_CONFIG_HOME") == null) allocator.free(config_home);

        const xdg_path = try std.fs.path.join(allocator, &.{ config_home, "hana", "config.toml" });
        defer allocator.free(xdg_path);

        return loadConfig(allocator, xdg_path);
    }
}

pub fn loadConfig(allocator: std.mem.Allocator, path: []const u8) !defs.Config {
    // Use POSIX APIs directly - read file into buffer
    const path_z = try allocator.dupeZ(u8, path);
    defer allocator.free(path_z);

    const fd = std.posix.open(path_z, .{ .ACCMODE = .RDONLY }, 0) catch |err| {
        if (err == error.FileNotFound) {
            log.configNotFound(path);
            return getDefaultConfig();
        }
        return err;
    };
    defer std.posix.close(fd);

    // Read file in chunks - allocate reasonable buffer (1MB max)
    var content = std.ArrayList(u8){};
    try content.ensureTotalCapacity(allocator, 4096);
    defer content.deinit(allocator);

    var buf: [4096]u8 = undefined;
    while (true) {
        const bytes_read = try std.posix.read(fd, &buf);
        if (bytes_read == 0) break;
        try content.appendSlice(allocator, buf[0..bytes_read]);
        if (content.items.len > 1024 * 1024) return error.FileTooLarge;
    }

    var doc = try parser.parse(allocator, content.items);
    defer doc.deinit();

    var config = getDefaultConfig();
    try parseKeybindings(allocator, &doc, &config);
    parseTiling(&doc, &config);
    parseWorkspaces(&doc, &config);
    try parseRules(allocator, &doc, &config);
    try validateConfig(allocator, &config);

    log.configLoaded(path);
    return config;
}

fn getDefaultConfig() defs.Config {
    return .{};
}

// KEYBINDINGS

const MOD_MAP = std.StaticStringMap(u16).initComptime(.{
    .{ "Super", defs.MOD_SUPER },
    .{ "Mod4", defs.MOD_SUPER },
    .{ "Alt", defs.MOD_ALT },
    .{ "Mod1", defs.MOD_ALT },
    .{ "Control", defs.MOD_CONTROL },
    .{ "Ctrl", defs.MOD_CONTROL },
    .{ "Shift", defs.MOD_SHIFT },
});

const ACTION_MAP = std.StaticStringMap(defs.Action).initComptime(.{
    .{ "close", .close_window },
    .{ "kill", .close_window },
    .{ "reload", .reload_config },
    .{ "reload_config", .reload_config },
    .{ "focus_next", .focus_next },
    .{ "focus_prev", .focus_prev },
    .{ "toggle_layout", .toggle_layout },
    .{ "increase_master", .increase_master },
    .{ "decrease_master", .decrease_master },
    .{ "increase_master_count", .increase_master_count },
    .{ "decrease_master_count", .decrease_master_count },
    .{ "toggle_tiling", .toggle_tiling },
    .{ "dump_state", .dump_state },
    .{ "emergency_recover", .emergency_recover },
});

fn parseKeybindings(allocator: std.mem.Allocator, doc: *const parser.Document, config: *defs.Config) !void {
    const section = doc.getSection("Keybindings") orelse return;

    const mod_substitute = section.getString("Mod");

    var iter = section.pairs.iterator();
    while (iter.next()) |entry| {
        if (std.mem.eql(u8, entry.key_ptr.*, "Mod")) continue;

        const command = entry.value_ptr.*.asString() orelse continue;

        const keybind_str = if (mod_substitute) |mod|
            try substituteModVariable(allocator, entry.key_ptr.*, mod)
        else
            entry.key_ptr.*;
        defer if (mod_substitute != null) allocator.free(keybind_str);

        const parts = parseKeybindString(keybind_str) catch continue;
        const action = try parseAction(allocator, command);

        try config.keybindings.append(allocator, .{
            .modifiers = parts.modifiers,
            .keysym = parts.keysym,
            .action = action,
        });
    }
}

fn substituteModVariable(allocator: std.mem.Allocator, keybind: []const u8, mod: []const u8) ![]const u8 {
    if (std.mem.startsWith(u8, keybind, "Mod+")) {
        return try std.fmt.allocPrint(allocator, "{s}+{s}", .{ mod, keybind[4..] });
    }
    return try allocator.dupe(u8, keybind);
}

fn parseKeybindString(str: []const u8) !struct { modifiers: u16, keysym: u32 } {
    var modifiers: u16 = 0;
    var keysym: ?u32 = null;

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

    const keysym = xkb.xkb_keysym_from_name(@ptrCast(&buf), xkb.XKB_KEYSYM_CASE_INSENSITIVE);
    return if (keysym == xkb.XKB_KEY_NoSymbol) error.UnknownKeyName else keysym;
}

fn parseAction(allocator: std.mem.Allocator, cmd: []const u8) !defs.Action {
    if (ACTION_MAP.get(cmd)) |action| return action;

    // Workspace commands
    if (std.mem.startsWith(u8, cmd, "workspace_")) {
        const num = try std.fmt.parseInt(usize, cmd[10..], 10);
        if (num < 1 or num > 20) return error.InvalidWorkspace;
        return .{ .switch_workspace = num - 1 };
    }

    if (std.mem.startsWith(u8, cmd, "move_to_workspace_")) {
        const num = try std.fmt.parseInt(usize, cmd[18..], 10);
        if (num < 1 or num > 20) return error.InvalidWorkspace;
        return .{ .move_to_workspace = num - 1 };
    }

    // Shell command
    return .{ .exec = try allocator.dupe(u8, cmd) };
}

pub fn resolveKeybindings(keybindings: anytype, xkb_state: *xkb.XkbState) void {
    for (keybindings) |*kb| {
        kb.keycode = xkb_state.keysymToKeycode(kb.keysym);
    }
}

// TILING CONFIG

fn parseTiling(doc: *const parser.Document, config: *defs.Config) void {
    const section = doc.getSection("tiling") orelse return;

    config.tiling.enabled = get(bool, section, "enabled", true, null);
    config.tiling.layout = get([]const u8, section, "layout", "master_left", null);
    config.tiling.master_count = get(usize, section, "master_count", 1, struct {
        fn v(n: usize) bool {
            return n >= 1;
        }
    }.v);
    config.tiling.master_width_factor = get(f32, section, "master_width_factor", 50.0, struct {
        fn v(n: f32) bool {
            return inRange(f32, n, 0.05, 0.95);
        }
    }.v);
    config.tiling.gaps = get(u16, section, "gaps", 10, struct {
        fn v(n: u16) bool {
            return n <= 200;
        }
    }.v);
    config.tiling.border_width = get(u16, section, "border_width", 2, struct {
        fn v(n: u16) bool {
            return n <= 100;
        }
    }.v);
    config.tiling.border_focused = get(u32, section, "border_focused", 0x5294E2, isValidColor);
    config.tiling.border_normal = get(u32, section, "border_normal", 0x383C4A, isValidColor);
}

// WORKSPACES CONFIG

fn parseWorkspaces(doc: *const parser.Document, config: *defs.Config) void {
    const section = doc.getSection("workspaces") orelse return;

    config.workspaces.count = get(usize, section, "count", 9, struct {
        fn v(n: usize) bool {
            return inRange(usize, n, 1, 20);
        }
    }.v);
}

fn parseRules(allocator: std.mem.Allocator, doc: *const parser.Document, config: *defs.Config) !void {
    // Support [rules] section
    if (doc.getSection("rules")) |section| {
        var iter = section.pairs.iterator();
        while (iter.next()) |entry| {
            const ws_num = entry.value_ptr.*.asInt() orelse continue;
            if (ws_num < 1 or ws_num > 20) continue;

            const rule = defs.Rule{
                .class_name = try allocator.dupe(u8, entry.key_ptr.*),
                .workspace = @intCast(ws_num - 1),
            };
            try config.workspaces.rules.append(allocator, rule);
        }
    }

    // Support [rules.N] sections
    var section_iter = doc.sections.iterator();
    while (section_iter.next()) |entry| {
        const name = entry.key_ptr.*;
        const ws_str = if (std.mem.startsWith(u8, name, "workspace.rules."))
            name[16..]
        else if (std.mem.startsWith(u8, name, "rules."))
            name[6..]
        else
            continue;

        const ws_num = std.fmt.parseInt(usize, ws_str, 10) catch continue;
        if (ws_num < 1 or ws_num > 20) continue;

        var iter = entry.value_ptr.pairs.iterator();
        while (iter.next()) |class_entry| {
            const rule = defs.Rule{
                .class_name = try allocator.dupe(u8, class_entry.key_ptr.*),
                .workspace = ws_num - 1,
            };
            try config.workspaces.rules.append(allocator, rule);
        }
    }
}

// VALIDATION

fn validateConfig(allocator: std.mem.Allocator, config: *const defs.Config) !void {
    if (config.keybindings.items.len < 2) return;

    var sorted = try allocator.dupe(defs.Keybind, config.keybindings.items);
    defer allocator.free(sorted);

    std.mem.sort(defs.Keybind, sorted, {}, struct {
        fn lt(_: void, a: defs.Keybind, b: defs.Keybind) bool {
            return if (a.modifiers != b.modifiers)
                a.modifiers < b.modifiers
            else
                a.keysym < b.keysym;
        }
    }.lt);

    for (sorted[0 .. sorted.len - 1], sorted[1..]) |a, b| {
        if (a.modifiers == b.modifiers and a.keysym == b.keysym) {
            return error.DuplicateKeybinding;
        }
    }
}
