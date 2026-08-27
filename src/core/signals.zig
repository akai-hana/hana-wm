//! Signal self-pipe and dispatch.
//! Routes POSIX signals through a self-pipe so the event loop can dispatch them safely.

const std = @import("std");

const utils = @import("utils");
const spawn = @import("spawn");
const restart = @import("restart");

// End indices of the self-pipe: signal handlers write to pipe_write; the
// event loop polls pipe_read.
const pipe_read = 0;
const pipe_write = 1;

var signal_pipe: [2]std.posix.fd_t = .{ -1, -1 };

// Async-signal-safe handler: writes the signal number as a byte to the pipe.
fn signalHandler(signo: std.posix.SIG) callconv(.c) void {
    const byte: u8 = @intCast(@intFromEnum(signo));
    _ = std.os.linux.write(signal_pipe[pipe_write], &[_]u8{byte}, 1);
}

/// Creates the signal self-pipe and installs handlers for SIGHUP/SIGTERM/SIGINT/SIGCHLD.
pub fn setup() !void {
    signal_pipe = try utils.makePipe();
    utils.setSignalWriteFd(signal_pipe[pipe_write]);

    const sa: std.posix.Sigaction = .{
        .handler = .{ .handler = signalHandler },
        .mask = std.posix.sigemptyset(),
        .flags = std.posix.SA.RESTART,
    };

    // SIGCHLD is reaped in dispatchSignal; the rest control the event loop.
    inline for (.{ std.posix.SIG.HUP, std.posix.SIG.TERM, std.posix.SIG.INT, std.posix.SIG.CHLD, std.posix.SIG.USR1 }) |sig|
        std.posix.sigaction(sig, &sa, null);
}

// Closes both ends of the signal pipe.
pub fn deinit() void {
    utils.setSignalWriteFd(-1);
    for (&signal_pipe) |*fd| {
        if (fd.* == -1) continue;
        _ = std.os.linux.close(fd.*);
        fd.* = -1;
    }
}

/// Read end of the signal self-pipe, for the event loop's poll fd array.
pub fn readFd() std.posix.fd_t {
    return signal_pipe[pipe_read];
}

// Dispatches a single signal byte to the appropriate handler.
fn dispatchSignal(byte: u8) void {
    switch (@as(std.posix.SIG, @enumFromInt(byte))) {
        .HUP => utils.reload(),
        // Unified reload trigger, same semantics as the reload keybind:
        // re-exec the current binary if it changed since boot, else hot-reload
        // the config (restart.requestReload decides). Dispatch runs on the
        // event loop, NOT in the signal handler, so statx/flag work is safe.
        .USR1 => restart.requestReload(),
        .TERM, .INT => utils.quit(),
        // SIGCHLD: an intermediate double-fork child has exited.
        // Reap it with WNOHANG, then immediately drain the spawn pipes so
        // registerSpawn fires without waiting for the next XCB event batch.
        .CHLD => {
            spawn.reapPendingChildren();
            spawn.drainPendingSpawns();
        },
        else => {},
    }
}

// Drain a burst in one syscall rather than one per byte.
const signal_drain_buf = 16;

/// Drains the non-blocking signal pipe and dispatches each signal.
///
/// std.os.linux.read returns usize; a kernel error wraps a negative value into
/// a huge unsigned number an unsigned comparison would never catch. Bitcast to
/// isize and stop on any non-positive result (error, EOF, or empty).
pub fn drainAndDispatch(fd: std.posix.fd_t) void {
    var buf: [signal_drain_buf]u8 = undefined;
    while (true) {
        const rc: isize = @bitCast(std.os.linux.read(fd, &buf, buf.len));
        if (rc <= 0) break; // 0 = EOF on write-end close, negative = error/EAGAIN
        const n: usize = @intCast(rc);
        for (buf[0..n]) |byte| {
            // Wake byte written by utils.reload(): poke the event loop out of
            // poll, but don't re-dispatch it (see utils.wake_byte).
            if (byte == utils.wake_byte) continue;
            dispatchSignal(byte);
        }
    }
}
