// Config parser - modernized and simplified

const std = @import("std");
const defs = @import("defs");
const toml = @import("toml");

const Config = defs.Config;

/// Default configuration values
const DEFAULTS = struct {
    const border_width: u12 = 4;
    const border_focused: u24 = 0x00ff00;
    const border_unfocused: u24 = 0xff0000;
    const gap_inner: u16 = 10;
    const gap_outer: u16 = 20;
};

/// Validation constraints
const LIMITS = struct {
    const max_border_width: u12 = 4095;
    const max_gap: u16 = 1000;
    const max_color: u24 = 0xFFFFFF;
};

/// Configuration validation errors
pub const ValidationError = error{
    BorderWidthZero,
    BorderWidthTooLarge,
    InvalidColorRange,
    GapTooLarge,
    InvalidKeybinding,
    DuplicateKeybinding,
};

/// Modifier key mappings
const MODIFIER_MAP = std.StaticStringMap(u16).initComptime(.{
    .{ "Mod4", defs.MOD_SUPER },
    .{ "Super", defs.MOD_SUPER },
    .{ "Mod1", defs.MOD_ALT },
    .{ "Alt", defs.MOD_ALT },
    .{ "Shift", defs.MOD_SHIFT },
    .{ "Control", defs.MOD_CONTROL },
    .{ "Ctrl", defs.MOD_CONTROL },
});

/// Get XDG-compliant config path
/// Caller owns returned memory
pub fn getConfigPath(allocator: std.mem.Allocator) ![]const u8 {
    const home = std.posix.getenv("HOME") orelse ".";
    const config_home = std.posix.getenv("XDG_CONFIG_HOME") orelse
        try std.fmt.allocPrint(allocator, "{s}/.config", .{home});
    defer if (std.posix.getenv("XDG_CONFIG_HOME") == null) allocator.free(config_home);
    
    return try std.fs.path.join(allocator, &.{config_home, "hana", "config.toml"});
}

/// Load configuration from XDG-compliant default path
pub fn loadConfigDefault(allocator: std.mem.Allocator) !Config {
    const path = try getConfigPath(allocator);
    defer allocator.free(path);
    return loadConfig(allocator, path);
}

/// Load configuration from TOML file, falling back to defaults if not found
/// Note: TOML parsing errors will propagate as errors, but missing sections/keys
/// will silently use defaults. Invalid values will log warnings and use defaults.
pub fn loadConfig(allocator: std.mem.Allocator, path: []const u8) !Config {
    const content = readConfigFile(allocator, path) catch |err| switch (err) {
        error.FileNotFound => {
            std.log.info("Config file not found, using defaults", .{});
            return getDefaultConfig();
        },
        else => return err,
    };
    defer allocator.free(content);

    // Parse TOML document - syntax errors will return an error
    var doc = try toml.parse(allocator, content);
    defer doc.deinit();

    // Build config from TOML with defaults
    var config = getDefaultConfig();
    
    try parseAppearance(&doc, &config);
    try parseGaps(&doc, &config);
    try parseKeybindings(allocator, &doc, &config);
    
    try validateConfig(allocator, &config);
    
    return config;
}

/// Read config file into string
fn readConfigFile(allocator: std.mem.Allocator, path: []const u8) ![]const u8 {
    // Create a single-threaded IO instance for file operations
    var threaded: std.Io.Threaded = .init_single_threaded;
    defer threaded.deinit();
    const io = threaded.io();
    
    // Use readFileAlloc with 10MB limit for safety
    const max_size = 10 * 1024 * 1024; // 10MB
    return try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, @enumFromInt(max_size));
}

