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
//!   1. `pactl` subprocess (PipeWire/PulseAudio).
//!   2. `amixer` subprocess (ALSA fallback).
//!
//! Both are subprocesses on purpose. A pair of in-process backends used to
//! stand in front of them -- libpulse via `dlopen`, and raw `/dev/snd/controlC*`
//! ioctls -- for 588 lines. They were removed because they bought nothing a
//! user could observe, and the honest measurement is the cost: on a machine
//! with a PulseAudio runtime but no `libpulse.so.0` installed, `pactl` is
//! absent too, so the pair traded a dependency nobody had for a fork nobody
//! needed. `commit_cost` is still reported per sub, because the throttle
//! decision is real even when every rung is a spawn; the 0-100 % clamp in
//! `commit` is the single guard for every caller's value.

const std = @import("std");
const types = @import("types");
const slider = @import("slider");

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
/// latched backend. It used to carry a second `forget_native` field for the
/// native-probe flags, which were a one-shot latch whose clearing needed its
/// own reason; with those backends gone the flag had nothing to clear.
pub const Probe = struct { walk: bool };

const ProbeDecision = enum { skip, retry, recheck };

pub fn verdict(d: ProbeDecision) Probe {
    return .{ .walk = switch (d) {
        .skip => false,
        .retry => true,
        .recheck => false,
    } };
}

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

/// Whether a PulseAudio/PipeWire daemon socket exists. This is the ONLY thing
/// `native_pulse` still contributed, and it is ten lines of `stat`, so it
/// lives here rather than in a 363-line module that also did `dlopen`.
fn pulseReachable() bool {
    var base_buf: [192]u8 = undefined;
    const base = if (std.c.getenv("XDG_RUNTIME_DIR")) |env|
        std.mem.span(env)
    else blk: {
        const uid = std.c.getuid();
        break :blk std.fmt.bufPrint(&base_buf, "/run/user/{d}", .{uid}) catch return false;
    };
    var p: [256]u8 = undefined;
    const path = std.fmt.bufPrint(&p, "{s}/pulse/native", .{base}) catch return false;
    if (path.len >= p.len) return false;
    p[path.len] = 0;
    return std.c.access(p[0..path.len :0], std.c.F_OK) == 0;
}

/// (26.7) Whether the ladder may be walked now. `probeDecision`'s clock and IO
/// edge, and the only place that mutates the cache's own bookkeeping.
fn probeDue() bool {
    const now = slider.nowMs();
    const recheck_window = now >= g_pulse_recheck_at_ms;
    const reachable = if (recheck_window) pulseReachable() else false;
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
pub const Rung = enum { pactl, amixer, none };

pub fn latchedRung(backend: Backend) Rung {
    return switch (backend) {
        .pulse => .pactl,
        .alsa => .amixer,
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

/// Re-reads level + mute from the live backend, probing most-native first
/// (native pulse -> pactl -> native ALSA -> amixer). Returns true when this
/// read changed the displayed state.
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
        .none => return null,
    }
    g_has_value = true;
    return changedFrom(had_value, old_pct, old_muted);
}

fn changedFrom(had_value: bool, old_pct: u8, old_muted: bool) bool {
    return !had_value or g_pct != old_pct or g_muted != old_muted;
}

/// The original four-rung ladder, now reached only when nothing is latched (or
/// the latch went stale). Its native-attempt flags are cleared only on the slow
/// re-probe trigger, so a daemon that appears later is retried rather than
/// written off by a one-shot `*_probed` flag.
fn runLadder() bool {
    const had_value = g_has_value;
    const old_pct = g_pct;
    const old_muted = g_muted;
    var ok = false;

    // The backend is latched: once a rung answers, that rung is the one read
    // from until it fails, so the common case is two spawns and no search.
    if (g_backend == .alsa) {
        var buf: [1024]u8 = undefined;
        const out = slider.runOut(amixer_vol_cmd, &buf);
        if (parsePercent(out)) |p| {
            g_pct = p;
            g_muted = std.mem.indexOf(u8, out, "[off]") != null;
            g_has_value = true;
            ok = true;
        } else {
            g_backend = .unknown;
        }
    } else {
        var buf: [1024]u8 = undefined;
        const out = slider.runOut(pactl_vol_cmd, &buf);
        if (parsePercent(out)) |p| {
            g_backend = .pulse;
            g_pct = p;
            const out2 = slider.runOut(pactl_mute_cmd, &buf);
            g_muted = std.mem.indexOf(u8, out2, "Mute: yes") != null;
            g_has_value = true;
            ok = true;
        } else if (g_backend == .pulse) {
            // The daemon stopped answering under us: fall through to amixer
            // rather than latching a rung that can no longer read.
            g_backend = .unknown;
        }
        if (!ok) {
            const out2 = slider.runOut(amixer_vol_cmd, &buf);
            if (parsePercent(out2)) |p| {
                g_backend = .alsa;
                g_pct = p;
                g_muted = std.mem.indexOf(u8, out2, "[off]") != null;
                g_has_value = true;
                ok = true;
            } else {
                g_backend = .unknown;
            }
        }
    }

    g_ladder_failed_at_ms = noteLadderResult(ok, slider.nowMs());
    if (!g_has_value) return false;
    return changedFrom(had_value, old_pct, old_muted);
}

/// The latency class of one commit on the live backend. Every rung is a
/// subprocess, so this is always `.rate_limited` while a backend is latched
/// and while none is; it reports `.immediate` only when the backend is known,
/// which today no rung reaches. Kept as a per-sub query because the slider
/// core throttles on it and brightness's sysfs path genuinely is immediate --
/// folding the answer to a constant here would push that distinction into
/// every caller.
fn commitCost() slider.CommitCost {
    return switch (g_backend) {
        .pulse, .alsa => .rate_limited,
        .unknown => .rate_limited,
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
    switch (g_backend) {
        .pulse => {
            var buf: [64]u8 = undefined;
            const cmd = std.fmt.bufPrint(&buf, "pactl set-sink-volume @DEFAULT_SINK@ {d}%", .{pct}) catch return;
            _ = slider.runOk(cmd);
        },
        .alsa => {
            var buf: [64]u8 = undefined;
            const cmd = std.fmt.bufPrint(&buf, "amixer set Master {d}%", .{pct}) catch return;
            _ = slider.runOk(cmd);
        },
        .unknown => return,
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
fn renderDisplay(config: types.BarConfig, muted: bool, buf: []u8) slider.Label {
    const fmt = if (muted)
        (config.volume_muted_format orelse default_muted_format)
    else
        (config.volume_format orelse default_format);
    const state: []const u8 = if (muted) "mute" else "unmute";
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
}

pub fn label(config: types.BarConfig, buf: []u8) slider.Label {
    return renderDisplay(config, g_muted, buf);
}

fn toggleMute() void {
    switch (g_backend) {
        .pulse => _ = slider.runOk("pactl set-sink-mute @DEFAULT_SINK@ toggle"),
        .alsa => _ = slider.runOk("amixer set Master toggle"),
        .unknown => return,
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
