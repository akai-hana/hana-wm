// Configuration parser for Hana window manager
// Reads TOML config files and converts them into our internal Config struct

// INITIALIZATION

// Imports
const std  = @import("std");
const defs = @import("defs");
const toml = @import("toml");
const xkb  = @import("xkbcommon");

const Config = defs.Config;

/// Config validation error handling
pub const ValidationError = error{ // TODO: move to error.zig
    InvalidKeybinding,   // Keybinding string couldn't be parsed
    DuplicateKeybinding, // Same key combo defined twice
    XkbInitFailed,       // Failed to initialize xkbcommon
};

// MAPPING

/// Modkey name to bitflag values mapping
const MODIFIER_MAP = std.StaticStringMap(u16).initComptime(.{
    // Super
    .{ "Mod4", defs.MOD_SUPER },
    .{ "Super", defs.MOD_SUPER },
    // Alt
    .{ "Mod1", defs.MOD_ALT },
    .{ "Alt", defs.MOD_ALT },
    // Ctrl
    .{ "Ctrl", defs.MOD_CONTROL },
    .{ "Control", defs.MOD_CONTROL }, 
    // Shift
    .{ "Shift", defs.MOD_SHIFT },
});

/// Get XDG-compliant config file path
/// Checks XDG_CONFIG_HOME, falls back to ~/.config/hana/config.toml
/// Caller must free the returned string
pub fn getConfigPath(allocator: std.mem.Allocator) ![]const u8 {
    // Get home directory from environment (use current dir as fallback)
    const home = std.posix.getenv("HOME") orelse "."; // TODO: inform user when using fallback
    
    // Check if user has custom XDG_CONFIG_HOME, otherwise use ~/.config
    const config_home = std.posix.getenv("XDG_CONFIG_HOME") orelse
        try std.fmt.allocPrint(allocator, "{s}/.config", .{home});
    
    // Free the allocated string if we created it (not if it came from environment)
    defer if (std.posix.getenv("XDG_CONFIG_HOME") == null) allocator.free(config_home);
    
    // Build full path: $XDG_CONFIG_HOME/hana/config.toml
    return try std.fs.path.join(allocator, &.{config_home, "hana", "config.toml"});
}

/// Load configuration from the default XDG path
/// Convenience wrapper around loadConfig() that finds the config file automatically
pub fn loadConfigDefault(allocator: std.mem.Allocator) !Config {
    const path = try getConfigPath(allocator);
    defer allocator.free(path);
    return loadConfig(allocator, path);
}

/// Load configuration from a specific TOML file
/// Falls back to defaults if file doesn't exist
/// Missing sections/keys use defaults, but invalid values log warnings
pub fn loadConfig(allocator: std.mem.Allocator, path: []const u8) !Config {
    // Inline the file reading
    var threaded: std.Io.Threaded = .init_single_threaded;
    defer threaded.deinit();
    const max_size = 10 * 1024 * 1024;
    
    const content = std.Io.Dir.cwd().readFileAlloc(threaded.io(), path, allocator, @enumFromInt(max_size)) catch |err| switch (err) {
        error.FileNotFound => {
            std.log.info("Config file not found, using defaults", .{});
            return getDefaultConfig();
        },
        else => return err,
    };
    defer allocator.free(content);

    // Parse TOML syntax for any syntax errors
    var doc = try toml.parse(allocator, content);
    defer doc.deinit(); // Clean up the parsed document

    // Start with default config, then override with values from file
    // TODO: Invert this process; start with values from file and override only those that failed to be set with the values of the default config
    var config = getDefaultConfig();
    
    // Parse keybindings section
    try parseKeybindings(allocator, &doc, &config);
    
    // Validate that all values are reasonable
    try validateConfig(allocator, &config);
    
    return config;
}

/// Parse the [Keybindings] section
/// Converts strings like "Mod4+Return = alacritty" into executable keybindings
fn parseKeybindings(allocator: std.mem.Allocator, doc: *const toml.Document, config: *Config) !void {
    // If there's no [Keybindings] section, no keybindings will be set
    const exec_section = doc.getSection("Keybindings") orelse return;

    // Pre-allocate keybinrevent Arraylist from reallocating as it grows
    try config.keybindings.ensureTotalCapacity(allocator, exec_section.pairs.count());
    
    // Iterate through all key = value pairs in the section
    var iter = exec_section.pairs.iterator();
    while (iter.next()) |entry| {
        const binding_str = entry.key_ptr.*; // e.g., "Mod4+Return"
        
        // Value must be a string (the command to execute)
        const command = entry.value_ptr.*.asString() orelse {
            std.log.warn("Keybinding value must be a string: {s}", .{binding_str});
            continue;
        };
        
        // Parse the keybinding string into modifiers and keysym
        const keybind_parts = parseKeybindString(binding_str) catch |err| {
            std.log.warn("Invalid keybinding '{s}': {}", .{binding_str, err});
            continue;
        };
        
        // Create the keybind struct
        const keybind = defs.Keybind{
            .modifiers = keybind_parts.modifiers,
            .keysym = keybind_parts.keysym,  // Now using keysym instead of keycode
            .action = .{ .exec = try allocator.dupe(u8, command) }, // Copy command string
        };
        
        // Add to config's keybinding list
        try config.keybindings.append(allocator, keybind);
    }
}

