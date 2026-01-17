// Configuration parser - optimized with lookup tables

const std = @import("std");
const defs = @import("defs");
const parser = @import("parser");
const xkb = @import("xkbcommon");

const Config = defs.Config;

pub const ValidationError = error{
    InvalidKeybinding,
    DuplicateKeybinding,
    XkbInitFailed,
    InvalidConfigValue,
};

const MODIFIER_MAP = std.StaticStringMap(u16).initComptime(.{
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

pub fn getConfigPath(allocator: std.mem.Allocator) ![]const u8 {
    // Check local config first
    const cwd_path = try std.process.getCwdAlloc(allocator);
    defer allocator.free(cwd_path);

    const local_path = try std.fs.path.join(allocator, &.{ cwd_path, "config.toml" });
    const local_path_z = try allocator.dupeZ(u8, local_path);
    defer allocator.free(local_path_z);

    const fd_local = std.posix.open(local_path_z, .{ .ACCMODE = .RDONLY }, 0) catch -1;
    if (fd_local != -1) {
        std.posix.close(@intCast(fd_local));
        return local_path;
    }
    allocator.free(local_path);

    // Fallback to XDG
    const home = if (std.c.getenv("HOME")) |s| std.mem.span(s) else ".";
    var config_home: []const u8 = undefined;
    var owned = false;

    if (std.c.getenv("XDG_CONFIG_HOME")) |s| {
        config_home = std.mem.span(s);
    } else {
        config_home = try std.fmt.allocPrint(allocator, "{s}/.config", .{home});
        owned = true;
    }
    defer if (owned) allocator.free(config_home);

    return std.fs.path.join(allocator, &.{ config_home, "hana", "config.toml" });
}

pub fn loadConfig(allocator: std.mem.Allocator, path: []const u8) !Config {
    var threaded: std.Io.Threaded = .init_single_threaded;
    defer threaded.deinit();
    const io = threaded.io();

    const file = std.Io.Dir.openFileAbsolute(io, path, .{}) catch |err| {
        if (err == error.FileNotFound) {
            std.log.info("Config file not found at '{s}', using defaults", .{path});
            return getDefaultConfig();
        }
        return err;
    };
    defer file.close(io);

    var read_buf: [16384]u8 = undefined;  // Increased buffer size to 16KB
    var file_reader = file.reader(io, &read_buf);
    var buffer = std.Io.Writer.Allocating.init(allocator);
    defer buffer.deinit();
    _ = try file_reader.interface.streamRemaining(&buffer.writer);
    const content = try allocator.dupe(u8, buffer.written());
    defer allocator.free(content);

    var doc = try parser.parse(allocator, content);
    defer doc.deinit();

    var config = getDefaultConfig();
    try parseKeybindings(allocator, &doc, &config);
    try parseTiling(&doc, &config);
    try parseWorkspaces(&doc, &config);
    try parseRules(allocator, &doc, &config);
    try validateConfig(allocator, &config);

    std.log.info("Successfully loaded config from: {s}", .{path});
    return config;
}

pub fn loadConfigDefault(allocator: std.mem.Allocator) !Config {
    const path = try getConfigPath(allocator);
    defer allocator.free(path);
    return loadConfig(allocator, path);
}

fn parseKeybindings(allocator: std.mem.Allocator, doc: *const parser.Document, config: *Config) !void {
    const section = doc.getSection("Keybindings") orelse return;
    try config.keybindings.ensureTotalCapacity(allocator, section.pairs.count());

    var mod_substitute: ?[]const u8 = null;
    if (section.getString("Mod")) |mod_value| {
        mod_substitute = mod_value;
        std.log.info("Found Mod variable: {s}", .{mod_value});
    }

    var iter = section.pairs.iterator();
    while (iter.next()) |entry| {
        if (std.mem.eql(u8, entry.key_ptr.*, "Mod")) continue;

        const command = entry.value_ptr.*.asString() orelse {
            std.log.warn("Keybinding value must be a string: {s}", .{entry.key_ptr.*});
            continue;
        };

        const keybind_str = if (mod_substitute) |mod_val|
            try substituteModVariable(allocator, entry.key_ptr.*, mod_val)
        else
            entry.key_ptr.*;
        defer if (mod_substitute != null) allocator.free(keybind_str);

        const parts = parseKeybindString(keybind_str) catch |err| {
            // Free allocated string before continuing (fixes memory leak)
            if (mod_substitute != null) allocator.free(keybind_str);
            std.log.warn("Invalid keybinding '{s}': {any}", .{entry.key_ptr.*, err});
            continue;
        };

        const action = try parseAction(allocator, command);

        try config.keybindings.append(allocator, .{
            .modifiers = parts.modifiers,
            .keysym = parts.keysym,
            .action = action,
        });
    }
}

fn parseAction(allocator: std.mem.Allocator, command: []const u8) !defs.Action {
    // Check static action map first
    if (ACTION_MAP.get(command)) |action| {
        std.log.info("[config] Keybinding → {s} action", .{command});
        return action;
    }

    // Check for workspace commands
    if (std.mem.startsWith(u8, command, "workspace_")) {
        const num_str = command[10..];
        const ws_num = std.fmt.parseInt(usize, num_str, 10) catch {
            std.log.warn("[config] Invalid workspace number in '{s}'", .{command});
            return error.InvalidConfigValue;
        };
        if (ws_num < 1 or ws_num > 20) {
            std.log.err("[config] Workspace number must be 1-20, got {}", .{ws_num});
            return error.InvalidConfigValue;
        }
        std.log.info("[config] Keybinding → switch to workspace {}", .{ws_num});
        return .{ .switch_workspace = ws_num - 1 };
    }

    if (std.mem.startsWith(u8, command, "move_to_workspace_")) {
        const num_str = command[18..];
        const ws_num = std.fmt.parseInt(usize, num_str, 10) catch {
            std.log.warn("[config] Invalid workspace number in '{s}'", .{command});
            return error.InvalidConfigValue;
        };
        if (ws_num < 1 or ws_num > 20) {
            std.log.err("[config] Workspace number must be 1-20, got {}", .{ws_num});
            return error.InvalidConfigValue;
        }
        std.log.info("[config] Keybinding → move to workspace {}", .{ws_num});
        return .{ .move_to_workspace = ws_num - 1 };
    }

    // Default: shell command
    std.log.info("[config] Keybinding → exec: {s}", .{command});
    return .{ .exec = try allocator.dupe(u8, command) };
}

fn substituteModVariable(allocator: std.mem.Allocator, keybind: []const u8, mod_value: []const u8) ![]const u8 {
    if (std.mem.startsWith(u8, keybind, "Mod+")) {
        return try std.fmt.allocPrint(allocator, "{s}+{s}", .{ mod_value, keybind[4..] });
    }
    return try allocator.dupe(u8, keybind);
}

fn parseTiling(doc: *const parser.Document, config: *Config) !void {
    const section = doc.getSection("tiling") orelse {
        std.log.info("[config] No [tiling] section found, using defaults", .{});
        return;
    };

    std.log.info("[config] ========== PARSING TILING CONFIG ==========", .{});

    // Parse layout (string)
    if (section.getString("layout")) |val| {
        config.tiling.layout = val;
        std.log.info("[config] ✓ layout = \"{s}\"", .{val});
    } else {
        std.log.info("[config] ○ layout not specified, using default", .{});
    }

    // Parse enabled (bool)
    if (section.getBool("enabled")) |val| {
        config.tiling.enabled = val;
        std.log.info("[config] ✓ enabled = {}", .{val});
    } else {
        std.log.info("[config] ○ enabled not specified, using default", .{});
    }

    if (section.getInt("master_count")) |count| {
        if (count >= 1) {
            config.tiling.master_count = @intCast(count);
            std.log.info("[config] ✓ master_count = {}", .{count});
        } else {
            std.log.warn("[config] ✗ master_count must be >= 1", .{});
        }
    }

    if (section.getInt("master_width_factor")) |factor| {
        if (factor >= 5 and factor <= 95) {
            config.tiling.master_width_factor = @as(f32, @floatFromInt(factor)) / 100.0;
            std.log.info("[config] ✓ master_width_factor = {}%", .{factor});
        } else {
            std.log.warn("[config] ✗ master_width_factor out of range (5-95)", .{});
        }
    }

    if (section.getInt("gaps")) |gaps| {
        config.tiling.gaps = @intCast(@min(gaps, 200));
        std.log.info("[config] ✓ gaps = {}px", .{config.tiling.gaps});
    }

    if (section.getInt("border_width")) |width| {
        config.tiling.border_width = @intCast(@min(width, 100));
        std.log.info("[config] ✓ border_width = {}px", .{config.tiling.border_width});
    }

    if (section.getColor("border_focused")) |color| {
        if (color <= 0xFFFFFF) {
            config.tiling.border_focused = color;
            std.log.info("[config] ✓ border_focused = 0x{x:0>6}", .{color});
        } else {
            std.log.warn("[config] ✗ border_focused exceeds RGB range (got 0x{x}), using default", .{color});
        }
    }

    if (section.getColor("border_normal")) |color| {
        if (color <= 0xFFFFFF) {
            config.tiling.border_normal = color;
            std.log.info("[config] ✓ border_normal = 0x{x:0>6}", .{color});
        } else {
            std.log.warn("[config] ✗ border_normal exceeds RGB range (got 0x{x}), using default", .{color});
        }
    }

    std.log.info("[config] ===============================================", .{});
}

fn parseWorkspaces(doc: *const parser.Document, config: *Config) !void {
    const section = doc.getSection("workspaces") orelse return;

    std.log.info("[config] ========== PARSING WORKSPACE CONFIG ==========", .{});

    if (section.getInt("count")) |count| {
        if (count >= 1 and count <= 20) {
            config.workspaces.count = @intCast(count);
            std.log.info("[config] ✓ workspace count = {}", .{count});
        } else {
            std.log.warn("[config] ✗ workspace count out of range (1-20)", .{});
        }
    }

    std.log.info("[config] ==================================================", .{});
}

fn parseRules(allocator: std.mem.Allocator, doc: *const parser.Document, config: *Config) !void {
    std.log.info("[config] ========== PARSING WORKSPACE RULES ==========", .{});

    var rules_found: usize = 0;

    // Support both old format [rules] and new format [rules.N]

    // First, check for old-style [rules] section
    if (doc.getSection("rules")) |section| {
        var iter = section.pairs.iterator();
        while (iter.next()) |entry| {
            const class_name = entry.key_ptr.*;
            const workspace_num = entry.value_ptr.*.asInt() orelse {
                std.log.warn("[config] Rule for '{s}' must have integer workspace number", .{class_name});
                continue;
            };

            if (workspace_num < 1 or workspace_num > 20) {
                std.log.warn("[config] Workspace number for '{s}' out of range (1-20): {}", .{class_name, workspace_num});
                continue;
            }

            const class_name_copy = try allocator.dupe(u8, class_name);
            errdefer allocator.free(class_name_copy);

            const rule = defs.Rule{
                .class_name = class_name_copy,
                .workspace = @intCast(workspace_num - 1),
            };

            try config.workspaces.rules.append(allocator, rule);
            std.log.info("[config] ✓ Rule: '{s}' → workspace {}", .{class_name, workspace_num});
            rules_found += 1;
        }
    }

    // Then check for new-style [rules.1], [rules.2], [workspace.rules.1], etc.
    var section_iter = doc.sections.iterator();
    while (section_iter.next()) |section_entry| {
        const section_name = section_entry.key_ptr.*;

        // Determine if this is a rules section and extract workspace number
        var workspace_str: ?[]const u8 = null;
        
        // Support both [rules.N] and [workspace.rules.N]
        if (std.mem.startsWith(u8, section_name, "workspace.rules.")) {
            workspace_str = section_name[16..]; // Skip "workspace.rules."
        } else if (std.mem.startsWith(u8, section_name, "rules.")) {
            workspace_str = section_name[6..]; // Skip "rules."
        }

        if (workspace_str) |ws_str| {
            const workspace_num = std.fmt.parseInt(usize, ws_str, 10) catch {
                std.log.warn("[config] Invalid workspace number in section [{s}]", .{section_name});
                continue;
            };

            if (workspace_num < 1 or workspace_num > 20) {
                std.log.warn("[config] Workspace number out of range (1-20) in section [{s}]", .{section_name});
                continue;
            }

            const section = section_entry.value_ptr;

            // Each key in this section is a window class for this workspace
            // The value can be anything (we ignore it) or just be present as a marker
            var iter = section.pairs.iterator();
            while (iter.next()) |entry| {
                const class_name = entry.key_ptr.*;

                const class_name_copy = try allocator.dupe(u8, class_name);
                errdefer allocator.free(class_name_copy);

                const rule = defs.Rule{
                    .class_name = class_name_copy,
                    .workspace = workspace_num - 1, // Convert to 0-indexed
                };

                try config.workspaces.rules.append(allocator, rule);
                std.log.info("[config] ✓ Rule: '{s}' → workspace {} (from [{s}])",
                    .{class_name, workspace_num, section_name});
                rules_found += 1;
            }
        }
    }

    std.log.info("[config] Loaded {} workspace rules", .{rules_found});
    std.log.info("[config] ==================================================", .{});
}

fn parseKeybindString(str: []const u8) !struct { modifiers: u16, keysym: u32 } {
    var modifiers: u16 = 0;
    var keysym: ?u32 = null;

    var parts = std.mem.splitScalar(u8, str, '+');
    while (parts.next()) |part| {
        const trimmed = std.mem.trim(u8, part, " \t");

        if (MODIFIER_MAP.get(trimmed)) |mod| {
            modifiers |= mod;
        } else {
            if (keysym != null) return error.MultipleKeysInBinding;
            keysym = try keyNameToKeysym(trimmed);
        }
    }

    return .{ .modifiers = modifiers, .keysym = keysym orelse return error.NoKeysymFound };
}

fn keyNameToKeysym(name: []const u8) !u32 {
    if (name.len >= 64) return error.KeyNameTooLong;

    var buf: [64]u8 = undefined;
    @memcpy(buf[0..name.len], name);
    buf[name.len] = 0;

    const keysym = xkb.xkb_keysym_from_name(@ptrCast(&buf), xkb.XKB_KEYSYM_CASE_INSENSITIVE);
    if (keysym == xkb.XKB_KEY_NoSymbol) {
        std.log.warn("Unknown key name: {s}", .{name});
        return error.UnknownKeyName;
    }

    return keysym;
}

pub fn resolveKeybindings(keybindings: anytype, xkb_state: *xkb.XkbState) void {
    for (keybindings) |*keybind| {
        keybind.keycode = xkb_state.keysymToKeycode(keybind.keysym);
        if (keybind.keycode == null) {
            std.log.warn("Could not find keycode for keysym 0x{x}", .{keybind.keysym});
        }
    }
}

pub fn validateConfig(allocator: std.mem.Allocator, config: *const Config) !void {
    if (config.keybindings.items.len < 2) return;

    var sorted = try allocator.dupe(defs.Keybind, config.keybindings.items);
    defer allocator.free(sorted);

    std.mem.sort(defs.Keybind, sorted, {}, struct {
        fn lessThan(_: void, a: defs.Keybind, b: defs.Keybind) bool {
            return if (a.modifiers != b.modifiers) a.modifiers < b.modifiers else a.keysym < b.keysym;
        }
    }.lessThan);

    for (sorted[0 .. sorted.len - 1], sorted[1..]) |a, b| {
        if (a.modifiers == b.modifiers and a.keysym == b.keysym) {
            std.log.err("Duplicate keybinding: mod={x} keysym={d}", .{ a.modifiers, a.keysym });
            return ValidationError.DuplicateKeybinding;
        }
    }
}

fn getDefaultConfig() Config {
    return Config{ .keybindings = .{} };
}

pub fn deinit(self: *Config, allocator: std.mem.Allocator) void {
    for (self.keybindings.items) |*kb| {
        kb.action.deinit(allocator);
    }
    self.keybindings.deinit(allocator);
}
