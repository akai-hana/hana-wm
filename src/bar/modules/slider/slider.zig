//! Slider bar segment: a systatus-style package that aggregates discrete
//! 0-100 % controls -- volume, brightness, any future sibling that binds
//! `pub const sub: Sub` -- behind ONE closed core.
//!
//! This eponymous file is the segment AND the package core:
//!   - `Sub` is the surface contract every slider-like control binds.
//!   - `subs` comes from the generated `slider_subs` registry (file presence +
//!     self-declared role: a sibling without `pub const sub` is a private
//!     implementation file, never a bound addon).
//!   - `module` is the `plugin.Segment` the bar places, config identity
//!     "slider".
//!
//! The core owns everything the subs share and nothing that differs:
//!   - the commit scheduler (`Throttle`) plus the `/bin/sh` racers each sub
//!     runs its spawned commands through (allocation-free, inlined);
//!   - the interaction shell (click hit-testing across sub slots, exclusive
//!     press-hold drag, wheel steps, one-shot applies) and the poll loop
//!     (per-sub cadence + owed-sweep), so the subs keep only their backend,
//!     read/write, and display format.
//! A sub keeps its OWN truth (backend handles, cached state, format); the
//! core addresses it through hooks -- `read`/`pct`/`preview`/`commit`/`apply`
//! -- and remembers only per-sub slot geometry, arming, and cadence.
//!
//! Interaction mirrors the standalone segments it replaces, verbatim:
//!   - wheel up/down: +/- 2 % on the last-interacted sub (else the first);
//!   - left press / press-hold drag anywhere over a sub's slot: set its level
//!     from the horizontal position; while the press is held that sub renders
//!     as the accent-filled loading bar and the label resumes on release;
//!   - right press: the sub's secondary action (volume's mute toggle;
//!     brightness reserves it).
//! Scrolls and drags commit per motion event; whether they are THROTTLED or
//! not depends entirely on the commit's cost: native commits (one in-process
//! ioctl / sysfs write / libpulse round trip) are applied immediately,
//! un-throttled; subprocess spawns (pactl/amixer/brightnessctl) are
//! rate-limited to `throttle_ms`, coalesced onto the newest value, and
//! flushed by the poll loop. The display always follows the sub's optimistic
//! `preview` immediately; backend truth arrives on the next read. The 0-100 %
//! clamp is each sub's single guard, so scrolling at a boundary is a true
//! no-op.

const std = @import("std");
const types = @import("types");
const drawing = @import("drawing");
const segmod = @import("segment");
const utils = @import("utils");

const c = @cImport({
    @cInclude("stdio.h");
});

const subs = @import("slider_subs").subs;

const scroll_step: u8 = 2;
/// Longest cadence in the registry; a poll deadline closer than this (the
/// earliest armed sub's next read, or an owed flush) wins anyway, so this
/// only bounds how far ahead a single wake can be scheduled.
const max_cadence_ms: i64 = 5000;

/// Spawn-commit window shared by every sub. A fork+exec+pipe+waitpid blocks
/// the WM's event loop for ~1-5 ms, so a per-event spawn throttled the whole
/// WM under a fast drag or scroll; coalescing onto the newest value keeps a
/// sweep to at most one spawn per window. Native commits ignore it.
pub const throttle_ms: i64 = 80;

/// The WM's single time base: monotonic-ish wall time in ms.
pub fn nowMs() i64 {
    return @intCast(utils.realtimeNs() / std.time.ns_per_ms);
}

/// Commit scheduler for scroll/drag events, shared by every slider sub. A
/// native commit is applied immediately; a spawn commit runs at most once per
/// `interval_ms`, and an inside-window event is marked owed (coalesced onto
/// the newest value, flushed by the poll loop or drag end).
pub const Throttle = struct {
    interval_ms: i64,
    last_ms: i64 = 0,
    pending: bool = false,

    /// Decides one event. `write` is the sub's commit callback, comptime so
    /// the scheduler inlines into the caller (factoring it here costs nothing
    /// at runtime).
    pub fn apply(self: *Throttle, native: bool, pct: u8, write: anytype) void {
        if (native or nowMs() -| self.last_ms >= self.interval_ms) {
            write(pct);
            self.last_ms = nowMs();
            self.pending = false;
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
            write(pct);
            self.last_ms = nowMs();
            self.pending = false;
        }
    }

    /// Drag end: force-lands the final value when one is still owed (the
    /// authoritative release of a scrub), regardless of the window.
    pub fn finish(self: *Throttle, pct: u8, write: anytype) void {
        if (self.pending) {
            write(pct);
            self.last_ms = nowMs();
            self.pending = false;
        }
    }
};

