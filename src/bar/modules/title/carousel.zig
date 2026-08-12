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
pub const default_scroll_speed: u8 = 250;

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
    last_bg: u32, // accent colour baked into cp
    last_fg: u32, // text colour baked into cp
    // last_bg/last_fg detect colour-only changes on later draws so the pixmap
    // is re-rendered in place (scroll position preserved) instead of rebuilt.
    window: ?u32, // window the pixmap was built for (null = no window)
    geom: SegmentGeometry,
};

/// True when `e` must be rebuilt from scratch: the window it was built for,
/// the title, the cycle width, or the segment geometry changed.
/// Colour-only changes (e.last_bg/e.last_fg) are deliberately excluded — those
/// reuse the existing pixmap in place.
inline fn entryStale(e: *const CarouselEntry, window: ?u32, title_invalidated: bool, cycle_w: u16, geom: SegmentGeometry) bool {
    return e.window != window or title_invalidated or e.cycle_w != cycle_w or
        e.geom.seg_x != geom.seg_x or e.geom.seg_w != geom.seg_w or e.geom.avail_w != geom.avail_w;
}

/// Runtime-configurable scroll parameters.
/// Read by the carousel thread (wakeIntervalNs, advanceCarouselOffset) and
/// written by the main thread during config parse/reload, so both fields are
/// atomics rather than plain f64.
const ScrollConfig = struct {
    speed: std.atomic.Value(f64) = std.atomic.Value(f64).init(default_scroll_speed),
    /// When > 0, overrides the monitor's detected refresh rate for the wake
    /// interval. Set via `carousel_refresh_rate` in the config file.
    rate_override: std.atomic.Value(f64) = std.atomic.Value(f64).init(0.0),
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
    /// Atomic mirror of `single != null or seg != null`, maintained under
    /// draw_mutex. Lets the carousel thread's wake-loop check activity (and
    /// pick its sleep interval) without racing the main thread's deinit of the
    /// non-atomic `single`/`seg` fields.
    active: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
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
    scroll_config.speed.store(if (px_per_s > 0.0) px_per_s else default_scroll_speed, .monotonic);
}

/// Override the refresh rate used for the wake interval.
/// Pass 0 (the default) to use the monitor's auto-detected rate.
pub fn setRefreshRateOverride(hz: f64) void {
    scroll_config.rate_override.store(if (hz > 0.0) hz else 0.0, .monotonic);
}

/// Returns the carousel thread's wake interval in nanoseconds.
///
/// Priority:
///   1. User-configured `carousel_refresh_rate` (rate_override > 0).
///   2. Monitor refresh rate detected via RandR — queried at startup and
///      re-detected live whenever the monitor re-configures (mode switch,
///      hotplug), so a rate change takes effect on the very next wake.
///   3. 60 Hz fallback when detection is unavailable or has not yet run.
///
/// Called once per carousel-thread sleep cycle; the division is cheap relative
/// to the timedWait syscall that follows.
pub fn wakeIntervalNs() u64 {
    const rate_override = scroll_config.rate_override.load(.monotonic);
    const hz: f64 = if (rate_override > 0.0) rate_override else scale.getDetectedRateHz();
    return @intFromFloat(1_000_000_000.0 / hz);
}

// Public API — lifecycle

/// True when either carousel pixmap is live.
/// Backed by the `active` atomic mirror so the carousel thread can read it
/// without draw_mutex — reading render.single/render.seg themselves from a
/// second thread would race the main thread's deinit under the lock.
pub fn isCarouselActive() bool {
    return render.active.load(.monotonic);
}

/// Returns the window ID the segmented carousel was built for, or null.
/// Caller must hold bar.zig's draw_mutex — reading render.seg here is only
/// safe while no other thread can be drawing concurrently.
pub fn getSegmentedCarouselWindow() ?u32 {
    return if (render.seg) |e| e.window else null;
}

/// Free all carousel pixmaps and reset cross-thread signals.
/// Call on bar deinit or config reload. Safe both when the carousel thread is
/// still running and after it has been stopped: it acquires bar.zig's
/// draw_mutex (which the carousel thread holds while drawing) so it cannot
/// race a concurrent blit of render.single/render.seg.
/// Caller must NOT already hold draw_mutex (it is not recursive); use
/// deinitCarouselLocked() from within a draw that holds draw_mutex.
pub fn deinitCarousel() void {
    bar.draw_mutex.lock();
    defer bar.draw_mutex.unlock();
    deinitCarouselLocked();
}

/// Same teardown as deinitCarousel() for callers that already hold bar.zig's
/// draw_mutex (title rendering paths run under it via performDraw/redraws).
/// Must not be called without holding draw_mutex.
pub fn deinitCarouselLocked() void {
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
        if (render.seg == null) render.active.store(false, .monotonic);
    }
}

