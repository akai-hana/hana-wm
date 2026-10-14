//! Clock bar segment.
//!
//! Renders wall-clock time and schedules its own repaints: the event loop
//! asks bar.pollTimeoutMs() for the nearest timer deadline (this segment
//! contributes the ms-to-next-boundary value) and wakes exactly at
//! whole-second boundaries; `bar.updateClock` then redraws this segment when
//! its on-screen content has gone stale (second rolled over, a config reload
//! changed the format, or the display mode changed). The three display modes
//! -- date-time (default, configured format), time-only, date-only -- cycle
//! by clicking the segment: left-click advances, right-click reverses. A cycle
//! also moves the reserved slot width, so the bar re-lays the row for the new
//! mode rather than ticking in place (see bar.updateClock).
//! Single-threaded by construction -- all state lives on the main thread, so
//! there are no locks, flags, or drain races.

const std = @import("std");
const types = @import("types");
const drawing = @import("drawing");
const segmod = @import("segment");
const contract = @import("contract");

const time = @import("time");
const c = @cImport(@cInclude("time.h"));

const ns_per_s = std.time.ns_per_s;

/// Measurement string used to pre-compute the clock segment width.
const clock_measure_string: []const u8 = "0000-00-00 00:00:00";

/// Width probes for the narrower display modes, so the segment reserves the
/// span of the ACTIVE view rather than always the full date-time span.
const time_measure_string: []const u8 = "00:00:00";
const date_measure_string: []const u8 = "0000-00-00";

/// The mode-specific width probe: the string whose measured width the segment
/// reserves for that view. Stable within a mode, so per-second text drift never
/// re-lays the row; only a mode cycle (or a fresh bar) re-measures it. Pure,
/// so tests can pin each mode's probe.
pub fn measureStringFor(m: DisplayMode) []const u8 {
    return switch (m) {
        .date_time => clock_measure_string,
        .time => time_measure_string,
        .date => date_measure_string,
    };
}

/// The clock's reserved-width probe: the string the bar measures at
/// layout width. At most one module provides a `measureString` hook.
fn measureString() []const u8 {
    return measureStringFor(mode);
}

/// Display modes cycled by clicking the segment. date_time is the default and
/// renders the configured `clock_format`; time and date render built-in
/// strftime formats on their own.
pub const DisplayMode = enum(u2) { date_time, time, date };

/// strftime formats for the time-only and date-only modes.
const time_format: []const u8 = "%H:%M:%S";
const date_format: []const u8 = "%Y-%m-%d";

/// Current on-screen clock mode. Plain var -- only the main thread touches it.
var mode: DisplayMode = .date_time;

/// The format `m` maps `base` (the configured format) to: the config format
/// unchanged in date_time mode, a fixed built-in otherwise. Pure, so tests can
/// pin each mode's format.
pub fn effectiveFormatFor(base: []const u8, m: DisplayMode) []const u8 {
    return switch (m) {
        .date_time => base,
        .time => time_format,
        .date => date_format,
    };
}

/// The next mode after `m` when cycling in direction `forward` (left-click =
/// +1, right-click = -1), wrapping through the three states and back. Pure, so
/// tests can pin the wrap directions.
pub fn cycledMode(m: DisplayMode, forward: bool) DisplayMode {
    return switch (m) {
        .date_time => if (forward) .time else .date,
        .time => if (forward) .date else .date_time,
        .date => if (forward) .date_time else .time,
    };
}

/// What is currently on screen: the epoch second last rendered, the display
/// mode rendered under, and an OWNED copy of the effective format (a fixed
/// buffer, never a slice into config memory -- see recordRendered). Plain
/// vars -- only the main thread touches them. Comparing the second catches
/// the passage of time; the format's BYTES catch config reloads; the mode
/// catches display-mode cycles whose effective format happens to be
/// byte-identical (date_time configured as the built-in time format), where
/// the bytes alone would read "unchanged" even though the mode's width probe
/// -- the reservation -- moved.
pub const fmt_limit: usize = 128;
var rendered_sec: i64 = -1;
var rendered_mode: DisplayMode = .date_time;
var rendered_fmt_buf: [fmt_limit]u8 = undefined;
var rendered_fmt_len: usize = 0;