/// Runs `cmd` via /bin/sh and returns its captured stdout, trimmed of
/// trailing whitespace. Empty slice on any failure (popen denied, the child
/// wrote nothing, or the command is too long for the fixed buffer).
pub fn runOut(cmd: []const u8, buf: []u8) []const u8 {
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

/// Runs `cmd`, drains its output (so pclose never blocks on a full pipe), and
/// returns whether the child exited 0.
pub fn runOk(cmd: []const u8) bool {
    if (cmd.len + 1 > 256) return false;
    var cmd_buf: [256]u8 = undefined;
    @memcpy(cmd_buf[0..cmd.len], cmd);
    cmd_buf[cmd.len] = 0;
    const f = c.popen(&cmd_buf, "r") orelse return false;
    var sink: [64]u8 = undefined;
    _ = c.fread(&sink, 1, sink.len, f);
    return c.pclose(f) == 0;
}

// ---------------------------------------------------------------------------
// The slider surface is a closed-core / open-module system, like every
// surface in this tree:
//
//   - The CLOSED CORE is this file: the `Sub` contract plus the generic
//     render/interaction/poll/commit shell below. It never names a control
//     module; every control is reached through `subs`, the generated
//     registry (see build.zig's `buildSubsRegistryModule`).
//
//   - The OPEN MODULES are the siblings that bind `pub const sub: Sub`.
//     Siblings WITHOUT the binding (the native_alsa / native_pulse backends)
//     are private implementation files: importable by stem, never bound.
//     Membership in `subs` comes from FILE PRESENCE plus self-declared role,
//     so adding a control is drop a file; deleting one is delete the file.
//
// To add a control: drop `foo.zig` here exporting `pub const sub: Sub`.
// ---------------------------------------------------------------------------

pub const Sub = struct {
    /// Config/prefix identity ("volume", "brightness", ...): the name a
    /// future `slider_items`-style selector would address this control by.
    name: []const u8,
    /// Per-sub poll cadence.
    read_interval_ms: i64 = 5000,
    /// True once the sub has an answer; while false the sub renders nothing
    /// (zero-width slot, unclickable). Null = always present.
    has_value: ?*const fn () bool = null,
    /// True while the backend can write; while false interactions no-op but
    /// the level still displays.
    writable: *const fn () bool,
    /// Refresh the sub's live state (attach/probe cached inside); returns
    /// true when the displayed state changed this call.
    read: *const fn () bool,
    /// The currently displayed 0-100 level.
    pct: *const fn () u8,
    /// Optimistic display update used by scroll/drag: advances what the next
    /// label render shows without a backend round trip; the next read
    /// reconciles truth.
    preview: *const fn (u8) void,
    /// True when THIS sub's commits are native in-process calls (one ioctl /
    /// sysfs write / libpulse round trip) and need no throttling.
    commit_is_native: *const fn () bool,
    /// Writes `pct` to the backend (native call or subprocess spawn). The
    /// 0-100 clamp is the sub's single guard.
    commit: *const fn (u8) void,
    /// One-shot apply (press set / drag-end): commit + immediately re-read so
    /// the label follows the sink/device truth.
    apply: *const fn (u8) void,
    /// Renders the idle label into `buf` (sub-scoped scratch) from the sub's
    /// own state and config; valid until the next call.
    label: *const fn (types.BarConfig, []u8) []const u8,
    /// Right-click action (volume's mute toggle); null = reserved no-op.
    secondary: ?*const fn () void = null,
    /// Idle width when the sub has never laid out (natural-reserve fallback).
    probe_natural_width: u16 = 44,
};

const Instance = struct {
    /// Latched on the sub's first read (the segment's first draw arms every
    /// present sub). Poll deadlines only count armed instances.
    armed: bool = false,
    next_read_ms: i64 = 0,
    /// Sub-slot bounds relative to the segment start, from the last idle
    /// draw: the click hit-test range and the slider denominator.
    slot_x: u16 = 0,
    slot_w: u16 = 0,
    /// Sub-scoped label scratch, so each sub's label stays valid until its
    /// own next draw.
    scratch: [128]u8 = undefined,
};

var g_inst: [subs.len]Instance = [_]Instance{.{}} ** subs.len;

var g_armed: bool = false;
var g_pending_redraw: bool = false;
var g_throttle: Throttle = .{ .interval_ms = throttle_ms };
/// Index of the sub whose value was last previewed and may be owed to the
/// throttle; the flush target for poll and drag-end sweeps.
var g_commit_sub: usize = 0;
/// Last-interacted sub: the default wheel target (a drag takes precedence).
var g_active_sub: usize = 0;
/// Sub currently scrubbed by a press-hold, if any (one exclusive drag).
var g_drag_sub: ?usize = null;

/// A sub's recorded slot bounds in the drawn belt (see `slotAt`).
pub const Slot = struct {
    x: u16,
    w: u16,
};

/// Linear slider mapping across a slot: a pointer offset (relative to the
/// segment start) maps to 0-100 % of the slot. The bar records the click
/// bound at the reserved width, which mirrors `slot_w` at draw time.
pub fn pctFromSlot(slot_x: u16, slot_w: u16, offset: u16) u8 {
    const w: u32 = @max(slot_w, 1);
    const base: u32 = @as(u32, offset) -| @as(u32, slot_x);
    const v: u32 = base * 100 / w;
    return @intCast(@min(v, 100));
}

/// Which recorded slot owns the pointer offset (relative to the segment
/// start), by the slot bounds from the last idle draw. Zero-width slots hold
/// nothing. Pure: tested directly by slider_test.
pub fn slotAt(offset: u16, slots: []const Slot) ?usize {
    const off: u32 = offset;
    for (slots, 0..) |s, i| {
        if (s.w == 0) continue;
        if (off >= s.x and off < @as(u32, s.x) + s.w) return i;
    }
    return null;
}

/// Which sub owns the pointer offset, from the belt bounds recorded at the
/// last idle draw.
fn subAt(offset: u16) ?usize {
    var slots: [subs.len]Slot = undefined;
    for (g_inst, 0..) |inst, i| slots[i] = .{ .x = inst.slot_x, .w = inst.slot_w };
    return slotAt(offset, &slots);
}

/// The slider denominator for sub `i` at pointer `offset`.
fn pctAt(i: usize, offset: u16) u8 {
    return pctFromSlot(g_inst[i].slot_x, g_inst[i].slot_w, offset);
}

fn present(i: usize) bool {
    if (subs[i].has_value) |h| return h();
    return true;
}

/// Preview the value optimistically and run it through the shared commit
/// scheduler (native un-throttled, spawn rate-limited). Marks `i` as the
/// active/commit sub.
fn commitPreview(idx: usize, pct: u8) void {
    const sub = subs[idx];
    sub.preview(pct);
    g_commit_sub = idx;
    g_active_sub = idx;
    g_throttle.apply(sub.commit_is_native(), pct, sub.commit);
}

/// Poll deadline: the segment doesn't arm itself until its first draw (when
/// the bar actually renders it), so an unconfigured slider never wakes the
/// loop. Returns -1 while unarmed, ms until the next wake otherwise (0 = due
/// now): the earliest of every armed sub's read cadence and an owed commit
/// flush.
fn pollDeadlineMs() i32 {
    if (!g_armed) return -1;
    var deadline: i64 = std.math.maxInt(i64);
    for (g_inst) |inst| {
        if (inst.armed) deadline = @min(deadline, inst.next_read_ms);
    }
    if (g_throttle.pending) {
        const flush_at = g_throttle.last_ms + g_throttle.interval_ms;
        if (flush_at < deadline) deadline = flush_at;
    }
    if (deadline == std.math.maxInt(i64)) return -1;
    const left = deadline - nowMs();
    if (left <= 0) return 0;
    return @intCast(@min(left, max_cadence_ms));
}

fn onPollWakeup() void {
    if (!g_armed) return;
    if (subs.len != 0) {
        // Sweep an owed scroll/drag commit whose throttle window has elapsed
        // (the read cadence below stays gated: this wake exists purely to
        // land the newest value the backend hasn't seen yet).
        g_throttle.flushOwed(subs[g_commit_sub].pct(), subs[g_commit_sub].commit);
    }
    for (subs, 0..) |sub, i| {
        const inst = &g_inst[i];
        if (!inst.armed) continue;
        if (nowMs() < inst.next_read_ms) continue;
        inst.next_read_ms = nowMs() + sub.read_interval_ms;
        if (sub.read()) g_pending_redraw = true;
    }
}

fn consumeRedrawRequest() bool {
    const p = g_pending_redraw;
    g_pending_redraw = false;
    return p;
}

fn naturalWidthHook(_: *const anyopaque, _: u16) u16 {
    var total: u16 = 0;
    for (subs, 0..) |sub, i| {
        if (!present(i)) continue;
        total +|= if (g_inst[i].slot_w != 0) g_inst[i].slot_w else sub.probe_natural_width;
    }
    return total;
}

/// Drag-mode loading bar for one sub: paints its whole reserved slot with a
/// background strip plus a fill (the title segment's minimized accent) and
/// overlays the live percentage centered in the slot. Returns the slot's far
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
    if (std.fmt.bufPrint(&b, "{d}", .{pct})) |ps| {
        const tw = dc.dc.measureTextWidth(ps);
        dc.dc.drawText(x +| slot / 2 -| tw / 2, dc.dc.baselineY(height), ps, dc.config.fg) catch {};
    } else |_| {}
    return x + slot;
}

