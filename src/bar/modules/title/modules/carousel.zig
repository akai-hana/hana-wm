//! Carousel / ticker logic for the title segment, including monitor
//! refresh-rate detection.
//!
//! A "carousel" is a pre-rendered XCB pixmap wider than the available area.
//! Every frame a window into that pixmap is blitted via xcb_copy_area using a
//! time-derived offset, producing a smooth horizontal scroll.
//!
//! V-sync alignment
//!
//! The scroll offset is quantised to monitor frame boundaries so that
//! destination pixels change at most once per frame, eliminating sub-pixel
//! drift and aligning every visible update with a v-blank interval.
//!
//!   frame_duration = 1 000 ms / hz
//!   pixels_per_frame = g_scroll_speed / hz
//!   frame_number = floor(elapsed_ms / frame_duration)
//!   offset = (frame_number × pixels_per_frame)  mod  cycle_w
//!
//! The pixmap is rebuilt only when the window ID, title, accent colour, or
//! segment geometry changes — the hot path is always two xcb_copy_area blits.
//!
//! Leapfrog wrap
//!
//! Two logical copies of the text sit `cycle_w` apart in the pixmap.  As
//! `offset` advances 0 -> cycle_w the first copy exits left while the second
//! enters right.  At cycle_w the state is identical to 0 — seamless loop.
//!
//!   cycle_w = text_w + CAROUSEL_GAP_PX
//!
//! Threading model
//!
//! The render thread (bar thread) is the SOLE OWNER of all carousel pixmaps.
//! It is the only thread that creates, blits, or frees them.  The main thread
//! (focus / event loop) communicates exclusively via two lock-free atomics:
//!
//!   g_seg_invalidated    — stored true on focus change; the render thread
//!                          swaps it to false at the start of blitSegCarousel
//!                          and rebuilds the pixmap when it was true.
//!   g_seg_focus_start_ms — stores nowMs() at the focus-change instant so the
//!                          animation is anchored to click time, not draw time;
//!                          consumed (swapped to 0) by blitSegCarousel once.
//!
//! Functions that must only be called from the RENDER thread:
//!   ensureDetected, drawOrScrollTitle, blitSegCarousel, drawCarouselTick,
//!   deinitSingleCarousel, deinitSegCarousel, deinitCarousel, isCarouselActive,
//!   getSegCarouselWindow.
//!
//! Functions that must only be called from the MAIN thread (or before the
//! render thread starts):
//!   notifyFocusChanged.
//!
//! Functions safe to call from EITHER thread:
//!   getCached, invalidate, setCarouselEnabled, isCarouselEnabled,
//!   setScrollSpeed, getScrollSpeed, setRefreshRateOverride,
//!   getEffectiveRefreshRate.
//!
//! Calling render-thread-only functions from the main thread is a data race.

const std     = @import("std");
const defs    = @import("defs");
const drawing = @import("drawing");
const core    = @import("core");
const xcb     = core.xcb;

// ── Hertz detection ──────────────────────────────────────────────────────────
//
// Usage:
//   carousel.ensureDetected(conn);  // once per draw cycle — no-op after first
//   carousel.invalidate();          // on RRScreenChangeNotify
//   carousel.getCached();           // read cached value; never blocks

/// Fallback rate used when RandR is unavailable or returns an invalid value.
pub const DEFAULT_HZ: f64 = 60.0;

var g_hz:       f64  = DEFAULT_HZ;
var g_hz_ready: bool = false;

/// Return the cached refresh rate (Hz).
/// Always safe to call; returns DEFAULT_HZ if detection has not yet run.
pub fn getCached() f64 { return g_hz; }

/// Detect and cache the monitor refresh rate.
/// Subsequent calls are a single branch and a return — zero X11 I/O.
pub fn ensureDetected(conn: *xcb.xcb_connection_t) void {
    if (g_hz_ready) return;
    g_hz_ready = true;
    g_hz       = hzDetect(conn);
}

/// Force re-detection on the next ensureDetected() call.
/// Call this when handling an RRScreenChangeNotify event so that a monitor
/// hotplug or mode switch is picked up on the next draw cycle.
pub fn invalidate() void { g_hz_ready = false; }