/// Parse [appearance] section
fn parseAppearance(doc: *const toml.Document, config: *Config) !void {
    const appearance = doc.getSection("appearance") orelse return;
    
    if (appearance.getInt("border_width")) |width| {
        if (width >= 0 and width <= LIMITS.max_border_width) {
            config.border_width = @intCast(width);
        } else {
            std.log.warn("border_width out of range (0-{d}), using default", .{LIMITS.max_border_width});
        }
    }
    
    // Try parsing as int first, then as string for hex colors
    if (appearance.getInt("border_focused")) |value| {
        if (value >= 0 and value <= LIMITS.max_color) {
            config.border_focused = @intCast(value);
        } else {
            std.log.warn("border_focused out of RGB range, using default", .{});
        }
    } else if (appearance.getString("border_focused")) |hex_str| {
        if (parseHexColor(hex_str)) |color| {
            config.border_focused = color;
        } else |_| {
            std.log.warn("Invalid border_focused hex color '{s}', using default", .{hex_str});
        }
    }
    
    if (appearance.getInt("border_unfocused")) |value| {
        if (value >= 0 and value <= LIMITS.max_color) {
            config.border_unfocused = @intCast(value);
        } else {
            std.log.warn("border_unfocused out of RGB range, using default", .{});
        }
    } else if (appearance.getString("border_unfocused")) |hex_str| {
        if (parseHexColor(hex_str)) |color| {
            config.border_unfocused = color;
        } else |_| {
            std.log.warn("Invalid border_unfocused hex color '{s}', using default", .{hex_str});
        }
    }
}

/// Parse hex color string like "#00ff00" or "00ff00"
fn parseHexColor(str: []const u8) !u24 {
    const trimmed = std.mem.trim(u8, str, " \t");
    const hex_str = if (std.mem.startsWith(u8, trimmed, "#"))
        trimmed[1..]
    else
        trimmed;
    
    if (hex_str.len != 6) return error.InvalidHexLength;
    
    return std.fmt.parseInt(u24, hex_str, 16) catch return error.InvalidHexFormat;
}

/// Parse [gaps] section
fn parseGaps(doc: *const toml.Document, config: *Config) !void {
    const gaps = doc.getSection("gaps") orelse return;
    
    if (gaps.getInt("inner")) |inner| {
        if (inner >= 0 and inner <= LIMITS.max_gap) {
            config.gap_inner = @intCast(inner);
        } else {
            std.log.warn("gap_inner out of range (0-{d}), using default", .{LIMITS.max_gap});
        }
    }
    
    if (gaps.getInt("outer")) |outer| {
        if (outer >= 0 and outer <= LIMITS.max_gap) {
            config.gap_outer = @intCast(outer);
        } else {
            std.log.warn("gap_outer out of range (0-{d}), using default", .{LIMITS.max_gap});
        }
    }
}

/// Parse [keybindings.exec] section
fn parseKeybindings(allocator: std.mem.Allocator, doc: *const toml.Document, config: *Config) !void {
    const exec_section = doc.getSection("keybindings.exec") orelse return;
    
    var iter = exec_section.pairs.iterator();
    while (iter.next()) |entry| {
        const binding_str = entry.key_ptr.*;
        const command = entry.value_ptr.*.asString() orelse {
            std.log.warn("Keybinding value must be a string: {s}", .{binding_str});
            continue;
        };
        
        const keybind_parts = parseKeybindString(binding_str) catch |err| {
            std.log.warn("Invalid keybinding '{s}': {}", .{binding_str, err});
            continue;
        };
        
        const keybind = defs.Keybind{
            .modifiers = keybind_parts.modifiers,
            .keycode = keybind_parts.keycode,
            .action = .{ .exec = try allocator.dupe(u8, command) },
        };
        
        try config.keybindings.append(allocator, keybind);
    }
}

/// Parse keybinding string like "Mod4+Return" into modifiers and keycode
fn parseKeybindString(str: []const u8) !struct { modifiers: u16, keycode: u8 } {
    var modifiers: u16 = 0;
    var keycode: ?u8 = null;
    
    var parts = std.mem.splitScalar(u8, str, '+');
    while (parts.next()) |part| {
        const trimmed = std.mem.trim(u8, part, " \t");
        
        if (MODIFIER_MAP.get(trimmed)) |mod| {
            modifiers |= mod;
        } else {
            // This is the actual key
            if (keycode != null) {
                return error.MultipleKeysInBinding;
            }
            keycode = try keyNameToKeycode(trimmed);
        }
    }
    
    return .{ 
        .modifiers = modifiers, 
        .keycode = keycode orelse return error.NoKeycodeFound,
    };
}

