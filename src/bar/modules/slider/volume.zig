//! Volume slider sub: shows the default sink's level and mute state and
//! controls it, bound to the slider core's `Sub` contract. This module owns
//! the sink's TRUTH -- backend attach/probe, reads, writes, display format
//! -- while the slider core owns the shared render shell, interaction, poll
//! and commit clock.
//!
//! Backends, most-native first. The resolved backend is LATCHED: once a read
//! has identified one, later reads go straight to it; a ladder that found
//! nothing is negative-cached so a dead daemon cannot cost a fresh pair of
//! subprocesses on every press, right-click and 5 s poll. Both directions
//! are undone by the same trigger -- a daemon-reachability recheck plus a
//! slow deadline -- so a daemon that starts later is still picked up:
//!   1. `libpulse` via dlopen (`native_pulse.zig`) -- PulseAudio AND every
//!      real PipeWire desktop (`pipewire-pulse` ships the `libpulse.so.0`
//!      ABI). In-process, one socket round trip per commit.
//!   2. `pactl` subprocess -- the split-packaging case: the .so absent but
//!      the CLI present.
//!   3. `amixer` subprocess -- ALSA, when alsa-utils is installed.
//!   4. `/dev/snd/controlC*` ioctls (`native_alsa.zig`) -- the ALSA floor.
//!
//! The two native rungs are why `commit_cost` is a per-sub query (`.immediate`
//! vs `.rate_limited`). The 0-100 % clamp in `commit` guards every caller.

const std = @import("std");
const log = std.log.scoped(.volume);
const types = @import("types");
const bar_config = @import("bar_config");
const slider = @import("slider");
const drawing = @import("drawing");
const spawn_capture = @import("spawn_capture");
const core = @import("core");
const native_pulse = @import("native_pulse");
const native_alsa = @import("native_alsa");

const default_format = "VOL {pct}%";
const default_muted_format = "MUTE";

const Backend = enum { unknown, pulse, alsa };

/// Owner state (P2-58): the latched backend, the display value, the ladder
/// negative cache, the two in-process rung handles, and the optimistic-commit
/// muted bits. Attached handles: non-null means the rung won the ladder walk
/// and is latched. The negative cache stops every read against a dead daemon
/// re-walking all four rungs (up to three blocking `popen`s). The recheck
/// window is separate from the cache deadline so a cheap reachability check
/// can retry long before the cache expires. `pulse_muted`/`alsa_muted` are
/// each rung's last muted bits, echoed before the next read.
const VolumeState = struct {
    backend: Backend = .unknown,
    pct: u8 = 0,
    muted: bool = false,
    has_value: bool = false,
    ladder_failed_at_ms: ?i64 = null,
    native_pulse: ?native_pulse.Backend = null,
    native_alsa: ?native_alsa.Master = null,
    pulse_recheck_at_ms: i64 = 0,
    pulse_reachable: ?bool = null,
    pulse_muted: bool = false,
    alsa_muted: bool = false,
    reason_logged: bool = false,
};
var g: VolumeState = .{};
pub const reprobe_interval_ms: i64 = 15_000;

/// What the negative cache says about one poll: whether the ladder may be
/// walked. One bool, because there is exactly one thing to forget: the latched
/// backend. A daemon-reachability CHANGE grants the walk that finds it late.
pub const Probe = struct { walk: bool };

/// The pure re-probe decision: whether a poll may walk the ladder again, and
/// whether it must first re-ask reachability. No clock, no IO -- testable.
///   - No recorded failure: run. Slow deadline passed: retry on it alone.
///   - Recheck window arrived: ask again; a CHANGED answer is the trigger.
///   - Otherwise: skip -- the whole point of the negative cache.
pub fn probeDecision(
    now: i64,
    failed_at_ms: ?i64,
    recheck_at_ms: i64,
    last_reachable: ?bool,
    reachable: bool,
) Probe {
    // No recorded failure: the ladder has never completed, so run it even
    // if the daemon looks as it did last time.
    if (failed_at_ms == null) return .{ .walk = true };
    const failed_at = failed_at_ms.?;
    if (now -| failed_at >= reprobe_interval_ms) return .{ .walk = true };
    if (now >= recheck_at_ms) {
        // Only a CHANGED answer un-latches: the daemon that started after
        // we wrote it off is found here, without paying for the ladder on
        // every poll.
        return .{ .walk = last_reachable == null or last_reachable.? != reachable };
    }
    return .{ .walk = false };
}

