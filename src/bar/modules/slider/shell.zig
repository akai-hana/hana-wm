//! The slider interaction shell: everything a bound control needs to BE a
//! live bar segment -- click hit-test over the control's own slot, exclusive
//! press-hold drag, wheel steps, one-shot applies, the poll loop
//! (per-control cadence + owed-sweep), the commit scheduler (`Throttle`),
//! and the per-segment lifecycle (arm-on-first-draw, dirty redraw marking,
//! painted-width tracking).
//!
//! This file sits BESIDE the package core (`slider.zig`), which keeps the
//! `Sub` contract, the generated `subs` registry, the pct map and the
//! `segmentFor(i)` binding build.zig emits -- that binding's hooks below are
//! reached through `shell.*` re-points in the core, so the bar registry
//! still imports `slider.segmentFor` and never this file. The dependency is
//! one-WAY: the core imports this shell; the shell reads the contract
//! THROUGH the registry (`slider_subs`) and never imports the core, which
//! is why the contract type is named as `@TypeOf(subs[0])` below rather
//! than as `slider.Sub`.
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
//!
//! The per-segment lifecycle is a structural twin of systatus.zig's
//! read-only version -- and deliberately not shared with it: this shell adds
//! drag/scroll interaction, a commit throttle, and per-control cadences atop
//! the same 10-line shape, so extracting a common scaffold would cost a
//! parameterised contract surface for little net body. See systatus.zig.

const std = @import("std");
const time = @import("time");
const level = @import("level");
const drawing = @import("drawing");
const segmod = @import("segment");
const contract = @import("contract");

/// The generated registry, imported directly: this file never imports the
/// package core (see header), so the contract is reached as the registry
/// ELEMENT type below.
const subs = @import("slider_subs").subs;

/// The `Sub` contract type, named through the registry: the declaration
/// lives in the package core (`slider.zig`), and `subs[0]` is one element
/// of it -- naming it this way keeps the shell -> core edge out of the graph.
const Sub = @TypeOf(subs[0]);

/// The level map (lifted to `bar/level.zig`), called through `level`: the
/// core keeps its own slider-named re-export for its tests, and this alias
/// keeps the shell's dependency one-way.
const pctFromSlot = level.pctFromSlot;

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
/// What the caller wants a `write` to do. Named, and folded into ONE hook from
/// the three it replaces (`preview` / `commit` / `apply`).
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
/// Commit scheduler for scroll/drag events, shared by every slider control. A
/// native commit is applied immediately; a spawn commit runs at most once per
/// `interval_ms`, and an inside-window event is marked owed (coalesced onto
/// the newest value, flushed by the poll loop or drag end).
pub const Throttle = struct {
    interval_ms: i64,
    /// Where a landed commit goes. The scheduler is per control, so the control
    /// it writes to belongs here rather than being threaded through `apply` /
    /// `flushOwed` / `finish` as an argument. It was an argument because
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
        self.last_ms = time.realtimeMs();
        self.pending = false;
    }

    /// Decides one event. `cost` is the control's own latency class: an
    /// in-process write lands every time, a spawn waits for its window.
    pub fn apply(self: *Throttle, cost: CommitCost, pct: u8) void {
        if (cost == .immediate or time.realtimeMs() -| self.last_ms >= self.interval_ms) {
            self.land(pct);
        } else {
            self.pending = true;
        }
    }

    /// Restarts the commit clock and clears any owed value, for an immediate
    /// one-shot commit (the press that enters drag mode) so the first motion
    /// does not double-send.
    pub fn reset(self: *Throttle) void {
        self.last_ms = time.realtimeMs();
        self.pending = false;
    }

    /// The poll-loop sweep: flushes an owed commit whose window has elapsed
    /// (the newest value lands exactly once per window).
    pub fn flushOwed(self: *Throttle, pct: u8) void {
        if (self.pending and time.realtimeMs() -| self.last_ms >= self.interval_ms) {
            self.land(pct);
        }
    }

    /// Drag end: force-lands the final value when one is still owed (the
    /// authoritative release of a scrub), regardless of the window.
    pub fn finish(self: *Throttle, pct: u8) void {
        if (self.pending) self.land(pct);
    }
};
/// One control's mutable state, indexed by registry position (segment i ==
/// subs[i]). The AoS slot for what used to be five parallel arrays
/// (g_inst/g_armed/g_pending_redraw/g_throttle/g_drag): the arrays shared
/// only an index, so a control's lifecycle was spread across five
/// declarations to keep in lockstep. One struct says which fields belong to
/// the same control, and `&g_state[idx]` hands the whole lifecycle to a
/// helper at once (the same shape systatus's `Readout` gives its readouts).
const SubState = struct {
    /// Set by the control's first draw (which arms it: the segment doesn't
    /// wake the loop before the bar actually renders it).
    armed: bool = false,
    /// A value-changed redraw is owed (see `consumeRedrawRequestFor`).
    pending_redraw: bool = false,
    /// Whether this control is currently scrubbed by a press-hold (one
    /// exclusive drag per segment).
    drag: bool = false,
    next_read_ms: i64 = 0,
    /// The control's commit scheduler, pointing at its own write hook. `subs`
    /// is comptime-generated, so the wiring is a comptime loop with no runtime
    /// init and no per-event lookup.
    throttle: Throttle,
    /// Sub-scoped label scratch, so each control's label stays valid until
    /// its own next draw.
    scratch: [128]u8 = undefined,
};

