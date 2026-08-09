//! Carousel title extension
//! Adds a scrolling effect to window titles that don't fit the title bar segment.

const std = @import("std");
const utils = @import("utils");

const scale = @import("scale");
const drawing = @import("drawing");
const bar = @import("bar");
const debug = @import("debug");

// Public constants

/// Default scroll speed in pixels per second.
pub const default_scroll_speed: f64 = 125.0;

/// Pixel gap between the end of text copy A and the start of copy B in the
/// pre-rendered pixmap.
pub const carousel_gap_px: u16 = 60;

// Public geometry type

/// Segment geometry passed to carousel draw functions.
pub const SegmentGeometry = struct {
    seg_x: u16, // Full segment bounds
    seg_w: u16, // (clip + fill region)
    text_x: u16, // inset text area
    avail_w: u16, // (used for overflow check and static/ellipsis fallback drawing)
};

/// Horizontal inset between the text area and the segment bounds.
inline fn leftPadOf(geom: SegmentGeometry) u16 {
    return if (geom.text_x > geom.seg_x) geom.text_x - geom.seg_x else 0;
}

// Internal types

/// All state for one live carousel (single-window or segmented).
const CarouselEntry = struct {
    cp: drawing.CarouselPixmap,
    cycle_w: u16, // text_w + carousel_gap_px
    pixel_offset: u16, // current integer blit offset (advances each tick)
    frac_acc: f64, // sub-pixel carry between ticks (Bresenham remainder)
    last_ns: u64, // monotonicNs() of the most-recent blit
    last_bg: u32, // accent colour baked into cp; detects colour-only changes on later draws
    // to detect a colour change before the next full draw
    window: ?u32, // window the pixmap was built for (null = no window)
    geom: SegmentGeometry,
};

/// True when `e` must be rebuilt from scratch: the window it was built for,
/// the title, the cycle width, or the segment geometry changed.
/// Colour-only changes (e.last_bg) are deliberately excluded — those reuse
/// the existing pixmap in place.
inline fn entryStale(e: *const CarouselEntry, window: ?u32, title_invalidated: bool, cycle_w: u16, geom: SegmentGeometry) bool {
    return e.window != window or title_invalidated or e.cycle_w != cycle_w or
        e.geom.seg_x != geom.seg_x or e.geom.seg_w != geom.seg_w or e.geom.avail_w != geom.avail_w;
}

/// Runtime-configurable scroll parameters.
const ScrollConfig = struct {
    speed: f64 = default_scroll_speed,
    /// When > 0, overrides the monitor's detected refresh rate for the wake
    /// interval. Set via `carousel_refresh_rate` in the config file.
    rate_override: f64 = 0.0,
};

/// All state exclusively owned by whichever thread currently holds bar.zig's
/// draw_mutex (the main WM thread or the dedicated carousel thread — never
/// both at once). `is_enabled` is also written by the main thread outside
/// that lock (setCarouselEnabled) and is therefore an atomic; all other
/// fields require draw_mutex.
const RenderState = struct {
    single: ?CarouselEntry = null,
    seg: ?CarouselEntry = null,
    is_enabled: std.atomic.Value(bool) = std.atomic.Value(bool).init(true),
};

/// Cross-thread signal: the focus system sets is_invalidated (from the main
/// thread, outside draw_mutex) when focus changes; whichever thread is
/// currently drawing (main or carousel, under draw_mutex) consumes it on the
/// next seg-carousel blit.
///
/// `seg_window` is the window the seg carousel was last built for (0 = none).
/// The drawing thread writes it atomically after updating render.seg so the
/// main thread's notifyFocusChanged can check it without touching the
/// non-atomic render.seg.
const FocusSignal = struct {
    is_invalidated: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    seg_window: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
};

var scroll_config: ScrollConfig = .{};
var render: RenderState = .{};
var focus_signal: FocusSignal = .{};

// Public API — feature toggles and scroll config

/// Enable or disable the carousel globally.
/// Disabling immediately frees all carousel pixmaps.
pub fn setCarouselEnabled(enabled: bool) void {
    if (!enabled and render.is_enabled.load(.acquire)) deinitCarousel();
    render.is_enabled.store(enabled, .release);
}

