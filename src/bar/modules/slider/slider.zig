//! Slider control segments (volume, brightness, ...).
//! Every control sub in this directory is promoted to its OWN bar segment
//! ("volume", "brightness", ...) via `segmentFor(i)`, so each control is
//! selected, ordered, and spaced independently in `[bar.layout.*]` -- there
//! is no aggregate "slider" belt any more.
//!
//! This eponymous file is the package core:
//!   - `Sub` is the surface contract every slider-like control binds.
//!   - `subs` comes from the generated `slider_subs` registry (file presence +
//!     self-declared role: a sibling without `pub const sub` is a private
//!     implementation file, never a bound addon).
//!   - `segmentFor(i)` builds the `contract.Segment` the bar places for control
//!     `i`, config identity `subs[i].name`. build.zig emits one entry per
//!     discovered control with a `pub const sub`.
//!
//! The core owns everything the controls share and nothing that differs:
//!   - the commit scheduler (`Throttle`) plus the `/bin/sh` racers each control
//!     runs its spawned commands through (allocation-free, inlined);
//!   - the interaction shell (a click hit-tests the control's own slot,
//!     exclusive press-hold drag, wheel steps, one-shot applies) and the poll
//!     loop (per-control cadence + owed-sweep), so the controls keep only
//!     their backend, read/write, and display format.
//! A control keeps its OWN truth (backend handles, cached state, format); the
//! core addresses it through hooks -- `read`/`pct`/`preview`/`commit`/`apply`
//! -- and remembers only per-segment slot geometry, arming, and cadence.
//!
//! The per-segment lifecycle (arm-on-first-draw, poll deadline, dirty redraw
//! marking, painted-width tracking) is a structural twin of systatus.zig's
//! read-only version -- and deliberately not shared with it: this core adds
//! drag/scroll interaction, a commit throttle, and per-control cadences atop
//! the same 10-line shape, so extracting a common scaffold would cost a
//! parameterised contract surface for little net body. See systatus.zig.
//!
//! Interaction mirrors the standalone segments it replaces, verbatim:
//!   - wheel up/down: +/- 2 %;
//!   - left press / press-hold drag anywhere over the control's slot: set its
//!     level from the horizontal position; while the press is held the
//!     control renders as the accent-filled loading bar and the label resumes
//!     on release;
//!   - right press: the control's secondary action (volume's mute toggle;
//!     brightness reserves it).
//! Scrolls and drags commit per motion event; whether they are THROTTLED or
//! not depends entirely on the commit's cost: native commits (one in-process
//! ioctl / sysfs write / libpulse round trip) are applied immediately,
//! un-throttled; subprocess spawns (pactl/amixer/brightnessctl) are
//! rate-limited to `throttle_ms`, coalesced onto the newest value, and
//! flushed by the poll loop. The display always follows the control's
//! optimistic `preview` immediately; backend truth arrives on the next read.
//! The 0-100 % clamp is each control's single guard, so scrolling at a
//! boundary is a true no-op.

const std = @import("std");
const types = @import("types");
const drawing = @import("drawing");
const segmod = @import("segment");
const contract = @import("contract");
const utils = @import("utils");

const c = @cImport({
    @cInclude("stdio.h");
});

const subs = @import("slider_subs").subs;

const scroll_step: u8 = 2;
/// Longest cadence in the registry; a poll deadline closer than this (the
/// control's next read, or an owed flush) wins anyway, so this only bounds
/// how far ahead a single wake can be scheduled.
const max_cadence_ms: i64 = 5000;

/// Spawn-commit window shared by every control. A fork+exec+pipe+waitpid
/// blocks the WM's event loop for ~1-5 ms, so a per-event spawn throttled the
/// whole WM under a fast drag or scroll; coalescing onto the newest value
/// keeps a sweep to at most one spawn per window. Native commits ignore it.
const throttle_ms: i64 = 80;

/// The WM's single time base: monotonic-ish wall time in ms.
pub fn nowMs() i64 {
    return utils.realtimeMs();
}

