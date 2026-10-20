//! Detached command spawning for `exec` actions: fork+setsid, WM as subreaper,
//! O_CLOEXEC pipe for outcome reporting; PIDs tracked and reaped in event loop.

const std = @import("std");
const builtin = @import("builtin");

// libc bindings for fork/exec/wait/prctl (no Zig stdlib wrappers exist for these
// low-level syscalls)
const c = @cImport({
    @cInclude("unistd.h");
    @cInclude("sys/wait.h");
    @cInclude("sys/prctl.h");
});

/// Installs hana as a child subreaper (PR_SET_CHILD_SUBREAPER), once, before
/// anything forks.
///
/// Without it a single-fork spawn leaves the WM as the parent of every command
/// it launches, and those commands' own orphaned grandchildren re-parent to
/// init -- which is fine, except init is not the only thing that can exit: in
/// a container the reaper is whatever PID 1 is, and a subreaper here means the
/// orphan comes to hana instead, which then has to collect it. That collection
/// is the existing `waitpid(-1, WNOHANG)` sweep in reapPendingChildren, so the
/// subreaper adds no new reaping path -- it only changes who the orphan's
/// parent is, to the one process that already sweeps.
///
/// Idempotent and cheap: one branch per spawn, because the flag is
/// process-wide and cannot meaningfully be re-asserted.
fn ensureSubreaper() void {
    if (builtin.os.tag != .linux) return;
    if (subreaper_installed) return;
    if (c.prctl(c.PR_SET_CHILD_SUBREAPER, @as(c_ulong, 1), @as(c_ulong, 0), @as(c_ulong, 0), @as(c_ulong, 0)) != 0) {
        // Not fatal: the spawn still runs, and the only loss is that an
        // orphaned grandchild goes to init rather than to hana. Worth one
        // line, because it means the subreaper invariant is not in force.
        std.debug.print("hana: prctl(PR_SET_CHILD_SUBREAPER) failed; orphan reaping falls back to init\n", .{});
        return;
    }
    subreaper_installed = true;
}

var subreaper_installed: bool = false;

const core = @import("core");
const log = std.log.scoped(.spawn);
const query = @import("query");
const window = @import("window");
const admission = @import("admission");

const bounded = @import("bounded");
/// The one message the spawn pipe can carry, and the only value the wire
/// format defines. `pub` because it IS the protocol: it is the byte the child
/// writes, and the tests assert against it so a change to the value cannot
/// leave them green while exercising something the child never sends.
pub const tag_failed: u8 = 1;

/// Writes the tag_failed byte to the spawn pipe and exits: the signal that
/// resolves this spawn as failed. The only post-fork failure path.
fn failWithTag(pipe_write: c_int) noreturn {
    const msg = [1]u8{tag_failed};
    _ = c.write(pipe_write, &msg, msg.len);
    _ = c.close(pipe_write);
    std.process.exit(1);
}

/// Creates a pipe with O_NONBLOCK | O_CLOEXEC on both ends via pipe2(2).
///
/// Shared by the detached-spawn plumbing here and the signal self-pipe
/// (process.zig), avoiding byte-equivalent copies of this in each.
pub fn makePipe() ![2]std.posix.fd_t {
    var fds: [2]std.posix.fd_t = undefined;
    const flags = std.os.linux.O{ .CLOEXEC = true, .NONBLOCK = true };
    switch (std.posix.errno(std.os.linux.pipe2(&fds, flags))) {
        .SUCCESS => {},
        .MFILE => return error.ProcessFdQuotaExceeded,
        .NFILE => return error.SystemFdQuotaExceeded,
        else => |err| return std.posix.unexpectedErrno(err),
    }
    return fds;
}

/// execvp of `cmd` through `/bin/sh -c`; failures fall through to the caller's
/// own exit/tag path.
fn execShell(cmd_z: [*:0]const u8) void {
    _ = c.execvp("/bin/sh", @ptrCast(&[_:null]?[*:0]const u8{ "/bin/sh", "-c", cmd_z, null }));
}

/// Child of the WM: detaches from the WM's session and execs the command.
/// On execvp failure, writes a tag_failed byte to pipe_write before exiting.
/// On success this function never returns far enough to write anything;
/// pipe_write's O_CLOEXEC copy closes itself as part of the exec.
fn execDetached(pipe_write: c_int, cmd_z: [*:0]const u8) noreturn {
    // setsid() makes the child a session leader, so an `exec` of a terminal
    // emulator can acquire a controlling terminal.
    _ = c.setsid();
    execShell(cmd_z);
    failWithTag(pipe_write);
}

// Pending spawn table (max 16 in-flight spawns).

