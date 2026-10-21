//! Threadless title marquee ("carousel").
//!
//! When the focused window's title is wider than its bar slot, it scrolls
//! continuously: copies of the text slide leftward through the cell,
//! separated by a fixed gap, wrapping seamlessly. Titles that fit are drawn
//! statically and this module stays inert.
//!
//! Design (mirrors clock.zig): all state is plain main-thread vars; no
//! thread, no locks. Motion is elapsed-time-based (dt * speed), so
//! redundant renders within one tick are harmless. Frames are requested
//! through pollDeadlineMs(). The math is pure; identity is tracked by
//! (window id, title hash) so a rename restarts from the beginning.

const std = @import("std");
const title_mod = @import("title");

/// This module's title-scroller addon binding. Membership in
/// `title_subs.addons` comes from file presence alone, so dropping this
/// file degrades the title to static (ellipsis) rendering with zero core
/// edits.
pub const addon: title_mod.Scroller = .{
    .offsetFor = offsetFor,
    .pivot = pivot,
    .pollDeadlineMs = pollDeadlineMs,
};

/// How much a scrolling cell's slot must GROW before that cell is allowed
/// to stop scrolling. `text_w > avail_w` is a knife-edge re-run every
/// frame, and the centered title's reserved width wobbles by a few pixels
/// whenever a neighbour gains or loses a digit. Continuation is keyed on
/// `scrolling`, so each of those frames would restart the marquee at the
/// head without hysteresis. One font character absorbs their jitter while
/// still stopping on a real resize.
const scroll_exit_slack_px: u16 = 8;

/// Owner state for the marquee (P2-58): motion clock plus identity. The
/// motion clock has an ANCHOR and the position is a pure function of the
/// frame time, so frame-rate independence is true by construction: any
/// number of draws at any times agree on the position.
///
/// `shown_off_px` is NOT an accumulator: it remembers the last offset
/// actually handed out, for the `pivot` rebase, which must continue from
/// the position on screen rather than one recomputed with a moved clock.
///
/// `last_drawn_ms` is when a frame was last handed out, for `pollDeadlineMs`
/// to pace the bar's poll timeout. Deliberately NOT derived from
/// `anchor_ms` + offset: after a `pivot` that sum no longer names the last
/// draw.
///
/// `scrolling` is whether the tracked cell is overflowing RIGHT NOW. The
/// scroller is GIVEN its `enabled` policy by draw and never goes looking
/// for it: `scrolling` is assigned `overflows`, which conjoins `enabled`,
/// so `pollDeadlineMs` needs no separate policy channel.
///
/// `pivot_next_frame` is set when the bar re-appears after a hide, or when
/// config changed: consumed by the next offsetFor so that frame rebases
/// its elapsed-time clock at `now` instead of integrating the whole gap.
const CarouselState = struct {    anchor_ms: i64 = 0,
    shown_off_px: f32 = 0,
    last_drawn_ms: i64 = 0,
    active_win: u32 = 0,
    active_hash: u64 = 0,
    scrolling: bool = false,
    pivot_next_frame: bool = false,
};
var g: CarouselState = .{};

/// Advances the marquee by the time elapsed since the previous call and
/// returns the SUB-PIXEL offset the text should be drawn at (0 is the
/// title's head at its resting position). Returns 0 and deactivates when
/// disabled or the text fits its slot.
pub fn offsetFor(
    win: u32,
    title: []const u8,
    text_w: u16,
    avail_w: u16,
    enabled: bool,
    speed_px_s: u16,
    /// Gap between repeating copies, in px: added to the text width it is
    /// the wrap period. Config knob `carousel_gap_px`.
    gap_px: u16,
    now_ms: i64,
) title_mod.Scroll {
    // Both of these are consumed on EVERY call, so they are stated once
    // here rather than at each of the three exits below. `pivot_next_frame`
    // needs a local because the pivot branch below clears it.
    g.last_drawn_ms = now_ms;
    const pivoting = g.pivot_next_frame;
    g.pivot_next_frame = false;

    const hash = std.hash.Wyhash.hash(0, title);
    const continues = g.scrolling and win == g.active_win and hash == g.active_hash;

    // Hysteresis, not a plain overflow test: a cell already scrolling stays
    // scrolling until its slot has grown to fit the title WITH room to
    // spare. Only a non-scrolling cell has to beat `text_w` outright.
    const slack: u16 = if (continues) scroll_exit_slack_px else 0;
    const overflows = enabled and text_w > avail_w -| slack;
    g.scrolling = overflows;
    g.active_win = win;
    g.active_hash = hash;

    // `cycle` is text_w + gap, so it is zero only if both are; `@mod` by
    // zero is undefined rather than an error, so this is guarded.
    const cycle: f32 = @as(f32, @floatFromInt(text_w)) + @as(f32, gap_px);

    // One transition, two reasons: the text fits (or the feature is off),
    // so the segment draws statically; or this is the FIRST frame of an
    // overflowing cell. Either way the clock is re-anchored at `now` and
    // the offset is the head, so motion -- or its retirement -- begins on
    // the NEXT frame.
    //
    // The starting-over case reports `active = true`, not false: `false`
    // sends the renderer through its static ellipsis path, so arriving at
    // an overflowing workspace from a static-title one paints a frame of
    // truncated "..." before the marquee appears.
    if (!overflows or !continues) {
        g.anchor_ms = now_ms;
        g.shown_off_px = 0;
        return .{ .off = 0, .cycle = cycle, .active = overflows };
    }

    const speed: f32 = @floatFromInt(speed_px_s);

    if (pivoting) {
        // The bar was hidden between frames, or config changed. The new
        // speed and width change what a cycle even is, so evaluating
        // `mod((now - anchor) * speed, cycle)` now would teleport the
        // marquee to an arbitrary point of the NEW cycle. Re-anchor so the
        // position at `now` is the one still on screen.
        //
        // Speed 0 has no inverse, and at 0 the offset is 0 regardless.
        g.anchor_ms = if (speed > 0)
            now_ms - @as(i64, @intFromFloat(@round(g.shown_off_px * 1000.0 / speed)))
        else
            now_ms;
    }

    const off: f32 = if (cycle > 0)
        @mod((@as(f32, @floatFromInt(now_ms - g.anchor_ms))) * speed / 1000.0, cycle)
    else
        0;
    g.shown_off_px = off;
    return .{ .off = off, .cycle = cycle, .active = true };
}

/// Milliseconds until the next marquee frame, for the bar's poll-timeout
/// minimum: one display period at `hz`, rounded up so wakes never land
/// past a scanout. Returns -1 when inactive (no wakeup contribution),
/// mirroring prompt.blinkPollTimeoutMs. `scrolling` alone answers "is
/// there motion to pace" because it is assigned `overflows`, which
/// conjoins `enabled`.
pub fn pollDeadlineMs(now_ms: i64, hz: f64) i32 {
    if (!g.scrolling) return -1;
    const period_ms: i64 = @intFromFloat(@ceil(1000.0 / @max(hz, 1.0)));
    const until_next = period_ms - (now_ms - g.last_drawn_ms);
    return @intCast(@max(1, until_next));
}

/// Rebase the elapsed-time clock at the next `offsetFor` call, so motion
/// continues from the last shown offset instead of integrating the whole
/// gap that passed while nothing was drawn. Two callers, one operation:
/// the bar showing again after a hide, and a config reload.
pub fn pivot() void {
    g.pivot_next_frame = true;
}

/// Clears all marquee state. Test hook: the state is a module-global owner
/// struct by design (single bar, main thread only).
pub fn resetForTesting() void {
    g = .{};
}