/// Whether the ladder may be walked now. `probeDecision`'s clock and IO
/// edge, and the only place that mutates the cache's own bookkeeping.
fn probeDue() bool {
    const now = core.realtimeMs();
    const recheck_window = now >= g.pulse_recheck_at_ms;
    const reachable = if (recheck_window) native_pulse.pulseReachable() else false;
    const probe = probeDecision(
        now,
        g.ladder_failed_at_ms,
        g.pulse_recheck_at_ms,
        g.pulse_reachable,
        reachable,
    );
    if (recheck_window) {
        g.pulse_recheck_at_ms = now + reprobe_interval_ms;
        g.pulse_reachable = reachable;
    }
    // A daemon that appeared (or vanished) is worth a fresh native attach:
    // the one-shot probed flag would otherwise write the machine off for
    // the rest of the session.
    return probe.walk;
}

/// The rung a latched backend is read through. Named so the backend ->
/// rung mapping is checkable without a daemon: the latch consults it
/// directly and never re-derives it by re-walking the ladder.
pub const Rung = enum { native_pulse, pactl, amixer, native_alsa, none };

pub fn latchedRung(backend: Backend) Rung {
    return switch (backend) {
        .pulse => if (g.native_pulse != null) .native_pulse else .pactl,
        .alsa => if (g.native_alsa != null) .native_alsa else .amixer,
        .unknown => .none,
    };
}

/// The level a press should show without re-reading. Null means "show
/// nothing new": with no backend, `commitPct` wrote nothing, so echoing
/// would display a level the sink never accepted.
pub fn optimisticLevel(backend: Backend, v: u8) ?u8 {
    return if (backend == .unknown) null else slider.clampPct(v);
}

/// The display level after a press. Value in, value out, so the "with no
/// backend the display does not move" half is checkable.
pub fn optimisticAfter(backend: Backend, v: u8, current: u8) u8 {
    return optimisticLevel(backend, v) orelse current;
}

/// The negative cache after one ladder run. A rung answered so it is CLEARED
/// -- an armed failure must never outlive the success that disproved it.
/// Nothing answered: armed at `now`, so the next poll and right-click skip it.
pub fn noteLadderResult(ok: bool, now: i64) ?i64 {
    return if (ok) null else now;
}

const pactl_vol_cmd = "pactl get-sink-volume @DEFAULT_SINK@";
const pactl_mute_cmd = "pactl get-sink-mute @DEFAULT_SINK@";
const amixer_vol_cmd = "amixer get Master";

/// First `N%` in `out`, scanning the digits back from the `%`; 0-100.
pub fn parsePercent(out: []const u8) ?u8 {
    for (out, 0..) |ch, i| {
        if (ch != '%') continue;
        var j = i;
        while (j > 0 and out[j - 1] >= '0' and out[j - 1] <= '9') j -= 1;
        if (j == i) continue;
        const v = std.fmt.parseUnsigned(u8, out[j..i], 10) catch continue;
        return if (v > 100) 100 else v;
    }
    return null;
}

/// The one-time diagnostic for a machine where every rung failed. Distinct
/// from the MUTE display: MUTE is the steady state (the sink may genuinely
/// be muted); this is the one line saying *why* there is no level. Armed
/// once per process: the poll would otherwise repeat it every 5 s, and a bar
/// that repeats itself is how a real fault gets ignored.
fn logNoBackend() void {
    if (g.reason_logged) return;
    g.reason_logged = true;
    log.warn(
        "volume: no usable backend (libpulse.so.0, pactl, amixer and " ++
            "/dev/snd/controlC* all failed); showing MUTE",
        .{},
    );
}

