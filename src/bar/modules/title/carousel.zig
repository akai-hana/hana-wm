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

/// All state owned by whichever thread holds bar.zig's draw_mutex (the main
/// WM thread or the carousel thread — never both). `is_enabled` is also
/// written outside that lock (setCarouselEnabled) and is therefore an atomic;
/// all other fields require draw_mutex.
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

/// Cross-thread signal: the focus system sets is_invalidated (main thread,
/// outside draw_mutex) on focus change; whichever thread is drawing consumes
/// it on the next seg-carousel blit.
///
/// `seg_window` is the window the seg carousel was built for (0 = none),
/// written atomically after updating render.seg so notifyFocusChanged can
/// check it without touching the non-atomic field.
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
/// Priority: user-configured `carousel_refresh_rate` (rate_override > 0), then
/// the RandR-detected monitor rate (re-detected live on mode switch/hotplug,
/// so a change takes effect on the very next wake), then a 60 Hz fallback.
///
/// Called once per sleep cycle; the division is cheap relative to the
/// timedWait that follows.
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

/// Free all carousel pixmaps and reset cross-thread signals; call on bar
/// deinit or reload. Safe before or after the carousel thread stops: it takes
/// bar.zig's draw_mutex so it can't race a concurrent blit. Caller must NOT
/// already hold draw_mutex (not recursive) — use deinitCarouselLocked() there.
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
// The carousel redraws on its own cadence (roughly per display refresh) while
// a title scrolls, independent of the once-a-second clock tick and the main
// event loop — mirroring clock.zig's dedicated-thread pattern.
//
// Unlike the clock thread there's no wall-clock deadline, so the loop just
// re-sleeps for wakeIntervalNs() each iteration, re-read live so a
// refresh-rate config change takes effect on the very next wake.
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
        // Sleep one refresh interval while scrolling, or a long idle interval
        // when nothing is active. The check runs under carousel_mutex — the
        // same mutex commitCarouselFrame signals under — so the activation
        // signal can't be lost between check and wait.
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
/// Returns false when no single carousel is live, the segment position/size
/// changed (bar resize), or the accent colour changed (minimize/unminimize —
/// caller triggers a full draw that rebuilds with the new bg baked in).
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
    // source content is identical, so the last frame is already correct. This
    // avoids ~25% of the copy+flush work at typical speeds. The accumulator
    // still carries the remainder, so motion resumes where it left off.
    const prev_off = e.pixel_offset;
    const off = advanceCarouselOffset(e, utils.monotonicNs());
    if (off == prev_off) return true;
    blitOneFrame(e, dc, e.geom);
    return true;
}

/// Parameterless segmented carousel tick for drawTitleOnly. Reads seg_x, seg_w,
/// and last_bg from the live render.seg entry so the caller needn't cache the
/// focused segment's bounds. Returns false when no seg carousel is live or the
/// accent changed (a minimize/unminimize needing a full rebuild).
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
    blitOneFrame(e, dc, e.geom);
    return true;
}

// Public API — single-window title rendering

/// Render `text` into the segment described by `geom`.
///
/// Fits: draw statically, free any carousel. Overflows + enabled: build (or
/// reuse) the wide pixmap and blit one frame. Overflows + disabled: ellipsis.
///
/// Rebuild triggers (any resets the accumulator to zero): no pixmap live,
/// window changed, title changed (title_invalidated), text width changed
/// (cycle_w mismatch), or segment geometry changed (position/size).
///
/// Colour-only change: re-rendered in-place, preserving the scroll position.
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

    _ = try commitCarouselFrame(&render.single, dc, .{
        .text = text,
        .text_w = text_w,
        .bg = bg,
        .fg = fg,
        .baseline_y = y,
        .geom = geom,
        .window = window,
        .title_invalidated = title_invalidated,
        .force_rebuild = false,
    });
}

// Public API — segmented carousel

/// Render the focused window's title for a split-view segment.
///
/// Returns true when a carousel blit was performed; false when the text fits
/// and the caller should draw it directly.
///
/// Same rebuild logic as drawScrollingTitle, plus the focus_signal
/// invalidation (set by notifyFocusChanged). Colour-only: re-rendered
/// in-place, scroll preserved.
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
        // Text fits — free any live seg-carousel so the tick fast-path can't
        // blit stale scrolling content over the static text the caller draws.
        deinitSegmentedCarousel();
        return false;
    }

    // Consume the focus-change signal atomically.
    const force_rebuild = focus_signal.is_invalidated.swap(false, .acq_rel);

    const rebuilt = try commitCarouselFrame(&render.seg, dc, .{
        .text = text,
        .text_w = text_w,
        .bg = accent,
        .fg = text_fg,
        .baseline_y = baseline_y,
        .geom = geom,
        .window = window,
        .title_invalidated = title_invalidated,
        .force_rebuild = force_rebuild,
    });
    // Publish the window atomically after a rebuild so notifyFocusChanged on the
    // main thread can check it without touching render.seg.
    if (rebuilt) focus_signal.seg_window.store(window, .release);
    return true;
}

// Private — shared rebuild/recolour/blit step

