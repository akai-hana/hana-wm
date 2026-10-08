//! The bar's live state: the `State` value and everything that only exists
//! to describe or locate it -- the `Bar`/`gBar` handle, the segment-registry
//! identity helpers, the per-frame scratch types, and the hook walkers.
//!
//! Split OUT of `bar.zig` to break three import cycles: `repaint`,
//! `visibility_glue`, and `input_events` all read this state on every batch,
//! and importing `bar.zig` for it dragged them into a cycle with the file
//! that also drives them (bar.zig imports all three). With the state in its
//! own leaf, those three import THIS file and nothing imports them back.
//!
//! Nothing here performs X work or decides anything: it is data plus the
//! accessors over it. Lifecycle (create/destroy/reload), polling, and the
//! chrome stay in `bar.zig`.

const std = @import("std");
const build_options = @import("build_options");
const core = @import("core");
const constants = @import("constants");
const log = @import("log");
const types = @import("types");
const tracking = @import("tracking");
const focus = @import("focus");
const pipeline = @import("pipeline");
const model = @import("model");
const reconcile = @import("reconcile");
const wincache = @import("wincache");
const window = @import("window");
const drawing = @import("drawing");
const segmod = @import("segment");
const scaffold = @import("scaffold");
const barwin = @import("win");
const center_row = @import("center_row");
const contract = @import("contract");

/// The hide-family provider bound to the generated window registry, resolved
/// once at file scope: the hidden-set synthesis and its collect dispatch
/// share one lookup (no module is ever named by the bar).
pub const collect_hidden_set = window.providerOf(.collectHiddenSet);

// Registry-resolved segment identity (comptime): the bar locates modules by
// name through the generated registry instead of importing them directly.
// Role/named lookups return null on an absent (even empty) registry, so the
// bar still compiles and no-ops when ALL segments are removed.
// File-local: consumers raw-import `@import("X_modules").modules` at their
// point of use (the window-layer spelling); contract's `tiling_mods` is the
// one documented facade exception.
const bar_mods = @import("bar_modules").modules;

// The capability sets live in segment.zig (their one home); these aliases
// keep state's internal readers (`title_id`, `selfTickerIndex`) unqualified.
// `self_ticking_ids` stays pub for repaint.zig and bar.zig.
pub const self_ticking_ids = segmod.self_ticking_ids;
const center_slot_ids = segmod.center_slot_ids;

/// Primary center-slot segment: the FIRST center-slot binder in registry
/// order (config order within a center layout). Title-centric bar behaviors
/// (click-to-focus, chrome-overlay toggle) route through it; with a single
/// binder this is exactly the title, with several it is the leftmost one.
pub const title_id: ?usize = if (center_slot_ids.len != 0) center_slot_ids[0] else null;

/// Registry entry at a resolved `id`. Callers reach this only after a
/// registry capability/role lookup matched a name; a match is
/// impossible when the registry is empty.
pub inline fn segAt(id: usize) *const contract.Segment {
    if (comptime !segmod.hasRegisteredSegments()) unreachable;
    return &bar_mods[id];
}

/// Dirty-bit read for a registry id (null: a name that does not resolve is
/// never dirty). The null check precedes the comptime guard so an
/// empty-registry build never reaches `unreachable`.
pub inline fn segDirty(self: *const State, id: ?usize) bool {
    const i = id orelse return false;
    if (comptime !segmod.hasRegisteredSegments()) unreachable;
    return self.dirty.segments[i];
}

/// Position of `id` within `self_ticking_ids` (the key into
/// `Clock.segs`), or null when it is not a self-ticking segment.
pub fn selfTickerIndex(id: ?usize) ?usize {
    return segmod.roleIndexOf(id, self_ticking_ids);
}

pub fn runVoidHook(comptime hook: std.meta.FieldEnum(contract.Segment)) void {
    contract.callAll(contract.Segment, bar_mods[0..], hook, .{});
}

