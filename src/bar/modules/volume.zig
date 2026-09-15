//! Volume bar segment.
//! Shows the default sink's level and mute state and controls it:
//!   - wheel up/down (buttons 4/5): +/- 2 %
//!   - left press / press-hold drag: set the level from the horizontal
//!     position (the whole reserved slot is the slider; x/width maps linearly
//!     to 0-100 %)
//!   - right press: toggle mute
//! Reads happen once per 5 s poll cadence (plus an immediate first read at
//! first draw and a re-read after every apply). The backend is auto-detected
//! at first read: `pactl` (PipeWire/PulseAudio) if it answers, otherwise
//! `amixer`; the choice is cached per session and re-probed whenever a read
//! stops answering. Subprocess reads are blocking (a few ms) on the main
//! thread once per cadence, mirroring the prompt's spawn model; the widget
//! design notes accept this latency.

const std = @import("std");
const types = @import("types");
const utils = @import("utils");
const drawing = @import("drawing");
const segmod = @import("segment");

const c = @cImport({
    @cInclude("stdio.h");
});

const read_interval_ms: i64 = 5000;
const probe_natural_width: u16 = 56;

const default_format = "VOL {pct}%";
const default_muted_format = "MUTE";

const Backend = enum { unknown, pulse, alsa };

var g_backend: Backend = .unknown;
var g_pct: u8 = 0;
var g_muted: bool = false;
var g_has_value: bool = false;
var g_armed: bool = false;
var g_next_read_ms: i64 = 0;
var g_pending_redraw: bool = false;
/// Reserved slot width from the last draw; the bar records the same width as
/// the click bound, so it doubles as the slider denominator.
var g_slot_width: u16 = 0;
/// Scratch for the rendered display string; persists until the next draw so
/// the returned slice stays valid past the draw call.
var g_display: [128]u8 = undefined;
var g_display_len: usize = 0;

const pactl_vol_cmd = "pactl get-sink-volume @DEFAULT_SINK@";
const pactl_mute_cmd = "pactl get-sink-mute @DEFAULT_SINK@";
const amixer_vol_cmd = "amixer get Master";

fn nowMs() i64 {
    return @intCast(utils.realtimeNs() / std.time.ns_per_ms);
}

/// Runs `cmd` via /bin/sh and returns its captured stdout, trimmed of
/// trailing whitespace. Empty slice on any failure (popen denied, the child
/// wrote nothing, or the command is too long for the fixed buffer).
fn runOut(cmd: []const u8, buf: []u8) []const u8 {
    if (cmd.len + 1 > 256) return "";
    var cmd_buf: [256]u8 = undefined;
    @memcpy(cmd_buf[0..cmd.len], cmd);
    cmd_buf[cmd.len] = 0;
    const f = c.popen(&cmd_buf, "r") orelse return "";
    defer _ = c.pclose(f);
    const n = c.fread(buf.ptr, 1, buf.len, f);
    if (n == 0) return "";
    return std.mem.trimEnd(u8, buf[0..n], " \n\r");
}

/// Runs `cmd` and reaps the child (drains output so pclose never blocks on a
/// full pipe).
fn runReap(cmd: []const u8) void {
    var sink: [64]u8 = undefined;
    _ = runOut(cmd, &sink);
}

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

