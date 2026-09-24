//! Fallback configuration.
//! Provides terminal auto-detection and the embedded default TOML.

const std = @import("std");
const debug = @import("debug");
const paths = @import("paths");
const fallback_toml = @import("fallback_toml");

// Ordered by preference so the first match wins.
const terminals = [_][]const u8{
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

/// Last-resort terminal when nothing on the preference list is available.
const fallback_terminal = "xterm";

/// Returns the first available terminal from the preference list, falling back
/// to `fallback_terminal` when nothing else is found.
pub fn detectTerminal() []const u8 {
    for (terminals) |cmd| {
        if (isCommandAvailable(cmd)) {
            debug.info("Detected terminal: {s}", .{cmd});
            return cmd;
        }
    }
    debug.warn("No preferred terminal found, using '{s}'", .{fallback_terminal});
    return fallback_terminal;
}

fn isCommandAvailable(command: []const u8) bool {
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path_env = std.mem.span(std.c.getenv("PATH") orelse return false);
    var dir_it = paths.dirIterator(path_env);
    while (dir_it.next()) |dir| {
        if (paths.exeInDir(&buf, dir, command)) return true;
    }
    return false;
}

/// Returns the fallback TOML embedded in the binary, or null when
/// config/fallback.toml was absent at build time.
///
/// The `fallback_toml` module (injected by build.zig's injectShared) always
/// exists; an empty `content` slice is the only "missing" signal.
pub fn getFallbackToml() ?[]const u8 {
    const content = fallback_toml.content;
    return if (content.len == 0) null else content;
}