pub fn anyBoolHook(comptime hook: std.meta.FieldEnum(contract.Segment), args: anytype) bool {
    for (bar_mods) |seg| if (@field(seg, @tagName(hook))) |f| if (@call(.auto, f, args)) return true;
    return false;
}

/// Global bar coordination flags. Read and written exclusively on the main
/// thread; no mutex protection required.
pub const Bar = struct {
    state: ?*State = null,
    /// True when presentForPrompt() had to map an otherwise-hidden bar (e.g.
    /// hidden by a fullscreen window, or by the user toggling it off) purely
    /// so the inline prompt would be visible. dismissAfterPrompt() checks this
    /// to know whether hiding the bar again is part of "returning to normal".
    prompt_forced_visible: bool = false,
};

pub var gBar: Bar = .{};
/// X11 connection and window handle; stable for the bar's lifetime.
pub const WindowCtx = struct {
    conn: core.Connection,
    win_id: u32,
    colormap: u32,

    /// Destroys the window AND frees its colormap, in that order, through
    /// win.zig's single teardown (20.4). This used to free only the colormap,
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

pub const RenderCtx = struct {
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
pub const max_click_bounds: usize = bar_mods.len;

/// Scratch bound for the per-draw right-cluster segment widths. Right segments
/// are measured once into this buffer and reused for both the total-width
/// calculation and the draw; a config with more than this many right segments
/// falls back to re-measuring at draw time (layout math identical, no win).
pub const max_right_segments: usize = 16;

/// Cap on solved row slots in one frame.
///
/// The layout is RUNTIME config (`BarLayout.segments` is an ArrayList) and a
/// config may list the same segment in several layouts, so there is no
/// comptime ceiling to derive: this is a generous fixed bound, and overflow is
/// handled rather than trusted (see RowPlan.push). Generous on purpose -- the
/// alternative, a cap that silently dropped slots, would drop click bounds and
/// paints with no trace, and `plan.slots[0..len]` past the end is a panic in
/// Debug and out-of-bounds reads in ReleaseFast.
pub const max_row_slots: usize = 64;

/// Cap on updateIfDirty's re-request redraw loop: a module that keeps
/// re-requesting a full redraw past this many iterations is treated as a
/// stall (logged), keeping a rogue module from busy-spinning the batch.
pub const max_batched_redraws: u8 = 4;

/// Right-aligned cluster bookkeeping for one draw frame. Measures every
/// right-position segment once up front, deriving both the reserved width
/// (which left/center placement shrinks around) and the per-segment widths
/// the draw consumes. Falls back to measure-at-draw when the segment count
/// overflows `max_right_segments`.
pub const RightCluster = struct {
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
/// with no draw call anywhere near it. (20.1)
///
/// The split exists because geometry, hit-testing and painting were one unit
/// of change in drawAllInner: adding a segment meant editing a loop that
/// measured it, recorded its click bound, scoped its ticker, cleared its
/// region and drew it, all interleaved. Solve produces these; paint walks them.
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
/// into paint order here rather than at draw time. That reversal is the
/// fiddly part the item warned about, and doing it once in solve is what lets
/// paint be a single flat loop with no backward cursor.
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
                log.warnOnErr(error.RowPlanOverflow, "bar solveRowPlan");
            }
            return;
        }
        self.slots[self.len] = slot;
        self.len += 1;
    }
};

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

