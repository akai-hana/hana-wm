//! Systatus readout segments.
//! Every readout sub in this directory is promoted to its OWN bar segment
//! ("cpu", "ram", "batt", ...) via `segmentFor(i)`, so each readout is
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
const drawing = @import("drawing");
const segmod = @import("segment");
const contract = @import("contract");

const scaffold = @import("scaffold");
const time = @import("time");
const read_interval_ms: i64 = 2000;

/// Length of the per-segment rendered-text buffers: room for "<label> <pct>%"
/// (worst-case label plus a 3-digit readout). Larger than any rendered slot.
const render_buf_len: usize = 128;

// The systatus surface is a closed-core / open-module system: the CLOSED CORE
// is this file (`Sub` + the per-segment poll/render machinery); the OPEN
// MODULES are the sibling `.zig` files, each binding `pub const sub: Sub`, and
// membership in `subs` -- and therefore a bar segment named after it -- comes
// from FILE PRESENCE alone.
//
// To add a readout: drop `foo.zig` beside this file exporting
// `pub const sub: Sub`. Every file here besides systatus.zig must export it.

pub const Sub = struct {
    /// Config identity ("ram", "cpu", ...): the name its bar segment is
    /// selected by in `[bar.layout.*]`.
    name: []const u8,
    /// Label prefix rendered before the value ("RAM", "CPU", ...).
    label: []const u8,
    /// Current readout, or null when unreadable / not present this tick (the
    /// segment then renders nothing, zero width).
    read: *const fn () ?Sample,
};

/// One reading from a readout, carrying its DISPLAY text. (25.3)
///
/// This used to be `?u8` -- a bare 0-100 percent -- and the core hardcoded
/// "{d}%" when rendering it. That put the readout's presentation in the wrong
/// place: a module could not report a temperature, a byte count, or "up", and
/// the only way to express one was to abandon the systatus registry. The sample
/// now carries the formatted text, so the module owns its own presentation and
/// the core just paints two spans.
///
/// `text` is borrowed from storage the module owns (typically a module-level
/// buffer); the core COPIES it into the render buffer, so it need not outlive
/// the call.
pub const Sample = struct {
    /// Display form of the value, e.g. "42%". Rendered in the segment's
    /// value colour.
    text: []const u8,
};

/// Builds a percentage `Sample` into `buf`, the common case. Kept so the
/// existing percentage readouts do not each hand-roll the same format.
pub fn percentSample(buf: []u8, value: u8) Sample {
    return .{ .text = std.fmt.bufPrint(buf, "{d}%", .{value}) catch "?" };
}

/// The readout registry, generated from file presence (build.zig). Each
/// entry becomes one standalone bar segment named `sub.name`.
pub const subs = @import("systatus_subs").subs;

/// One file read, with truncation reported rather than hidden.
pub const FileRead = struct {
    bytes: []const u8,
    /// True when the read filled `buf` completely, so the tail was dropped and
    /// the contents cannot be trusted whole. `readSmallFile` used to discard
    /// this, which made a /proc/meminfo larger than the buffer
    /// indistinguishable from a meminfo with no MemAvailable: a truncated file
    /// read as "no RAM" rather than as the I/O problem it is.
    truncated: bool,
};

/// Opens `path` and reads its contents into `buf`, reporting whether the
/// buffer was filled (see `FileRead.truncated`). Null when absent/unreadable.
pub fn readFileChecked(path: []const u8, buf: []u8) ?FileRead {
    const io = std.Options.debug_io;
    var f = std.Io.Dir.openFileAbsolute(io, path, .{}) catch return null;
    defer f.close(io);
    const n = f.readPositionalAll(io, buf, 0) catch return null;
    return .{ .bytes = buf[0..n], .truncated = n == buf.len };
}

/// Consecutive failed reads tolerated before a readout collapses. One
/// transient miss (a sysfs attribute mid-update, an EAGAIN on procfs) must not
/// blank the segment: collapsing the row on a single failure caused a visible
/// blink plus a spurious re-lay on every hiccup. After this many consecutive
/// misses the readout is treated as genuinely gone (battery removed, file
/// deleted) and the slot collapses for real.
const miss_tolerance: u8 = 3;

