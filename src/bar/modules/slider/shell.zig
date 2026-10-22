//! The slider interaction shell: click hit-test, exclusive press-hold drag,
//! wheel steps, one-shot applies, the poll loop (per-control cadence +
//! owed-sweep), the commit scheduler (`Throttle`), and the per-segment
//! lifecycle (arm-on-first-draw, dirty redraw, painted-width tracking).
//!
//! Sits BESIDE the package core (`slider.zig`), which keeps the `Sub`
//! contract, the generated `subs` registry, and the `segmentFor(i)` binding.
//! One-WAY dependency: the core imports this shell; the shell reads the
//! contract THROUGH the registry (`slider_subs`) -- which is why the contract
//! type is `@TypeOf(subs[0])` rather than `slider.Sub`.
//!
//! Interaction: wheel ±2%; left press / press-hold drag sets the level from
//! the horizontal position; right press is the secondary action (volume
//! mute). THROTTLING depends on the commit's cost: native commits (ioctl /
//! sysfs / libpulse) land immediately; subprocess spawns are rate-limited to
//! `throttle_ms` and coalesced onto the newest value. Display follows the
//! optimistic `preview`; backend truth arrives on the next read.

const std = @import("std");
const core = @import("core");
const level = @import("level");
const drawing = @import("drawing");
const segmod = @import("segment");
const contract = @import("bar_contract");

/// The generated registry, imported directly: this file never imports the
/// package core (see header), so the contract is reached as the registry
/// ELEMENT type.
const subs = @import("slider_subs").subs;

/// The `Sub` contract type, named through the registry so the shell ->
/// core edge stays out of the graph.
const Sub = @TypeOf(subs[0]);

const pctFromSlot = level.pctFromSlot;

const scroll_step: u8 = 2;
/// Longest cadence in the registry; a poll deadline closer than this wins
/// anyway, so this only bounds how far ahead a single wake can be scheduled.
const max_cadence_ms: i64 = 5000;

/// The control's effective poll cadence: its runtime hook when it has one,
/// else the static field. One spelling so poll and arm sites cannot drift.
fn readIntervalMs(s: Sub) i64 {
    return if (s.read_interval_ms_of) |f| f() else s.read_interval_ms;
}

