//! Spawn engine: detached command execution for keybind `exec` actions.
//!
//! Double-fork so the grandchild re-parents to init and the WM never
//! accumulates zombies. A single O_CLOEXEC pipe carries the outcome: success
//! closes its copy automatically; otherwise the intermediate child writes
//! tag_pid and the grandchild writes tag_failed only if execvp() fails; two
//! independently-scheduled writers, so messages can arrive in either order
//! (finishSpawn() handles both). EOF ends the conversation; entries resolve via
//! drainPendingSpawns() (every event batch) or reapPendingChildren() (SIGCHLD).

const std = @import("std");

// libc bindings for fork/exec/wait (no Zig stdlib wrappers exist for these low-level syscalls)
const c = @cImport({
    @cInclude("unistd.h");
    @cInclude("sys/wait.h");
});

const core = @import("core");
const log = @import("log");
const time = @import("time");
const tracking = @import("tracking");
const window = @import("window");

const bounded = @import("bounded");
const lifecycle = @import("lifecycle");
/// Tags for the two possible messages written onto the spawn pipe. Sent as
/// a leading byte so the reader can tell them apart no matter which order
/// they arrive in (see finishSpawn()).
const tag_pid: u8 = 0;
const tag_failed: u8 = 1;

/// Byte length of a tag_pid message: the tag plus a raw c_int.
const pid_msg_len: usize = 1 + @sizeOf(c_int);

/// Writes the tag_failed byte to the spawn pipe and exits: the signal that
/// resolves this spawn as failed. Used on both post-fork failure paths.
fn failWithTag(pipe_write: c_int) noreturn {
    const msg = [1]u8{tag_failed};
    _ = c.write(pipe_write, &msg, msg.len);
    _ = c.close(pipe_write);
    std.process.exit(1);
}

/// execvp of `cmd` through `/bin/sh -c`; failures fall through to the caller's
/// own exit/tag path.
fn execShell(cmd_z: [*:0]const u8) void {
    _ = c.execvp("/bin/sh", @ptrCast(&[_:null]?[*:0]const u8{ "/bin/sh", "-c", cmd_z, null }));
}

/// Grandchild: detaches from the session and execs the command.
/// On execvp failure, writes a tag_failed byte to pipe_write before exiting.
/// On success this function never returns far enough to write anything;
/// pipe_write's O_CLOEXEC copy closes itself as part of the exec.
fn execAsGrandchild(pipe_write: c_int, cmd_z: [*:0]const u8) noreturn {
    _ = c.setsid();
    execShell(cmd_z);
    failWithTag(pipe_write);
}

const second_fork_failed = "hana: second fork failed\n";

/// Intermediate child: forks the grandchild, forwards its PID over the
/// spawn pipe tagged as tag_pid, then exits so the grandchild is
/// re-parented to init.
fn forkIntermediate(pipe_write: c_int, cmd_z: [*:0]const u8) noreturn {
    const grandchild_pid = c.fork();
    if (grandchild_pid < 0) {
        // Raw write(2) only (same discipline as signals.writeLiteral):
        // anything that allocates or takes a lock is unsafe in a forked
        // child before exec.
        _ = std.os.linux.write(2, second_fork_failed.ptr, second_fork_failed.len);
        std.process.exit(1);
    }
    if (grandchild_pid == 0) {
        // Grandchild: keep pipe_write open rather than closing it up front.
        // Its copy is O_CLOEXEC, so a successful execvp() closes it for us;
        // execAsGrandchild only writes to it explicitly if exec fails.
        execAsGrandchild(pipe_write, cmd_z);
    }

    const gp: c_int = grandchild_pid;
    var msg: [pid_msg_len]u8 = undefined;
    msg[0] = tag_pid;
    @memcpy(msg[1..], std.mem.asBytes(&gp));
    // A short/failed write (e.g. EPIPE after the WM closed the read end
    // on shutdown) would leave the WM waiting on a conversation that never
    // delivers a pid. In that case declare the spawn failed and exit
    // non-zero; the grandchild (if any) still runs, just unrouted.
    if (c.write(pipe_write, &msg, msg.len) != pid_msg_len) {
        failWithTag(pipe_write);
    }
    _ = c.close(pipe_write);
    std.process.exit(0);
}

// Pending spawn table (max 16 in-flight double-forks).

const max_pending_spawns: usize = 16;

/// Commands shorter than this are null-terminated on the stack; longer ones
/// are copied to the heap so executeShellCommand stays allocation-free for
/// the common short-command case.
const stack_cmd_capacity: usize = 256;