fn drawHook(ctx: *anyopaque, x: u16) !u16 {
    const dc = segmod.castDraw(ctx);
    // First draw arms every sub: fill each label before its own cadence.
    if (!g_armed) {
        for (subs, 0..) |sub, i| {
            if (!g_inst[i].armed) {
                _ = sub.read();
                g_inst[i].armed = true;
                g_inst[i].next_read_ms = nowMs() + sub.read_interval_ms;
            }
        }
        g_armed = true;
    }

    var cx = x;
    for (subs, 0..) |sub, i| {
        if (!present(i)) continue;
        const inst = &g_inst[i];
        inst.slot_x = cx - x;
        // While scrubbed the sub is a loading bar; the label resumes on the
        // drag-end redraw. The other subs render normally beside it.
        if (g_drag_sub == i) {
            cx = drawDragBar(dc, cx, inst.slot_w, sub.pct());
            continue;
        }
        const label = sub.label(dc.config, &inst.scratch);
        const end_x = try drawing.drawPaddedSegment(dc.dc, dc.config, dc.height, cx, label);
        // Track the ACTUAL painted width, not the row reservation: the
        // palette must follow the text, or the segment locks onto the startup
        // probe and its neighbors overlap it, forever (matches the widthState
        // collapse path). A width change marks the segment dirty so the bar
        // re-lays out. The slot also feeds the click bound and the slider
        // denominator.
        const drawn = end_x - cx;
        if (drawn != inst.slot_w) g_pending_redraw = true;
        inst.slot_w = drawn;
        cx = end_x;
    }
    return cx;
}

