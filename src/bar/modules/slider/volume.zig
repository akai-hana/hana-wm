//! Volume slider sub: shows the default sink's level and mute state and
//! controls it, bound to the slider core's `Sub` contract. This module owns
//! the sink's TRUTH (backend probe, reads, writes, display format); the
//! slider core owns the shared render shell, interaction, poll and commit
//! clock.
//!
//! Backends are `Rung`s, tried in this order:
//!   1. `pactl`  -- PulseAudio and PipeWire (`pipewire-pulse`).
//!   2. `amixer` -- ALSA, when alsa-utils is installed.
//!   3. `/dev/snd/controlC*` ioctls (`native_alsa.zig`) -- the ALSA floor.
//! The first rung that answers a read is LATCHED: later reads, writes and
//! mute toggles go straight to it until a read fails, which unlatches it and
//! walks the ladder again. A ladder that found nothing is negative-cached so
//! a dead daemon cannot cost a pair of subprocesses on every poll; the cache
//! is undone by a daemon-reachability flip or a slow deadline, so a daemon
//! that starts later is still picked up.
//!
//! `commit_cost` is per-rung: in-process ioctls are `.immediate`, spawned
//! commands are `.rate_limited` by the slider core's throttle.

const std = @import("std");
const log = std.log.scoped(.volume);
const bar_config = @import("bar_config");
const slider = @import("slider");
const drawing = @import("drawing");
const spawn_capture = @import("spawn_capture");
const core = @import("core");
const native_alsa = @import("native_alsa");

const c = @cImport({
    @cInclude("unistd.h");
    @cInclude("stdlib.h");
});

const default_format = "VOL {pct}%";
const default_muted_format = "MUTE";

pub const reprobe_interval_ms: i64 = 15_000;

const Reading = struct { pct: u8, muted: bool };

/// One way of talking to the mixer. `read` returns null when the rung cannot
/// answer (tool missing, device absent, unparsable output).
const Rung = struct {
    read: *const fn () ?Reading,
    set: *const fn (u8) void,
    toggle_mute: *const fn () void,
    immediate: bool = false,
};

/// A rung driven through a shell command. `mute_get` is the command whose
/// output carries the mute state, or empty when `get` already reports it.
fn shellRung(
    comptime get: []const u8,
    comptime mute_get: []const u8,
    comptime muted_token: []const u8,
    comptime set_fmt: []const u8,
    comptime toggle: []const u8,
) Rung {
    return .{
        .read = struct {
            fn f() ?Reading {
                var buf: [1024]u8 = undefined;
                var out = spawn_capture.runOut(get, &buf);
                const pct = parsePercent(out) orelse return null;
                if (mute_get.len != 0) out = spawn_capture.runOut(mute_get, &buf);
                return .{ .pct = pct, .muted = std.mem.indexOf(u8, out, muted_token) != null };
            }
        }.f,
        .set = struct {
            fn f(pct: u8) void {
                var buf: [64]u8 = undefined;
                const cmd = std.fmt.bufPrint(&buf, set_fmt, .{pct}) catch return;
                _ = spawn_capture.runOk(cmd);
            }
        }.f,
        .toggle_mute = struct {
            fn f() void {
                _ = spawn_capture.runOk(toggle);
            }
        }.f,
    };
}

var alsa: ?native_alsa.Master = null;

const alsa_rung: Rung = .{
    .read = struct {
        fn f() ?Reading {
            if (alsa == null) alsa = native_alsa.openMaster();
            const m = alsa orelse return null;
            return .{ .pct = m.readVolumePct() orelse return null, .muted = m.readMuted() orelse false };
        }
    }.f,
    .set = struct {
        fn f(pct: u8) void {
            if (alsa) |m| _ = m.setVolumePct(pct);
        }
    }.f,
    .toggle_mute = struct {
        fn f() void {
            if (alsa) |m| _ = m.setMuted(!g.muted);
        }
    }.f,
    .immediate = true,
};

const rungs = [_]Rung{
    shellRung("pactl get-sink-volume @DEFAULT_SINK@", "pactl get-sink-mute @DEFAULT_SINK@", "Mute: yes", "pactl set-sink-volume @DEFAULT_SINK@ {d}%", "pactl set-sink-mute @DEFAULT_SINK@ toggle"),
    shellRung("amixer get Master", "", "[off]", "amixer set Master {d}%", "amixer set Master toggle"),
    alsa_rung,
};

var g: struct {
    rung: ?*const Rung = null,
    pct: u8 = 0,
    muted: bool = false,
    has_value: bool = false,
    failed_at_ms: ?i64 = null,
    recheck_at_ms: i64 = 0,
    reachable: ?bool = null,
    warned: bool = false,
} = .{};

pub const Probe = struct { walk: bool };

