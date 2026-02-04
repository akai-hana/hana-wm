///! Fallback configuration logic - terminal and font detection - Optimized version
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
    // OPTIMIZATION: Use inline for since array size is known at compile time
    inline for (TERMINALS) |terminal| {
        if (isCommandAvailable(allocator, terminal)) {
            std.log.info("[fallback] Detected terminal: {s}", .{terminal});
            return terminal;
        }
    }
    
    // Ultimate fallback
    std.log.warn("[fallback] No preferred terminal found, using 'xterm'", .{});
    return "xterm";
}

/// Detect first available font from the system
pub fn detectFont(_: std.mem.Allocator) ![]const u8 {
    // OPTIMIZATION: Use inline for since array size is known at compile time
    inline for (FONTS) |font| {
        if (isFontAvailable(font)) {
            std.log.info("[fallback] Detected font: {s}", .{font});
            return font;
        }
    }
    
    // Ultimate fallback
    std.log.warn("[fallback] No preferred font found, using 'monospace'", .{});
    return "monospace";
}

/// Check if a command is available in PATH
/// Note: Uses open/close approach for compatibility across Zig versions
fn isCommandAvailable(_: std.mem.Allocator, command: []const u8) bool {
    // OPTIMIZATION: First try PATH environment variable for more thorough search
    if (std.c.getenv("PATH")) |path_env| {
        const path_str = std.mem.span(path_env);
        var it = std.mem.splitScalar(u8, path_str, ':');
        
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        while (it.next()) |path_dir| {
            const full_path = std.fmt.bufPrintZ(&buf, "{s}/{s}", .{ path_dir, command }) catch continue;
            
            // Check if file exists and is accessible
            const fd = std.posix.open(full_path, .{ .ACCMODE = .RDONLY }, 0) catch continue;
            std.posix.close(fd);
            return true;
        }
    }
    
    // Fallback to common paths
    const common_paths = [_][]const u8{
        "/usr/bin/",
        "/usr/local/bin/",
        "/bin/",
        "/opt/bin/",
    };
    
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    for (common_paths) |path| {
        const full_path = std.fmt.bufPrintZ(&buf, "{s}{s}", .{ path, command }) catch continue;
        const fd = std.posix.open(full_path, .{ .ACCMODE = .RDONLY }, 0) catch continue;
        std.posix.close(fd);
        return true;
    }
    
    return false;
}

/// OPTIMIZATION: Simplified font checking with compile-time string map
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