/// Commit scheduler for scroll/drag events, shared by every slider control. A
/// native commit is applied immediately; a spawn commit runs at most once per
/// `interval_ms`, and an inside-window event is marked owed (coalesced onto
/// the newest value, flushed by the poll loop or drag end).
pub const Throttle = struct {
    interval_ms: i64,
    last_ms: i64 = 0,
    pending: bool = false,

    /// Commits `pct` through `write`, restarts the commit clock, and clears
    /// any owed value. Shared by the immediate path, the owed flush, and the
    /// drag-end release.
    fn land(self: *Throttle, pct: u8, write: anytype) void {
        write(pct);
        self.last_ms = nowMs();
        self.pending = false;
    }

    /// Decides one event. `write` is the control's commit callback, comptime
    /// so the scheduler inlines into the caller (factoring it here costs
    /// nothing at runtime).
    pub fn apply(self: *Throttle, native: bool, pct: u8, write: anytype) void {
        if (native or nowMs() -| self.last_ms >= self.interval_ms) {
            self.land(pct, write);
        } else {
            self.pending = true;
        }
    }

    /// Restarts the commit clock and clears any owed value, for an immediate
    /// one-shot commit (the press that enters drag mode) so the first motion
    /// does not double-send.
    pub fn reset(self: *Throttle) void {
        self.last_ms = nowMs();
        self.pending = false;
    }

    /// The poll-loop sweep: flushes an owed commit whose window has elapsed
    /// (the newest value lands exactly once per window).
    pub fn flushOwed(self: *Throttle, pct: u8, write: anytype) void {
        if (self.pending and nowMs() -| self.last_ms >= self.interval_ms) {
            self.land(pct, write);
        }
    }

    /// Drag end: force-lands the final value when one is still owed (the
    /// authoritative release of a scrub), regardless of the window.
    pub fn finish(self: *Throttle, pct: u8, write: anytype) void {
        if (self.pending) self.land(pct, write);
    }
};

/// The single pct↔range linear map shared by every control backend: maps a
/// raw level on the control's [min..max] scale onto 0-100 percent (and back),
/// nearest-rounding in both directions so a round trip is stable and 50 % of
/// 0..87 lands on 44 (what `amixer set Master 50%` writes). A degenerate
/// (zero-length or inverted) range maps the range floor on write and 0 on
/// read.
pub fn rawFromPct(comptime T: type, pct: u8, min: T, max: T) T {
    if (max <= min) return min;
    const span: i128 = @as(i128, max) - @as(i128, min);
    const lead: i128 = @min(@divTrunc(@as(i128, @min(pct, 100)) * span + 50, 100), span);
    return @intCast(@as(i128, min) + lead);
}

/// Inverse of `rawFromPct` (the shared map): raw value onto the 0-100 scale.
pub fn pctFromRaw(comptime T: type, raw: T, min: T, max: T) u8 {
    if (max <= min) return 0;
    const span: i128 = @as(i128, max) - @as(i128, min);
    const off: i128 = std.math.clamp(@as(i128, raw) - @as(i128, min), 0, span);
    const pct: i128 = @divTrunc(off * 100 + @divTrunc(span, 2), span);
    return @intCast(@min(pct, 100));
}

/// Runs `cmd` via /bin/sh, drains its stdout into `sink` (so `pclose` never
/// blocks on a full pipe), and reports the bytes captured plus whether the
/// child exited 0. Null on any failure: the command is too long for the fixed
/// 256-byte buffer, or `popen` was denied. Shared body of `runOut`/`runOk`.
fn spawnCapture(cmd: []const u8, sink: []u8) ?struct { bytes: usize, exit_ok: bool } {
    if (cmd.len + 1 > 256) return null;
    var cmd_buf: [256]u8 = undefined;
    @memcpy(cmd_buf[0..cmd.len], cmd);
    cmd_buf[cmd.len] = 0;
    const f = c.popen(&cmd_buf, "r") orelse return null;
    const bytes = c.fread(sink.ptr, 1, sink.len, f);
    return .{ .bytes = bytes, .exit_ok = c.pclose(f) == 0 };
}

/// Runs `cmd` via /bin/sh and returns its captured stdout, trimmed of
/// trailing whitespace. Empty slice on any failure (popen denied, the child
/// wrote nothing, or the command is too long for the fixed buffer).
pub fn runOut(cmd: []const u8, buf: []u8) []const u8 {
    const cap = spawnCapture(cmd, buf) orelse return "";
    if (cap.bytes == 0) return "";
    return std.mem.trimEnd(u8, buf[0..cap.bytes], " \n\r");
}

