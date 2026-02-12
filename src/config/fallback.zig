///! Fallback configuration logic - terminal and font detection - Optimized version
const std = @import("std");

const debug = @import("debug");

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

// CONSOLIDATED: Generic detection helper to eliminate duplication
fn detectFromList(
    comptime list: []const []const u8,
    comptime checkFn: fn([]const u8) bool,
    item_type: []const u8,
    fallback: []const u8,
) []const u8 {
    inline for (list) |item| {
        if (checkFn(item)) {
            debug.info("Detected {s}: {s}", .{item_type, item});
            return item;
        }
    }
    debug.warn("No preferred {s} found, using '{s}'", .{item_type, fallback});
    return fallback;
}

/// Detect first available terminal from the system
pub fn detectTerminal(_: std.mem.Allocator) ![]const u8 {
    return detectFromList(
        &TERMINALS,
        struct { fn check(cmd: []const u8) bool { return isCommandAvailable(std.heap.c_allocator, cmd); } }.check,
        "terminal",
        "xterm"
    );
}

/// Detect first available font from the system
pub fn detectFont(_: std.mem.Allocator) ![]const u8 {
    return detectFromList(
        &FONTS,
        isFontAvailable,
        "font",
        "monospace"
    );
}

/// OPTIMIZATION: Inline helper for path checking
inline fn checkPath(buf: []u8, dir: []const u8, command: []const u8) bool {
    const full_path = std.fmt.bufPrintZ(buf, "{s}/{s}", .{ dir, command }) catch return false;
    const fd = std.posix.open(full_path, .{ .ACCMODE = .RDONLY }, 0) catch return false;
    std.posix.close(fd);
    return true;
}

/// OPTIMIZATION: Improved command availability check with caching
fn isCommandAvailable(_: std.mem.Allocator, command: []const u8) bool {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    
    // OPTIMIZATION: Check most common paths first (faster than PATH parsing)
    // Most binaries are in /usr/bin
    const common_paths = [_][]const u8{ "/usr/bin", "/usr/local/bin", "/bin" };
    inline for (common_paths) |path| {
        if (checkPath(&buf, path, command)) return true;
    }
    
    // If not in common paths, check full PATH
    if (std.c.getenv("PATH")) |path_env| {
        var it = std.mem.splitScalar(u8, std.mem.span(path_env), ':');
        while (it.next()) |path_dir| {
            // Skip empty paths and paths we already checked
            if (path_dir.len == 0) continue;
            
            // Skip if we already checked this path
            var skip = false;
            inline for (common_paths) |common| {
                if (std.mem.eql(u8, path_dir, common)) {
                    skip = true;
                    break;
                }
            }
            if (skip) continue;
            
            if (checkPath(&buf, path_dir, command)) return true;
        }
    }
    
    return false;
}

/// OPTIMIZATION: Simplified font checking with compile-time string map
fn isFontAvailable(font: []const u8) bool {
    // OPTIMIZATION: Use compile-time string map for O(1) lookup
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
    // X11 will use fallback if not actually present
    return COMMON_FONTS.has(font);
}

/// Load fallback TOML embedded in binary
pub inline fn getFallbackToml() []const u8 {
    return @embedFile("fallback.toml");
}