/// Returns true when the carousel feature is currently enabled.
pub fn isCarouselEnabled() bool {
    return render.is_enabled.load(.monotonic);
}

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

/// Returns the carousel thread's wake interval in nanoseconds.
///
/// Priority:
///   1. User-configured `carousel_refresh_rate` (rate_override > 0).
///   2. Monitor refresh rate detected via RandR at startup.
///   3. 60 Hz fallback when detection has not yet run.
///
/// Called once per carousel-thread sleep cycle; the division is cheap relative
/// to the timedWait syscall that follows.
pub fn wakeIntervalNs() u64 {
    const hz: f64 = if (scroll_config.rate_override > 0.0)
        scroll_config.rate_override
    else
        scale.getDetectedRateHz();
    return @intFromFloat(1_000_000_000.0 / hz);
}

// Public API — lifecycle

/// True when either carousel pixmap is live.
pub fn isCarouselActive() bool {
    return render.single != null or render.seg != null;
}

/// Returns the window ID the segmented carousel was built for, or null.
/// Caller must hold bar.zig's draw_mutex — reading render.seg here is only
/// safe while no other thread can be drawing concurrently.
pub fn getSegmentedCarouselWindow() ?u32 {
    return if (render.seg) |e| e.window else null;
}

/// Free all carousel pixmaps and reset cross-thread signals.
/// Call on bar deinit or config reload, after the carousel thread has
/// already been stopped (carousel.stopThread()) so nothing else can be
/// touching render.single/render.seg concurrently.
pub fn deinitCarousel() void {
    deinitSingleCarousel();
    deinitSegmentedCarousel();
    focus_signal.is_invalidated.store(false, .monotonic);
}

/// Free the single-window carousel pixmap.
/// Caller must either hold draw_mutex or call after the carousel thread has
/// stopped (see deinitCarousel).
pub fn deinitSingleCarousel() void {
    if (render.single) |*e| {
        e.cp.deinit();
        render.single = null;
    }
}

/// Free the segmented carousel pixmap.
/// Caller must either hold draw_mutex or call after the carousel thread has
/// stopped (see deinitCarousel).
pub fn deinitSegmentedCarousel() void {
    if (render.seg) |*e| {
        e.cp.deinit();
        render.seg = null;
    }
    focus_signal.seg_window.store(0, .release);
}

// Public API — focus notification (main thread only)

/// Called by the focus system when the focused window changes.
/// MUST be called from the main thread only.
/// Sets focus_signal.is_invalidated so whichever thread draws next rebuilds
/// the seg-carousel on its next blit.
pub fn notifyFocusChanged(new_window: ?u32) void {
    const tracked = focus_signal.seg_window.load(.acquire);
    const changed = if (new_window) |nw| nw != tracked else tracked != 0;
    if (!changed) return;
    focus_signal.is_invalidated.store(true, .release);
}

// Thread lifecycle
//
// The carousel needs to redraw on its own cadence (roughly once per display
// refresh) whenever a title is actively scrolling, independent of both the
// once-a-second clock tick and whatever the main WM event loop happens to be
// doing. This mirrors clock.zig's dedicated-thread pattern: a small thread
// that sleeps, wakes, ticks if there's anything to tick, and sleeps again.
//
// Unlike the clock thread, there is no wall-clock deadline to stay aligned
// to, so the loop simply re-sleeps for wakeIntervalNs() every iteration
// (re-read live each time, so a config-driven refresh-rate change or
// carousel_refresh_rate override takes effect on the very next wake) rather
// than tracking a fixed schedule.
//
//   startThread() — call from bar.init() after the bar window exists.
//   stopThread()  — call before bar teardown (deinit and reload).

var carousel_mutex: utils.Mutex = .{};
var carousel_cond: utils.Condition = .{};
var carousel_quit: bool = false;
var carousel_thread: ?std.Thread = null;

