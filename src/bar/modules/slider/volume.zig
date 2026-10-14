//! Volume slider sub.
//! Shows the default sink's level and mute state and controls it, bound to
//! the slider core's `Sub` contract. This module owns the sink's TRUTH --
//! backend attach/probe, reads, writes, and the display format -- while the
//! slider core owns the shared render shell, interaction, poll, and commit
//! clock.
//!
//! Backends, most-native first. The resolved backend is LATCHED (26.7): once a
//! read has identified one, later reads go straight to it instead of re-walking
//! the ladder, and a ladder that found nothing is negative-cached for a while
//! so a dead daemon cannot cost a fresh pair of subprocesses on every press,
//! right-click and 5 s poll. Both directions are undone by the same trigger --
//! a daemon-reachability recheck, plus a slow deadline -- so a daemon that
//! starts after we gave up on it is still picked up:
//!   1. `libpulse` via dlopen (`native_pulse.zig`) -- PulseAudio AND every
//!      real PipeWire desktop (`pipewire-pulse` ships the `libpulse.so.0`
//!      ABI). In-process, one socket round trip per commit.
//!   2. `pactl` subprocess -- the split-packaging case: the .so absent
//!      but the CLI present.
//!   3. `amixer` subprocess -- ALSA, when alsa-utils is installed.
//!   4. `/dev/snd/controlC*` ioctls (`native_alsa.zig`) -- the ALSA
//!      floor: kernel ioctls, no userspace tool required at all.
//!
//! The two native rungs are why `commit_cost` is a per-sub query: they are
//! single in-process round trips (`.immediate`), while the two subprocess
//! rungs fork (`.rate_limited`), and the slider core throttles on the
//! difference. The 0-100 % clamp in `commit` is the single guard for every
//! caller's value.

const std = @import("std");
const log = @import("log");
const types = @import("types");
const slider = @import("slider");
const native_pulse = @import("native_pulse");
const native_alsa = @import("native_alsa");

const default_format = "VOL {pct}%";
const default_muted_format = "MUTE";

const Backend = enum { unknown, pulse, alsa };

var g_backend: Backend = .unknown;
var g_pct: u8 = 0;
var g_muted: bool = false;
var g_has_value: bool = false;

/// (26.7) Negative cache for a ladder that found no working backend. Null
/// until the first total failure. Without it every read against a dead daemon
/// re-walked all four rungs -- up to three `popen`s, each blocking the WM
/// loop -- and the poll, every press and every right-click paid it again.
var g_ladder_failed_at_ms: ?i64 = null;

/// Attached handles for the two in-process rungs. Non-null means the rung won
/// the ladder walk and is latched. Probed lazily and never given up on: a
/// `null` here only means "not attached yet", and the reachability recheck in
/// `probeDue` is what allows a late-appearing daemon to be picked up.
var g_native_pulse: ?native_pulse.Backend = null;
var g_native_alsa: ?native_alsa.Master = null;
/// When the daemon is next re-checked for having come back. Separate from the
/// negative cache's deadline so the cheap reachability check can trigger a
/// retry long before the cache expires.
var g_pulse_recheck_at_ms: i64 = 0;
/// Last observed daemon reachability, so a CHANGE can be recognised. Null
/// until first observed.
var g_pulse_reachable: ?bool = null;
/// How long a failed ladder is trusted before being re-walked regardless.
pub const reprobe_interval_ms: i64 = 15_000;

/// What the negative cache says about one poll: whether the ladder may be
/// walked. One bool, because there is now exactly one thing to forget: the
/// latched backend. (The native rungs' one-shot attach is un-latched by a
/// daemon-reachability CHANGE instead -- see `probeDue` -- which is what
/// finds a daemon that started after this cache wrote the machine off.)
pub const Probe = struct { walk: bool };

