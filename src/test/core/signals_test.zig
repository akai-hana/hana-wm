//! Tests for the signal disposition POLICY (signals.plan).
//!
//! This file deliberately tests `plan` and never `setup`. `setup` opens the
//! self-pipe and calls sigaction on five signals, which in a test binary would
//! replace the test runner's own SIGINT/SIGTERM dispositions and make Ctrl-C
//! (and the runner's timeout handling) unreliable. Splitting the table out as
//! pure data is what makes the interesting part -- WHICH signals hana takes
//! over, and the ordering constraint between the alternate stack and the
//! ONSTACK handler -- assertable at all.
//!
//! The behavioural half (that the dispositions are really installed) is
//! covered by booting the real binary, which is what dev/scripts/xtest.sh and
//! the start-up smoke test do.

const std = @import("std");
const signals = @import("signals");

test "plan: the five control signals are handled, in order" {
    const p = signals.plan();

    try std.testing.expectEqual(@as(usize, 5), p.handled.len);
    // Order is the install order. It is not merely cosmetic: the handler is
    // installed first, so a signal arriving mid-setup is queued to the pipe
    // rather than taking the default action.
    try std.testing.expectEqual(std.posix.SIG.HUP, p.handled[0]);
    try std.testing.expectEqual(std.posix.SIG.TERM, p.handled[1]);
    try std.testing.expectEqual(std.posix.SIG.INT, p.handled[2]);
    try std.testing.expectEqual(std.posix.SIG.CHLD, p.handled[3]);
    try std.testing.expectEqual(std.posix.SIG.USR1, p.handled[4]);
}

test "plan: SIGPIPE is ignored, not handled" {
    const p = signals.plan();

    try std.testing.expectEqual(std.posix.SIG.PIPE, p.ignored);
    // SIGPIPE must NOT also be in the handled set: the ignored disposition is
    // installed after the handler loop, so a signal that was in both lists
    // would end up SIG_IGN by luck of ordering rather than by intent.
    for (p.handled) |sig| {
        try std.testing.expect(sig != std.posix.SIG.PIPE);
    }
}

test "plan: SIGUSR2 is the backtrace signal, so it is not in the handled set" {
    const p = signals.plan();

    // SIGUSR2 is armed separately by setupBacktraceHandler (SA.SIGINFO), not
    // by the self-pipe handler. If it ever appeared in `handled`, the later
    // backtrace arm would be silently overwritten by the pipe handler and
    // Ctrl-\ backtraces would stop working.
    for (p.handled) |sig| {
        try std.testing.expect(sig != std.posix.SIG.USR2);
    }
}
