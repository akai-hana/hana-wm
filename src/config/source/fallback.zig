//! Fallback configuration.
//! Provides terminal auto-detection and the embedded default TOML.
//! Also hosts the shared $PATH probe-order machinery (probe_order,
//! dirIterator, exeInDir): one probe order for finding an executable, shared
//! by this module's terminal detection and the prompt's command completion,
//! so the two cannot drift.
const std = @import("std");
const log = std.log.scoped(.fallback);
const fallback_toml = @import("fallback_toml");

/// Directories probed BEFORE the general $PATH walk: the handful of
/// well-known install locations checked first, in probe order. A dir
/// appearing both here and in $PATH is probed exactly once (see `probe_set`).
const probe_order = [_][]const u8{ "/usr/bin", "/usr/local/bin", "/bin" };

/// Membership set derived from `probe_order` so the two stay in sync: $PATH
/// segments equal to one of these are skipped during the general walk because
/// they were already probed.
const probe_set = std.StaticStringMap(void).initComptime(blk: {
    var kvs: [probe_order.len]struct { []const u8, void } = undefined;
    for (probe_order, 0..) |dir, i| kvs[i] = .{ dir, {} };
    break :blk kvs;
});

/// Yields an iterator over every directory a command should be probed in, in
/// probe order: `probe_order` first, then each non-empty $PATH segment not
/// already covered by a common dir. `env_val` aliases the caller's $PATH
/// buffer (getenv or the config arena) and must outlive the iterator.
pub fn dirIterator(env_val: []const u8) DirIterator {
    return .{ .env = env_val };
}

const DirIterator = struct {
    env: []const u8,
    common_idx: usize = 0,
    path_it: ?std.mem.SplitIterator(u8, .scalar) = null,

    pub fn next(self: *DirIterator) ?[]const u8 {
        if (self.common_idx < probe_order.len) {
            const dir = probe_order[self.common_idx];
            self.common_idx += 1;
            return dir;
        }
        self.path_it = self.path_it orelse std.mem.splitScalar(u8, self.env, ':');
        while (self.path_it.?.next()) |dir| {
            if (dir.len == 0) continue;
            if (probe_set.has(dir)) continue;
            return dir;
        }
        return null;
    }
};

/// True when `dir/name` resolves to an executable file. `buf` must have room
/// for the joined path (and is reused by the caller for the next probe, so the
/// whole scan stays allocation-free). A single faccessat X_OK checks existence
/// and executability in one syscall; openFileAbsolute checks readability only,
/// so a non-executable file named like a command is not misreported as
/// "available" and left to fail later with EACCES.
pub fn exeInDir(buf: []u8, dir: []const u8, name: []const u8) bool {
    const full_path = std.fmt.bufPrintZ(buf, "{s}/{s}", .{ dir, name }) catch return false;
    const rc: isize = @bitCast(std.os.linux.faccessat(
        std.os.linux.AT.FDCWD,
        full_path,
        std.posix.X_OK,
        0,
    ));
    return rc == 0;
}

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
            log.info("Detected terminal: {s}", .{cmd});
            return cmd;
        }
    }
    log.warn("No preferred terminal found, using '{s}'", .{fallback_terminal});
    return fallback_terminal;
}

fn isCommandAvailable(command: []const u8) bool {
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path_env = std.mem.span(std.c.getenv("PATH") orelse return false);
    var dir_it = dirIterator(path_env);
    while (dir_it.next()) |dir| {
        if (exeInDir(&buf, dir, command)) return true;
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
