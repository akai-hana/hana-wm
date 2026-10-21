//! Detached command spawning for `exec` actions: fork+setsid, WM as subreaper,
//! O_CLOEXEC pipe for outcome reporting; PIDs tracked and reaped in event loop.

const std = @import("std");
const builtin = @import("builtin");

// libc bindings for fork/exec/wait/prctl (no stdlib wrappers exist).
const c = @cImport({
    @cInclude("unistd.h");
    @cInclude("sys/wait.h");
    @cInclude("sys/prctl.h");
});

/// Installs hana as a child subreaper (PR_SET_CHILD_SUBREAPER), once, before
/// anything forks. Without it an orphaned grandchild re-parents to init/PID 1
/// (which may itself be short-lived in a container); with it the orphan comes
/// to hana, whose existing waitpid(-1) sweep in reapPendingChildren already
/// collects it -- no new reaping path, only a different parent. Idempotent:
/// the flag is process-wide, so one branch.
fn ensureSubreaper() void {
    if (builtin.os.tag != .linux) return;
    if (subreaper_installed) return;
    if (c.prctl(c.PR_SET_CHILD_SUBREAPER, @as(c_ulong, 1), @as(c_ulong, 0), @as(c_ulong, 0), @as(c_ulong, 0)) != 0) {
        // Not fatal: the spawn still runs; the only loss is orphaned
        // grandchildren falling back to init (the subreaper invariant is off).
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
/// The spawn pipe's only message. `pub` because it IS the protocol: the tests
/// assert against it, so changing the value cannot leave them green.
pub const tag_failed: u8 = 1;

/// Writes tag_failed and exits: the only post-fork failure path.
fn failWithTag(pipe_write: c_int) noreturn {
    const msg = [1]u8{tag_failed};
    _ = c.write(pipe_write, &msg, msg.len);
    _ = c.close(pipe_write);
    std.process.exit(1);
}

/// Creates a pipe with O_NONBLOCK | O_CLOEXEC on both ends via pipe2(2).
/// Shared with the signal self-pipe (process.zig).
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

/// execvp of `cmd` through `/bin/sh -c`; failures fall to the caller's exit/tag path.
fn execShell(cmd_z: [*:0]const u8) void {
    _ = c.execvp("/bin/sh", @ptrCast(&[_:null]?[*:0]const u8{ "/bin/sh", "-c", cmd_z, null }));
}

/// Child of the WM: detaches and execs the command. On execvp failure it
/// writes tag_failed to pipe_write; on success O_CLOEXEC closes that end as
/// part of the exec, so nothing is ever written.
fn execDetached(pipe_write: c_int, cmd_z: [*:0]const u8) noreturn {
    // setsid() makes the child a session leader so a terminal emulator can
    // acquire a controlling terminal.
    _ = c.setsid();
    execShell(cmd_z);
    failWithTag(pipe_write);
}

const max_pending_spawns: usize = 16;

/// Stack buffer for the common short command; longer ones go to the heap so
/// executeShellCommand stays allocation-free. Generous unmeasured bound.
const stack_cmd_capacity: usize = 256;

/// Nul-terminated command from `resolveCmdZ`; `heap` is the owning allocation
/// when the command outgrew the stack buffer (`z` then aliases it).
const ResolvedCmd = struct {
    z: [:0]const u8,
    heap: ?[:0]const u8 = null,
};

/// Copies `cmd` nul-terminated into the stack buffer, else a heap dupe the caller frees.
fn resolveCmdZ(alloc: std.mem.Allocator, cmd: []const u8, buf: *[stack_cmd_capacity]u8) !ResolvedCmd {
    if (cmd.len < buf.len)
        return .{ .z = try std.fmt.bufPrintZ(buf, "{s}", .{cmd}) };
    const heap = try alloc.dupeZ(u8, cmd);
    return .{ .z = heap, .heap = heap };
}

/// Largest possible spawn-pipe conversation: a single tag_failed byte.
const spawn_msg_max: usize = 1;

/// Command text kept per pending spawn for diagnostics (truncated head-first):
/// without it a failed or wedged spawn could not say WHICH command it meant.
const cmd_report_max: usize = 96;

/// How long a pending entry may stay unresolved before it is dropped as
/// stuck. The conversation is a few bytes between two forks of one parent, so
/// anything open past this has lost the outcome; 16 wedged entries would
/// refuse every later `exec` with SpawnQueueFull.
const spawn_timeout_ms: i64 = 5_000;

const PendingSpawn = struct {
    pid: c_int, // PID of the spawned process; also the registerSpawn target.
    spawn_fd: ?c_int, // Read end of the spawn pipe (O_NONBLOCK). null once done.
    buf: [spawn_msg_max]u8 = undefined, // Accumulates bytes until the conversation ends.
    len: usize = 0,
    spawn_ws: ?u8, // Target workspace for window.registerSpawn.
    /// Truncated command text (not NUL-terminated; use `cmd_len`) so failure
    /// reports and stuck-entry expiry can name the command.
    cmd: [cmd_report_max]u8 = undefined,
    cmd_len: u8 = 0,
    /// Monotonic start of this entry, for the stuck-entry deadline.
    started_ms: i64 = 0,

    fn command(self: *const PendingSpawn) []const u8 {
        return self.cmd[0..self.cmd_len];
    }
};

// bounded.BoundedList is the shared fixed-buffer stand-in (std.BoundedArray
// was removed in Zig 0.16).
var g_pending: bounded.BoundedList(PendingSpawn, max_pending_spawns) = .{};

/// Spawns `cmd` as a detached child, returning immediately; lifecycle is
/// tracked in g_pending and resolved without blocking the event loop.
pub fn executeShellCommand(cmd: []const u8) !void {
    // Snapshot the workspace now; correct for sequence actions of the form
    // [exec, switch_workspace] where a later action mutates g_current.
    const spawn_ws = query.getCurrentWorkspace();

    var cmd_buf: [stack_cmd_capacity]u8 = undefined;
    const resolved = try resolveCmdZ(core.getState().alloc, cmd, &cmd_buf);
    defer if (resolved.heap) |h| core.getState().alloc.free(h);
    const cmd_z = resolved.z.ptr;

    // Refuse up front rather than fork-then-discover the table is full:
    // that path would fall back to a blocking waitpid and drop routing.
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
        // Keep pipe_write open: its copy is O_CLOEXEC, so a successful
        // execvp() closes it; only an exec failure writes to it.
        _ = c.close(pipe_fds[0]);
        execDetached(pipe_fds[1], cmd_z);
    }

    // Parent: close the write end so our read end eventually sees EOF.
    _ = c.close(pipe_fds[1]);

    // Spawn-crossing suppression queries the cursor at MapRequest time
    // (once per window), so no round-trip is needed here.

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

/// Upper bound on `readFds` output so the event loop can size its poll set
/// once; matches the table capacity so a full table is representable.
pub const max_read_fds: usize = max_pending_spawns;

/// Copies the read end of every pending spawn pipe into `buf`; closed entries
/// are skipped so the count can shrink between calls.
///
/// Polling exactly these fds is what keeps the spawn hand-off free of
/// unbounded latency: the pipe is otherwise only drained from X event batches,
/// SIGCHLD, and the `nextDeadlineMs` deadline, so a command that prints and
/// exits while the X socket stays silent would stall until unrelated traffic.
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

/// Nearest stuck-entry deadline across `g_pending`, in ms from now, or null.
/// Fed into the core Timers list so an idle event loop still wakes to drop a
/// wedged entry at `spawn_timeout_ms`; without it a fully wedged queue stayed
/// wedged behind SpawnQueueFull until unrelated X traffic arrived.
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
/// on pipe readiness, and on `nextDeadlineMs` poll timeouts), until EOF or a
/// full buffer -- a full buffer already holds both possible messages, so EOF
/// needn't be awaited. finishSpawn() classifies.
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
                    // Full: both possible messages have arrived; no EOF wait.
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
                // One last WNOHANG reap so a gone-but-unsignaled child leaves no zombie.
                if (c.waitpid(entry.pid, null, c.WNOHANG) > 0) entry.pid = -1;
            }
            g_pending.swapRemove(i);
            continue;
        }

        if (entry.spawn_fd != null) {
            i += 1;
            continue;
        }

        // Pipe EOF means the intermediate child just exited; reap it eagerly
        // (WNOHANG-only, never blocks) instead of waiting for SIGCHLD.
        //
        // `drained_pid` captures the real pid before any clearing: finishSpawn
        // passes it to registerSpawn, where a -1 would @intCast into a huge
        // u32. `pid` clears only when waitpid actually reaped it (WNOHANG==0
        // is not a reap); leftover zombies are the waitpid(-1) sweep's job.
        const drained_pid = entry.pid;
        if (entry.pid > 0 and c.waitpid(entry.pid, null, c.WNOHANG) > 0)
            entry.pid = -1;

        finishSpawn(entry, drained_pid);
        g_pending.swapRemove(i);
    }
}

