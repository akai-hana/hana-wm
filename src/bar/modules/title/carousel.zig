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

/// Fallback refresh rate used when RandR is unavailable or returns an
/// invalid value.  No longer used internally for carousel math; retained
/// for callers that call effectiveRefreshRate().
pub const default_hz: f64 = scale.default_hz;

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
    rate_override: f64 = 0.0,   // kept for API compat; not used in offset math
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
const FocusSignal = struct {
    is_invalidated: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
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

/// Returns the current scroll speed in pixels per second.
pub fn getScrollSpeed() f64 { return scroll_config.speed; }

/// Override the refresh rate used for frame cadence calculations.
/// Retained for API compatibility; the offset formula no longer uses Hz.
pub fn setRefreshRateOverride(hz: f64) void {
    scroll_config.rate_override = if (hz > 0.0) hz else 0.0;
}

/// Returns the active refresh rate (override when set, else auto-detected).
/// Retained for callers that need the Hz value for their own purposes.
pub fn effectiveRefreshRate() f64 {
    return if (scroll_config.rate_override > 0.0)
        scroll_config.rate_override
    else
        scale.cachedRefreshRate();
}

// ── Public API — lifecycle ───────────────────────────────────────────────────

/// True when either carousel pixmap is live.
pub fn isCarouselActive() bool {
    return render.single != null or render.seg != null;
}

/// Returns the window ID the segmented carousel was built for, or null.
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
}

// ── Public API — focus notification (main thread only) ───────────────────────

/// Called by the focus system when the focused window changes.
/// MUST be called from the main thread only.
/// Sets focus_signal.is_invalidated so the render thread rebuilds the
/// seg-carousel on the next blit.
pub fn notifyFocusChanged(new_window: ?u32) void {
    const changed = if (render.seg) |e|
        if (new_window) |nw| nw != e.window else true
    else
        new_window != null;

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
    if (text_w <= geom.avail_w) return false;

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

// ── Private — Hz detection (kept for effectiveRefreshRate API) ───────────────

fn xcbRootWindow(conn: *xcb.xcb_connection_t) u32 {
    const setup = xcb.xcb_get_setup(conn);
    var it      = xcb.xcb_setup_roots_iterator(setup);
    return if (it.rem > 0) it.data.*.root else 0;
}

fn detectRefreshRateViaCrtc(conn: *xcb.xcb_connection_t, root: u32) ?f64 {
    const rc = xcb.xcb_randr_get_screen_resources_current(conn, root);
    const rr = xcb.xcb_randr_get_screen_resources_current_reply(conn, rc, null) orelse
        return null;
    defer std.c.free(rr);

    const mode_it_len = xcb.xcb_randr_get_screen_resources_current_modes_length(rr);
    const mode_it_ptr = xcb.xcb_randr_get_screen_resources_current_modes(rr);
    if (mode_it_len <= 0 or mode_it_ptr == null) return null;
    const modes = mode_it_ptr.?[0..@intCast(mode_it_len)];

    const crtc_it_len = xcb.xcb_randr_get_screen_resources_current_crtcs_length(rr);
    const crtc_it_ptr = xcb.xcb_randr_get_screen_resources_current_crtcs(rr);
    if (crtc_it_len <= 0 or crtc_it_ptr == null) return null;
    const crtcs = crtc_it_ptr.?[0..@intCast(crtc_it_len)];

    const max_crtcs: usize = 16;
    const n_crtcs          = @min(crtcs.len, max_crtcs);
    var crtc_cookies: [max_crtcs]xcb.xcb_randr_get_crtc_info_cookie_t = undefined;
    for (crtcs[0..n_crtcs], crtc_cookies[0..n_crtcs]) |crtc, *cookie|
        cookie.* = xcb.xcb_randr_get_crtc_info(conn, crtc, rr.*.config_timestamp);

    var best_hz: f64 = 0.0;
    for (0..n_crtcs) |i| {
        const cr = xcb.xcb_randr_get_crtc_info_reply(conn, crtc_cookies[i], null) orelse continue;
        defer std.c.free(cr);
        const mode_id = cr.*.mode;
        if (mode_id == 0) continue;
        for (modes) |m| {
            if (m.id != mode_id) continue;
            const htotal: u64 = m.htotal;
            const vtotal: u64 = m.vtotal;
            if (htotal == 0 or vtotal == 0) break;
            const hz: f64 = @as(f64, @floatFromInt(m.dot_clock)) /
                            @as(f64, @floatFromInt(htotal * vtotal));
            if (hz > best_hz) best_hz = hz;
            break;
        }
    }
    return if (best_hz > 0.0) best_hz else null;
}

fn detectRefreshRate(conn: *xcb.xcb_connection_t) f64 {
    if (!@hasDecl(xcb, "xcb_randr_get_screen_info")) return default_hz;
    const root = xcbRootWindow(conn);
    if (root == 0) return default_hz;
    const cookie = xcb.xcb_randr_get_screen_info(conn, root);
    const reply  = xcb.xcb_randr_get_screen_info_reply(conn, cookie, null) orelse
        return default_hz;
    defer std.c.free(reply);
    const rate = reply.*.rate;
    if (rate > 0) return @floatFromInt(rate);
    if (@hasDecl(xcb, "xcb_randr_get_screen_resources_current"))
        if (detectRefreshRateViaCrtc(conn, root)) |hz| return hz;
    return default_hz;
}
