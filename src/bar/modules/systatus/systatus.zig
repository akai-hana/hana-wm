//! Systatus readout segments.
//! Every readout sub in this directory is promoted to its OWN bar segment
//! ("cpu", "mem", "batt", ...) via `segmentFor(i)`, so each readout is
//! selected, ordered, and spaced independently in `[bar.layout.*]` -- there
//! is no aggregate "systatus" belt any more. Readouts refresh on a 2 s poll.
//! All reads are plain file reads on the main thread -- no subprocesses, no
//! allocation -- so the cadence is effectively free.
//!
//! The readout modules keep binding `pub const sub: Sub`; this closed core
//! owns only the machinery every readout shares: arm-on-first-draw, the poll
//! deadline, dirty redraw requests, and the "<label> <pct>%" render.
//!
//! This per-segment lifecycle (arm once, poll a deadline, mark dirty on
//! change, track painted width) is a structural twin of slider.zig's. The
//! two are deliberately NOT merged into a shared "polled-segment" scaffold:
//! a readout is read-only on one fixed cadence, while a slider adds drag /
//! scroll interaction, a commit throttle, per-control cadences, and a click
//! bound -- so the extracted core would be a parameterised contract surface
//! (refresh + draw + cadence hooks) around a thin body. The shared 10-line
//! shape is kept explicit in each file instead; see slider.zig.

const std = @import("std");
const utils = @import("utils");
const drawing = @import("drawing");
const segmod = @import("segment");
const plugin = @import("plugin");

const read_interval_ms: i64 = 2000;

// ---------------------------------------------------------------------------
// The systatus surface is a closed-core / open-module system, like every
// surface interface in this tree:
//
//   - The CLOSED CORE is this file: the `Sub` contract plus the generic
//     per-segment poll/render machinery in `segmentFor`. It never names a
//     readout module; every readout is reached through the `subs` registry,
//     which is a generated array (see build.zig's `buildSubsRegistryModule`).
//
//   - The OPEN MODULES are the sibling `.zig` files in this directory. Each
//     binds `pub const sub: Sub`, and membership in `subs` -- and therefore a
//     bar segment named after it -- comes from FILE PRESENCE alone: build.zig
//     scans this dir, regenerates `systatus_subs`, and appends one
//     `segmentFor(i)` entry per readout to `bar_modules`. Adding a readout =
//     drop a file; deleting one = delete the file. No source edit in the
//     core, and no dead reference lingers after a readout is removed.
//
// To add a readout: drop `foo.zig` beside this file exporting
// `pub const sub: Sub`. Every file here besides systatus.zig must export it.
// ---------------------------------------------------------------------------

pub const Sub = struct {
    /// Config identity ("mem", "cpu", ...): the name its bar segment is
    /// selected by in `[bar.layout.*]`.
    name: []const u8,
    /// Label prefix rendered before the value ("Mem", "Cpu", ...).
    label: []const u8,
    /// Current readout as a 0-100 percent, or null when unreadable / not
    /// present this tick (the segment then renders nothing, zero width).
    read: *const fn () ?u8,
};

/// The readout registry, generated from file presence (build.zig). Each
/// entry becomes one standalone bar segment named `sub.name`.
pub const subs = @import("systatus_subs").subs;

/// Per-segment state, indexed by registry position (segment i == subs[i]).
var g_armed: [subs.len]bool = @splat(false);
var g_pending_redraw: [subs.len]bool = @splat(false);
var g_next_read_ms: [subs.len]i64 = @splat(0);
var g_slot_width: [subs.len]u16 = @splat(0);
/// Cached rendered text and its length; a redraw is only requested when this
/// actually changes, so the 2 s poll doesn't repaint the bar unconditionally.
var g_last: [subs.len][128]u8 = undefined;
var g_len: [subs.len]usize = @splat(0);
/// Byte range of the numeric readout ("42%") inside `g_last`; `g_value_len ==
/// 0` when there is no value this tick. The number is painted with the
/// segment's `_value` color while the label keeps its own (see
/// drawing.drawPaddedSegmentValue).
var g_value_start: [subs.len]usize = @splat(0);
var g_value_len: [subs.len]usize = @splat(0);

fn appendText(dst: []u8, start: usize, text: []const u8) usize {
    if (start >= dst.len) return start;
    const n = @min(dst.len - start, text.len);
    @memcpy(dst[start..][0..n], text[0..n]);
    return start + n;
}

