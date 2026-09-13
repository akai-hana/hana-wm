//! Unified WM reload coordinator.
//!
//! Owns the *process hand-off* (in-place exec of the current binary) and the
//! event-loop trigger flag. xcb-free and model-free: it never touches the X
//! connection or the model. The event loop performs the actual re-exec
//! sequence (save state, close the X connection, then execNext) so this
//! module stays a pure flag surface, mirroring how proc.zig owns the reload
//! flag but events.zig consumes it.
//!
//! The reload is UNCONDITIONAL: every request re-execs whatever image is at
//! the resolved exec path right now (the freshly built binary). There is no
//! binary-change check -- comparing the running image against the file is
//! pointless when the intent is "run the current file", and a stale
//! comparison could silently keep the old code running (see requestReload).

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

/// Null-terminated absolute path to exec on re-exec (readLink of
/// `/proc/self/exe`, or the override passed to init()). c_allocator-owned,
/// process-lifetime: never freed.
var exec_path_z: ?[*:0]const u8 = null;

/// Re-exec request flag. Set by `requestReexec` / `requestReload` (both
/// trigger the hand-off unconditionally), consumed by `consumeReexec` in the
/// main event loop.
var should_reexec = std.atomic.Value(bool).init(false);

/// Resolves the binary to exec on re-exec: the readLink of `/proc/self/exe`
/// (or the override passed in). One-shot at startup, before any reload/reexec
/// request can arrive.
///
/// `binary_path_override` names the binary to exec when the running image
/// can't be resolved via /proc (e.g. tests); when null, the resolved
/// readLink of `/proc/self/exe` is used.
pub fn init(alloc: std.mem.Allocator, binary_path_override: ?[]const u8) void {
    if (binary_path_override) |override| {
        exec_path_z = alloc.dupeZ(u8, override) catch null;
        return;
    }
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = std.os.linux.readlinkat(std.os.linux.AT.FDCWD, "/proc/self/exe", &buf, buf.len);
    if (std.posix.errno(n) != .SUCCESS) {
        debug.warn(
            "restart: readlink /proc/self/exe failed; in-place re-exec disabled",
            .{},
        );
        exec_path_z = null;
    } else {
        exec_path_z = alloc.dupeZ(u8, buf[0..n]) catch null;
    }
}

/// The unified entry: everything the `reload` keybind (and SIGUSR1) means.
/// Always re-execs the binary at the exec path, unconditionally — no
/// identity check, so a rebuild is picked up on the very first reload.
pub fn requestReload() void {
    requestReexec();
}

/// Unconditional re-exec (`reload_hana` action / `reload_config` alike):
/// re-exec the current in-place binary, skipping any change check.
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
