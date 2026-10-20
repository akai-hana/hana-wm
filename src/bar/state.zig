//! The bar's live state: the `State` value and everything that only exists
//! to describe or locate it -- the `Bar`/`gBar` handle, the segment-registry
//! identity helpers, and the hook walkers.
//!
//! The state lives in its own leaf so `render` and `input_events` -- both
//! imported by `bar.zig`, both reading this state on every batch -- can reach
//! it without importing `bar.zig` back and closing a cycle.
//!
//! Nothing here performs X work or decides anything: it is data plus
//! `init`/`deinit`. Lifecycle (create/destroy/reload), polling, and the
//! chrome stay in `bar.zig`; frame collection, the paint pass, and the
//! State operations (damage, click bounds, clock scope, measurement) live
//! in `render.zig`.

const std = @import("std");
const core = @import("core");
const types = @import("types");
const bar_config = @import("bar_config");
const query = @import("query");
const model = @import("model");
const window_facts = @import("window_facts");
const drawing = @import("drawing");
const segmod = @import("segment");
const vocab = @import("vocab");
const barwin = @import("win");
const center_row = @import("center_row");

// The capability sets live in segment.zig (their one home); these aliases
// keep state's remaining reader (`title_id`) unqualified.
const self_ticking_ids = segmod.self_ticking_ids;
const center_slot_ids = segmod.center_slot_ids;

/// Primary center-slot segment: the FIRST center-slot binder in registry
/// order (config order within a center layout). Title-centric bar behaviors
/// (click-to-focus, chrome-overlay toggle) route through it; with a single
/// binder this is exactly the title, with several it is the leftmost one.
pub const title_id: ?usize = if (center_slot_ids.len != 0) center_slot_ids[0] else null;

/// Minimum spacing between two log lines for the SAME draw failure (P2-62):
/// a permanently broken segment fails on every dirty frame, and one warn per
/// frame is how a real fault gets drowned in the journal. The FIRST
/// occurrence always logs (its stamp is 0); after that at most one line per
/// interval, per segment id.
pub const draw_fail_log_interval_ms: i64 = 10_000;

/// Pure rate-limit decision over one failure-log stamp slot: log when the
/// stamp says "never" (0) or the interval has elapsed, stamping on every
/// admitted line. Pure in `now` so a test drives synthetic time; `now` is a
/// realtime-ms clock and must be non-zero (a zero stamp means "never").
pub fn failLogDue(stamp: *i64, now: i64, interval_ms: i64) bool {
    if (stamp.* != 0 and now - stamp.* < interval_ms) return false;
    stamp.* = now;
    return true;
}

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
    /// win.zig's single teardown, so both real teardown paths -- shutdown and
    /// the reload-time recreate -- cannot remember one half and forget the
    /// other: a path that forgot `xcb_destroy_window` would leak the window
    /// and keep the bar on screen with no way back to it. The errdefer on a
    /// half-built bar is the only place that has to reach past this.
    pub fn deinit(self: *WindowCtx) void {
        barwin.destroyBarWindow(self.conn, self.win_id, self.colormap);
    }
};

/// The live bar configuration, read straight from core rather than copied:
/// a copy would borrow slices from a config the caller frees, and need a
/// re-point on every reload path -- nothing to re-point, nothing to forget.
pub inline fn renderBar() bar_config.Config {
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
    /// The `layout_gen` this bound was solved in (P2-63). A region-scoped
    /// repaint paints at these coordinates, so a bound stamped by an older
    /// layout pass than the current one is stale: Debug asserts on it before
    /// painting, instead of the old comment-only precondition.
    gen: u64 = 0,

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
/// region-scope its repaint.
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
    /// the blit copies only the changed region.
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
    /// The `layout_gen` this scope was recorded in (P2-63). drawClockOnly's
    /// region-scoped tick paints at these coordinates, so a scope stamped by
    /// an older layout pass than the current one is stale: Debug asserts on
    /// it before painting, instead of the old comment-only precondition.
    gen: u64 = 0,
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
    /// (id only until fillDrawCtx annotates title + geom).
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
/// fillDrawCtx from the WM-owned title cache (window_facts.peekTitle) and the
/// sync truth-rect -- never the wire, so no async fetch, no positional slot,
/// no X11 in the draw path.
const TitleScratch = struct {
    minimized: std.AutoHashMapUnmanaged(u32, void) = .{},
    /// Title addon's minimized-state service, cached from the DrawCtx after
    /// the first draw so scanLiveFrame can synthesize the set each frame
    /// without bar.zig naming the minimize addon.
    minimized_api: segmod.MinimizedApi = .{},
    /// Storage for the focused window's title. The per-window titles
    /// on `frame.entries` borrow straight from the window_facts (they are
    /// refreshed every frame before the draw); the focused title is copied
    /// instead, because a borrowed slice would leave the DrawCtx pointing
    /// into a cache that a title change overwrites in place. That is the
    /// same window as often as not -- the focused window is usually also in
    /// the frame's entry list, whose title is refreshed right beside this
    /// copy -- so the one field with the widest lifetime needs the one byte
    /// copy. Copying costs one memcpy and removes the question of which
    /// readers may hold the slice across a cache write.
    focused_title_buf: [window_facts.max_title_len]u8 = undefined,
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
    /// A batch that hit `max_batched_redraws` still owes a frame that no draw
    /// in that batch landed. The next poll must not sleep: `pollTimeoutMs`
    /// reports 0 so the loop wakes, folds the owed work and ships it now
    /// instead of at the next module deadline -- which on an idle bar is the
    /// clock's whole-second boundary. One-shot by construction: cleared by
    /// that wake and set only at the cap exit, so a module that re-requests
    /// forever degrades to the ordinary timer cadence instead of spinning a
    /// 0-timeout poll.
    owed_redraw: bool = false,
    /// Per-segment last draw-failure log stamp (realtime ms; 0 = never
    /// logged), plus one trailing slot for failures with no resolvable
    /// segment id (the `reportDrewNothing` null-id path). Drives the
    /// `draw_fail_log_interval_ms` rate limit (P2-62): a permanently broken
    /// segment fails every dirty frame, and one warn per frame is how a real
    /// fault gets drowned in the journal.
    draw_fail_log_ms: [segmod.all().len + 1]i64 = @splat(0),
    /// Layout-pass generation (P2-63): bumped by every `solveRowPlan` and
    /// stamped into each recorded scope/bound (`SelfTickerScope.gen`,
    /// `SegBound.gen`). Region-scoped repaints assert (Debug) that the stamp
    /// matches before painting at the recorded coordinates, turning the old
    /// comment-only "bound must match the current layout" precondition into a
    /// tripwire. A reload rebuilds State, so a mismatch can only be a logic
    /// bug -- never a stale config artifact.
    layout_gen: u64 = 0,
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
        config: bar_config.Config,
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

    /// Whether the draw failure for `id` (null = no resolvable segment) is
    /// DUE a log line at `now`, stamping its slot when it is. A registry
    /// index maps to its own slot; the null/unresolvable case shares the one
    /// trailing slot, since there is no segment identity to key on.
    pub fn drawFailLogDue(s: *State, id: ?usize, now: i64) bool {
        const slot = if (id) |i| @min(i, s.draw_fail_log_ms.len - 1) else s.draw_fail_log_ms.len - 1;
        return failLogDue(&s.draw_fail_log_ms[slot], now, draw_fail_log_interval_ms);
    }
};