/// Runs `cmd`, drains its output (so `pclose` never blocks on a full pipe),
/// and returns whether the child exited 0.
pub fn runOk(cmd: []const u8) bool {
    var sink: [64]u8 = undefined;
    const cap = spawnCapture(cmd, &sink) orelse return false;
    return cap.exit_ok;
}

/// A rendered slider label plus its numeric value region: the byte subslice of
/// `text` holding the `{pct}` expansion (plus a directly-attached literal
/// `%`, so "42%" colors as one number). Null when the format has no number to
/// color (e.g. volume's muted "MUTE"), in which case the whole label paints in
/// the segment color.
pub const Label = struct {
    text: []const u8,
    value: ?[]const u8 = null,
};

/// Renders a control's display `format` into `buf`, substituting every
/// `{pct}` placeholder with the decimal `pct` and -- when `state` is non-null
/// -- every `{state}` placeholder with that marker string. A substitution
/// that would overflow `buf` stops the walk; a truncated tail is still a
/// complete, scan-safe string. Any other `{...}` passes through literally.
/// Shared substitution walker for the volume/brightness display formats;
/// records the numeric value region (see `Label.value`) so the segment can
/// paint the number in its `_value` color. The value is the first `{pct}`
/// expansion plus a literal `%` that directly follows the placeholder.
pub fn renderLineValue(format: []const u8, pct: u8, state: ?[]const u8, buf: []u8) Label {
    var n: usize = 0;
    var i: usize = 0;
    var value: ?[]const u8 = null;
    while (i < format.len and n < buf.len) {
        if (format[i] == '{') {
            if (state != null and std.mem.startsWith(u8, format[i..], "{state}")) {
                const s = state.?;
                if (n + s.len > buf.len) break;
                @memcpy(buf[n..][0..s.len], s);
                n += s.len;
                i += 7;
                continue;
            }
            if (std.mem.startsWith(u8, format[i..], "{pct}")) {
                var b: [16]u8 = undefined;
                const ps = std.fmt.bufPrint(&b, "{d}", .{pct}) catch break;
                if (n + ps.len > buf.len) break;
                @memcpy(buf[n..][0..ps.len], ps);
                // Extend the number's span through a literal '%' right after
                // the placeholder (guarded by `n` so the record never points
                // past the final `text`), coloring "42%" as one number.
                const ok_percent = i + 5 < format.len and format[i + 5] == '%';
                const value_len = ps.len + @intFromBool(ok_percent and n + ps.len < buf.len);
                if (value == null) value = buf[n .. n + value_len];
                n += ps.len;
                i += 5;
                continue;
            }
        }
        buf[n] = format[i];
        n += 1;
        i += 1;
    }
    return .{ .text = buf[0..n], .value = value };
}

// The slider surface is a closed-core / open-module system, like every
// surface in this tree:
//
//   - The CLOSED CORE is this file: the `Sub` contract plus the generic
//     per-control render/interaction/poll/commit shell below. It never names a
//     control module; every control is reached through `subs`, the generated
//     registry (see build.zig's `buildSubsRegistryModule`).
//
//   - The OPEN MODULES are the siblings that bind `pub const sub: Sub`.
//     Siblings WITHOUT the binding (the native_alsa / native_pulse backends)
//     are private implementation files: importable by stem, never bound.
//     Membership in `subs` -- and therefore a bar segment named after the
//     control -- comes from FILE PRESENCE plus self-declared role, so adding
//     a control is drop a file; deleting one is delete the file.
//
// To add a control: drop `foo.zig` here exporting `pub const sub: Sub`.