/// Left press: enter drag mode on the pressed sub and set its level at that
/// position; right press: the sub's secondary action (mute toggle), reserved
/// for subs without one.
fn onClickHook(
    offset: u16,
    left: bool,
    right: bool,
    _: *anyopaque,
    _: *const fn (*anyopaque, u16) void,
    redraw: *const fn () void,
) bool {
    const i = subAt(offset) orelse return false;
    const sub = subs[i];
    if (left) {
        if (!sub.writable()) return false;
        // Enter drag mode immediately, and restart the commit clock after this
        // press's set so the first motion doesn't double-send.
        g_drag_sub = i;
        sub.apply(pctAt(i, offset));
        g_throttle.reset();
    } else if (right) {
        const secondary = sub.secondary orelse return false;
        secondary();
    } else {
        return false;
    }
    g_active_sub = i;
    g_pending_redraw = true;
    redraw();
    return true;
}

fn onScrollHook(dir: i8, redraw: *const fn () void) bool {
    if (subs.len == 0) return false;
    const idx = g_drag_sub orelse g_active_sub;
    if (idx >= subs.len) return false;
    const sub = subs[idx];
    if (!g_inst[idx].armed) return false;
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
    // -- scrolling at 0/100 % is a true no-op, never backend traffic.
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
fn onDragMotionHook(offset: u16, redraw: *const fn () void) bool {
    const i = g_drag_sub orelse return false;
    if (!subs[i].writable()) return false;
    commitPreview(i, pctAt(i, offset));
    redraw();
    return true;
}

/// Scrub end (button-1 release): force-land any owed commit, re-read the
/// sub so its label shows the truth, and repaint back to text mode.
fn onDragEndHook(redraw: *const fn () void) void {
    if (subs.len != 0) {
        g_throttle.finish(subs[g_commit_sub].pct(), subs[g_commit_sub].commit);
    }
    if (g_drag_sub) |i| {
        g_drag_sub = null;
        _ = subs[i].read();
        g_pending_redraw = true;
        redraw();
    }
}

pub const module: @import("plugin").Segment = .{
    .name = "slider",
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
    .onDragEnd = onDragEndHook,
};

// Pure geometry helpers (pctFromSlot, slotAt) are covered by slider_test; the
// stateful wrappers above are exercised end-to-end through interaction tests.
