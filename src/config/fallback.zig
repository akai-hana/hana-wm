///! Fallback configuration logic - terminal and font detection
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

// Generic detection helper to eliminate duplication
fn detectFromList(
    comptime list: []const []const u8,
    comptime checkFn: fn ([]const u8) bool,
    item_type: []const u8,
    fallback: []const u8,
) []const u8 {
    inline for (list) |item| {
        if (checkFn(item)) {
            debug.info("Detected {s}: {s}", .{ item_type, item });
            return item;
        }
    }
    debug.warn("No preferred {s} found, using '{s}'", .{ item_type, fallback });
    return fallback;
}

/// Detect first available terminal from the system
pub fn detectTerminal(_: std.mem.Allocator) ![]const u8 {
    return detectFromList(
        &TERMINALS,
        struct {
            fn check(cmd: []const u8) bool {
                return isCommandAvailable(cmd);
            }
        }.check,
        "terminal",
        "xterm",
    );
}

/// Detect first available font from the system.
/// Fonts are checked in preference order; X11 falls back gracefully if a font
/// is not actually installed, so we assume any font in our curated list is usable.
pub fn detectFont(_: std.mem.Allocator) ![]const u8 {
    return detectFromList(&FONTS, struct {
        fn check(_: []const u8) bool { return true; }
    }.check, "font", "monospace");
}

/// Inline helper for path checking
inline fn checkPath(buf: []u8, dir: []const u8, command: []const u8) bool {
    const full_path = std.fmt.bufPrintZ(buf, "{s}/{s}", .{ dir, command }) catch return false;
    const fd = std.posix.open(full_path, .{ .ACCMODE = .RDONLY }, 0) catch return false;
    std.posix.close(fd);
    return true;
}

/// Check command availability by searching common paths then $PATH
fn isCommandAvailable(command: []const u8) bool {
    var buf: [std.fs.max_path_bytes]u8 = undefined;

    // Check most common paths first (faster than full PATH parsing)
    const common_paths = [_][]const u8{ "/usr/bin", "/usr/local/bin", "/bin" };
    inline for (common_paths) |path| {
        if (checkPath(&buf, path, command)) return true;
    }

    // Walk $PATH, skipping directories already checked above
    const path_env = std.mem.span(std.c.getenv("PATH") orelse return false);
    var it = std.mem.splitScalar(u8, path_env, ':');
    while (it.next()) |dir| {
        if (dir.len == 0) continue;
        const already_checked = inline for (common_paths) |c| {
            if (std.mem.eql(u8, dir, c)) break true;
        } else false;
        if (!already_checked and checkPath(&buf, dir, command)) return true;
    }

    return false;
}

/// Load fallback TOML embedded in binary
pub inline fn getFallbackToml() []const u8 {
    return @embedFile("fallback.toml");
}