/// (26.7) The pure re-probe decision. All the timing policy, with no clock and
/// no IO, so it is testable: whether a poll may walk the ladder again, and
/// whether it must first re-ask whether a daemon is reachable.
///
///   - No recorded failure: the ladder has never run to completion, so it runs.
///   - The slow deadline has passed: retry on the deadline alone.
///   - The recheck window has arrived: ask again; a CHANGED answer is the
///     trigger that finds a daemon started after we wrote it off, without
///     paying for the ladder on every poll.
///   - Otherwise: skip, which is the whole point of the negative cache.
pub fn probeDecision(
    now: i64,
    failed_at_ms: ?i64,
    recheck_at_ms: i64,
    last_reachable: ?bool,
    reachable: bool,
) Probe {
    // No recorded failure: the ladder has never run to completion, so run it
    // even if the daemon looks exactly as it did last time. "Unchanged" is
    // only evidence once there is a previous observation to be unchanged from.
    if (failed_at_ms == null) return .{ .walk = true };
    const failed_at = failed_at_ms.?;
    if (now -| failed_at >= reprobe_interval_ms) return .{ .walk = true };
    if (now >= recheck_at_ms) {
        // The daemon was asked again. Only a CHANGED answer un-latches, which
        // is what finds a daemon that started after we wrote it off.
        return .{ .walk = last_reachable == null or last_reachable.? != reachable };
    }
    return .{ .walk = false };
}

/// (26.7) Whether the ladder may be walked now. `probeDecision`'s clock and IO
/// edge, and the only place that mutates the cache's own bookkeeping.
fn probeDue() bool {
    const now = slider.nowMs();
    const recheck_window = now >= g_pulse_recheck_at_ms;
    const reachable = if (recheck_window) native_pulse.pulseReachable() else false;
    const probe = probeDecision(
        now,
        g_ladder_failed_at_ms,
        g_pulse_recheck_at_ms,
        g_pulse_reachable,
        reachable,
    );
    if (recheck_window) {
        g_pulse_recheck_at_ms = now + reprobe_interval_ms;
        g_pulse_reachable = reachable;
    }
    // A daemon that appeared (or vanished) is worth a fresh native attach: the
    // one-shot probed flag would otherwise write the machine off for the rest
    // of the session. Only the reachability change grants this.
    return probe.walk;
}

/// The rung a latched backend is read through. Named, not inlined into
/// `readLatched`, so the backend -> rung mapping is checkable without a
/// daemon: the point of the latch is that this mapping is consulted directly
/// and never re-derived by re-walking the ladder.
pub const Rung = enum { native_pulse, pactl, amixer, native_alsa, none };

pub fn latchedRung(backend: Backend) Rung {
    return switch (backend) {
        .pulse => if (g_native_pulse != null) .native_pulse else .pactl,
        .alsa => if (g_native_alsa != null) .native_alsa else .amixer,
        .unknown => .none,
    };
}

/// (26.7) The level a press should show without re-reading. Null means "show
/// nothing new": with no backend, `commitPct` wrote nothing, so echoing the
/// value back would display a level the sink never accepted.
pub fn optimisticLevel(backend: Backend, v: u8) ?u8 {
    return if (backend == .unknown) null else clampPct(v);
}

/// The display level after a press. Value in, value out, so the "with no
/// backend the display does not move" half of the contract is checkable: with
/// `unknown`, `commitPct` wrote nothing, and echoing the value back would show
/// a level the sink never accepted.
pub fn optimisticAfter(backend: Backend, v: u8, current: u8) u8 {
    return optimisticLevel(backend, v) orelse current;
}

/// The negative cache after one ladder run. A rung answered, so the cache is
/// CLEARED -- an armed failure must never outlive the success that disproved
/// it, or a recovered daemon would stay unwalked. Nothing answered, so it is
/// armed at `now`, which is what stops the next poll, press and right-click
/// from re-paying for up to three blocked subprocess spawns.
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

/// Whether the "no sound system at all" reason has already been logged. Armed
/// once per process: the poll loop would otherwise repeat the same line every
/// 5 s for the life of the session, and a bar that says the same thing every
/// five seconds is how a real fault gets ignored.
var g_reason_logged: bool = false;

/// The one-time diagnostic for a machine where every rung failed. Distinct
/// from the MUTE display: MUTE is the steady state (the sink may genuinely be
/// muted), this is the one line saying *why* there is no level to show.
fn logNoBackend() void {
    if (g_reason_logged) return;
    g_reason_logged = true;
    log.warn(
        "volume: no usable backend (libpulse.so.0, pactl, amixer and " ++
            "/dev/snd/controlC* all failed); showing MUTE",
        .{},
    );
}

/// Re-reads level + mute from the live backend, walking the ladder
/// (libpulse -> pactl -> amixer -> native ALSA). Returns true when this read
/// changed the displayed state.
fn readVolume() bool {
    // (26.7) A LATCHED backend is read directly. This is the change that takes
    // the ladder off the hot path: previously every read re-walked the rungs
    // from the top, re-attempting a native attach and, when the daemon was
    // dead, spawning pactl/amixer on every poll, press and right-click.
    if (g_backend != .unknown) {
        if (readLatched()) |changed| return changed;
        // The latched backend stopped answering (daemon restarted, card
        // unplugged). Forget it and let the ladder decide again -- but the
        // negative cache still applies, so this is not a free re-probe either.
        g_backend = .unknown;
    }
    if (!probeDue()) return false;
    return runLadder();
}

