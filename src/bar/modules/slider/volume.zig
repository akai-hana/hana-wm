//! Volume slider sub.
//! Shows the default sink's level and mute state and controls it, bound to
//! the slider core's `Sub` contract. This module owns the sink's TRUTH --
//! backend attach/probe, reads, writes, and the display format -- while the
//! slider core owns the shared render shell, interaction, poll, and commit
//! clock.
//!
//! Backends, most-native first (probed at the first read and cached; a read
//! that stops answering re-probes):
//!   1. native PulseAudio (`native_pulse`): in-process libpulse, no
//!      subprocess -- the path on PipeWire/PulseAudio machines, including
//!      ones where no `pactl` binary exists.
//!   2. `pactl` subprocess (PipeWire/PulseAudio fallback).
//!   3. native ALSA control (`native_alsa`): direct `/dev/snd/controlC*`
//!      ioctls -- only when no PulseAudio runtime is present, because with
//!      PipeWire the system `Master` is a software mixer element and the raw
//!      card control would write a different volume.
//!   4. `amixer` subprocess (fallback).
//!
//! `commit_is_native` reports whether THIS sub's commits go through an
//! in-process native call (microseconds, no subprocess): the slider core
//! throttles only the spawned paths. The 0-100 % clamp in `commit` is the
//! single guard for every caller's value; scrolling at the boundary computes
//! the same value it already has and is a zero-cost no-op.

const std = @import("std");
const types = @import("types");
const slider = @import("slider");
const native_pulse = @import("native_pulse");
const native_alsa = @import("native_alsa");

const default_format = "VOL {pct}%";
const default_muted_format = "MUTE";

const Backend = enum { unknown, pulse, alsa };

var g_backend: Backend = .unknown;
/// Native in-process PulseAudio backend (libpulse via dlopen), attached once
/// on pulsing systems. Null until probed (once) or when it cannot attach.
var g_native_pulse: ?native_pulse.Backend = null;
var g_native_pulse_probed: bool = false;
/// Native dependency-free ALSA control backend. Only attached on machines
/// without a PulseAudio runtime (where the system `Master` is the raw card
/// control). Null until probed (once).
var g_native_alsa: ?native_alsa.Master = null;
var g_native_alsa_probed: bool = false;
var g_pct: u8 = 0;
var g_muted: bool = false;
var g_has_value: bool = false;

const pactl_vol_cmd = "pactl get-sink-volume @DEFAULT_SINK@";
const pactl_mute_cmd = "pactl get-sink-mute @DEFAULT_SINK@";
const amixer_vol_cmd = "amixer get Master";

/// First `N%` in `out`, scanning the digits back from the `%`; 0-100.
fn parsePercent(out: []const u8) ?u8 {
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
    const had_value = g_has_value;
    const old_pct = g_pct;
    const old_muted = g_muted;
    var ok = false;

    if (g_backend != .alsa) {
        // 1. Native PulseAudio: one in-process libpulse round trip. Probing
        //    is once-only per session (attach connects + resolves the sink).
        if (!g_native_pulse_probed) {
            g_native_pulse_probed = true;
            g_native_pulse = native_pulse.attach();
        }
        if (g_native_pulse) |*np| {
            if (np.readSink()) |snap| {
                g_backend = .pulse;
                g_pct = snap.pct;
                g_muted = snap.muted;
                g_has_value = true;
                ok = true;
            }
        }
        // 2. pactl subprocess (PipeWire/PulseAudio without libpulse, or the
        //    live daemon disagreed with the native read).
        if (!ok) {
            var buf: [1024]u8 = undefined;
            const out = slider.runOut(pactl_vol_cmd, &buf);
            if (parsePercent(out)) |p| {
                g_backend = .pulse;
                g_pct = p;
                const out2 = slider.runOut(pactl_mute_cmd, &buf);
                g_muted = std.mem.indexOf(u8, out2, "Mute: yes") != null;
                g_has_value = true;
                ok = true;
            }
        }
    }
    // 3. Native ALSA: only valid where no PulseAudio runtime exists (with
    //    PipeWire the system Master is a softvol, not the card control).
    if (!ok) {
        if (!g_native_alsa_probed) {
            g_native_alsa_probed = true;
            if (!native_pulse.pulseReachable())
                g_native_alsa = native_alsa.openMaster();
        }
        if (g_native_alsa) |na| {
            if (na.readVolumePct()) |p| {
                g_backend = .alsa;
                g_pct = p;
                g_muted = na.readMuted() orelse g_muted;
                g_has_value = true;
                ok = true;
            }
        }
    }
    // 4. amixer subprocess (fallback).
    if (!ok) {
        var buf: [1024]u8 = undefined;
        const out = slider.runOut(amixer_vol_cmd, &buf);
        if (parsePercent(out)) |p| {
            g_backend = .alsa;
            g_pct = p;
            g_muted = std.mem.indexOf(u8, out, "[off]") != null;
            g_has_value = true;
            ok = true;
        } else {
            g_backend = .unknown;
        }
    }

    if (!g_has_value) return false;
    return !had_value or g_pct != old_pct or g_muted != old_muted;
}

