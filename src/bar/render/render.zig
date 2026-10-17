//! Draw submission, the paint pass, and the scoped-repaint skeleton: the
//! full-bar draw (`performDraw`), the blocking full draw used across bar
//! replacement, the whole-bar dirty request, the grab-safe redraw, the
//! region-scoped single-slot repaints (drag/scroll sweep, clock-tick
//! reflow), the clock-only tick, the module redraw-request fold -- plus the
//! frame's solve/paint halves (`drawAllInner`, `solveRowPlan`,
//! `paintRowPlan` and friends) and the per-frame live-state collection
//! (`scanLiveFrame`/`fillDrawCtx`). This file decides WHEN to paint,
//! collects the frame facts to paint, and then paints them.
//!
//! This file reads the state through `state.zig`, never through `bar.zig`.
//! `bar.zig` imports this file to submit draws, so importing it back would
//! be a cycle; the state lives in its own leaf so both files can read it
//! with no edge between them.

const std = @import("std");
const build_options = @import("build_options");
const drawing = @import("drawing");
const focus = @import("focus");
const log = std.log.scoped(.render);
const pipeline = @import("pipeline");
const model = @import("model");
const reconcile = @import("reconcile");
const query = @import("query");
const contract = @import("bar_contract");
const center_row = @import("center_row");
const segmod = @import("segment");
const title_cache = @import("title_cache");
const window = @import("window");
const state = @import("state");

const center_slot_ids = segmod.center_slot_ids;

const State = state.State;
const SegBound = state.SegBound;
const max_click_bounds = state.max_click_bounds;
const self_ticking_ids = segmod.self_ticking_ids;

// Live-state collection
//
// Reads the workspace/window model, title cache and minimized set into the
// bar's frame scratch, plus the hidden-set synthesis thunk. Pure model reads
// -- titles come from the WM-owned cache, geoms from the sync truth-rect --
// so no X11 and nothing to prefetch; the paint pass below consumes what
// these fill.

/// The hide-family provider bound to the generated window registry, resolved
/// once at file scope: the hidden-set synthesis and its collect dispatch
/// share one lookup (no module is ever named by the bar).
const collect_hidden_set = window.providerOf(.collectHiddenSet);

/// Fills the shared per-frame DrawCtx the bar hands to every segment's
/// draw hook, including the title snapshot slots.
pub fn fillDrawCtx(s: *State, ctx: *segmod.DrawCtx) void {
    ctx.frame = s.frame.frame;
    ctx.frame.workspace_has_windows = s.frame.ws_has_windows[0..s.frame.frame.workspace_count];
    // The minimized-state service is drawn from the window module registry
    // here (upfront, per frame) so the title segment need not name the
    // addon that owns it. No provider compiled in => empty api =>
    // scanLiveFrame no-ops.
    var minimized_api: segmod.MinimizedApi = .{};
    if (collect_hidden_set != null)
        minimized_api.collect = minimizedCollect;
    ctx.minimized_api = minimized_api;
    // Titles/geoms below come from the WM-owned title cache and the sync
    // truth-rect -- neither performs X11 work, so the draw path is
    // non-blocking and no positional batch exists to scramble. The backing
    // entries live on State, valid for the rest of the frame AND for
    // post-draw click handling through the cached `frame.last_ctx`.
    const entries = s.frame.entries[0..s.frame.entries_len];
    for (entries) |*e| {
        e.title = title_cache.peekTitle(e.window);
        e.geom = titleGeom(e.window, s.title_data.minimized.contains(e.window));
    }
    // Title of the minimized window, used in the single-window title case.
    var minimized_title: []const u8 = "";
    if (entries.len > 0 and s.title_data.minimized.contains(entries[0].window))
        minimized_title = entries[0].title;
    ctx.focused_window = focus.getFocused();
    // Copy, do not borrow: `peekTitle` returns a slice of the
    // cache's own storage, and this ctx outlives the draw through
    // `frame.last_ctx`. See focused_title_buf.
    if (ctx.focused_window) |fw| {
        const src = title_cache.peekTitle(fw);
        @memcpy(s.title_data.focused_title_buf[0..src.len], src);
        ctx.focused_title = s.title_data.focused_title_buf[0..src.len];
    } else {
        ctx.focused_title = "";
    }
    ctx.minimized_title = minimized_title;
    ctx.current_ws_entries = entries;
    ctx.minimized_set = &s.title_data.minimized;
}

