//! The bar's live state: the `State` value and everything that only exists
//! to describe or locate it -- the `Bar`/`gBar` handle, the segment-registry
//! identity helpers, and the hook walkers.
//!
//! Split OUT of `bar.zig` to break three import cycles: `repaint`,
//! `visibility_glue`, and `input_events` all read this state on every batch,
//! and importing `bar.zig` for it dragged them into a cycle with the file
//! that also drives them (bar.zig imports all three). With the state in its
//! own leaf, those three import THIS file and nothing imports them back.
//!
//! Nothing here performs X work or decides anything: it is data plus the
//! accessors over it. Lifecycle (create/destroy/reload), polling, and the
//! chrome stay in `bar.zig`; frame collection lives in `frame.zig` and the
//! paint pass in `repaint.zig` (Phase 4 step 23).

const std = @import("std");
const core = @import("core");
const constants = @import("constants");
const types = @import("types");
const query = @import("query");
const model = @import("model");
const wincache = @import("wincache");
const drawing = @import("drawing");
const segmod = @import("segment");
const vocab = @import("vocab");
const barwin = @import("win");
const center_row = @import("center_row");
const contract = @import("contract");

// The capability sets live in segment.zig (their one home); these aliases
// keep state's internal readers (`title_id`, `selfTickerIndex`) unqualified.
const self_ticking_ids = segmod.self_ticking_ids;
const center_slot_ids = segmod.center_slot_ids;

/// Primary center-slot segment: the FIRST center-slot binder in registry
/// order (config order within a center layout). Title-centric bar behaviors
/// (click-to-focus, chrome-overlay toggle) route through it; with a single
/// binder this is exactly the title, with several it is the leftmost one.
pub const title_id: ?usize = if (center_slot_ids.len != 0) center_slot_ids[0] else null;

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

/// Global bar coordination flags. Read and written exclusively on the main
/// thread; no mutex protection required.
pub const Bar = struct {
    state: ?*State = null,
    /// True when visibility_glue.presentForPrompt() had to map an
    /// otherwise-hidden bar (e.g. hidden by a fullscreen window, or by the
    /// user toggling it off) purely so the inline prompt would be visible.
    /// visibility_glue.dismissAfterPrompt() checks this to know whether
    /// hiding the bar again is part of "returning to normal" -- the flag's
    /// whole lifecycle (set, cleared, guarded against) lives in that file.
    prompt_forced_visible: bool = false,
};

pub var gBar: Bar = .{};
/// X11 connection and window handle; stable for the bar's lifetime.
const WindowCtx = struct {
    conn: core.Connection,
    win_id: u32,
    colormap: u32,

    /// Destroys the window AND frees its colormap, in that order, through
    /// win.zig's single teardown. This used to free only the colormap,
    /// so both real teardown paths -- shutdown and the reload-time recreate --
    /// had to remember to call `xcb_destroy_window` themselves, and did, in
    /// two places. The one that forgot would leak the window and keep the bar
    /// on screen with no way back to it. win.zig owns both halves now, and
    /// the errdefer on a half-built bar is the only place left that has to
    /// reach past this.
    pub fn deinit(self: *WindowCtx) void {
        barwin.destroyBarWindow(self.conn, self.win_id, self.colormap);
    }
};

/// The live bar configuration, read straight from core rather than copied:
/// a copy would borrow slices from a config the caller frees, and need a
/// re-point on every reload path -- nothing to re-point, nothing to forget.
pub inline fn renderBar() types.BarConfig {
    return core.getState().config.bar;
}

const RenderCtx = struct {
    dc: *drawing.DrawContext,
    width: u16,
    height: u16,
    allocator: std.mem.Allocator,
};

/// Per-frame window-count bound for the title scratch buffers; shares the
/// single bar-wide cap in segment.zig.
pub const max_frame_windows: usize = segmod.max_visible_windows;

/// Upper bound on recorded click bounds: one slot per clickable segment in
/// the configured layout. Configs with more clickable segments than this
/// simply lose clickability on the extras (rendering is unaffected).
const max_click_bounds: usize = segmod.all().len;

/// Cap on updateIfDirty's re-request redraw loop: a module that keeps
/// re-requesting a full redraw past this many iterations is treated as a
/// stall (logged), keeping a rogue module from busy-spinning the batch.
pub const max_batched_redraws: u8 = 4;