/// How long a readout that has collapsed as ABSENT goes unprobed before it is
/// given one more chance. Without this, a desktop with no battery paid eight
/// futile /sys/class/power_supply opens every 2 s forever; with a plain
/// one-way latch it would never notice a battery being hot-swapped in. The
/// slow re-probe is the cost of not being wrong in either direction: the
/// absent readout is silent (no slot reserved) but not abandoned.
const absent_reprobe_ms: i64 = 30_000;

/// Per-segment state, indexed by registry position (segment i == subs[i]).
var g_armed: [subs.len]bool = @splat(false);
/// Consecutive failed reads for readout `idx`; reset on every successful read.
/// Drives the sticky last-good window (see `miss_tolerance`).
var g_misses: [subs.len]u8 = @splat(0);
/// True once readout `idx` exhausted its miss tolerance and collapsed: its
/// segment reserves nothing, and its poll slows to `absent_reprobe_ms` instead
/// of hammering an answer that is not coming. Cleared by the first success.
var g_absent: [subs.len]bool = @splat(false);
var g_pending_redraw: [subs.len]bool = @splat(false);
var g_next_read_ms: [subs.len]i64 = @splat(0);
/// The last drawn width of a readout is NOT tracked here any more: it is the
/// shared `scaffold.widthState` singleton for that readout's name, which owns
/// the store / consume / naturalWidth triple. The bar-private copy of that
/// triple (a `g_slot_width` array plus an inline "did the width change? mark
/// dirty" at the draw site) was a second implementation of code that already
/// existed, and the two could drift; every readout is comptime-indexed by
/// `segmentFor`, so one instantiation per name is exactly the state each needs.
fn widthStateFor(comptime idx: usize) type {
    return scaffold.widthState(subs[idx].name);
}
var g_last: [subs.len][render_buf_len]u8 = undefined;
var g_len: [subs.len]usize = @splat(0);
/// Byte range of the numeric readout ("42%") inside `g_last`; `g_value_len ==
/// 0` when there is no value this tick. The number is painted with the
/// segment's `_value` color while the label keeps its own (see
/// drawing.drawPaddedSegmentValue).
var g_value_start: [subs.len]usize = @splat(0);
var g_value_len: [subs.len]usize = @splat(0);

/// A rendered readout: the full segment text plus the span of the value within
/// it. (25.3) Offsets, not a subslice, so the painter never has to recover a
/// position from an address.
pub const Rendered = struct {
    text: []const u8,
    value_start: usize,
    value_len: usize,
};