/// Re-reads level + mute from the live backend, walking the ladder
/// (libpulse -> pactl -> amixer -> native ALSA). True when this read
/// changed the displayed state.
fn readVolume() bool {
    // A LATCHED backend is read directly: the latch takes the ladder off the
    // hot path so a dead daemon does not spawn subprocesses on every poll.
    if (g.backend != .unknown) {
        if (readLatched()) |changed| return changed;
        // The latched backend stopped answering (daemon restarted, card
        // unplugged). Forget it; the negative cache still applies.
        g.backend = .unknown;
    }
    if (!probeDue()) return false;
    return runLadder();
}

/// Reads only the currently latched backend. Null when that backend does
/// not answer, which tells `readVolume` to fall back to the ladder.
fn readLatched() ?bool {
    const had_value = g.has_value;
    const old_pct = g.pct;
    const old_muted = g.muted;
    // One read per rung. `pactl` needs two commands (level, then mute), so
    // the two rungs share a shape but not a body.
    switch (latchedRung(g.backend)) {
        .native_pulse => {
            const sink = g.native_pulse.?.readSink() orelse {
                // The native backend stopped answering: tear it DOWN and
                // forget it so the next ladder walk attaches fresh instead
                // of holding a dead context (and its worker thread).
                g.native_pulse.?.deinit();
                g.native_pulse = null;
                return null;
            };
            g.pct = sink.pct;
            g.muted = sink.muted;
        },
        .pactl => {
            var buf: [1024]u8 = undefined;
            const out = spawn_capture.runOut(pactl_vol_cmd, &buf);
            g.pct = parsePercent(out) orelse return null;
            const out2 = spawn_capture.runOut(pactl_mute_cmd, &buf);
            g.muted = std.mem.indexOf(u8, out2, "Mute: yes") != null;
        },
        .amixer => {
            var buf: [1024]u8 = undefined;
            const out = spawn_capture.runOut(amixer_vol_cmd, &buf);
            g.pct = parsePercent(out) orelse return null;
            g.muted = std.mem.indexOf(u8, out, "[off]") != null;
        },
        .native_alsa => {
            g.pct = g.native_alsa.?.readVolumePct() orelse return null;
            g.muted = g.native_alsa.?.readMuted() orelse false;
        },
        .none => return null,
    }
    g.has_value = true;
    g.reason_logged = false;
    return changedFrom(had_value, old_pct, old_muted);
}

fn changedFrom(had_value: bool, old_pct: u8, old_muted: bool) bool {
    return !had_value or g.pct != old_pct or g.muted != old_muted;
}

/// The four-rung ladder, reached only when nothing is latched (or the latch
/// went stale). Order is by protocol family, not by speed:
///   1. libpulse via dlopen -- PulseAudio AND every real PipeWire desktop.
///   2. `pactl` -- same family, for the split-packaging case.
///   3. `amixer` -- ALSA, when alsa-utils is installed.
///   4. `/dev/snd/controlC*` -- the ALSA floor: kernel ioctls only.
/// Deliberately NOT "most-native first": rung 1 only exists on Pulse-family
/// machines, so it would cost a failed dlopen on every pure-ALSA box.
fn runLadder() bool {
    const had_value = g.has_value;
    const old_pct = g.pct;
    const old_muted = g.muted;
    var ok = false;

    if (tryRungNativePulse()) {
        ok = true;
    } else if (tryRung(.pulse, pactl_vol_cmd, pactl_mute_cmd, "Mute: yes")) |v| {
        g.pct = v;
        g.muted = g.pulse_muted;
        g.backend = .pulse;
        ok = true;
    } else if (tryRung(.alsa, amixer_vol_cmd, "", "[off]")) |v| {
        g.pct = v;
        g.muted = g.alsa_muted;
        g.backend = .alsa;
        ok = true;
    } else if (tryRungNativeAlsa()) {
        ok = true;
    } else {
        g.backend = .unknown;
    }

    g.ladder_failed_at_ms = noteLadderResult(ok, core.realtimeMs());
    if (!ok) {
        logNoBackend();
        return false;
    }
    g.has_value = true;
    g.reason_logged = false;
    return changedFrom(had_value, old_pct, old_muted);
}