/// On-screen hit-test bound of one segment, recorded by recordClickBound
/// during the layout pass. THE click-bound storage: hit-testing iterates
/// these in recorded order (first match wins).
pub const SegBound = struct {
    /// Segment identity, not its name. The layout already knows the id it is
    /// positioning, so keying the record by id makes lookup a compare instead
    /// of a string scan, and two segments sharing a name (or one appearing
    /// twice) can no longer alias each other's bounds.
    id: usize,
    x: u16,
    w: u16,

    pub inline fn contains(self: SegBound, px: u16) bool {
        return px >= self.x and px < self.x + self.w;
    }
};

const Visibility = struct {
    /// Whether the bar window is currently mapped (the wire state). Written
    /// only by the paths that actually issue map/unmap: the visibility glue
    /// (decision apply + the prompt present/dismiss pair), and the reload swap
    /// (which carries it over). Pure policy (`visibility.zig`) never touches
    /// it -- it compares its decision against this and the caller applies.
    shown: bool = true,
    /// The USER-level bar toggle (`toggle_bar_visibility`), handed to the
    /// policy as `is_globally_visible`. Fullscreen force-hide is deliberately
    /// NOT stored here: the policy re-derives it from the model on every
    /// decision, so a fullscreen window closing while the bar is down (or a
    /// workspace switch) needs no bookkeeping write to recover the bar.
    preferred: bool = true,
};

/// The bar's damage state: a request layer (whole-bar flag), a scope layer
/// (which slots), and a damage layer (what to blit), read as one conjunction
/// by the draw gates.
///
/// NOT foldable into one store -- the flag and the per-segment set are
/// independent in three real states, and every consumer needs both halves:
/// startup has all bits set with the flag clear (the first draw is admitted
/// by the bits alone), `markDirtySource` sets the flag while matching no
/// segment (a fact revision for a module that is not in the layout), and the
/// overlay-only prompt's bit is never cleared (it is never painted), so
/// "any bit set" can never mean "a draw is owed". `pendingFullRedraw` takes
/// the CONJUNCTION for exactly that reason: a partial wake must still
/// region-scope its repaint. This pair already absorbed the older
/// `gBar.force` flag (BARCR-09); re-collapsing it would re-open that ruling.
const Dirty = struct {
    /// Whole-bar redraw requested (a fact revision or forced draw).
    flag: bool = false,
    /// Per-segment dirty flags, one per entry in the generated bar_modules
    /// registry. When set, the segment is repainted on the next draw;
    /// cleared after painting. Every segment starts dirty so the first draw
    /// is a full redraw.
    segments: [segmod.all().len]bool = @splat(true),
    /// Left edge (inclusive) of the current draw's dirty span: the bounding
    /// x/w of every repainted segment + gap, tracked by extendDirtySpan so
    /// flushRender copies only the changed region.
    span_x: u16 = 0,
    /// Width of the current draw's dirty span. 0 = empty span (nothing to
    /// blit); set non-zero by the first extendDirtySpan of a draw.
    span_w: u16 = 0,
};

/// Region scratch for one self-ticking segment, indexed by position in
/// `self_ticking_ids` (the registry order the capability set was built in).
const SelfTickerScope = struct {
    /// Left edge of the segment's reserved slot from the last layout pass.
    x: u16 = 0,
    /// Reserved width from the same layout (its natural width at that frame's
    /// clock budget).
    width: u16 = 0,
    /// True once a layout pass placed the segment (a self-ticker that never
    /// made it into a layout is never repainted region-scoped).
    valid: bool = false,
};

pub const Clock = struct {
    /// The single clock-width store: the bar-wide MERGED display width of the
    /// self-ticking segments (max across them), read by every naturalWidth
    /// hook as its clock budget and re-derived on a clock display-mode cycle.
    /// Re-derived at State.init, by adoptFreshClockWidth (driven by the
    /// segment's mode-aware staleness on every event batch), and -- for a bar
    /// surviving a failed reload, where the new config's font/padding never
    /// reached this State -- on the next second tick, which is also the
    /// cadence that picks up any other live-probe drift.
    width: u16 = 0,
    /// Per self-ticking segment last-bound scratch, keyed by position in
    /// `self_ticking_ids`. Only `valid` entries are ever read.
    segs: [self_ticking_ids.len]SelfTickerScope = @splat(.{}),
};

const Clicks = struct {
    /// Click bounds recorded by the last layout pass, in record order.
    bounds: [max_click_bounds]SegBound = undefined,
    len: usize = 0,
};

