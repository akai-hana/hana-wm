//! title-addon.zig — drop-in template for a hana title scroller
//! addon.
//!
//! COPY ME: the fastest way to start a new title decoration is
//!
//!     cp dev/plugin-template/title-addon.zig src/bar/modules/title/myscroller.zig
//!
//! then edit the TODO markers. Nothing else needs to change:
//! build.zig's sub-registry generation (`title_subs`) picks the file
//! up from FILE PRESENCE plus the `pub const addon` self-declaration.
//!
//! AT MOST ONE scroller addon may exist: the title core guards
//! `title_subs.addons.len <= 1` at comptime (a second `Scroller`
//! was silently dropped while the registry kept looking like a
//! registry, so the seam is a SINGLETON slot now). Shipping this
//! template beside the carousel addon is a compile error by design
//! — copy it in REPLACING the carousel, not beside it.
//!
//! The scroller contract is one call per frame (`offsetFor` returns
//! the whole scroll decoration — offset, wrap period and the
//! live-motion bit — so the three can never drift apart across the
//! seam), plus the pivot (reset your motion anchor: overlay close,
//! bar shown, reload) and the poll deadline (the marquee's next
//! frame request, contributed through the bar's poll-timeout
//! minimum). Motion should be elapsed-time-based — a pure function
//! of the frame time against an anchor — so a duplicated draw is a
//! no-op and a late frame shows where the decoration actually is;
//! the carousel addon is the reference implementation.
//!
//! Titles that fit their slot are drawn statically and the scroller
//! stays inert (`active = false`); `enabled` is the config's
//! scroll-enable bit, so an addon can decline to scroll without
//! unregistering.
//!
//! `check-plugin-template` compiles this file against the real title
//! module, so contract drift self-fails on `zig build check`.

const title = @import("title");

/// The whole scroll decoration for one frame. `off` is the
/// sub-pixel x offset of the title head (0 = resting position);
/// `cycle` is the wrap period in px (the scrolled text run is
/// [x0, x0 + cycle)); `active` is true while this frame produced
/// live motion — the title's needsRepaint hook forwards exactly
/// this bit, since marquee frames repaint moving pixels whose data
/// has not changed.
fn offsetFor(
    win: u32,
    text: []const u8,
    text_w: u16,
    avail_w: u16,
    enabled: bool,
    speed_px_s: u16,
    now_ms: i64,
) title.Scroll {
    // TODO: your scroll math. The resting answer (a title that
    // fits, scrolling disabled, or no motion this frame) is
    // off = 0, cycle = 0, active = false.
    _ = win;
    _ = text;
    _ = text_w;
    _ = avail_w;
    _ = enabled;
    _ = speed_px_s;
    _ = now_ms;
    return .{ .off = 0, .cycle = 0, .active = false };
}

/// Reset the motion anchor. Called on overlay close, bar shown and
/// reload — the points where the frame-time base the offset is
/// computed against is no longer meaningful.
fn pivot() void {
    // TODO: reset your anchor (e.g. re-read the clock).
}

/// The next frame deadline in ms, or -1 to defer to the bar's own
/// cadence. `hz` is the title's configured scroll rate; a marquee
/// requests its next frame here so redundant renders within one
/// tick are harmless and event-driven redraws always show the
/// current position.
fn pollDeadlineMs(now_ms: i64, hz: f64) i32 {
    // TODO: now_ms + the interval your speed implies, as i32 ms.
    _ = now_ms;
    _ = hz;
    return -1;
}

/// This module's title-scroller addon binding. Membership in
/// `title_subs.addons` comes from file presence alone (build.zig's
/// sub-registry generation), so dropping this file degrades the
/// title to its built-in static (ellipsis) rendering with zero
/// core edits — and, per the singleton guard above, at most one
/// addon of this family may be present at a time.
pub const addon: title.Scroller = .{
    .offsetFor = offsetFor,
    .pivot = pivot,
    .pollDeadlineMs = pollDeadlineMs,
};
