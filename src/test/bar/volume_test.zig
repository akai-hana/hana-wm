//! Reachability anchor for the volume slider sub's inline tests.
//!
//! volume.zig's pure re-probe/negative-cache helpers are inline tests, the
//! convention every other bar module follows. But inline tests only run if the
//! file is reachable from a test root, and nothing in the test tree imported
//! volume -- so all of them were dead code. The build compiles volume.zig (a
//! mutation that broke it produced compile errors), which is exactly how the
//! gap hid: the file was type-checked and its tests never once executed.
//!
//! The helpers themselves are `pub` and tested HERE rather than inline, because
//! the `zig build test` harness runs tests from the test root only: an inline
//! test in an imported module is compiled but never executed. (brightness.zig's
//! five inline tests are dead the same way; a canary `expectEqual(1, 2)` in
//! either file reports success.) So the file that makes volume.zig reachable
//! is also the file that has to hold its tests.

// build-gate: seg_brightness

const std = @import("std");
const volume = @import("volume");

const Probe = volume.Probe;
const Rung = volume.Rung;
const reprobe_interval_ms = volume.reprobe_interval_ms;
const probeDecision = volume.probeDecision;
const latchedRung = volume.latchedRung;
const optimisticLevel = volume.optimisticLevel;
const optimisticAfter = volume.optimisticAfter;
const latchedRungFor = volume.latchedRungFor;
const noteLadderResult = volume.noteLadderResult;

const no = Probe{ .walk = false, .forget_native = false };
const yes = Probe{ .walk = true, .forget_native = false };
const flip = Probe{ .walk = true, .forget_native = true };

test "probeDecision: a ladder that never ran is walked immediately" {
    // "Unchanged" is only evidence once there is a previous observation. With
    // no failure recorded, an unchanged reachability must NOT suppress the
    // walk, or a machine whose first poll finds nothing would never resolve.
    try std.testing.expectEqual(yes, probeDecision(0, null, 0, null, false));
    try std.testing.expectEqual(yes, probeDecision(50_000, null, 0, false, false));
    try std.testing.expectEqual(yes, probeDecision(50_000, null, 0, false, true));
}

test "probeDecision: a recorded failure is cached, not re-walked per poll" {
    const t0 = 100_000;
    // Straight after the failure, and for the whole cache window, the ladder
    // must not run. This is the 26.7 saving: three popens per poll, per press
    // and per right-click, against a dead daemon.
    try std.testing.expectEqual(no, probeDecision(t0 + 1, t0, t0 + 2, false, false));
    try std.testing.expectEqual(no, probeDecision(t0 + 5_000, t0, t0 + 6_000, false, false));
    // Cached even when the daemon now looks reachable: the point of a negative
    // cache is that it is consulted before the recheck, not after.
    try std.testing.expectEqual(no, probeDecision(t0 + 1, t0, t0 + 2, false, true));
}

test "probeDecision: the slow deadline retries on its own" {
    const t0 = 100_000;
    // Deadline reached, daemon still unreachable: retry anyway, so a daemon
    // that came back without changing reachability is not lost forever. But do
    // NOT forget the native probe -- the deadline is a retry, not a new clue.
    try std.testing.expectEqual(yes, probeDecision(t0 + reprobe_interval_ms, t0, t0 + 2, false, false));
    // Saturating subtraction: a clock that reads earlier than the failure must
    // not underflow into a spurious retry storm.
    try std.testing.expectEqual(no, probeDecision(0, t0, t0 + 2, false, false));
}

