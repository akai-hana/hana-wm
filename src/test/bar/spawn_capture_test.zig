//! Tests for the slider's shell runner (`spawn_capture`).
//!
//! WHY A DEADLINE-TESTABLE SEAM
//!   The pre-fork runner used `popen`, which has no timeout: a helper wedged
//!   behind a lock stalled the bar segment for the child's entire lifetime.
//!   The fork+exec+poll rewrite bounds every run by a deadline and SIGKILLs
//!   the child when it expires; the last test pins exactly that, using the
//!   injected-budget seam so the suite doesn't pay the production 3s budget.
//!
//! The import graph is the runner's: std + core only -- no X11, so these run
//! anywhere /bin/sh exists.

// build-gate: seg_slider

const std = @import("std");
const core = @import("core");
const spawn_capture = @import("spawn_capture");

test "runOut captures stdout and trims trailing whitespace" {
    var buf: [256]u8 = undefined;
    try std.testing.expectEqualStrings("hello", spawn_capture.runOut("printf 'hello\\n'", &buf));
}

test "runOut returns empty when the command prints nothing" {
    var buf: [256]u8 = undefined;
    try std.testing.expectEqualStrings("", spawn_capture.runOut("true", &buf));
}

test "runOut drains output larger than the pipe and keeps the leading bytes" {
    // 100 KiB exceeds a typical pipe buffer; without the scratch-drain loop
    // the child would block mid-write and this would hang until the deadline.
    var buf: [64]u8 = undefined;
    const out = spawn_capture.runOut("head -c 100000 /dev/zero | tr '\\0' 'a'", &buf);
    try std.testing.expectEqual(@as(usize, 64), out.len);
    try std.testing.expect(std.mem.allEqual(u8, out, 'a'));
}

test "runOk is true iff the command exits 0" {
    try std.testing.expect(spawn_capture.runOk("true"));
    try std.testing.expect(!spawn_capture.runOk("false"));
}

test "runOk reports a missing binary as not-ok" {
    // execvp fails in the child -> exit 127; the runner must reap that as a
    // completed run, not hang waiting for a process that already exited.
    try std.testing.expect(!spawn_capture.runOk("/nonexistent-binary-definitely"));
}

test "an expired deadline SIGKILLs the child instead of waiting it out" {
    // Regression guard for the popen hang: a `sleep 5` helper with a 150ms
    // budget must come back with empty output well before the child's 5s.
    var buf: [256]u8 = undefined;
    const t0 = core.realtimeMs();
    const out = spawn_capture.runOutWithTimeoutForTest("sleep 5", &buf, 150);
    const elapsed = core.realtimeMs() - t0;
    try std.testing.expectEqualStrings("", out);
    try std.testing.expect(elapsed < 3000);
}