/// Spawns the dedicated carousel-tick thread. Safe to call after stopThread().
pub fn startThread() void {
    // timedWait uses a CLOCK_MONOTONIC deadline; safe to re-init on every
    // call (init/reload) since the thread is never running while this fires.
    carousel_cond.initMonotonic();
    carousel_mutex.lock();
    carousel_quit = false;
    carousel_mutex.unlock();
    carousel_thread = std.Thread.spawn(.{}, runCarouselThread, .{}) catch |e| {
        debug.err("Carousel thread spawn failed: {s}", .{@errorName(e)});
        return;
    };
}

/// Signals the carousel thread to exit and blocks until it has joined.
/// Returns within one wake interval (typically well under 16ms) rather than
/// waiting for a full sleep cycle, since stopThread signals the condition
/// the thread is sleeping on.
pub fn stopThread() void {
    carousel_mutex.lock();
    carousel_quit = true;
    carousel_cond.signal();
    carousel_mutex.unlock();
    if (carousel_thread) |t| {
        t.join();
        carousel_thread = null;
    }
}

fn runCarouselThread() void {
    while (true) {
        carousel_mutex.lock();
        const quit = carousel_quit;
        carousel_mutex.unlock();
        if (quit) return;

        if (isCarouselActive()) bar.tickCarousel();

        carousel_mutex.lock();
        defer carousel_mutex.unlock();
        if (carousel_quit) return;
        carousel_cond.timedWait(&carousel_mutex, wakeIntervalNs()) catch {};
        // Timeout is the expected outcome every iteration; a signal (from
        // stopThread) is handled by the quit re-check at the top of the loop.
    }
}

// Public API — hot-path carousel tick

/// Fast per-tick single-window carousel blit.
///
/// Returns false when:
///   • no single carousel is live,
///   • the segment position/size changed (bar resize — caller triggers a full draw), or
///   • the accent colour changed (minimize/unminimize — caller triggers a full draw
///     which rebuilds the pixmap with the new bg baked in).
///
/// Hot path: one xcb_copy_area (wide pixmap → offscreen) + blitAndFlush.
/// No fill, no Cairo, no Pango.
pub fn drawCarouselTick(
    dc: *drawing.DrawContext,
    bg: u32,
    seg_x: u16,
    seg_w: u16,
) bool {
    if (render.single == null) return false;
    const e = &render.single.?;
    if (seg_x != e.geom.seg_x or seg_w != e.geom.seg_w or bg != e.last_bg)
        return false;

    const off = advanceCarouselOffset(e, utils.monotonicNs());
    e.cp.blitFrame(dc.offscreen_pixmap, dc.gc, seg_x, off, seg_w);
    dc.blitAndFlush(seg_x, seg_w);
    return true;
}

/// Parameterless segmented carousel tick for use from the bar's drawTitleOnly path.
///
/// Reads seg_x, seg_w, and last_bg directly from the live render.seg entry so
/// the caller does not need to cache or re-derive the focused segment's bounds.
/// Returns false when no segmented carousel is live or the accent colour changed
/// (indicating a minimize/unminimize that requires a full rebuild).
pub fn drawSegCarouselTickAuto(dc: *drawing.DrawContext, accent: u32) bool {
    if (render.seg == null) return false;
    const e = &render.seg.?;
    if (accent != e.last_bg) return false;
    // If a focus change is pending, bail out so the caller falls through to
    // drawCached → drawSegmentedTitles, which redraws ALL segments with the
    // correct accent colours (old focused → unfocused, new focused → focused).
    if (focus_signal.is_invalidated.load(.acquire)) return false;
    const off = advanceCarouselOffset(e, utils.monotonicNs());
    e.cp.blitFrame(dc.offscreen_pixmap, dc.gc, e.geom.seg_x, off, e.geom.seg_w);
    dc.blitAndFlush(e.geom.seg_x, e.geom.seg_w);
    return true;
}

// Public API — single-window title rendering