/// Re-reads readout `idx` and renders "<label> <pct>%" into its slot in
/// `g_last`; a failed read renders nothing (the segment goes zero-width).
/// Returns true when the rendered text changed.
fn refresh(idx: usize) bool {
    const sub = subs[idx];

    var buf: [128]u8 = undefined;
    var n: usize = 0;
    var value_start: usize = 0;
    var value_len: usize = 0;
    if (sub.read()) |value| {
        var num: [16]u8 = undefined;
        const value_text = std.fmt.bufPrint(&num, "{d}%", .{value}) catch "";
        n = appendText(&buf, n, sub.label);
        n = appendText(&buf, n, " ");
        value_start = n;
        n = appendText(&buf, n, value_text);
        value_len = value_text.len;
    }

    const changed = g_len[idx] != n or !std.mem.eql(u8, g_last[idx][0..n], buf[0..n]);
    @memcpy(g_last[idx][0..n], buf[0..n]);
    g_len[idx] = n;
    g_value_start[idx] = value_start;
    g_value_len[idx] = value_len;
    return changed;
}

/// Poll deadline for readout `idx`: the segment doesn't arm itself until its
/// first draw (when the bar actually renders it), so an unconfigured readout
/// never wakes the loop. Returns -1 while unarmed, ms until the next read
/// otherwise (0 = due now).
fn pollDeadlineMsFor(idx: usize) i32 {
    if (!g_armed[idx]) return -1;
    const left = g_next_read_ms[idx] - utils.realtimeMs();
    if (left <= 0) return 0;
    return @intCast(@min(left, read_interval_ms));
}

fn onPollWakeupFor(idx: usize) void {
    if (!g_armed[idx]) return;
    if (utils.realtimeMs() < g_next_read_ms[idx]) return;
    g_next_read_ms[idx] = utils.realtimeMs() + read_interval_ms;
    if (refresh(idx)) g_pending_redraw[idx] = true;
}

fn consumeRedrawRequestFor(idx: usize) bool {
    const p = g_pending_redraw[idx];
    g_pending_redraw[idx] = false;
    return p;
}

/// Row reservation for readout `idx`: the last drawn width. 0 until the first
/// draw (and forever when a readout has no value to show, e.g. `batt` with no
/// battery), so an absent readout's slot fully collapses and never opens a
/// gap -- the bar lays out exactly what the segment paints. Mirrors
/// segdraw's widthState default.
fn naturalWidthFor(idx: usize) u16 {
    return g_slot_width[idx];
}

fn drawFor(idx: usize, ctx: *anyopaque, x: u16) !u16 {
    const c = segmod.castDraw(ctx);
    if (!g_armed[idx]) {
        g_armed[idx] = true;
        g_next_read_ms[idx] = utils.realtimeMs() + read_interval_ms;
        _ = refresh(idx); // prime the text so the first draw isn't empty
    }

    // Nothing to show this tick: render nothing (zero width) so an absent
    // readout -- no battery, unreadable file -- takes no space. The reserved
    // slot collapses on the next re-layout.
    if (g_len[idx] == 0) {
        if (g_slot_width[idx] != 0) {
            g_slot_width[idx] = 0;
            g_pending_redraw[idx] = true;
        }
        return x;
    }

    const value = if (g_value_len[idx] != 0)
        g_last[idx][g_value_start[idx] .. g_value_start[idx] + g_value_len[idx]]
    else
        null;
    const end_x = try drawing.drawPaddedSegmentValue(c.dc, c.config, c.height, x, subs[idx].name, g_last[idx][0..g_len[idx]], value, c.config.segmentProps(subs[idx].name));

    // Track the ACTUAL painted width, not the row reservation: the row must
    // follow the text or the segment locks onto the startup probe and paints
    // over its right neighbors ("Mem 42%" clipped by the next slot). A width
    // change marks the segment dirty so the bar re-lays out.
    const drawn = end_x - x;
    if (drawn != g_slot_width[idx]) g_pending_redraw[idx] = true;
    g_slot_width[idx] = drawn;
    return end_x;
}

/// The bar-module binding for readout `i` (comptime so each instantiation is
/// a distinct segment with its own hooks into `subs[i]`'s state). Emitted by
/// build.zig per discovered readout with a `pub const sub`, in the same
/// alphabetical order as `subs`.
pub fn segmentFor(comptime i: usize) plugin.Segment {
    const Hooks = struct {
        fn poll() i32 {
            return pollDeadlineMsFor(i);
        }
        fn wakeup() void {
            return onPollWakeupFor(i);
        }
        fn redraw() bool {
            return consumeRedrawRequestFor(i);
        }
        fn naturalWidth(_: *const anyopaque, _: u16) u16 {
            return naturalWidthFor(i);
        }
        fn draw(ctx: *anyopaque, x: u16) anyerror!u16 {
            return drawFor(i, ctx, x);
        }
    };
    return .{
        .name = subs[i].name,
        .clickable = false,
        .pollTimeoutMs = Hooks.poll,
        .onPollWakeup = Hooks.wakeup,
        .consumeRedrawRequest = Hooks.redraw,
        .naturalWidth = Hooks.naturalWidth,
        .draw = Hooks.draw,
    };
}
