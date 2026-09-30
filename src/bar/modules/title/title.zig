//! Title bar segment
//! Displays the focused window title on the status bar, with a split view
//! when minimized windows are present.
//!
//! The title render/snapshot machinery and the `DrawCtx`/`Frame` vocabulary
//! live in `segment.zig` (shared across bar segments); this module only owns
//! the rendering of the title slot and the prompt overlay.

// The title reads no global state at all: config arrives per draw on the
// render context, and even the refresh rate is only *read* (the hz memo
// `bar.init` primes). A DRAW must not detect a refresh rate, because
// detection writes that shared memo.
const hz = @import("hz");

const types = @import("types");

const drawing = @import("drawing");
const segmod = @import("segment");
const geom = @import("geom");
const contract = @import("contract");
// The scrolling title addon (the carousel) binds its motion, cycle and
const time = @import("time");
// frame-pacing hooks to this contract; membership in the generated
// `title_subs` registry is driven by file presence alone, so this module
// never names it. Dropping carousel.zig just shortens `addons` and the title
// falls back to its real built-in static (ellipsis) rendering -- no stub.
/// The whole scroll decoration for one frame, as ONE value. Declared HERE, in
/// the contract, not in the extensor: the seam's shape must not depend on
/// whether carousel.zig is present, which is the whole point of the addon
/// registry.
///
/// The title used to call `offsetFor` for the offset and then separately ask
/// `scrollingActive` whether the scroll was live and call `cyclePx` for its
/// period -- three seam calls whose agreement was a cross-member invariant
/// nothing enforced, with `cyclePx` duplicated in the title so it could
/// re-derive the period from a width it had measured itself.
pub const Scroll = struct {
    /// Sub-pixel x offset for the title head (0 = resting position).
    off: f32,
    /// Period in px: the offset wraps at this, and the scrolled text run is
    /// [x0, x0 + cycle).
    cycle: f32,
    /// True while this frame produced live motion. Marquee frames repaint
    /// moving pixels whose data has not changed, so the title's needsRepaint
    /// hook forwards exactly this bit.
    active: bool,
};

pub const Scroller = struct {
    /// The whole scroll decoration for one frame, in one call: offset, cycle
    /// and the active bit. Three separate seam queries (offsetFor /
    /// scrollingActive / cyclePx) had to agree with each other across the
    /// seam boundary, and the title carried its own copy of cyclePx to make
    /// that possible.
    offsetFor: *const fn (win: u32, title: []const u8, text_w: u16, avail_w: u16, enabled: bool, speed_px_s: u16, now_ms: i64) Scroll,
    pivot: *const fn () void,
    pollDeadlineMs: *const fn (now_ms: i64, hz: f64) i32,
};
comptime {
    // The seam is a SINGLETON slot, and taking `addons[0]` said nothing about
    // that: a second `Scroller` addon was silently dropped while the registry
    // kept looking like a registry. One decorator composes; two need the seam
    // to become a capability query.
    if (@import("title_subs").addons.len > 1) @compileError(
        "title: at most one Scroller addon is supported; " ++
            "a second one would be silently dropped by the addons[0] slot",
    );
}
const scroller: ?Scroller = if (@import("title_subs").addons.len != 0)
    @import("title_subs").addons[0]
else
    null;
// The prompt overlays this slot when active: it binds a runtime-overlay
// value (contract.BarOverlay) on its Segment, which this module finds through
// the generated bar segment registry -- name-free, like every other registry
// capability. Nothing in the closed core names the overlay module.
const overlay: ?contract.BarOverlay = if (contract.providerOf(contract.Segment, @import("bar_modules").modules[0..], .overlay)) |m|
    m.overlay.?
else
    null;

fn overlayActive() bool {
    return if (overlay) |o| o.is_active() else false;
}

// The minimized-state service (set synthesis + per-window checks) is provided
// by the window module registry and forwarded through the shared DrawCtx by
// the bar; the title segment just reads `snapshot.minimized_set`.

const SegmentGeometry = struct {
    seg_x: u16,
    seg_w: u16,
    text_x: u16,
    avail_w: u16,
};

/// Fixed left indent applied inside every title cell, independent of
/// `scaledSegmentPadding`.
const title_lead_px: u16 = 4;