/// Render `text` into the segment described by `geom`.
///
/// • If text fits within geom.avail_w: draw statically, free any carousel.
/// • If text overflows and carousel is enabled: build (or reuse) the wide
///   pixmap and blit one frame.
/// • If text overflows and carousel is disabled: draw with ellipsis.
///
/// Pixmap rebuild triggers (any change resets the accumulator to zero):
///   • No pixmap live
///   • Window ID changed
///   • Title text changed (title_invalidated)
///   • Text width changed (cycle_w mismatch)
///   • Segment geometry changed (position or size)
///
/// Colour-only change (accent update): pixmap is re-rendered in-place without
/// freeing and reallocating, preserving the scroll position.
pub fn drawScrollingTitle(
    dc: *drawing.DrawContext,
    y: u16,
    geom: SegmentGeometry,
    text: []const u8,
    bg: u32,
    fg: u32,
    window: ?u32,
    title_invalidated: bool,
) !void {
    // Recover text_w from the live entry when the title hasn't changed,
    // avoiding a Pango measurement on the common steady-state path.
    const text_w: u16 = if (!title_invalidated) blk: {
        if (render.single) |e| if (e.window == window) break :blk e.cycle_w - carousel_gap_px;
        break :blk dc.measureTextWidth(text);
    } else dc.measureTextWidth(text);

    if (text_w <= geom.avail_w) {
        deinitSingleCarousel();
        try dc.drawText(geom.text_x, y, text, fg);
        return;
    }

    if (!render.is_enabled.load(.monotonic)) {
        deinitSingleCarousel();
        try dc.drawTextEllipsis(geom.text_x, y, text, geom.avail_w, fg);
        return;
    }

    _ = try commitCarouselFrame(&render.single, dc, text, text_w, bg, fg, y, geom, window, title_invalidated, false);
}

// Public API — segmented carousel

/// Render the focused window's title for a split-view segment.
///
/// Returns true when a carousel blit was performed; false when the text fits
/// and the caller should draw it with dc.drawText directly.
///
/// Rebuild triggers: same unified logic as drawScrollingTitle, plus
/// externally_invalidated from focus_signal (set by notifyFocusChanged).
/// Colour-only change: re-rendered in-place, scroll position preserved.
pub fn drawSegmentedCarousel(
    dc: *drawing.DrawContext,
    baseline_y: u16,
    geom: SegmentGeometry,
    text_w: u16,
    text: []const u8,
    accent: u32,
    text_fg: u32,
    window: u32,
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
    const force_rebuild = focus_signal.is_invalidated.swap(false, .acq_rel);

    const rebuilt = try commitCarouselFrame(&render.seg, dc, text, text_w, accent, text_fg, baseline_y, geom, window, title_invalidated, force_rebuild);
    // Publish the window atomically after a rebuild so notifyFocusChanged on the
    // main thread can check it without touching render.seg.
    if (rebuilt) focus_signal.seg_window.store(window, .release);
    return true;
}

// Private — shared rebuild/recolour/blit step

/// Rebuilds `slot`'s pixmap from scratch when it is stale (window, title,
/// cycle width, or segment geometry changed — or `force_rebuild` is set), or
/// re-renders the existing pixmap in place on a colour-only change, then
/// advances the scroll offset and blits one frame.
/// Returns true when the pixmap was rebuilt from scratch.
fn commitCarouselFrame(
    slot: *?CarouselEntry,
    dc: *drawing.DrawContext,
    text: []const u8,
    text_w: u16,
    bg: u32,
    fg: u32,
    baseline_y: u16,
    geom: SegmentGeometry,
    window: ?u32,
    title_invalidated: bool,
    force_rebuild: bool,
) !bool {
    const cycle_w: u16 = text_w + carousel_gap_px;

    // Determine whether a full pixmap rebuild is needed (geometry/identity/
    // focus changed) vs. an in-place colour update vs. no action.
    const geom_stale = force_rebuild or if (slot.*) |*e| entryStale(e, window, title_invalidated, cycle_w, geom) else true;

    if (geom_stale) {
        // Full rebuild: free old pixmap (if any) then delegate to buildCarouselEntry.
        if (slot.*) |*old| old.cp.deinit();
        slot.* = try buildCarouselEntry(dc, text, text_w, bg, fg, baseline_y, geom, cycle_w, window);
        const e = &slot.*.?;
        const off = advanceCarouselOffset(e, e.last_ns);
        e.cp.blitFrame(dc.offscreen_pixmap, dc.gc, geom.seg_x, off, geom.seg_w);
        return true;
    }

    const e = &slot.*.?;

    if (e.last_bg != bg) {
        // Colour-only change: re-render into the existing pixmap without
        // freeing or reallocating it, preserving the scroll position.
        try e.cp.render(dc, text, bg, fg, baseline_y, leftPadOf(geom), cycle_w);
        e.last_bg = bg;
    }

    const off = advanceCarouselOffset(e, utils.monotonicNs());
    e.cp.blitFrame(dc.offscreen_pixmap, dc.gc, geom.seg_x, off, geom.seg_w);
    return false;
}

