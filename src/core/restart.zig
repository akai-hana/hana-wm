//! Unified WM reload coordinator.
//!
//! Owns the *decision* (binary changed since boot? then re-exec, else config
//! reload) and the *process hand-off* (in-place exec of the new binary).
//! xcb-free and model-free: it never touches the X connection or the model.
//! The event loop performs the actual re-exec sequence (save state, close the
//! X connection, then execNext) so this module stays a pure decision/flag
//! surface, mirroring how proc.zig owns the reload flag but events.zig
//! consumes it.
//!
//! The binary-change check exploits an /proc asymmetry: `/proc/self/exe`
//! always resolves to the ORIGINAL file the running image was exec'd from,
//! even after the filesystem path has been replaced. So the check compares
//! the running image (captured at init) against the current file at the
//! resolved exec path (an atomic `mv new bin` shows up as an inode/device
//! change, a truncate-plus-rewrite-in-place shows up as an mtime/size change.

const std = @import("std");

const utils = @import("utils");
const debug = @import("debug");

// libc bindings for execv/setenv (no Zig stdlib wrappers exist for them, and
// the executable links libc, so mirroring spawn.zig's pattern is the honest
// route). execv (not execvp) is deliberate: we hand it the absolute self
// path, so there is no PATH lookup; and as the variadic execv it inherits
// the process environ, which carries DISPLAY and HANA_RESTORE forward.
const c = @cImport({
    @cInclude("unistd.h");
    @cInclude("stdlib.h");
});

/// Identity tuple of a stat'd binary: enough to tell "same file" from
/// "different file or rewritten file" across a filesystem.
const FileIdentity = struct {
    dev_major: u32,
    dev_minor: u32,
    ino: u64,
    mtime_sec: i64,
    mtime_nsec: u32,
    size: u64,
};

/// Boot-time identity of the running image (stat of `/proc/self/exe`).
/// Null if the stat failed, in which case no change can ever be detected.
var boot_identity: ?FileIdentity = null;

/// Null-terminated absolute path to exec on re-exec (readLink of
/// `/proc/self/exe`, or the override passed to init()). c_allocator-owned,
/// process-lifetime: never freed.
var exec_path_z: ?[*:0]const u8 = null;

/// Re-exec request flag, mirroring proc.should_reload. Set by
/// `requestReexec` / `requestReload` (binary changed), consumed by
/// `consumeReexec` in the main event loop.
var should_reexec = std.atomic.Value(bool).init(false);

/// stats `path_z` (following symlinks, like stat(2)), returns null on any
/// error so callers degrade to the config-reload fallback instead of
/// re-exec'ing into a missing or unreadable binary.
///
/// Uses statx(2) because Zig 0.16 vetoes the libc stat structs on Linux and
/// std's own file IO buries `dev`; statx returns dev+ino+mtime+size in one
/// syscall, which is exactly the (dev, ino, mtime_ns, size) tuple the change
/// check needs.
fn statIdentity(path_z: [*:0]const u8) ?FileIdentity {
    var stx: std.os.linux.Statx = std.mem.zeroes(std.os.linux.Statx);
    const rc = std.os.linux.statx(
        std.os.linux.AT.FDCWD,
        path_z,
        std.os.linux.AT.NO_AUTOMOUNT,
        std.os.linux.STATX.BASIC_STATS,
        &stx,
    );
    switch (std.posix.errno(rc)) {
        .SUCCESS => {},
        else => return null,
    }
    return .{
        .dev_major = stx.dev_major,
        .dev_minor = stx.dev_minor,
        .ino = stx.ino,
        .mtime_sec = stx.mtime.sec,
        .mtime_nsec = stx.mtime.nsec,
        .size = stx.size,
    };
}

/// Captures the running image's identity (stat of `/proc/self/exe`) and
/// stashes the optional override for the path to exec on re-exec.
///
/// `binary_path_override` names the binary to exec when the running image
/// can't be resolved via /proc (e.g. tests); when null, the resolved
/// readLink of `/proc/self/exe` is used. Must be called once at startup,
/// before any reload/reexec request can arrive.
pub fn init(alloc: std.mem.Allocator, binary_path_override: ?[]const u8) void {
    boot_identity = statIdentity("/proc/self/exe");
    if (boot_identity == null)
        debug.warn("restart: could not stat /proc/self/exe; binary-change re-exec disabled", .{});

    if (binary_path_override) |override| {
        exec_path_z = alloc.dupeZ(u8, override) catch null;
        return;
    }
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = std.os.linux.readlinkat(std.os.linux.AT.FDCWD, "/proc/self/exe", &buf, buf.len);
    switch (std.posix.errno(n)) {
        .SUCCESS => exec_path_z = alloc.dupeZ(u8, buf[0..n]) catch null,
        else => {
            debug.warn("restart: readlink /proc/self/exe failed; binary-change re-exec disabled", .{});
            exec_path_z = null;
        },
    }
}

