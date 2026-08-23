//! Process lifecycle signals + fd plumbing (D6 split from utils.zig). xcb-free.
//!
//! Module-level atomics, not WM struct fields; this is process control
//! state, not window-manager state. Signal handlers and keybind actions
//! write here; the main event loop reads here.

const std = @import("std");

/// Set to false by SIGTERM/SIGINT to break the main event loop.
pub var running = std.atomic.Value(bool).init(true);

/// Set to true by SIGHUP or the `reload_config` keybinding.
/// Consumed by `consumeReload` in the main event loop.
var should_reload = std.atomic.Value(bool).init(false);

/// Write end of the signal self-pipe (owned by signals.zig), registered via
/// `setSignalWriteFd`. The `reload_config` keybinding has no signal byte, so
/// `reload()` writes a wake byte here to poke the event loop out of poll
/// immediately instead of waiting for an unrelated signal.
var signal_write_fd: std.posix.fd_t = -1;

/// Byte `reload()` writes to the signal pipe to wake the event loop. Must not
/// be a real signal number: `signals.drainAndDispatch` dispatches every byte
/// it reads, and re-dispatching the wake byte as SIGHUP would make the drain
/// loop call `reload()` again; writing another wake byte and spinning forever.
pub const wake_byte: u8 = 0xff;

/// Registers the write end of the signal self-pipe so `reload()` can wake the
/// event loop. Pass -1 to unregister (teardown).
pub fn setSignalWriteFd(fd: std.posix.fd_t) void {
    signal_write_fd = fd;
}

pub inline fn quit() void {
    running.store(false, .release);
}

/// Signals the main event loop to reload the user config.
///
/// Safe from any thread: the wake byte is a plain write, not a signal. If the
/// pipe is full (or not yet registered) the write is dropped; the event loop
/// also polls the flag itself every iteration, so a lost byte only delays the
/// reload by one poll timeout at worst.
pub inline fn reload() void {
    if (!should_reload.swap(true, .acq_rel)) {
        if (signal_write_fd >= 0)
            _ = std.os.linux.write(signal_write_fd, &[_]u8{wake_byte}, 1);
    }
}

/// Atomically consumes the reload flag.
/// Returns true exactly once per request, whichever call path checks first wins.
pub inline fn consumeReload() bool {
    return should_reload.swap(false, .acq_rel);
}

/// Creates a pipe with O_NONBLOCK | O_CLOEXEC on both ends via pipe2(2).
///
/// Shared by input.zig (double-fork spawn plumbing) and signals.zig (signal
/// self-pipe), avoiding byte-equivalent copies of this in each.
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
