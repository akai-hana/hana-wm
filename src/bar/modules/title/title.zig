//! Title bar segment: focused window title on the status bar, with a split
//! view when minimized windows are present. The title render/snapshot
//! machinery and the `DrawCtx`/`Frame` vocabulary live in `segment.zig`;
//! this module only owns the title slot and the prompt overlay.

// The title reads no global state: config arrives per draw on the render
// context, and even the refresh rate is only *read* (the hz memo `bar.init`
// primes). A DRAW must not detect a refresh rate, because detection writes
// that shared memo.
const hz = @import("hz");

const types = @import("types");
const bar_config = @import("bar_config");

const segmod = @import("segment");
const geom = @import("geom");
const vocab = @import("vocab");
const contract = @import("bar_contract");
const dispatch = @import("contract_dispatch");
// The scrolling title addon binds its hooks to this contract; membership in
// the generated `title_subs` registry is driven by file presence alone, so
// this module never names it. Dropping carousel.zig just shortens `addons`
// and the title falls back to static (ellipsis) rendering.
const core = @import("core");
/// The whole scroll decoration for one frame, as ONE value. Declared HERE,
/// in the contract, not in the extensor: this contract's shape must not
/// depend on whether carousel.zig is present.
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
    /// Offset, cycle and the active bit arrive together: the three must
    /// agree with each other across the addon boundary.
    offsetFor: *const fn (win: u32, title: []const u8, text_w: u16, avail_w: u16, enabled: bool, speed_px_s: u16, gap_px: u16, now_ms: i64) Scroll,
    pivot: *const fn () void,
    pollDeadlineMs: *const fn (now_ms: i64, hz: f64) i32,
};

/// The registry-facing spelling of this contract: build.zig types the
/// generated `title_subs` array through it, so the generated module
/// never names the concrete struct or a sibling's import alias.
pub const Binding = Scroller;
// The scroller is a SINGLETON slot, and taking `addons[0]` says nothing about
// that: a second `Scroller` addon would be silently dropped while the
// registry still looks like a registry. One decorator composes; two need the
// slot to become a capability query.
const subs = @import("title_subs").addons;
comptime {
    if (subs.len > 1) @compileError("title: at most one Scroller addon");
}
const scroller: ?Scroller = if (subs.len != 0) subs[0] else null;

/// The scroller's pivot, resolved once with the null check the three call
/// sites (overlay close, bar shown, reload) would otherwise each repeat.
fn noPivot() void {}
const pivot: *const fn () void = if (scroller) |s| s.pivot else noPivot;

// The prompt overlays this slot when active: it binds a runtime-overlay
// value (contract.BarOverlay) on its Segment, found through the generated bar
// segment registry -- name-free, like every other registry capability.
const overlay: ?contract.BarOverlay = if (dispatch.providerOf(contract.Segment, segmod.all(), .overlay)) |m|
    m.overlay.?
else
    null;

fn overlayActive() bool {
    return if (overlay) |o| o.is_active() else false;
}

const SegmentGeometry = struct {
    seg_x: u16,
    seg_w: u16,
    text_x: u16,
    avail_w: u16,
};

const title_lead_px: u16 = 4;

/// Shared body of all title draw entry points. Window entries are read from
/// the snapshot (in-process caches populated by the bar); no X11 and no
/// owned buffers to free. Infallible: every text and rect op on this path is.
fn drawInner(
    ctx: vocab.TitleRenderContext,
    snapshot: vocab.TitleSnapshot,
) u16 {
    // No refresh-rate detection here: `bar.init` primes it once at startup,
    // and detection writes global state, so calling it from a DRAW would
    // make a render mutate the state the next frame's pacing depends on.
    const window_count = snapshot.entries.len;
    if (window_count == 0) {
        ctx.dc.fillRect(ctx.start_x, 0, ctx.width, ctx.height, ctx.config.bg);
    } else if (window_count == 1) {
        drawSingleWindow(ctx, snapshot);
    } else {
        drawSegmentedTitles(ctx, snapshot);
    }
    return ctx.start_x + ctx.width;
}