/// Re-reads level + mute from the live backend, auto-detecting pulse vs ALSA
/// on first success and re-probing after any read stops answering. Returns
/// true when this read changed the displayed state.
fn readVolume() bool {
    const had_value = g_has_value;
    const old_pct = g_pct;
    const old_muted = g_muted;
    var ok = false;

    if (g_backend != .alsa) {
        var buf: [1024]u8 = undefined;
        const out = runOut(pactl_vol_cmd, &buf);
        if (parsePercent(out)) |p| {
            g_backend = .pulse;
            g_pct = p;
            const out2 = runOut(pactl_mute_cmd, &buf);
            g_muted = std.mem.indexOf(u8, out2, "Mute: yes") != null;
            g_has_value = true;
            ok = true;
        }
    }
    if (!ok) {
        var buf: [1024]u8 = undefined;
        const out = runOut(amixer_vol_cmd, &buf);
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

/// Applies a state change, then re-reads so the display follows the sink
/// immediately rather than on the next 5 s tick.
fn setPct(v: u8) void {
    switch (g_backend) {
        .pulse => {
            var buf: [64]u8 = undefined;
            const cmd = std.fmt.bufPrint(&buf, "pactl set-sink-volume @DEFAULT_SINK@ {d}%", .{v}) catch return;
            runReap(cmd);
        },
        .alsa => {
            var buf: [64]u8 = undefined;
            const cmd = std.fmt.bufPrint(&buf, "amixer set Master {d}%", .{v}) catch return;
            runReap(cmd);
        },
        .unknown => return,
    }
    _ = readVolume();
}

fn toggleMute() void {
    switch (g_backend) {
        .pulse => runReap("pactl set-sink-mute @DEFAULT_SINK@ toggle"),
        .alsa => runReap("amixer set Master toggle"),
        .unknown => return,
    }
    _ = readVolume();
}

/// Linear slider mapping: click/drag offset across the reserved slot maps to
/// 0-100 %. The bar records the click bound at the reserved width, which this
/// module mirrors in `g_slot_width` at draw time.
fn pctFromOffset(offset: u16) u8 {
    const w: u32 = @max(@as(u32, g_slot_width), 1);
    const v: u32 = @as(u32, offset) * 100 / w;
    return @intCast(@min(v, 100));
}

/// Renders the display string into `g_display`, substituting every `{pct}`
/// and `{state}` placeholder, and returns the text. `g_display_len` is
/// updated; a truncated tail is still a complete, scan-safe string.
fn renderDisplay(config: types.BarConfig, muted: bool) []const u8 {
    const fmt = if (muted)
        (config.volume_muted_format orelse default_muted_format)
    else
        (config.volume_format orelse default_format);

    var n: usize = 0;
    var i: usize = 0;
    while (i < fmt.len and n < g_display.len) {
        if (fmt[i] == '{') {
            if (std.mem.startsWith(u8, fmt[i..], "{pct}")) {
                var b: [16]u8 = undefined;
                const pct = std.fmt.bufPrint(&b, "{d}", .{g_pct}) catch break;
                if (n + pct.len > g_display.len) break;
                @memcpy(g_display[n..][0..pct.len], pct);
                n += pct.len;
                i += 5;
                continue;
            }
            if (std.mem.startsWith(u8, fmt[i..], "{state}")) {
                const state = if (muted) "mute" else "unmute";
                if (n + state.len > g_display.len) break;
                @memcpy(g_display[n..][0..state.len], state);
                n += state.len;
                i += 7;
                continue;
            }
        }
        g_display[n] = fmt[i];
        n += 1;
        i += 1;
    }
    g_display_len = n;
    return g_display[0..n];
}

/// Poll deadline: the module doesn't arm itself until its first draw (when
/// the bar actually renders it), so an unconfigured volume segment never
/// wakes the loop. Returns -1 while unarmed, ms until the next read otherwise
/// (0 = due now).
pub fn pollDeadlineMs() i32 {
    if (!g_armed) return -1;
    const left = g_next_read_ms - nowMs();
    if (left <= 0) return 0;
    return @intCast(@min(left, read_interval_ms));
}

pub fn onPollWakeup() void {
    if (!g_armed) return;
    if (nowMs() < g_next_read_ms) return;
    g_next_read_ms = nowMs() + read_interval_ms;
    if (readVolume()) g_pending_redraw = true;
}

pub fn consumeRedrawRequest() bool {
    const p = g_pending_redraw;
    g_pending_redraw = false;
    return p;
}

fn naturalWidthHook(_: *const anyopaque, _: u16) u16 {
    return if (g_slot_width != 0) g_slot_width else probe_natural_width;
}

fn drawHook(ctx: *anyopaque, x: u16) !u16 {
    const dc = segmod.castDraw(ctx);
    // First draw is the arming read: fill the segment before its 5 s cadence.
    if (!g_armed) {
        _ = readVolume();
        g_armed = true;
        g_next_read_ms = nowMs() + read_interval_ms;
    }

    const display = renderDisplay(dc.config, g_muted);
    const end_x = try drawing.drawPaddedSegment(dc.dc, dc.config, dc.height, x, display);

    // Track the ACTUAL painted width, not the row reservation: the palette
    // must follow the text, or the segment locks onto the startup probe and
    // its neighbors overlap it, forever. A width change marks the segment
    // dirty so the bar re-lays out (matches the widthState collapse path).
    // The slot also feeds the click bound AND the slider denominator.
    const drawn = end_x - x;
    if (drawn != g_slot_width) g_pending_redraw = true;
    g_slot_width = drawn;
    return end_x;
}

/// Left click: set the level at the clicked position. Right click: toggle
/// mute. Redraws inside the click so the value updates without waiting for
/// the next cadence.
fn onClickHook(
    offset: u16,
    left: bool,
    right: bool,
    _: *anyopaque,
    _: *const fn (*anyopaque, u16) void,
    redraw: *const fn () void,
) bool {
    if (!g_has_value) return false;
    if (left) {
        setPct(pctFromOffset(offset));
    } else if (right) {
        toggleMute();
    } else {
        return false;
    }
    g_pending_redraw = true;
    redraw();
    return true;
}

fn onScrollHook(dir: i8, redraw: *const fn () void) bool {
    if (!g_has_value) return false;
    const base: u16 = g_pct;
    const new_u: u16 = if (dir > 0) @min(base + 2, 100) else base -| 2;
    setPct(@intCast(new_u));
    g_pending_redraw = true;
    redraw();
    return true;
}

fn onDragMotionHook(offset: u16, redraw: *const fn () void) bool {
    if (!g_has_value) return false;
    setPct(pctFromOffset(offset));
    g_pending_redraw = true;
    redraw();
    return true;
}

pub const module: @import("plugin").Segment = .{
    .name = "volume",
    .clickable = true,
    .self_ticking = false,
    .pollTimeoutMs = pollDeadlineMs,
    .onPollWakeup = onPollWakeup,
    .consumeRedrawRequest = consumeRedrawRequest,
    .naturalWidth = naturalWidthHook,
    .draw = drawHook,
    .onClick = onClickHook,
    .onScroll = onScrollHook,
    .onDragMotion = onDragMotionHook,
};

// Tests exercise the pure, subprocess-free geometry and formatting helpers.
const testing = std.testing;

test "parsePercent extracts first N%" {
    try testing.expectEqual(@as(?u8, 42), parsePercent("Volume: 123456 / 42% / 6,56 dB"));
    try testing.expectEqual(@as(?u8, 100), parsePercent("Mono: Playback 65536 [100%] [on]"));
    try testing.expectEqual(@as(?u8, 7), parsePercent("vol 7%"));
    try testing.expectEqual(@as(?u8, null), parsePercent("no percent here"));
    try testing.expectEqual(@as(?u8, null), parsePercent(""));
}

test "pctFromOffset uses reserved width" {
    g_slot_width = 100;
    try testing.expectEqual(@as(u8, 0), pctFromOffset(0));
    try testing.expectEqual(@as(u8, 50), pctFromOffset(50));
    try testing.expectEqual(@as(u8, 100), pctFromOffset(100));
    try testing.expectEqual(@as(u8, 1), pctFromOffset(1));
}

fn placeholderText(config: types.BarConfig, muted: bool) []const u8 {
    return renderDisplay(config, muted);
}

test "renderDisplay honors configuration" {
    var cfg = types.BarConfig{};
    cfg.volume_format = "Level {pct}";
    cfg.volume_muted_format = "Silenced {state}";
    g_pct = 42;
    g_muted = false;
    try testing.expectEqualStrings("Level 42", placeholderText(cfg, false));
    g_muted = true;
    try testing.expectEqualStrings("Silenced mute", placeholderText(cfg, true));
    g_muted = false;
}

test "default formats" {
    const cfg = types.BarConfig{};
    g_pct = 33;
    g_muted = false;
    try testing.expectEqualStrings("VOL 33%", placeholderText(cfg, false));
    g_muted = true;
    try testing.expectEqualStrings("MUTE", placeholderText(cfg, true));
    g_muted = false;
}