var g_state: [subs.len]SubState = blk: {
    var states: [subs.len]SubState = undefined;
    for (0..subs.len) |i| states[i] = .{ .throttle = .{ .interval_ms = throttle_ms, .write = subs[i].write } };
    break :blk states;
};

/// Applies control `idx`'s declared commit window to its scheduler, once the
/// control is known. Called at arm time; a control that shares the default
/// keeps it.
fn applyCommitWindow(idx: usize) void {
    if (subs[idx].commit_window_ms) |w| g_state[idx].throttle.interval_ms = w;
}
/// The width the bar reserves for control `idx`, and the ONE denominator for
/// everything that needs a slider's width: the row reservation
/// (`naturalWidthFor`), the drag mapping (`pctAt`) and the click hit-test
/// (`onClickFor`).
///
/// These used to disagree on the first frame: the width was 0 until the
/// segment's first draw completed, `onClickFor` rejected every click while it
/// was 0 (so the very first press on a freshly laid-out slider did nothing at
/// all), and the drag denominator and the row reservation fell back to
/// DIFFERENT values. `widthState.resolved` is now that one rule, shared
/// with systatus, so the hit-test, the drag range and the reservation cannot
/// disagree about what "not measured yet" means.
/// The shared `segmod.widthState` singleton for this control's name, which
/// owns the store / consumeRedrawRequest / resolved triple. The hand-rolled
/// `slot_w` field plus its inline "did the width change? mark dirty"
/// was a second implementation of code systatus already used, and this module
/// is comptime-indexed by `subs`, so one instantiation per name is exactly
/// the state each control needs.
fn widthStateFor(comptime idx: usize) type {
    return segmod.widthState(subs[idx].name);
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

/// The control's displayed level for the drag mapping, or 0 when it has not
/// answered. The 0 is the level an empty slider would have drawn, so a control
/// that loses its backend mid-gesture settles at "nothing" rather than at a
/// stale or arbitrary value.
pub fn subLevelOrZero(sub: Sub) u8 {
    return subLevel(sub) orelse 0;
}
/// Preview the value optimistically and run it through the control's own
/// commit scheduler (native un-throttled, spawn rate-limited).
fn commitPreview(idx: usize, pct: u8) void {
    const sub = subs[idx];
    sub.write(.preview, pct);
    g_state[idx].throttle.apply(sub.commit_cost(), pct);
}

/// Poll deadline for control `idx`: the segment doesn't arm itself until its
/// first draw (when the bar actually renders it), so an unconfigured control
/// never wakes the loop. Returns -1 while unarmed, ms until the next wake
/// otherwise (0 = due now): the earliest of the control's read cadence and an
/// owed commit flush.
pub fn pollDeadlineMsFor(idx: usize) i32 {
    const st = &g_state[idx];
    if (!st.armed) return -1;
    var deadline: i64 = st.next_read_ms;
    if (st.throttle.pending) {
        const flush_at = st.throttle.last_ms + st.throttle.interval_ms;
        if (flush_at < deadline) deadline = flush_at;
    }
    const left = deadline - time.realtimeMs();
    if (left <= 0) return 0;
    return @intCast(@min(left, max_cadence_ms));
}

pub fn onPollWakeupFor(idx: usize) void {
    const st = &g_state[idx];
    if (!st.armed) return;
    // Sweep an owed scroll/drag commit whose throttle window has elapsed
    // (the read cadence below stays gated: this wake exists purely to land
    // the newest value the backend hasn't seen yet).
    st.throttle.flushOwed(subLevelOrZero(subs[idx]));
    if (time.realtimeMs() < st.next_read_ms) return;
    st.next_read_ms = time.realtimeMs() + subs[idx].read_interval_ms;
    if (subs[idx].read()) st.pending_redraw = true;
}

pub fn consumeRedrawRequestFor(idx: usize) bool {
    const st = &g_state[idx];
    const p = st.pending_redraw;
    st.pending_redraw = false;
    return p;
}

pub fn naturalWidthFor(idx: usize) u16 {
    if (!subPresent(subs[idx])) return 0;
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
    const fill_w = level.offsetFromPct(0, inner_w, pct);
    if (fill_w != 0 and inner_h != 0)
        dc.dc.fillRect(x + pad, pad, fill_w, inner_h, dc.config.title_minimized_accent);

    var b: [8]u8 = undefined;
    const ps = std.fmt.bufPrint(&b, "{d}", .{pct}) catch return x + slot;
    const tw = dc.dc.measureTextWidth(ps);
    dc.dc.drawText(x +| slot / 2 -| tw / 2, dc.dc.baselineY(height), ps, dc.config.fg);
    return x + slot;
}

pub fn drawFor(comptime idx: usize, ctx: *anyopaque, x: u16) !contract.Painted {
    const dc = segmod.castDraw(ctx);
    const sub = subs[idx];
    const st = &g_state[idx];
    // First draw arms the control: fill its label before its own cadence.
    if (!st.armed) {
        _ = sub.read();
        st.armed = true;
        st.next_read_ms = time.realtimeMs() + sub.read_interval_ms;
        applyCommitWindow(idx);
    }
    // Absent backend: nothing to show (a zero-width slot, unclickable, never
    // polled past arm); naturalWidth reports 0, so the layout leaves no gap.
    if (!subPresent(subs[idx])) return contract.Painted.nothing(x);
    // While scrubbed the control is a loading bar; the label resumes on the
    // drag-end redraw.
    if (st.drag) {
        // The scrub fills the reserved slot, so the painted span IS the
        // reserved width -- reporting it is a no-op against the measured label
        // width it replaces, which is exactly the intent: the label width must
        // survive the scrub so the drag-end redraw re-renders it in place.
        return contract.Painted.span(x, drawDragBar(dc, x, reservedWidth(idx), subLevelOrZero(subs[idx])));
    }
    const label = sub.label(dc.config, &st.scratch);
    const end_x = try drawing.drawPaddedSegmentValue(dc.dc, dc.config, dc.height, x, sub.name, label.text, label.value_start, label.value_len, dc.config.segmentProps(sub.name));
    // Report the ACTUAL painted width, not the row reservation: the palette
    // must follow the text, or the segment locks onto the startup probe and
    // its neighbors overlap it, forever (matches the widthState collapse
    // path).
    //
    // The store itself is NOT here. The bar hands the width back through
    // onPainted, which owns the "changed -> owes a re-layout" rule;
    // the module's own pending flag is left to mean the OTHER reason a slider
    // repaints (its value committed). Both are consumed together, so neither
    // can leak a request.
    return contract.Painted.span(x, end_x);
}

/// Left press: enter drag mode on the control and set its level at that
/// position; right press: the control's secondary action (mute toggle),
/// reserved for controls without one.
pub fn onClickFor(idx: usize, ctx: *const contract.ClickCtx) bool {
    const sub = subs[idx];
    const st = &g_state[idx];
    if (!ctx.is_left and !ctx.is_right) return false;
    if (!subPresent(subs[idx])) return false;
    // Bound by the SAME width the row reserved, not by the last painted width:
    // a press that arrives before the first draw still maps to a level instead
    // of being dropped.
    const bound = reservedWidth(idx);
    if (ctx.offset >= bound) return false;
    if (ctx.is_left) {
        if (!sub.writable()) return false;
        // Enter drag mode immediately, and restart the commit clock after
        // this press's set so the first motion doesn't double-send.
        st.drag = true;
        sub.write(.apply, pctAt(idx, ctx.offset));
        st.throttle.reset();
    } else {
        const secondary = sub.secondary orelse return false;
        secondary();
    }
    st.pending_redraw = true;
    ctx.redraw();
    return true;
}

pub fn onScrollFor(idx: usize, dir: i8, redraw: *const fn () void) bool {
    const sub = subs[idx];
    if (!g_state[idx].armed) return false;
    if (!subPresent(subs[idx])) return false;
    if (!sub.writable()) return false;
    const base: u16 = subLevelOrZero(subs[idx]);
    const new_u: u16 = if (dir > 0)
        @min(base + scroll_step, 100)
    else
        base -| scroll_step;
    const pct: u8 = @intCast(new_u);
    // Boundary: the clamped target equals the current level, so this wheel
    // step changes nothing. Claim it and return without writing or repainting
    // scrolling at 0/100 % is a true no-op, never backend traffic.
    if (pct == subLevelOrZero(subs[idx])) return true;
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
/// Deliberately does NOT raise `pending_redraw`: bar.zig's post-batch
/// `updateIfDirty` folds that flag into a FULL-bar redraw, defeating the
/// scoped `redraw` callback every motion. The bar passes the segment-scoped
/// repaint here, so the display is updated without re-laying the whole bar.
pub fn onDragMotionFor(idx: usize, offset: u16, redraw: *const fn () void) bool {
    if (!g_state[idx].drag) return false;
    if (!subs[idx].writable()) return false;
    commitPreview(idx, pctAt(idx, offset));
    redraw();
    return true;
}

/// Scrub end (button-1 release): force-land any owed commit, re-read the
/// control so its label shows the truth, and repaint back to text mode.
pub fn onDragEndFor(idx: usize, redraw: *const fn () void) void {
    const st = &g_state[idx];
    st.throttle.finish(subLevelOrZero(subs[idx]));
    if (st.drag) {
        st.drag = false;
        _ = subs[idx].read();
        st.pending_redraw = true;
        redraw();
    }
}
/// Where the bar's painted-width report lands: this control's own width
/// state, which both its naturalWidth hook and the click bound's
/// denominator read back. The store itself is not here: the bar hands the
/// width back through onPainted, which owns the "changed -> owes a
/// re-layout" rule; the module's own pending flag means the OTHER reason a
/// slider repaints (its value committed). Both are consumed together, so
/// neither can leak a request.
pub fn onPaintedFor(comptime idx: usize, width: u16) void {
    widthStateFor(idx).store(width);
    if (widthStateFor(idx).consumeRedrawRequest()) g_state[idx].pending_redraw = true;
}