/// Reads only the currently latched backend. Returns null when that backend
/// does not answer, which tells `readVolume` to fall back to the ladder.
fn readLatched() ?bool {
    const had_value = g_has_value;
    const old_pct = g_pct;
    const old_muted = g_muted;
    // One read per rung. `pactl` needs two commands (level, then mute), so the
    // two rungs share a shape but not a body.
    switch (latchedRung(g_backend)) {
        .native_pulse => {
            const sink = g_native_pulse.?.readSink() orelse return null;
            g_pct = sink.pct;
            g_muted = sink.muted;
        },
        .pactl => {
            var buf: [1024]u8 = undefined;
            const out = slider.runOut(pactl_vol_cmd, &buf);
            g_pct = parsePercent(out) orelse return null;
            const out2 = slider.runOut(pactl_mute_cmd, &buf);
            g_muted = std.mem.indexOf(u8, out2, "Mute: yes") != null;
        },
        .amixer => {
            var buf: [1024]u8 = undefined;
            const out = slider.runOut(amixer_vol_cmd, &buf);
            g_pct = parsePercent(out) orelse return null;
            g_muted = std.mem.indexOf(u8, out, "[off]") != null;
        },
        .native_alsa => {
            g_pct = g_native_alsa.?.readVolumePct() orelse return null;
            g_muted = g_native_alsa.?.readMuted() orelse false;
        },
        .none => return null,
    }
    g_has_value = true;
    g_reason_logged = false;
    return changedFrom(had_value, old_pct, old_muted);
}

fn changedFrom(had_value: bool, old_pct: u8, old_muted: bool) bool {
    return !had_value or g_pct != old_pct or g_muted != old_muted;
}

/// The four-rung ladder, reached only when nothing is latched (or the latch
/// went stale). Order is by protocol family, not by speed:
///
///   1. libpulse via dlopen  -- PulseAudio AND every real PipeWire desktop,
///      because `pipewire-pulse` ships a `libpulse.so.0` ABI. One rung, two
///      systems, no fork.
///   2. `pactl`              -- the same family again, for the split-packaging
///      case where the .so is absent but the CLI is not.
///   3. `amixer`             -- ALSA, when alsa-utils is installed.
///   4. `/dev/snd/controlC*` -- the ALSA floor: kernel ioctls, no userspace
///      tool required at all.
///
/// Deliberately NOT "most-native first". Native rung 1 beats `pactl` on latency,
/// but rung 1 only exists on Pulse-family machines; putting it ahead of `amixer`
/// would cost a failed dlopen on every pure-ALSA box. Ordering by family keeps
/// each machine's first probe the one that can actually answer.
///
/// Rungs 1 and 4 are the coverage floor: a PulseAudio install without
/// pulseaudio-utils, or a kernel ALSA box without alsa-utils, has no CLI at all
/// and is reachable only through them.
fn runLadder() bool {
    const had_value = g_has_value;
    const old_pct = g_pct;
    const old_muted = g_muted;
    var ok = false;

    if (tryRungNativePulse()) {
        ok = true;
    } else if (tryRung(.pulse, pactl_vol_cmd, pactl_mute_cmd, "Mute: yes")) |v| {
        g_pct = v;
        g_muted = g_pulse_muted;
        g_backend = .pulse;
        ok = true;
    } else if (tryRung(.alsa, amixer_vol_cmd, "", "[off]")) |v| {
        g_pct = v;
        g_muted = g_alsa_muted;
        g_backend = .alsa;
        ok = true;
    } else if (tryRungNativeAlsa()) {
        ok = true;
    } else {
        g_backend = .unknown;
    }

    g_ladder_failed_at_ms = noteLadderResult(ok, slider.nowMs());
    if (!ok) {
        logNoBackend();
        return false;
    }
    g_has_value = true;
    g_reason_logged = false;
    return changedFrom(had_value, old_pct, old_muted);
}

/// Mute flag captured alongside the level by `tryRung`. Split out because the
/// two subprocess rungs differ only in their mute token and command set.
var g_pulse_muted: bool = false;
var g_alsa_muted: bool = false;

