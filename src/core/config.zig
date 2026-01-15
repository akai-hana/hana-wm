// Configuration parser for Hana window manager
const std = @import("std");
const defs = @import("defs");
const toml = @import("toml");
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

pub fn getConfigPath(allocator: std.mem.Allocator) ![]const u8 {
    // 1. Check for local config first (Development Mode)
    const cwd_path = try std.process.getCwdAlloc(allocator);
    defer allocator.free(cwd_path);
    
    const local_path = try std.fs.path.join(allocator, &.{ cwd_path, "config.toml" });
    
    // We use a null-terminated string for POSIX calls
    const local_path_z = try allocator.dupeZ(u8, local_path);
    defer allocator.free(local_path_z);
    
    // Try to open the file using raw POSIX to check existence
    const fd_local = std.posix.open(local_path_z, .{ .ACCMODE = .RDONLY }, 0) catch -1;
    if (fd_local != -1) {
        std.posix.close(@intCast(fd_local));
        return local_path; // Caller frees this
    }
    allocator.free(local_path);
    
    // 2. Fallback to System/XDG paths
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
    // Set up IO backend for file operations
    var threaded: std.Io.Threaded = .init_single_threaded;
    defer threaded.deinit();
    const io = threaded.io();
    
    // Open and read the config file
    const file = std.Io.Dir.openFileAbsolute(io, path, .{}) catch |err| {
        if (err == error.FileNotFound) {
            std.log.info("Config file not found at '{s}', using defaults", .{path});
            return getDefaultConfig();
        }
        return err;
    };
    defer file.close(io);
    
    // Read the content using a reader
    var read_buf: [4096]u8 = undefined;
    var file_reader = file.reader(io, &read_buf);
    var buffer = std.Io.Writer.Allocating.init(allocator);
    defer buffer.deinit();
    _ = try file_reader.interface.streamRemaining(&buffer.writer);
    const content = try allocator.dupe(u8, buffer.written());
    defer allocator.free(content);
    
    // Parse TOML
    var doc = try toml.parse(allocator, content);
    defer doc.deinit();
    
    var config = getDefaultConfig();
    try parseKeybindings(allocator, &doc, &config);
    try parseTiling(&doc, &config);
    try validateConfig(allocator, &config);
    
    std.log.info("Successfully loaded config from: {s}", .{path});
    return config;
}

pub fn loadConfigDefault(allocator: std.mem.Allocator) !Config {
    const path = try getConfigPath(allocator);
    defer allocator.free(path);
    return loadConfig(allocator, path);
}

fn parseKeybindings(allocator: std.mem.Allocator, doc: *const toml.Document, config: *Config) !void {
    const section = doc.getSection("Keybindings") orelse return;
    try config.keybindings.ensureTotalCapacity(allocator, section.pairs.count());
    
    // First pass: look for "Mod" variable definition
    var mod_substitute: ?[]const u8 = null;
    if (section.getString("Mod")) |mod_value| {
        mod_substitute = mod_value;
        std.log.info("Found Mod variable: {s}", .{mod_value});
    }
    
    var iter = section.pairs.iterator();
    while (iter.next()) |entry| {
        // Skip the "Mod" variable definition itself
        if (std.mem.eql(u8, entry.key_ptr.*, "Mod")) continue;
        
        const command = entry.value_ptr.*.asString() orelse {
            std.log.warn("Keybinding value must be a string: {s}", .{entry.key_ptr.*});
            continue;
        };
        
        // Substitute "Mod" with its value before parsing
        const keybind_str = if (mod_substitute) |mod_val|
            try substituteModVariable(allocator, entry.key_ptr.*, mod_val)
        else
            entry.key_ptr.*;
        defer if (mod_substitute != null) allocator.free(keybind_str);
        
        const parts = parseKeybindString(keybind_str) catch |err| {
            std.log.warn("Invalid keybinding '{s}': {}", .{entry.key_ptr.*, err});
            continue;
        };
        
        try config.keybindings.append(allocator, .{
            .modifiers = parts.modifiers,
            .keysym = parts.keysym,
            .action = .{ .exec = try allocator.dupe(u8, command) },
        });
    }
}