/// Reads workspace/window state into the frame fields. Pure model reads:
/// no X11. The per-window titles/geoms are filled later (fillDrawCtx)
/// straight from the WM-owned title cache and the sync truth-rect, so
/// there is no fetch key to diff and nothing to prefetch.
pub fn scanLiveFrame(s: *State) void {
    const m = pipeline.state();
    // The minimized set feeds the title snapshot; the title addon owns the
    // synthesis, exposed through the cached DrawCtx api. Synthesizing
    // fresh each scan makes set membership equivalent to a live
    // per-window query.
    if (build_options.has_minimize) {
        if (s.title_data.minimized_api.collect) |f| f(m, &s.title_data.minimized, s.render.allocator);
    }
    if (build_options.has_workspaces) {
        s.frame.frame.workspace_count = @intCast(query.getWorkspaceCount());
        s.frame.frame.current_workspace = @intCast(m.current.index);
        s.frame.frame.is_all_view_active = m.all_view_active;
        @memset(&s.frame.ws_has_windows, false);
        s.frame.entries_len = 0;
        const cur_ws: model.WSId = model.WSId.fromIndex(s.frame.frame.current_workspace);
        const cur_bit: u64 = if (s.frame.frame.current_workspace < s.frame.frame.workspace_count)
            model.bit(cur_ws)
        else
            0;
        // OR-accumulate all window masks in a single pass, collecting the
        // current workspace's windows on the way.
        var combined_mask: u64 = 0;
        for (query.allWindowsInto(&s.snapshot)) |entry| {
            combined_mask |= entry.mask;
            if (cur_bit != 0 and model.maskedOn(entry.mask, cur_ws) and
                s.frame.entries_len < state.max_frame_windows)
            {
                // Id only: fillDrawCtx annotates title + geom before any
                // draw reads the entry.
                s.frame.entries[s.frame.entries_len] = .{
                    .window = entry.win,
                    .title = "",
                    .geom = null,
                };
                s.frame.entries_len += 1;
            }
        }
        for (0..s.frame.frame.workspace_count) |i| {
            s.frame.ws_has_windows[i] = model.maskedOn(combined_mask, model.WSId.fromIndex(i));
        }
    }
}

/// Canonical title-slot geometry for `win`: the off-screen sentinel while
/// minimized, else the sync truth-rect (floating anchor / last sent rect)
/// with the off-screen sentinel for windows that have never been placed
/// (parked/unsent) -- truth-rect first, sentinel fallback, with no
/// xcb_get_geometry round-trip.
fn titleGeom(win: u32, minimized: bool) ?model.Rect {
    if (minimized) return segmod.offscreen_rect;
    return reconcile.truthRect(pipeline.state(), win) orelse segmod.offscreen_rect;
}

/// Full hidden-set synthesis forwarded to the hide-family provider
/// (DrawCtx api signature).
fn minimizedCollect(
    m: *const anyopaque,
    set: *std.AutoHashMapUnmanaged(u32, void),
    allocator: std.mem.Allocator,
) void {
    const mm: *const model.Model = @ptrCast(@alignCast(m));
    if (collect_hidden_set) |wm|
        wm.collectHiddenSet.?(mm, set, allocator);
}

// State operations
//
// The `State` methods: damage bookkeeping, click-bound recording, clock
// scope and measurement. `state.zig` keeps only the data (plus
// `init`/`deinit`); these read and mutate it in place. Zig defines methods
// in the struct's own file, so they are free functions over `*State` here,
// and this file's call sites call them unqualified.

/// Dirty-bit read for a registry id (null: a name that does not resolve is
/// never dirty). The null check precedes the comptime guard so an
/// empty-registry build never reaches `unreachable`.
inline fn segDirty(self: *const State, id: ?usize) bool {
    const i = id orelse return false;
    if (comptime !segmod.hasRegisteredSegments()) unreachable;
    return self.dirty.segments[i];
}

/// Position of `id` within `self_ticking_ids` (the key into
/// `Clock.segs`), or null when it is not a self-ticking segment.
fn selfTickerIndex(id: ?usize) ?usize {
    return segmod.roleIndexOf(id, self_ticking_ids);
}

/// Flags a full redraw: dirty flag + every segment slot (the
/// background-clear trigger).
pub fn markDirty(self: *State) void {
    self.dirty.flag = true;
    @memset(&self.dirty.segments, true);
}

/// Clears the dirty bit of the segment at registry id `id`; a null id
/// (a name that no longer resolves) has no bit to clear.
pub fn clearSegmentDirty(self: *State, id: ?usize) void {
    const i = id orelse return;
    if (comptime !segmod.hasRegisteredSegments()) unreachable;
    self.dirty.segments[i] = false;
}

/// Extends the current draw's dirty span to cover [x, x + w).
/// Called for every repainted segment + gap so the blit copies only
/// the region that actually changed.
pub inline fn extendDirtySpan(self: *State, x: u16, w: u16) void {
    if (w == 0) return;
    // Accumulate the span arithmetic in u32 so a large segment stack can't
    // wrap span_x/span_w past 65535; clamp on the way back into the u16
    // fields. Identical results for sane values.
    const x32: u32 = x;
    const w32: u32 = w;
    if (self.dirty.span_w == 0) {
        self.dirty.span_x = x;
        self.dirty.span_w = w;
    } else {
        const end: u32 = @as(u32, self.dirty.span_x) + self.dirty.span_w;
        const new_end: u32 = x32 + w32;
        if (x < self.dirty.span_x) self.dirty.span_x = x;
        if (new_end > end) {
            const new_w: u32 = new_end - @as(u32, self.dirty.span_x);
            self.dirty.span_w = @intCast(@min(new_w, std.math.maxInt(u16)));
        }
    }
}