/// Live frame state (recollected on every draw; see frame.scanLiveFrame). Holds
/// the shared `segmod.Frame` directly (workspace_count/current_workspace/
/// is_all_view_active) plus the bar-local backing array it slices, so the
/// segment-visible struct stays the single source instead of a mirror.
const FrameState = struct {
    frame: segmod.Frame = .{},
    /// Backing array for `frame.workspace_has_windows` (the shared struct
    /// only holds the slice).
    ws_has_windows: [constants.max_workspaces]bool = @splat(false),
    /// The current workspace's windows for the frame, one entry per window
    /// (id only until frame.fillDrawCtx annotates title + geom; the AoS record
    /// replaces the separate `wins` / titles_buf / geoms_buf arrays).
    entries: [max_frame_windows]vocab.TitleEntry = undefined,
    entries_len: usize = 0,
    /// Per-frame title rendering context from the last draw, reused for
    /// post-draw click hit-testing (backing buffers are stable for the rest
    /// of the event-loop batch: they live on State, and nothing reallocates
    /// them between draws).
    last_ctx: segmod.DrawCtx = undefined,
    /// Whether a full scan+fill pass (frame.scanLiveFrame, frame.fillDrawCtx) has ever
    /// populated `last_ctx`. Guards the marquee-only fast path, which reuses
    /// the cached snapshot in place of re-scanning the live frame: until the
    /// first full draw, last_ctx is undefined and must not be copied.
    ctx_valid: bool = false,
};

/// Title-data scratch: the minimized-set service plus the focused-title
/// copy. The per-window title/geom annotations are NOT here: they live on
/// `frame.entries` (one record per window, id + title + geom), filled by
/// frame.fillDrawCtx from the WM-owned title cache (wincache.peekTitle) and the
/// sync truth-rect -- never the wire, so no async fetch, no positional slot,
/// no X11 in the draw path.
const TitleScratch = struct {
    minimized: std.AutoHashMapUnmanaged(u32, void) = .{},
    /// Title addon's minimized-state service, cached from the DrawCtx after
    /// the first draw so frame.scanLiveFrame can synthesize the set each frame
    /// without bar.zig naming the minimize addon.
    minimized_api: segmod.MinimizedApi = .{},
    /// Storage for the focused window's title. The per-window titles
    /// on `frame.entries` borrow straight from the wincache (they are
    /// refreshed every frame before the draw); the focused title used to be
    /// a slice straight into the wincache's per-window `title_buf`, so the
    /// DrawCtx retained a borrowed pointer into a cache that a title change
    /// overwrites in place. That is the same window as often as not -- the
    /// focused window is usually also in the frame's entry list, whose title
    /// is refreshed right beside this copy -- so the one field with the
    /// widest lifetime needed the one byte copy. Copying costs one memcpy and
    /// removes the question of which readers may hold the slice across a
    /// cache write.
    focused_title_buf: [wincache.max_title_len]u8 = undefined,
};

