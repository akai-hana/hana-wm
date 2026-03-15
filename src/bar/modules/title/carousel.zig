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

/// Horizontal scroll speed in pixels per second (≈ 150 px/s).
/// Divided by the monitor Hz to get pixels-per-frame at detection time.
pub const CAROUSEL_PX_PER_S: f64 = 150.0;

/// Pixel gap between the end of one text copy and the start of the next.
pub const CAROUSEL_GAP_PX: u16 = 60;

// Types

/// A pre-rendered XCB pixmap for one carousel instance — used for both the
/// single-window path and the segmented (split-view) path.  Sharing one type
/// removes the duplicate cp/window/cycle_w/start_ms fields that previously
/// existed in the separate CarouselCache and SegCarousel structs.
///
/// Fields in the "single-window only" section default to 0 and are ignored
/// by the segmented path.
const CarouselEntry = struct {
    cp:       drawing.CarouselPixmap,
    /// Window ID this pixmap was rendered for.  null is accepted by the
    /// single-window path when no window is focused; always non-null for
    /// the segmented path.
    window:   ?u32,
    cycle_w:  u16,
    start_ms: i64,

    // ── Single-window path only ──────────────────────────────────────────
    // The segmented path never reads or writes these; they default to 0.

    /// Background colour baked into the pixmap at render() time.  Used to
    /// detect accent changes (e.g. minimize/unminimize) so the pixmap can
    /// be rebuilt while preserving start_ms for a seamless scroll.
    last_bg:      u32 = 0,
    /// Inset clip coords stored so drawCarouselTick uses the same clip_x
    /// as drawOrScrollTitle.  Both paths compute draw_x = clip_x - offset,
    /// so matching clip_x prevents a positional stutter when start_ms is
    /// preserved across a bg-only rebuild.
    text_x:       u16 = 0,
    text_avail_w: u16 = 0,
};

// Module state

/// Active single-window carousel.  Non-null iff the title segment is currently
/// scrolling a single-window title.
var g_carousel: ?CarouselEntry = null;

/// Active segmented carousel for the focused window in split-view.  Non-null
/// iff a split-view title is being scrolled.
var g_seg_carousel: ?CarouselEntry = null;

/// Monotonic timestamp (ms) recorded the instant focus changed to a new
/// window — set by notifyFocusChanged and consumed once by blitSegCarousel
/// when it builds the replacement pixmap.
///
/// Keeping this separate from CarouselEntry.start_ms means the animation
/// clock starts ticking at focus-click time even if several milliseconds
/// elapse before the next draw cycle actually runs.  A value of 0 means
/// no pending focus change (the draw cycle will call nowMs() as usual).
var g_seg_focus_start_ms: i64 = 0;

/// When false the carousel is disabled globally.  Both single-window and
/// split-view title rendering fall back to ellipsis on overflow.
var g_carousel_enabled: bool = true;

// Public API — feature toggle

/// Enable or disable the carousel globally.
///
/// Disabling immediately frees all carousel pixmaps so no stale pixmap
/// lingers while the feature is off.
pub fn setCarouselEnabled(enabled: bool) void {
    if (!enabled and g_carousel_enabled) deinitCarousel();
    g_carousel_enabled = enabled;
}

/// Returns true when the carousel feature is currently enabled.
pub fn isCarouselEnabled() bool {
    return g_carousel_enabled;
}

// Public API — lifecycle

/// True when either a single-window or segmented carousel pixmap is live.
/// The bar thread polls this to decide whether to schedule carousel ticks.
pub fn isCarouselActive() bool {
    return g_carousel != null or g_seg_carousel != null;
}

/// Free all carousel pixmaps.  Call on bar deinit or config reload.
pub fn deinitCarousel() void {
    if (g_carousel)     |*e| { e.cp.deinit(); g_carousel     = null; }
    if (g_seg_carousel) |*e| { e.cp.deinit(); g_seg_carousel = null; }
    g_seg_focus_start_ms = 0;
}

/// Called by the focus system the instant the focused window changes.
///
/// Two things happen here that cannot wait for the next draw cycle:
///
///   1. g_seg_focus_start_ms is stamped to the current monotonic clock so the
///      animation is anchored to focus-click time, not draw time.
///
///   2. The stale seg-carousel pixmap is freed immediately (when the window
///      actually changed).  Without this the bar keeps blitting the old
///      window's title for however many frames elapse before the next full
///      draw runs.
///
/// Pass new_window = null when focus is cleared entirely.
/// Safe to call at any time; a no-op when the window is unchanged.
pub fn notifyFocusChanged(new_window: ?u32) void {
    // Always stamp the focus timestamp first — blitSegCarousel consumes it
    // when it builds the replacement pixmap so the animation is anchored to
    // when the user clicked, not when the draw cycle happened to run.
    g_seg_focus_start_ms = nowMs();

    if (g_seg_carousel) |*e| {
        const same = if (new_window) |nw| e.window == @as(?u32, nw) else false;
        if (!same) {
            e.cp.deinit();
            g_seg_carousel = null;
        }
    }
}

// Public API — hot-path tick

