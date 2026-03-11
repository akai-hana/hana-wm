//! Carousel / ticker logic for the title segment.
//!
//! A "carousel" is a pre-rendered XCB pixmap that is wider than the available
//! area.  Every frame, a window into that pixmap is blitted via xcb_copy_area
//! using a time-derived offset, producing a smooth horizontal scroll.
//!
//! V-sync alignment
//! ────────────────
//! The scroll offset is quantised to monitor frame boundaries so that the
//! destination pixels change at most once per frame.  This eliminates the
//! sub-pixel drift that occurs when the bar redraws mid-frame and ensures
//! that every visible update coincides with a v-blank interval.
//!
//!   frame_duration = 1 000 ms / hz
//!   pixels_per_frame = CAROUSEL_PX_PER_S / hz
//!   frame_number = floor(elapsed_ms / frame_duration)
//!   offset = (frame_number × pixels_per_frame)  mod  cycle_w
//!
//! The pixmap is only rebuilt when the window ID changes or the title is
//! invalidated — the hot path is always two xcb_copy_area blits.
//!
//! Leapfrog wrap
//! ─────────────
//! Two logical copies of the text sit `cycle_w` apart in the pixmap.  As
//! `offset` advances 0 → cycle_w the first copy exits left while the second
//! enters right.  At cycle_w the state is identical to 0 → seamless loop.
//!
//!   cycle_w = text_w + CAROUSEL_GAP_PX

const std     = @import("std");
const defs    = @import("defs");
const drawing = @import("drawing");
const hertz   = @import("hertz");

// Constants

/// Horizontal scroll speed in pixels per second (≈ 90 px/s).
/// Divided by the monitor Hz to get pixels-per-frame at detection time.
pub const CAROUSEL_PX_PER_S: f64 = 150.0;

/// Pixel gap between the end of one text copy and the start of the next.
pub const CAROUSEL_GAP_PX: u16 = 60;

// Types

/// Pre-rendered title pixmap for the single-window carousel.
const CarouselCache = struct {
    cp:       drawing.CarouselPixmap,
    window:   ?u32,
    cycle_w:  u16,
    /// Monotonic timestamp (ms) when this pixmap was first built.
    /// The scroll offset is derived from `now - start_ms` so the animation
    /// always restarts from position 0 whenever the carousel is rebuilt after
    /// being hidden (e.g. workspace switch to an empty workspace).
    start_ms: i64,
};

/// Pre-rendered title pixmap for the focused segment in split-view.
const SegCarousel = struct {
    cp:       drawing.CarouselPixmap,
    window:   u32,
    cycle_w:  u16,
    /// Monotonic timestamp (ms) when the focused window gained focus or the
    /// pixmap was first built.  The scroll offset is derived from `now -
    /// start_ms` so the animation always starts from position 0 on focus
    /// change.
    start_ms: i64,
};

// Module state

var g_carousel:            ?CarouselCache = null;
var g_carousel_active:     bool           = false;
var g_seg_carousel:        ?SegCarousel   = null;
var g_seg_carousel_active: bool           = false;

/// Monotonic timestamp (ms) recorded the instant focus changed to a new
/// window — set by notifyFocusChanged and consumed once by blitSegCarousel
/// when it builds the replacement pixmap.
///
/// Keeping this separate from SegCarousel.start_ms means the animation
/// clock starts ticking at focus-click time even if several milliseconds
/// elapse before the next draw cycle actually runs.  A value of 0 means
/// no pending focus change (the draw cycle will call nowMs() as usual).
var g_seg_focus_start_ms: i64 = 0;

/// When false the carousel is disabled globally.  Both single-window and
/// split-view title rendering fall back to ellipsis on overflow.
/// Defaults to true (carousel enabled) to match the previous behaviour.
var g_carousel_enabled: bool = true;

// Public API — feature toggle

/// Enable or disable the carousel globally.
///
/// Disabling immediately frees all carousel pixmaps and deactivates the
/// carousel so the bar rendering loop stops scheduling fast carousel ticks.
pub fn setCarouselEnabled(enabled: bool) void {
    if (!enabled and g_carousel_enabled) {
        // Turning off — release all carousel resources right away so no stale
        // pixmap lingers in the background while the feature is disabled.
        deinitCarousel();
    }
    g_carousel_enabled = enabled;
}

/// Returns true when the carousel feature is enabled.
pub fn isCarouselEnabled() bool {
    return g_carousel_enabled;
}

// Public API — lifecycle

pub fn isCarouselActive() bool {
    return g_carousel_active or g_seg_carousel_active;
}

/// Free all carousel pixmaps.  Call on bar deinit or config reload.
pub fn deinitCarousel() void {
    if (g_carousel)     |*cc| { cc.cp.deinit(); g_carousel     = null; }
    if (g_seg_carousel) |*sc| { sc.cp.deinit(); g_seg_carousel = null; }
    g_carousel_active     = false;
    g_seg_carousel_active = false;
    g_seg_focus_start_ms  = 0;
}

