//! Threadless title marquee ("carousel").
//!
//! When the focused window's title is wider than its bar slot, it scrolls
//! continuously: copies of the text slide leftward through the cell,
//! separated by a fixed gap, wrapping seamlessly. Titles that fit are drawn
//! statically and this module stays inert.
//!
//! Design (mirrors clock.zig):
//!   - All state is plain main-thread vars; no thread, no locks.
//!   - Motion is elapsed-time-based: each frame advances a fractional offset
//!     by dt * speed, so redundant renders within one tick are harmless and
//!     event-driven redraws always show the current position.
//!   - Frames are requested through pollDeadlineMs(), contributed via the
//!     bar's poll-timeout minimum; rendering rides the normal redraw path.
//!   - The math is pure (see src/test/carousel_test.zig); identity is tracked
//!     by (window id, title hash) so a newly focused or renamed title always
//!     restarts from its beginning.

const std = @import("std");

/// Horizontal gap between the repeating copies of a title, in pixels.
pub const gap_px: u16 = 48;

/// Frame cadence follows the detected monitor refresh rate (see
/// refresh.detectedHz), so each frame advances by one display period
/// and motion is locked to the monitor's scanout. Motion itself is
/// sub-pixel: the fractional offset is handed straight to cairo, so at
/// high refresh rates frames differ by less than a pixel and scrolling
/// stays smooth instead of stuttering between integer pixels.
var offset_px: f32 = 0;
var last_frame_ms: i64 = 0;
var active_win: u32 = 0;
var active_hash: u64 = 0;
var scrolling: bool = false;

/// True while the last offsetFor() call produced an active scroll. The title
/// segment forwards this through its Segment needsRepaint hook, which the
/// bar consults on every draw to keep the title segment out of the
/// snapshot-diff skip: marquee frames repaint moving pixels whose data
/// hasn't changed.
pub fn scrollingActive() bool {
    return scrolling;
}

/// Advances the marquee by the time elapsed since the previous call and
/// returns the SUB-PIXEL pixel offset the text should be drawn at (0 is the
/// title's head at its resting position, which the title segment anchors at
/// the padded text start; grows unbounded only within one wrap cycle). Returns
/// 0 and deactivates when disabled or the text fits its slot.
///
/// Call at most once per rendered frame for the focused cell (the split-view
/// path calls it only for the focused window's segment). `now_ms` is any
/// monotonic millisecond clock.
pub fn offsetFor(
    win: u32,
    title: []const u8,
    text_w: u16,
    avail_w: u16,
    enabled: bool,
    speed_px_s: u16,
    now_ms: i64,
) f32 {
    const hash = std.hash.Wyhash.hash(0, title);
    const continues = scrolling and win == active_win and hash == active_hash;

    scrolling = enabled and text_w > avail_w;
    active_win = win;
    active_hash = hash;
    const dt_ms = now_ms - last_frame_ms;
    last_frame_ms = now_ms;

    if (!scrolling or !continues) {
        // Inactive, or the first frame of a cell (focus change, rename,
        // enable, overflow start): show the head of the title and let
        // motion begin next frame.
        offset_px = 0;
        return 0;
    }

    if (dt_ms > 0)
        offset_px += @as(f32, @floatFromInt(speed_px_s)) * @as(f32, @floatFromInt(dt_ms)) / 1000.0;
    const cycle: f32 = @as(f32, @floatFromInt(text_w)) + @as(f32, @floatFromInt(gap_px));
    offset_px = @mod(offset_px, cycle);
    return offset_px;
}

/// Milliseconds until the next marquee frame, for the bar's poll-timeout
/// minimum: one display period at `hz`, rounded up so wakes never land past
/// a scanout. Returns -1 when inactive (no wakeup contribution), mirroring
/// prompt.blinkPollTimeoutMs.
pub fn pollDeadlineMs(now_ms: i64, enabled: bool, hz: f64) i32 {
    if (!enabled or !scrolling) return -1;
    const period_ms: i64 = @intFromFloat(@ceil(1000.0 / @max(hz, 1.0)));
    const until_next = period_ms - (now_ms - last_frame_ms);
    return @intCast(@max(1, until_next));
}

/// Clears all marquee state. Test hook: the vars are module-global by
/// design (single bar, main thread only).
pub fn resetForTesting() void {
    offset_px = 0;
    last_frame_ms = 0;
    active_win = 0;
    active_hash = 0;
    scrolling = false;
}
