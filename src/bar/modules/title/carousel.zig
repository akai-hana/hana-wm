
//! Carousel title extension.
//! Extends title by adding a smooth-scroll carousel effect for titles that
//! don't fully fit the segment.
//!
//! Design
//! ──────
//! A wide XCB pixmap is pre-rendered once per title change:
//!
//!   [ bg * left_pad | text A | bg * gap | text B ]
//!    ←── left_pad ──→←text_w→←── gap ──→←text_w→
//!
//! where left_pad = text_x − seg_x (the segment's left inset).
//! cycle_w = text_w + gap.  At scroll offset O the hot-path blit is a
//! single xcb_copy_area of seg_w pixels from pixmap position O into the
//! offscreen pixmap, then a flushRect.  Two XCB calls total per tick —
//! no fill, no clipping arithmetic, no second copy.
//!
//! Offset formula: O = (elapsed_ms × speed / 1000) mod cycle_w.
//! Continuous linear interpolation — no frame-quantisation.  Smooth at
//! any wakeup rate.
//!
//! Invalidation is deliberately unified: any change (window, title, bg,
//! or geometry) rebuilds the pixmap and resets start_ms to now.  The
//! previous code's three-way full_stale / bg_changed / geom_changed split
//! was a source of subtle bugs and is removed.

const std = @import("std");

const core    = @import("core");
    const xcb = core.xcb;
const utils   = @import("utils");

const scale   = @import("scale");
const drawing = @import("drawing");

// ── Public constants ────────────────────────────────────────────────────────

/// Default scroll speed in pixels per second.
pub const default_scroll_speed: f64 = 125.0;

/// Pixel gap between the end of text copy A and the start of copy B in the
/// pre-rendered pixmap.
pub const carousel_gap_px: u16 = 60;

// ── Public geometry type ────────────────────────────────────────────────────

/// Segment geometry passed to carousel draw functions.
///
///   seg_x  / seg_w  — full segment bounds (clip + fill region).
///   text_x / avail_w — inset text area used for the overflow check and for
///                      static / ellipsis fallback drawing.
pub const SegmentGeometry = struct {
    seg_x:   u16,
    seg_w:   u16,
    text_x:  u16,
    avail_w: u16,
};

// ── Internal types ──────────────────────────────────────────────────────────

/// All state for one live carousel (single-window or segmented).
const CarouselEntry = struct {
    cp:       drawing.CarouselPixmap,
    cycle_w:  u16,   // text_w + carousel_gap_px
    start_ms: i64,   // monotonicMs() at the moment the animation started
    last_bg:  u32,   // accent colour baked into cp; used by drawCarouselTick
                     //   to detect a colour change before the next full draw
    window:   ?u32,  // window the pixmap was built for (null = no window)
    geom:     SegmentGeometry,
};

/// Runtime-configurable scroll parameters.
const ScrollConfig = struct {
    speed:         f64 = default_scroll_speed,
    /// When > 0, overrides the monitor's detected refresh rate for the wake
    /// interval. Set via `carousel_refresh_rate` in the config file.
    rate_override: f64 = 0.0,
};

/// All state exclusively owned by the render thread.
/// `is_enabled` is also written by the main thread (setCarouselEnabled) and
/// is therefore an atomic; all other fields are render-thread-only.
const RenderState = struct {
    single:     ?CarouselEntry                    = null,
    seg:        ?CarouselEntry                    = null,
    is_enabled: std.atomic.Value(bool) = std.atomic.Value(bool).init(true),
};

/// Cross-thread signal: main thread sets is_invalidated when focus changes;
/// render thread consumes it on the next seg-carousel blit.
///
/// `seg_window` is the window the render thread last built the seg carousel
/// for (0 = none).  The render thread writes it atomically after updating
/// render.seg so the main thread never has to read the non-atomic render.seg.
const FocusSignal = struct {
    is_invalidated: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    seg_window:     std.atomic.Value(u32)  = std.atomic.Value(u32).init(0),
};

var scroll_config: ScrollConfig = .{};
var render:        RenderState  = .{};
var focus_signal:  FocusSignal  = .{};