/// Nul-terminated command resolved by `resolveCmdZ`. `heap` is the owning
/// allocation when the command was too long for the stack buffer (the caller
/// frees it); `z` then aliases it.
const ResolvedCmd = struct {
    z: [:0]const u8,
    heap: ?[:0]const u8 = null,
};

/// Copies `cmd` into a nul-terminated form: the provided stack buffer when it
/// fits, otherwise a heap dupe the caller must free.
fn resolveCmdZ(alloc: std.mem.Allocator, cmd: []const u8, buf: *[stack_cmd_capacity]u8) !ResolvedCmd {
    if (cmd.len < buf.len)
        return .{ .z = try std.fmt.bufPrintZ(buf, "{s}", .{cmd}) };
    const heap = try alloc.dupeZ(u8, cmd);
    return .{ .z = heap, .heap = heap };
}

/// Largest possible spawn-pipe conversation: a tag_pid message plus an
/// optional trailing (or leading) tag_failed byte.
const spawn_msg_max: usize = pid_msg_len + 1;

/// Longest command text kept per pending spawn, for diagnostics. A failed
/// spawn used to be reported as nothing at all (or, for a wedged pipe, as
/// silence forever), so there was no way to tell "the command failed" from
/// "hana lost track of the command".
const cmd_report_max: usize = 96;

/// How long a pending entry may stay unresolved before it is dropped as stuck
/// (4.8). The whole conversation is a few bytes between two forks of the same
/// parent, so anything still open after this has already lost the outcome; a
/// table of 16 such entries is a permanent wedge on `exec` (every later spawn
/// refused with SpawnQueueFull).
const spawn_timeout_ms: i64 = 5_000;

/// Lifecycle state for a single double-fork spawn.
const PendingSpawn = struct {
    pid: c_int, // PID of intermediate child; used for targeted waitpid.
    spawn_fd: ?c_int, // Read end of the spawn pipe (O_NONBLOCK). null once done.
    buf: [spawn_msg_max]u8 = undefined, // Accumulates bytes until the conversation ends.
    len: usize = 0, // Valid bytes accumulated in buf so far.
    spawn_ws: ?u8, // Target workspace for window.registerSpawn.
    /// Truncated command text (not NUL-terminated; use `cmd_len`). Present
    /// only so finishSpawn's failure report and the stuck-entry expiry can
    /// say WHICH command they are talking about.
    cmd: [cmd_report_max]u8 = undefined,
    cmd_len: u8 = 0,
    /// Monotonic start of this entry, for the stuck-entry deadline (4.8).
    started_ms: i64 = 0,

    fn command(self: *const PendingSpawn) []const u8 {
        return self.cmd[0..self.cmd_len];
    }
};

// std.BoundedArray was removed in the Zig 0.16 toolchain; bounded.BoundedList
// is the shared fixed-buffer-plus-length stand-in used everywhere this shape
// is needed.
var g_pending: bounded.BoundedList(PendingSpawn, max_pending_spawns) = .{};

/// Spawns `cmd` as a detached grandchild (double-fork). Returns immediately;
/// lifecycle is tracked in g_pending and resolved by drainPendingSpawns() /
/// reapPendingChildren() without blocking the event loop.
pub fn executeShellCommand(cmd: []const u8) !void {
    // Snapshot the workspace now; correct for sequence actions of the form
    // [exec, switch_workspace] where a later action mutates g_current.
    const spawn_ws = tracking.getCurrentWorkspace();

    var cmd_buf: [stack_cmd_capacity]u8 = undefined;
    const resolved = try resolveCmdZ(core.getState().alloc, cmd, &cmd_buf);
    defer if (resolved.heap) |h| core.getState().alloc.free(h);
    const cmd_z = resolved.z.ptr;

    // Refuse up front instead of fork-then-discover-the-table-is-full. The
    // old path logged past the append and, once the table filled, fell back
    // to a synchronous waitpid on the event loop and silently dropped
    // workspace routing for the spawn.
    if (g_pending.len >= max_pending_spawns) {
        log.err("spawn: pending spawn table full, rejecting '{s}'", .{cmd});
        return error.SpawnQueueFull;
    }

    const pipe_fds = lifecycle.makePipe() catch {
        log.err("pipe2() failed (spawn pipe): {s}", .{cmd});
        return error.PipeFailed;
    };

    const pid = c.fork();
    if (pid < 0) {
        _ = c.close(pipe_fds[0]);
        _ = c.close(pipe_fds[1]);
        log.err("First fork failed: {s}", .{cmd});
        return error.ForkFailed;
    }

    if (pid == 0) {
        _ = c.close(pipe_fds[0]);
        forkIntermediate(pipe_fds[1], cmd_z);
    }

    // Parent: close the write end so our read end eventually sees EOF.
    _ = c.close(pipe_fds[1]);

    // Spawn-crossing suppression queries the cursor in window.handleMapRequest
    // when the MapRequest arrives (once per window), so no round-trip here.

    // The capacity pre-check above guarantees room, so append cannot fail.
    var entry = PendingSpawn{
        .pid = pid,
        .spawn_fd = pipe_fds[0],
        .spawn_ws = spawn_ws,
        .started_ms = time.monotonicMs(),
    };
    const keep = @min(cmd.len, cmd_report_max);
    @memcpy(entry.cmd[0..keep], cmd[0..keep]);
    entry.cmd_len = @intCast(keep);
    std.debug.assert(g_pending.append(entry));
}