/// Copy the entry's current frame into the bar's offscreen pixmap and flush
/// it to screen.
///
/// The flush is skipped while the main thread holds the X server grab:
/// xcb_flush would release grab-batch requests mid-grab, splitting one atomic
/// frame. The enqueued copy_area rides along with the closing ungrabAndFlush.
/// Used by every blit site (tick fast-paths and rebuild/colour commits) so
/// the grab handling stays consistent.
fn blitOneFrame(e: *CarouselEntry, dc: *drawing.DrawContext, geom: SegmentGeometry) void {
    e.cp.blitFrame(dc.offscreen_pixmap, dc.gc, geom.seg_x, e.pixel_offset, geom.seg_w);
    if (!utils.isGrabActive()) dc.blitAndFlush(geom.seg_x, geom.seg_w);
}

/// Publish a freshly-built entry: set the atomic `active` mirror and wake the
/// carousel thread so the scroll starts on the next refresh, not at the end of
/// the idle interval. Call while holding draw_mutex; safe before startThread().
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

/// The render parameters for one carousel frame commit. Bundled so
/// commitCarouselFrame takes three arguments instead of eleven, and so the two
/// call sites (single-window and segmented) can't reorder/omit arguments.
const CarouselFrame = struct {
    text: []const u8,
    text_w: u16,
    bg: u32,
    fg: u32,
    baseline_y: u16,
    geom: SegmentGeometry,
    window: ?u32,
    title_invalidated: bool,
    force_rebuild: bool,
};

/// Rebuilds, recolours, or blits the current frame into `slot` as needed and
/// flushes it to the screen. Returns true when a full pixmap rebuild was done,
/// false when the existing frame was recoloured/blitted in place.
fn commitCarouselFrame(
    slot: *?CarouselEntry,
    dc: *drawing.DrawContext,
    frame: CarouselFrame,
) !bool {
    const cycle_w: u16 = frame.text_w + carousel_gap_px;

    // Determine whether a full pixmap rebuild is needed (geometry/identity/
    // focus changed) vs. an in-place colour update vs. no action.
    const geom_stale = frame.force_rebuild or if (slot.*) |*e| entryStale(e, frame.window, frame.title_invalidated, cycle_w, frame.geom) else true;

    if (geom_stale) {
        // Full rebuild: build the new pixmap before freeing the old one so a
        // failed build keeps the previous pixmap live (the scroll continues on
        // the old frame) instead of dropping to a blank segment.
        const new_entry = try buildCarouselEntry(dc, frame.text, frame.bg, frame.fg, frame.baseline_y, frame.geom, cycle_w, frame.window);
        if (slot.*) |*old| old.cp.deinit();
        slot.* = new_entry;
        publishActive();
        const e = &slot.*.?;
        _ = advanceCarouselOffset(e, e.last_ns);
        blitOneFrame(e, dc, frame.geom);
        return true;
    }

    const e = &slot.*.?;

    if (e.last_bg != frame.bg or e.last_fg != frame.fg) {
        // Colour-only change: re-render into the existing pixmap without
        // freeing or reallocating it, preserving the scroll position.
        try e.cp.render(dc, frame.text, frame.bg, frame.fg, frame.baseline_y, leftPadOf(frame.geom), cycle_w);
        e.last_bg = frame.bg;
        e.last_fg = frame.fg;
    }

    _ = advanceCarouselOffset(e, utils.monotonicNs());
    blitOneFrame(e, dc, frame.geom);
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
    // The blit window is always [O, O + seg_w) with O in [0, cycle_w), so
    // pixels past cycle_w + seg_w are never read; copy B clips at the pixmap
    // edge when the title is wider than the segment, always in bounds. A full
    // second copy would hold unread text — roughly double pixmap memory.
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
/// Advances `e.pixel_offset` by the correct integer pixel count for the
/// elapsed time since the last blit, carrying the fractional remainder in
/// `e.frac_acc` for the next tick.
///
/// This distributes 0 px and 1 px advances evenly across frames rather than
/// clustering the fractional debt into occasional jumps: at 125 px/s on
/// 165 Hz the raw advance is ≈0.758 px/frame, and flooring each frame would
/// freeze every ~4–5 frames then snap 1 px.
///
/// Caller must hold a mutable pointer to the entry.
fn advanceCarouselOffset(e: *CarouselEntry, now_ns: u64) u16 {
    std.debug.assert(e.cycle_w > 0);
    const delta_ns = @as(f64, @floatFromInt(now_ns -| e.last_ns));
    // Accumulate exact sub-pixel advance for this tick plus any carry.
    const delta_px = delta_ns * scroll_config.speed.load(.monotonic) / 1_000_000_000.0 + e.frac_acc;
    const int_px = @floor(delta_px);
    e.frac_acc = delta_px - int_px; // carry remainder to next tick
    e.last_ns = now_ns;

    // Reduce modulo cycle_w in float *before* casting to an integer: under
    // normal ticking int_px is 0 or 1 (no-op), but after a long stall
    // (descheduled thread, suspend) it can exceed u32 and @intFromFloat would
    // overflow (trap in safe builds, UB otherwise). Only the wrapped remainder
    // affects pixel_offset, so reducing first is exactly equivalent.
    const cycle_w_f: f64 = @floatFromInt(e.cycle_w);
    const wrapped_advance: u32 = @intFromFloat(@mod(int_px, cycle_w_f));
    e.pixel_offset = @truncate((@as(u32, e.pixel_offset) + wrapped_advance) % @as(u32, e.cycle_w));
    return e.pixel_offset;
}