/// Shared body of all title draw entry points. Titles/geoms are read from the
/// snapshot (in-process caches populated by the bar); no X11 and no owned
/// buffers to free here.
fn drawInner(
    ctx: segmod.TitleRenderContext,
    snapshot: segmod.TitleSnapshot,
) !u16 {
    // No refresh-rate detection here: `bar.init` primes it once at startup, and
    // detection writes global state (the monitor's Hz memo every other segment
    // reads), so calling it from a DRAW made a render mutate the state the next
    // frame's pacing decision depends on. The field it needed is gone with it.
    const window_count = snapshot.current_ws_wins.len;
    // Empty workspace: fill the background and return the segment's end x.
    if (window_count == 0) {
        ctx.dc.fillRect(ctx.start_x, 0, ctx.width, ctx.height, ctx.config.bg);
        return ctx.start_x + ctx.width;
    }

    if (window_count == 1) {
        try drawSingleWindow(ctx, snapshot);
    } else {
        try drawSegmentedTitles(ctx, snapshot);
    }

    return ctx.start_x + ctx.width;
}

/// Render the title slot at `x` (its reserved width is in `ctx.width`),
/// delegating to the active prompt overlay when open.
fn renderTitle(ctx: *segmod.DrawCtx, x: u16) !u16 {
    return drawInner(
        ctx.titleRenderContext(x, ctx.width),
        ctx.titleSnapshot(),
    );
}

/// Draw a window resolved via DrawCtx as the single-window case.
fn drawSingleWindow(
    ctx: segmod.TitleRenderContext,
    snapshot: segmod.TitleSnapshot,
) !void {
    const single_win = snapshot.current_ws_wins[0];
    const is_minimized = snapshot.minimized_set.contains(single_win);
    const workspace_has_focus = snapshot.focused_window != null;

    const accent = accentFor(ctx.config, workspace_has_focus, is_minimized, ctx.config.bg);
    ctx.dc.fillRect(ctx.start_x, 0, ctx.width, ctx.height, accent);

    const baseline_y = ctx.dc.baselineY(ctx.height);
    const text_geom = titleTextGeom(ctx, ctx.start_x, ctx.width);

    if (is_minimized) {
        if (snapshot.minimized_title.len > 0)
            try drawFittedTitle(
                ctx,
                baseline_y,
                text_geom,
                single_win,
                snapshot.minimized_title,
                ctx.dc.measureTextWidth(snapshot.minimized_title),
                ctx.config.fg,
                false,
            );
        return;
    }

    if (snapshot.focused_title.len == 0) return;

    const fg = if (workspace_has_focus) ctx.config.selected_fg else ctx.config.fg;
    try drawFittedTitle(
        ctx,
        baseline_y,
        text_geom,
        single_win,
        snapshot.focused_title,
        ctx.dc.measureTextWidth(snapshot.focused_title),
        fg,
        workspace_has_focus,
    );
}

/// Draws the focused window's overflowing title as a marquee cell.
fn drawMarqueeCell(
    ctx: segmod.TitleRenderContext,
    baseline_y: u16,
    sg: SegmentGeometry,
    win: u32,
    txt: []const u8,
    text_w: u16,
    fg: u32,
    now: i64,
) void {
    if (scroller) |s| {
        const scroll = advanceScroll(
            s,
            win,
            txt,
            text_w,
            sg.avail_w,
            ctx.config.carousel_enabled,
            ctx.config.carousel_speed_px_s,
            now,
        );
        if (scroll.active) {
            const cycle = scroll.cycle;
            // Anchor the scroll at the padded text start (same spot static mode uses),
            // so enabling the carousel continues seamlessly from where the head sat.
            const x0: f64 = @as(f64, @floatFromInt(sg.text_x)) - scroll.off;
            ctx.dc.drawTextScrolled(
                sg.seg_x,
                sg.seg_w,
                baseline_y,
                .{ x0, x0 + cycle },
                txt,
                fg,
            );
            return;
        }
    }
    ctx.dc.drawTextEllipsis(sg.text_x, baseline_y, txt, sg.avail_w, fg);
}

/// Accent colour for a title segment: focused wins, then minimized, then the
/// unfocused fallback.
inline fn accentFor(
    config: types.BarConfig,
    is_focused: bool,
    is_minimized: bool,
    unfocused_fallback: u32,
) u32 {
    return if (is_focused)
        config.title_accent_color
    else if (is_minimized)
        config.title_minimized_accent
    else
        unfocused_fallback;
}

