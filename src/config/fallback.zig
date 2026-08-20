//! Fallback configuration.
//! Provides a terminal auto-detection heuristic and an embedded TOML
//! default used when no user config is present.

const std = @import("std");
const debug = @import("debug");

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

/// Returns the first available terminal from the preference list, falling back
/// to "xterm" when nothing else is found.
pub fn detectTerminal() []const u8 {
    for (terminals) |cmd| {
        if (isCommandAvailable(cmd)) {
            debug.info("Detected terminal: {s}", .{cmd});
            return cmd;
        }
    }
    debug.warn("No preferred terminal found, using 'xterm'", .{});
    return "xterm";
}

const common_paths = std.StaticStringMap(void).initComptime(.{
    .{ "/usr/bin", {} },
    .{ "/usr/local/bin", {} },
    .{ "/bin", {} },
});

fn isCommandAvailable(command: []const u8) bool {
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;

    const common_dirs = [_][]const u8{ "/usr/bin", "/usr/local/bin", "/bin" };
    inline for (common_dirs) |path| {
        if (checkPath(&buf, path, command)) return true;
    }

    const path_env = std.mem.span(std.c.getenv("PATH") orelse return false);
    var it = std.mem.splitScalar(u8, path_env, ':');
    while (it.next()) |dir| {
        if (dir.len == 0) continue;
        if (!common_paths.has(dir) and checkPath(&buf, dir, command)) return true;
    }

    return false;
}

// std.posix.access was removed in this Zig version, so faccessat is called
// as a raw syscall. It checks existence and executability in one syscall;
// openFileAbsolute checks readability only, so a non-executable file named
// like a terminal is not reported "available" and fails later with EACCES.
inline fn checkPath(buf: []u8, dir: []const u8, command: []const u8) bool {
    const full_path = std.fmt.bufPrintZ(buf, "{s}/{s}", .{ dir, command }) catch return false;
    const rc: isize = @bitCast(std.os.linux.faccessat(std.os.linux.AT.FDCWD, full_path, std.posix.X_OK, 0));
    return rc == 0;
}

/// Returns the fallback TOML embedded in the binary, or null when
/// config/fallback.toml was absent at build time.
///
/// The `fallback_toml` module (injected by build.zig's injectShared) always
/// exists; an empty `content` slice is the only "missing" signal.
pub inline fn getFallbackToml() ?[]const u8 {
    const content = @import("fallback_toml").content;
    return if (content.len == 0) null else content;
}
