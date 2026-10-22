//! `/bin/sh` spawn capture: the bar's subprocess runners.
//!
//! `runOut` / `runOk` are the allocation-free racers every spawned control
//! command goes through (pactl / amixer / brightnessctl). They were lifted
//! out of the slider package when the split made it plain that nothing here
//! is slider-specific: run the child, drain its stdout so a full pipe can
//! never stall it, report the bytes (or exit status), and let the caller keep
//! its fixed buffers. Anything in the bar that needs to run a command and
//! read its output belongs here.
//!
//! Everything here is DEADLINED: the poll loop and the post-EOF wait share one
//! `timeout_ms` budget, and an expiring budget SIGKILLs the child and reports
//! failure. `popen`/`pclose` had no such bound -- a helper wedged on a locked
//! device or a dead daemon socket froze the WM's event loop for the child's
//! entire lifetime, and popen exposes no pid to break it out. A timed-out run
//! reports total failure (null / empty) rather than truncated output: a
//! partial volume reading is worse than no reading.

const std = @import("std");
const core = @import("core");

const c = @cImport({
    @cInclude("unistd.h");
    @cInclude("sys/wait.h");
    @cInclude("signal.h");
    @cInclude("poll.h");
});

const log = std.log.scoped(.bar);

/// Hard cap on one captured command, covering the read loop AND the wait for
/// the child to exit after EOF. Control commands answer in single-digit
/// milliseconds when they answer at all; 3 s is the "something is wedged"
/// line, not a performance target.
pub const timeout_ms: i64 = 3_000;

/// How long a SIGKILLed child gets to become reapable before this runner
/// gives up on collecting it. A zombie left behind here is collected by the
/// WM's `waitpid(-1)` sweep on the next SIGCHLD, so abandoning is safe --
/// only the exit STATUS is lost, and the run has already been failed.
const kill_grace_ms: i64 = 200;

/// Monotonic ms for the deadline, inlined over the clock (no WM state).
fn nowMs() i64 {
    return core.monotonicMs();
}

/// Runs `cmd` via /bin/sh, drains its stdout into `sink` (so the child can
/// never block on a full pipe), and reports the bytes captured plus whether
/// the child exited 0. Null on any failure: the command is too long for the
/// fixed 256-byte buffer, the fork/pipe was denied, or the deadline expired.
/// Shared body of `runOut`/`runOk`.
fn spawnCapture(cmd: []const u8, sink: []u8, budget_ms: i64) ?struct { bytes: usize, exit_ok: bool } {
    if (cmd.len + 1 > 256) return null;
    var cmd_buf: [256]u8 = undefined;
    @memcpy(cmd_buf[0..cmd.len], cmd);
    cmd_buf[cmd.len] = 0;
    const cmd_z: [*:0]const u8 = @ptrCast(&cmd_buf);

    var fds: [2]std.posix.fd_t = undefined;
    const flags = std.os.linux.O{ .CLOEXEC = true };
    switch (std.posix.errno(std.os.linux.pipe2(&fds, flags))) {
        .SUCCESS => {},
        else => return null,
    }

    const pid = c.fork();
    if (pid < 0) {
        _ = c.close(fds[0]);
        _ = c.close(fds[1]);
        return null;
    }
    if (pid == 0) {
        // Child: stdout into the pipe; stderr stays inherited, exactly as
        // `popen(cmd, "r")` behaved. Async-signal-safe only: dup2, close,
        // execvp -- no allocation, no stdio, matching the fork-in-a-WM rule.
        _ = c.close(fds[0]);
        if (c.dup2(fds[1], c.STDOUT_FILENO) < 0) std.process.exit(127);
        _ = c.close(fds[1]);
        _ = c.execvp("/bin/sh", @ptrCast(&[_:null]?[*:0]const u8{ "/bin/sh", "-c", cmd_z, null }));
        std.process.exit(127);
    }

    _ = c.close(fds[1]);
    const read_fd = fds[0];
    const deadline = nowMs() + budget_ms;

    // Read loop: poll with the remaining budget, then read what is ready.
    // `sink` fills first; the remainder drains into scratch (as before) so
    // the child always reaches EOF instead of wedging on a full pipe.
    var total: usize = 0;
    var eof = false;
    read: while (true) {
        const left = deadline - nowMs();
        if (left <= 0) break;
        var pfd = c.pollfd{ .fd = read_fd, .events = c.POLLIN, .revents = 0 };
        const pr = c.poll(&pfd, 1, @intCast(@min(left, std.math.maxInt(c_int))));
        if (pr < 0) {
            if (std.posix.errno(pr) == .INTR) continue;
            break; // hard fd error: treat as end-of-stream
        }
        if (pr == 0) break; // deadline
        if (total < sink.len) {
            const n = c.read(read_fd, sink.ptr + total, sink.len - total);
            if (n > 0) {
                total += @intCast(n);
                continue;
            } else if (n == 0) {
                eof = true;
                break :read;
            } else if (std.posix.errno(n) == .INTR) {
                continue;
            } else {
                break :read;
            }
        } else {
            var scratch: [256]u8 = undefined;
            const n = c.read(read_fd, &scratch, scratch.len);
            if (n > 0) continue;
            if (n == 0) {
                eof = true;
                break :read;
            }
            if (std.posix.errno(n) != .INTR) break :read;
        }
    }
    _ = c.close(read_fd);

    if (!eof) {
        // Deadline expired with the pipe still open: the child is wedged.
        // SIGKILL, then a short grace for the reap; if even that expires the
        // zombie belongs to the WM's sweep and the status is abandoned.
        log.warn("spawn_capture: '{s}' exceeded {d}ms, killing", .{ cmd, budget_ms });
        _ = c.kill(pid, c.SIGKILL);
        _ = reapBounded(pid, kill_grace_ms);
        return null;
    }

    // EOF means the pipe is gone; only the child's exit remains. Wait inside
    // the same budget -- a command that closes stdout but keeps running
    // (a stray background holder, a shell waiting on a wedged grandchild)
    // must not park the loop either.
    if (collectExit(pid, deadline)) |ok| return .{ .bytes = total, .exit_ok = ok };
    log.warn("spawn_capture: '{s}' did not exit within {d}ms after output, killing", .{ cmd, budget_ms });
    _ = c.kill(pid, c.SIGKILL);
    _ = reapBounded(pid, kill_grace_ms);
    return null;
}