/// The record's clip: the store and the compare both truncate `fmt` here, so
/// they always see the same byte span. formatTime's own stack copy (fmt_z) is
/// this same length, so every format that CAN render compares exactly; one
/// that cannot (>= fmt_limit, rejected by formatTime) compares on its clip --
/// it paints nothing either way, and the record stays stable instead of
/// re-reading as changed forever (which would retry the doomed render every
/// event batch rather than once per second).
fn clip(fmt: []const u8) []const u8 {
    return fmt[0..@min(fmt.len, fmt_limit)];
}

/// The staleness predicate, pure so a test can drive it without a live wall
/// clock. Keyed on the format's BYTES, not on its pointer: a reload frees the
/// old config arena, so a re-parse can land a different format at a recycled
/// address, and a pointer compare would call that "unchanged" (or, worse,
/// "changed" for a format that did not move). The mode compare is what drives
/// the post-cycle width re-derivation (bar.updateClock): a cycle between two
/// modes whose effective bytes are identical still moves the width probe, so
/// it must read stale.
pub fn stalenessFor(
    sec: i64,
    rendered_sec_val: i64,
    m: DisplayMode,
    rendered_mode_val: DisplayMode,
    fmt: []const u8,
    rendered_fmt_val: []const u8,
) bool {
    if (sec != rendered_sec_val) return true;
    if (m != rendered_mode_val) return true;
    const want = clip(fmt);
    if (want.len != rendered_fmt_val.len) return true;
    return !std.mem.eql(u8, want, rendered_fmt_val);
}

/// True when the segment on screen no longer matches (sec, mode, fmt).
/// Callers pass the base configured format so reloads invalidate without a
/// separate flag; the segment folds its own display-mode format in on top of
/// it (the effective format) and compares the mode itself, so a mode cycle
/// invalidates whether or not the two modes' formats agree byte-for-byte.
/// Drawing clears staleness as a side effect of rendering; a failed draw
/// leaves it stale so the next boundary retries.
fn secondElapsed(base_fmt: []const u8) bool {
    const sec = currentEpochSeconds();
    const fmt = effectiveFormatFor(base_fmt, mode);
    return stalenessFor(sec, rendered_sec, mode, rendered_mode, fmt, rendered_fmt_buf[0..rendered_fmt_len]);
}

/// Records (sec, mode, format) as the on-screen state, copying the format
/// into this module's buffer. The copy is a correctness fix, not an
/// optimization: a config reload frees the old config, and a slice left
/// pointing at the old `clock_format` would compare against freed memory on
/// the next same-second staleness check. Called BEFORE the fallible
/// formatTime (the storm guard documented there), so a render failure still
/// records the attempt.
fn recordRendered(sec: i64, m: DisplayMode, fmt: []const u8) void {
    rendered_sec = sec;
    rendered_mode = m;
    const src = clip(fmt);
    rendered_fmt_len = src.len;
    @memcpy(rendered_fmt_buf[0..src.len], src);
}

/// Deadline arithmetic, factored out pure so tests can drive the clock.
/// ms from `now_ms` to the next whole-second wall-clock boundary: always in
/// [1, 1000]. poll()'s timeout is only a lower bound (POSIX), so the wake
/// lands at or after the boundary -- no grace padding is needed because
/// nothing must drain a producer's output before rendering; the render
/// itself happens lazily in draw().
pub fn deadlineFromMs(now_ms: i64) i32 {
    return @intCast(1000 - @mod(now_ms, 1000));
}

/// ms until the next whole-second boundary, contributed via bar.pollTimeoutMs().
fn tickDeadlineMs() i32 {
    return deadlineFromMs(time.realtimeMs());
}

// Drawing

