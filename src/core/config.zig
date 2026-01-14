// Configuration parser for Hana window manager

const std  = @import("std");

const defs = @import("defs");
const toml = @import("toml");
const xkb  = @import("xkbcommon");

const Config = defs.Config;

pub const ValidationError = error{
    InvalidKeybinding,
    DuplicateKeybinding,
    XkbInitFailed,
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
    const home = std.posix.getenv("HOME") orelse ".";
    const config_home = std.posix.getenv("XDG_CONFIG_HOME") orelse 
        try std.fmt.allocPrint(allocator, "{s}/.config", .{home});
    defer if (std.posix.getenv("XDG_CONFIG_HOME") == null) allocator.free(config_home);

    return std.fs.path.join(allocator, &.{config_home, "hana", "config.toml"});
}

pub fn loadConfigDefault(allocator: std.mem.Allocator) !Config {
    const path = try getConfigPath(allocator);
    defer allocator.free(path);
    return loadConfig(allocator, path);
}

pub fn loadConfig(allocator: std.mem.Allocator, path: []const u8) !Config {
    var threaded: std.Io.Threaded = .init_single_threaded;
    defer threaded.deinit();

    const content = std.Io.Dir.cwd().readFileAlloc(
        threaded.io(), path, allocator, @enumFromInt(10 * 1024 * 1024) // = 10MB config filesize security limit
    ) catch |err| return switch (err) {
        error.FileNotFound => blk: {
            std.log.info("Config file not found, using defaults", .{});
            break :blk getDefaultConfig();
        },
        else => err,
    };
    defer allocator.free(content);

    var doc = try toml.parse(allocator, content);
    defer doc.deinit();

    var config = getDefaultConfig();
    try parseKeybindings(allocator, &doc, &config);
    try validateConfig(allocator, &config);

    return config;
}

fn parseKeybindings(allocator: std.mem.Allocator, doc: *const toml.Document, config: *Config) !void {
    const section = doc.getSection("Keybindings") orelse return;
    try config.keybindings.ensureTotalCapacity(allocator, section.pairs.count());

    var iter = section.pairs.iterator();
    while (iter.next()) |entry| {
        const command = entry.value_ptr.*.asString() orelse {
            std.log.warn("Keybinding value must be a string: {s}", .{entry.key_ptr.*});
            continue;
        };

        const parts = parseKeybindString(entry.key_ptr.*) catch |err| {
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