/// Decides whether a drained spawn-pipe conversation means failure. Pure so
/// the rule is testable without forking.
///
/// The child writes `tag_failed` only when execvp failed; a SUCCESSFUL exec
/// closes the O_CLOEXEC write end, so the parent sees clean EOF. Rule: BYTES
/// MEAN FAILURE, NO BYTES MEAN SUCCESS -- success is the absence of a message,
/// which is why the predicate is `len != 0`, not a tag comparison. Both
/// writes are under PIPE_BUF so a byte is never torn; `buf` holds at most one.
pub fn conversationFailed(data: []const u8) bool {
    return data.len != 0;
}

/// Applies a fully-drained conversation: on success, registers the spawn for
/// workspace routing; on failure, says which command did not launch.
fn finishSpawn(entry: *PendingSpawn, pid: i32) void {
    const data = entry.buf[0..entry.len];

    if (conversationFailed(data)) {
        log.warn("spawn failed: '{s}' (exec did not succeed)", .{entry.command()});
        return;
    }
    if (entry.spawn_ws) |ws| {
        admission.registerSpawn(core.WorkspaceId.fromIndex(ws), @intCast(pid));
    }
}

/// Reaps zombie children without blocking, from the SIGCHLD handler; the
/// spawn-pipe drain stays in process.zig so SIGCHLD doesn't run it twice.
pub fn reapPendingChildren() void {
    // ONE reaper path: waitpid(-1, WNOHANG) sweeps every child hana owns, so
    // a SIGCHLD for a pid with no pending entry (entry removed on pipe-close)
    // can never leave an uncollected zombie. It returns -ECHILD once hana has
    // no unreaped children -- a cheap no-op. This sweep is also what makes
    // the subreaper safe: a re-parented orphan has no PendingSpawn entry, and
    // only this waitpid(-1) ever collects it.
    while (c.waitpid(-1, null, c.WNOHANG) > 0) {}

    // Do NOT clear entry.pid here: the drain loop still needs the real pid for
    // finishSpawn's registerSpawn (it copies it before any clearing).
}

