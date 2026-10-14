//! Draw submission and the scoped-repaint skeleton: the full-bar draw
//! (`performDraw`), the blocking full draw used across bar replacement,
//! the whole-bar dirty request, the grab-safe redraw, the region-scoped
//! single-slot repaints (drag/scroll sweep, clock-tick reflow), the
//! clock-only tick, and the module redraw-request fold. The paint pass
//! itself -- `drawAllInner`, `solveRowPlan`, `paintRowPlan` and friends --
//! stays on `State`: this file decides WHEN to paint and WHAT to blit, the
//! State methods paint it.
//!
//! This file reads the state through `state.zig`, never through `bar.zig`.
//! `bar.zig` imports this file to submit draws, so importing it back would
//! be a cycle; the state lives in its own leaf so both files can read it
//! with no edge between them.

const segmod = @import("segment");
const state = @import("state");

const State = state.State;
const self_ticking_ids = state.self_ticking_ids;

/// Repaints every self-ticking segment whose on-screen content is stale
/// (second rolled over). Cheap region-scoped blits, one per ticker.
pub fn drawClockOnly(s: *State) void {
    // Same comptime guard as recordSelfTickerScope: the loop body indexes
    // `segs`, which is zero-length when nothing self-ticks.
    if (comptime self_ticking_ids.len == 0) return;
    for (self_ticking_ids, 0..) |cid, i| {
        const sc = s.clock.segs[i];
        if (!sc.valid) continue;
        redrawSlotScoped(s, cid, sc.x, sc.width, null, true);
    }
}

// Draw submission

/// Shared per-frame DrawCtx skeleton: dc/config/height/conn/allocator from the
/// live render context plus a defaulted frame. Callers fill the title-snapshot
/// slots afterward via `fillDrawCtx` (the clock-only path leaves them empty).
fn frameCtx(s: *State) segmod.DrawCtx {
    return .{
        .dc = s.render.dc,
        .config = state.renderBar(),
        .height = s.render.height,
        .conn = s.win.conn,
        .allocator = s.render.allocator,
        .frame = .{},
    };
}

/// Collects live state, repaints every segment into the off-screen pixmap,
/// and queues the single xcb_copy_area blit (cairo_surface_flush included,
/// xcb_flush NOT: the caller's context flushes (event-loop end-of-batch on
/// normal paths, ungrabAndFlush inside grabs).
pub fn performDraw() void {
    const s = state.gBar.state orelse return;
    if (!s.vis.shown) return;
    // Fold any queued module redraw request into a full dirty (flag +
    // every slot) -- the same gate the poll-wakeup and X-batch paths use -- so
    // a direct submitDraw can never drop it; the onPollWakeup / updateIfDirty
    // callers have typically already consumed, in which case this is a false
    // no-op.
    if (!s.dirty.flag) _ = foldModuleRedraw(s);
    // A timer-only wake with zero repaint work (nothing whole-bar dirty, no
    // segment dirty or needsRepaint) must not run the full
    // scan + measure pass. The clock's own repaint on the same wake is handled
    // separately by the region-scoped updateClock blit.
    if (!s.dirty.flag and !s.hasPendingRepaintWork()) return;
    // Marquee/overlay-only wake. With nothing whole-bar
    // dirty, and no layout segment carrying a dirty bit, the only pending
    // repaint is a self-animated needsRepaint hook (the scrolling title or a
    // blinking caret). The frame facts backing the drawn content -- workspace
    // set, window list, titles, geoms, minimized set -- are unchanged since
    // the last full scan (any such change clears this gate via markDirty/
    // markDirtySource), so the cached post-draw last_ctx snapshot is still
    // accurate. Reuse it in place of scanLiveFrame + fillDrawCtx: those two
    // re-walk tracking.allWindowsInto() and rebuild the title/minute snapshot on
    // every marquee tick, and the marquee advances 60x/sec.
    if (!s.dirty.flag and s.frame.ctx_valid and
        !s.hasLayoutSegmentDirty())
    {
        var ctx = s.frame.last_ctx;
        s.drawAllInner(&ctx);
        s.frame.last_ctx = ctx;
        if (s.dirty.span_w > 0)
            s.render.dc.queueBlit(s.dirty.span_x, s.dirty.span_w);
        return;
    }
    s.scanLiveFrame();

    // Titles/geoms are read from in-process caches (wincache + sync
    // truth-rect) with no X11 round-trip, so every frame renders inline:
    // there is no async prefetch to fire, defer, or commit.
    var ctx = frameCtx(s);
    s.fillDrawCtx(&ctx);
    s.drawAllInner(&ctx);
    // Cache the minimized-state service (built by fillDrawCtx from the window
    // module registry) so scanLiveFrame can synthesize the set each frame.
    // Guarded so an empty api still leaves the prior snapshot intact.
    if (ctx.minimized_api.collect != null) s.title_data.minimized_api = ctx.minimized_api;
    s.frame.last_ctx = ctx;
    s.frame.ctx_valid = true;
    // Only enqueue the dirty span: drawAllInner tracks the bounding x/w of
    // every repainted segment; skip the XCopyArea entirely when nothing
    // changed. No flush here (queueBlit), matching the grab-path contract.
    if (s.dirty.span_w > 0)
        s.render.dc.queueBlit(s.dirty.span_x, s.dirty.span_w);
    // A draw consumes the folded full request: clear the whole-bar flag so a
    // bare poll wake (module consume already drained) doesn't re-run a full
    // redraw. Segment dirty flags were cleared while painting.
    s.dirty.flag = false;
}

