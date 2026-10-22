//! Draw submission, the paint pass, and the scoped-repaint skeleton: the
//! full-bar draw (`performDraw`), the blocking full draw, the whole-bar
//! dirty request, the grab-safe redraw, the region-scoped single-slot
//! repaints, the clock-only tick, the module redraw-request fold -- plus
//! the frame's solve/paint halves and the per-frame live-state collection.
//! Decides WHEN to paint, collects the frame facts, then paints them.
//! Reads state through `state.zig`, never through `bar.zig` (a cycle).

const std = @import("std");
const build_options = @import("build_options");
const core = @import("core");
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
const window_facts = @import("window_facts");
const window = @import("window");
const state = @import("state");

const center_slot_ids = segmod.center_slot_ids;

const State = state.State;
const SegBound = state.SegBound;
const max_click_bounds = state.max_click_bounds;
const self_ticking_ids = segmod.self_ticking_ids;

// Live-state collection: reads the workspace/window model, title cache and
// minimized set into the frame scratch, plus the hidden-set synthesis thunk.

/// The hide-family provider bound to the generated window registry, resolved
/// once at file scope: synthesis and collect dispatch share one lookup.
const collect_hidden_set = window.hide.providerOf(.collectHiddenSet);

/// Fills the shared per-frame DrawCtx the bar hands to every segment's
/// draw hook, including the title snapshot slots.
pub fn fillDrawCtx(s: *State, ctx: *segmod.DrawCtx) void {
    ctx.frame = s.frame.frame;
    ctx.frame.workspace_has_windows = s.frame.ws_has_windows[0..s.frame.frame.workspace_count];
    // Minimized-state service drawn from the window module registry here
    // (upfront, per frame) so the title segment need not name the addon.
    var minimized_api: segmod.MinimizedApi = .{};
    if (collect_hidden_set != null)
        minimized_api.collect = minimizedCollect;
    ctx.minimized_api = minimized_api;
    // Titles/geoms come from the WM-owned title cache and the sync
    // truth-rect -- no X11 work, so the draw path is non-blocking.
    const entries = s.frame.entries[0..s.frame.entries_len];
    for (entries) |*e| {
        e.title = window_facts.peekTitle(e.window);
        e.geom = titleGeom(e.window, s.title_data.minimized.contains(e.window));
    }
    var minimized_title: []const u8 = "";
    if (entries.len > 0 and s.title_data.minimized.contains(entries[0].window))
        minimized_title = entries[0].title;
    ctx.focused_window = focus.getFocused();
    // Copy, do not borrow: `peekTitle` returns a slice of the cache's own
    // storage, and this ctx outlives the draw through `frame.last_ctx`.
    if (ctx.focused_window) |fw| {
        const src = window_facts.peekTitle(fw);
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
/// no X11.
pub fn scanLiveFrame(s: *State) void {
    const m = pipeline.state();
    // The minimized set feeds the title snapshot; the title addon owns the
    // synthesis, making set membership equal to a live per-window query.
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
/// minimized, else the sync truth-rect with the sentinel for windows never
/// placed (parked/unsent) -- no xcb_get_geometry round-trip.
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
        wm.hide.collectHiddenSet.?(mm, set, allocator);
}

// State operations: damage bookkeeping, click-bound recording, clock scope and
// measurement; `state.zig` keeps only the data (methods live in the struct).

/// Dirty-bit read for a registry id (null: a name that does not resolve is never
/// dirty). The null check precedes the comptime guard for empty-registry builds.
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

/// Extends the current draw's dirty span to cover [x, x + w). Called for
/// every repainted segment + gap so the blit copies only the region that
/// actually changed.
pub inline fn extendDirtySpan(self: *State, x: u16, w: u16) void {
    if (w == 0) return;
    // Accumulate in u32 so a large segment stack can't wrap span_x/span_w
    // past 65535; clamp on the way back into the u16 fields.
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

/// Marks dirty every segment whose declared `dirty_sources` has bit `source` set,
/// and flags the bar dirty. Name-free: bit masks are a contract capability.
pub fn markDirtySource(self: *State, source: segmod.DirtySourcesSource) void {
    self.dirty.flag = true;
    for (segmod.all(), 0..) |m, i| {
        if (segmod.hasSource(m.dirty_sources, source)) self.dirty.segments[i] = true;
    }
}

/// True when the segment must be repainted on this draw: its dirty bit is
/// set, or it declares the self-animated repaint capability and its runtime
/// query reports active (a scrolling marquee advances only while drawn, so
/// change detection must not skip it). Uniform: resolved by registry.
pub fn isSegmentRepaintable(self: *const State, id: ?usize) bool {
    const i = id orelse return false;
    if (segDirty(self, id)) return true;
    if (segmod.segmentAt(i).needsRepaint) |q| return q();
    return false;
}

/// True when every registry slot is dirty (the complete-background-clear
/// trigger). Non-configured segments (e.g. the prompt overlay) are never
/// drawn or cleared, so an all-dirty set only occurs on a folded full-redraw.
pub fn isFullDirty(self: *const State) bool {
    for (self.dirty.segments) |d| {
        if (!d) return false;
    }
    return true;
}

/// True when a full redraw (every segment) is pending. A partial wake sets
/// the flag without the full set, so a region-scoped repaint can still run.
pub fn pendingFullRedraw(self: *const State) bool {
    return self.dirty.flag and isFullDirty(self);
}

/// True when any layout segment matches `pred` (overlay excluded: its dirty
/// flag is never cleared). Names resolve once here, not per predicate.
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

/// True when any layout segment has a dirty bit (vs only a needsRepaint hook):
/// frame facts changed, so the next draw must rescan; without one last_ctx stays.
pub fn hasLayoutSegmentDirty(self: *const State) bool {
    return anyLayoutSegment(self, segDirty);
}

/// Records on-screen bounds for click hit-testing (skip: not clickable or
/// unresolvable name).
pub fn recordClickBound(self: *State, id: ?usize, x: u16, w: u16) void {
    const i = id orelse return;
    if (!segmod.segmentAt(i).clickable) return;
    if (self.clicks.len >= max_click_bounds) return;
    self.clicks.bounds[self.clicks.len] = .{ .id = i, .x = x, .w = w, .gen = self.layout_gen };
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

/// Records the last layout bound of a self-ticking segment so drawClockOnly
/// can region-scope its repaint. Unconfigured self-tickers stay invalid.
pub fn recordSelfTickerScope(self: *State, id: ?usize, x: u16, w: u16) void {
    // comptime guard: with no self-ticker, `Clock.segs` is zero-length and
    // the indexed store is a compile error.
    if (comptime self_ticking_ids.len == 0) return;
    if (selfTickerIndex(id)) |i| {
        // Solved slot width threaded through, not re-measured: that would
        // run naturalWidth twice per frame.
        self.clock.segs[i] = .{
            .x = x,
            .width = w,
            .valid = true,
            .gen = self.layout_gen,
        };
    }
}

/// Re-derives the merged clock width from live probes, reporting whether it moved
/// (a display-mode cycle: the next layout reserves the span; the tick blit cannot).
pub fn adoptFreshClockWidth(self: *State) bool {
    const fresh = center_row.mergedClockWidth(self.render.dc, state.renderBar(), self.render.height, drawing.DrawContext.measureTextWidthStyled);
    if (fresh == self.clock.width) return false;
    self.clock.width = fresh;
    return true;
}

/// Repaints every self-ticking segment whose content is stale. Cheap
/// region-scoped blits, one per ticker.
pub fn drawClockOnly(s: *State) void {
    if (comptime self_ticking_ids.len == 0) return;
    for (self_ticking_ids, 0..) |cid, i| {
        const sc = s.clock.segs[i];
        if (!sc.valid) continue;
        // P2-63 tripwire: tick paints at the scope's coords; an older
        // generation is a stale re-layout without re-record.
        std.debug.assert(sc.gen == s.layout_gen);
        redrawSlotScoped(s, cid, sc.x, sc.width, null, true);
    }
}

// Draw submission

/// Shared per-frame DrawCtx skeleton: live render context + defaulted frame.
/// Callers fill title-snapshot slots afterward via `fillDrawCtx`.
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
/// queues the single xcb_copy_area blit. No flush here (cairo_surface_flush
/// only): the caller's context flushes (end-of-batch, or ungrabAndFlush).
pub fn performDraw() void {
    const s = state.gBar.state orelse return;
    if (!s.vis.shown) return;
    // Fold any queued module redraw request into a full dirty so a direct
    // submitDraw can never drop it (false no-op when already consumed).
    if (!s.dirty.flag) _ = foldModuleRedraw(s);
    // A timer-only wake with zero repaint work must not run the full scan
    // + measure pass; the clock's repaint comes from the updateClock blit.
    if (!s.dirty.flag and !hasPendingRepaintWork(s)) return;
    // Marquee/overlay-only wake fast path: nothing whole-bar dirty, no
    // layout segment with a dirty bit -- only a self-animated needsRepaint
    // hook (scrolling title / blinking caret) is pending. Frame facts are
    // unchanged since the last full scan (any change clears this gate via
    // markDirty/markDirtySource), so last_ctx is accurate: reuse it. The
    // alternative re-walks query.allWindowsInto() on every marquee tick.
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

    // Titles/geoms from in-process caches (no X11 round-trip): every frame
    // renders inline, no async prefetch to commit.
    var ctx = frameCtx(s);
    fillDrawCtx(s, &ctx);
    drawAllInner(s, &ctx);
    // Cache the minimized-state service so scanLiveFrame can synthesize the
    // set each frame; empty api leaves the prior snapshot intact.
    if (ctx.minimized_api.collect != null) s.title_data.minimized_api = ctx.minimized_api;
    s.frame.last_ctx = ctx;
    s.frame.ctx_valid = true;
    // Only enqueue the dirty span; skip XCopyArea entirely when nothing
    // changed. No flush here (queueBlit), matching the grab-path contract.
    if (s.dirty.span_w > 0)
        s.render.dc.queueBlit(s.dirty.span_x, s.dirty.span_w);
    // A draw consumes the folded full request so a bare poll wake doesn't
    // re-run a full redraw; segment dirty flags cleared while painting.
    s.dirty.flag = false;
}

pub fn submitDrawBlockingFull() void {
    const s = state.gBar.state orelse return;
    markDirty(s);
    performDraw();
}

/// Requests the next draw to repaint every segment (full background-clear:
/// layout facts, module redraw requests, bar re-anchoring).
pub fn requestFullRedraw() void {
    if (state.gBar.state) |s| markDirty(s);
}

/// Folds queued module redraw requests into the dirty state; true when at
/// least one was pending. Single shared fold for the poll wakeup,
/// direct-submit, and X-batch paths so no path can drops a request. One pass
/// consumes EVERY pending request: the batched redraw loop iterates per
/// settle ROUND, so a per-module drain would push multi-module settles into
/// the cap.
///
/// D20 width-stable per-segment fast path: a request whose segment's
/// reservation is unchanged since last layout is a content-only repaint --
/// set just that segment's dirty bit so paintRowPlan runs with
/// is_full_redraw = false. A width change (or never laid out) escalates to
/// a full redraw: every downstream slot shifts and must repaint. Fact bumps
/// (markDirtySource) are a separate path, untouched here.
pub fn foldModuleRedraw(s: *State) bool {
    if (comptime !segmod.hasRegisteredSegments()) return false;
    var any = false;
    var width_changed = false;
    for (segmod.all(), 0..) |seg, i| {
        const cr = seg.consumeRedrawRequest orelse continue;
        if (!cr()) continue;
        any = true;
        // Width-stability read without consuming anything extra (the module's
        // hook drained it); a missing bound escalates so first paint is full.
        const cur = measureSegmentWidth(s, &s.frame.frame, @as(?usize, i));
        const rec = recordedBound(s, i);
        if (rec == null or rec.?.w != cur) {
            width_changed = true;
        } else {
            s.dirty.segments[i] = true;
        }
    }
    if (!any) return false;
    s.dirty.flag = true;
    if (width_changed) @memset(&s.dirty.segments, true);
    return true;
}

/// Synchronous bar update safe inside xcb_grab_server.
/// Phase 1 (inside grab): render to the off-screen pixmap; queueBlit does
/// cairo_surface_flush and ENQUEUES xcb_copy_area without flushing, so the
/// compositor sees no intermediate frame.
/// Phase 2: the caller's ungrabAndFlush() sends configure_window + copy_area +
/// ungrab in one flush = one frame. Title data comes from in-process caches.
pub fn redrawInsideGrab() void {
    const s = state.gBar.state orelse return;
    if (!s.vis.shown) return;
    if (pendingFullRedraw(s)) return;
    performDraw();
}

/// Phase-1 repaint of ONLY the segment `id` at its last recorded bound. A
/// drag/scroll mutates a single segment's pixels; a full performDraw would relayout
/// every segment (and, for a subprocess-bound slider, stall the bar). Mirrors
/// redrawInsideGrab: queueBlit, no flush; end-of-batch ships one composite frame.
fn redrawSegmentScoped(s: *State, id: usize) void {
    if (!s.vis.shown) return;
    if (pendingFullRedraw(s)) return;
    const tb = recordedBound(s, id) orelse return;
    // P2-63 tripwire: paints at the bound's coords; an older generation
    // is a stale re-layout without re-record -- a logic bug, never config.
    std.debug.assert(tb.gen == s.layout_gen);
    redrawSlotScoped(s, id, tb.x, tb.w, tb.w, false);
}

/// Shared region-scoped single-slot repaint skeleton: clear the reserved
/// slot, re-draw, then blit at least what was painted (`drawn_w` can exceed
/// the reservation after font fallback; the cached width alone would clip)
/// while covering the full reserved slot so stale pixels from a wider earlier
/// frame are overwritten. `pinned_w` pins the reserved width into the ctx
/// (null = draw unmeasured); `flush_blit` picks immediate blitRegion+flush
/// (timer-driven clock path) vs queueBlit (event-loop batch).
fn redrawSlotScoped(s: *State, id: usize, x: u16, bound_w: u16, pinned_w: ?u16, flush_blit: bool) void {
    if (segmod.segmentAt(id).draw == null) return;
    // Clear the whole reserved slot: a display-mode shrink paints less than
    // the reservation, and the leftover must show clean background.
    clearRegion(s, x, bound_w);
    var ctx = frameCtx(s);
    // Shared harness: catches/logs draw errors; a segment that painted nothing
    // reports width 0 and skips the blit, rather than the bar inferring it.
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

/// Scoped repaint of the in-flight scrub/scroll target (`drag_segment` or
/// `scroll_segment`), so a drag or wheel sweep never forces full-bar redraws.
pub fn redrawScopedSegment() void {
    const s = state.gBar.state orelse return;
    const id = s.drag_segment orelse s.scroll_segment orelse return;
    redrawSegmentScoped(s, id);
}

// Row geometry and the paint pass

/// Scratch for right-cluster widths; more segments than this fall back to
/// measure-at-draw (layout math identical).
const max_right_segments: usize = 16;

/// Cap on solved row slots. Runtime config has no comptime ceiling, so this is a
/// generous fixed bound; overflow drops + logs once per frame (RowPlan.push).
const max_row_slots: usize = 64;

const RightCluster = struct {
    widths: [max_right_segments]u16 = undefined,
    count: usize = 0,
    ridx: usize = 0,
    total_raw: u32 = 0,
    scaled_spacing: u16 = 0,
    right_x: u16 = 0,
};

/// One solved row slot: geometry + paint flags, no draw call near it. Solve
/// produces these, paint walks them: no interleaved measure/draw loop to edit.
pub const RowSlot = struct {
    /// Registry id resolved ONCE at push; null = unknown name, zero-width.
    id: ?usize = null,
    w: u16,
    /// SOLVED left edge (right cluster only; left/center leave it 0 and paint
    /// threads its own cursor -- advance depends on the width actually PAINTED.
    x: u16 = 0,
    omit_gap: bool = false,
    center_idx: u16 = 0,
    repaintable: bool = false,
    self_ticking: bool = false,
    is_right: bool = false,
    /// First slot of its right LAYOUT: starts a fresh gap run (the
    /// inter-layout space is already in `right_total`).
    right_layout_start: bool = false,
};

/// The whole row's solved geometry for one frame, in PAINT order. Right cluster
/// measured forwards but painted right-to-left, reversed here for one forward loop.
pub const RowPlan = struct {
    slots: [max_row_slots]RowSlot = undefined,
    len: usize = 0,
    right_total: u16 = 0,
    right_x: u16 = 0,
    cluster: RightCluster = .{},
    overflowed: bool = false,

    /// Appends a solved slot. On overflow the slot is DROPPED and `len` is left
    /// alone, so `slots[0..len]` can never index past the array; the drop loses
    /// that segment's paint and click bound, so it is logged once per frame.
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

/// One segment's draw result: what it painted + whether that counts as a paint.
/// They differ only in the zero-width case -- the point of returning both.
const Drawn = struct {
    painted: contract.Painted,
    drew: bool,
};

/// Unknown/draw-less name: nothing painted, row falls back to the reservation.
/// Warn rate-limited per segment id (P2-62): one per frame would drown a fault.
inline fn reportDrewNothing(x: u16, s: *State, id: ?usize) contract.Painted {
    if (s.drawFailLogDue(id, core.realtimeMs()))
        log.warn("Best-effort op failed (bar drawSegment): {}", .{error.DrewInvalidSegment});
    return contract.Painted.nothing(x);
}

/// Draws a segment by registry dispatch, catching and logging errors, and
/// reports the width it actually painted back to the segment.
///
/// The width handback and painted/nothing decision live in
/// `segmod.finishDraw`: testing them through this loop would need a live
/// DrawContext and X connection (untested in practice), and a segment that
/// forgets its drawn width stays locked onto its startup width.
fn drawSegment(s: *State, ctx: *segmod.DrawCtx, id: ?usize, x: u16, width: ?u16) Drawn {
    const i = id orelse return .{ .painted = reportDrewNothing(x, s, null), .drew = false };
    if (segmod.segmentAt(i).draw == null) return .{ .painted = reportDrewNothing(x, s, id), .drew = false };
    // Pin reserved width + name into the shared DrawCtx immediately before the
    // draw so width-reading renderers advance and modules resolve their colors.
    ctx.name = segmod.segmentAt(i).name;
    ctx.width = width orelse measureSegmentWidth(s, &ctx.frame, id);
    const painted = segmod.segmentAt(i).draw.?(ctx, x) catch |e| {
        // Rate-limited (P2-62): a permanently broken segment fails every
        // dirty frame; first failure logs at once.
        if (s.drawFailLogDue(id, core.realtimeMs()))
            log.warn("Best-effort op failed (bar drawSegment): {}", .{e});
        // A caught error is a broken segment, not one with nothing to show: both
        // paint nothing, but a zero-width PAINT would collapse a one-off failure.
        return .{ .painted = contract.Painted.nothing(x), .drew = false };
    };
    return .{
        .painted = painted,
        .drew = segmod.finishDraw(segmod.segmentAt(i), painted),
    };
}

/// Draws one segment of a left-to-right row, painting the inter-segment gap and
/// advancing `x`; `omit_gap` seats the next segment flush after a title.
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
    // Segment says whether it painted (not bar guessing from "did x move?"); a
    // zero-width draw and a caught error both consume the reserved `w`.
    const drew = drawn.drew;
    if (drew and !omit_gap) paintGap(s, painted.end_x, scaled_spacing);
    return if (drew)
        painted.end_x + (if (omit_gap) 0 else scaled_spacing)
    else
        x_before + w;
}

fn paintGap(s: *State, gap_x: u16, scaled_spacing: u16) void {
    clearRegion(s, gap_x, scaled_spacing);
}

/// Solves the frame's row geometry and paints it through one `RowPlan`: solve
/// measures/pins every slot, paint walks it. Nothing in solve draws; no measuring in paint.
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

/// Measures the frame into `plan`: right-cluster widths/positions first (so
/// left/center know how much room is gone), then left/center forwards. Records
/// nothing on `s` -- click/ticker bookkeeping belongs to paint.
pub fn solveRowPlan(s: *State, ctx: *segmod.DrawCtx, plan: *RowPlan) void {
    // Every solve is a new layout generation (P2-63): paint stamps it, and
    // region-scoped repaints assert the stamp still matches.
    s.layout_gen +%= 1;
    const r = &s.render;
    const fr = &ctx.frame;
    const scaled_spacing = state.renderBar().scaledSpacing(r.height);
    plan.cluster.scaled_spacing = scaled_spacing;
    plan.cluster.right_x = r.width;

    // Measure right cluster once so left/center placement can shrink around
    // it and the draw need not re-measure.
    for (state.renderBar().layout.items) |lay| {
        if (lay.position != .right) continue;
        for (lay.segments.items) |seg| {
            const w = measureSegmentWidth(s, fr, segmod.segId(seg));
            if (plan.cluster.count < max_right_segments) {
                plan.cluster.widths[plan.cluster.count] = w;
            }
            plan.cluster.count += 1;
            // u32: widths + gaps can exceed u16 on a very wide desktop.
            plan.cluster.total_raw += @as(u32, w) + scaled_spacing;
        }
        if (lay.segments.items.len > 0) plan.cluster.total_raw -= scaled_spacing;
    }
    plan.right_total = @intCast(@min(plan.cluster.total_raw, std.math.maxInt(u16)));

    // Center share is geometry (not painting): budget is avail minus the
    // right cluster AND preceding left/center claims. This cursor tracks the
    // CLAIM; the painted cursor paint threads separately can differ -- a
    // click bound must match the pixels, not the plan.
    var claimed: u16 = 0;
    for (state.renderBar().layout.items) |lay| {
        switch (lay.position) {
            .left, .center => {
                // Saturating: a pathological reservation clamps at 0, not wrap.
                const avail = r.width -| claimed -| plan.right_total;
                const budget = center_row.centerRowBudget(lay, avail, scaled_spacing, fr, s.clock.width);
                const remaining = budget.remaining;
                const center_count = budget.center_count;
                var center_idx: u16 = 0;
                for (lay.segments.items) |seg| {
                    const id = segmod.segId(seg);
                    const is_center = (lay.position == .center) and segmod.isRole(id, center_slot_ids);
                    // Center slots split remaining budget evenly, contiguous
                    // (no gap) so duplicates cannot reach the right cluster.
                    const w: u16 = if (is_center)
                        center_row.centerShare(remaining, center_count, center_idx)
                    else
                        measureSegmentWidth(s, fr, id);
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
                // Backward layout across ALL right layouts (matching right_total),
                // reversed into paint order so paint is one forward loop.
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
                    // Saturating: a pathological width sum clamps at 0.
                    cur_x = cur_x -| seg_w;
                    if (pending_gap) cur_x = cur_x -| scaled_spacing;
                    plan.push(.{
                        .id = id,
                        .w = seg_w,
                        .x = cur_x,
                        .repaintable = isSegmentRepaintable(s, id),
                        .self_ticking = segmod.isRole(id, self_ticking_ids),
                        .is_right = true,
                        // LAST index pushed = leftmost = layout start.
                        .right_layout_start = i == n - 1,
                    });
                    pending_gap = true;
                }
                plan.cluster.right_x = cur_x;
            },
        }
    }
}

/// Walks the solved plan in paint order. Flat: the backward right-cluster
/// cursor is already baked into the plan's slot positions.
pub fn paintRowPlan(s: *State, ctx: *segmod.DrawCtx, plan: *const RowPlan, is_full_redraw: bool) void {
    const scaled_spacing = state.renderBar().scaledSpacing(s.render.height);
    // Left/center advance threaded separately from the plan's right-cluster
    // positions: a right slot's `x` is final, a left/center one can move.
    var x: u16 = 0;
    var pending_gap = false;

    s.clicks.len = 0;
    for (plan.slots[0..plan.len]) |slot| {
        // Both feed the same two recordings (self-ticker scope + click bound),
        // which must agree with where paint landed; drawClockOnly needs the scope.
        const slot_x = if (slot.is_right) slot.x else x;
        if (slot.self_ticking) recordSelfTickerScope(s, slot.id, slot_x, slot.w);
        recordClickBound(s, slot.id, slot_x, slot.w);

        if (!slot.repaintable) {
            // Reserved space only; cursor still moves past it. Plain `+=` on
            // purpose: saturating a u16 overflow would hide a config bug.
            if (!slot.is_right) {
                x += slot.w;
                if (!slot.omit_gap) x += scaled_spacing;
            } else {
                pending_gap = true;
            }
            continue;
        }

        if (!is_full_redraw) {
            // Left/center clear also covers the trailing gap it advances past.
            const clear_w = if (slot.is_right)
                slot.w
            else if (slot.omit_gap)
                slot.w
            else
                slot.w +| scaled_spacing;
            clearRegion(s, slot_x, clear_w);
        }

        if (slot.is_right) {
            // New right layout starts a fresh gap run: layouts are spaced by
            // right_total, not a painted gap; a pending gap would clear twice.
            if (slot.right_layout_start) pending_gap = false;
            const drew = drawSegment(s, ctx, slot.id, slot.x, slot.w).drew;
            if (drew and pending_gap) paintGap(s, slot.x +| slot.w, scaled_spacing);
            // A failed draw still occupies its slot as empty space so the
            // next leftward segment gets the same gap solve computed.
            pending_gap = true;
        } else {
            const x_before = x;
            x = drawRowSegment(s, ctx, slot.id, x, slot.w, slot.omit_gap, scaled_spacing);
            if (x != x_before) extendDirtySpan(s, x_before, x - x_before);
        }
        clearSegmentDirty(s, slot.id);
    }
}
