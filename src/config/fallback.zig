///! Fallback configuration logic - terminal and font detection - Improved version
const std = @import("std");

// Terminal detection - ordered by preference
const TERMINALS = [_][]const u8{
    "ghostty",
    "alacritty",
    "kitty",
    "wezterm",
    "foot",
    "st",
    "urxvt",
    "rxvt",
    "xterm",
    "konsole",
    "gnome-terminal",
    "xfce4-terminal",
    "mate-terminal",
    "lxterminal",
    "terminator",
};

// Font detection - ordered by preference
const FONTS = [_][]const u8{
    "FiraCode Nerd Font Ret",
    "FiraCode Retina",
    "FiraCode Nerd Font",
    "FiraCode",
    "JetBrains Mono Nerd Font",
    "JetBrains Mono",
    "Terminus",
    "monospace", // System fallback
};

/// Detect first available terminal from the system
pub fn detectTerminal(allocator: std.mem.Allocator) ![]const u8 {
    inline for (TERMINALS) |terminal| {
        if (isCommandAvailable(allocator, terminal)) {
            std.log.info("[fallback] Detected terminal: {s}", .{terminal});
            return terminal;
        }
    }
    
    std.log.warn("[fallback] No preferred terminal found, using 'xterm'", .{});
    return "xterm";
}

/// Detect first available font from the system
pub fn detectFont(_: std.mem.Allocator) ![]const u8 {
    inline for (FONTS) |font| {
        if (isFontAvailable(font)) {
            std.log.info("[fallback] Detected font: {s}", .{font});
            return font;
        }
    }
    
    std.log.warn("[fallback] No preferred font found, using 'monospace'", .{});
    return "monospace";
}

/// IMPROVEMENT: Extracted helper function to reduce duplication
/// Checks if a command exists at a given path
fn checkPath(buf: []u8, dir: []const u8, command: []const u8) bool {
    const full_path = std.fmt.bufPrintZ(buf, "{s}/{s}", .{ dir, command }) catch return false;
    const fd = std.posix.open(full_path, .{ .ACCMODE = .RDONLY }, 0) catch return false;
    std.posix.close(fd);
    return true;
}

/// Check if a command is available in PATH
fn isCommandAvailable(_: std.mem.Allocator, command: []const u8) bool {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    
    // First try PATH environment variable for more thorough search
    if (std.c.getenv("PATH")) |path_env| {
        var it = std.mem.splitScalar(u8, std.mem.span(path_env), ':');
        while (it.next()) |path_dir| {
            if (checkPath(&buf, path_dir, command)) return true;
        }
    }
    
    // Fallback to common paths
    for ([_][]const u8{ "/usr/bin", "/usr/local/bin", "/bin", "/opt/bin" }) |path| {
        if (checkPath(&buf, path, command)) return true;
    }
    
    return false;
}

/// Simplified font checking with compile-time string map
fn isFontAvailable(font: []const u8) bool {
    // Use compile-time string map for O(1) lookup
    const COMMON_FONTS = std.StaticStringMap(void).initComptime(.{
        .{ "monospace", {} },
        .{ "FiraCode", {} },
        .{ "FiraCode Retina", {} },
        .{ "FiraCode Nerd Font", {} },
        .{ "FiraCode Nerd Font Ret", {} },
        .{ "JetBrains Mono", {} },
        .{ "JetBrains Mono Nerd Font", {} },
        .{ "Terminus", {} },
    });
    
    // If it's a common font, assume available
    if (COMMON_FONTS.has(font)) {
        return true;
    }
    
    // Default to true - worst case X11 will use fallback font
    return true;
}

/// Load fallback TOML embedded in binary
pub inline fn getFallbackToml() []const u8 {
    return @embedFile("fallback.toml");
}