/// One subprocess rung: run `vol_cmd`, parse a percentage, then derive the mute
/// state. `mute_cmd` empty means the mute answer is in the volume output
/// (`amixer` reports both in one line).
fn tryRung(backend: Backend, vol_cmd: []const u8, mute_cmd: []const u8, on_token: []const u8) ?u8 {
    var buf: [1024]u8 = undefined;
    const out = slider.runOut(vol_cmd, &buf);
    const pct = parsePercent(out) orelse return null;
    const muted = if (mute_cmd.len == 0)
        std.mem.indexOf(u8, out, on_token) != null
    else blk: {
        const m = slider.runOut(mute_cmd, &buf);
        break :blk std.mem.indexOf(u8, m, on_token) != null;
    };
    switch (backend) {
        .pulse => g_pulse_muted = muted,
        .alsa => g_alsa_muted = muted,
        .unknown => {},
    }
    return pct;
}

fn tryRungNativePulse() bool {
    if (g_native_pulse == null) g_native_pulse = native_pulse.attach();
    if (g_native_pulse) |*np| {
        if (np.readSink()) |sink| {
            g_backend = .pulse;
            g_pct = sink.pct;
            g_muted = sink.muted;
            return true;
        }
    }
    return false;
}

fn tryRungNativeAlsa() bool {
    if (g_native_alsa == null) g_native_alsa = native_alsa.openMaster();
    if (g_native_alsa) |*na| {
        if (na.readVolumePct()) |pct| {
            g_backend = .alsa;
            g_pct = pct;
            g_muted = na.readMuted() orelse false;
            return true;
        }
    }
    return false;
}

/// The latency class of one commit on the live backend: the two native rungs
/// are a single ioctl (or an in-process libpulse call) and report
/// `.immediate`, while the two subprocess rungs fork and are
/// `.rate_limited`. Kept as a per-sub query because the slider core throttles
/// on it and brightness's sysfs path genuinely is immediate -- folding the
/// answer to a constant here would push that distinction into every
/// caller.
/// The slider core throttles on this, so folding it to a constant would either
/// throttle the native path needlessly or let the subprocess rungs commit on
/// every scroll event.
fn commitCost() slider.CommitCost {
    return switch (latchedRung(g_backend)) {
        .native_pulse, .native_alsa => .immediate,
        .pactl, .amixer, .none => .rate_limited,
    };
}

/// The one clamp every level passes: 0-100 % is all the backend ever
/// receives. `commitPct` and every `write` mode MUST go through the same
/// function -- they used to clamp independently, and when the preview path
/// forgot to, a scroll/drag motion could display a level the backend then
/// refused.
pub fn clampPct(v: u8) u8 {
    return @min(v, 100);
}

fn commitPct(v: u8) void {
    const pct = clampPct(v);
    switch (latchedRung(g_backend)) {
        .native_pulse => {
            _ = g_native_pulse.?.setVolumePct(pct);
        },
        .pactl => {
            var buf: [64]u8 = undefined;
            const cmd = std.fmt.bufPrint(&buf, "pactl set-sink-volume @DEFAULT_SINK@ {d}%", .{pct}) catch return;
            _ = slider.runOk(cmd);
        },
        .amixer => {
            var buf: [64]u8 = undefined;
            const cmd = std.fmt.bufPrint(&buf, "amixer set Master {d}%", .{pct}) catch return;
            _ = slider.runOk(cmd);
        },
        .native_alsa => {
            _ = g_native_alsa.?.setVolumePct(pct);
        },
        .none => return,
    }
}

/// The one write entry point (26.8), replacing `previewPct` / `commitPct` /
/// `applyPct`. See brightness.zig's for why the three were one function with a
/// mode: the clamp and the display update existed three times each, and a
/// preview that skipped the clamp showed a level the sink would refuse.
fn write(w: slider.Write, v: u8) void {
    switch (w) {
        // Scroll/drag motion: the label follows immediately while the backend
        // write is the core scheduler's business.
        .preview => g_pct = optimisticAfter(g_backend, v, g_pct),
        .commit => commitPct(v),
        // Press set / drag end. (26.7) The follow-up read is gone: it forced a
        // full re-probe -- and with an unresolved backend, up to three
        // subprocess spawns blocking the WM loop -- on every press and every
        // right-click. The value just committed IS the display value, so it is
        // shown optimistically and the next poll confirms it against the real
        // sink. With no backend the display does not move, because commitPct
        // wrote nothing and echoing the value would show a level the sink
        // never accepted.
        .apply => {
            commitPct(v);
            g_pct = optimisticAfter(g_backend, v, g_pct);
        },
    }
}