/// Parse a keybinding string like "Mod4+Shift+Return" into parts
/// Returns the modifier flags and the keysym
fn parseKeybindString(str: []const u8) !struct { modifiers: u16, keysym: u32 } {
    var modifiers: u16 = 0;      // Bitfield of modifier flags
    var keysym: ?u32 = null;     // The actual key (only one allowed)
    
    // Split by '+' character (e.g., "Mod4+Shift+Return" -> ["Mod4", "Shift", "Return"])
    var parts = std.mem.splitScalar(u8, str, '+');
    while (parts.next()) |part| {
        const trimmed = std.mem.trim(u8, part, " \t");
        
        // Check if this part is a modifier key
        if (MODIFIER_MAP.get(trimmed)) |mod| {
            modifiers |= mod; // Set the corresponding bit flag
        } else {
            // This is the actual key being pressed
            // Only one key is allowed per binding
            if (keysym != null) {
                return error.MultipleKeysInBinding;
            }
            keysym = try keyNameToKeysym(trimmed);
        }
    }
    
    return .{ 
        .modifiers = modifiers, 
        .keysym = keysym orelse return error.NoKeysymFound,
    };
}

/// Convert key name (like "Return", "a", "F1") to xkb keysym using xkbcommon
/// This properly handles all key names that xkbcommon supports
fn keyNameToKeysym(name: []const u8) !u32 {
    // xkb_keysym_from_name expects a null-terminated string
    // We need to create a temporary buffer for this
    var buf: [64]u8 = undefined;
    if (name.len >= buf.len) return error.KeyNameTooLong;
    
    @memcpy(buf[0..name.len], name);
    buf[name.len] = 0;  // Null terminate
    
    // Convert to keysym using xkbcommon
    // XKB_KEYSYM_CASE_INSENSITIVE flag allows "return", "Return", "RETURN"
    const keysym = xkb.xkb_keysym_from_name(
        @as([*:0]const u8, @ptrCast(&buf)),
        xkb.XKB_KEYSYM_CASE_INSENSITIVE
    );
    
    // XKB_KEY_NoSymbol (0) means the key name wasn't recognized
    if (keysym == xkb.XKB_KEY_NoSymbol) {
        std.log.warn("Unknown key name: {s}", .{name});
        return error.UnknownKeyName;
    }
    
    return keysym;
}

/// Validate the entire configuration for consistency and safety
/// Uses sorting for better cache locality than HashMap (faster for small configs)
pub fn validateConfig(allocator: std.mem.Allocator, config: *const Config) !void {
    // Nothing to validate if we have 0 or 1 keybindings
    if (config.keybindings.items.len < 2) return;
    
    // Sort keybindings by (modifiers, keysym) for O(n log n) duplicate detection
    // This is faster than HashMap for small configs due to better cache locality
    const Context = struct {
        pub fn lessThan(_: @This(), a: defs.Keybind, b: defs.Keybind) bool {
            if (a.modifiers != b.modifiers) return a.modifiers < b.modifiers;
            return a.keysym < b.keysym;
        }
    };
    
    var sorted = try allocator.dupe(defs.Keybind, config.keybindings.items);
    defer allocator.free(sorted);
    
    std.mem.sort(defs.Keybind, sorted, Context{}, Context.lessThan);
    
    // Check for adjacent duplicates (O(n) after sort)
    for (sorted[0..sorted.len-1], sorted[1..]) |a, b| {
        if (a.modifiers == b.modifiers and a.keysym == b.keysym) {
            std.log.err("Duplicate keybinding found: mod={x} keysym={d}", .{a.modifiers, a.keysym});
            return ValidationError.DuplicateKeybinding;
        }
    }
}

/// Create a config with all default values
/// Used as base config before applying user overrides
fn getDefaultConfig() Config {
    return Config{
        .keybindings = .{}, // Empty list of keybindings
    };
}

/// Clean up configuration resources
/// Must be called when done with a Config to avoid memory leaks
pub fn deinit(self: *Config, allocator: std.mem.Allocator) void {
    // Free all command strings from keybindings
    for (self.keybindings.items) |*kb| {
        kb.action.deinit(allocator);
    }
    // Free the keybindings list itself
    self.keybindings.deinit(allocator);
}