/// Called by the focus system the instant the focused window changes.
///
/// Two things happen here that cannot wait for the next draw cycle:
///
///   1. The stale seg-carousel pixmap is freed immediately.
///      Without this, the bar keeps blitting the old window's title for
///      however many frames elapse before the next full draw runs.
///
///   2. g_seg_focus_start_ms is stamped to the current monotonic clock.
///      blitSegCarousel consumes this timestamp when it builds the new
///      pixmap, anchoring the animation to focus-click time rather than
///      draw time.  Any scheduling latency between the focus event and the
///      draw therefore does not add a visible delay before the scroll starts,
///      nor does it cause the title to appear mid-scroll on the first frame.
///
/// Pass new_window = null when focus is cleared entirely (no focused window).
/// Safe to call at any time; a no-op when the window is unchanged.
pub fn notifyFocusChanged(new_window: ?u32) void {
    if (g_seg_carousel) |*sc| {
        // Only act when the focused window actually changed.  If new_window
        // matches the carousel's window, the user re-focused the same title
        // segment — nothing to reset.
        const same = if (new_window) |nw| nw == sc.window else false;
        if (!same) {
            sc.cp.deinit();
            g_seg_carousel = null;
            // Stamp now so the animation clock starts at the focus event,
            // not at the (potentially later) draw-cycle moment.
            g_seg_focus_start_ms = nowMs();
        }
    } else {
        // No existing seg-carousel to free, but still record the timestamp
        // so the very first carousel built after this focus change starts
        // from position 0 relative to when the user clicked, not draw time.
        g_seg_focus_start_ms = nowMs();
    }
}

// Public API — hot-path tick

/// Fast per-tick single-window carousel redraw.
///
/// Skips Pango, Cairo surface flush, and the full-bar blit.
/// Returns false when no carousel is active (caller must fall back to a full
/// title draw).
///
/// Hot path:
///   fillRect          — one xcb_poly_fill_rectangle
///   blitFrame         — at most two xcb_copy_area
///   flushRect         — one targeted xcb_copy_area, no cairo_surface_flush
pub fn drawCarouselTick(
    dc:      *drawing.DrawContext,
    bg:      u32,
    height:  u16,
    x:       u16,
    avail_w: u16,
) bool {
    const cc = g_carousel orelse return false;
    dc.fillRect(x, 0, avail_w, height, bg);
    const offset = carouselOffset(cc.start_ms, cc.cycle_w);
    cc.cp.blitFrame(dc.drawable, dc.gc, x, avail_w, offset, cc.cycle_w);
    dc.flushRect(x, avail_w);
    return true;
}

// Public API — single-window title rendering

/// Render `text` into `avail_w` pixels starting at (`x`, `y`).
///
/// If the text fits it is drawn normally via Pango/Cairo.
/// If it overflows and the carousel is enabled, a CarouselPixmap is built (or
/// reused) and blitted with a v-synced scroll offset.
/// If it overflows and the carousel is disabled, ellipsis is used as fallback.
///
/// The pixmap is rebuilt only when `window` changes or `title_invalidated` is
/// true, keeping the hot path allocation-free.  On every rebuild `start_ms` is
/// reset to now so the animation restarts from position 0 rather than
/// continuing where a previous carousel left off.
pub fn drawOrScrollTitle(
    dc:                *drawing.DrawContext,
    x:                 u16,
    y:                 u16,
    avail_w:           u16,
    text:              []const u8,
    bg:                u32,
    fg:                u32,
    window:            ?u32,
    title_invalidated: bool,
) !void {
    const text_w = dc.textWidth(text);

    if (text_w <= avail_w) {
        // Text fits — release any stale pixmap and draw normally.
        if (g_carousel) |*cc| { cc.cp.deinit(); g_carousel = null; }
        g_carousel_active = false;
        try dc.drawText(x, y, text, fg);
        return;
    }

    // Text overflows — use ellipsis when the carousel feature is disabled.
    if (!g_carousel_enabled) {
        if (g_carousel) |*cc| { cc.cp.deinit(); g_carousel = null; }
        g_carousel_active = false;
        try dc.drawTextEllipsis(x, y, text, avail_w, fg);
        return;
    }

    g_carousel_active = true;

    const stale = g_carousel == null
        or g_carousel.?.window != window
        or title_invalidated;

    if (stale) {
        if (g_carousel) |*cc| { cc.cp.deinit(); g_carousel = null; }

        var cp = try drawing.CarouselPixmap.init(dc, text_w);
        errdefer cp.deinit();
        try cp.render(dc, text, bg, fg, y);
        const cycle_w: u16 = text_w + CAROUSEL_GAP_PX;
        // Reset start_ms on every rebuild so the scroll always begins from
        // position 0 — the carousel is never "resumed" mid-scroll after it
        // was previously hidden (e.g. after switching back from an empty
        // workspace).
        g_carousel = .{
            .cp       = cp,
            .window   = window,
            .cycle_w  = cycle_w,
            .start_ms = nowMs(),
        };
    }

    const cc     = g_carousel.?;
    const offset = carouselOffset(cc.start_ms, cc.cycle_w);
    cc.cp.blitFrame(dc.drawable, dc.gc, x, avail_w, offset, cc.cycle_w);
}