fn titleTextGeom(ctx: segmod.TitleRenderContext, seg_x: u16, seg_w: u16) SegmentGeometry {
    const scaled_padding = ctx.config.scaledSegmentPadding(ctx.height);
    return .{
        .seg_x = seg_x,
        .seg_w = seg_w,
        .text_x = seg_x + scaled_padding + title_lead_px,
        .avail_w = seg_w -| scaled_padding *| 2 -| title_lead_px,
    };
}

fn drawFittedTitle(
    ctx: segmod.TitleRenderContext,
    baseline_y: u16,
    sg: SegmentGeometry,
    window: u32,
    title: []const u8,
    text_w: u16,
    text_fg: u32,
    scroll_enabled: bool,
) !void {
    const now = time.monotonicMs();
    if (text_w <= sg.avail_w) {
        // Focused cell that no longer overflows: retire any active scroll so
        // the carousel state machine (and with it the poll deadline and the
        // needsRepaint query) stops requesting frames for a static cell.
        // Unfocused cells never touch the carousel: it tracks exactly one
        // cell per frame, the focused one.
        if (scroll_enabled) {
            if (scroller) |s| _ = advanceScroll(s, window, title, text_w, sg.avail_w, false, 0, now);
        }
        ctx.dc.drawText(sg.text_x, baseline_y, title, text_fg);
    } else if (scroll_enabled)
        drawMarqueeCell(ctx, baseline_y, sg, window, title, text_w, text_fg, now)
    else
        ctx.dc.drawTextEllipsis(sg.text_x, baseline_y, title, sg.avail_w, text_fg);
}

/// Renders one title segment per window in a horizontal split-view layout.
/// The gather (geom.gatherAndSortWindowInfos: build + sort up to max_visible_windows
/// entries) and the width pass (Pango measureTextWidth per non-focused cell)
/// are computed fresh each frame.
fn drawSegmentedTitles(
    ctx: segmod.TitleRenderContext,
    snapshot: segmod.TitleSnapshot,
) !void {
    const windows = snapshot.current_ws_wins;
    // The gather clamps to max_visible_windows internally; the snapshot list
    // is also built into the same bar-wide cap, so the count can never drift.
    if (windows.len == 0) return;

    var scratch: geom.GatherScratch = .{};
    const sorted = scratch.gather(snapshot, windows) orelse return;

    const window_count: u32 = @intCast(sorted.len);
    const baseline_y = ctx.dc.baselineY(ctx.height);
    const min_cell_w = ctx.config.scaledSegmentPadding(ctx.height) *| 2;

    for (sorted, 0..) |info, i| {
        const bounds = geom.segmentBounds(ctx.width, i, window_count);
        if (bounds.w == 0) continue;
        const segment_x = ctx.start_x + bounds.x;

        const is_focused_win = snapshot.focused_window == info.window;
        const accent = accentFor(
            ctx.config,
            is_focused_win,
            info.minimized,
            ctx.config.title_unfocused_accent,
        );
        ctx.dc.fillRect(segment_x, 0, bounds.w, ctx.height, accent);

        if (info.title.len == 0 or bounds.w <= min_cell_w) continue;

        const text_fg = if (is_focused_win) ctx.config.selected_fg else ctx.config.fg;
        try drawFittedTitle(
            ctx,
            baseline_y,
            titleTextGeom(ctx, segment_x, bounds.w),
            info.window,
            info.title,
            ctx.dc.measureTextWidth(info.title),
            text_fg,
            is_focused_win,
        );
    }
}

// Segment hooks

/// True while the last draw handed the slot to the prompt overlay. Latched
/// here so the overlay close can be noticed: the scroller saw no frames for
/// the whole session (pollTimeoutMs contributed none), so resuming without a
/// pivot would advance `last_frame_ms` across it and teleport the marquee.
var overlay_was_active: bool = false;

