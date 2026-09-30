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
const scaffold = @import("scaffold");
const contract = @import("contract");
const time = @import("time");
const meter = @import("meter");

const c = @cImport({
    @cInclude("stdio.h");
});

/// Public for the unit tests: the registry is build-generated, and a test that
/// hardcoded a control name would break whenever one is added or removed.
pub const subs = @import("slider_subs").subs;

const scroll_step: u8 = 2;
/// Longest cadence in the registry; a poll deadline closer than this (the
/// control's next read, or an owed flush) wins anyway, so this only bounds
/// how far ahead a single wake can be scheduled.
const max_cadence_ms: i64 = 5000;

/// Spawn-commit window DEFAULT for every control. A fork+exec+pipe+waitpid
/// blocks the WM's event loop for ~1-5 ms, so a per-event spawn throttled the
/// whole WM under a fast drag or scroll; coalescing onto the newest value
/// keeps a sweep to at most one spawn per window. `immediate` commits ignore
/// it, and a control whose spawn is cheaper than average can declare a
/// tighter window of its own via `Sub.commit_window_ms`.
const throttle_ms: i64 = 80;

/// The latency class of ONE commit on a control, as a value the scheduler
/// switches on rather than a boolean the shell has to interpret.
///
/// It stays a function (not a plain field) because the class is genuinely a
/// per-BACKEND fact that resolves at runtime, not a per-control constant:
/// brightness writes sysfs in microseconds when that backend is live but
/// spawns `brightnessctl` when it is not, and volume is native over libpulse
/// or ALSA depending on what it attached to. A static field would have to
/// claim the cheaper class and then throttle a sysfs write that needs no
/// window, or claim the spawn class and lag a native drag. What changed is
/// that the answer is a NAMED class instead of a bare bool, so the scheduler
/// reads `cost == .immediate` rather than a predicate whose meaning lives in
/// the control's comment.
pub const CommitCost = enum { immediate, rate_limited };

/// The WM's single time base: monotonic-ish wall time in ms.
pub fn nowMs() i64 {
    return time.realtimeMs();
}

