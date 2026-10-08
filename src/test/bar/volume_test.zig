//! Unit tests for the volume slider sub.
//!
//! volume.zig's pure helpers (the re-probe / negative-cache decision logic, plus
//! the pre-existing `parsePercent`/`label` tests) used to be INLINE in
//! volume.zig, with this file as a mere "reachability anchor" -- the belief
//! being that importing a module runs its inline tests. IT DOES NOT: the
//! `zig build test` harness executes test blocks in the test root only, so an
//! inline test in an imported module is never even analyzed. A canary
//! `expectEqual(1, 2)` appended to volume.zig does not fail; the same canary
//! appended here does.
//!
//! The gap hid because the build still type-checks volume.zig, so a mutation
//! there produced compile errors that read like test kills -- the first
//! mutation pass reported M36-M48 as KILLED when M46-M48 were
//! compile-error cascades and no assertion had ever run.
//!
//! All the helpers are `pub` and tested HERE. The two recovered `label` tests
//! were still calling the old by-pointer signature, so they could not have
//! compiled had they ever run; they are corrected below. `label` reads
//! module-private display state, set up through the explicit
//! `setDisplayForTest` seam.
//
//! (The same trap held brightness.zig's five tests, native_alsa.zig's five and
//! native_pulse.zig's seven. All twenty were recovered the same way; a repo-wide
//! sweep now reports zero dead inline tests.)

// build-gate: volume

const std = @import("std");
const volume = @import("volume");
const slider = @import("slider");
const types = @import("types");

const Probe = volume.Probe;
const Rung = volume.Rung;
const reprobe_interval_ms = volume.reprobe_interval_ms;
const probeDecision = volume.probeDecision;
const latchedRung = volume.latchedRung;
const optimisticLevel = volume.optimisticLevel;
const optimisticAfter = volume.optimisticAfter;
const noteLadderResult = volume.noteLadderResult;

const no = Probe{ .walk = false };
const yes = Probe{ .walk = true };
const flip = Probe{ .walk = true };

/// The span form: `Label` carries `value_start`/`value_len` rather than a
/// subslice, so assertions spell the comparison out instead of relying on a
/// `?[]const u8` field these tests used to have.
fn valueSpan(l: slider.Label) []const u8 {
    return l.text[l.value_start..][0..l.value_len];
}

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
    // must not run. This is the backend-latch saving: three popens per poll, per press
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
    // search order -- the whole point of the latch. Latch/unlatch state is
    // module-private and used by latchedRung, so the test's assertion only
    // holds after clearing the (process-global) native backends via the seam.
    volume.clearNativeBackendForTest();
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

// ---------------------------------------------------------------------------
// Recovered dead tests. These lived INLINE in volume.zig and had never once
// executed: the harness runs tests from the test root, and nothing imported
// volume.zig. The build still type-checked it, so a mutation there read as a
// kill. They now run for the first time. `label` reads module-private display
// state, so they set it through the explicit `setDisplayForTest` seam.

test "parsePercent extracts first N%" {
    try std.testing.expectEqual(@as(?u8, 42), volume.parsePercent("Volume: 123456 / 42% / 6,56 dB"));
    try std.testing.expectEqual(@as(?u8, 100), volume.parsePercent("Mono: Playback 65536 [100%] [on]"));
    try std.testing.expectEqual(@as(?u8, 7), volume.parsePercent("vol 7%"));
    try std.testing.expectEqual(@as(?u8, null), volume.parsePercent("no percent here"));
    try std.testing.expectEqual(@as(?u8, null), volume.parsePercent(""));
}

test "label honors configuration" {
    var cfg = types.BarConfig{};
    cfg.volume_format = "Level {pct}";
    cfg.volume_muted_format = "Silenced {state}";
    var buf: [128]u8 = undefined;
    volume.setDisplayForTest(42, false);
    try std.testing.expectEqualStrings("Level 42", volume.label(cfg, &buf).text);
    try std.testing.expectEqualStrings("42", valueSpan(volume.label(cfg, &buf)));
    volume.setDisplayForTest(42, true);
    try std.testing.expectEqualStrings("Silenced mute", volume.label(cfg, &buf).text);
    try std.testing.expectEqual(@as(usize, 0), volume.label(cfg, &buf).value_len);
    volume.setDisplayForTest(42, false);
}

test "label default formats" {
    var buf: [128]u8 = undefined;
    volume.setDisplayForTest(33, false);
    try std.testing.expectEqualStrings("VOL 33%", volume.label(types.BarConfig{}, &buf).text);
    try std.testing.expectEqualStrings("33%", valueSpan(volume.label(types.BarConfig{}, &buf)));
    volume.setDisplayForTest(33, true);
    try std.testing.expectEqualStrings("MUTE", volume.label(types.BarConfig{}, &buf).text);
    volume.setDisplayForTest(33, false);
}

// ---------------------------------------------------------------------------
// The no-backend display contract. With every rung failed there is no sink to
// have muted anything, so the segment must not claim `VOL 0%`.

test "no backend renders MUTE rather than VOL 0%" {
    var cfg = types.BarConfig{};
    cfg.volume_format = "VOL {pct}%";
    cfg.volume_muted_format = "MUTE";
    var buf: [128]u8 = undefined;

    // A value is set and then cleared, which is the no-backend start-up
    // condition: the forced-mute path owns the display.
    volume.setDisplayForTest(0, false);
    volume.clearValueForTest();
    try std.testing.expectEqualStrings("MUTE", volume.label(cfg, &buf).text);
}

test "a read value un-mutes the display again" {
    var cfg = types.BarConfig{};
    cfg.volume_format = "VOL {pct}%";
    cfg.volume_muted_format = "MUTE";
    var buf: [128]u8 = undefined;

    // setDisplayForTest also sets the has-value flag (a supplied pct is a
    // level some rung read), so the un-muted format returns.
    volume.setDisplayForTest(42, false);
    try std.testing.expectEqualStrings("VOL 42%", volume.label(cfg, &buf).text);
}