// ── Public API — feature toggles and scroll config ──────────────────────────

/// Enable or disable the carousel globally.
/// Disabling immediately frees all carousel pixmaps.
pub fn setCarouselEnabled(enabled: bool) void {
    if (!enabled and render.is_enabled.load(.acquire)) deinitCarousel();
    render.is_enabled.store(enabled, .release);
}

/// Returns true when the carousel feature is currently enabled.
pub fn isCarouselEnabled() bool { return render.is_enabled.load(.acquire); }

/// Set the scroll speed in pixels per second.
/// Values ≤ 0 are clamped to default_scroll_speed.
pub fn setScrollSpeed(px_per_s: f64) void {
    scroll_config.speed = if (px_per_s > 0.0) px_per_s else default_scroll_speed;
}

/// Override the refresh rate used for the wake interval.
/// Pass 0 (the default) to use the monitor's auto-detected rate.
pub fn setRefreshRateOverride(hz: f64) void {
    scroll_config.rate_override = if (hz > 0.0) hz else 0.0;
}

/// Returns the bar thread's carousel wake interval in nanoseconds.
///
/// Priority:
///   1. User-configured `carousel_refresh_rate` (rate_override > 0).
///   2. Monitor refresh rate detected via RandR at startup.
///   3. 60 Hz fallback when detection has not yet run.
///
/// Called once per bar-thread sleep cycle; the division is cheap relative
/// to the timedWait syscall that follows.
pub fn wakeIntervalNs() u64 {
    const hz: f64 = if (scroll_config.rate_override > 0.0)
        scroll_config.rate_override
    else
        scale.getDetectedRateHz();
    return @intFromFloat(1_000_000_000.0 / hz);
}

// ── Public API — lifecycle ───────────────────────────────────────────────────

/// True when either carousel pixmap is live.
pub fn isCarouselActive() bool {
    return render.single != null or render.seg != null;
}

/// Returns the window ID the segmented carousel was built for, or null.
/// Render thread only — reading render.seg here is safe.
pub fn getSegmentedCarouselWindow() ?u32 {
    return if (render.seg) |e| e.window else null;
}

/// Free all carousel pixmaps and reset cross-thread signals.
/// Call on bar deinit or config reload.  Render thread only.
pub fn deinitCarousel() void {
    deinitSingleCarousel();
    deinitSegmentedCarousel();
    focus_signal.is_invalidated.store(false, .monotonic);
}

/// Free the single-window carousel pixmap.  Render thread only.
pub fn deinitSingleCarousel() void {
    if (render.single) |*e| { e.cp.deinit(); render.single = null; }
}

/// Free the segmented carousel pixmap.  Render thread only.
pub fn deinitSegmentedCarousel() void {
    if (render.seg) |*e| { e.cp.deinit(); render.seg = null; }
    focus_signal.seg_window.store(0, .release);
}

// ── Public API — focus notification (main thread only) ───────────────────────

/// Called by the focus system when the focused window changes.
/// MUST be called from the main thread only.
/// Sets focus_signal.is_invalidated so the render thread rebuilds the
/// seg-carousel on the next blit.
pub fn notifyFocusChanged(new_window: ?u32) void {
    const tracked = focus_signal.seg_window.load(.acquire);
    const changed = if (new_window) |nw| nw != tracked else tracked != 0;
    if (!changed) return;
    focus_signal.is_invalidated.store(true, .release);
}

// ── Public API — hot-path carousel tick ─────────────────────────────────────

/// Fast per-tick single-window carousel blit.
///
/// Returns false when:
///   • no single carousel is live,
///   • the segment position/size changed (bar resize — caller triggers a full draw), or
///   • the accent colour changed (minimize/unminimize — caller triggers a full draw
///     which rebuilds the pixmap with the new bg baked in).
///
/// Hot path: one xcb_copy_area (wide pixmap → offscreen) + flushRect.
/// No fill, no Cairo, no Pango.
pub fn drawCarouselTick(
    dc:    *drawing.DrawContext,
    bg:    u32,
    seg_x: u16,
    seg_w: u16,
) bool {
    const e = render.single orelse return false;
    if (seg_x != e.geom.seg_x or seg_w != e.geom.seg_w or bg != e.last_bg)
        return false;

    const off = carouselOffset(e.start_ms, e.cycle_w, utils.monotonicMs());
    e.cp.blitFrame(dc.offscreen_pixmap, dc.gc, seg_x, off, seg_w);
    dc.flushRect(seg_x, seg_w);
    return true;
}