pub const Sub = struct {
    /// Config identity ("volume", "brightness", ...): the name its bar
    /// segment is selected by in `[bar.layout.*]`.
    name: []const u8,
    /// Per-control poll cadence.
    read_interval_ms: i64 = 5000,
    /// True once the control has an answer; while false the control renders
    /// nothing (zero-width slot, unclickable). Null = always present.
    has_value: ?*const fn () bool = null,
    /// True while the backend can write; while false interactions no-op but
    /// the level still displays.
    writable: *const fn () bool,
    /// Refresh the control's live state (attach/probe cached inside); returns
    /// true when the displayed state changed this call.
    read: *const fn () bool,
    /// The currently displayed 0-100 level.
    pct: *const fn () u8,
    /// Optimistic display update used by scroll/drag: advances what the next
    /// label render shows without a backend round trip; the next read
    /// reconciles truth.
    preview: *const fn (u8) void,
    /// True when THIS control's commits are native in-process calls (one
    /// ioctl / sysfs write / libpulse round trip) and need no throttling.
    commit_is_native: *const fn () bool,
    /// Writes `pct` to the backend (native call or subprocess spawn). The
    /// 0-100 clamp is the control's single guard.
    commit: *const fn (u8) void,
    /// One-shot apply (press set / drag-end): commit + immediately re-read so
    /// the label follows the sink/device truth.
    apply: *const fn (u8) void,
    /// Renders the idle label into `buf` (control-scoped scratch) from the
    /// control's own state and config, plus the label's numeric region;
    /// valid until the next call.
    label: *const fn (types.BarConfig, []u8) Label,
    /// Right-click action (volume's mute toggle); null = reserved no-op.
    secondary: ?*const fn () void = null,
    /// Idle width when the control has never laid out (natural-reserve
    /// fallback).
    probeNaturalWidth: u16 = 44,
};

const Instance = struct {
    /// Latched on the control's first read (the segment's first draw arms
    /// it; see `g_armed`).
    next_read_ms: i64 = 0,
    /// The control's slot width from the last idle draw (a single-slot
    /// segment spanning [0, slot_w) at the segment start): the click
    /// hit-test range and the slider denominator.
    slot_w: u16 = 0,
    /// Sub-scoped label scratch, so each control's label stays valid until
    /// its own next draw.
    scratch: [128]u8 = undefined,
};

/// Per-segment state, indexed by registry position (segment i == subs[i]).
var g_inst: [subs.len]Instance = [_]Instance{.{}} ** subs.len;
var g_armed: [subs.len]bool = @splat(false);
var g_pending_redraw: [subs.len]bool = @splat(false);
var g_throttle: [subs.len]Throttle = [_]Throttle{.{ .interval_ms = throttle_ms }} ** subs.len;
/// Whether this control is currently scrubbed by a press-hold (one exclusive
/// drag per segment).
var g_drag: [subs.len]bool = @splat(false);

/// Linear slider mapping across a slot: a pointer offset (relative to the
/// segment start) maps to 0-100 % of the slot. The bar records the click
/// bound at the reserved width, which mirrors `slot_w` at draw time.
pub fn pctFromSlot(slot_x: u16, slot_w: u16, offset: u16) u8 {
    const w: u32 = @max(slot_w, 1);
    const base: u32 = @as(u32, offset) -| @as(u32, slot_x);
    const v: u32 = base * 100 / w;
    return @intCast(@min(v, 100));
}

/// The slider denominator for control `idx` at pointer `offset` (the single
/// slot spans [0, slot_w)).
fn pctAt(idx: usize, offset: u16) u8 {
    return pctFromSlot(0, g_inst[idx].slot_w, offset);
}

fn present(idx: usize) bool {
    if (subs[idx].has_value) |h| return h();
    return true;
}

/// Preview the value optimistically and run it through the control's own
/// commit scheduler (native un-throttled, spawn rate-limited).
fn commitPreview(idx: usize, pct: u8) void {
    const sub = subs[idx];
    sub.preview(pct);
    g_throttle[idx].apply(sub.commit_is_native(), pct, sub.commit);
}

/// Poll deadline for control `idx`: the segment doesn't arm itself until its
/// first draw (when the bar actually renders it), so an unconfigured control
/// never wakes the loop. Returns -1 while unarmed, ms until the next wake
/// otherwise (0 = due now): the earliest of the control's read cadence and an
/// owed commit flush.
fn pollDeadlineMsFor(idx: usize) i32 {
    if (!g_armed[idx]) return -1;
    var deadline: i64 = g_inst[idx].next_read_ms;
    if (g_throttle[idx].pending) {
        const flush_at = g_throttle[idx].last_ms + g_throttle[idx].interval_ms;
        if (flush_at < deadline) deadline = flush_at;
    }
    const left = deadline - nowMs();
    if (left <= 0) return 0;
    return @intCast(@min(left, max_cadence_ms));
}