const max_pending_spawns: usize = 16;

/// Commands shorter than this are null-terminated on the stack; longer ones
/// are copied to the heap so executeShellCommand stays allocation-free for
/// the common short-command case. Unmeasured: chosen generous -- 255 bytes
/// covers every binding action line hana ships, and longer commands take the
/// heap path by design rather than failing.
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

/// Largest possible spawn-pipe conversation: a single tag_failed byte.
const spawn_msg_max: usize = 1;

/// Longest command text kept per pending spawn, for diagnostics. Without it,
/// a failed spawn would report nothing at all (or, for a wedged pipe,
/// silence forever), leaving no way to tell "the command failed" from "hana
/// lost track of the command". Unmeasured: 96 bytes wraps a typical action
/// line into the two-line warn without dominating it; longer commands are
/// truncated head-first by design.
const cmd_report_max: usize = 96;

/// How long a pending entry may stay unresolved before it is dropped as stuck
/// The whole conversation is a few bytes between two forks of the same
/// parent, so anything still open after this has already lost the outcome; a
/// table of 16 such entries is a permanent wedge on `exec` (every later spawn
/// refused with SpawnQueueFull).
const spawn_timeout_ms: i64 = 5_000;

/// Lifecycle state for a single spawn.
const PendingSpawn = struct {
    pid: c_int, // PID of the spawned process; also the registerSpawn target.
    spawn_fd: ?c_int, // Read end of the spawn pipe (O_NONBLOCK). null once done.
    buf: [spawn_msg_max]u8 = undefined, // Accumulates bytes until the conversation ends.
    len: usize = 0, // Valid bytes accumulated in buf so far.
    spawn_ws: ?u8, // Target workspace for window.registerSpawn.
    /// Truncated command text (not NUL-terminated; use `cmd_len`). Present
    /// only so finishSpawn's failure report and the stuck-entry expiry can
    /// say WHICH command they are talking about.
    cmd: [cmd_report_max]u8 = undefined,
    cmd_len: u8 = 0,
    /// Monotonic start of this entry, for the stuck-entry deadline.
    started_ms: i64 = 0,

    fn command(self: *const PendingSpawn) []const u8 {
        return self.cmd[0..self.cmd_len];
    }
};

// std.BoundedArray was removed in the Zig 0.16 toolchain; bounded.BoundedList
// is the shared fixed-buffer-plus-length stand-in used everywhere this shape
// is needed.
var g_pending: bounded.BoundedList(PendingSpawn, max_pending_spawns) = .{};

