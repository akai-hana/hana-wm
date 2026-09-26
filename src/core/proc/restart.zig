//! Unified WM reload coordinator.
//!
//! Owns the *process hand-off* (in-place exec of the current binary) and the
//! event-loop trigger flag. xcb-free and model-free: it never touches the X
//! connection or the model. The event loop performs the actual re-exec
//! sequence (save state, close the X connection, then execNext) so this
//! module stays a pure flag surface, mirroring how lifecycle.zig owns the reload
//! flag but events.zig consumes it.
//!
//! The reload is UNCONDITIONAL: every request re-execs whatever image is at
//! the resolved exec path right now (the freshly built binary). There is no
//! binary-change check -- comparing the running image against the file is
//! pointless when the intent is "run the current file", and a stale
//! comparison could silently keep the old code running.
//!
//! Binary-only by construction: the re-exec hand-off pins HANA_CONFIG_DIR to
//! the frozen last-good config snapshot (config.refreshSnapshot), so the
//! successor never re-reads the user's config files. Config changes land
//! exclusively through the `reload_config` action / SIGHUP.
//!
//! This is the *re-exec* coordinator only. Config-only reloads (the
//! `reload_config` keybind, SIGHUP) stay in lifecycle.zig's flag surface and never
//! re-exec the process.

const std = @import("std");

const log = @import("log");

const lifecycle = @import("lifecycle");
// libc bindings for execv/setenv (no Zig stdlib wrappers exist for them, and
// the executable links libc, so mirroring spawn.zig's pattern is the honest
// route). execv (not execvp) is deliberate: we hand it the absolute self
// path, so there is no PATH lookup; and as the variadic execv it inherits
// the process environ, which carries DISPLAY and HANA_RESTORE forward.
const c = @cImport({
    @cInclude("unistd.h");
    @cInclude("stdlib.h");
});

/// c_allocator-owned, NUL-terminated copy of `src`, or die: the re-exec
/// cannot proceed without the path, the X connection is already closed, and
/// there is nothing left to do but end the session.
fn mustDupeZ(src: []const u8, what: []const u8) [:0]const u8 {
    return std.heap.c_allocator.dupeZ(u8, src) catch {
        log.err("restart: out of memory copying {s}", .{what});
        std.process.exit(1);
    };
}

/// Null-terminated absolute path to exec on re-exec (readLink of
/// `/proc/self/exe`). c_allocator-owned, process-lifetime: never freed.
var exec_path_z: ?[:0]const u8 = null;

/// Re-exec request flag. Set by `requestReexec` (the `reload_hana` action and
/// SIGUSR1), consumed by `consumeReexec` in the main event loop.
var should_reexec = std.atomic.Value(bool).init(false);

/// Resolves the binary to exec on re-exec: the readLink of `/proc/self/exe`.
/// One-shot at startup, before any reload/reexec request can arrive.
pub fn init() void {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = std.os.linux.readlinkat(std.os.linux.AT.FDCWD, "/proc/self/exe", &buf, buf.len);
    // readlinkat returns exactly `buf.len` (errno still SUCCESS) when the
    // path fills the buffer -- truncated, no NUL. The old code then dupeZ'd
    // the truncated bytes as the exec path. Treat a full buffer as
    // unresolvable so a re-exec can never hand execv a cut-off path.
    if (std.posix.errno(n) != .SUCCESS or n == buf.len) {
        log.warn(
            "restart: readlink /proc/self/exe failed or truncated; in-place re-exec disabled",
            .{},
        );
        exec_path_z = null;
    } else {
        exec_path_z = std.heap.c_allocator.dupeZ(u8, buf[0..n]) catch null;
    }
}

/// Unconditional re-exec (`reload_hana` action / SIGUSR1): re-exec the
/// current in-place binary, skipping any change check.
pub fn requestReexec() void {
    should_reexec.store(true, .release);
    lifecycle.wake();
}

/// Atomic, mirrors proc.consumeReload: true exactly once per request.
/// Consumed by the event loop before consumeReload.
pub fn consumeReexec() bool {
    return should_reexec.swap(false, .acq_rel);
}

/// The resolved path of the running image. Null when re-exec was never armed
/// (init saw no /proc). The event loop hands this to execNext as argv[0] /
/// exec path.
pub fn selfPath() ?[]const u8 {
    const z = exec_path_z orelse return null;
    return z[0..z.len];
}

/// The same path, still sentinel-terminated, for callers that hand it to
/// `execv`. `execNext` takes this form so the hand-off does not re-duplicate a
/// string the process is already holding.
pub fn selfPathZ() ?[:0]const u8 {
    return exec_path_z;
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
/// The complete re-exec hand-off, assembled once and owned by `restart`.
///
/// These three values used to travel separately: the event loop held the exec
/// path, built the restore path, and called into config for the snapshot path
/// before handing each to `execNext` as loose arguments. Three sources of truth
/// for one transition means the sequence has to be re-derived at every call
/// site, and nothing can assert the set is complete. Naming the record makes
/// "what crosses the hand-off" a single declaration.
pub const Handoff = struct {
    /// Sentinel-terminated (`selfPathZ()`); this process's own image.
    self_path: [:0]const u8,
    /// The session state file. Not sentinel-terminated: the only copy is made
    /// here, inside the call that needs it.
    restore_path: []const u8,
    /// Frozen last-good config directory, or null when no user config was ever
    /// loaded (a fallback-only session has nothing to pin).
    config_snapshot: ?[:0]const u8 = null,
};

/// The hand-off for this process, or null when re-exec was never armed
/// (`init` saw no `/proc`, so there is no exec path to hand over).
///
/// `config_snapshot` is passed in rather than resolved here: the snapshot
/// lives in the config layer, and importing config from `core/proc` to fetch
/// one path would invert the dependency for no gain. The caller already has
/// both values; this only fixes their order and names them.
pub fn currentHandoff(restore_path: []const u8, config_snapshot: ?[:0]const u8) ?Handoff {
    const self_path = selfPathZ() orelse return null;
    return .{
        .self_path = self_path,
        .restore_path = restore_path,
        .config_snapshot = config_snapshot,
    };
}

pub fn execNext(handoff: Handoff) noreturn {
    const self_z = handoff.self_path;
    const restore_z = mustDupeZ(handoff.restore_path, "restore path");

    if (c.setenv("HANA_RESTORE", restore_z, 1) != 0) {
        log.err("restart: setenv failed", .{});
        std.process.exit(1);
    }
    if (handoff.config_snapshot) |snap_z|
        _ = c.setenv("HANA_CONFIG_DIR", snap_z, 1);
    _ = c.execv(self_z, @ptrCast(&[_:null]?[*:0]const u8{ self_z, null }));
    // Only reachable when exec failed; the X connection is already closed,
    // so there is nothing left to do but end the session.
    log.err("restart: execv failed", .{});
    std.process.exit(1);
}