/// Spawn-commit window DEFAULT. A fork+exec+pipe+waitpid blocks the WM's
/// event loop for ~1-5 ms, so a per-event spawn throttles the whole WM under
/// a fast drag; coalescing keeps a sweep to one window (`immediate` ignores it).
const throttle_ms: i64 = 80;
/// What the caller wants a `write` to do. One hook with a named mode so the
/// clamp and the display update each live in one place.
pub const Write = enum {
    /// Display only: advance the label now, write nothing. Scroll/drag motion.
    preview,
    /// Write to the backend. The 0-100 clamp is the control's single guard.
    commit,
    /// Write and show it: a press set, or the authoritative end of a scrub.
    /// Not throttled -- dropping it would leave the backend short of the
    /// value the user is looking at.
    apply,
};
/// The latency class of ONE commit, as a value the scheduler switches on
/// rather than a bare bool. Stays a function because the class is a per-BACKEND
/// fact resolved at runtime (sysfs vs `brightnessctl`; libpulse vs ALSA).
pub const CommitCost = enum { immediate, rate_limited };
/// Commit scheduler for scroll/drag events, shared by every slider control.
pub const Throttle = struct {
    interval_ms: i64,
    /// Where a landed commit goes. Per control, so it belongs here rather
    /// than threaded through `apply`/`flushOwed`/`finish`.
    write: *const fn (Write, u8) void,
    last_ms: i64 = 0,
    pending: bool = false,

    /// Commits `pct` through `write`, restarts the clock, clears any owed.
    fn land(self: *Throttle, pct: u8) void {
        self.write(.commit, pct);
        self.last_ms = core.realtimeMs();
        self.pending = false;
    }

    /// Decides one event: an in-process write lands every time; a spawn
    /// waits for its window.
    pub fn apply(self: *Throttle, cost: CommitCost, pct: u8) void {
        if (cost == .immediate or core.realtimeMs() -| self.last_ms >= self.interval_ms) {
            self.land(pct);
        } else {
            self.pending = true;
        }
    }

    /// Restarts the clock and clears any owed value, for an immediate
    /// one-shot (the press entering drag mode) so first motion doesn't
    /// double-send.
    pub fn reset(self: *Throttle) void {
        self.last_ms = core.realtimeMs();
        self.pending = false;
    }

    /// Poll-loop sweep: flushes an owed commit whose window has elapsed.
    pub fn flushOwed(self: *Throttle, pct: u8) void {
        if (self.pending and core.realtimeMs() -| self.last_ms >= self.interval_ms) {
            self.land(pct);
        }
    }

    /// Drag end: force-lands the final owed value, regardless of the window.
    pub fn finish(self: *Throttle, pct: u8) void {
        if (self.pending) self.land(pct);
    }
};
/// One control's mutable state, indexed by registry position (segment i ==
/// subs[i]). `&g_state[idx]` hands the whole lifecycle to a helper at once.
const SubState = struct {
    /// Set by the control's first draw (which arms it: the segment doesn't
    /// wake the loop before the bar actually renders it).
    armed: bool = false,
    pending_redraw: bool = false,
    /// Whether this control is currently scrubbed by a press-hold.
    drag: bool = false,
    next_read_ms: i64 = 0,
    /// The control's commit scheduler, pointing at its own write hook.
    /// `subs` is comptime-generated, so the wiring is a comptime loop.
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

/// Applies control `idx`'s declared commit window to its scheduler, once
/// the control is known. Called at arm time.
fn applyCommitWindow(idx: usize) void {
    if (subs[idx].commit_window_ms) |w| g_state[idx].throttle.interval_ms = w;
}
/// The shared `segmod.widthState` singleton for this control's name: owns
/// the store / consumeRedrawRequest / resolved triple, and is the ONE
/// denominator for the row reservation, drag mapping and click hit-test --
/// `resolved` is the shared "not measured yet" rule.
fn widthStateFor(comptime idx: usize) type {
    return segmod.widthState(subs[idx].name);
}

fn reservedWidth(idx: usize) u16 {
    // Event handlers reach here with a RUNTIME idx, while the width state
    // is one comptime-tagged singleton. `inline for` keeps the selection
    // comptime; no runtime `slot_w` mirror to fall out of sync with.
    inline for (0..subs.len) |i| {
        if (i == idx) return widthStateFor(i).resolved(subs[i].probeNaturalWidth);
    }
    unreachable;
}

/// The slider denominator for control `idx` at pointer `offset`.
fn pctAt(idx: usize, offset: u16) u8 {
    return pctFromSlot(0, reservedWidth(idx), offset);
}

/// A control's presence, from the contract alone. Pure, so a fake `Sub` can
/// exercise both directions without a backend -- the registry's own
/// controls are all absent in a headless test.
pub fn subPresent(sub: Sub) bool {
    if (sub.level) |l| return l() != null;
    return true;
}

/// A control's level, or null for "has not answered". Null HOOK means
/// always present, and reports 0.
pub fn subLevel(sub: Sub) ?u8 {
    const l = sub.level orelse return 0;
    return l();
}

/// The control's displayed level for the drag mapping, or 0 when it has not
/// answered (the level an empty slider would draw, so a control that loses
/// its backend mid-gesture settles at "nothing").
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

/// Poll deadline for control `idx`: doesn't arm until its first draw, so an
/// unconfigured control never wakes the loop. -1 while unarmed; ms until the
/// next wake otherwise (0 = due now): earliest of read cadence and owed flush.
pub fn pollDeadlineMsFor(idx: usize) i32 {
    const st = &g_state[idx];
    if (!st.armed) return -1;
    var deadline: i64 = st.next_read_ms;
    if (st.throttle.pending) {
        const flush_at = st.throttle.last_ms + st.throttle.interval_ms;
        if (flush_at < deadline) deadline = flush_at;
    }
    const left = deadline - core.realtimeMs();
    if (left <= 0) return 0;
    return @intCast(@min(left, max_cadence_ms));
}

pub fn onPollWakeupFor(idx: usize) void {
    const st = &g_state[idx];
    if (!st.armed) return;
    // Sweep an owed commit whose throttle window elapsed (the read cadence
    // stays gated: this wake exists purely to land the newest value).
    st.throttle.flushOwed(subLevelOrZero(subs[idx]));
    if (core.realtimeMs() < st.next_read_ms) return;
    st.next_read_ms = core.realtimeMs() + readIntervalMs(subs[idx]);
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
/// Returns the slot's far edge WITHOUT feeding the width state: the label
/// width must survive the scrub so the drag-end redraw re-renders it in place.
fn drawDragBar(dc: *segmod.DrawCtx, x: u16, slot: u16, pct: u8) u16 {
    const height = dc.height;
    dc.dc.fillRect(x, 0, slot, height, dc.config.bg);
    // Half the padding so the fill sits one padding inside the slot; at
    // least one pixel or a 1px-tall bar paints nothing.
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
        st.next_read_ms = core.realtimeMs() + readIntervalMs(sub);
        applyCommitWindow(idx);
    }
    // Absent backend: zero-width slot, unclickable, never polled past arm;
    // naturalWidth reports 0 so the layout leaves no gap.
    if (!subPresent(subs[idx])) return contract.Painted.nothing(x);
    // While scrubbed the control is a loading bar; the label resumes on the
    // drag-end redraw. The scrub fills the reserved slot, so the label width
    // must survive the scrub and not be overwritten by the painted span.
    if (st.drag) {
        return contract.Painted.span(x, drawDragBar(dc, x, reservedWidth(idx), subLevelOrZero(subs[idx])));
    }
    const label = sub.label(dc.config, &st.scratch);
    const end_x = try drawing.drawPaddedSegmentValue(dc.dc, dc.config, dc.height, x, sub.name, label.text, label.value_start, label.value_len, dc.config.segmentProps(sub.name));
    // Report the ACTUAL painted width, not the row reservation (see the
    // onPainted doc below): the module's pending flag means the OTHER repaint
    // reason, a committed value; both are consumed together here.
    return contract.Painted.span(x, end_x);
}

/// Left press: enter drag mode and set the level at that position; right
/// press: the control's secondary action (mute toggle), reserved for
/// controls without one.
pub fn onClickFor(idx: usize, ctx: *const contract.ClickCtx) bool {
    const sub = subs[idx];
    const st = &g_state[idx];
    if (!ctx.is_left and !ctx.is_right) return false;
    if (!subPresent(subs[idx])) return false;
    // Bound by the SAME width the row reserved, not the last painted width:
    // a press that arrives before the first draw still maps to a level.
    const bound = reservedWidth(idx);
    if (ctx.offset >= bound) return false;
    if (ctx.is_left) {
        if (!sub.writable()) return false;
        // Enter drag immediately; restart the commit clock so the first
        // motion doesn't double-send.
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
    // step changes nothing. Claim it without writing or repainting --
    // scrolling at 0/100 % is a true no-op, never backend traffic.
    if (pct == subLevelOrZero(subs[idx])) return true;
    // Optimistic display + throttled commit: the label follows immediately
    // while the write is coalesced; truth arrives on the read cadence.
    commitPreview(idx, pct);
    redraw();
    return true;
}

/// Press-hold scrub: updates the display immediately and schedules the
/// commit per motion -- native commits apply on every event, subprocess
/// spawns at most every `throttle_ms`. A value owed inside the window is
/// coalesced and flushed on release, or by the poll loop.
///
/// Deliberately does NOT raise `pending_redraw`: bar.zig's post-batch
/// `updateIfDirty` folds that flag into a FULL-bar redraw, defeating the
/// scoped `redraw` callback every motion. The bar passes the segment-scoped
/// repaint here so the display updates without re-laying the whole bar.
pub fn onDragMotionFor(idx: usize, offset: u16, redraw: *const fn () void) bool {
    if (!g_state[idx].drag) return false;
    if (!subs[idx].writable()) return false;
    commitPreview(idx, pctAt(idx, offset));
    redraw();
    return true;
}

/// Scrub end (button-1 release): force-land any owed commit, re-read so the
/// label shows the truth, and repaint back to text mode.
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
/// state, which its naturalWidth hook and the click bound's denominator read
/// back. The store is not here: the bar hands the width back through
/// `onPainted`, which owns "changed -> owes a re-layout"; the module's
/// pending flag means the OTHER repaint reason (value committed).
pub fn onPaintedFor(comptime idx: usize, width: u16) void {
    widthStateFor(idx).store(width);
    if (widthStateFor(idx).consumeRedrawRequest()) g_state[idx].pending_redraw = true;
}