/// Clears a horizontal region to the bar background and extends the dirty
/// span to cover it: the shared repaint idiom for every segment region
/// (including the full-redraw path, where `x = 0, w = width`).
pub fn clearRegion(self: *State, x: u16, w: u16) void {
    self.render.dc.fillRect(x, 0, w, self.render.height, state.renderBar().bg);
    extendDirtySpan(self, x, w);
}

/// Marks dirty every segment whose declared `dirty_sources` has bit
/// `source` set, and flags the bar dirty. Name-free: the bit masks are a
/// declared contract capability, not a name-keyed lookup.
pub fn markDirtySource(self: *State, source: segmod.DirtySourcesSource) void {
    self.dirty.flag = true;
    for (segmod.all(), 0..) |m, i| {
        if (segmod.hasSource(m.dirty_sources, source)) self.dirty.segments[i] = true;
    }
}

/// True when the segment must be repainted on this draw: its dirty bit
/// is set, or it declares the self-animated repaint capability and its
/// runtime query reports active (e.g. a scrolling marquee: the motion
/// only advances while the segment is drawn, so change detection must
/// not skip it). Uniform: resolved by registry, never by segment name.
/// A name that does not resolve (null) is never repaintable.
pub fn isSegmentRepaintable(self: *const State, id: ?usize) bool {
    const i = id orelse return false;
    if (segDirty(self, id)) return true;
    if (segmod.segmentAt(i).needsRepaint) |q| return q();
    return false;
}

/// True when every registry slot is dirty (the complete-background-clear
/// trigger). Non-configured segments (e.g. the prompt overlay) are never
/// drawn and never cleared, so an all-dirty set only occurs on a folded
/// full-redraw request.
pub fn isFullDirty(self: *const State) bool {
    for (self.dirty.segments) |d| {
        if (!d) return false;
    }
    return true;
}

/// True when a full redraw (every segment) is pending: the whole-bar flag
/// AND every slot dirty. A partial wake (a markDirtySource subset or the
/// drag hold) sets the flag without the full set, so a region-scoped
/// repaint can still run; only genuine full requests pass this.
pub fn pendingFullRedraw(self: *const State) bool {
    return self.dirty.flag and isFullDirty(self);
}

/// Scans the configured layout tree, returning true as soon as a segment
/// matches `pred`. Layout-rendered segments only: the overlay-only prompt
/// slot is excluded (its dirty flag is never cleared, so a registry-wide
/// scan would always match and defeat the fast-path early-exit). The
/// layout stores names; the predicate takes a resolved id, so each name
/// is resolved exactly once here instead of once per predicate.
inline fn anyLayoutSegment(self: *const State, comptime pred: anytype) bool {
    for (state.renderBar().layout.items) |lay| {
        for (lay.segments.items) |seg| {
            if (pred(self, segmod.segId(seg))) return true;
        }
    }
    return false;
}

/// True when the next draw would repaint at least one layout-rendered
/// segment: a dirty flag or a live needsRepaint hook (the title marquee).
pub fn hasPendingRepaintWork(self: *const State) bool {
    return anyLayoutSegment(self, isSegmentRepaintable);
}

/// True when any layout-rendered segment carries a set dirty bit (as
/// opposed to only a self-animated needsRepaint hook). A dirty bit means
/// the facts backing the drawn content changed, so the frame must be
/// rescanned and the DrawCtx refilled before drawing; when no dirty bit is
/// set and !dirty.flag, the only pending work is a marquee/overlay
/// needsRepaint hook and the cached last_ctx snapshot is still accurate.
pub fn hasLayoutSegmentDirty(self: *const State) bool {
    return anyLayoutSegment(self, segDirty);
}

/// Records the on-screen bounds of a clickable segment as the layout pass
/// positions it, so handleButtonPress can hit-test against them without
/// redoing the layout. Called unconditionally for every slot; a segment
/// whose module declares `clickable == false`, or whose name does not
/// resolve (null), is skipped.
pub fn recordClickBound(self: *State, id: ?usize, x: u16, w: u16) void {
    const i = id orelse return;
    if (!segmod.segmentAt(i).clickable) return;
    if (self.clicks.len >= max_click_bounds) return;
    self.clicks.bounds[self.clicks.len] = .{ .id = i, .x = x, .w = w };
    self.clicks.len += 1;
}

pub fn recordedBound(self: *const State, id: usize) ?SegBound {
    for (self.clicks.bounds[0..self.clicks.len]) |b| {
        if (b.id == id) return b;
    }
    return null;
}

/// Measures a segment's natural (reserved) width via its uniform
/// naturalWidth hook, or 0 for an unknown/removed segment name (null id).
pub fn measureSegmentWidth(self: *State, frame: *const segmod.Frame, id: ?usize) u16 {
    return segmod.naturalWidthOf(id, frame, self.clock.width);
}