/// Upper bound on `readFds` output, so the event loop can size its poll set
/// once instead of growing it. Matches the table capacity, so a full table is
/// representable.
pub const max_read_fds: usize = max_pending_spawns;

/// Copies the read end of every pending spawn pipe into `buf` and returns how
/// many were written. Entries whose pipe is already closed (buffer full, or
/// EOF already seen) are skipped, so the count can shrink between calls.
///
/// The event loop polls exactly these fds, which is what removes the last
/// unbounded-latency path in the spawn hand-off: a spawn whose output is ready
/// but which produced no X event and no signal used to wait for the next
/// unrelated wakeup, because the pipe was only drained from inside the X event
/// batch (`drainPendingSpawns` at the end of `handleXcbEvents`) and from
/// SIGCHLD. A command that prints and exits while the X socket stays silent
/// therefore stalled until some other client happened to talk to the server.
pub fn readFds(buf: []std.posix.fd_t) []std.posix.fd_t {
    var n: usize = 0;
    for (g_pending.slice()) |*entry| {
        if (entry.spawn_fd == null) continue;
        if (n == buf.len) break;
        buf[n] = entry.spawn_fd.?;
        n += 1;
    }
    return buf[0..n];
}

/// Drains pending spawn entries non-blockingly (every event batch, on SIGCHLD,
/// and now on spawn-pipe readiness), until EOF or a full buffer; a full buffer already holds both
/// possible messages, so EOF needn't be awaited. finishSpawn() classifies.
pub fn drainPendingSpawns() void {
    if (g_pending.len == 0) return;
    var i: usize = 0;
    while (i < g_pending.len) {
        const entry = &g_pending.slice()[i];

        if (entry.spawn_fd) |fd| {
            const n = c.read(fd, &entry.buf[entry.len], entry.buf.len - entry.len);
            if (n > 0) {
                entry.len += @intCast(n);
                if (entry.len == entry.buf.len) {
                    // Buffer full: both possible messages have necessarily
                    // arrived already; no need to wait for EOF too.
                    _ = c.close(fd);
                    entry.spawn_fd = null;
                }
            } else if (n < 0 and std.posix.errno(n) == .AGAIN) {
                // Not ready yet; retry on the next call.
            } else {
                // EOF (n == 0) or a hard read error: conversation is over.
                _ = c.close(fd);
                entry.spawn_fd = null;
            }
        }

        // 4.8: the pipe closing is not a deadline. A stuck entry (pipe open,
        // or closed with the child never reaped) is dropped once it is older
        // than spawn_timeout_ms, so 16 stuck entries can no longer wedge
        // `exec` forever behind SpawnQueueFull.
        if (entry.started_ms != 0 and time.monotonicMs() - entry.started_ms > spawn_timeout_ms) {
            log.warn("spawn stuck for {d}ms, dropping: '{s}'", .{
                spawn_timeout_ms,
                entry.command(),
            });
            entry.spawn_fd = null;
            if (entry.pid > 0) {
                // One last non-blocking reap so the common case (child gone,
                // signal not yet delivered) does not leak a zombie.
                if (c.waitpid(entry.pid, null, c.WNOHANG) > 0) entry.pid = -1;
            }
            g_pending.swapRemove(i);
            continue;
        }

        if (entry.spawn_fd != null) {
            i += 1;
            continue;
        }

        // The intermediate child wrote EOF (or its fd errored closed), so it
        // has just exited; reap it eagerly here rather than leaving a zombie
        // until SIGCHLD is next delivered. Same WNOHANG/WNOHANG-only policy
        // as reapPendingChildren: never blocks the event loop.
        //
        // 4.2: clear `pid` ONLY when waitpid actually reaped. This used to be
        // unconditional, which was the bug: a WNOHANG that returned 0 (the
        // child had closed its fd but not yet exited) disarmed the only
        // reaper for that pid, and the entry is removed below -- so the
        // intermediate child became a permanent zombie. `spawn_is_closed`
        // keeps the entry in the table until the reap really happened.
        if (entry.pid > 0 and c.waitpid(entry.pid, null, c.WNOHANG) > 0)
            entry.pid = -1;

        finishSpawn(entry);
        g_pending.swapRemove(i);
    }
}