/// Last-seen core fact revisions (see core.Facts). Each is diffed against the
/// live core fact in updateIfDirty; a mismatch marks segments dirty (cheap)
/// or forces a full redraw. Initialized to the sentinel so the first update
/// draws.
const Facts = struct {
    /// Last focus_rev we diffed. A change marks the title segment dirty.
    focus_rev: u32 = std.math.maxInt(u32),
    /// Last window_rev we diffed. A change marks all segments dirty (the
    /// workspaces/title segments reflect window & workspace state).
    window_rev: u32 = std.math.maxInt(u32),
    /// Last layout_rev we diffed. A change forces a full redraw (all segments).
    layout_rev: u32 = std.math.maxInt(u32),
    /// Last fullscreen_rev we diffed. A change means fullscreen occupancy of
    /// the current workspace changed; the bar recomputes its forced hidden/
    /// shown state (shared-screen reaction) from the core fact.
    fullscreen_rev: u32 = std.math.maxInt(u32),
};
/// All live bar state. The title-window scratch below is rebuilt every frame
/// from in-process caches (no X11, nothing to refetch); every other field is
/// recomputed per frame.
///
/// State is plain data owned by this file alone: the poll-driven loop reads
/// and mutates it directly, and segments receive only per-segment sub-views
/// (via the DrawCtx), never State itself.
pub const State = struct {
    win: WindowCtx,
    render: RenderCtx,

    /// Caller-owned scratch for query.allWindowsInto (window walks during
    /// a frame build). State-local so two walks cannot share one buffer.
    snapshot: [model.store_capacity]query.Entry = undefined,

    vis: Visibility = .{},
    dirty: Dirty = .{},
    clock: Clock = .{},
    clicks: Clicks = .{},
    /// Segment id whose recorded bound owns an in-flight button-1 scrub
    /// (drag motion on a clickable segment). Set on a left press and cleared
    /// on release; while set, every surface motion routes to that segment's
    /// `onDragMotion` hook (X's implicit grab keeps motion flowing even past
    /// the bar's edge).
    drag_segment: ?usize = null,
    /// Segment id being serviced by a scroll `onScroll` dispatch while its
    /// scoped repaint callback runs, so the callback repaints only the
    /// scrolled segment's recorded bound (see redrawScopedSegment) instead
    /// of forcing a full-bar redraw. Set around the dispatch in
    /// handleButtonPress and cleared before it returns.
    scroll_segment: ?usize = null,
    frame: FrameState = .{},
    title_data: TitleScratch = .{},
    facts: Facts = .{},

    pub fn init(
        allocator: std.mem.Allocator,
        conn: core.Connection,
        win_id: u32,
        colormap: u32,
        width: u16,
        height: u16,
        dc: *drawing.DrawContext,
        config: types.BarConfig,
    ) !*State {
        const s = try allocator.create(State);
        // The merged clock display width comes from the self-ticking segments'
        // measureString hooks (max across them; a segment with no hook
        // contributes 0). Styled, matching the draw's own probe, so the
        // reservation and the paint agree for a [bar.properties]-styled clock.
        const clock_width = center_row.mergedClockWidth(dc, config, height, drawing.DrawContext.measureTextWidthStyled);
        s.* = .{
            .win = .{
                .conn = conn,
                .win_id = win_id,
                .colormap = colormap,
            },
            .render = .{
                .dc = dc,
                .width = width,
                .height = height,
                .allocator = allocator,
            },
            .clock = .{ .width = clock_width },
        };
        // Partial-failure mirror of deinit(); the caller's errdefers own the
        // window+colormap and the dc.
        errdefer {
            s.title_data.minimized.deinit(allocator);
            allocator.destroy(s);
        }
        // Width caches for size-varying segments reset per bar creation
        // through their uniform invalidate hook (tags/workspaces); layout and
        // variants deliberately bind none, keeping their last measured width
        // so a re-measure never reserves a 0-width slot for a frame (see
        // scaffold.Opts.invalidate).
        segmod.runVoidHook(.invalidate);
        return s;
    }

    pub fn deinit(self: *State) void {
        self.win.deinit();
        const alloc = self.render.allocator;
        self.title_data.minimized.deinit(alloc);
        alloc.destroy(self);
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
        self.render.dc.fillRect(x, 0, w, self.render.height, renderBar().bg);
        self.extendDirtySpan(x, w);
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
        return self.dirty.flag and self.isFullDirty();
    }

    /// Scans the configured layout tree, returning true as soon as a segment
    /// matches `pred`. Layout-rendered segments only: the overlay-only prompt
    /// slot is excluded (its dirty flag is never cleared, so a registry-wide
    /// scan would always match and defeat the fast-path early-exit). The
    /// layout stores names; the predicate takes a resolved id, so each name
    /// is resolved exactly once here instead of once per predicate.
    inline fn anyLayoutSegment(self: *const State, comptime pred: anytype) bool {
        for (renderBar().layout.items) |lay| {
            for (lay.segments.items) |seg| {
                if (pred(self, segmod.segId(seg))) return true;
            }
        }
        return false;
    }

    /// True when the next draw would repaint at least one layout-rendered
    /// segment: a dirty flag or a live needsRepaint hook (the title marquee).
    pub fn hasPendingRepaintWork(self: *const State) bool {
        return self.anyLayoutSegment(State.isSegmentRepaintable);
    }

    /// True when any layout-rendered segment carries a set dirty bit (as
    /// opposed to only a self-animated needsRepaint hook). A dirty bit means
    /// the facts backing the drawn content changed, so the frame must be
    /// rescanned and the DrawCtx refilled before drawing; when no dirty bit is
    /// set and !dirty.flag, the only pending work is a marquee/overlay
    /// needsRepaint hook and the cached last_ctx snapshot is still accurate.
    pub fn hasLayoutSegmentDirty(self: *const State) bool {
        return self.anyLayoutSegment(segDirty);
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
            // ran during the layout pass) rather than re-measured here: the
            // latter made every self-ticker's hook run twice per frame.
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
        const fresh = center_row.mergedClockWidth(self.render.dc, renderBar(), self.render.height, drawing.DrawContext.measureTextWidthStyled);
        if (fresh == self.clock.width) return false;
        self.clock.width = fresh;
        return true;
    }
};
