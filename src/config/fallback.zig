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

// std.posix.access(..., X_OK) checks both existence and that the file is
// executable by the current user in one syscall — this is intentionally not
// std.Io.Dir.openFileAbsolute (which only checks that the path can be
// opened for reading). A regular, non-executable file happening to share a
// terminal's name (e.g. a stray "kitty" left in /usr/local/bin by some
// unrelated package) would otherwise be reported as "available" here and
// only fail later, with an unhelpful EACCES, when hana actually tries to
// spawn it as the detected terminal.
inline fn checkPath(buf: []u8, dir: []const u8, command: []const u8) bool {
    const full_path = std.fmt.bufPrintZ(buf, "{s}/{s}", .{ dir, command }) catch return false;
    std.posix.access(full_path, std.posix.X_OK) catch return false;
    return true;
}

/// Returns the fallback TOML configuration embedded in the binary,
/// or error.FallbackMissing if config/fallback.toml was absent at build time.
pub inline fn getFallbackToml() error{FallbackMissing}![]const u8 {
    const opts = @import("build_options");
    if (!@hasDecl(opts, "fallback_toml")) return error.FallbackMissing;
    return @field(opts, "fallback_toml");
}
