//! Filesystem path helpers.
//! Shared $PATH walking for the config-side terminal detector (fallback.zig)
//! and the prompt's command completer (prompt.zig): one probe order, one
//! common-dir fast path, no duplicated split/scan logic.

const std = @import("std");

/// Directories probed BEFORE the general $PATH walk: the handful of
/// well-known install locations checked first. A dir appearing both here and
/// in $PATH is probed exactly once (see `common_paths`).
const common_dirs = [_][]const u8{ "/usr/bin", "/usr/local/bin", "/bin" };

/// Membership set derived from `common_dirs` so the two stay in sync: $PATH
/// segments equal to one of these are skipped during the general walk because
/// they were already probed.
const common_paths = std.StaticStringMap(void).initComptime(blk: {
    var kvs: [common_dirs.len]struct { []const u8, void } = undefined;
    for (common_dirs, 0..) |dir, i| kvs[i] = .{ dir, {} };
    break :blk kvs;
});

/// Yields an iterator over every directory a command should be probed in, in
/// probe order: `common_dirs` first, then each non-empty $PATH segment not
/// already covered by a common dir. `env_val` aliases the caller's $PATH
/// buffer (getenv or the config arena) and must outlive the iterator.
pub fn dirIterator(env_val: []const u8) DirIterator {
    return .{ .env = env_val };
}

pub const DirIterator = struct {
    env: []const u8,
    common_idx: usize = 0,
    path_it: ?std.mem.SplitIterator(u8, .scalar) = null,

    pub fn next(self: *DirIterator) ?[]const u8 {
        if (self.common_idx < common_dirs.len) {
            const dir = common_dirs[self.common_idx];
            self.common_idx += 1;
            return dir;
        }
        self.path_it = self.path_it orelse std.mem.splitScalar(u8, self.env, ':');
        while (self.path_it.?.next()) |dir| {
            if (dir.len == 0) continue;
            if (common_paths.has(dir)) continue;
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

/// POSIX mode for files that must never be world/group-writable: the session
/// restore file and the prompt's history file both call this out explicitly
/// so the magic literal isn't re-spelled at each call site.
pub const restricted_file_mode: u32 = 0o600;