/// Draws the current time at `start_x`, formatting lazily: the strftime run
/// happens at most once per wall-second (or after a format change), right
/// here on the main thread. Covers the reserved slot with the active mode's
/// own probe so a region-scoped repaint (mode cycle) leaves no stale pixels
/// from the previous wider view.
fn draw(dc: *drawing.DrawContext, config: types.BarConfig, height: u16, start_x: u16) !contract.Painted {
    var buf: [64]u8 = undefined;
    const sec = currentEpochSeconds();
    const fmt = effectiveFormatFor(drawing.clockFormat(config), mode);
    // Record the attempt BEFORE rendering. A persistent render failure (e.g.
    // fonts unavailable) must degrade to one retry per boundary -- the
    // second-boundary cadence -- never to a per-event-batch retry storm, and
    // only an assignment placed ahead of the fallible call can promise that.
    // (Placed after, as this once was, a failing formatTime left the record
    // untouched and every event batch retried -- the exact storm the comment
    // promised to prevent. A >=128-byte clock_format made it permanent, since
    // the stack buffer could never be large enough.) A genuine transient miss
    // simply shows the previous second for up to one extra second, exactly as
    // the cadence design intends.
    recordRendered(sec, mode, fmt);
    // Propagation is fine: the record above is already written, so a failure
    // still leaves the next retry one boundary away rather than one event
    // batch away.
    const str = try formatTime(&buf, sec, fmt);
    return contract.Painted.span(start_x, try drawing.drawPaddedSegment(
        dc,
        config,
        height,
        start_x,
        "clock",
        str,
        measureStringFor(mode),
        config.segmentProps("clock"),
    ));
}

fn currentEpochSeconds() i64 {
    return @intCast(time.realtimeNs() / ns_per_s);
}

/// Formats `sec` (seconds since the Unix epoch) into `buf` using `fmt` as a
/// strftime(3) format string. Uses localtime_r for the local timezone, falling
/// back to gmtime_r when timezone data is unavailable. Both are POSIX-guaranteed
/// reentrant.
fn formatTime(buf: []u8, sec: i64, fmt: []const u8) ![]const u8 {
    var raw_sec: c.time_t = @intCast(sec);
    var tm_buf: c.struct_tm = undefined;
    const tm_ptr = c.localtime_r(&raw_sec, &tm_buf) orelse
        c.gmtime_r(&raw_sec, &tm_buf);
    if (tm_ptr == null) return error.TimeFailed;

    var fmt_z: [fmt_limit]u8 = undefined;
    if (fmt.len >= fmt_limit) return error.FormatTooLong;
    @memcpy(fmt_z[0..fmt.len], fmt);
    fmt_z[fmt.len] = 0;

    const n = c.strftime(buf.ptr, buf.len, &fmt_z, tm_ptr);
    if (n == 0) return error.StrftimeFailed;
    return buf[0..n];
}

/// Cycles the clock's display mode: left-click advances date-time -> time ->
/// date -> date-time, right-click cycles the opposite way. The repaint rides
/// the existing staleness path: the mode change makes the next secondElapsed
/// report stale (the record's mode no longer matches), so the bar's
/// end-of-batch updateClock runs this same batch. That path re-derives the
/// clock budget and re-lays the row for the new mode's slot width (a narrower
/// mode's text cannot be blitted into the outgoing mode's wider reservation),
/// which is why this hook neither redraws nor measures anything itself.
fn onClickHook(ctx: *const contract.ClickCtx) bool {
    mode = cycledMode(mode, ctx.is_left);
    return true;
}

/// This module's bar-segment contribution (registry binding). Reserved width
/// is the bar's merged clock budget (State.Clock.width), passed in as the
/// `naturalWidth` argument and returned unmodified -- the builder's
/// measure-string passthrough. There is deliberately no clock-local width
/// store: the budget is re-derived at State.init, on the mode-aware staleness
/// path (bar.updateClock -> adoptFreshClockWidth), and within one second of
/// any config change on a surviving bar (the ordinary tick), always from the
/// same live probe the draw measures.
pub const module = segmod.module(
    "clock",
    draw,
    null,
    .{
        .self_ticking = true,
        .on_click = onClickHook,
        .pollTimeoutMs = tickDeadlineMs,
        .secondsElapsed = secondElapsed,
        .measureString = measureString,
        // The clock's reserved width is measured per mode, not observed from
        // what painted -- see SlotMode.self_measured.
        .mode = .self_measured,
    },
);