/// Spawns `cmd` as a detached child. Returns immediately;
/// lifecycle is tracked in g_pending and resolved by drainPendingSpawns() /
/// reapPendingChildren() without blocking the event loop.
pub fn executeShellCommand(cmd: []const u8) !void {
    // Snapshot the workspace now; correct for sequence actions of the form
    // [exec, switch_workspace] where a later action mutates g_current.
    const spawn_ws = query.getCurrentWorkspace();

    var cmd_buf: [stack_cmd_capacity]u8 = undefined;
    const resolved = try resolveCmdZ(core.getState().alloc, cmd, &cmd_buf);
    defer if (resolved.heap) |h| core.getState().alloc.free(h);
    const cmd_z = resolved.z.ptr;

    // Refuse up front instead of fork-then-discover-the-table-is-full: forking
    // first would fall back to a synchronous waitpid on the event loop and
    // silently drop workspace routing for the spawn.
    if (g_pending.len >= max_pending_spawns) {
        log.err("spawn: pending spawn table full, rejecting '{s}'", .{cmd});
        return error.SpawnQueueFull;
    }

    const pipe_fds = makePipe() catch {
        log.err("pipe2() failed (spawn pipe): {s}", .{cmd});
        return error.PipeFailed;
    };

    ensureSubreaper();
    const pid = c.fork();
    if (pid < 0) {
        _ = c.close(pipe_fds[0]);
        _ = c.close(pipe_fds[1]);
        log.err("First fork failed: {s}", .{cmd});
        return error.ForkFailed;
    }

    if (pid == 0) {
        // Child: keep pipe_write open rather than closing it up front. Its
        // copy is O_CLOEXEC, so a successful execvp() closes it for us;
        // execDetached only writes to it explicitly if exec fails.
        _ = c.close(pipe_fds[0]);
        execDetached(pipe_fds[1], cmd_z);
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
        .started_ms = core.monotonicMs(),
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
/// The event loop polls exactly these fds, which is what keeps the spawn
/// hand-off free of unbounded latency: without that, a spawn whose output is
/// ready but which produced no X event and no signal would wait for the next
/// unrelated wakeup, because the pipe is only drained from inside the X event
/// batch (`drainPendingSpawns` at the end of `handleXcbEvents`), from
/// SIGCHLD, and on poll timeouts (the `nextDeadlineMs` stuck-entry wakeup).
/// A command that prints and exits while the X socket stays silent would
/// then stall until some other client happens to talk to the server.
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

/// Nearest stuck-entry deadline across `g_pending`, in ms from now, or null
/// when nothing is pending with a start time. Fed into the core Timers list
/// (events.zig) so an idle event loop still wakes in time for
/// `drainPendingSpawns` to drop a wedged entry at `spawn_timeout_ms`; without
/// this the sweep only ran when some spawn fd happened to go ready, and a
/// fully wedged queue stayed wedged behind `SpawnQueueFull` until unrelated
/// X traffic arrived.
pub fn nextDeadlineMs() ?i32 {
    if (g_pending.len == 0) return null;
    const now = core.monotonicMs();
    var nearest: ?i64 = null;
    for (g_pending.slice()) |*entry| {
        if (entry.started_ms == 0) continue;
        const remaining = spawn_timeout_ms - (now - entry.started_ms);
        if (nearest == null or remaining < nearest.?) nearest = remaining;
    }
    if (nearest == null) return null;
    // Already overdue: wake on the next poll turn (0), never negative.
    const ms = nearest.?;
    if (ms <= 0) return 0;
    if (ms > std.math.maxInt(i32)) return std.math.maxInt(i32);
    return @intCast(ms);
}

/// Drains pending spawn entries non-blockingly (every event batch, on SIGCHLD,
/// on spawn-pipe readiness, and on poll timeouts that the `nextDeadlineMs`
/// stuck-entry deadline produced), until EOF or a full buffer; a full buffer
/// already holds both possible messages, so EOF needn't be awaited.
/// finishSpawn() classifies.
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

        // The pipe closing is not a deadline. A stuck entry (pipe open,
        // or closed with the child never reaped) is dropped once it is older
        // than spawn_timeout_ms, so 16 stuck entries cannot wedge `exec`
        // forever behind SpawnQueueFull.
        if (entry.started_ms != 0 and core.monotonicMs() - entry.started_ms > spawn_timeout_ms) {
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
        // `drained_pid` captures the real pid before any clearing --
        // finishSpawn passes it to registerSpawn, where a -1 would @intCast
        // into a huge u32. `pid` is cleared only when waitpid actually reaped
        // it: a WNOHANG that returns 0 (the child closed its fd but has not
        // exited yet) is not a reap. Zombies are collected by the
        // waitpid(-1) sweep in reapPendingChildren, never by bookkeeping here.
        const drained_pid = entry.pid;
        if (entry.pid > 0 and c.waitpid(entry.pid, null, c.WNOHANG) > 0)
            entry.pid = -1;

        finishSpawn(entry, drained_pid);
        g_pending.swapRemove(i);
    }
}

/// Decides whether a fully-drained spawn-pipe conversation means the exec
/// failed. Pure, so the rule can be tested without forking anything.
///
/// The child's only message is `tag_failed`, written just before it exits when
/// execvp failed. A SUCCESSFUL exec closes the O_CLOEXEC write end instead, so
/// the parent sees clean EOF. The rule is therefore: BYTES MEAN FAILURE, NO
/// BYTES MEAN SUCCESS. There is no byte pattern that can mean success, because
/// success is the absence of a message, and that asymmetry is the whole reason
/// the predicate is `len != 0` rather than a comparison against the tag.
///
/// Both writes are under PIPE_BUF, so a tag_failed byte is never torn or
/// interleaved; `buf` is one byte, so at most one arrives.
pub fn conversationFailed(data: []const u8) bool {
    return data.len != 0;
}

/// Applies a fully-drained conversation: on success, registers the spawn for
/// workspace routing; on failure, says which command did not launch.
fn finishSpawn(entry: *PendingSpawn, pid: i32) void {
    const data = entry.buf[0..entry.len];

    if (conversationFailed(data)) {
        // `entry.cmd` is the truncated command, so the report is actionable:
        // which command, and that execvp is what failed.
        log.warn("spawn failed: '{s}' (exec did not succeed)", .{entry.command()});
        return;
    }
    if (entry.spawn_ws) |ws| {
        admission.registerSpawn(core.WorkspaceId.fromIndex(ws), @intCast(pid));
    }
}

/// Reaps zombie children without blocking. Called from the
/// SIGCHLD handler; the spawn-pipe drain stays in process.zig so it doesn't
/// run twice per SIGCHLD.
pub fn reapPendingChildren() void {
    // ONE reaper path. The per-pid loop alone was not enough -- a SIGCHLD
    // that arrived for a pid hana no longer had a pending entry for (the
    // entry was removed on pipe-close, and an early version cleared `pid`
    // before the child was actually reaped) was a zombie nothing would ever
    // collect. waitpid(-1, WNOHANG) sweeps every child hana owns, so the
    // hand-off is idempotent and cannot miss one; it returns -ECHILD the
    // moment hana has no unreaped children, which is a cheap no-op.
    //
    // This sweep is also what makes the subreaper safe: an orphaned
    // grandchild of a launched app re-parents to hana, and hana has no
    // PendingSpawn entry for it at all -- only this waitpid(-1) ever collects
    // it.
    while (c.waitpid(-1, null, c.WNOHANG) > 0) {}

    // Do NOT clear entry.pid for reaped children here: the drain loop below
    // still needs the real pid for finishSpawn's registerSpawn, and it keeps
    // its own copy before any clearing. The waitpid(-1) sweep above is the
    // reap; the per-pid entries are only used at drain time.
}

/// Runs `cmd` to completion before returning, for `,`-sequenced exec steps.
///
/// Unlike executeShellCommand (fire-and-forget detach), this single-fork keeps
/// the child a direct child and BLOCKS the caller -- and therefore the WM
/// event loop -- on waitpid until the command exits. That is the whole point:
/// a `,` sequence step is only "done" once its exec has fully finished, so the
/// next step starts against a completed state. The WM is frozen for the
/// duration, so the wait is WALL-CLOCK CAPPED: at `sync_exec_timeout_ms` the
/// child is SIGKILLed and a warn is logged (a `sleep 60` bind can no longer
/// freeze hana past the cap). The killed child is reaped here on a short
/// grace loop, and by the normal waitpid(-1) sweep if it lingers in
/// uninterruptible sleep. This is deliberately a config-author opt-in, never
/// the path for a bare single-action binding; config lint warns when a bind
/// routes here (binds.zig's containsSyncExec).
pub const sync_exec_timeout_ms = 5000;

pub fn execSynchronous(alloc: std.mem.Allocator, cmd: []const u8) void {
    execSynchronousBounded(alloc, cmd, sync_exec_timeout_ms);
}

/// The timeout-injectable wait behind execSynchronous (test seam: a `sleep 60`
/// must not cost a 5s stall in the suite). See execSynchronous for the policy.
pub fn execSynchronousBounded(alloc: std.mem.Allocator, cmd: []const u8, timeout_ms: i64) void {
    var cmd_buf: [stack_cmd_capacity]u8 = undefined;
    const resolved = resolveCmdZ(alloc, cmd, &cmd_buf) catch return;
    defer if (resolved.heap) |h| alloc.free(h);
    const cmd_z = resolved.z.ptr;

    ensureSubreaper();
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
    const deadline_ms = core.monotonicMs() + timeout_ms;
    while (true) {
        const rc = c.waitpid(pid, &status, c.WNOHANG);
        if (rc == pid) return; // exited and reaped
        if (rc < 0) {
            switch (std.posix.errno(rc)) {
                .INTR => continue,
                else => {
                    log.err("waitpid failed (synchronous exec): {s}", .{cmd});
                    return;
                },
            }
        }
        // rc == 0: still running. Enforce the deadline.
        if (core.monotonicMs() >= deadline_ms) {
            log.warn("sync_exec timed out after {d}ms; killing: '{s}'", .{ timeout_ms, cmd });
            _ = c.kill(pid, c.SIGKILL);
            // Bounded reap grace: SIGKILL lands unless the child is stuck in
            // uninterruptible sleep; in that case the waitpid(-1) sweep in
            // reapPendingChildren collects it later, so we must not block
            // the WM again waiting for it here.
            var grace: usize = 0;
            while (grace < 50) : (grace += 1) { // ~500ms of 10ms naps
                const r2 = c.waitpid(pid, &status, c.WNOHANG);
                if (r2 == pid or r2 < 0) return;
                syncNap();
            }
            return;
        }
        syncNap();
    }
}

/// One 10ms pause between sync_exec waitpid polls. nanosleep directly (the
/// XKB retry path sleeps the same way); EINTR just re-polls sooner.
fn syncNap() void {
    var req = std.os.linux.timespec{ .sec = 0, .nsec = 10 * std.time.ns_per_ms };
    var rem = std.os.linux.timespec{ .sec = 0, .nsec = 0 };
    _ = std.os.linux.nanosleep(&req, &rem);
}