/// Parameterless segmented carousel tick for use from the bar's drawTitleOnly path.
///
/// Reads seg_x, seg_w, and last_bg directly from the live render.seg entry so
/// the caller does not need to cache or re-derive the focused segment's bounds.
/// Returns false when no segmented carousel is live or the accent colour changed
/// (indicating a minimize/unminimize that requires a full rebuild).
pub fn drawSegCarouselTickAuto(dc: *drawing.DrawContext, accent: u32) bool {
    const e = render.seg orelse return false;
    if (accent != e.last_bg) return false;
    // If a focus change is pending, bail out so the caller falls through to
    // drawCached → drawSegmentedTitles, which redraws ALL segments with the
    // correct accent colours (old focused → unfocused, new focused → focused).
    if (focus_signal.is_invalidated.load(.acquire)) return false;
    const off = carouselOffset(e.start_ms, e.cycle_w, utils.monotonicMs());
    e.cp.blitFrame(dc.offscreen_pixmap, dc.gc, e.geom.seg_x, off, e.geom.seg_w);
    dc.flushRect(e.geom.seg_x, e.geom.seg_w);
    return true;
}

// ── Public API — single-window title rendering ───────────────────────────────

/// Render `text` into the segment described by `geom`.
///
/// • If text fits within geom.avail_w: draw statically, free any carousel.
/// • If text overflows and carousel is enabled: build (or reuse) the wide
///   pixmap and blit one frame.
/// • If text overflows and carousel is disabled: draw with ellipsis.
///
/// Pixmap rebuild triggers (unified — any change resets start_ms to now):
///   • No pixmap live
///   • Window ID changed
///   • Title text changed (title_invalidated)
///   • Accent colour changed
///   • Text width changed (cycle_w mismatch)
///   • Segment geometry changed (position or size)
pub fn drawScrollingTitle(
    dc:                *drawing.DrawContext,
    y:                 u16,
    geom:              SegmentGeometry,
    text:              []const u8,
    bg:                u32,
    fg:                u32,
    window:            ?u32,
    title_invalidated: bool,
) !void {
    const text_w = dc.measureTextWidth(text);

    if (text_w <= geom.avail_w) {
        deinitSingleCarousel();
        try dc.drawText(geom.text_x, y, text, fg);
        return;
    }

    if (!render.is_enabled.load(.acquire)) {
        deinitSingleCarousel();
        try dc.drawTextEllipsis(geom.text_x, y, text, geom.avail_w, fg);
        return;
    }

    const cycle_w: u16 = text_w + carousel_gap_px;

    const stale = render.single == null
        or render.single.?.window  != window
        or render.single.?.last_bg != bg
        or title_invalidated
        or render.single.?.cycle_w         != cycle_w
        or render.single.?.geom.seg_x      != geom.seg_x
        or render.single.?.geom.seg_w      != geom.seg_w
        or render.single.?.geom.avail_w    != geom.avail_w;

    if (stale) {
        deinitSingleCarousel();

        const left_pad: u16 = if (geom.text_x > geom.seg_x)
            geom.text_x - geom.seg_x else 0;
        const pixmap_w: u16 = @max(
            left_pad + cycle_w + text_w,   // room for text copy B
            cycle_w  + geom.seg_w,          // room for blit at max offset
        );

        var cp = try drawing.CarouselPixmap.init(dc, pixmap_w);
        errdefer cp.deinit();
        try cp.render(dc, text, bg, fg, y, left_pad, cycle_w);

        render.single = .{
            .cp       = cp,
            .cycle_w  = cycle_w,
            .start_ms = utils.monotonicMs(),
            .last_bg  = bg,
            .window   = window,
            .geom     = geom,
        };
    }

    const e   = render.single.?;
    const off = carouselOffset(e.start_ms, e.cycle_w, utils.monotonicMs());
    e.cp.blitFrame(dc.offscreen_pixmap, dc.gc, geom.seg_x, off, geom.seg_w);
}