/// Renders the display string into `buf`, substituting every `{pct}` and
/// `{state}` placeholder, and returns the text (plus the numeric region); a
/// truncated tail is still a complete, scan-safe string.
/// With no backend at all, `muted` is forced true so the segment renders MUTE
/// rather than `VOL 0%`. `VOL 0%` would be a lie -- it claims a level was read
/// from a sink when no sink was ever reached -- and it is also the one string
/// that reads as "muted" to a user while inviting a pointless volume-up scroll.
/// MUTE is the honest terminal state and matches what the user asked for.
fn renderDisplay(config: types.BarConfig, muted: bool, buf: []u8) slider.Label {
    const effective_mute = muted or !g_has_value;
    const fmt = if (effective_mute)
        (config.volume_muted_format orelse default_muted_format)
    else
        (config.volume_format orelse default_format);
    const state: []const u8 = if (effective_mute) "mute" else "unmute";
    return slider.renderLineValue(fmt, g_pct, state, buf);
}

/// Idle label hook: the slider core renders this during the segment's draw.
/// Test-only seam: the display state `label` reads (`g_pct`, `g_muted`) is
/// module-private, and the inline tests that used to live in this file had
/// direct access to it. They are dead for good reason, not just unused: this
/// harness runs tests from the test ROOT, so an inline test in an imported
/// module is never even ANALYZED. The two `label` tests below were still calling
/// the pre-26.8 by-pointer signature, so they could not have compiled had they
/// run. They now live in `src/test/bar/volume_test.zig` and need this to set
/// their state. A plain `pub` on the globals would export mutable global state to
/// every importer; this scopes the write to an obviously test-shaped name.
pub fn setDisplayForTest(pct: u8, muted: bool) void {
    g_pct = pct;
    g_muted = muted;
    // A supplied pct is by definition a level some rung read, so the seam sets
    // the has-value flag with it. Without this the forced-MUTE path in
    // `renderDisplay` would swallow every level these tests are checking.
    g_has_value = true;
}

/// Paired with `setDisplayForTest` to reach the one state that seam cannot
/// express: set, then cleared, is "a level is on screen but no rung ever read
/// one", which is exactly the no-backend start-up condition the forced-MUTE
/// path exists for.
pub fn clearValueForTest() void {
    g_has_value = false;
}

/// Test seam for the latch/rung mapping: the native backends are process
/// globals latched once, and a test that never clears them lets one stale
/// backend choice leak into the next test's assertion. Clearing here keeps each
/// latchedRung decision pinned to this test's own state.
pub fn clearNativeBackendForTest() void {
    g_native_pulse = null;
    g_native_alsa = null;
}

pub fn label(config: types.BarConfig, buf: []u8) slider.Label {
    return renderDisplay(config, g_muted, buf);
}

/// Right-click: flip the sink's mute state. Routed through the LATCHED
/// rung like every other commit (`commitPct`), so the native backends --
/// whose protocol takes an ABSOLUTE mute state, not a toggle -- set the
/// inverted observed state directly instead of spawning a `pactl`/`amixer`
/// that would talk to a different mixer than the latched backend reads.
/// Returns through the same follow-up read, so the display reflects what
/// the sink actually did.
fn toggleMute() void {
    switch (latchedRung(g_backend)) {
        .native_pulse => {
            if (g_native_pulse) |*np| _ = np.setMuted(!g_muted);
        },
        .native_alsa => {
            if (g_native_alsa) |*na| _ = na.setMuted(!g_muted);
        },
        .pactl => _ = slider.runOk("pactl set-sink-mute @DEFAULT_SINK@ toggle"),
        .amixer => _ = slider.runOk("amixer set Master toggle"),
        .none => return,
    }
    _ = readVolume();
}

/// The displayed level, or null while the backend has never answered, which is
/// what makes an audio-less machine reserve no slot and take no clicks. The
/// absence and the value used to be a `{bool, u8}` pair latched together
/// (26.8); one optional cannot hold half of them.
fn currentLevel() ?u8 {
    return if (g_has_value) g_pct else null;
}

fn writable() bool {
    return g_has_value;
}

pub const sub: slider.Sub = .{
    .name = "volume",
    .read_interval_ms = 5000,
    .level = currentLevel,
    .writable = writable,
    .read = readVolume,
    .write = write,
    .commit_cost = commitCost,

    .label = label,
    .secondary = toggleMute,
    .probeNaturalWidth = 56,
};
