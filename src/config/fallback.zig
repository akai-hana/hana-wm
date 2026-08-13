//! Fallback configuration
//! Auto-detects a suitable terminal and font when no user config is provided.

const std = @import("std");
const debug = @import("debug");

// Checked in preference order.
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

/// Returns the first available terminal from TERMINALS, or "xterm".
/// Pure PATH scan — does not allocate; returns a static string slice.
pub fn detectTerminal() []const u8 {
    for (TERMINALS) |cmd| {
        if (isCommandAvailable(cmd)) {
            debug.info("Detected terminal: {s}", .{cmd});
            return cmd;
        }
    }
    debug.warn("No preferred terminal found, using 'xterm'", .{});
    return "xterm";
}

/// Checks whether command exists in a common bin directory or $PATH.
fn isCommandAvailable(command: []const u8) bool {
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;

    const common_paths = [_][]const u8{ "/usr/bin", "/usr/local/bin", "/bin" };
    inline for (common_paths) |path| {
        if (checkPath(&buf, path, command)) return true;
    }

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

// std.posix.access was removed in this Zig version, so faccessat is called
// directly as a raw syscall, matching the codebase's other std.os.linux usage.
// It checks both existence and executability in one syscall — intentionally
// not std.Io.Dir.openFileAbsolute (which only checks readability), so a
// stray non-executable file named like a terminal isn't reported "available"
// and only later fails with an unhelpful EACCES at spawn time.
inline fn checkPath(buf: []u8, dir: []const u8, command: []const u8) bool {
    const full_path = std.fmt.bufPrintZ(buf, "{s}/{s}", .{ dir, command }) catch return false;
    const rc: isize = @bitCast(std.os.linux.faccessat(std.os.linux.AT.FDCWD, full_path, std.posix.X_OK, 0));
    return rc == 0;
}

/// Returns the fallback TOML embedded in the binary, or null when
/// config/fallback.toml was absent at build time. The `fallback_toml` module
/// (injected by build.zig's injectShared) always exists; an empty `content`
/// slice is the only "missing" signal.
pub inline fn getFallbackToml() ?[]const u8 {
    const content = @import("fallback_toml").content;
    return if (content.len == 0) null else content;
}