/// Classifies a fully-drained spawn-pipe conversation and, on success,
/// registers the spawn for workspace routing.
///
/// Both writes are under PIPE_BUF, so neither is torn or interleaved: a
/// tag_failed byte anywhere is a reliable failure signal in any arrival
/// order; an empty buffer means the second fork() never ran.
fn finishSpawn(entry: *PendingSpawn) void {
    const data = entry.buf[0..entry.len];

    var grandchild: c_int = -1;
    var failed = data.len == 0;

    var rest = data;
    while (rest.len > 0) {
        switch (rest[0]) {
            tag_pid => {
                if (rest.len < pid_msg_len) {
                    failed = true;
                    break;
                }
                grandchild = std.mem.bytesToValue(c_int, rest[1..][0..@sizeOf(c_int)]);
                rest = rest[pid_msg_len..];
            },
            tag_failed => {
                failed = true;
                rest = rest[1..];
            },
            else => {
                failed = true;
                break;
            },
        }
    }

    if (failed) {
        // 4.4: a failed spawn used to be completely silent. `entry.cmd` is
        // the truncated command, so this is now actionable: which command,
        // and that execvp (or the second fork) is what failed.
        log.warn("spawn failed: '{s}' (exec did not succeed)", .{entry.command()});
        return;
    }
    if (entry.spawn_ws) |ws| {
        const pid_u32: u32 = if (grandchild > 0) @intCast(grandchild) else 0;
        window.registerSpawn(core.WorkspaceId.fromIndex(ws), pid_u32);
    }
}

/// Reaps zombie intermediate children without blocking. Called from the
/// SIGCHLD handler; the spawn-pipe drain stays in signals.zig so it doesn't
/// run twice per SIGCHLD.
pub fn reapPendingChildren() void {
    // 4.2: ONE reaper path. The per-pid loop alone was not enough -- a SIGCHLD
    // that arrived for a pid hana no longer had a pending entry for (the
    // entry was removed on pipe-close, and an early version cleared `pid`
    // before the child was actually reaped) was a zombie nothing would ever
    // collect. waitpid(-1, WNOHANG) sweeps every child hana owns, so the
    // hand-off is idempotent and cannot miss one; it returns -ECHILD the
    // moment hana has no unreaped children, which is a cheap no-op.
    while (c.waitpid(-1, null, c.WNOHANG) > 0) {}

    for (g_pending.slice()) |*entry| {
        if (entry.pid > 0 and c.waitpid(entry.pid, null, c.WNOHANG) > 0)
            entry.pid = -1;
    }
}

/// Runs `cmd` to completion before returning, for `,`-sequenced exec steps.
///
/// Unlike executeShellCommand (fire-and-forget detach), this single-fork keeps
/// the child a direct child and BLOCKS the caller -- and therefore the WM
/// event loop -- on waitpid until the command exits. That is the whole point:
/// a `,` sequence step is only "done" once its exec has fully finished, so
/// the next step starts against a completed state. The WM is frozen for the
/// duration; an exec that never exits (a terminal emulator, a game) freezes
/// hana until it does. This is deliberately a config-author opt-in, never the
/// path for a bare single-action binding.
pub fn execSynchronous(cmd: []const u8) void {
    const alloc = core.getState().alloc;

    var cmd_buf: [stack_cmd_capacity]u8 = undefined;
    const resolved = resolveCmdZ(alloc, cmd, &cmd_buf) catch return;
    defer if (resolved.heap) |h| alloc.free(h);
    const cmd_z = resolved.z.ptr;

    const pid = c.fork();
    if (pid < 0) {
        log.err("Fork failed (synchronous exec): {s}", .{cmd});
        return;
    }
    if (pid == 0) {
        // Single-fork child: inherits stdio, stays re-parentable to the WM
        // so waitpid below actually observes its exit. No detach, no pipe.
        execShell(cmd_z);
        std.process.exit(127);
    }

    var status: c_int = 0;
    while (true) {
        const rc = c.waitpid(pid, &status, 0);
        switch (std.posix.errno(rc)) {
            .SUCCESS => break,
            .INTR => continue, // SIGCHLD from an unrelated child interrupts; retry.
            else => {
                log.err("waitpid failed (synchronous exec): {s}", .{cmd});
                return;
            },
        }
    }
}