fn onPollWakeupFor(idx: usize) void {
    if (!g_armed[idx]) return;
    // Sweep an owed scroll/drag commit whose throttle window has elapsed
    // (the read cadence below stays gated: this wake exists purely to land
    // the newest value the backend hasn't seen yet).
    g_throttle[idx].flushOwed(subs[idx].pct(), subs[idx].commit);
    const inst = &g_inst[idx];
    if (nowMs() < inst.next_read_ms) return;
    inst.next_read_ms = nowMs() + subs[idx].read_interval_ms;
    if (subs[idx].read()) g_pending_redraw[idx] = true;
}

fn consumeRedrawRequestFor(idx: usize) bool {
    const p = g_pending_redraw[idx];
    g_pending_redraw[idx] = false;
    return p;
}

fn naturalWidthFor(idx: usize) u16 {
    if (!present(idx)) return 0;
    return if (g_inst[idx].slot_w != 0) g_inst[idx].slot_w else subs[idx].probeNaturalWidth;
}

/// Drag-mode loading bar for one control: paints its whole reserved slot with
/// a background strip plus a fill (the title segment's minimized accent) and
/// overlays the live percentage centered in the slot, in the bar-wide fg
/// (regular text color, not the segment's accent). Returns the slot's far
/// edge WITHOUT feeding `slot_w`: the label width must survive the scrub so
/// the drag-end redraw re-renders it in place.
fn drawDragBar(dc: *segmod.DrawCtx, x: u16, slot: u16, pct: u8) u16 {
    const height = dc.height;
    dc.dc.fillRect(x, 0, slot, height, dc.config.bg);
    const pad = @max(@as(u16, 1), dc.config.scaledSegmentPadding(height) / 2);
    const inner_w = slot -| pad * 2;
    const inner_h = height -| pad * 2;
    const fill_w: u16 = @intCast(@as(u32, inner_w) * pct / 100);
    if (fill_w != 0 and inner_h != 0)
        dc.dc.fillRect(x + pad, pad, fill_w, inner_h, dc.config.title_minimized_accent);

    var b: [8]u8 = undefined;
    const ps = std.fmt.bufPrint(&b, "{d}", .{pct}) catch return x + slot;
    const tw = dc.dc.measureTextWidth(ps);
    dc.dc.drawText(x +| slot / 2 -| tw / 2, dc.dc.baselineY(height), ps, dc.config.fg) catch {};
    return x + slot;
}

fn drawFor(idx: usize, ctx: *anyopaque, x: u16) !u16 {
    const dc = segmod.castDraw(ctx);
    const sub = subs[idx];
    const inst = &g_inst[idx];
    // First draw arms the control: fill its label before its own cadence.
    if (!g_armed[idx]) {
        _ = sub.read();
        g_armed[idx] = true;
        inst.next_read_ms = nowMs() + sub.read_interval_ms;
    }
    // Absent backend: nothing to show (a zero-width slot, unclickable, never
    // polled past arm); naturalWidth reports 0, so the layout leaves no gap.
    if (!present(idx)) return x;
    // While scrubbed the control is a loading bar; the label resumes on the
    // drag-end redraw.
    if (g_drag[idx]) {
        return drawDragBar(dc, x, inst.slot_w, sub.pct());
    }
    const label = sub.label(dc.config, &inst.scratch);
    const end_x = try drawing.drawPaddedSegmentValue(dc.dc, dc.config, dc.height, x, sub.name, label.text, label.value, dc.config.segmentProps(sub.name));
    // Track the ACTUAL painted width, not the row reservation: the palette
    // must follow the text, or the segment locks onto the startup probe and
    // its neighbors overlap it, forever (matches the widthState collapse
    // path). A width change marks the segment dirty so the bar re-lays out.
    // The slot also feeds the click bound and the slider denominator.
    const drawn = end_x - x;
    if (drawn != inst.slot_w) g_pending_redraw[idx] = true;
    inst.slot_w = drawn;
    return end_x;
}

/// Left press: enter drag mode on the control and set its level at that
/// position; right press: the control's secondary action (mute toggle),
/// reserved for controls without one.
fn onClickFor(
    idx: usize,
    offset: u16,
    left: bool,
    right: bool,
    _: *anyopaque,
    _: *const fn (*anyopaque, u16) void,
    redraw: *const fn () void,
) bool {
    const sub = subs[idx];
    if (!left and !right) return false;
    if (g_inst[idx].slot_w == 0 or offset >= g_inst[idx].slot_w) return false;
    if (left) {
        if (!sub.writable()) return false;
        // Enter drag mode immediately, and restart the commit clock after
        // this press's set so the first motion doesn't double-send.
        g_drag[idx] = true;
        sub.apply(pctAt(idx, offset));
        g_throttle[idx].reset();
    } else {
        const secondary = sub.secondary orelse return false;
        secondary();
    }
    g_pending_redraw[idx] = true;
    redraw();
    return true;
}