/// PURE (25.3): renders "<label> <value>" into `buf` from a sample. No globals,
/// no I/O, no latching -- the absence and tolerance POLICY stays in `refresh`,
/// so this half of the segment is directly testable. Before the split, the
/// formatting, the value-span bookkeeping, the miss latching and the change
/// detection were one function over module globals, which is why none of it
/// could be tested at all.
pub fn render(label: []const u8, sample: Sample, buf: []u8) Rendered {
    var n = appendText(buf, 0, label);
    n = appendText(buf, n, " ");
    const value_start = n;
    n = appendText(buf, n, sample.text);
    return .{
        .text = buf[0..n],
        .value_start = value_start,
        // Truncation must shorten the span, or it would point past `text`.
        .value_len = n - value_start,
    };
}

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

    var buf: [render_buf_len]u8 = undefined;
    var n: usize = 0;
    var value_start: usize = 0;
    var value_len: usize = 0;
    if (sub.read()) |sample| {
        g_misses[idx] = 0;
        // Recovering from absence re-fills the rendered text, so the ordinary
        // `changed` check below requests the redraw and the width store
        // re-expands the slot -- nothing extra is needed for the recovery
        // path, only the latch itself has to be cleared.
        g_absent[idx] = false;
        const r = render(sub.label, sample, buf[0..]);
        n = r.text.len;
        value_start = r.value_start;
        value_len = r.value_len;
    } else {
        // Sticky last-good: within the tolerance window KEEP whatever is
        // already in g_last and report no change, so the segment keeps
        // painting the last known-good reading. Once the window is exhausted
        // fall through with n == 0, which is the real collapse.
        if (g_misses[idx] < miss_tolerance) g_misses[idx] += 1;
        if (g_misses[idx] < miss_tolerance) return false;
        // Tolerated window exhausted: genuinely absent, so latch it and let
        // the poll back off to the slow re-probe cadence.
        g_absent[idx] = true;
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
fn pollDeadlineMsFor(comptime idx: usize) i32 {
    if (!g_armed[idx]) return -1;
    // An absent readout still contributes a wakeup, but only on the slow
    // re-probe cadence: stopping entirely would make a hot-swapped battery or
    // a since-boot /sysfs file invisible forever.
    const interval: i64 = if (g_absent[idx]) absent_reprobe_ms else read_interval_ms;
    const left = g_next_read_ms[idx] - time.realtimeMs();
    if (left <= 0) return 0;
    return @intCast(@min(left, interval));
}

fn onPollWakeupFor(comptime idx: usize) void {
    if (!g_armed[idx]) return;
    if (time.realtimeMs() < g_next_read_ms[idx]) return;
    // The next deadline is set from the same absent/present decision the poll
    // itself makes, so the backing-off and the wakeup cannot disagree.
    g_next_read_ms[idx] = time.realtimeMs() +
        (if (g_absent[idx]) absent_reprobe_ms else read_interval_ms);
    if (refresh(idx)) g_pending_redraw[idx] = true;
}

/// A redraw is owed for either reason the segment can change shape: the
/// TEXT changed (refresh), or the painted WIDTH changed (widthState). Both are
/// consumed here, so the caller sees one answer and neither source can leak a
/// stale request.
fn consumeRedrawRequestFor(comptime idx: usize) bool {
    const p = g_pending_redraw[idx];
    g_pending_redraw[idx] = false;
    return p or widthStateFor(idx).consumeRedrawRequest();
}

fn drawFor(comptime idx: usize, ctx: *anyopaque, x: u16) !contract.Painted {
    const c = segmod.castDraw(ctx);
    if (!g_armed[idx]) {
        g_armed[idx] = true;
        g_next_read_ms[idx] = time.realtimeMs() + read_interval_ms;
        _ = refresh(idx); // prime the text so the first draw isn't empty
    }

    // Nothing to show this tick: render nothing (zero width) so an absent
    // readout -- no battery, unreadable file -- takes no space. The reserved
    // slot collapses on the next re-layout.
    if (g_len[idx] == 0) {
        // An absent readout paints nothing. Reporting a 0 width is enough:
        // the bar feeds it back through onPainted, whose store raises the
        // redraw request on change, so the collapse needs no private
        // bookkeeping here.
        return contract.Painted.nothing(x);
    }

    // (25.3) The stored offsets go straight to the painter; no subslice is
    // manufactured here just to carry a position.
    const end_x = try drawing.drawPaddedSegmentValue(c.dc, c.config, c.height, x, subs[idx].name, g_last[idx][0..g_len[idx]], g_value_start[idx], g_value_len[idx], c.config.segmentProps(subs[idx].name));

    // Report the ACTUAL painted width, not the row reservation: the row must
    // follow the text or the segment locks onto the startup probe and paints
    // over its right neighbors ("RAM 42%" clipped by the next slot). The bar
    // hands that width back through onPainted, whose store raises the redraw
    // request on change (21.7), so the re-layout is not this module's job.
    return contract.Painted.span(x, end_x);
}

/// The bar-module binding for readout `i` (comptime so each instantiation is
/// a distinct segment with its own hooks into `subs[i]`'s state). Emitted by
/// build.zig per discovered readout with a `pub const sub`, in the same
/// alphabetical order as `subs`.
pub fn segmentFor(comptime i: usize) contract.Segment {
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
        fn naturalWidth(frame: *const contract.Frame, fallback: u16) u16 {
            return widthStateFor(i).naturalWidth(frame, fallback);
        }
        fn draw(ctx: *anyopaque, x: u16) anyerror!contract.Painted {
            return drawFor(i, ctx, x);
        }
        /// Where the bar's painted-width report lands: this readout's own
        /// width state, which its naturalWidth hook reads back.
        fn onPainted(width: u16) void {
            widthStateFor(i).store(width);
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
        .onPainted = Hooks.onPainted,
    };
}