/// Convert key name to X11 keycode
/// This is a simplified mapping - ideally would use xkbcommon or similar
fn keyNameToKeycode(name: []const u8) !u8 {
    // Allocate buffer for lowercase conversion (stack allocated for small strings)
    var buf: [32]u8 = undefined;
    if (name.len > buf.len) return error.KeyNameTooLong;
    
    const lower = std.ascii.lowerString(&buf, name);
    
    // Common keys (X11 keycodes)
    const key_map = std.StaticStringMap(u8).initComptime(.{
        // Letters
        .{ "a", 38 }, .{ "b", 56 }, .{ "c", 54 }, .{ "d", 40 },
        .{ "e", 26 }, .{ "f", 41 }, .{ "g", 42 }, .{ "h", 43 },
        .{ "i", 31 }, .{ "j", 44 }, .{ "k", 45 }, .{ "l", 46 },
        .{ "m", 58 }, .{ "n", 57 }, .{ "o", 32 }, .{ "p", 33 },
        .{ "q", 24 }, .{ "r", 27 }, .{ "s", 39 }, .{ "t", 28 },
        .{ "u", 30 }, .{ "v", 55 }, .{ "w", 25 }, .{ "x", 53 },
        .{ "y", 29 }, .{ "z", 52 },
        
        // Numbers
        .{ "0", 19 }, .{ "1", 10 }, .{ "2", 11 }, .{ "3", 12 },
        .{ "4", 13 }, .{ "5", 14 }, .{ "6", 15 }, .{ "7", 16 },
        .{ "8", 17 }, .{ "9", 18 },
        
        // Special keys (with common variants)
        .{ "return", 36 }, .{ "enter", 36 },
        .{ "escape", 9 }, .{ "esc", 9 },
        .{ "tab", 23 },
        .{ "backspace", 22 },
        .{ "space", 65 },
        
        // Function keys
        .{ "f1", 67 }, .{ "f2", 68 }, .{ "f3", 69 }, .{ "f4", 70 },
        .{ "f5", 71 }, .{ "f6", 72 }, .{ "f7", 73 }, .{ "f8", 74 },
        .{ "f9", 75 }, .{ "f10", 76 }, .{ "f11", 95 }, .{ "f12", 96 },
        
        // Arrow keys
        .{ "left", 113 }, .{ "right", 114 },
        .{ "up", 111 }, .{ "down", 116 },
    });
    
    return key_map.get(lower) orelse return error.UnknownKeyName;
}

/// Validate configuration values
pub fn validateConfig(allocator: std.mem.Allocator, config: *const Config) !void {
    if (config.border_width == 0) {
        return ValidationError.BorderWidthZero;
    }
    if (config.border_width > LIMITS.max_border_width) {
        return ValidationError.BorderWidthTooLarge;
    }
    if (config.border_focused > LIMITS.max_color or 
        config.border_unfocused > LIMITS.max_color) {
        return ValidationError.InvalidColorRange;
    }
    if (config.gap_inner > LIMITS.max_gap or config.gap_outer > LIMITS.max_gap) {
        return ValidationError.GapTooLarge;
    }
    
    // Check for duplicate keybindings using HashMap
    // Define the type explicitly so it matches in both HashMap and the loop
    const Key = struct { modifiers: u16, keycode: u8 }; 
    var seen = std.AutoHashMap(Key, void).init(allocator);
    defer seen.deinit();

    for (config.keybindings.items) |kb| {
        // Use the explicit 'Key' type here
        const key = Key{ .modifiers = kb.modifiers, .keycode = kb.keycode };
        const gop = try seen.getOrPut(key);
        if (gop.found_existing) {
            std.log.err("Duplicate keybinding found: mod={x} key={d}", .{kb.modifiers, kb.keycode});
            return ValidationError.DuplicateKeybinding;
        }
    }
}

/// Return default configuration
fn getDefaultConfig() Config {
    return Config{
        .border_width = DEFAULTS.border_width,
        .border_focused = DEFAULTS.border_focused,
        .border_unfocused = DEFAULTS.border_unfocused,
        .gap_inner = DEFAULTS.gap_inner,
        .gap_outer = DEFAULTS.gap_outer,
        .keybindings = .{},
    };
}

/// Clean up configuration resources
pub fn deinit(self: *Config, allocator: std.mem.Allocator) void {
    for (self.keybindings.items) |kb| {
        if (kb.action == .exec) {
            allocator.free(kb.action.exec);
        }
    }
    self.keybindings.deinit(allocator);
}