fn substituteModVariable(allocator: std.mem.Allocator, keybind: []const u8, mod_value: []const u8) ![]const u8 {
    // Replace "Mod+" with the actual modifier value
    if (std.mem.startsWith(u8, keybind, "Mod+")) {
        return try std.fmt.allocPrint(allocator, "{s}+{s}", .{mod_value, keybind[4..]});
    }
    return try allocator.dupe(u8, keybind);
}

fn parseTiling(doc: *const toml.Document, config: *Config) !void {
    const section = doc.getSection("tiling") orelse {
        std.log.warn("[config] No [tiling] section found", .{});
        return;
    };
    
    if (section.getString("layout")) |layout| {
        config.tiling.layout = layout;
        std.log.info("[config] Loaded layout: {s}", .{layout});
    }
    
    if (section.getInt("enabled")) |enabled| {
        config.tiling.enabled = enabled != 0;
        std.log.info("[config] Loaded enabled: {}", .{enabled != 0});
    }
    
    if (section.getInt("master_count")) |count| {
        if (count < 1) {
            std.log.warn("[config] master_count must be at least 1, using default", .{});
        } else {
            config.tiling.master_count = @intCast(count);
            std.log.info("[config] Loaded master_count: {}", .{count});
        }
    }
    
    if (section.getInt("master_width_factor")) |factor| {
        if (factor < 5 or factor > 95) {
            std.log.warn("[config] master_width_factor {} out of range (5-95), using default", .{factor});
        } else {
            config.tiling.master_width_factor = @as(f32, @floatFromInt(factor)) / 100.0;
            std.log.info("[config] Loaded master_width_factor: {} ({}%)", .{config.tiling.master_width_factor, factor});
        }
    }
    
    if (section.getInt("gaps")) |gaps| {
        if (gaps > 200) {
            std.log.warn("[config] gaps={} seems excessive, capping at 200", .{gaps});
            config.tiling.gaps = 200;
        } else {
            config.tiling.gaps = @intCast(gaps);
            std.log.info("[config] Loaded gaps: {}", .{gaps});
        }
    }
    
    if (section.getInt("border_width")) |width| {
        if (width > 100) {
            std.log.warn("[config] border_width={} seems excessive, capping at 100", .{width});
            config.tiling.border_width = 100;
        } else {
            config.tiling.border_width = @intCast(width);
            std.log.info("[config] Loaded border_width: {}", .{width});
        }
    }
    
    if (section.getColor("border_focused")) |color| {
        if (color > 0xFFFFFF) {
            std.log.warn("[config] border_focused 0x{x} exceeds 24-bit RGB range", .{color});
        }
        config.tiling.border_focused = color;
        std.log.info("[config] Loaded border_focused: 0x{x}", .{color});
    }
    
    if (section.getColor("border_normal")) |color| {
        if (color > 0xFFFFFF) {
            std.log.warn("[config] border_normal 0x{x} exceeds 24-bit RGB range", .{color});
        }
        config.tiling.border_normal = color;
        std.log.info("[config] Loaded border_normal: 0x{x}", .{color});
    }
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
            if (keysym != null) {
                std.log.err("Multiple keys in binding: '{s}' (found '{s}' after already having a key)", .{str, trimmed});
                return error.MultipleKeysInBinding;
            }
            keysym = try keyNameToKeysym(trimmed);
        }
    }
    
    if (keysym == null) {
        std.log.err("No key found in binding: '{s}'", .{str});
        return error.NoKeysymFound;
    }
    
    return .{ .modifiers = modifiers, .keysym = keysym.? };
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

/// Convert keysyms to keycodes using XKB state
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
    
    // Check adjacent duplicates after sort
    for (sorted[0..sorted.len-1], sorted[1..]) |a, b| {
        if (a.modifiers == b.modifiers and a.keysym == b.keysym) {
            std.log.err("Duplicate keybinding: mod={x} keysym={d}", .{a.modifiers, a.keysym});
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