pub const Visibility = struct {
    /// Whether the bar window is currently mapped (the wire state). Written
    /// only by the paths that actually issue map/unmap: the visibility glue's
    /// decision apply, the prompt present/dismiss pair, and the reload swap
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
pub const Dirty = struct {
    /// Whole-bar redraw requested (a fact revision or forced draw).
    flag: bool = false,
    /// Per-segment dirty flags, one per entry in the generated bar_modules
    /// registry. When set, the segment is repainted on the next draw;
    /// cleared after painting. Every segment starts dirty so the first draw
    /// is a full redraw.
    segments: [bar_mods.len]bool = @splat(true),
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
pub const SelfTickerScope = struct {
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

pub const Clicks = struct {
    /// Click bounds recorded by the last layout pass, in record order.
    bounds: [max_click_bounds]SegBound = undefined,
    len: usize = 0,
};

/// Live frame state (recollected on every draw; see scanLiveFrame). Holds
/// the shared `segmod.Frame` directly (workspace_count/current_workspace/
/// is_all_view_active) plus the bar-local backing array it slices, so the
/// segment-visible struct stays the single source instead of a mirror.
pub const FrameState = struct {
    frame: segmod.Frame = .{},
    /// Backing array for `frame.workspace_has_windows` (the shared struct
    /// only holds the slice).
    ws_has_windows: [constants.max_workspaces]bool = @splat(false),
    /// The current workspace's windows for the frame, one entry per window
    /// (id only until fillDrawCtx annotates title + geom; the AoS record
    /// replaces the separate `wins` / titles_buf / geoms_buf arrays).
    entries: [max_frame_windows]segmod.TitleEntry = undefined,
    entries_len: usize = 0,
    /// Per-frame title rendering context from the last draw, reused for
    /// post-draw click hit-testing (backing buffers are stable for the rest
    /// of the event-loop batch: they live on State, and nothing reallocates
    /// them between draws).
    last_ctx: segmod.DrawCtx = undefined,
    /// Whether a full scan+fill pass (scanLiveFrame, fillDrawCtx) has ever
    /// populated `last_ctx`. Guards the marquee-only fast path, which reuses
    /// the cached snapshot in place of re-scanning the live frame: until the
    /// first full draw, last_ctx is undefined and must not be copied.
    ctx_valid: bool = false,
};

/// Title-data scratch: the minimized-set service plus the focused-title
/// copy. The per-window title/geom annotations are NOT here: they live on
/// `frame.entries` (one record per window, id + title + geom), filled by
/// fillDrawCtx from the WM-owned title cache (wincache.peekTitle) and the
/// sync truth-rect -- never the wire, so no async fetch, no positional slot,
/// no X11 in the draw path.
pub const TitleScratch = struct {
    minimized: std.AutoHashMapUnmanaged(u32, void) = .{},
    /// Title addon's minimized-state service, cached from the DrawCtx after
    /// the first draw so scanLiveFrame can synthesize the set each frame
    /// without bar.zig naming the minimize addon.
    minimized_api: segmod.MinimizedApi = .{},
    /// Storage for the focused window's title. (11.9) The per-window titles
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
pub const Facts = struct {
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

    /// Caller-owned scratch for tracking.allWindowsInto (window walks during
    /// a frame build). State-local so two walks cannot share one buffer.
    snapshot: [model.store_capacity]tracking.Entry = undefined,

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
        runVoidHook(.invalidate);
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
    inline fn extendDirtySpan(self: *State, x: u16, w: u16) void {
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
        for (bar_mods, 0..) |m, i| {
            if (segmod.hasSource(m.dirty_sources, source)) self.dirty.segments[i] = true;
        }
    }

    /// True when the segment must be repainted on this draw: its dirty bit
    /// is set, or it declares the self-animated repaint capability and its
    /// runtime query reports active (e.g. a scrolling marquee: the motion
    /// only advances while the segment is drawn, so change detection must
    /// not skip it). Uniform: resolved by registry, never by segment name.
    /// A name that does not resolve (null) is never repaintable.
    fn isSegmentRepaintable(self: *const State, id: ?usize) bool {
        const i = id orelse return false;
        if (segDirty(self, id)) return true;
        if (segAt(i).needsRepaint) |q| return q();
        return false;
    }

    /// True when every registry slot is dirty (the complete-background-clear
    /// trigger). Non-configured segments (e.g. the prompt overlay) are never
    /// drawn and never cleared, so an all-dirty set only occurs on a folded
    /// full-redraw request.
    fn isFullDirty(self: *const State) bool {
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
    fn recordClickBound(self: *State, id: ?usize, x: u16, w: u16) void {
        const i = id orelse return;
        if (!segAt(i).clickable) return;
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
    fn measureSegmentWidth(self: *State, frame: *const segmod.Frame, id: ?usize) u16 {
        return segmod.naturalWidthOf(id, frame, self.clock.width);
    }

    /// Records the last layout-pass bound of a self-ticking segment so its
    /// end-of-batch tick can region-scope a repaint (drawClockOnly). Written
    /// for every configured self-ticker in ANY cluster (left/center/right);
    /// unconfigured self-tickers stay invalid and are never repainted.
    fn recordSelfTickerScope(self: *State, id: ?usize, x: u16, w: u16) void {
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

    /// Fills the shared per-frame DrawCtx the bar hands to every segment's
    /// draw hook, including the title snapshot slots.
    pub fn fillDrawCtx(self: *State, ctx: *segmod.DrawCtx) void {
        ctx.frame = self.frame.frame;
        ctx.frame.workspace_has_windows = self.frame.ws_has_windows[0..self.frame.frame.workspace_count];
        // The minimized-state service is drawn from the window module registry
        // here (upfront, per frame) so the title segment need not name the
        // addon that owns it. No provider compiled in => empty api =>
        // scanLiveFrame no-ops, matching prior boot ordering.
        var minimized_api: segmod.MinimizedApi = .{};
        if (collect_hidden_set != null)
            minimized_api.collect = minimizedCollect;
        ctx.minimized_api = minimized_api;
        // Titles/geoms below come from the WM-owned title cache and the sync
        // truth-rect -- neither performs X11 work, so the draw path is
        // non-blocking and no positional batch exists to scramble. The backing
        // entries live on State, valid for the rest of the frame AND for
        // post-draw click handling through the cached `frame.last_ctx`.
        const entries = self.frame.entries[0..self.frame.entries_len];
        for (entries) |*e| {
            e.title = wincache.peekTitle(e.window);
            e.geom = titleGeom(e.window, self.title_data.minimized.contains(e.window));
        }
        // Title of the minimized window, used in the single-window title case.
        var minimized_title: []const u8 = "";
        if (entries.len > 0 and self.title_data.minimized.contains(entries[0].window))
            minimized_title = entries[0].title;
        ctx.focused_window = focus.getFocused();
        // Copy, do not borrow (11.9): `peekTitle` returns a slice of the
        // cache's own storage, and this ctx outlives the draw through
        // `frame.last_ctx`. See focused_title_buf.
        if (ctx.focused_window) |fw| {
            const src = wincache.peekTitle(fw);
            @memcpy(self.title_data.focused_title_buf[0..src.len], src);
            ctx.focused_title = self.title_data.focused_title_buf[0..src.len];
        } else {
            ctx.focused_title = "";
        }
        ctx.minimized_title = minimized_title;
        ctx.current_ws_entries = entries;
        ctx.minimized_set = &self.title_data.minimized;
    }

    // Live-state collection

    /// Reads workspace/window state into the frame fields. Pure model reads:
    /// no X11. The per-window titles/geoms are filled later (fillDrawCtx)
    /// straight from the WM-owned title cache and the sync truth-rect, so
    /// there is no fetch key to diff and nothing to prefetch.
    pub fn scanLiveFrame(self: *State) void {
        const m = pipeline.model();
        // The minimized set feeds the title snapshot; the title addon owns the
        // synthesis, exposed through the cached DrawCtx api. Synthesizing
        // fresh each scan makes set membership equivalent to a live
        // per-window query.
        if (build_options.has_minimize) {
            if (self.title_data.minimized_api.collect) |f| f(m, &self.title_data.minimized, self.render.allocator);
        }
        if (build_options.has_workspaces) {
            self.frame.frame.workspace_count = @intCast(tracking.getWorkspaceCount());
            self.frame.frame.current_workspace = @intCast(m.current.index);
            self.frame.frame.is_all_view_active = m.all_view_active;
            @memset(&self.frame.ws_has_windows, false);
            self.frame.entries_len = 0;
            const cur_ws: model.WSId = model.WSId.fromIndex(self.frame.frame.current_workspace);
            const cur_bit: u64 = if (self.frame.frame.current_workspace < self.frame.frame.workspace_count)
                model.bit(cur_ws)
            else
                0;
            // OR-accumulate all window masks in a single pass, collecting the
            // current workspace's windows on the way.
            var combined_mask: u64 = 0;
            for (tracking.allWindowsInto(&self.snapshot)) |entry| {
                combined_mask |= entry.mask;
                if (cur_bit != 0 and model.maskedOn(entry.mask, cur_ws) and
                    self.frame.entries_len < max_frame_windows)
                {
                    // Id only: fillDrawCtx annotates title + geom before any
                    // draw reads the entry.
                    self.frame.entries[self.frame.entries_len] = .{
                        .window = entry.win,
                        .title = "",
                        .geom = null,
                    };
                    self.frame.entries_len += 1;
                }
            }
            for (0..self.frame.frame.workspace_count) |i| {
                self.frame.ws_has_windows[i] = model.maskedOn(combined_mask, model.WSId.fromIndex(i));
            }
        }
    }

    /// Canonical title-slot geometry for `win`: the off-screen sentinel while
    /// minimized, else the sync truth-rect (floating anchor / last sent rect)
    /// with the off-screen sentinel for windows that have never been placed
    /// (parked/unsent). Mirrors the old batch behavior (truth-rect first,
    /// sentinel fallback) without the xcb_get_geometry round-trip.
    fn titleGeom(win: u32, minimized: bool) ?model.Rect {
        if (minimized) return segmod.offscreen_rect;
        return reconcile.truthRect(pipeline.model(), win) orelse segmod.offscreen_rect;
    }

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
        log.warnOnErr(error.DrewInvalidSegment, "bar drawSegment");
        return contract.Painted.nothing(x);
    }

    /// Draws a segment by registry dispatch, catching and logging errors
    /// instead of propagating them, and reports the width it actually painted
    /// back to the segment.
    ///
    /// The width handback and the painted/nothing decision live in
    /// `scaffold.finishDraw` (21.7) rather than inline here: they are the
    /// bar's post-draw policy, but testing them through this loop would need a
    /// live DrawContext and an X connection, so in practice they would go
    /// untested -- and a segment that forgets to record its own drawn width
    /// stays locked onto its startup width with its neighbours overlapping it
    /// forever, with no symptom but a bar that looks wrong.
    /// `id` is the resolved registry index the layout pass already holds; a
    /// null (a name that no longer resolves) paints nothing and reports the
    /// fallback the row reserves.
    pub fn drawSegment(self: *State, ctx: *segmod.DrawCtx, id: ?usize, x: u16, width: ?u16) Drawn {
        const i = id orelse return .{ .painted = reportDrewNothing(x), .drew = false };
        if (segAt(i).draw == null) return .{ .painted = reportDrewNothing(x), .drew = false };
        // The DrawCtx is shared mutable scratch: pin the reserved width into it
        // immediately before the draw so width-reading renderers (the title)
        // advance correctly. The name goes in the same way, so a module can
        // resolve its own themed colors (the slider's fill reads
        // segmentValueFg(name)) without the draw hook carrying a per-segment
        // argument.
        ctx.name = segAt(i).name;
        ctx.width = width orelse self.measureSegmentWidth(&ctx.frame, id);
        const painted = segAt(i).draw.?(ctx, x) catch |e| {
            log.warnOnErr(e, "bar drawSegment");
            // A caught error is a broken segment, not a segment with nothing
            // to show: it painted nothing either way, but reporting it as a
            // zero-width PAINT would let the next layout collapse a slot that
            // only failed this once.
            return .{ .painted = contract.Painted.nothing(x), .drew = false };
        };
        return .{
            .painted = painted,
            .drew = scaffold.finishDraw(segAt(i), painted),
        };
    }

    /// Draws one segment of a left-to-right row, painting the inter-segment gap
    /// and advancing `x`. `w` is the reserved width; `omit_gap` suppresses the
    /// gap after a title so the next segment sits flush (center layout).
    /// Returns the new `x`.
    fn drawRowSegment(
        self: *State,
        ctx: *segmod.DrawCtx,
        id: ?usize,
        x: u16,
        w: u16,
        omit_gap: bool,
        scaled_spacing: u16,
    ) u16 {
        const x_before = x;
        const drawn = self.drawSegment(ctx, id, x, w);
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
        if (drew and !omit_gap) self.paintGap(painted.end_x, scaled_spacing);
        return if (drew)
            painted.end_x + (if (omit_gap) 0 else scaled_spacing)
        else
            x_before + w;
    }

    fn paintGap(self: *State, gap_x: u16, scaled_spacing: u16) void {
        self.clearRegion(gap_x, scaled_spacing);
    }

    /// Repaints the bar into the off-screen pixmap. When every segment is
    /// dirty (full redraw) the whole background is cleared once;
    /// otherwise only the dirty segments' regions are repainted, leaving
    /// unchanged pixels from the previous frame untouched.
    /// Solves the frame's row geometry and paints it. The two halves talk
    /// through one `RowPlan` (20.1): solve measures and pins every slot, paint
    /// walks the plan in paint order. Nothing in solve draws, and nothing in
    /// paint measures.
    pub fn drawAllInner(self: *State, ctx: *segmod.DrawCtx) void {
        const r = &self.render;
        const is_full_redraw = self.isFullDirty();
        self.dirty.span_x = 0;
        self.dirty.span_w = 0;

        if (is_full_redraw) {
            self.clearRegion(0, r.width);
        }

        var plan: RowPlan = .{ .right_x = r.width };
        self.solveRowPlan(ctx, &plan);
        self.paintRowPlan(ctx, &plan, is_full_redraw);
    }

    /// Measures the frame into `plan`: right-cluster widths and their backward
    /// positions first (so left/center know how much room is gone), then the
    /// left/center rows forwards. Records nothing on `self` -- the click and
    /// ticker-scope bookkeeping belongs to paint, which is the only half that
    /// knows a slot actually got drawn.
    fn solveRowPlan(self: *State, ctx: *segmod.DrawCtx, plan: *RowPlan) void {
        const r = &self.render;
        const frame = &ctx.frame;
        const scaled_spacing = renderBar().scaledSpacing(r.height);
        plan.cluster.scaled_spacing = scaled_spacing;
        plan.cluster.right_x = r.width;

        // Right cluster: measure once, up front, for two reasons. Left/center
        // placement must shrink around the space it will occupy, and the draw
        // must not re-measure what solve already knows.
        for (renderBar().layout.items) |lay| {
            if (lay.position != .right) continue;
            for (lay.segments.items) |seg| {
                const w = self.measureSegmentWidth(frame, segmod.segId(seg));
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
        for (renderBar().layout.items) |lay| {
            switch (lay.position) {
                .left, .center => {
                    // Space before the right cluster; saturating because a
                    // pathological reservation must clamp at 0, not wrap.
                    const avail = r.width -| claimed -| plan.right_total;
                    const budget = center_row.centerRowBudget(lay, avail, scaled_spacing, frame, self.clock.width);
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
                            self.measureSegmentWidth(frame, id);
                        // Center slots are contiguous, so neither the claim
                        // nor the paint cursor adds a gap after one.
                        claimed = claimed +% w +% (if (is_center) 0 else scaled_spacing);
                        plan.push(.{
                            .id = id,
                            .w = w,
                            .omit_gap = is_center,
                            .center_idx = center_idx,
                            .repaintable = self.isSegmentRepaintable(id),
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
                        const seg_w = if (widths) |ws| ws[i] else self.measureSegmentWidth(frame, id);
                        // Saturating: a pathological width sum clamps at 0
                        // instead of wrapping into a rightward paint.
                        cur_x = cur_x -| seg_w;
                        if (pending_gap) cur_x = cur_x -| scaled_spacing;
                        plan.push(.{
                            .id = id,
                            .w = seg_w,
                            .x = cur_x,
                            .repaintable = self.isSegmentRepaintable(id),
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

    /// Walks the solved plan in paint order and draws it. The single flat loop
    /// replaces the old interleaved placement loop: the backward right-cluster
    /// cursor, which used to live in drawRightSegments, is already baked into
    /// the plan's slot positions.
    fn paintRowPlan(self: *State, ctx: *segmod.DrawCtx, plan: *const RowPlan, is_full_redraw: bool) void {
        const scaled_spacing = renderBar().scaledSpacing(self.render.height);
        // Left/center advance, threaded separately from the plan's right-cluster
        // positions: a right slot's `x` is final, but a left/center slot's is
        // only where it started, because the draw can move the cursor.
        var x: u16 = 0;
        var pending_gap = false;

        self.clicks.len = 0;
        for (plan.slots[0..plan.len]) |slot| {
            // Right slots carry a solved x; left/center slots take the live
            // cursor. Both feed the same two recordings, which is why this is
            // the only place they are made: a self-ticker's scope and a
            // segment's click bound must agree with where the paint landed.
            //
            // Self-ticker scope is recorded in ANY cluster: drawClockOnly
            // depends on it regardless of where the clock is laid out.
            const slot_x = if (slot.is_right) slot.x else x;
            if (slot.self_ticking) self.recordSelfTickerScope(slot.id, slot_x, slot.w);
            self.recordClickBound(slot.id, slot_x, slot.w);

            if (!slot.repaintable) {
                // Not repaintable: the slot is reserved space only, and the
                // cursor still has to move past it. Plain `+=` on purpose, to
                // keep the wrap-in-debug arithmetic identical to the loop this
                // replaced; a config that overflows u16 here is a config bug,
                // and silently saturating would hide it behind a wrong layout
                // instead of a loud failure.
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
                self.clearRegion(slot_x, clear_w);
            }

            if (slot.is_right) {
                // Right cluster, already positioned backwards by solve. A new
                // layout starts a fresh gap run: layouts are spaced by
                // `right_total`, not by a painted gap, so inheriting the
                // previous layout's pending gap would clear a second time
                // where the old per-layout loop started clean.
                if (slot.right_layout_start) pending_gap = false;
                const drew = self.drawSegment(ctx, slot.id, slot.x, slot.w).drew;
                if (drew and pending_gap) self.paintGap(slot.x +| slot.w, scaled_spacing);
                // A failed draw still occupies its slot as empty space, so the
                // next leftward segment gets the same gap solve computed. That
                // uniformity is what keeps placement from desyncing next frame.
                pending_gap = true;
            } else {
                const x_before = x;
                x = self.drawRowSegment(ctx, slot.id, x, slot.w, slot.omit_gap, scaled_spacing);
                if (x != x_before) self.extendDirtySpan(x_before, x - x_before);
            }
            self.clearSegmentDirty(slot.id);
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
/// Full hidden-set synthesis forwarded to the hide-family provider
/// (DrawCtx api signature).
pub fn minimizedCollect(
    m: *const anyopaque,
    set: *std.AutoHashMapUnmanaged(u32, void),
    allocator: std.mem.Allocator,
) void {
    const mm: *const model.Model = @ptrCast(@alignCast(m));
    if (collect_hidden_set) |wm|
        wm.collectHiddenSet.?(mm, set, allocator);
}