// Public API — split-view segmented carousel

/// Call at the top of a segmented-titles draw pass.
///
/// If the window that owns the current seg-carousel is no longer in the
/// workspace window list, the pixmap is freed so we don't blit a title that
/// is no longer on-screen.
/// Also resets the `g_seg_carousel_active` flag; the draw loop sets it again
/// if a carousel is actually needed this frame.
pub fn prepareSegCarousel(win_items: []const u32) void {
    if (g_seg_carousel) |sc| {
        var still_present = false;
        for (win_items) |w| {
            if (w == sc.window) { still_present = true; break; }
        }
        if (!still_present) {
            g_seg_carousel.?.cp.deinit();
            g_seg_carousel = null;
        }
    }
    g_seg_carousel_active = false;
}

/// Render the focused window's title for a split-view segment.
///
/// If `text` fits in `avail_w` the caller should draw it normally and pass
/// `was_built = false`.  Returns true when a carousel blit was performed.
///
/// The pixmap is rebuilt only when the focused window changes
/// (sc.window != window), the title is invalidated, or the cycle_w changes
/// (meaning the available area changed).  On focus change start_ms is reset
/// so the scroll animation begins from position 0.
pub fn blitSegCarousel(
    dc:                *drawing.DrawContext,
    text_x:            u16,
    baseline_y:        u16,
    avail_w:           u16,
    text_w:            u16,
    text:              []const u8,
    accent:            u32,
    text_fg:           u32,
    window:            u32,
    title_invalidated: bool,
) !bool {
    if (text_w <= avail_w) return false; // fits — caller draws normally

    g_seg_carousel_active = true;

    const expected_cycle_w: u16 = text_w + CAROUSEL_GAP_PX;

    const stale = if (g_seg_carousel) |sc|
        sc.window != window or
        title_invalidated    or
        sc.cycle_w != expected_cycle_w
    else
        true;

    if (stale) {
        if (g_seg_carousel) |*sc| { sc.cp.deinit(); g_seg_carousel = null; }
        var cp = try drawing.CarouselPixmap.init(dc, text_w);
        errdefer cp.deinit();
        try cp.render(dc, text, accent, text_fg, baseline_y);
        // Use the focus-event timestamp when available so the animation
        // clock is anchored to when the user clicked, not when the draw
        // cycle ran.  Consume it (reset to 0) so subsequent invalidations
        // (e.g. title text changes) fall back to the normal nowMs() path.
        const start: i64 = if (g_seg_focus_start_ms != 0) blk: {
            const t = g_seg_focus_start_ms;
            g_seg_focus_start_ms = 0;
            break :blk t;
        } else nowMs();
        g_seg_carousel = .{
            .cp       = cp,
            .window   = window,
            .cycle_w  = expected_cycle_w,
            .start_ms = start,
        };
    }

    const sc     = g_seg_carousel.?;
    const offset = carouselOffset(sc.start_ms, sc.cycle_w);
    sc.cp.blitFrame(dc.drawable, dc.gc, text_x, avail_w, offset, sc.cycle_w);
    return true;
}

// Internal helpers

fn nowMs() i64 {
    const ts = std.posix.clock_gettime(.MONOTONIC) catch return 0;
    return ts.sec * 1000 + @divTrunc(ts.nsec, 1_000_000);
}

/// Compute the v-synced scroll offset for a carousel with the given cycle width.
///
/// The offset is quantised to monitor frame boundaries:
///
///   frame_duration_ms = 1000.0 / hz
///   px_per_frame      = CAROUSEL_PX_PER_S / hz
///   frame_num         = floor(elapsed_ms / frame_duration_ms)
///   offset            = (frame_num × px_per_frame) mod cycle_w
///
/// Quantising to frames means the blit source changes at most once per
/// display refresh cycle, aligning visual updates with v-blank and preventing
/// the partial-frame tearing that arises when the bar redraws at an arbitrary
/// sub-frame moment.
///
/// `start_ms` is the monotonic timestamp at which this carousel was last
/// built.  All carousels (single-window and split-view) derive their offset
/// from `now - start_ms`, so the animation always begins at position 0 when
/// first shown and never "resumes" a previous scroll position after the
/// carousel was destroyed and recreated.
fn carouselOffset(start_ms: i64, cycle_w: u16) u16 {
    const hz           = hertz.getCached();
    const frame_ms     = 1000.0 / hz;
    const px_per_frame = CAROUSEL_PX_PER_S / hz;

    const elapsed_ms = @as(f64, @floatFromInt(nowMs() - start_ms));
    const frame_num  = @floor(elapsed_ms / frame_ms);
    const raw_px     = frame_num * px_per_frame;
    const cycle_f    = @as(f64, @floatFromInt(cycle_w));
    const offset_f   = @mod(raw_px, cycle_f);

    const offset: u64 = @intFromFloat(offset_f);
    return @intCast(@min(offset, @as(u64, cycle_w - 1)));
}
