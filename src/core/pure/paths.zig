//! Filesystem path utilities (XDG config home, $PATH walking, probe-order
//! membership) shared across config and bar modules. One probe order for
//! finding an executable: `probe_order` first (the source of truth), then the
//! caller's $PATH segments with those dirs skipped (`probe_set`, derived from
//! it, so the two cannot drift). Consumers: config/fallback and
//! prompt/completion walk the probe order; config/discover resolves
//! `configHome`; the prompt history and the session restore file share
//! `restricted_file_mode`; the re-exec snapshot and the restore file share
//! `runtimeFile`.

const std = @import("std");

/// Runtime-dir file path, the ONE policy for per-session state files:
/// `$XDG_RUNTIME_DIR/{base}{ext}` when set (already per-user, so no uid
/// suffix), else `/tmp/{base}-{uid}{ext}` so co-located users stay apart.
/// The uid suffix in the fallback is load-bearing. Callers own the returned
/// slice. Deliberately NOT used by native_pulse's socket probe: PulseAudio's
/// `/run/user/{uid}` fallback is a different convention, not this policy.
pub fn runtimeFile(alloc: std.mem.Allocator, base: []const u8, ext: []const u8) ![]u8 {
    if (std.c.getenv("XDG_RUNTIME_DIR")) |dir|
        return std.fmt.allocPrint(alloc, "{s}/{s}{s}", .{ std.mem.span(dir), base, ext });
    return std.fmt.allocPrint(alloc, "/tmp/{s}-{d}{s}", .{ base, std.os.linux.getuid(), ext });
}

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

/// XDG config-home resolution, the one place that policy lives (it was inline
/// in discover.searchPaths, which is the only caller but is not the right owner
/// for a rule about environment variables).
///
/// `$XDG_CONFIG_HOME` wins when set AND non-empty; otherwise `$HOME/.config`.
/// An EMPTY value counts as unset, per the XDG spec and for a concrete reason:
/// joining `""` with the app name yields a RELATIVE path, so `XDG_CONFIG_HOME=""`
/// silently redirected the config search to the current working directory --
/// a config that boots differently depending on where hana was started. The
/// old `getenv`-is-non-null test took the empty string at face value and hit
/// exactly that.
///
/// Writes into `buf` and returns the slice; `buf` is caller-owned so the
/// previous arena-dupe-then-free dance disappears.
pub fn configHome(buf: []u8, xdg: ?[]const u8, home: []const u8) ![]const u8 {
    if (xdg) |x| {
        if (x.len != 0) return std.fmt.bufPrint(buf, "{s}", .{x}) catch error.NameTooLong;
    }
    // The caller passes "/" for an unset HOME (so the result stays absolute),
    // and a bare "{s}/.config" would then be "//.config" -- harmless, but it
    // leaks into every warning and path comparison that mentions the config
    // home. Join semantics, not string concatenation.
    if (home.len != 0 and home[home.len - 1] == '/')
        return std.fmt.bufPrint(buf, "{s}.config", .{home}) catch error.NameTooLong;
    return std.fmt.bufPrint(buf, "{s}/.config", .{home}) catch error.NameTooLong;
}

/// POSIX mode for files that must never be world/group-writable: the session
/// restore file and the prompt's history file both call this out explicitly
/// so the magic literal isn't re-spelled at each call site.
pub const restricted_file_mode: u32 = 0o600;