/// True when the current backend commits through an in-process native call
/// (cheap: one ioctl or one libpulse round trip), which needs no throttling.
fn commitIsNative() bool {
    return switch (g_backend) {
        .pulse => g_native_pulse != null,
        .alsa => g_native_alsa != null,
        .unknown => false,
    };
}

/// Applies a level to the backend WITHOUT the follow-up re-read (the commit
/// half of the throttle path). The clamp is the single guard for every
/// caller's value (slider, scroll, config): 0-100 % is all the backend ever
/// receives. Scheduled by the slider core's throttle, which owns the commit
/// clock.
fn commitPct(v: u8) void {
    const pct = @min(v, 100);
    switch (g_backend) {
        .pulse => {
            // Native: an in-process libpulse set (no fork/exec/pipe at all).
            if (g_native_pulse) |*np| {
                _ = np.setVolumePct(pct);
            } else {
                var buf: [64]u8 = undefined;
                const cmd = std.fmt.bufPrint(&buf, "pactl set-sink-volume @DEFAULT_SINK@ {d}%", .{pct}) catch return;
                _ = slider.runOk(cmd);
            }
        },
        .alsa => {
            // Native: one SNDRV_CTL_IOCTL_ELEM_WRITE ioctl on the card.
            if (g_native_alsa) |na| {
                _ = na.setVolumePct(pct);
            } else {
                var buf: [64]u8 = undefined;
                const cmd = std.fmt.bufPrint(&buf, "amixer set Master {d}%", .{pct}) catch return;
                _ = slider.runOk(cmd);
            }
        },
        .unknown => return,
    }
}

/// One-shot apply (press, drag end): commit then re-read so the display
/// follows the sink immediately rather than on the next poll tick. The
/// scroll/drag motion paths use the core's preview + throttle and their own
/// optimistic display.
fn applyPct(v: u8) void {
    commitPct(v);
    _ = readVolume();
}

/// Optimistic display update from a scroll/drag motion: the label follows
/// immediately while the backend write is committed by the core's scheduler.
fn previewPct(v: u8) void {
    g_pct = v;
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
fn label(config: types.BarConfig, buf: []u8) slider.Label {
    return renderDisplay(config, g_muted, buf);
}

fn toggleMute() void {
    switch (g_backend) {
        .pulse => {
            if (g_native_pulse) |*np| {
                _ = np.setMuted(!g_muted);
            } else {
                _ = slider.runOk("pactl set-sink-mute @DEFAULT_SINK@ toggle");
            }
        },
        .alsa => {
            if (g_native_alsa) |na| {
                if (na.readMuted()) |muted| {
                    _ = na.setMuted(!muted);
                }
            } else {
                _ = slider.runOk("amixer set Master toggle");
            }
        },
        .unknown => return,
    }
    _ = readVolume();
}

// Current displayed level / write-gate hooks for the core.
fn currentPct() u8 {
    return g_pct;
}

fn writable() bool {
    return g_has_value;
}

pub const sub: slider.Sub = .{
    .name = "volume",
    .read_interval_ms = 5000,
    .writable = writable,
    .read = readVolume,
    .pct = currentPct,
    .preview = previewPct,
    .commit_is_native = commitIsNative,
    .commit = commitPct,
    .apply = applyPct,
    .label = label,
    .secondary = toggleMute,
    .probeNaturalWidth = 56,
};

// Tests exercise the pure, subprocess-free parsing and formatting helpers.
const testing = std.testing;

test "parsePercent extracts first N%" {
    try testing.expectEqual(@as(?u8, 42), parsePercent("Volume: 123456 / 42% / 6,56 dB"));
    try testing.expectEqual(@as(?u8, 100), parsePercent("Mono: Playback 65536 [100%] [on]"));
    try testing.expectEqual(@as(?u8, 7), parsePercent("vol 7%"));
    try testing.expectEqual(@as(?u8, null), parsePercent("no percent here"));
    try testing.expectEqual(@as(?u8, null), parsePercent(""));
}

test "label honors configuration" {
    var cfg = types.BarConfig{};
    cfg.volume_format = "Level {pct}";
    cfg.volume_muted_format = "Silenced {state}";
    var buf: [128]u8 = undefined;
    g_pct = 42;
    g_muted = false;
    try testing.expectEqualStrings("Level 42", label(&cfg, &buf).text);
    try testing.expectEqualStrings("42", label(&cfg, &buf).value.?);
    g_muted = true;
    try testing.expectEqualStrings("Silenced mute", label(&cfg, &buf).text);
    try testing.expect(label(&cfg, &buf).value == null);
    g_muted = false;
}

test "label default formats" {
    var buf: [128]u8 = undefined;
    g_pct = 33;
    g_muted = false;
    try testing.expectEqualStrings("VOL 33%", label(&(types.BarConfig{}), &buf).text);
    try testing.expectEqualStrings("33%", label(&(types.BarConfig{}), &buf).value.?);
    g_muted = true;
    try testing.expectEqualStrings("MUTE", label(&(types.BarConfig{}), &buf).text);
    g_muted = false;
}