/// One subprocess rung: run `vol_cmd`, parse a percentage, then derive the
/// mute state. `mute_cmd` empty means the mute answer is in the volume
/// output (`amixer` reports both in one line).
fn tryRung(backend: Backend, vol_cmd: []const u8, mute_cmd: []const u8, on_token: []const u8) ?u8 {
    var buf: [1024]u8 = undefined;
    const out = spawn_capture.runOut(vol_cmd, &buf);
    const pct = parsePercent(out) orelse return null;
    const muted = if (mute_cmd.len == 0)
        std.mem.indexOf(u8, out, on_token) != null
    else blk: {
        const m = spawn_capture.runOut(mute_cmd, &buf);
        break :blk std.mem.indexOf(u8, m, on_token) != null;
    };
    switch (backend) {
        .pulse => g.pulse_muted = muted,
        .alsa => g.alsa_muted = muted,
        .unknown => {},
    }
    return pct;
}

fn tryRungNativePulse() bool {
    if (g.native_pulse == null) g.native_pulse = native_pulse.attach();
    if (g.native_pulse) |*np| {
        if (np.readSink()) |sink| {
            g.backend = .pulse;
            g.pct = sink.pct;
            g.muted = sink.muted;
            return true;
        }
        // Attached but unresponsive: tear down and forget, mirroring the
        // readLatched failure path -- a fresh attach is the only way back to
        // the native rung after a daemon restart.
        np.deinit();
        g.native_pulse = null;
    }
    return false;
}

fn tryRungNativeAlsa() bool {
    if (g.native_alsa == null) g.native_alsa = native_alsa.openMaster();
    if (g.native_alsa) |*na| {
        if (na.readVolumePct()) |pct| {
            g.backend = .alsa;
            g.pct = pct;
            g.muted = na.readMuted() orelse false;
            return true;
        }
    }
    return false;
}

/// The latency class of one commit on the live backend: the two native rungs
/// are a single ioctl/libpulse call (`.immediate`); the two subprocess rungs
/// fork (`.rate_limited`). Per-sub query because the slider core throttles on it.
fn commitCost() slider.CommitCost {
    return switch (latchedRung(g.backend)) {
        .native_pulse, .native_alsa => .immediate,
        .pactl, .amixer, .none => .rate_limited,
    };
}

fn commitPct(v: u8) void {
    const pct = slider.clampPct(v);
    switch (latchedRung(g.backend)) {
        .native_pulse => {
            _ = g.native_pulse.?.setVolumePct(pct);
        },
        .pactl => {
            var buf: [64]u8 = undefined;
            const cmd = std.fmt.bufPrint(&buf, "pactl set-sink-volume @DEFAULT_SINK@ {d}%", .{pct}) catch return;
            _ = spawn_capture.runOk(cmd);
        },
        .amixer => {
            var buf: [64]u8 = undefined;
            const cmd = std.fmt.bufPrint(&buf, "amixer set Master {d}%", .{pct}) catch return;
            _ = spawn_capture.runOk(cmd);
        },
        .native_alsa => {
            _ = g.native_alsa.?.setVolumePct(pct);
        },
        .none => return,
    }
}

/// The one write entry point; each mode names its difference so the clamp
/// and the display update each live in one place (see brightness.zig).
fn write(w: slider.Write, v: u8) void {
    switch (w) {
        // Scroll/drag motion: the label follows immediately.
        .preview => g.pct = optimisticAfter(g.backend, v, g.pct),
        .commit => commitPct(v),
        // Press set / drag end. The value just committed IS the display
        // value, shown optimistically; the next poll confirms against the
        // real sink. With no backend the display does not move.
        .apply => {
            commitPct(v);
            g.pct = optimisticAfter(g.backend, v, g.pct);
        },
    }
}