fn drawHook(ctx: *anyopaque, x: u16) !contract.Painted {
    const c = segmod.castDraw(ctx);
    if (overlay) |o| if (o.is_active()) {
        overlay_was_active = true;
        // The overlay returns advanced x, not a width report: it covers the
        // whole slot, so the span is the reserved width by construction. The
        // title declares no `onPainted` at all -- its reservation is
        // `title_min_width`, fixed by construction and never a function of
        // what painted -- so nothing is forwarded on the title's behalf.
        return contract.Painted.span(x, try o.draw(ctx, x));
    };
    // Overlay just closed after at least one overlay frame: pivot the
    // scroller's elapsed-time base so motion continues from the last shown
    // offset instead of catching the whole session in one frame.
    if (overlay_was_active) {
        overlay_was_active = false;
        if (scroller) |s| s.pivot();
    }
    return contract.Painted.span(x, try renderTitle(c, x));
}

fn onClickHook(ctx: *const contract.ClickCtx) bool {
    const active = overlayActive();
    if (ctx.is_right) {
        if (!active) if (overlay) |o| o.toggle();
    } else if (!active) {
        // `state` and `title_click` travel together: the trampoline needs the
        // same bar state this hook was handed.
        ctx.title_click(ctx.state, ctx.offset);
    }
    return true;
}

fn naturalWidthHook(_: *const contract.Frame, _: u16) u16 {
    return segmod.title_min_width;
}

fn pollTimeoutMsHook() i32 {
    // The prompt overlay covers the whole title slot while open (draw
    // delegates to it), so no scroller is visible; contribute no wakeup
    // instead of leaving it polling hidden pixels. The next visible draw
    // re-arms motion via offsetFor. The title owns this decision, so the
    // overlay never reaches into the scroller to pause it.
    if (overlayActive()) return -1;
    if (scroller) |s| return s.pollDeadlineMs(time.monotonicMs(), hz.detectedHz());
    return -1;
}

/// Repaint query for the bar's uniform frame loop (the Segment needsRepaint
/// capability). While the carousel is actively scrolling its motion only
/// advances while the title draw runs, so the bar must repaint this segment on
/// every draw submission even when change detection marks nothing dirty. While
/// the prompt overlay covers the slot, the marquee is hidden (draw delegation
/// routes around it) and the overlay's own pending repaints are forwarded
/// instead: the bar then repaints just this slot for a caret toggle rather
/// than forcing a whole-bar redraw.
fn needsRepaintHook() bool {
    if (overlay) |o| if (o.is_active()) return o.needsRepaint();
    return scroll_active;
}

/// The last frame's scroll-active bit, recorded from the single seam call.
/// This is the title's copy of what used to be an out-of-band `scrollingActive`
/// QUERY on the seam: the value now arrives together with the offset it
/// describes, and the title remembers it for the one consumer that is not a
/// draw (needsRepaintHook).
var scroll_active: bool = false;

/// The single point where the title talks to the scroller, so the active bit
/// cannot be recorded on the draw path and forgotten on the retire path.
fn advanceScroll(
    s: Scroller,
    win: u32,
    txt: []const u8,
    text_w: u16,
    avail_w: u16,
    enabled: bool,
    speed_px_s: u16,
    now_ms: i64,
) Scroll {
    const scroll = s.offsetFor(win, txt, text_w, avail_w, enabled, speed_px_s, now_ms);
    scroll_active = scroll.active;
    return scroll;
}

/// The bar fires this on every show (map). A marquee that was scrolling when
/// the bar hid must resume from its last shown offset rather than catching
/// the whole hidden gap in one frame (which would land it mid-cycle).
fn onBarShownHook() void {
    if (scroller) |s| s.pivot();
}

/// Fired by the bar when a reload invalidates every segment cache. Config is
/// about to change the scroller's own inputs (carousel speed, the bar's
/// padding, the cell's usable width), so the elapsed-time base is rebased
/// instead of integrated across the change: without this, a reload mid-scroll
/// produced one frame whose dt spanned the old and the new geometry at once.
fn invalidateReloadCachesHook() void {
    if (scroller) |s| s.pivot();
}

/// This module's bar-segment contribution (registry binding).
pub const module: @import("contract").Segment = .{
    .name = "title",
    .center_slot = true,
    .dirty_sources = .{ .focus = true, .frame = true },
    .needsRepaint = needsRepaintHook,
    .pollTimeoutMs = pollTimeoutMsHook,
    .naturalWidth = naturalWidthHook,
    .draw = drawHook,
    .onClick = onClickHook,
    .onBarShown = onBarShownHook,
    .invalidateReloadCaches = invalidateReloadCachesHook,
};