fn onScrollFor(idx: usize, dir: i8, redraw: *const fn () void) bool {
    const sub = subs[idx];
    if (!g_armed[idx]) return false;
    if (!present(idx)) return false;
    if (!sub.writable()) return false;
    const base: u16 = sub.pct();
    const new_u: u16 = if (dir > 0)
        @min(base + scroll_step, 100)
    else
        base -| scroll_step;
    const pct: u8 = @intCast(new_u);
    // Boundary: the clamped target equals the current level, so this wheel
    // step changes nothing. Claim it and return without writing or repainting
    // scrolling at 0/100 % is a true no-op, never backend traffic.
    if (pct == sub.pct()) return true;
    // Optimistic display + throttled commit: the label follows immediately
    // while the backend write is coalesced (commitPreview) and the value is
    // reconciled on the read cadence.
    commitPreview(idx, pct);
    redraw();
    return true;
}

/// Press-hold scrub: updates the display immediately and schedules the commit
/// per motion -- native commits apply on every event, subprocess spawns at
/// most every `throttle_ms`. A value owed inside the throttle window is
/// coalesced and flushed on release, or by the poll loop.
///
/// Deliberately does NOT raise `g_pending_redraw`: bar.zig's post-batch
/// `updateIfDirty` folds that flag into a FULL-bar redraw, defeating the
/// scoped `redraw` callback every motion. The bar passes the segment-scoped
/// repaint here, so the display is updated without re-laying the whole bar.
fn onDragMotionFor(idx: usize, offset: u16, redraw: *const fn () void) bool {
    if (!g_drag[idx]) return false;
    if (!subs[idx].writable()) return false;
    commitPreview(idx, pctAt(idx, offset));
    redraw();
    return true;
}

/// Scrub end (button-1 release): force-land any owed commit, re-read the
/// control so its label shows the truth, and repaint back to text mode.
fn onDragEndFor(idx: usize, redraw: *const fn () void) void {
    g_throttle[idx].finish(subs[idx].pct(), subs[idx].commit);
    if (g_drag[idx]) {
        g_drag[idx] = false;
        _ = subs[idx].read();
        g_pending_redraw[idx] = true;
        redraw();
    }
}

/// The bar-module binding for control `i` (comptime so each instantiation is
/// a distinct segment with its own hooks into `subs[i]`'s state). Emitted by
/// build.zig per discovered control with a `pub const sub`, in the same
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
        fn naturalWidth(_: *const anyopaque, _: u16) u16 {
            return naturalWidthFor(i);
        }
        fn draw(ctx: *anyopaque, x: u16) anyerror!u16 {
            return drawFor(i, ctx, x);
        }
        fn onClick(
            offset: u16,
            left: bool,
            right: bool,
            a: *anyopaque,
            trampoline: *const fn (*anyopaque, u16) void,
            request_redraw: *const fn () void,
        ) bool {
            return onClickFor(i, offset, left, right, a, trampoline, request_redraw);
        }
        fn onScroll(dir: i8, request_redraw: *const fn () void) bool {
            return onScrollFor(i, dir, request_redraw);
        }
        fn onDragMotion(offset: u16, request_redraw: *const fn () void) bool {
            return onDragMotionFor(i, offset, request_redraw);
        }
        fn onDragEnd(request_redraw: *const fn () void) void {
            return onDragEndFor(i, request_redraw);
        }
    };
    return .{
        .name = subs[i].name,
        .clickable = true,
        .pollTimeoutMs = Hooks.poll,
        .onPollWakeup = Hooks.wakeup,
        .consumeRedrawRequest = Hooks.redraw,
        .naturalWidth = Hooks.naturalWidth,
        .draw = Hooks.draw,
        .onClick = Hooks.onClick,
        .onScroll = Hooks.onScroll,
        .onDragMotion = Hooks.onDragMotion,
        .onDragEnd = Hooks.onDragEnd,
    };
}

// Pure geometry helper pctFromSlot is covered by slider_test; the stateful
// wrappers above are exercised end-to-end through interaction tests.