// Private — carousel entry construction

/// Build a fresh CarouselPixmap and CarouselEntry from scratch.
/// Computes left_pad and pixmap_w from `geom` and `text_w`, initialises the
/// sub-pixel accumulator to zero, and captures the current monotonic timestamp.
/// Returns a fully-populated entry ready to be stored in render.single or render.seg.
fn buildCarouselEntry(
    dc: *drawing.DrawContext,
    text: []const u8,
    text_w: u16,
    bg: u32,
    fg: u32,
    baseline_y: u16,
    geom: SegmentGeometry,
    cycle_w: u16,
    window: ?u32,
) !CarouselEntry {
    const left_pad = leftPadOf(geom);
    const pixmap_w: u16 = @max(
        left_pad + cycle_w + text_w, // room for text copy B
        cycle_w + geom.seg_w, // room for blit at max offset
    );
    var cp = try drawing.CarouselPixmap.init(dc, pixmap_w);
    errdefer cp.deinit();
    try cp.render(dc, text, bg, fg, baseline_y, left_pad, cycle_w);
    const now_ns = utils.monotonicNs();
    return CarouselEntry{
        .cp = cp,
        .cycle_w = cycle_w,
        .pixel_offset = 0,
        .frac_acc = 0.0,
        .last_ns = now_ns,
        .last_bg = bg,
        .window = window,
        .geom = geom,
    };
}

// Private — scroll math

/// Bresenham-style sub-pixel accumulator.
///
/// Advances `e.pixel_offset` by the correct integer number of pixels for the
/// elapsed time since the last blit, carrying the fractional remainder in
/// `e.frac_acc` so it is applied on the next tick.
///
/// This distributes 0 px and 1 px advances evenly across frames (Bresenham
/// pattern) rather than clustering all the fractional debt into occasional
/// larger jumps.  At 125 px/s on a 165 Hz display the raw advance is
/// ≈0.758 px/frame; simply flooring that value each frame would instead
/// produce a freeze every ~4–5 frames followed by a 1 px snap.  The
/// accumulator ensures every frame moves either 0 or 1 px in an optimally
/// spaced sequence with no clustering.
///
/// Caller must hold a mutable pointer to the entry (`*CarouselEntry`).
fn advanceCarouselOffset(e: *CarouselEntry, now_ns: u64) u16 {
    std.debug.assert(e.cycle_w > 0);
    const delta_ns = @as(f64, @floatFromInt(now_ns -| e.last_ns));
    // Accumulate exact sub-pixel advance for this tick plus any carry.
    const delta_px = delta_ns * scroll_config.speed / 1_000_000_000.0 + e.frac_acc;
    const int_px = @floor(delta_px);
    e.frac_acc = delta_px - int_px; // carry remainder to next tick
    e.last_ns = now_ns;

    // Reduce modulo cycle_w in floating point *before* casting to an
    // integer. Under normal ticking int_px is 0 or 1 and this is a no-op,
    // but after a long stall (the carousel thread being descheduled, or the
    // machine suspending) delta_ns — and therefore int_px — can be far
    // larger than fits in a u32. Casting that directly via @intFromFloat
    // below would overflow (a trap in safety-checked builds, UB otherwise).
    // Only the wrapped remainder ever affects pixel_offset, so reducing
    // first is exactly equivalent for the result while staying in range.
    const cycle_w_f: f64 = @floatFromInt(e.cycle_w);
    const wrapped_advance: u32 = @intFromFloat(@mod(int_px, cycle_w_f));
    e.pixel_offset = @truncate((@as(u32, e.pixel_offset) + wrapped_advance) % @as(u32, e.cycle_w));
    return e.pixel_offset;
}