/// Renders the display string into `buf`, substituting `{pct}` and `{state}`,
/// returning the text (plus the numeric region). Truncated tail is scan-safe.
/// With no backend at all, `muted` is forced true so the segment renders MUTE
/// rather than `VOL 0%`, which would claim a sink read that never happened.
fn renderDisplay(config: bar_config.Config, muted: bool, buf: []u8) drawing.Label {
    const effective_mute = muted or !g.has_value;
    const fmt = if (effective_mute)
        (config.volume_muted_format orelse default_muted_format)
    else
        (config.volume_format orelse default_format);
    const state: []const u8 = if (effective_mute) "mute" else "unmute";
    return drawing.renderLineValue(fmt, g.pct, state, buf);
}

/// Idle label hook: the slider core renders this during the segment's draw.
/// Test-only seam: the display state `label` reads is module-private and its
/// tests live in `src/test/bar/volume_test.zig` (run from the test ROOT, so
/// an inline test in an imported module is never analyzed). A plain `pub`
/// would export mutable global state; this scopes the write to a test name.
pub fn setDisplayForTest(pct: u8, muted: bool) void {
    g.pct = pct;
    g.muted = muted;
    // A supplied pct is by definition a level some rung read, so the seam
    // sets has-value with it. Without this the forced-MUTE path would
    // swallow every level these tests are checking.
    g.has_value = true;
}

/// Paired with `setDisplayForTest` to reach the one state that seam cannot
/// express: set, then cleared, is "a level is on screen but no rung ever read
/// one" -- the no-backend start-up condition the forced-MUTE path exists for.
pub fn clearValueForTest() void {
    g.has_value = false;
}

/// Test seam for the latch/rung mapping: a test that never clears the
/// native backends lets one stale backend choice leak into the next
/// assertion; clearing here pins each latchedRung decision to its own state.
pub fn clearNativeBackendForTest() void {
    g.native_pulse = null;
    g.native_alsa = null;
}

pub fn label(config: bar_config.Config, buf: []u8) drawing.Label {
    return renderDisplay(config, g.muted, buf);
}

/// Right-click: flip the sink's mute state. Routed through the LATCHED rung
/// like every other commit, so the native backends -- whose protocol takes
/// an ABSOLUTE mute state, not a toggle -- set the inverted observed state
/// directly instead of spawning a CLI that would talk to another mixer.
fn toggleMute() void {
    switch (latchedRung(g.backend)) {
        .native_pulse => {
            if (g.native_pulse) |*np| _ = np.setMuted(!g.muted);
        },
        .native_alsa => {
            if (g.native_alsa) |*na| _ = na.setMuted(!g.muted);
        },
        .pactl => _ = spawn_capture.runOk("pactl set-sink-mute @DEFAULT_SINK@ toggle"),
        .amixer => _ = spawn_capture.runOk("amixer set Master toggle"),
        .none => return,
    }
    _ = readVolume();
}

/// The displayed level, or null while the backend has never answered, which
/// is what makes an audio-less machine reserve no slot and take no clicks.
fn currentLevel() ?u8 {
    return if (g.has_value) g.pct else null;
}

fn writable() bool {
    return g.has_value;
}

/// The volume sub's live poll cadence from the bar config knob (default
/// 5000 ms). Wired as `Sub.read_interval_ms_of`; the static field stays as
/// the fallback default.
fn readIntervalMsFromConfig() i64 {
    return core.getState().config.bar.volume_read_interval_ms;
}

pub const sub: slider.Sub = .{
    .name = "volume",
    .read_interval_ms = 5000,
    .read_interval_ms_of = readIntervalMsFromConfig,
    .level = currentLevel,
    .writable = writable,
    .read = readVolume,
    .write = write,
    .commit_cost = commitCost,

    .label = label,
    .secondary = toggleMute,
    .probeNaturalWidth = 56,
};