fn drawSingleWindow(
    ctx: vocab.TitleRenderContext,
    snapshot: vocab.TitleSnapshot,
) void {
    const single_win = snapshot.entries[0].window;
    const is_minimized = snapshot.minimized_set.contains(single_win);
    const workspace_has_focus = snapshot.focused_window != null;

    const accent = accentFor(ctx.config, workspace_has_focus, is_minimized, ctx.config.title_unfocused_accent);
    ctx.dc.fillRect(ctx.start_x, 0, ctx.width, ctx.height, accent);

    const baseline_y = ctx.dc.baselineY(ctx.height);
    const text_geom = titleTextGeom(ctx, ctx.start_x, ctx.width);

    // A minimized cell shows its own title and never enters the carousel:
    // the two branches differ in fg (always `fg`, even on a focused
    // workspace) and in the scroll gate, so they are not one if/else.
    if (is_minimized) {
        // The minimized cell never consults the scroller, but a marquee the
        // pre-minimize focused frame left live would keep repainting. Hand
        // the scroller one retiring call (enabled=false) so it stops and
        // the poll deadline clears.
        if (scroller) |s| {
            const title_width = if (snapshot.minimized_title.len > 0) ctx.dc.measureTextWidth(snapshot.minimized_title) else 0;
            _ = s.offsetFor(
                single_win,
                snapshot.minimized_title,
                title_width,
                text_geom.avail_w,
                false,
                0,
                ctx.config.carousel_gap_px,
                core.monotonicMs(),
            );
            g.scroll_active = false;
        }
        if (snapshot.minimized_title.len > 0)
            drawFittedTitle(
                ctx,
                baseline_y,
                text_geom,
                single_win,
                snapshot.minimized_title,
                ctx.config.fg,
                false,
            );
        return;
    }

    if (snapshot.focused_title.len == 0) return;

    const fg = if (workspace_has_focus) ctx.config.selected_fg else ctx.config.fg;
    drawFittedTitle(
        ctx,
        baseline_y,
        text_geom,
        single_win,
        snapshot.focused_title,
        fg,
        workspace_has_focus,
    );
}

/// Draws the focused window's title: live marquee if it overflows and
/// scrolling is enabled, ellipsised title if it overflows and is not, plain
/// text if it fits. `text_w` is measured here because all three cases want
/// it and no caller could have it cheaper.
fn drawFittedTitle(
    ctx: vocab.TitleRenderContext,
    baseline_y: u16,
    sg: SegmentGeometry,
    window: u32,
    title: []const u8,
    text_fg: u32,
    scroll_enabled: bool,
) void {
    const text_w = ctx.dc.measureTextWidth(title);
    const now = core.monotonicMs();

    // Unfocused cells never touch the carousel: it tracks exactly one cell
    // per frame, the focused one. For the focused cell the scroller is
    // consulted on BOTH outcomes -- scrolling when it still overflows, and
    // a retiring call (enabled=false) when it no longer does, so the state
    // machine and with it the poll deadline stop asking for frames.
    if (scroll_enabled) {
        if (scroller) |s| {
            const scroll = s.offsetFor(
                window,
                title,
                text_w,
                sg.avail_w,
                ctx.config.carousel_enabled and text_w > sg.avail_w,
                ctx.config.carousel_speed_px_s,
                ctx.config.carousel_gap_px,
                now,
            );
            // The scroller's one call carries the active bit, recorded here
            // for the one consumer that is not a draw (needsRepaintHook).
            g.scroll_active = scroll.active;
            if (scroll.active) {
                // Anchor at the padded text start (same spot static mode
                // uses), so enabling the carousel continues seamlessly.
                const x0: f64 = @as(f64, @floatFromInt(sg.text_x)) - scroll.off;
                ctx.dc.drawTextScrolled(
                    sg.seg_x,
                    sg.seg_w,
                    baseline_y,
                    .{ x0, x0 + scroll.cycle },
                    title,
                    text_fg,
                );
                return;
            }
        }
    }

    if (text_w <= sg.avail_w)
        ctx.dc.drawText(sg.text_x, baseline_y, title, text_fg)
    else
        ctx.dc.drawTextEllipsis(sg.text_x, baseline_y, title, sg.avail_w, text_fg);
}

/// Accent colour for a title segment: focused wins, then minimized, then the
/// unfocused fallback.
inline fn accentFor(
    config: bar_config.Config,
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

fn titleTextGeom(ctx: vocab.TitleRenderContext, seg_x: u16, seg_w: u16) SegmentGeometry {
    const scaled_padding = ctx.config.scaledSegmentPadding(ctx.height);
    return .{
        .seg_x = seg_x,
        .seg_w = seg_w,
        .text_x = seg_x + scaled_padding + title_lead_px,
        .avail_w = seg_w -| scaled_padding *| 2 -| title_lead_px,
    };
}

/// Renders one title segment per window in a horizontal split-view layout.
/// The gather and the width pass are computed fresh each frame.
fn drawSegmentedTitles(
    ctx: vocab.TitleRenderContext,
    snapshot: vocab.TitleSnapshot,
) void {
    // No empty-workspace guard here: `drawInner` has already dispatched the
    // zero case, so the gather cannot see an empty list from this path.
    var scratch: geom.GatherScratch = .{};
    const sorted = scratch.gather(snapshot) orelse return;

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
        drawFittedTitle(
            ctx,
            baseline_y,
            titleTextGeom(ctx, segment_x, bounds.w),
            info.window,
            info.title,
            text_fg,
            is_focused_win,
        );
    }
}