/// Commit scheduler for scroll/drag events, shared by every slider control. A
/// native commit is applied immediately; a spawn commit runs at most once per
/// `interval_ms`, and an inside-window event is marked owed (coalesced onto
/// the newest value, flushed by the poll loop or drag end).
pub const Throttle = struct {
    interval_ms: i64,
    /// Where a landed commit goes. The scheduler is per control, so the control
    /// it writes to belongs here rather than being threaded through `apply` /
    /// `flushOwed` / `finish` as an argument (26.8). It was an argument because
    /// the target used to be a bare `commit` hook; it is now the `.commit` mode
    /// of one `write`, and passing it three times only to bind a mode was the
    /// shape of the thing being folded away.
    write: *const fn (Write, u8) void,
    last_ms: i64 = 0,
    pending: bool = false,

    /// Commits `pct` through `write`, restarts the commit clock, and clears
    /// any owed value. Shared by the immediate path, the owed flush, and the
    /// drag-end release.
    fn land(self: *Throttle, pct: u8) void {
        self.write(.commit, pct);
        self.last_ms = nowMs();
        self.pending = false;
    }

    /// Decides one event. `cost` is the control's own latency class: an
    /// in-process write lands every time, a spawn waits for its window.
    pub fn apply(self: *Throttle, cost: CommitCost, pct: u8) void {
        if (cost == .immediate or nowMs() -| self.last_ms >= self.interval_ms) {
            self.land(pct);
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
    pub fn flushOwed(self: *Throttle, pct: u8) void {
        if (self.pending and nowMs() -| self.last_ms >= self.interval_ms) {
            self.land(pct);
        }
    }

    /// Drag end: force-lands the final value when one is still owed (the
    /// authoritative release of a scrub), regardless of the window.
    pub fn finish(self: *Throttle, pct: u8) void {
        if (self.pending) self.land(pct);
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
    /// (25.3) The numeric value's span as EXPLICIT offsets, with `value_len ==
    /// 0` meaning "no value". This used to be a subslice of `text`, which
    /// forced the painter to recover the offset by subtracting pointers.
    value_start: usize = 0,
    value_len: usize = 0,
};

/// Renders a control's display `format` into `buf`, substituting every
/// `{pct}` placeholder with the decimal `pct` and -- when `state` is non-null
/// -- every `{state}` placeholder with that marker string. A substitution
/// that would overflow `buf` stops the walk; a truncated tail is still a
/// complete, scan-safe string. Any other `{...}` passes through literally.
/// Shared substitution walker for the volume/brightness display formats;
/// records the numeric value region (see `Label.value_start`/`value_len`) so the segment can
/// paint the number in its `_value` color. The value is the first `{pct}`
/// expansion plus a literal `%` that directly follows the placeholder.
pub fn renderLineValue(format: []const u8, pct: u8, state: ?[]const u8, buf: []u8) Label {
    var n: usize = 0;
    var i: usize = 0;
    var value_start: usize = 0;
    var value_len: usize = 0;
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
                const span = ps.len + @intFromBool(ok_percent and n + ps.len < buf.len);
                // First {pct} wins, as before.
                if (value_len == 0) {
                    value_start = n;
                    value_len = span;
                }
                n += ps.len;
                i += 5;
                continue;
            }
        }
        buf[n] = format[i];
        n += 1;
        i += 1;
    }
    return .{ .text = buf[0..n], .value_start = value_start, .value_len = value_len };
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

/// What the caller wants a `write` to do. Named, and folded into ONE hook from
/// the three it replaces (`preview` / `commit` / `apply`, 26.8).
///
/// They were never three operations. A module that differed in only one of them
/// -- brightness writes a file, volume writes a sink, and both clamp the same
/// way -- had to write a near-duplicate function per hook, so the clamp and the
/// display update existed three times each and could drift apart. One hook with
/// a named mode puts each of those in one place, and the mode says which of the
/// three it used to be.
pub const Write = enum {
    /// Display only: advance the label now, write nothing to the backend. This
    /// is what scroll/drag motion wants, where the write is deferred anyway.
    preview,
    /// Write to the backend (native call or subprocess spawn). The 0-100 clamp
    /// is the control's single guard. The display reconciles on the next read.
    commit,
    /// Write and show it: a press set, or the authoritative end of a scrub.
    /// Not throttled -- this is the release of the gesture, not another motion
    /// sample, and dropping it would leave the backend short of the value the
    /// user is looking at.
    apply,
};

pub const Sub = struct {
    /// Config identity ("volume", "brightness", ...): the name its bar
    /// segment is selected by in `[bar.layout.*]`.
    name: []const u8,
    /// Per-control poll cadence.
    read_interval_ms: i64 = 5000,
    /// The control's 0-100 level, or null while it has no answer (the control
    /// then renders nothing: zero-width slot, unclickable). Null HOOK = always
    /// present.
    ///
    /// This is one hook, not the `{bool, u8}` pair it replaced (26.8). The two
    /// were always written and always latched together, and a module that
    /// latched one and forgot the other produced a control that reported a
    /// level nobody had or hid a level everybody could see. The absence is now
    /// in the type, so it cannot disagree with the value.
    level: ?*const fn () ?u8 = null,
    /// True while the backend can write; while false interactions no-op but
    /// the level still displays.
    writable: *const fn () bool,
    /// Refresh the control's live state (attach/probe cached inside); returns
    /// true when the displayed state changed this call.
    read: *const fn () bool,
    /// Writes `pct`, or advances only the display -- see `Write`.
    write: *const fn (Write, u8) void,
    /// The latency class of one commit on this control, as a named value (see
    /// `CommitCost`). `immediate` commits are cheap in-process writes and are
    /// never coalesced; `rate_limited` ones pass through the throttle window.
    commit_cost: *const fn () CommitCost,
    /// This control's own spawn-commit window in ms, or null to share the core
    /// default (`throttle_ms`). Per-control so a control whose subprocess is
    /// cheap enough to afford a tighter sweep can say so as data instead of
    /// living with the shared window. Ignored for `immediate` commits.
    commit_window_ms: ?i16 = null,
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
    /// Sub-scoped label scratch, so each control's label stays valid until
    /// its own next draw.
    scratch: [128]u8 = undefined,
};

/// Per-segment state, indexed by registry position (segment i == subs[i]).
var g_inst: [subs.len]Instance = [_]Instance{.{}} ** subs.len;
var g_armed: [subs.len]bool = @splat(false);
var g_pending_redraw: [subs.len]bool = @splat(false);
/// One scheduler per control, each already pointing at its own control's write
/// hook. `subs` is comptime-generated, so the wiring is a comptime loop with no
/// runtime init and no per-event lookup.
var g_throttle: [subs.len]Throttle = blk: {
    var t: [subs.len]Throttle = undefined;
    for (0..subs.len) |i| t[i] = .{ .interval_ms = throttle_ms, .write = subs[i].write };
    break :blk t;
};

/// Applies control `idx`'s declared commit window to its scheduler, once the
/// control is known. Called at arm time; a control that shares the default
/// keeps it.
fn applyCommitWindow(idx: usize) void {
    if (subs[idx].commit_window_ms) |w| g_throttle[idx].interval_ms = w;
}
/// Whether this control is currently scrubbed by a press-hold (one exclusive
/// drag per segment).
var g_drag: [subs.len]bool = @splat(false);

/// Linear slider mapping across a slot. Lifted to `bar/meter.zig` (26.8): it
/// is not a slider concept -- every horizontal meter needs it -- and the
/// zero-width-slot rule and the far-edge saturation had to be right in
/// whichever module happened to need them first. This re-export keeps the
/// slider's own name working, so the pure test and the core keep the same
/// entry point.
pub const pctFromSlot = meter.pctFromSlot;

/// The width the bar reserves for control `idx`, and the ONE denominator for
/// everything that needs a slider's width: the row reservation
/// (`naturalWidthFor`), the drag mapping (`pctAt`) and the click hit-test
/// (`onClickFor`).
///
/// These used to disagree on the first frame: the width was 0 until the
/// segment's first draw completed, `onClickFor` rejected every click while it
/// was 0 (so the very first press on a freshly laid-out slider did nothing at
/// all), and the drag denominator and the row reservation fell back to
/// DIFFERENT values. `widthState.resolved` is now that one rule (21.4), shared
/// with systatus, so the hit-test, the drag range and the reservation cannot
/// disagree about what "not measured yet" means.
/// The shared `scaffold.widthState` singleton for this control's name, which
/// owns the store / consumeRedrawRequest / resolved triple. The hand-rolled
/// `slot_w` field plus its inline "did the width change? mark dirty" (21.4)
/// was a second implementation of code systatus already used, and this module
/// is comptime-indexed by `subs`, so one instantiation per name is exactly
/// the state each control needs.
fn widthStateFor(comptime idx: usize) type {
    return scaffold.widthState(subs[idx].name);
}

fn reservedWidth(idx: usize) u16 {
    // Event handlers reach here with a RUNTIME idx (a pointer event names the
    // control it landed on), while the width state is one comptime-tagged
    // singleton per control. `inline for` keeps the selection comptime and
    // leaves a straight-line compare per control -- the array is a compile-time
    // constant of 2, so this is cheaper than any index it replaced, and there
    // is no runtime `slot_w` mirror to fall out of sync with.
    inline for (0..subs.len) |i| {
        if (i == idx) return widthStateFor(i).resolved(subs[i].probeNaturalWidth);
    }
    unreachable;
}

/// The slider denominator for control `idx` at pointer `offset` (the single
/// slot spans [0, reservedWidth)).
fn pctAt(idx: usize, offset: u16) u8 {
    return pctFromSlot(0, reservedWidth(idx), offset);
}

fn present(idx: usize) bool {
    return true;
}

/// A control's presence, from the contract alone. Pure, so a fake `Sub` can
/// exercise both directions without a backend behind it -- the registry's own
/// controls are all absent in a headless test, so a test that reads them can
/// only ever agree with one branch and would miss the other.
pub fn subPresent(sub: Sub) bool {
    if (sub.level) |l| return l() != null;
    return true;
}

/// A control's level, or null for "has not answered". Null HOOK means always
/// present, and reports 0 -- the level an empty slider would have drawn.
pub fn subLevel(sub: Sub) ?u8 {
    const l = sub.level orelse return 0;
    return l();
}

/// The control's displayed level for the drag mapping. A control with no level
/// is never reached by a drag (it is not clickable), so the 0 is only the
/// fallback for the unreachable case, and it is the same 0 the empty slider
/// would have drawn.
/// A control's level, or 0 when it has not answered. The 0 is the level an
/// empty slider would have drawn, so a control that loses its backend mid-gesture
/// settles at "nothing" instead of at a stale or arbitrary value.
pub fn subLevelOrZero(sub: Sub) u8 {
    return subLevel(sub) orelse 0;
}

fn levelOf(idx: usize) u8 {
    return subLevelOrZero(subs[idx]);
}

/// Preview the value optimistically and run it through the control's own
/// commit scheduler (native un-throttled, spawn rate-limited).
fn commitPreview(idx: usize, pct: u8) void {
    const sub = subs[idx];
    sub.write(.preview, pct);
    g_throttle[idx].apply(sub.commit_cost(), pct);
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
    g_throttle[idx].flushOwed(levelOf(idx));
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
    return reservedWidth(idx);
}

/// Drag-mode loading bar for one control: track, fill, centered percentage.
/// Returns the slot's far edge WITHOUT feeding the width state: the label width must
/// survive the scrub so the drag-end redraw re-renders it in place.
fn drawDragBar(dc: *segmod.DrawCtx, x: u16, slot: u16, pct: u8) u16 {
    const height = dc.height;
    dc.dc.fillRect(x, 0, slot, height, dc.config.bg);
    // Half the padding, so the fill's edges sit one padding inside the slot:
    // the same visual margin a text segment keeps between its background and
    // its glyphs. At least one pixel, or a 1px-tall bar paints nothing.
    const pad = @max(@as(u16, 1), dc.config.scaledSegmentPadding(height) / 2);
    const inner_w = slot -| pad * 2;
    const inner_h = height -| pad * 2;
    const fill_w: u16 = @intCast(@as(u32, inner_w) * pct / 100);
    if (fill_w != 0 and inner_h != 0)
        dc.dc.fillRect(x + pad, pad, fill_w, inner_h, dc.config.title_minimized_accent);

    var b: [8]u8 = undefined;
    const ps = std.fmt.bufPrint(&b, "{d}", .{pct}) catch return x + slot;
    const tw = dc.dc.measureTextWidth(ps);
    dc.dc.drawText(x +| slot / 2 -| tw / 2, dc.dc.baselineY(height), ps, dc.config.fg);
    return x + slot;
}

fn drawFor(comptime idx: usize, ctx: *anyopaque, x: u16) !contract.Painted {
    const dc = segmod.castDraw(ctx);
    const sub = subs[idx];
    const inst = &g_inst[idx];
    // First draw arms the control: fill its label before its own cadence.
    if (!g_armed[idx]) {
        _ = sub.read();
        g_armed[idx] = true;
        inst.next_read_ms = nowMs() + sub.read_interval_ms;
        applyCommitWindow(idx);
    }
    // Absent backend: nothing to show (a zero-width slot, unclickable, never
    // polled past arm); naturalWidth reports 0, so the layout leaves no gap.
    if (!present(idx)) return contract.Painted.nothing(x);
    // While scrubbed the control is a loading bar; the label resumes on the
    // drag-end redraw.
    if (g_drag[idx]) {
        // The scrub fills the reserved slot, so the painted span IS the
        // reserved width -- reporting it is a no-op against the measured label
        // width it replaces, which is exactly the intent: the label width must
        // survive the scrub so the drag-end redraw re-renders it in place.
        return contract.Painted.span(x, drawDragBar(dc, x, reservedWidth(idx), levelOf(idx)));
    }
    const label = sub.label(dc.config, &inst.scratch);
    const end_x = try drawing.drawPaddedSegmentValue(dc.dc, dc.config, dc.height, x, sub.name, label.text, label.value_start, label.value_len, dc.config.segmentProps(sub.name));
    // Report the ACTUAL painted width, not the row reservation: the palette
    // must follow the text, or the segment locks onto the startup probe and
    // its neighbors overlap it, forever (matches the widthState collapse
    // path).
    //
    // The store itself is NOT here. The bar hands the width back through
    // onPainted (21.7), which owns the "changed -> owes a re-layout" rule;
    // the module's own pending flag is left to mean the OTHER reason a slider
    // repaints (its value committed). Both are consumed together, so neither
    // can leak a request.
    return contract.Painted.span(x, end_x);
}

/// Left press: enter drag mode on the control and set its level at that
/// position; right press: the control's secondary action (mute toggle),
/// reserved for controls without one.
fn onClickFor(idx: usize, ctx: *const contract.ClickCtx) bool {
    const sub = subs[idx];
    if (!ctx.is_left and !ctx.is_right) return false;
    if (!present(idx)) return false;
    // Bound by the SAME width the row reserved, not by the last painted width:
    // a press that arrives before the first draw still maps to a level instead
    // of being dropped.
    const bound = reservedWidth(idx);
    if (ctx.offset >= bound) return false;
    if (ctx.is_left) {
        if (!sub.writable()) return false;
        // Enter drag mode immediately, and restart the commit clock after
        // this press's set so the first motion doesn't double-send.
        g_drag[idx] = true;
        sub.write(.apply, pctAt(idx, ctx.offset));
        g_throttle[idx].reset();
    } else {
        const secondary = sub.secondary orelse return false;
        secondary();
    }
    g_pending_redraw[idx] = true;
    ctx.redraw();
    return true;
}

fn onScrollFor(idx: usize, dir: i8, redraw: *const fn () void) bool {
    const sub = subs[idx];
    if (!g_armed[idx]) return false;
    if (!present(idx)) return false;
    if (!sub.writable()) return false;
    const base: u16 = levelOf(idx);
    const new_u: u16 = if (dir > 0)
        @min(base + scroll_step, 100)
    else
        base -| scroll_step;
    const pct: u8 = @intCast(new_u);
    // Boundary: the clamped target equals the current level, so this wheel
    // step changes nothing. Claim it and return without writing or repainting
    // scrolling at 0/100 % is a true no-op, never backend traffic.
    if (pct == levelOf(idx)) return true;
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
    g_throttle[idx].finish(levelOf(idx));
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
        fn naturalWidth(_: *const contract.Frame, _: u16) u16 {
            return naturalWidthFor(i);
        }
        fn draw(ctx: *anyopaque, x: u16) anyerror!contract.Painted {
            return drawFor(i, ctx, x);
        }
        /// Where the bar's painted-width report lands: this control's own
        /// width state, which both its naturalWidth hook and the click
        /// bound's denominator read back.
        fn onPainted(width: u16) void {
            widthStateFor(i).store(width);
            if (widthStateFor(i).consumeRedrawRequest()) g_pending_redraw[i] = true;
        }
        fn onClick(ctx: *const contract.ClickCtx) bool {
            return onClickFor(i, ctx);
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
        .onPainted = Hooks.onPainted,
        .onClick = Hooks.onClick,
        .onScroll = Hooks.onScroll,
        .onDragMotion = Hooks.onDragMotion,
        .onDragEnd = Hooks.onDragEnd,
    };
}

// Pure geometry helper pctFromSlot is covered by slider_test; the stateful
// wrappers above are exercised end-to-end through interaction tests.