/// One short pause between `waitpid` polls. Uses nanosleep directly;
/// `std.time.sleep`/`std.Thread.sleep` are absent in this Zig build (the XKB
/// probe sleeps the same way). Returns immediately on EINTR -- the WM's
/// SIGCHLD handler interrupts it precisely when the child became waitable,
/// and the caller's loop re-checks `waitpid` anyway.
fn napOnce() void {
    const req = std.os.linux.timespec{ .sec = 0, .nsec = std.time.ns_per_ms };
    var rem = std.os.linux.timespec{ .sec = 0, .nsec = 0 };
    _ = std.os.linux.nanosleep(&req, &rem);
}

/// Reaps `pid` after EOF, polling inside `deadline`. Returns the exit-zero
/// verdict, or null when the deadline expires first. ECHILD (some other reap
/// path got there first) reports "ran, status unknown" as NOT ok -- the same
/// verdict `pclose == -1` produced.
fn collectExit(pid: c_int, deadline: i64) ?bool {
    var status: c_int = 0;
    while (true) {
        const r = c.waitpid(pid, &status, c.WNOHANG);
        if (r == pid) return c.WIFEXITED(status) and c.WEXITSTATUS(status) == 0;
        if (r < 0) return false;
        if (nowMs() >= deadline) return null;
        napOnce();
    }
}

/// SIGKILLed children exit promptly; poll for up to `budget_ms` so the
/// common case reaps its own zombie. Returns whether it was collected.
fn reapBounded(pid: c_int, budget_ms: i64) bool {
    const deadline = nowMs() + budget_ms;
    var status: c_int = 0;
    while (nowMs() < deadline) {
        const r = c.waitpid(pid, &status, c.WNOHANG);
        if (r == pid) return true;
        if (r < 0) return false;
        napOnce();
    }
    return false;
}

/// Runs `cmd` via /bin/sh and returns its captured stdout, trimmed of
/// trailing whitespace. Empty slice on any failure (fork/pipe denied, the
/// child wrote nothing, the command is too long for the fixed buffer, or the
/// deadline expired).
pub fn runOut(cmd: []const u8, buf: []u8) []const u8 {
    const cap = spawnCapture(cmd, buf, timeout_ms) orelse return "";
    if (cap.bytes == 0) return "";
    return std.mem.trimEnd(u8, buf[0..cap.bytes], " \n\r");
}

/// Runs `cmd`, drains its output (so the child can never block on a full
/// pipe), and returns whether the child exited 0.
pub fn runOk(cmd: []const u8) bool {
    var sink: [64]u8 = undefined;
    const cap = spawnCapture(cmd, &sink, timeout_ms) orelse return false;
    return cap.exit_ok;
}

/// Test seam: the runner with an injected deadline, so the timeout path is
/// testable without waiting out the production budget. Everything else is
/// identical to `runOut`.
pub fn runOutWithTimeoutForTest(cmd: []const u8, buf: []u8, budget_ms: i64) []const u8 {
    const cap = spawnCapture(cmd, buf, budget_ms) orelse return "";
    if (cap.bytes == 0) return "";
    return std.mem.trimEnd(u8, buf[0..cap.bytes], " \n\r");
}