/// Fast per-tick single-window carousel redraw.
///
/// Skips Pango, Cairo surface flush, and the full-bar blit.
/// Returns false when no single-window carousel is live (caller falls back
/// to a full title draw).
///
/// Hot path:
///   fillRect   — one xcb_poly_fill_rectangle  (background + gap fill)
///   blitFrame  — at most two xcb_copy_area     (two leapfrog text copies)
///   flushRect  — one targeted xcb_copy_area    (no cairo_surface_flush)
pub fn drawCarouselTick(
    dc:      *drawing.DrawContext,
    bg:      u32,
    height:  u16,
    x:       u16,
    avail_w: u16,
) bool {
    const e = g_carousel orelse return false;
    // Fill the full segment area (background + the gap between text copies).
    dc.fillRect(x, 0, avail_w, height, bg);
    const offset = carouselOffset(e.start_ms, e.cycle_w);
    // Use the *inset* text coords stored in the entry so this path and
    // drawOrScrollTitle both compute draw_x = clip_x - offset with the same
    // clip_x, keeping the text position identical between the two paths.
    e.cp.blitFrame(dc.drawable, dc.gc, e.text_x, e.text_avail_w, offset, e.cycle_w);
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
        if (g_carousel) |*e| { e.cp.deinit(); g_carousel = null; }
        try dc.drawText(x, y, text, fg);
        return;
    }

    // Text overflows — use ellipsis when the carousel feature is disabled.
    if (!g_carousel_enabled) {
        if (g_carousel) |*e| { e.cp.deinit(); g_carousel = null; }
        try dc.drawTextEllipsis(x, y, text, avail_w, fg);
        return;
    }

    // A bg-only change (accent colour changed by minimize/unminimize) requires
    // a pixmap rebuild so the baked-in background pixels match the new accent.
    // We preserve start_ms in this case so the scroll is seamless — the user
    // sees only a colour change, not a jump back to position 0.
    // A full stale (window or title changed) always resets to position 0.
    const bg_changed = g_carousel != null and g_carousel.?.last_bg != bg;
    const full_stale = g_carousel == null
        or g_carousel.?.window != window
        or title_invalidated;

    if (full_stale or bg_changed) {
        const preserved_start_ms: i64 =
            if (!full_stale and bg_changed) g_carousel.?.start_ms else nowMs();

        if (g_carousel) |*e| { e.cp.deinit(); g_carousel = null; }

        var cp = try drawing.CarouselPixmap.init(dc, text_w);
        errdefer cp.deinit();
        try cp.render(dc, text, bg, fg, y);
        g_carousel = .{
            .cp           = cp,
            .window       = window,
            .cycle_w      = text_w + CAROUSEL_GAP_PX,
            .start_ms     = preserved_start_ms,
            .last_bg      = bg,
            .text_x       = x,
            .text_avail_w = avail_w,
        };
    }

    const e      = g_carousel.?;
    const offset = carouselOffset(e.start_ms, e.cycle_w);
    e.cp.blitFrame(dc.drawable, dc.gc, x, avail_w, offset, e.cycle_w);
}

// Public API — split-view segmented carousel

/// Call at the top of a segmented-titles draw pass.
///
/// The single-window carousel (g_carousel) is always freed here because the
/// single-window and segmented paths are mutually exclusive: entering a
/// segmented pass means there are >=2 windows, so g_carousel is stale by
/// definition.  Leaving it alive would cause the carousel timer to blit the
/// old single-window pixmap over the correct split render every frame.
///
/// Also frees the seg-carousel when its window is no longer in the workspace
/// window list, so we never blit a title for a window that has been closed.
pub fn prepareSegCarousel(win_items: []const u32) void {
    if (g_carousel) |*e| { e.cp.deinit(); g_carousel = null; }

    if (g_seg_carousel) |e| {
        var still_present = false;
        for (win_items) |w| {
            if (@as(?u32, w) == e.window) { still_present = true; break; }
        }
        if (!still_present) {
            g_seg_carousel.?.cp.deinit();
            g_seg_carousel = null;
        }
    }
}

/// Render the focused window's title for a split-view segment.
///
/// Returns true when a carousel blit was performed; false when the text fits
/// and the caller should draw it normally.
///
/// The pixmap is rebuilt only when the focused window changes, the title is
/// invalidated, or the cycle_w changes (available area changed).  On focus
/// change start_ms is reset so the scroll animation begins from position 0.
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

    const expected_cycle_w: u16 = text_w + CAROUSEL_GAP_PX;

    const stale = if (g_seg_carousel) |e|
        e.window != @as(?u32, window) or
        title_invalidated              or
        e.cycle_w != expected_cycle_w
    else
        true;

    if (stale) {
        if (g_seg_carousel) |*e| { e.cp.deinit(); g_seg_carousel = null; }
        var cp = try drawing.CarouselPixmap.init(dc, text_w);
        errdefer cp.deinit();
        try cp.render(dc, text, accent, text_fg, baseline_y);
        // Use the focus-event timestamp when available so the animation is
        // anchored to when the user clicked, not when the draw cycle ran.
        // Consume it (reset to 0) so subsequent invalidations (e.g. title
        // text changes) fall back to the normal nowMs() path.
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

    const e      = g_seg_carousel.?;
    const offset = carouselOffset(e.start_ms, e.cycle_w);
    e.cp.blitFrame(dc.drawable, dc.gc, text_x, avail_w, offset, e.cycle_w);
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
/// Quantising to frames aligns visual updates with v-blank and prevents the
/// partial-frame tearing that arises when the bar redraws at an arbitrary
/// sub-frame moment.
///
/// `start_ms` is the monotonic timestamp at which this entry was last built.
/// All carousels derive their offset from `now - start_ms`, so the animation
/// always begins at position 0 when first shown.
fn carouselOffset(start_ms: i64, cycle_w: u16) u16 {
    const hz           = hertz.getCached();
    const frame_ms     = 1000.0 / hz;
    const px_per_frame = CAROUSEL_PX_PER_S / hz;

    const elapsed_ms = @as(f64, @floatFromInt(nowMs() - start_ms));
    const frame_num  = @floor(elapsed_ms / frame_ms);
    const raw_px     = frame_num * px_per_frame;
    const cycle_f    = @as(f64, @floatFromInt(cycle_w));

    // @mod guarantees 0 <= result < cycle_f, so the result always fits in u16.
    return @intFromFloat(@mod(raw_px, cycle_f));
}