/// Whether a failed ladder is walked again now: after the slow deadline, or
/// when the daemon's reachability flipped since the last recheck window.
pub fn probeDecision(now: i64, failed_at_ms: ?i64, recheck_at_ms: i64, last_reachable: ?bool, reachable: bool) Probe {
    const failed_at = failed_at_ms orelse return .{ .walk = true };
    if (now -| failed_at >= reprobe_interval_ms) return .{ .walk = true };
    if (now >= recheck_at_ms) return .{ .walk = last_reachable != reachable };
    return .{ .walk = false };
}

/// Cheap "is a PulseAudio/PipeWire socket there" check: the re-probe trigger.
fn pulseReachable() bool {
    var rt: [64]u8 = undefined;
    var path: [256]u8 = undefined;
    const dir = if (c.getenv("XDG_RUNTIME_DIR")) |e| std.mem.span(e) else std.fmt.bufPrint(&rt, "/run/user/{d}", .{c.getuid()}) catch return false;
    const p = std.fmt.bufPrintZ(&path, "{s}/pulse/native", .{dir}) catch return false;
    return c.access(p, c.F_OK) == 0;
}

fn probeDue() bool {
    const now = core.realtimeMs();
    const window = now >= g.recheck_at_ms;
    const reachable = window and pulseReachable();
    const walk = probeDecision(now, g.failed_at_ms, g.recheck_at_ms, g.reachable, reachable).walk;
    if (window) {
        g.recheck_at_ms = now + reprobe_interval_ms;
        g.reachable = reachable;
    }
    return walk;
}

/// First `N%` in `out`, clamped to 100.
pub fn parsePercent(out: []const u8) ?u8 {
    for (out, 0..) |ch, i| {
        if (ch != '%') continue;
        var j = i;
        while (j > 0 and std.ascii.isDigit(out[j - 1])) j -= 1;
        if (j == i) continue;
        const v = std.fmt.parseUnsigned(u8, out[j..i], 10) catch continue;
        return @min(v, 100);
    }
    return null;
}

/// Stores a fresh reading; true when what the bar shows changed.
fn accept(r: Reading) bool {
    const changed = !g.has_value or g.pct != r.pct or g.muted != r.muted;
    g.pct = r.pct;
    g.muted = r.muted;
    g.has_value = true;
    g.warned = false;
    return changed;
}

fn readVolume() bool {
    if (g.rung) |rung| {
        if (rung.read()) |r| return accept(r);
        g.rung = null;
    }
    if (!probeDue()) return false;
    for (&rungs) |*rung| {
        if (rung.read()) |r| {
            g.rung = rung;
            g.failed_at_ms = null;
            return accept(r);
        }
    }
    g.failed_at_ms = core.realtimeMs();
    if (!g.warned) log.warn("volume: no usable backend (pactl, amixer and /dev/snd/controlC* all failed); showing MUTE", .{});
    g.warned = true;
    return false;
}

fn commitCost() slider.CommitCost {
    return if (g.rung) |r| (if (r.immediate) .immediate else .rate_limited) else .rate_limited;
}

/// `.preview` moves only the display, `.commit` only the sink, `.apply` both.
/// With no backend there is no sink to write, so nothing moves: the display
/// must never show a level the sink did not accept.
fn write(w: slider.Write, v: u8) void {
    const rung = g.rung orelse return;
    const pct = slider.clampPct(v);
    if (w != .preview) rung.set(pct);
    if (w != .commit) g.pct = pct;
}

fn toggleMute() void {
    const rung = g.rung orelse return;
    rung.toggle_mute();
    _ = readVolume();
}

pub fn label(config: *const bar_config.Config, buf: []u8) drawing.Label {
    const muted = g.muted or !g.has_value;
    const fmt = if (muted)
        (config.volume_muted_format orelse default_muted_format)
    else
        (config.volume_format orelse default_format);
    return drawing.renderLineValue(fmt, g.pct, if (muted) "mute" else "unmute", buf);
}

pub fn setDisplayForTest(pct: u8, muted: bool) void {
    g.pct = pct;
    g.muted = muted;
    g.has_value = true;
}

pub fn clearValueForTest() void {
    g.has_value = false;
}

/// Latches a rung that writes nothing, so `write`/`commit_cost` can be driven
/// without a mixer; null unlatches.
pub fn latchStubForTest(immediate: ?bool) void {
    const stub = struct {
        fn read() ?Reading {
            return null;
        }
        fn set(_: u8) void {}
        fn toggle() void {}
        var imm: Rung = .{ .read = read, .set = set, .toggle_mute = toggle, .immediate = true };
        var lazy: Rung = .{ .read = read, .set = set, .toggle_mute = toggle };
    };
    g.rung = if (immediate) |i| (if (i) &stub.imm else &stub.lazy) else null;
}

fn currentLevel() ?u8 {
    return if (g.has_value) g.pct else null;
}

fn writable() bool {
    return g.has_value;
}

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