/// Free the segmented carousel pixmap.
/// Caller must either hold draw_mutex or call after the carousel thread has
/// stopped (see deinitCarousel).
pub fn deinitSegmentedCarousel() void {
    if (render.seg) |*e| {
        e.cp.deinit();
        render.seg = null;
        if (render.single == null) render.active.store(false, .monotonic);
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

/// Sleep duration while no carousel is live. With no title scrolling, a
/// once-per-refresh wakeup is pure overhead; commitCarouselFrame signals the
/// condition variable when a carousel becomes active, so the thread still
/// starts scrolling within one refresh of activation despite the long sleep.
const idle_interval_ns: u64 = 250 * std.time.ns_per_ms;

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
        // Sleep one refresh interval while a title is scrolling, or a long idle
        // interval when nothing is active (most of the bar's lifetime). The
        // activity check runs under carousel_mutex — the same mutex
        // commitCarouselFrame holds while signalling on activation — so the
        // activation signal can never be lost between this check and the wait.
        const interval = if (isCarouselActive()) wakeIntervalNs() else idle_interval_ns;
        carousel_cond.timedWait(&carousel_mutex, interval) catch {};
        // Timeout is the expected outcome every iteration; a signal (from
        // stopThread or commitCarouselFrame) is handled by the re-checks at the
        // top of the loop.
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

    // Skip the blit when the offset didn't advance (sub-pixel carry frames):
    // the source content is identical, so the last frame is already correct.
    // This avoids ~25% of the copy+flush work at typical speeds on high-refresh
    // displays and lets the compositor skip a no-op present. The accumulator
    // still carries the fractional remainder, so motion resumes exactly where
    // it left off.
    const prev_off = e.pixel_offset;
    const off = advanceCarouselOffset(e, utils.monotonicNs());
    if (off == prev_off) return true;
    e.cp.blitFrame(dc.offscreen_pixmap, dc.gc, seg_x, off, seg_w);
    // Skip the flush while the main thread holds the X server grab: xcb_flush
    // here would release the grab-batch requests mid-grab, splitting what must
    // be one atomic compositor frame. The enqueued copy_area instead rides
    // along with the main thread's closing ungrabAndFlush.
    if (!utils.isGrabActive()) dc.blitAndFlush(seg_x, seg_w);
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
    const prev_off = e.pixel_offset;
    const off = advanceCarouselOffset(e, utils.monotonicNs());
    // See drawCarouselTick: identical-offset frames need no blit or flush.
    if (off == prev_off) return true;
    e.cp.blitFrame(dc.offscreen_pixmap, dc.gc, e.geom.seg_x, off, e.geom.seg_w);
    // See drawCarouselTick: skip the flush inside an X server grab so the
    // shared output buffer is not released mid-grab.
    if (!utils.isGrabActive()) dc.blitAndFlush(e.geom.seg_x, e.geom.seg_w);
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

/// Publish a freshly-built carousel entry: set the atomic `active` mirror and
/// wake the carousel thread so the scroll starts on the next refresh instead of
/// at the end of the idle interval. Must be called after storing a new entry
/// while holding draw_mutex. Safe before startThread() — with the thread not
/// running the mutex is never touched.
inline fn publishActive() void {
    render.active.store(true, .release);
    if (carousel_thread != null) {
        // Held only around the signal, matching the thread's activity check
        // under carousel_mutex so the wakeup cannot be lost (see
        // runCarouselThread).
        carousel_mutex.lock();
        carousel_cond.signal();
        carousel_mutex.unlock();
    }
}

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
        // Full rebuild: build the new pixmap before freeing the old one so a
        // failed build keeps the previous pixmap live (the scroll continues on
        // the old frame) instead of dropping to a blank segment.
        const new_entry = try buildCarouselEntry(dc, text, bg, fg, baseline_y, geom, cycle_w, window);
        if (slot.*) |*old| old.cp.deinit();
        slot.* = new_entry;
        publishActive();
        const e = &slot.*.?;
        const off = advanceCarouselOffset(e, e.last_ns);
        e.cp.blitFrame(dc.offscreen_pixmap, dc.gc, geom.seg_x, off, geom.seg_w);
        return true;
    }

    const e = &slot.*.?;

    if (e.last_bg != bg or e.last_fg != fg) {
        // Colour-only change: re-render into the existing pixmap without
        // freeing or reallocating it, preserving the scroll position.
        try e.cp.render(dc, text, bg, fg, baseline_y, leftPadOf(geom), cycle_w);
        e.last_bg = bg;
        e.last_fg = fg;
    }

    const off = advanceCarouselOffset(e, utils.monotonicNs());
    e.cp.blitFrame(dc.offscreen_pixmap, dc.gc, geom.seg_x, off, geom.seg_w);
    return false;
}

// Private — carousel entry construction

/// Build a fresh CarouselPixmap and CarouselEntry from scratch.
/// Computes left_pad and the blit-minimum pixmap width from `geom`, initialises
/// the sub-pixel accumulator to zero, and captures the current monotonic timestamp.
/// Returns a fully-populated entry ready to be stored in render.single or render.seg.
fn buildCarouselEntry(
    dc: *drawing.DrawContext,
    text: []const u8,
    bg: u32,
    fg: u32,
    baseline_y: u16,
    geom: SegmentGeometry,
    cycle_w: u16,
    window: ?u32,
) !CarouselEntry {
    const left_pad = leftPadOf(geom);
    // The blit window is always [O, O + seg_w) with O in [0, cycle_w), so source
    // pixels past cycle_w + seg_w are never read. Copy B clips at the pixmap
    // edge when the title is wider than the segment: the window can only ever
    // see the first seg_w - left_pad pixels of it, which always land inside the
    // pixmap. A full second copy (left_pad + cycle_w + text_w) holds text that
    // nothing ever reads — for very long titles that's roughly double the
    // server-side pixmap memory for zero gain.
    const pixmap_w: u16 = cycle_w + geom.seg_w;
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
        .last_fg = fg,
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
    const delta_px = delta_ns * scroll_config.speed.load(.monotonic) / 1_000_000_000.0 + e.frac_acc;
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
