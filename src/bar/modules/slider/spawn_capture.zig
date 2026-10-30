//! `/bin/sh` spawn capture: the bar's subprocess runners.
//!
//! `runOut` / `runOk` are the allocation-free racers every spawned control
//! command goes through (pactl / amixer / brightnessctl): run the child,
//! drain its stdout so a full pipe can never stall it, report the bytes (or
//! exit status), and let the caller keep its fixed buffers.
//!
//! Everything here is DEADLINED: the poll loop and the post-EOF wait share one
//! `timeout_ms` budget, and an expiring budget SIGKILLs the child and reports
//! failure. `popen`/`pclose` had no such bound -- a helper wedged on a locked
//! device or a dead daemon socket froze the WM's event loop for the child's
//! entire lifetime. A timed-out run reports total failure (null / empty)
//! rather than truncated output: a partial volume reading is worse than none.

const std = @import("std");
const core = @import("core");

const c = @cImport({
    @cInclude("unistd.h");
    @cInclude("sys/wait.h");
    @cInclude("signal.h");
    @cInclude("poll.h");
});

const log = std.log.scoped(.bar);

/// Hard cap on one captured command (read loop AND post-EOF wait). Control
/// commands answer in single-digit ms when they answer at all; 3 s is the
/// "something is wedged" line, not a performance target.
pub const timeout_ms: i64 = 3_000;

/// How long a SIGKILLed child gets to become reapable. A zombie left behind
/// is collected by the WM's `waitpid(-1)` sweep on the next SIGCHLD, so
/// abandoning it is safe -- only the exit STATUS is lost.
const kill_grace_ms: i64 = 200;

fn nowMs() i64 {
    return core.monotonicMs();
}

/// Polls `waitpid` until `pid` is reaped or `deadline` passes. True when it
/// exited 0, null on timeout. ECHILD (another reap path got there first) is
/// "ran, status unknown" -- NOT ok, the verdict `pclose == -1` produced.
fn reap(pid: c_int, deadline: i64) ?bool {
    var status: c_int = 0;
    while (true) {
        const r = c.waitpid(pid, &status, c.WNOHANG);
        if (r == pid) return c.WIFEXITED(status) and c.WEXITSTATUS(status) == 0;
        if (r < 0) return false;
        if (nowMs() >= deadline) return null;
        // One short pause. EINTR returns early: the WM's SIGCHLD handler fires
        // precisely when the child became waitable, and the loop re-checks.
        const req = std.os.linux.timespec{ .sec = 0, .nsec = std.time.ns_per_ms };
        _ = std.os.linux.nanosleep(&req, null);
    }
}

/// Runs `cmd` via /bin/sh, drains its stdout into `sink` (the remainder goes
/// to scratch so the child always reaches EOF), and reports the bytes
/// captured plus whether the child exited 0. Null on any failure: command
/// longer than the fixed 256-byte buffer, fork/pipe denied, or deadline hit.
fn spawnCapture(cmd: []const u8, sink: []u8, budget_ms: i64) ?struct { bytes: usize, exit_ok: bool } {
    if (cmd.len + 1 > 256) return null;
    var cmd_buf: [256]u8 = undefined;
    @memcpy(cmd_buf[0..cmd.len], cmd);
    cmd_buf[cmd.len] = 0;
    const cmd_z: [*:0]const u8 = @ptrCast(&cmd_buf);

    var fds: [2]std.posix.fd_t = undefined;
    if (std.posix.errno(std.os.linux.pipe2(&fds, .{ .CLOEXEC = true })) != .SUCCESS) return null;

    const pid = c.fork();
    if (pid < 0) {
        _ = c.close(fds[0]);
        _ = c.close(fds[1]);
        return null;
    }
    if (pid == 0) {
        // Child: stdout into the pipe, stderr inherited (as `popen` did).
        // Async-signal-safe only: dup2, close, execvp.
        _ = c.close(fds[0]);
        if (c.dup2(fds[1], c.STDOUT_FILENO) < 0) std.process.exit(127);
        _ = c.close(fds[1]);
        _ = c.execvp("/bin/sh", @ptrCast(&[_:null]?[*:0]const u8{ "/bin/sh", "-c", cmd_z, null }));
        std.process.exit(127);
    }

    _ = c.close(fds[1]);
    const deadline = nowMs() + budget_ms;
    var total: usize = 0;
    var scratch: [256]u8 = undefined;
    var eof = false;
    while (!eof) {
        const left = deadline - nowMs();
        if (left <= 0) break;
        var pfd = c.pollfd{ .fd = fds[0], .events = c.POLLIN, .revents = 0 };
        const pr = c.poll(&pfd, 1, @intCast(@min(left, std.math.maxInt(c_int))));
        if (pr < 0 and std.posix.errno(pr) == .INTR) continue;
        if (pr <= 0) break; // hard fd error or deadline
        const room = total < sink.len;
        const dst = if (room) sink[total..] else scratch[0..];
        const n = c.read(fds[0], dst.ptr, dst.len);
        if (n > 0) {
            if (room) total += @intCast(n);
        } else if (n == 0) {
            eof = true;
        } else if (std.posix.errno(n) != .INTR) break;
    }
    _ = c.close(fds[0]);

    // EOF means the pipe is gone; only the exit remains, inside the same
    // budget (a stray background holder must not park the loop either).
    if (eof) if (reap(pid, deadline)) |ok| return .{ .bytes = total, .exit_ok = ok };
    log.warn("spawn_capture: '{s}' exceeded {d}ms, killing", .{ cmd, budget_ms });
    _ = c.kill(pid, c.SIGKILL);
    _ = reap(pid, nowMs() + kill_grace_ms);
    return null;
}

/// Runs `cmd` and returns its stdout trimmed of trailing whitespace, or an
/// empty slice on any failure.
pub fn runOutFor(cmd: []const u8, buf: []u8, budget_ms: i64) []const u8 {
    const cap = spawnCapture(cmd, buf, budget_ms) orelse return "";
    return std.mem.trimEnd(u8, buf[0..cap.bytes], " \n\r");
}

pub fn runOut(cmd: []const u8, buf: []u8) []const u8 {
    return runOutFor(cmd, buf, timeout_ms);
}

/// Runs `cmd`, discarding its output; true when it exited 0.
pub fn runOk(cmd: []const u8) bool {
    var sink: [64]u8 = undefined;
    const cap = spawnCapture(cmd, &sink, timeout_ms) orelse return false;
    return cap.exit_ok;
}