// Segment hooks

/// Owner state for the title segment (P2-58): `overlay_was_active` latches
/// the last draw handing the slot to the prompt overlay so the overlay close
/// can be noticed (resuming without a pivot would teleport the marquee).
/// `scroll_active` is the last frame's scroll-active bit, recorded from the
/// single scroller call, for the one consumer that is not a draw
/// (needsRepaintHook).
const TitleState = struct {
    overlay_was_active: bool = false,
    scroll_active: bool = false,
};
var g: TitleState = .{};

fn drawHook(ctx: *anyopaque, x: u16) !contract.Painted {
    if (overlay) |o| if (o.is_active()) {
        g.overlay_was_active = true;
        // The overlay returns advanced x, not a width report: it covers
        // the whole slot, so the span is the reserved width by construction.
        // The title declares no `onPainted` -- its reservation is
        // `title_min_width`, fixed by construction -- so nothing is
        // forwarded on the title's behalf.
        return contract.Painted.span(x, try o.draw(ctx, x));
    };
    // Overlay just closed after at least one overlay frame: pivot the
    // scroller's elapsed-time base so motion continues from the last shown
    // offset instead of catching the whole session in one frame.
    if (g.overlay_was_active) {
        g.overlay_was_active = false;
        pivot();
    }
    const c = segmod.castDraw(ctx);
    return contract.Painted.span(x, drawInner(c.titleRenderContext(x, c.width), c.titleSnapshot()));
}

fn onClickHook(ctx: *const contract.ClickCtx) bool {
    // An open overlay owns the slot: it swallows the click rather than
    // acting on the window underneath it.
    if (overlayActive()) return true;
    if (ctx.is_right) {
        if (overlay) |o| o.toggle();
    } else {
        // `state` and `title_click` travel together: the trampoline needs
        // the same bar state this hook was handed.
        ctx.title_click(ctx.state, ctx.offset);
    }
    return true;
}

fn naturalWidthHook(_: *const contract.Frame, _: u16) u16 {
    return segmod.title_min_width;
}

fn pollTimeoutMsHook() i32 {
    // The prompt overlay covers the whole title slot while open, so no
    // scroller is visible; contribute no wakeup instead of leaving it
    // polling hidden pixels. The next visible draw re-arms motion via
    // offsetFor. The title owns this decision, so the overlay never
    // reaches into the scroller to pause it.
    if (overlayActive()) return -1;
    if (scroller) |s| return s.pollDeadlineMs(core.monotonicMs(), hz.detectedHz());
    return -1;
}

/// Repaint query for the bar's uniform frame loop. While the carousel is
/// actively scrolling, motion only advances while the title draw runs, so
/// the bar must repaint this segment on every submission even when change
/// detection marks nothing dirty. While the prompt overlay covers the slot,
/// the marquee is hidden and the overlay's own pending repaints are
/// forwarded instead: the bar then repaints just this slot for a caret
/// toggle rather than forcing a whole-bar redraw.
fn needsRepaintHook() bool {
    if (overlay) |o| if (o.is_active()) return o.needsRepaint();
    return g.scroll_active;
}

/// This module's bar-segment contribution (registry binding).
pub const module = segmod.module(
    "title",
    drawHook,
    null,
    .{
        .mode = .self_measured,
        .center_slot = true,
        .dirty_sources = .{ .focus = true, .frame = true },
        .needsRepaint = needsRepaintHook,
        .pollTimeoutMs = pollTimeoutMsHook,
        .natural_width = naturalWidthHook,
        .on_click = onClickHook,
        // Both hooks rebase the scroller's elapsed-time clock at `pivot`,
        // for two different reasons, so the reasons live at `pivot` itself.
        // On show: a marquee that was scrolling when the bar hid resumes
        // from its last shown offset rather than catching the whole hidden
        // gap in one frame. On reload: config is about to change the
        // scroller's own inputs, so the base is rebased instead of
        // integrated across the change.
        .onBarShown = pivot,
        .invalidateReloadCaches = pivot,
    },
);