/// Whether the file at the resolved exec path differs from the image
/// captured at init(). True on both atomic-replace (device/inode change) and
/// truncate-and-rewrite-in-place (mtime/size change).
///
/// If the boot capture or the stat of the current path fails (file missing),
/// returns false: never re-exec into nothing; the config-reload fallback
/// still runs.
pub fn binaryChanged() bool {
    const boot = boot_identity orelse return false;
    const exec_path = exec_path_z orelse return false;
    const now = statIdentity(exec_path) orelse return false;
    return !(now.dev_major == boot.dev_major and
        now.dev_minor == boot.dev_minor and
        now.ino == boot.ino and
        now.mtime_sec == boot.mtime_sec and
        now.mtime_nsec == boot.mtime_nsec and
        now.size == boot.size);
}

/// The unified entry: everything the `reload` keybind (and SIGUSR1) means.
/// If the binary changed, request re-exec; otherwise fall back to the
/// existing config-reload path (proc flag + wake byte).
pub fn requestReload() void {
    if (binaryChanged()) {
        debug.info("restart: binary changed since boot, re-exec", .{});
        should_reexec.store(true, .release);
        utils.wake();
    } else {
        debug.info("restart: binary unchanged, reloading config", .{});
        utils.reload();
    }
}

/// Unconditional re-exec (`reload_hana` action): skip the binary check.
pub fn requestReexec() void {
    should_reexec.store(true, .release);
    utils.wake();
}

/// Atomic, mirrors proc.consumeReload: true exactly once per request.
/// Consumed by the event loop before consumeReload.
pub fn consumeReexec() bool {
    return should_reexec.swap(false, .acq_rel);
}

/// The resolved path of the running image (readLink of `/proc/self/exe`, or
/// the init() override). Null when re-exec was never armed (init saw no
/// /proc). The event loop hands this to execNext as argv[0] / exec path.
pub fn selfPath() ?[]const u8 {
    const z = exec_path_z orelse return null;
    return z[0..std.mem.len(z)];
}

/// Execs `self_path` IN PLACE, inheriting environ/DISPLAY. Never returns.
/// MUST be called only after the X connection is closed (handleReexec does):
/// a live inherited fd would keep the old client (and its root
/// SubstructureRedirect grab) alive while the fresh connection tries to
/// claim the same grab, and the server would reject the newcomer with
/// BadAccess.
///
/// Deliberately NO fork: the process identity (pid and parent) survives
/// the hand-off. Under startx the display lives exactly as long as the
/// session client (xinit -> Xsession -> .xinitrc -> this process); replacing
/// the image in place keeps that chain unbroken, so the successor boots into
/// a live server and the session only ends when the new WM actually exits.
/// (The original fork-then-exit design killed every supervised re-exec:
/// the parent's exit made the session script return and xinit tore down
/// Xorg mid-hand-off.)
///
/// The restore path crosses the hand-off in HANA_RESTORE: execv inherits
/// environ, and Zig 0.16's classic `main() !void` cannot read argv, so the
/// environment is the one channel a fresh boot can see.
pub fn execNext(self_path: []const u8, restore_path: []const u8) noreturn {
    // Null-terminated copies for setenv/execv: the caller's slices are not
    // necessarily terminated, and nothing runs after exec to free them.
    const self_z = std.heap.c_allocator.dupeZ(u8, self_path) catch {
        debug.err("restart: out of memory copying self path", .{});
        std.process.exit(1);
    };
    const restore_z = std.heap.c_allocator.dupeZ(u8, restore_path) catch {
        debug.err("restart: out of memory copying restore path", .{});
        std.process.exit(1);
    };

    if (c.setenv("HANA_RESTORE", restore_z, 1) != 0) {
        debug.err("restart: setenv failed", .{});
        std.process.exit(1);
    }
    _ = c.execv(self_z, @ptrCast(&[_:null]?[*:0]const u8{ self_z, null }));
    // Only reachable when exec failed; the X connection is already closed,
    // so there is nothing left to do but end the session.
    debug.err("restart: execv failed", .{});
    std.process.exit(1);
}
