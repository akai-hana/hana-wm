//! `/bin/sh` spawn capture: the bar's subprocess runners.
//!
//! `runOut` / `runOk` are the allocation-free racers every spawned control
//! command goes through (pactl / amixer / brightnessctl). They were lifted
//! out of the slider package when the split made it plain that nothing here
//! is slider-specific: drain the child's stdout so `pclose` never blocks on a
//! full pipe, report the bytes (or exit status), and let the caller keep its
//! fixed buffers. Anything in the bar that needs to run a command and read
//! its output belongs here rather than growing its own popen/pclose dance.

const std = @import("std");

const c = @cImport({
    @cInclude("stdio.h");
});

/// Runs `cmd` via /bin/sh, drains its stdout into `sink` (so `pclose` never
/// blocks on a full pipe), and reports the bytes captured plus whether the
/// child exited 0. Null on any failure: the command is too long for the fixed
/// 256-byte buffer, or `popen` was denied. Shared body of `runOut`/`runOk`.
fn spawnCapture(cmd: []const u8, sink: []u8) ?struct { bytes: usize, exit_ok: bool } {
    if (cmd.len + 1 > 256) return null;
    var cmd_buf: [256]u8 = undefined;
    @memcpy(cmd_buf[0..cmd.len], cmd);
    cmd_buf[cmd.len] = 0;
    const f = c.popen(&cmd_buf, "r") orelse return null;
    const bytes = c.fread(sink.ptr, 1, sink.len, f);
    // fread's single pass is what stalled: an output larger than sink stopped
    // after one partial read, the child then blocked on the full pipe, and
    // pclose blocked on that child. Drain the remainder into a scratch so the
    // child can finish writing and pclose never waits for a blocked writer.
    if (bytes == sink.len) {
        var scratch: [256]u8 = undefined;
        while (c.fread(&scratch, 1, scratch.len, f) > 0) {}
    }
    return .{ .bytes = bytes, .exit_ok = c.pclose(f) == 0 };
}

/// Runs `cmd` via /bin/sh and returns its captured stdout, trimmed of
/// trailing whitespace. Empty slice on any failure (popen denied, the child
/// wrote nothing, or the command is too long for the fixed buffer).
pub fn runOut(cmd: []const u8, buf: []u8) []const u8 {
    const cap = spawnCapture(cmd, buf) orelse return "";
    if (cap.bytes == 0) return "";
    return std.mem.trimEnd(u8, buf[0..cap.bytes], " \n\r");
}

/// Runs `cmd`, drains its output (so `pclose` never blocks on a full pipe),
/// and returns whether the child exited 0.
pub fn runOk(cmd: []const u8) bool {
    var sink: [64]u8 = undefined;
    const cap = spawnCapture(cmd, &sink) orelse return false;
    return cap.exit_ok;
}