fn hzGetRootWindow(conn: *xcb.xcb_connection_t) u32 {
    const setup = xcb.xcb_get_setup(conn);
    var it      = xcb.xcb_setup_roots_iterator(setup);
    return if (it.rem > 0) it.data.*.root else 0;
}

/// Read the refresh rate of all active CRTCs and return the highest value.
///
/// All xcb_randr_get_crtc_info cookies are fired before any reply is read,
/// reducing round-trips from O(crtcs) to O(1).
///
/// Returning the maximum rate rather than the first ensures correct behaviour
/// on multi-monitor setups where each display has a different refresh rate.
///
/// Returns null on any failure.
fn hzDetectViaCrtc(conn: *xcb.xcb_connection_t, root: u32) ?f64 {
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

    // Phase 1 — fire all CRTC info cookies before reading any replies (O(1) RTT).
    const MAX_CRTCS: usize = 16;
    const n_crtcs           = @min(crtcs.len, MAX_CRTCS);
    var crtc_cookies: [MAX_CRTCS]xcb.xcb_randr_get_crtc_info_cookie_t = undefined;
    for (crtcs[0..n_crtcs], 0..) |crtc, i| {
        crtc_cookies[i] = xcb.xcb_randr_get_crtc_info(conn, crtc, rr.*.config_timestamp);
    }

    // Phase 2 — collect replies; track the highest Hz among all active CRTCs.
    var best_hz: f64 = 0.0;
    for (0..n_crtcs) |i| {
        const cr = xcb.xcb_randr_get_crtc_info_reply(conn, crtc_cookies[i], null) orelse continue;
        defer std.c.free(cr);

        const mode_id = cr.*.mode;
        if (mode_id == 0) continue; // CRTC disabled

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

/// Attempt to read the current refresh rate via xcb_randr_get_screen_info.
/// Falls back to CRTC mode data when rate == 0, then to DEFAULT_HZ.
fn hzDetect(conn: *xcb.xcb_connection_t) f64 {
    if (!@hasDecl(xcb, "xcb_randr_get_screen_info")) return DEFAULT_HZ;

    const root = hzGetRootWindow(conn);
    if (root == 0) return DEFAULT_HZ;

    const cookie = xcb.xcb_randr_get_screen_info(conn, root);
    const reply  = xcb.xcb_randr_get_screen_info_reply(conn, cookie, null) orelse
        return DEFAULT_HZ;
    defer std.c.free(reply);

    const rate = reply.*.rate;
    if (rate > 0) return @floatFromInt(rate);

    // Some drivers report rate=0 but supply correct data via
    // get_screen_resources_current.
    if (@hasDecl(xcb, "xcb_randr_get_screen_resources_current"))
        if (hzDetectViaCrtc(conn, root)) |hz| return hz;

    return DEFAULT_HZ;
}

// ── Constants ────────────────────────────────────────────────────────────────

/// Default horizontal scroll speed in pixels per second.
/// Overridable at runtime via setScrollSpeed().
pub const DEFAULT_SCROLL_SPEED: f64 = 125.0;

/// Pixel gap between the end of one text copy and the start of the next.
pub const CAROUSEL_GAP_PX: u16 = 60;

// ── Public geometry type ─────────────────────────────────────────────────────

/// All segment geometry passed to carousel functions, replacing the six
/// positional parameters (x, avail_w, blit_x, blit_w, seg_x, seg_w) that
/// previously appeared at every call site.
///
///   seg_x  / seg_w   — full segment bounds: used as the fill and clip region
///                       for blit so the scroll covers the entire segment.
///   text_x / avail_w — inset text area: used for the overflow check, for
///                       positioning text that fits without scrolling, and for
///                       the ellipsis fallback.
pub const SegmentGeometry = struct {
    seg_x:   u16,
    seg_w:   u16,
    text_x:  u16,
    avail_w: u16,
};

// ── Internal types ────────────────────────────────────────────────────────────

const CarouselBase = struct {
    cp:       drawing.CarouselPixmap,
    cycle_w:  u16,
    start_ms: i64,
};

/// Single-window carousel entry.
///
/// `geom`    — segment geometry baked in at build time and compared on every
///             drawOrScrollTitle call.  A mismatch (e.g. bar resize) triggers
///             a rebuild with start_ms preserved so the animation is seamless.
/// `last_bg` — background colour baked into the pixmap.  A mismatch triggers
///             a rebuild with start_ms preserved so the accent change (e.g.
///             minimize / unminimize) is reflected immediately without a
///             visible animation reset.
const SingleEntry = struct {
    base:    CarouselBase,
    window:  ?u32,
    last_bg: u32,
    geom:    SegmentGeometry,
};

/// Segmented (split-view) carousel entry.
///
/// `window`  — always a real window ID; the seg path only activates for the
///             focused window in a split view.
/// `last_bg` — same bg-change tracking as SingleEntry, applied when the
///             focused segment's accent colour changes.
const SegEntry = struct {
    base:    CarouselBase,
    window:  u32,
    last_bg: u32,
};

// ── Runtime-configurable parameters ──────────────────────────────────────────

var g_scroll_speed:          f64 = DEFAULT_SCROLL_SPEED;
var g_refresh_rate_override: f64 = 0.0;

// ── Render-thread state ──────────────────────────────────────────────────────
//
// Exclusively owned by the render thread.  The main thread never reads or
// writes these variables directly; it communicates only via the atomics below.

var g_carousel:         ?SingleEntry = null;
var g_seg_carousel:     ?SegEntry    = null;
var g_carousel_enabled: bool         = true;

// ── Cross-thread atomics ─────────────────────────────────────────────────────
//
// Written by the main thread in notifyFocusChanged; read and cleared by the
// render thread in blitSegCarousel.  Using atomics here avoids a mutex on the
// hot blit path while still giving the main thread a safe way to signal state
// changes.

/// Set to true by notifyFocusChanged when focus moved to a different window.
/// The render thread swaps this to false in blitSegCarousel and, when it was
/// true, frees the stale pixmap and rebuilds it on that draw cycle.
var g_seg_invalidated: std.atomic.Value(bool) =
    std.atomic.Value(bool).init(false);

/// Monotonic timestamp (ms) stamped by notifyFocusChanged at the instant focus
/// changed, so the animation is anchored to click time rather than draw time.
/// Consumed (swapped to 0) by blitSegCarousel once when building the new
/// pixmap.  A value of 0 means no pending focus event.
var g_seg_focus_start_ms: std.atomic.Value(i64) =
    std.atomic.Value(i64).init(0);

// ── Private helpers ───────────────────────────────────────────────────────────

/// Free the single-window carousel pixmap.  Render thread only.
pub fn deinitSingleCarousel() void {
    if (g_carousel) |*e| { e.base.cp.deinit(); g_carousel = null; }
}

/// Free the segmented carousel pixmap.  Render thread only.
pub fn deinitSegCarousel() void {
    if (g_seg_carousel) |*e| { e.base.cp.deinit(); g_seg_carousel = null; }
}

// ── Public API — feature toggle ───────────────────────────────────────────────

/// Enable or disable the carousel globally.
///
/// Disabling immediately frees all carousel pixmaps so no stale pixmap
/// lingers while the feature is off.
pub fn setCarouselEnabled(enabled: bool) void {
    if (!enabled and g_carousel_enabled) deinitCarousel();
    g_carousel_enabled = enabled;
}

/// Returns true when the carousel feature is currently enabled.
pub fn isCarouselEnabled() bool { return g_carousel_enabled; }

/// Set the scroll speed in pixels per second.
///
/// Values ≤ 0 are silently clamped to DEFAULT_SCROLL_SPEED.
/// The change takes effect on the next tick — no pixmap rebuild is needed
/// because speed only affects the offset calculation.
pub fn setScrollSpeed(px_per_s: f64) void {
    g_scroll_speed = if (px_per_s > 0.0) px_per_s else DEFAULT_SCROLL_SPEED;
}

/// Returns the current scroll speed in pixels per second.
pub fn getScrollSpeed() f64 { return g_scroll_speed; }

/// Override the refresh rate used for carousel frame quantisation.
///
/// Pass a positive Hz value to fix the rendering cadence regardless of what
/// the monitor reports (useful for capping on high-Hz displays or forcing a
/// specific rate for testing).  Pass 0.0 to restore auto-detection.
pub fn setRefreshRateOverride(hz: f64) void {
    g_refresh_rate_override = if (hz > 0.0) hz else 0.0;
}

/// Returns the active refresh rate: the override when set, otherwise the
/// auto-detected monitor rate.
pub fn getEffectiveRefreshRate() f64 {
    return if (g_refresh_rate_override > 0.0) g_refresh_rate_override else getCached();
}

// ── Public API — lifecycle ────────────────────────────────────────────────────

/// True when either a single-window or segmented carousel pixmap is live.
/// The bar thread polls this to decide whether to schedule carousel ticks.
pub fn isCarouselActive() bool {
    return g_carousel != null or g_seg_carousel != null;
}

/// Return the window ID the segmented carousel was built for, or null if none
/// is live.  Used by title.zig to determine whether the seg-carousel's window
/// is still present in the workspace window list.
pub fn getSegCarouselWindow() ?u32 {
    return if (g_seg_carousel) |e| e.window else null;
}

/// Free all carousel pixmaps and reset cross-thread signals.
/// Call on bar deinit or config reload.  Render thread only.
pub fn deinitCarousel() void {
    deinitSingleCarousel();
    deinitSegCarousel();
    g_seg_focus_start_ms.store(0, .monotonic);
    g_seg_invalidated.store(false, .monotonic);
}

// ── Public API — focus notification ──────────────────────────────────────────

/// Called by the focus system the instant the focused window changes.
/// MUST be called from the MAIN thread only.
///
/// This function never touches carousel pixmaps directly (that would race with
/// the render thread's blit).  Instead it writes two atomics:
///
///   g_seg_invalidated    — signals the render thread to free and rebuild the
///                          seg-carousel on the next blitSegCarousel call.
///   g_seg_focus_start_ms — records the click instant so the replacement
///                          animation starts from t=0 relative to when the
///                          user actually clicked, not when the next draw ran.
///
/// The render thread will show the stale title for at most one frame before
/// the atomic is consumed and the pixmap rebuilt — imperceptible in practice.
///
/// Safe to call at any time; a no-op when the window is unchanged.
pub fn notifyFocusChanged(new_window: ?u32) void {
    // Read g_seg_carousel without a lock — a torn read is harmless here since
    // the worst outcome is a spurious animation restart on the next frame.
    const changed = if (g_seg_carousel) |e|
        if (new_window) |nw| nw != e.window else true
    else
        new_window != null;

    if (!changed) return;

    // .release ordering ensures g_seg_focus_start_ms is visible to the render
    // thread before g_seg_invalidated, so when the render thread sees
    // invalidated=true it also sees the correct timestamp.
    g_seg_focus_start_ms.store(nowMs(), .release);
    g_seg_invalidated.store(true, .release);
}

// ── Public API — hot-path tick ────────────────────────────────────────────────

/// Fast per-tick single-window carousel redraw.
///
/// Returns false (caller falls back to a full draw) when:
///   • no single-window carousel is live, or
///   • the segment geometry changed since the pixmap was built (e.g. bar resize).
///     The caller's full draw will rebuild the pixmap with correct coordinates.
///
/// Hot path: fillRect + blitFrame + flushRect — no Pango, no Cairo, no X11 I/O.
pub fn drawCarouselTick(
    dc:      *drawing.DrawContext,
    bg:      u32,
    height:  u16,
    x:       u16,
    avail_w: u16,
) bool {
    const e = g_carousel orelse return false;

    // Geometry mismatch means the bar was resized since the pixmap was built.
    // Signal the caller to run a full draw, which will rebuild the pixmap.
    if (x != e.geom.seg_x or avail_w != e.geom.seg_w) return false;

    // fillRect and flushRect use the full segment coords to cover the
    // background including the left padding gap.
    dc.fillRect(x, 0, avail_w, height, bg);
    const now    = nowMs();
    const offset = carouselOffset(e.base.start_ms, e.base.cycle_w, now);
    e.base.cp.blitFrame(dc.drawable, dc.gc, e.geom.text_x, x, avail_w, offset, e.base.cycle_w);
    dc.flushRect(x, avail_w);
    return true;
}

// ── Public API — single-window title rendering ────────────────────────────────

/// Render `text` into the segment described by `geom`.
///
/// If the text fits within geom.avail_w it is drawn normally via Pango/Cairo.
/// If it overflows and the carousel is enabled, a pixmap is built (or reused)
/// and blitted with a v-synced scroll offset.
/// If it overflows and the carousel is disabled, ellipsis is used as fallback.
///
/// Pixmap rebuild triggers (in order of precedence):
///   full_stale   — window ID changed, title invalidated, or no pixmap exists;
///                  resets start_ms to 0 so the animation begins from position 0.
///   bg_changed   — accent colour changed (minimize / unminimize); preserves
///                  start_ms for a seamless visual update.
///   geom_changed — segment geometry changed (bar resize / DPI change); preserves
///                  start_ms so the animation continues without interruption.
pub fn drawOrScrollTitle(
    dc:                *drawing.DrawContext,
    y:                 u16,
    geom:              SegmentGeometry,
    text:              []const u8,
    bg:                u32,
    fg:                u32,
    window:            ?u32,
    title_invalidated: bool,
) !void {
    const text_w = dc.textWidth(text);

    if (text_w <= geom.avail_w) {
        // Text fits — release any stale pixmap and draw statically.
        deinitSingleCarousel();
        try dc.drawText(geom.text_x, y, text, fg);
        return;
    }

    if (!g_carousel_enabled) {
        deinitSingleCarousel();
        try dc.drawTextEllipsis(geom.text_x, y, text, geom.avail_w, fg);
        return;
    }

    const full_stale = g_carousel == null
        or g_carousel.?.window  != window
        or title_invalidated;

    const bg_changed   = !full_stale and g_carousel.?.last_bg != bg;
    const geom_changed = !full_stale and (
        g_carousel.?.geom.text_x != geom.text_x or
        g_carousel.?.geom.seg_w  != geom.seg_w
    );

    if (full_stale or bg_changed or geom_changed) {
        // Read start_ms before freeing the old entry (full_stale may set it to
        // nowMs(); the other two cases preserve the running animation clock).
        const preserved_start_ms: i64 =
            if (full_stale) nowMs() else g_carousel.?.base.start_ms;

        deinitSingleCarousel();

        const cycle_w: u16 = text_w + CAROUSEL_GAP_PX;
        std.debug.assert(cycle_w > 0); // text_w >= 1 and CAROUSEL_GAP_PX >= 1

        var cp = try drawing.CarouselPixmap.init(dc, text_w);
        errdefer cp.deinit();
        try cp.render(dc, text, bg, fg, y);

        g_carousel = .{
            .base    = .{ .cp = cp, .cycle_w = cycle_w, .start_ms = preserved_start_ms },
            .window  = window,
            .last_bg = bg,
            .geom    = geom,
        };
    }

    const e      = g_carousel.?;
    const now    = nowMs();
    const offset = carouselOffset(e.base.start_ms, e.base.cycle_w, now);
    e.base.cp.blitFrame(dc.drawable, dc.gc, geom.text_x, geom.seg_x, geom.seg_w, offset, e.base.cycle_w);
}

// ── Public API — split-view segmented carousel ────────────────────────────────

/// Render the focused window's title for a split-view segment.
///
/// Returns true when a carousel blit was performed; false when the text fits
/// and the caller should draw it with dc.drawText directly.
///
/// `text_w` is pre-computed by the caller (it already has it for the overflow
/// check before deciding whether to call this function).
///
/// Pixmap rebuild triggers:
///   externally_invalidated — focus changed (signalled via notifyFocusChanged);
///                            consumes g_seg_focus_start_ms so the animation
///                            is anchored to click time.
///   bg_changed             — accent colour changed; preserves start_ms.
///   window ID changed      — window replaced; resets start_ms to nowMs().
///   title_invalidated      — title text changed; resets start_ms to nowMs().
///   cycle_w mismatch       — available area changed; resets start_ms to nowMs().
pub fn blitSegCarousel(
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
    if (text_w <= geom.avail_w) return false; // fits — caller draws normally

    // Consume the focus-change signal atomically.  .acq_rel ensures we observe
    // the g_seg_focus_start_ms write that preceded the g_seg_invalidated write.
    const externally_invalidated = g_seg_invalidated.swap(false, .acq_rel);

    const expected_cycle_w: u16 = text_w + CAROUSEL_GAP_PX;

    const bg_changed = g_seg_carousel != null and g_seg_carousel.?.last_bg != accent;

    const content_stale = externally_invalidated or (if (g_seg_carousel) |e|
        e.window != window            or
        title_invalidated             or
        e.base.cycle_w != expected_cycle_w
    else
        true);

    if (content_stale or bg_changed) {
        // Determine start_ms before freeing the old entry.
        // bg_changed-only: preserve the running clock so the colour update is
        // seamless.  content_stale: consume the focus-event timestamp when
        // available, otherwise fall back to nowMs().
        const preserved_start_ms: i64 = if (!content_stale and bg_changed)
            g_seg_carousel.?.base.start_ms
        else blk: {
            const t = g_seg_focus_start_ms.swap(0, .acq_rel);
            break :blk if (t != 0) t else nowMs();
        };

        deinitSegCarousel();

        const cycle_w: u16 = expected_cycle_w;
        std.debug.assert(cycle_w > 0); // text_w >= 1 and CAROUSEL_GAP_PX >= 1

        var cp = try drawing.CarouselPixmap.init(dc, text_w);
        errdefer cp.deinit();
        try cp.render(dc, text, accent, text_fg, baseline_y);

        g_seg_carousel = .{
            .base    = .{ .cp = cp, .cycle_w = cycle_w, .start_ms = preserved_start_ms },
            .window  = window,
            .last_bg = accent,
        };
    }

    const e      = g_seg_carousel.?;
    const now    = nowMs();
    const offset = carouselOffset(e.base.start_ms, e.base.cycle_w, now);
    e.base.cp.blitFrame(dc.drawable, dc.gc, geom.text_x, geom.seg_x, geom.seg_w, offset, e.base.cycle_w);
    return true;
}

// ── Internal helpers ──────────────────────────────────────────────────────────

/// Return the current monotonic clock in milliseconds.
///
/// Uses std.posix.clock_gettime so the call is resolved via the VDSO on
/// Linux — a pure memory read with no syscall overhead on kernels that
/// support it, unlike std.os.linux.clock_gettime which bypasses the VDSO.
fn nowMs() i64 {
    var ts: std.os.linux.timespec = undefined;
    _ = std.os.linux.clock_gettime(.MONOTONIC, &ts);
    return ts.sec * 1000 + @divTrunc(ts.nsec, 1_000_000);
}

/// Compute the v-synced scroll offset for a carousel with the given cycle width.
///
///   frame_duration_ms = 1000.0 / hz
///   px_per_frame      = g_scroll_speed / hz
///   frame_num         = floor(elapsed_ms / frame_duration_ms)
///   offset            = (frame_num × px_per_frame) mod cycle_w
///
/// Quantising to frame boundaries aligns visual updates with v-blank and
/// prevents partial-frame tearing when the bar redraws at an arbitrary
/// sub-frame moment.
///
/// `now_ms` is passed in by the caller (computed once per function invocation
/// via nowMs()) to avoid redundant clock calls and to keep this function pure.
fn carouselOffset(start_ms: i64, cycle_w: u16, now_ms: i64) u16 {
    // cycle_w = text_w + CAROUSEL_GAP_PX; both are always >= 1.
    std.debug.assert(cycle_w > 0);

    const hz           = getEffectiveRefreshRate();
    const frame_ms     = 1000.0 / hz;
    const px_per_frame = g_scroll_speed / hz;
    const elapsed_ms   = @as(f64, @floatFromInt(now_ms - start_ms));
    const frame_num    = @floor(elapsed_ms / frame_ms);
    const raw_px       = frame_num * px_per_frame;
    const cycle_f      = @as(f64, @floatFromInt(cycle_w));

    // @mod guarantees 0 <= result < cycle_f, so the cast to u16 is always safe.
    return @intFromFloat(@mod(raw_px, cycle_f));
}