/// Records the last layout-pass bound of a self-ticking segment so its
/// end-of-batch tick can region-scope a repaint (drawClockOnly). Written
/// for every configured self-ticker in ANY cluster (left/center/right);
/// unconfigured self-tickers stay invalid and are never repainted.
pub fn recordSelfTickerScope(self: *State, id: ?usize, x: u16, w: u16) void {
    // `comptime` on the length: with no self-ticking segment compiled in,
    // `Clock.segs` is a zero-length array and the indexed store below is
    // still analyzed, which is a compile error. The length is a comptime
    // constant, so this drops the whole body before it is analyzed.
    if (comptime self_ticking_ids.len == 0) return;
    if (selfTickerIndex(id)) |i| {
        // The solved slot width is threaded through (its naturalWidth hook
        // ran during the layout pass) rather than re-measured here: that
        // would run every self-ticker's hook twice per frame.
        self.clock.segs[i] = .{
            .x = x,
            .width = w,
            .valid = true,
        };
    }
}

/// Re-derives the merged clock display width from the live width probes and
/// adopts it, reporting whether it moved. Driven by a display-mode cycle:
/// the next row layout must reserve the incoming mode's span, and the
/// region-scoped tick blit cannot deliver that (it paints inside the
/// previously laid-out slot).
pub fn adoptFreshClockWidth(self: *State) bool {
    const fresh = center_row.mergedClockWidth(self.render.dc, state.renderBar(), self.render.height, drawing.DrawContext.measureTextWidthStyled);
    if (fresh == self.clock.width) return false;
    self.clock.width = fresh;
    return true;
}

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
    if (!s.dirty.flag and !hasPendingRepaintWork(s)) return;
    // Marquee/overlay-only wake. With nothing whole-bar
    // dirty, and no layout segment carrying a dirty bit, the only pending
    // repaint is a self-animated needsRepaint hook (the scrolling title or a
    // blinking caret). The frame facts backing the drawn content -- workspace
    // set, window list, titles, geoms, minimized set -- are unchanged since
    // the last full scan (any such change clears this gate via markDirty/
    // markDirtySource), so the cached post-draw last_ctx snapshot is still
    // accurate. Reuse it in place of scanLiveFrame + fillDrawCtx: those two
    // re-walk query.allWindowsInto() and rebuild the title/minute snapshot on
    // every marquee tick, and the marquee advances 60x/sec.
    if (!s.dirty.flag and s.frame.ctx_valid and
        !hasLayoutSegmentDirty(s))
    {
        var ctx = s.frame.last_ctx;
        drawAllInner(s, &ctx);
        s.frame.last_ctx = ctx;
        if (s.dirty.span_w > 0)
            s.render.dc.queueBlit(s.dirty.span_x, s.dirty.span_w);
        return;
    }
    scanLiveFrame(s);

    // Titles/geoms are read from in-process caches (title_cache + sync
    // truth-rect) with no X11 round-trip, so every frame renders inline:
    // there is no async prefetch to fire, defer, or commit.
    var ctx = frameCtx(s);
    fillDrawCtx(s, &ctx);
    drawAllInner(s, &ctx);
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
    markDirty(s);
    performDraw();
}

/// Requests the next draw to repaint every segment and mark the whole bar
/// dirty. Used by paths that need a full background-clear repaint (layout
/// facts, module redraw requests, bar re-anchoring).
pub fn requestFullRedraw() void {
    if (state.gBar.state) |s| markDirty(s);
}