test "probeDecision: a reachability FLIP is the re-probe trigger" {
    const t0 = 100_000;
    // Recheck window open, daemon now reachable where it was not: walk AND
    // forget the native probe. This is what finds a daemon started after the
    // machine was written off, and what lets the native attach be retried.
    try std.testing.expectEqual(flip, probeDecision(t0 + 1, t0, t0, false, true));
    // Recheck window open, daemon now gone where it was there: also walk, so
    // the latch is dropped rather than kept against a daemon that died.
    try std.testing.expectEqual(flip, probeDecision(t0 + 1, t0, t0, true, false));
    // Recheck window open, answer UNCHANGED: ask again but do not walk and do
    // not forget the native probe. Re-asking is cheap; re-walking is not.
    try std.testing.expectEqual(no, probeDecision(t0 + 1, t0, t0, false, false));
    // No prior observation: the first recheck after a failure has nothing to
    // compare against, so it gets the one probe.
    try std.testing.expectEqual(flip, probeDecision(t0 + 1, t0, t0, null, false));
    // Outside the recheck window the daemon is not asked at all, so a flip
    // there must be ignored rather than acted on.
    try std.testing.expectEqual(no, probeDecision(t0 + 1, t0, t0 + 2, false, true));
    // Exactly on the deadline, and exactly on the window edge: both inclusive,
    // so neither trigger can be skipped by an off-by-one.
    try std.testing.expectEqual(yes, probeDecision(t0 + reprobe_interval_ms, t0, t0 + reprobe_interval_ms, false, false));
    try std.testing.expectEqual(flip, probeDecision(t0 + 1, t0, t0, true, true == false));
}

test "latchedRung maps a backend to the one read it needs" {
    // A latched backend must read through its OWN rung, never the ladder's
    // most-native-first order -- the whole point of the latch.
    try std.testing.expectEqual(Rung.pactl, latchedRungFor(.pulse, false, false));
    try std.testing.expectEqual(Rung.amixer, latchedRungFor(.alsa, false, false));
    try std.testing.expectEqual(Rung.none, latchedRungFor(.unknown, false, false));
    // With the native handle attached, the same latched pulse backend must read
    // in-process instead of spawning pactl. No unit test can attach a daemon,
    // so this arm is only reachable by passing the presence in.
    try std.testing.expectEqual(Rung.native_pulse, latchedRungFor(.pulse, true, false));
    try std.testing.expectEqual(Rung.native_alsa, latchedRungFor(.alsa, false, true));
    // Both handles present: each backend still reads its OWN, so an ALSA latch
    // is never diverted through the pulse handle.
    try std.testing.expectEqual(Rung.native_alsa, latchedRungFor(.alsa, true, true));
    try std.testing.expectEqual(Rung.native_pulse, latchedRungFor(.pulse, true, true));
    // The live wrapper, with no handles attached in a unit test.
    try std.testing.expectEqual(Rung.pactl, latchedRung(.pulse));
    try std.testing.expectEqual(Rung.amixer, latchedRung(.alsa));
    try std.testing.expectEqual(Rung.none, latchedRung(.unknown));
}

test "noteLadderResult arms the negative cache, and clears it on success" {
    // Nothing answered: arm at now, so the next poll does not re-walk.
    try std.testing.expectEqual(@as(?i64, 1_000), noteLadderResult(false, 1_000));
    // A rung answered: the cache MUST be cleared. An armed failure that
    // outlives the success that disproved it would leave a recovered daemon
    // unwalked for the rest of the cache window.
    try std.testing.expectEqual(@as(?i64, null), noteLadderResult(true, 1_000));
}

test "optimisticAfter moves the display only when a backend exists" {
    try std.testing.expectEqual(@as(u8, 40), optimisticAfter(.pulse, 40, 7));
    try std.testing.expectEqual(@as(u8, 40), optimisticAfter(.alsa, 40, 7));
    // Clamped by the same clamp the commit passes.
    try std.testing.expectEqual(@as(u8, 100), optimisticAfter(.pulse, 255, 7));
    // No backend: the display must NOT move. `commitPct` wrote nothing, so 40
    // would be a level the sink never accepted.
    try std.testing.expectEqual(@as(u8, 7), optimisticAfter(.unknown, 40, 7));
}

test "optimisticLevel echoes a committed level, but never invents one" {
    // A press displays what it just wrote...
    try std.testing.expectEqual(@as(?u8, 40), optimisticLevel(.pulse, 40));
    try std.testing.expectEqual(@as(?u8, 40), optimisticLevel(.alsa, 40));
    // ...clamped by the same clamp every commit passes, so the optimistic
    // display cannot show a level the backend would refuse.
    try std.testing.expectEqual(@as(?u8, 100), optimisticLevel(.pulse, 255));
    // ...but with no backend, `commitPct` wrote nothing, so there is nothing
    // to show. Echoing 40 here would display a level the sink never accepted.
    try std.testing.expectEqual(@as(?u8, null), optimisticLevel(.unknown, 40));
}