pub fn submitDrawBlockingFull() void {
    const s = state.gBar.state orelse return;
    s.markDirty();
    performDraw();
}

/// Requests the next draw to repaint every segment and mark the whole bar
/// dirty. Used by paths that need a full background-clear repaint (layout
/// facts, module redraw requests, bar re-anchoring).
pub fn requestFullRedraw() void {
    if (state.gBar.state) |s| s.markDirty();
}

/// Folds a queued module redraw request into the dirty state as a full
/// redraw (flag + every slot). Returns true when it consumed one. Single
/// shared fold for the poll wakeup, direct-submit, and X-batch paths so no
/// path can drop a request.
pub fn foldModuleRedraw(s: *State) bool {
    if (!state.anyBoolHook(.consumeRedrawRequest, .{})) return false;
    s.markDirty();
    return true;
}

/// Synchronous bar update safe to call inside xcb_grab_server.
///
/// Phase 1 (inside grab): render to the off-screen pixmap; queueBlit does
/// cairo_surface_flush and ENQUEUES xcb_copy_area without flushing, so the
/// compositor sees no intermediate frame.
/// Phase 2: the caller's ungrabAndFlush() sends configure_window +
/// copy_area + ungrab in one flush, producing exactly one compositor frame.
///
/// Title data is sourced from in-process caches (wincache + sync truth-rect),
/// so no frame blocks or defers under the grab: a click-triggered redraw here
/// is as cheap as any other frame.
pub fn redrawInsideGrab() void {
    const s = state.gBar.state orelse return;
    if (!s.vis.shown) return;
    if (s.pendingFullRedraw()) return;
    performDraw();
}

/// Phase-1 repaint of ONLY the segment `id` at its last recorded bound. A
/// press-hold drag or a scroll sweep mutates a single segment's pixels per
/// motion/event; a full performDraw would also relayout + repaint every
/// segment (and, for a subprocess-bound slider sub, stall the whole
/// bar). Mirrors redrawInsideGrab's contract: render to the off-screen pixmap
/// and queueBlit (no flush); the event-loop's end-of-batch xcb_flush ships it
/// to the server in one composite frame. The top-left clear + blit cover the
/// reserved slot even when the draw ran narrow.
fn redrawSegmentScoped(s: *State, id: usize) void {
    if (!s.vis.shown) return;
    if (s.pendingFullRedraw()) return;
    const tb = s.recordedBound(id) orelse return;
    redrawSlotScoped(s, id, tb.x, tb.w, tb.w, false);
}

/// Shared region-scoped single-slot repaint skeleton: clear the reserved
/// slot, re-draw the segment, then blit at least what was painted
/// (`drawn_end` can exceed the reserved width after font fallback or
/// digit-width drift: blitting only the cached width would clip digits)
/// while covering the full reserved slot so stale pixels from a wider
/// earlier frame get overwritten with the clean background just painted.
/// `pinned_w` pins the reserved width into the ctx exactly like a layout
/// pass draw (null = draw unmeasured); `flush_blit` picks the immediate
/// blitRegion+flush (timer-driven clock path -- no event-loop flush is
/// coming) vs queueBlit (event-loop batch, no flush).
pub fn redrawSlotScoped(s: *State, id: usize, x: u16, bound_w: u16, pinned_w: ?u16, flush_blit: bool) void {
    if (state.segAt(id).draw == null) return;
    // Clear the whole reserved slot first: a display-mode shrink paints less
    // than the reservation, and the leftover region must show clean
    // background (not the previous wider frame's content) for the blit.
    s.clearRegion(x, bound_w);
    var ctx = frameCtx(s);
    // Shared harness: catches/logs draw errors, and a segment that painted
    // nothing (an error, or genuinely nothing to show) reports width 0, which
    // must skip the blit below. The segment states that rather than the bar
    // inferring it from an unchanged x (21.7).
    const drawn = s.drawSegment(&ctx, id, x, pinned_w);
    if (!drawn.drew) return;
    const drawn_w: u16 = drawn.painted.width;
    if (flush_blit) {
        s.render.dc.blitRegion(x, @max(bound_w, drawn_w));
    } else {
        s.render.dc.queueBlit(x, @max(bound_w, drawn_w));
    }
    s.clearSegmentDirty(id);
}

/// Scoped repaint of the in-flight scrub/scroll target segment (`drag_segment`
/// for a button-1 drag motion, `scroll_segment` for an onScroll dispatch), so a
/// drag or fast wheel sweep never forces full-bar redraws. Used as the drag
/// motion `redraw` callback and the onScroll `redraw` callback.
pub fn redrawScopedSegment() void {
    const s = state.gBar.state orelse return;
    const id = s.drag_segment orelse s.scroll_segment orelse return;
    redrawSegmentScoped(s, id);
}
