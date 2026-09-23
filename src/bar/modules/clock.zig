//! Clock bar segment.
//!
//! Renders wall-clock time and schedules its own repaints: the event loop
//! asks bar.pollTimeoutMs() for the nearest timer deadline (this segment
//! contributes the ms-to-next-boundary value) and wakes exactly at
//! whole-second boundaries; `bar.updateClock` then redraws this segment when
//! its on-screen content has gone stale (second rolled over, a config reload
//! changed the format, or the display mode changed). The three display modes
//! -- date-time (default, configured format), time-only, date-only -- cycle
//! by clicking the segment: left-click advances, right-click reverses.
//! Single-threaded by construction -- all state lives on the main thread, so
//! there are no locks, flags, or drain races (docs/clock-plan.md).

const std = @import("std");
const types = @import("types");
const utils = @import("utils");
const drawing = @import("drawing");
const segdraw = @import("segdraw");

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

/// Reserved slot width for the current display mode (probe width + padding),
/// stable within a mode. Zero until the clock has drawn once; the bar's
/// `updateClock` then folds it into the row reservation and re-lays when a
/// mode cycle changes it.
var reserved_width: u16 = 0;
/// The mode `reserved_width` was measured for; cycling to a different mode
/// re-measures on the next draw.
var reserved_mode: ?DisplayMode = null;

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

/// What is currently on screen: the epoch second last rendered and the
/// format string used for it. Plain vars -- only the main thread touches
/// them. Comparing the format pointer catches config reloads that change
/// the format mid-second (a spurious extra reformat on equal content is
/// harmless); comparing the second catches the passage of time.
var rendered_sec: i64 = -1;
var rendered_fmt: []const u8 = "";

fn stale(sec: i64, fmt: []const u8) bool {
    return sec != rendered_sec or fmt.ptr != rendered_fmt.ptr;
}

/// True when the segment on screen no longer matches (sec, fmt).
/// Callers pass the base configured format so reloads invalidate without a
/// separate flag; the segment folds its own display-mode format in on top of
/// it (the effective format), so a mode cycle changes the compared pointer
/// and the next bar.updateClock repaints the clock. Drawing clears staleness
/// as a side effect of rendering; a failed draw leaves it stale so the next
/// boundary retries.
fn secondElapsed(base_fmt: []const u8) bool {
    return stale(currentEpochSeconds(), effectiveFormatFor(base_fmt, mode));
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
    return deadlineFromMs(utils.realtimeMs());
}

// Drawing

/// Draws the current time at `start_x`, formatting lazily: the strftime run
/// happens at most once per wall-second (or after a format change), right
/// here on the main thread. Covers the reserved slot with the active mode's
/// own probe so a region-scoped repaint (mode cycle) leaves no stale pixels
/// from the previous wider view.
fn draw(dc: *drawing.DrawContext, config: types.BarConfig, height: u16, start_x: u16) !u16 {
    var buf: [64]u8 = undefined;
    const sec = currentEpochSeconds();
    const fmt = effectiveFormatFor(drawing.clockFormat(config), mode);
    const str = try formatTime(&buf, sec, fmt);
    // Refresh the mode's reserved width once per mode; the probe is stable, so
    // per-second text-width drift never re-lays the row.
    if (reserved_mode != mode) {
        reserved_mode = mode;
        reserved_width = dc.measureTextWidthStyled(measureStringFor(mode), config.segmentProps("clock")) +
            2 * config.scaledSegmentPadding(height);
    }
    // Record the attempt before rendering: a persistent render failure
    // (e.g. fonts unavailable) must degrade to one retry per boundary --
    // the second-boundary cadence -- never to a per-event-batch retry storm.
    // A genuine transient miss simply shows the previous second for up to
    // one extra second, exactly as the cadence design intends.
    rendered_sec = sec;
    rendered_fmt = fmt;
    return drawing.drawPaddedSegment(dc, config, height, start_x, "clock", str, measureStringFor(mode), config.segmentProps("clock"));
}

/// Reserved row width: the current mode's slot (measured once per mode) once
/// the clock has drawn, else the bar's freshly computed probe width for the
/// initial layout. Also drives the bar's reflow check in updateClock, which
/// compares this against the laid-out reservation after a clock-only repaint.
fn naturalWidthHook(_: *const anyopaque, fallback: u16) u16 {
    return if (reserved_width > 0) reserved_width else fallback;
}

/// Resets the mode width reservation so the next draw re-measures the active
/// mode's probe under the current config (a reload may change the font or
/// padding). Until then the bar's freshly computed probe width (the natural
/// width fallback) applies, so the reservation never collapses to zero.
fn invalidateWidth() void {
    reserved_width = 0;
    reserved_mode = null;
}

fn currentEpochSeconds() i64 {
    return @intCast(utils.realtimeNs() / ns_per_s);
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

    var fmt_z: [128]u8 = undefined;
    if (fmt.len >= fmt_z.len) return error.FormatTooLong;
    @memcpy(fmt_z[0..fmt.len], fmt);
    fmt_z[fmt.len] = 0;

    const n = c.strftime(buf.ptr, buf.len, &fmt_z, tm_ptr);
    if (n == 0) return error.StrftimeFailed;
    return buf[0..n];
}

/// Cycles the clock's display mode: left-click advances date-time -> time ->
/// date -> date-time, right-click cycles the opposite way. The repaint rides
/// the existing staleness path: the mode change alters the effective format
/// pointer, so the bar's end-of-batch updateClock runs the region-scoped
/// clock redraw this same batch.
fn onClickHook(
    _: u16,
    left: bool,
    _: bool,
    _: *anyopaque,
    _: *const fn (*anyopaque, u16) void,
    _: *const fn () void,
) bool {
    mode = cycledMode(mode, left);
    return true;
}

/// This module's bar-segment contribution (registry binding). Natural width is
/// the current mode's measured slot (auto-sized to the active view via the
/// naturalWidth hook; the passthrough measureString default sizes a fresh bar).
pub const module = segdraw.module(
    "clock",
    draw,
    null,
    .{
        .self_ticking = true,
        .on_click = onClickHook,
        .pollTimeoutMs = tickDeadlineMs,
        .secondsElapsed = secondElapsed,
        .measureString = measureString,
        .natural_width = naturalWidthHook,
        .invalidate = invalidateWidth,
        .invalidateReloadCaches = invalidateWidth,
    },
);