// ── Public API — segmented carousel ─────────────────────────────────────────

/// Render the focused window's title for a split-view segment.
///
/// Returns true when a carousel blit was performed; false when the text fits
/// and the caller should draw it with dc.drawText directly.
///
/// Rebuild triggers: same unified logic as drawScrollingTitle, plus
/// externally_invalidated from focus_signal (set by notifyFocusChanged).
pub fn drawSegmentedCarousel(
    dc:                *drawing.DrawContext,
    baseline_y:        u16,
    geom:              SegmentGeometry,
    text_w:            u16,
    text:              []const u8,
    accent:            u32,
    text_fg:           u32,
    window:            u32,
    title_invalidated: bool,
) !bool {
    if (text_w <= geom.avail_w) {
        // Text fits — free any live seg-carousel pixmap so the tick fast-path
        // (drawSegCarouselTickAuto) cannot blit stale scrolling content over
        // the static text that the caller is about to draw.  Mirrors the
        // deinitSingleCarousel() call in drawScrollingTitle for the same case.
        deinitSegmentedCarousel();
        return false;
    }

    // Consume the focus-change signal atomically.
    const externally_invalidated = focus_signal.is_invalidated.swap(false, .acq_rel);

    const cycle_w: u16 = text_w + carousel_gap_px;

    const stale = externally_invalidated
        or render.seg == null
        or render.seg.?.window            != window
        or render.seg.?.last_bg           != accent
        or title_invalidated
        or render.seg.?.cycle_w           != cycle_w
        or render.seg.?.geom.seg_x        != geom.seg_x
        or render.seg.?.geom.seg_w        != geom.seg_w
        or render.seg.?.geom.avail_w      != geom.avail_w;

    if (stale) {
        deinitSegmentedCarousel();

        const left_pad: u16 = if (geom.text_x > geom.seg_x)
            geom.text_x - geom.seg_x else 0;
        const pixmap_w: u16 = @max(
            left_pad + cycle_w + text_w,
            cycle_w  + geom.seg_w,
        );

        var cp = try drawing.CarouselPixmap.init(dc, pixmap_w);
        errdefer cp.deinit();
        try cp.render(dc, text, accent, text_fg, baseline_y, left_pad, cycle_w);

        render.seg = .{
            .cp       = cp,
            .cycle_w  = cycle_w,
            .start_ms = utils.monotonicMs(),
            .last_bg  = accent,
            .window   = window,
            .geom     = geom,
        };
        // Publish the window atomically so notifyFocusChanged on the main
        // thread can check it without touching render.seg.
        focus_signal.seg_window.store(window, .release);
    }

    const e   = render.seg.?;
    const off = carouselOffset(e.start_ms, e.cycle_w, utils.monotonicMs());
    e.cp.blitFrame(dc.offscreen_pixmap, dc.gc, geom.seg_x, off, geom.seg_w);
    return true;
}

// ── Private — scroll math ────────────────────────────────────────────────────

/// Smooth continuous scroll offset.
///
///   offset = (elapsed_ms × speed / 1000.0) mod cycle_w
///
/// Linear interpolation with no frame quantisation — the position advances
/// proportionally to elapsed wall-clock time regardless of the bar thread's
/// wakeup cadence.  The previous frame-quantised formula stepped at display
/// Hz (e.g. every 16.67 ms at 60 Hz) while the bar woke at 165 Hz (6 ms),
/// producing a step-function: frozen for ~10 ms then a 2 px snap.
fn carouselOffset(start_ms: i64, cycle_w: u16, now_ms: i64) u16 {
    std.debug.assert(cycle_w > 0);
    const elapsed = @as(f64, @floatFromInt(@max(0, now_ms - start_ms)));
    const raw_px  = elapsed * scroll_config.speed / 1000.0;
    return @intFromFloat(@mod(raw_px, @as(f64, @floatFromInt(cycle_w))));
}