/// Folds queued module redraw requests into the dirty state as a full
/// redraw (flag + every slot). Returns true when at least one was pending.
/// Single shared fold for the poll wakeup, direct-submit, and X-batch paths
/// so no path can drop a request. One pass consumes EVERY pending request
/// (`segmod.foldBoolHook`), not just the first: the batched redraw loop
/// iterates per settle ROUND, so a per-module drain would spend one round
/// per module and push a multi-module first-paint settle into the cap.
pub fn foldModuleRedraw(s: *State) bool {
    if (!segmod.foldBoolHook(.consumeRedrawRequest)) return false;
    markDirty(s);
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
/// Title data is sourced from in-process caches (title_cache + sync truth-rect),
/// so no frame blocks or defers under the grab: a click-triggered redraw here
/// is as cheap as any other frame.
pub fn redrawInsideGrab() void {
    const s = state.gBar.state orelse return;
    if (!s.vis.shown) return;
    if (pendingFullRedraw(s)) return;
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
    if (pendingFullRedraw(s)) return;
    const tb = recordedBound(s, id) orelse return;
    redrawSlotScoped(s, id, tb.x, tb.w, tb.w, false);
}

/// Shared region-scoped single-slot repaint skeleton: clear the reserved
/// slot, re-draw the segment, then blit at least what was painted
/// (`drawn_w` can exceed the reserved width after font fallback or
/// digit-width drift: blitting only the cached width would clip digits)
/// while covering the full reserved slot so stale pixels from a wider
/// earlier frame get overwritten with the clean background just painted.
/// `pinned_w` pins the reserved width into the ctx exactly like a layout
/// pass draw (null = draw unmeasured); `flush_blit` picks the immediate
/// blitRegion+flush (timer-driven clock path -- no event-loop flush is
/// coming) vs queueBlit (event-loop batch, no flush).
fn redrawSlotScoped(s: *State, id: usize, x: u16, bound_w: u16, pinned_w: ?u16, flush_blit: bool) void {
    if (segmod.segmentAt(id).draw == null) return;
    // Clear the whole reserved slot first: a display-mode shrink paints less
    // than the reservation, and the leftover region must show clean
    // background (not the previous wider frame's content) for the blit.
    clearRegion(s, x, bound_w);
    var ctx = frameCtx(s);
    // Shared harness: catches/logs draw errors, and a segment that painted
    // nothing (an error, or genuinely nothing to show) reports width 0, which
    // must skip the blit below. The segment states that rather than the bar
    // inferring it from an unchanged x.
    const drawn = drawSegment(s, &ctx, id, x, pinned_w);
    if (!drawn.drew) return;
    const drawn_w: u16 = drawn.painted.width;
    if (flush_blit) {
        s.render.dc.blitRegion(x, @max(bound_w, drawn_w));
    } else {
        s.render.dc.queueBlit(x, @max(bound_w, drawn_w));
    }
    clearSegmentDirty(s, id);
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

// Row geometry and the paint pass
//
// `solveRowPlan` measures the frame into a `RowPlan`, `paintRowPlan` walks
// it in paint order, and `state.zig` keeps only the data (dirty bits, click
// bounds, clock scope) those read through `s`.

/// Scratch bound for the per-draw right-cluster segment widths. Right segments
/// are measured once into this buffer and reused for both the total-width
/// calculation and the draw; a config with more than this many right segments
/// falls back to re-measuring at draw time (layout math identical, no win).
const max_right_segments: usize = 16;

/// Cap on solved row slots in one frame.
///
/// The layout is RUNTIME config (`BarLayout.segments` is an ArrayList) and a
/// config may list the same segment in several layouts, so there is no
/// comptime ceiling to derive: this is a generous fixed bound, and overflow is
/// handled rather than trusted (see RowPlan.push). Generous on purpose -- the
/// alternative, a cap that silently dropped slots, would drop click bounds and
/// paints with no trace, and `plan.slots[0..len]` past the end is a panic in
/// Debug and out-of-bounds reads in ReleaseFast.
const max_row_slots: usize = 64;

/// Right-aligned cluster bookkeeping for one draw frame. Measures every
/// right-position segment once up front, deriving both the reserved width
/// (which left/center placement shrinks around) and the per-segment widths
/// the draw consumes. Falls back to measure-at-draw when the segment count
/// overflows `max_right_segments`.
const RightCluster = struct {
    /// Measured widths by position in the right cluster (concatenated right
    /// layouts, in order). Only the first `max_right_segments` are recorded.
    widths: [max_right_segments]u16 = undefined,
    /// Number of right segments encountered this frame.
    count: usize = 0,
    /// Running solve index, advanced per right layout so each layout reads
    /// its own slice of `widths`.
    ridx: usize = 0,
    /// u32 accumulator for `right_total`; saturates into the u16 on conversion.
    total_raw: u32 = 0,
    /// Scaled inter-segment spacing, cached by solve so the backward pass
    /// does not re-derive it per layout.
    scaled_spacing: u16 = 0,
    /// Continuation cursor across right layouts, so they lay out back-to-back
    /// rather than each restarting from the bar's right edge and overlapping
    /// the previous layout's pixels.
    right_x: u16 = 0,
};

/// One solved row slot: the geometry and the flags the paint pass needs,
/// with no draw call anywhere near it.
///
/// The split keeps geometry, hit-testing and painting apart: solve produces
/// these, and paint walks them, so adding a segment does not mean editing
/// one loop that measures it, records its click bound, scopes its ticker,
/// clears its region and draws it, all interleaved.
pub const RowSlot = struct {
    /// Registry id, resolved ONCE when the slot is pushed (the layout stores
    /// names; every downstream consumer -- measure, paint, click bound, dirty
    /// clear -- works on the id, so a name is never resolved twice in one
    /// frame). Null when the configured name does not resolve: an unknown or
    /// removed segment, reserved as a zero-width slot.
    id: ?usize = null,
    /// Reserved width, from the measure pass (or the center share).
    w: u16,
    /// Left edge of the reservation, SOLVED. Only set for right-cluster slots,
    /// where placement is purely measurement-derived and therefore final.
    /// Left/center slots deliberately leave it 0 and let paint thread its own
    /// cursor: their advance depends on the width a segment actually PAINTS,
    /// which is only known once it has been drawn (see paintRowPlan).
    x: u16 = 0,
    /// Center-slot segments carry no trailing gap.
    omit_gap: bool = false,
    /// Center-slot index, for the share arithmetic in the paint advance.
    center_idx: u16 = 0,
    /// Segment owns its pixels this frame (dirty or full redraw).
    repaintable: bool = false,
    /// Self-ticker: needs a scope recorded in whichever cluster it lands.
    self_ticking: bool = false,
    /// Right cluster (solved backwards), vs left/center (solved forwards).
    is_right: bool = false,
    /// First slot of its right LAYOUT. Right layouts butt against each other
    /// with no inter-layout gap, so the first slot of each one starts a fresh
    /// gap run: the slot to its left is in a different layout, and the
    /// inter-layout space is already accounted for in `right_total`.
    right_layout_start: bool = false,
};

/// The whole row's solved geometry for one frame, in PAINT order.
///
/// Paint order is the order slots must be drawn, not solve order: the right
/// cluster is measured forwards but painted right-to-left, so it is reversed
/// into paint order here rather than at draw time. Reversing once in solve is
/// what lets paint be a single flat loop with no backward cursor.
pub const RowPlan = struct {
    slots: [max_row_slots]RowSlot = undefined,
    len: usize = 0,
    /// The right cluster's reserved width, subtracted from left/center budgets.
    right_total: u16 = 0,
    /// Where the right cluster's left edge ended up; the continuation cursor
    /// shared across right layouts so they butt against each other.
    right_x: u16 = 0,
    /// Scratch for the right-cluster measure pass.
    cluster: RightCluster = .{},
    /// Latched once a slot was dropped, so the log is one line per frame
    /// instead of one per segment.
    overflowed: bool = false,

    /// Appends a solved slot. On overflow the slot is DROPPED and `len` is left
    /// alone, so `slots[0..len]` can never index past the array. Dropping is
    /// still wrong (that segment loses its paint and its click bound), so it is
    /// logged once per frame rather than swallowed.
    inline fn push(self: *RowPlan, slot: RowSlot) void {
        if (self.len >= max_row_slots) {
            if (!self.overflowed) {
                self.overflowed = true;
                log.warn("Best-effort op failed (bar solveRowPlan): {}", .{error.RowPlanOverflow});
            }
            return;
        }
        self.slots[self.len] = slot;
        self.len += 1;
    }
};

// Drawing

/// Warns on a draw failure and reports the position unchanged, so a broken
/// segment can't corrupt the layout.
/// One segment's draw result: what it painted, and whether that counts as
/// a paint. They differ only in the zero-width case, which is the whole
/// point of returning both (see contract.Painted).
const Drawn = struct {
    painted: contract.Painted,
    drew: bool,
};

/// An unknown or draw-less segment name: nothing was painted, and the
/// row falls back to the reservation.
inline fn reportDrewNothing(x: u16) contract.Painted {
    log.warn("Best-effort op failed (bar drawSegment): {}", .{error.DrewInvalidSegment});
    return contract.Painted.nothing(x);
}

/// Draws a segment by registry dispatch, catching and logging errors
/// instead of propagating them, and reports the width it actually painted
/// back to the segment.
///
/// The width handback and the painted/nothing decision live in
/// `segmod.finishDraw` rather than inline here: they are the
/// bar's post-draw policy, but testing them through this loop would need a
/// live DrawContext and an X connection, so in practice they would go
/// untested -- and a segment that forgets to record its own drawn width
/// stays locked onto its startup width with its neighbours overlapping it
/// forever, with no symptom but a bar that looks wrong.
/// `id` is the resolved registry index the layout pass already holds; a
/// null (a name that no longer resolves) paints nothing and reports the
/// fallback the row reserves.
fn drawSegment(s: *State, ctx: *segmod.DrawCtx, id: ?usize, x: u16, width: ?u16) Drawn {
    const i = id orelse return .{ .painted = reportDrewNothing(x), .drew = false };
    if (segmod.segmentAt(i).draw == null) return .{ .painted = reportDrewNothing(x), .drew = false };
    // The DrawCtx is shared mutable scratch: pin the reserved width into it
    // immediately before the draw so width-reading renderers (the title)
    // advance correctly. The name goes in the same way, so a module can
    // resolve its own themed colors (the slider's fill reads
    // segmentValueFg(name)) without the draw hook carrying a per-segment
    // argument.
    ctx.name = segmod.segmentAt(i).name;
    ctx.width = width orelse measureSegmentWidth(s, &ctx.frame, id);
    const painted = segmod.segmentAt(i).draw.?(ctx, x) catch |e| {
        log.warn("Best-effort op failed (bar drawSegment): {}", .{e});
        // A caught error is a broken segment, not a segment with nothing
        // to show: it painted nothing either way, but reporting it as a
        // zero-width PAINT would let the next layout collapse a slot that
        // only failed this once.
        return .{ .painted = contract.Painted.nothing(x), .drew = false };
    };
    return .{
        .painted = painted,
        .drew = segmod.finishDraw(segmod.segmentAt(i), painted),
    };
}

/// Draws one segment of a left-to-right row, painting the inter-segment gap
/// and advancing `x`. `w` is the reserved width; `omit_gap` suppresses the
/// gap after a title so the next segment sits flush (center layout).
/// Returns the new `x`.
fn drawRowSegment(
    s: *State,
    ctx: *segmod.DrawCtx,
    id: ?usize,
    x: u16,
    w: u16,
    omit_gap: bool,
    scaled_spacing: u16,
) u16 {
    const x_before = x;
    const drawn = drawSegment(s, ctx, id, x, w);
    const painted = drawn.painted;
    // The segment says whether it painted, instead of the bar guessing it
    // from "did you move x?". A successful zero-width draw (an absent
    // readout) and a caught error both end up here with width == 0, and
    // both correctly consume the whole reserved `w` so the next segment
    // leftward starts where the layout pass expects -- leaving x unchanged
    // would let it paint over this slot and desync the cluster.
    const drew = drawn.drew;
    // A real draw paints its trailing gap (omitted after the title so the
    // next center segment sits flush).
    if (drew and !omit_gap) paintGap(s, painted.end_x, scaled_spacing);
    return if (drew)
        painted.end_x + (if (omit_gap) 0 else scaled_spacing)
    else
        x_before + w;
}

fn paintGap(s: *State, gap_x: u16, scaled_spacing: u16) void {
    clearRegion(s, gap_x, scaled_spacing);
}

/// Repaints the bar into the off-screen pixmap. When every segment is
/// dirty (full redraw) the whole background is cleared once;
/// otherwise only the dirty segments' regions are repainted, leaving
/// unchanged pixels from the previous frame untouched.
/// Solves the frame's row geometry and paints it. The two halves talk
/// through one `RowPlan`: solve measures and pins every slot, paint
/// walks the plan in paint order. Nothing in solve draws, and nothing in
/// paint measures.
fn drawAllInner(s: *State, ctx: *segmod.DrawCtx) void {
    const r = &s.render;
    const is_full_redraw = isFullDirty(s);
    s.dirty.span_x = 0;
    s.dirty.span_w = 0;

    if (is_full_redraw) {
        clearRegion(s, 0, r.width);
    }

    var plan: RowPlan = .{ .right_x = r.width };
    solveRowPlan(s, ctx, &plan);
    paintRowPlan(s, ctx, &plan, is_full_redraw);
}

/// Measures the frame into `plan`: right-cluster widths and their backward
/// positions first (so left/center know how much room is gone), then the
/// left/center rows forwards. Records nothing on `s` -- the click and
/// ticker-scope bookkeeping belongs to paint, which is the only half that
/// knows a slot actually got drawn.
pub fn solveRowPlan(s: *State, ctx: *segmod.DrawCtx, plan: *RowPlan) void {
    const r = &s.render;
    const fr = &ctx.frame;
    const scaled_spacing = state.renderBar().scaledSpacing(r.height);
    plan.cluster.scaled_spacing = scaled_spacing;
    plan.cluster.right_x = r.width;

    // Right cluster: measure once, up front, for two reasons. Left/center
    // placement must shrink around the space it will occupy, and the draw
    // must not re-measure what solve already knows.
    for (state.renderBar().layout.items) |lay| {
        if (lay.position != .right) continue;
        for (lay.segments.items) |seg| {
            const w = measureSegmentWidth(s, fr, segmod.segId(seg));
            if (plan.cluster.count < max_right_segments) {
                plan.cluster.widths[plan.cluster.count] = w;
            }
            plan.cluster.count += 1;
            // u32: segment widths plus gaps can exceed u16 on a very wide
            // desktop, and this feeds a u16 field.
            plan.cluster.total_raw += @as(u32, w) + scaled_spacing;
        }
        if (lay.segments.items.len > 0) plan.cluster.total_raw -= scaled_spacing;
    }
    plan.right_total = @intCast(@min(plan.cluster.total_raw, std.math.maxInt(u16)));

    // Left/center rows, forwards. The center share is computed here because
    // it is geometry, not painting: the budget is `avail` minus whatever
    // the right cluster reserved AND whatever the preceding left/center
    // layouts will claim. This cursor tracks the CLAIM (reserved width plus
    // gap), which is what the next row's budget has to shrink around; the
    // painted cursor paint threads separately can differ by a segment that
    // over- or under-ran its reservation, and deliberately so, since a
    // click bound has to match the pixels rather than the plan.
    var claimed: u16 = 0;
    for (state.renderBar().layout.items) |lay| {
        switch (lay.position) {
            .left, .center => {
                // Space before the right cluster; saturating because a
                // pathological reservation must clamp at 0, not wrap.
                const avail = r.width -| claimed -| plan.right_total;
                const budget = center_row.centerRowBudget(lay, avail, scaled_spacing, fr, s.clock.width);
                const remaining = budget.remaining;
                const center_count = budget.center_count;
                var center_idx: u16 = 0;
                for (lay.segments.items) |seg| {
                    // One name -> id resolution per segment per frame;
                    // everything below (and in paint) reads the id.
                    const id = segmod.segId(seg);
                    const is_center = (lay.position == .center) and segmod.isRole(id, center_slot_ids);
                    // Center slots split the whole remaining budget evenly,
                    // left-to-right in config order, and stay contiguous
                    // (no gap) so duplicates cannot reach the right cluster.
                    const w: u16 = if (is_center)
                        center_row.centerShare(remaining, center_count, center_idx)
                    else
                        measureSegmentWidth(s, fr, id);
                    // Center slots are contiguous, so neither the claim
                    // nor the paint cursor adds a gap after one.
                    claimed = claimed +% w +% (if (is_center) 0 else scaled_spacing);
                    plan.push(.{
                        .id = id,
                        .w = w,
                        .omit_gap = is_center,
                        .center_idx = center_idx,
                        .repaintable = isSegmentRepaintable(s, id),
                        .self_ticking = segmod.isRole(id, self_ticking_ids),
                    });
                    if (is_center) center_idx += 1;
                }
            },
            .right => {
                // Backward layout, measured widths, across ALL right
                // layouts so they butt together with no inter-layout gap
                // (matching `right_total` above). Reversed into paint order
                // here so paint is a single forward loop.
                const start = plan.cluster.ridx;
                plan.cluster.ridx += lay.segments.items.len;
                const widths: ?[]const u16 = if (plan.cluster.count > max_right_segments)
                    null // overflowed the scratch: fall back to measure-at-draw
                else
                    plan.cluster.widths[start..][0..lay.segments.items.len];
                const n = lay.segments.items.len;
                var cur_x = plan.cluster.right_x;
                var pending_gap = false;
                var i = n;
                while (i > 0) {
                    i -= 1;
                    const id = segmod.segId(lay.segments.items[i]);
                    const seg_w = if (widths) |ws| ws[i] else measureSegmentWidth(s, fr, id);
                    // Saturating: a pathological width sum clamps at 0
                    // instead of wrapping into a rightward paint.
                    cur_x = cur_x -| seg_w;
                    if (pending_gap) cur_x = cur_x -| scaled_spacing;
                    plan.push(.{
                        .id = id,
                        .w = seg_w,
                        .x = cur_x,
                        .repaintable = isSegmentRepaintable(s, id),
                        .self_ticking = segmod.isRole(id, self_ticking_ids),
                        .is_right = true,
                        // Reverse order means the LAST index pushed is the
                        // leftmost, i.e. the one that starts the layout.
                        .right_layout_start = i == n - 1,
                    });
                    pending_gap = true;
                }
                plan.cluster.right_x = cur_x;
            },
        }
    }
}

/// Walks the solved plan in paint order and draws it. The loop is flat: the
/// backward right-cluster cursor is already baked into the plan's slot
/// positions.
pub fn paintRowPlan(s: *State, ctx: *segmod.DrawCtx, plan: *const RowPlan, is_full_redraw: bool) void {
    const scaled_spacing = state.renderBar().scaledSpacing(s.render.height);
    // Left/center advance, threaded separately from the plan's right-cluster
    // positions: a right slot's `x` is final, but a left/center slot's is
    // only where it started, because the draw can move the cursor.
    var x: u16 = 0;
    var pending_gap = false;

    s.clicks.len = 0;
    for (plan.slots[0..plan.len]) |slot| {
        // Right slots carry a solved x; left/center slots take the live
        // cursor. Both feed the same two recordings, which is why this is
        // the only place they are made: a self-ticker's scope and a
        // segment's click bound must agree with where the paint landed.
        //
        // Self-ticker scope is recorded in ANY cluster: drawClockOnly
        // depends on it regardless of where the clock is laid out.
        const slot_x = if (slot.is_right) slot.x else x;
        if (slot.self_ticking) recordSelfTickerScope(s, slot.id, slot_x, slot.w);
        recordClickBound(s, slot.id, slot_x, slot.w);

        if (!slot.repaintable) {
            // Not repaintable: the slot is reserved space only, and the
            // cursor still has to move past it. Plain `+=` on purpose: a
            // config that overflows u16 here is a config bug, and silently
            // saturating would hide it behind a wrong layout instead of a
            // loud failure.
            if (!slot.is_right) {
                x += slot.w;
                if (!slot.omit_gap) x += scaled_spacing;
            } else {
                pending_gap = true;
            }
            continue;
        }

        if (!is_full_redraw) {
            // The right cluster clears per segment; a left/center clear
            // also covers the trailing gap it is about to advance past.
            const clear_w = if (slot.is_right)
                slot.w
            else if (slot.omit_gap)
                slot.w
            else
                slot.w +| scaled_spacing;
            clearRegion(s, slot_x, clear_w);
        }

        if (slot.is_right) {
            // Right cluster, already positioned backwards by solve. A new
            // layout starts a fresh gap run: layouts are spaced by
            // `right_total`, not by a painted gap, so inheriting the
            // previous layout's pending gap would clear a second time.
            if (slot.right_layout_start) pending_gap = false;
            const drew = drawSegment(s, ctx, slot.id, slot.x, slot.w).drew;
            if (drew and pending_gap) paintGap(s, slot.x +| slot.w, scaled_spacing);
            // A failed draw still occupies its slot as empty space, so the
            // next leftward segment gets the same gap solve computed. That
            // uniformity is what keeps placement from desyncing next frame.
            pending_gap = true;
        } else {
            const x_before = x;
            x = drawRowSegment(s, ctx, slot.id, x, slot.w, slot.omit_gap, scaled_spacing);
            if (x != x_before) extendDirtySpan(s, x_before, x - x_before);
        }
        clearSegmentDirty(s, slot.id);
    }
}
