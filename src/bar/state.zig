//! The bar's live state: the `State` value and everything that only exists
//! to describe or locate it -- the `Bar`/`gBar` handle, the segment-registry
//! identity helpers, and the hook walkers.
//!
//! Split OUT of `bar.zig` to break the import cycles: `render` and
//! `input_events` read this state on every batch, and importing
//! `bar.zig` for it dragged them into a cycle with the file that also
//! drives them (bar.zig imports both). With the state in its own leaf,
//! those two import THIS file and nothing imports them back.
//!
//! Nothing here performs X work or decides anything: it is data plus
//! `init`/`deinit`. Lifecycle (create/destroy/reload), polling, and the
//! chrome stay in `bar.zig`; frame collection, the paint pass, and the
//! State operations (damage, click bounds, clock scope, measurement) live
//! in `render.zig` (Phase 4 step 23, unified in Phase 3).

const std = @import("std");
const core = @import("core");
const types = @import("types");
const query = @import("query");
const model = @import("wm_state");
const title_cache = @import("title_cache");
const drawing = @import("drawing");
const segmod = @import("segment");
const vocab = @import("vocab");
const barwin = @import("win");
const center_row = @import("center_row");
const contract = @import("contract");

// The capability sets live in segment.zig (their one home); these aliases
// keep state's remaining reader (`title_id`) unqualified.
const self_ticking_ids = segmod.self_ticking_ids;
const center_slot_ids = segmod.center_slot_ids;

/// Primary center-slot segment: the FIRST center-slot binder in registry
/// order (config order within a center layout). Title-centric bar behaviors
/// (click-to-focus, chrome-overlay toggle) route through it; with a single
/// binder this is exactly the title, with several it is the leftmost one.
pub const title_id: ?usize = if (center_slot_ids.len != 0) center_slot_ids[0] else null;

/// Global bar coordination flags. Read and written exclusively on the main
/// thread; no mutex protection required.
pub const Bar = struct {
    state: ?*State = null,
    /// True when `presentForPrompt` (bar.zig) had to map an
    /// otherwise-hidden bar (e.g. hidden by a fullscreen window, or by the
    /// user toggling it off) purely so the inline prompt would be visible.
    /// `dismissAfterPrompt` checks this to know whether hiding the bar
    /// again is part of "returning to normal" -- the flag's whole
    /// lifecycle (set, cleared, guarded against) lives in `bar.zig`.
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
pub const max_click_bounds: usize = segmod.all().len;

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

/// Live frame state (recollected on every draw; see scanLiveFrame). Holds
/// the shared `segmod.Frame` directly (workspace_count/current_workspace/
/// is_all_view_active) plus the bar-local backing array it slices, so the
/// segment-visible struct stays the single source instead of a mirror.
const FrameState = struct {
    frame: segmod.Frame = .{},
    /// Backing array for `frame.workspace_has_windows` (the shared struct
    /// only holds the slice).
    ws_has_windows: [model.max_workspaces]bool = @splat(false),
    /// The current workspace's windows for the frame, one entry per window
    /// (id only until fillDrawCtx annotates title + geom; the AoS record
    /// replaces the separate `wins` / titles_buf / geoms_buf arrays).
    entries: [max_frame_windows]vocab.TitleEntry = undefined,
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
/// fillDrawCtx from the WM-owned title cache (title_cache.peekTitle) and the
/// sync truth-rect -- never the wire, so no async fetch, no positional slot,
/// no X11 in the draw path.
const TitleScratch = struct {
    minimized: std.AutoHashMapUnmanaged(u32, void) = .{},
    /// Title addon's minimized-state service, cached from the DrawCtx after
    /// the first draw so scanLiveFrame can synthesize the set each frame
    /// without bar.zig naming the minimize addon.
    minimized_api: segmod.MinimizedApi = .{},
    /// Storage for the focused window's title. The per-window titles
    /// on `frame.entries` borrow straight from the title_cache (they are
    /// refreshed every frame before the draw); the focused title used to be
    /// a slice straight into the title_cache's per-window `title_buf`, so the
    /// DrawCtx retained a borrowed pointer into a cache that a title change
    /// overwrites in place. That is the same window as often as not -- the
    /// focused window is usually also in the frame's entry list, whose title
    /// is refreshed right beside this copy -- so the one field with the
    /// widest lifetime needed the one byte copy. Copying costs one memcpy and
    /// removes the question of which readers may hold the slice across a
    /// cache write.
    focused_title_buf: [title_cache.max_title_len]u8 = undefined,
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
/// (via the DrawCtx), never State itself. Its operations (damage, click
/// bounds, clock scope, measurement) live beside the paint pass in
/// `render.zig`; this file keeps `init`/`deinit`.
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
        // segment.Opts.invalidate).
        segmod.runVoidHook(.invalidate);
        return s;
    }

    pub fn deinit(self: *State) void {
        self.win.deinit();
        const alloc = self.render.allocator;
        self.title_data.minimized.deinit(alloc);
        alloc.destroy(self);
    }
};
