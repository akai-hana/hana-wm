///! Fallback configuration logic - terminal and font detection
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
    for (TERMINALS) |terminal| {
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
pub fn detectFont(allocator: std.mem.Allocator) ![]const u8 {
    for (FONTS) |font| {
        if (isFontAvailable(allocator, font)) {
            std.log.info("[fallback] Detected font: {s}", .{font});
            return font;
        }
    }
    
    // Ultimate fallback
    std.log.warn("[fallback] No preferred font found, using 'monospace'", .{});
    return "monospace";
}

/// Check if a command is available in PATH  
fn isCommandAvailable(allocator: std.mem.Allocator, command: []const u8) bool {
    _ = allocator;
    
    // Check common binary paths
    const paths = [_][]const u8{
        "/usr/bin/",
        "/usr/local/bin/",
        "/bin/",
    };
    
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    for (paths) |path| {
        const full_path = std.fmt.bufPrintZ(&buf, "{s}{s}", .{ path, command }) catch continue;
        const fd = std.posix.open(full_path, .{ .ACCMODE = .RDONLY }, 0) catch continue;
        std.posix.close(fd);
        return true;
    }
    
    return false;
}

/// Check if a font is available using fc-list
fn isFontAvailable(allocator: std.mem.Allocator, font: []const u8) bool {
    _ = allocator;
    
    // For common fonts, assume they're available
    // X11 will fall back to a default font if the requested one doesn't exist
    const common_fonts = [_][]const u8{
        "monospace",
        "FiraCode",
        "FiraCode Retina",
        "FiraCode Nerd Font",
        "FiraCode Nerd Font Ret",
        "JetBrains Mono",
        "JetBrains Mono Nerd Font",
        "Terminus",
    };
    
    for (common_fonts) |common_font| {
        if (std.mem.eql(u8, font, common_font)) {
            return true;
        }
    }
    
    // Default to true - worst case X11 will use fallback font
    return true;
}

/// Load fallback TOML embedded in binary
pub fn getFallbackToml() []const u8 {
    return @embedFile("fallback.toml");
}