/// Runs `cmd` to completion before returning, for `,`-sequenced exec steps.
///
/// Unlike executeShellCommand (fire-and-forget), this single-fork BLOCKS the
/// WM event loop on waitpid until the command exits -- a `,` step is only
/// "done" once its exec finished. The wait is WALL-CLOCK CAPPED at
/// `sync_exec_timeout_ms` (SIGKILL + warn; the killed child is reaped on a
/// short grace loop, else by the waitpid(-1) sweep). Deliberately a
/// config-author opt-in: config lint warns when a bind routes here
/// (binds.zig's containsSyncExec).
pub const sync_exec_timeout_ms = 5000;

pub fn execSynchronous(alloc: std.mem.Allocator, cmd: []const u8) void {
    execSynchronousBounded(alloc, cmd, sync_exec_timeout_ms);
}

/// The timeout-injectable wait behind execSynchronous (test seam so `sleep 60`
/// need not cost a 5s stall in the suite). Policy: see execSynchronous.
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
            // uninterruptible sleep; then the waitpid(-1) sweep collects it
            // later -- must not block the WM again here.
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

/// One 10ms nanosleep between sync_exec waitpid polls; EINTR re-polls sooner.
fn syncNap() void {
    var req = std.os.linux.timespec{ .sec = 0, .nsec = 10 * std.time.ns_per_ms };
    var rem = std.os.linux.timespec{ .sec = 0, .nsec = 0 };
    _ = std.os.linux.nanosleep(&req, &rem);
}
