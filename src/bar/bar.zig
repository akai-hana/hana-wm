//! Status bar
//! Creates and manages the WM status bar, rendering all configured segments.
//!
//! Rendering uses per-segment dirty tracking: the dirty set is registry-sized
//! (one bool per bar_modules entry); only dirty segments are repainted on
//! each draw. The whole-bar flag alongside an all-dirty set (the folded "full
//! redraw" request) triggers a complete background clear + repaint. Coalescing
//! happens through the dirty-mark scheduling (scheduleRedraw & friends).
//!
//! Bar segments are an open, drop-in addon set: the build generates the
//! `bar_modules.modules` registry and this orchestrator owns NO segment logic.
//! Lifecycle/polls/draw/width/click/prompt-extras are all driven by uniform
//! loops over that registry, dispatching through the Segment contract. The bar
//! never names a specific segment module: services flow one-way
//! through `segmod.BarHandlers`, the prompt overlay lives in the title module,
//! and reverse edges are resolved through the registry.

const std = @import("std");
const build_options = @import("build_options");

const core = @import("core");
const xcb = core.xcb;
const usable_area = @import("usable_area");
const scale = @import("dpi");
const constants = @import("constants");
const log = @import("log");

const types = @import("types");

const tracking = @import("tracking");
const focus = @import("focus");
const pipeline = @import("pipeline");
const actions = @import("actions");
const model = @import("model");
const reconcile = @import("reconcile");
const wincache = @import("wincache");

const window = @import("window");

const drawing = @import("drawing");
const metrics = @import("metrics");
const Metrics = metrics.Metrics;
const segmod = @import("segment");
const scaffold = @import("scaffold");
const title_geom = @import("geom");
const barwin = @import("win");
const center_row = @import("center_row");

// Bar visibility subsystem (pure decisions only; bar.zig keeps the wire glue).
const visibility = @import("visibility");
const visibility_glue = @import("visibility_glue");
const input_events = @import("input_events");
const draw = @import("draw");

// Window-addon registry (generated): the hidden-set synthesis is routed
// through the collectHiddenSet seam instead of naming the minimize or
// fullscreen module directly.
const window_mods = @import("window_modules").modules;
const contract = @import("contract");

const requests = @import("requests");
/// The hide-family provider bound to the generated window registry, resolved
/// once at file scope: the hidden-set synthesis and its collect dispatch
/// share one lookup (no module is ever named by the bar).
const collect_hidden_set = window.providerOf(.collectHiddenSet);

// Registry-resolved segment identity (comptime): the bar locates modules by
// name through the generated registry instead of importing them directly.
// Role/named lookups return null on an absent (even empty) registry, so the
// bar still compiles and no-ops when ALL segments are removed.
const bar_mods = @import("bar_modules").modules;

const self_ticking_ids: []const usize = segmod.findAllByCapability(&bar_mods, .self_ticking);
const center_slot_ids: []const usize = segmod.findAllByCapability(&bar_mods, .center_slot);

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

/// Dirty-bit read for a resolved `id` (comptime guarded as segAt).
inline fn segDirty(self: *const State, id: usize) bool {
    if (comptime !segmod.hasRegisteredSegments()) unreachable;
    return self.dirty.segments[id];
}

/// Dirty-bit write for a resolved `id` (comptime guarded as segAt).
inline fn setSegDirty(self: *State, id: usize, v: bool) void {
    if (comptime !segmod.hasRegisteredSegments()) unreachable;
    self.dirty.segments[id] = v;
}

/// Index of `name` within the registry-id set `comptime ids` (the
/// self-ticking and center-slot capability sets today), or null when it is
/// not a member. Name-free: membership is by declared capability, and the set
/// is resolved from the generated registry.
fn roleIndexOf(name: []const u8, comptime ids: []const usize) ?usize {
    const id = segmod.segId(name) orelse return null;
    inline for (ids, 0..) |rid, i| {
        if (id == rid) return i;
    }
    return null;
}

/// True when `name` resolves to a segment in the registry role set `ids`.
fn isRole(name: []const u8, comptime ids: []const usize) bool {
    return roleIndexOf(name, ids) != null;
}

/// Position of `name` within `self_ticking_ids` (the key into
/// `Clock.segs`), or null when it is not a self-ticking segment.
fn selfTickerIndex(name: []const u8) ?usize {
    return roleIndexOf(name, self_ticking_ids);
}

pub fn runVoidHook(comptime hook: std.meta.FieldEnum(contract.Segment)) void {
    contract.callAll(contract.Segment, bar_mods[0..], hook, .{});
}

fn anyBoolHook(comptime hook: std.meta.FieldEnum(contract.Segment), args: anytype) bool {
    return contract.callFirstTrue(contract.Segment, bar_mods[0..], hook, args);
}

// Bar height / font-size resolution.
//
// The RULES live in bar/metrics.zig (`metrics.resolve`), which is pure: it
// takes the configured values, the screen, and a font probe, and returns a
// `Metrics` value. This section only supplies the two live pieces -- the
// current config, and a probe that measures through
// drawing.probeFontMetrics' throwaway surface (no live DrawContext is
// touched) -- and threads the result into bar creation, draw-context
// construction, and the surviving State's own value. No global, no config
// mutation, and no save/restore: a bar's metrics belong to that bar (21.5).

/// Measures the configured fonts at `trial_pt`. The point size is always
/// explicit: the only two callers are the metric probe itself (a fixed trial
/// size) and `metrics.resolve`'s height decision, which measures at the
/// DPI-scaled base.
fn probeMetrics(trial_pt: u16) ?drawing.FontMetrics {
    const cs = core.getState();
    var sized = drawing.SizedFontList.build(cs.alloc, cs.config.bar.fonts.items, trial_pt) catch return null;
    defer sized.deinit();
    return drawing.probeFontMetrics(
        cs.alloc,
        core.dpi(),
        sized.items,
    );
}

/// Resolves the bar's metrics from the live config and screen. The rules
/// themselves live in `metrics.resolve` (21.5); this only supplies them.
fn resolveBarMetrics() Metrics {
    const cs = core.getState();
    return metrics.resolve(.{
        .font_size = cs.config.bar.font_size,
        .height = cs.config.bar.height,
        .screen_height = cs.screen.height_in_pixels,
    }, probeTextHeight);
}

/// The `metrics.Probe` adapter: the configured fonts' ascent+descent at a
/// trial point size, or null when none could be measured.
///
/// Pango reports i16 and a descent is a positive-downward distance here, so
/// the total is taken in i32 and floored at 0: a font that reports a
/// pathological negative total must clamp to "no measurement" rather than
/// wrap through `@intCast` in ReleaseFast.
fn probeTextHeight(trial_pt: u16) ?u32 {
    const m = probeMetrics(trial_pt) orelse return null;
    const total: i32 = @as(i32, m.ascent) + @as(i32, m.descent);
    if (total <= 0) return null;
    return @intCast(total);
}

/// Uniform poll wakeup: runs every module's onPollWakeup hook (prompt caret
/// blink, marquee repaint-marking, ...) then submits a draw. The bar never
/// names a segment.
pub fn onPollWakeup() void {
    // First gate is the lifecycle: with no live bar (disabled via config
    // reload, pre-init, or post-deinit), module hooks must not run at all --
    // the cadence here is what would put a dead-module background wake up at
    // the frame rate.
    const s = gBar.state orelse return;
    runVoidHook(.onPollWakeup);
    // A module's poll hook (e.g. the prompt's caret-blink toggle) must reach
    // the draw's repaint gate: fold any queued module redraw request into the
    // dirty state as a full redraw, exactly as the X-batch update path
    // (updateIfDirty) does, so the animation is visible even when the loop is
    // waking only on the poll timer with no X traffic to trigger that path.
    // performDraw consumes the redraw request itself; no consume here.
    _ = draw.foldModuleRedraw(s);
    draw.performDraw();
}

/// Combines every module's poll deadline (clock tick, prompt caret blink,
/// carousel scroll) into the shortest non-negative wait, or null when no
/// module wants one. Module hooks still speak in negatives ("no wake needed");
/// THIS is the single place that turns that into absence, because it is the
/// bar's whole contribution to core's deadline reduction (see core/loop/timers).
pub fn pollTimeoutMs() ?i32 {
    // A bar-less session wants no wakeups from module hooks at all: polling,
    // then dispatching every dead module's cadence at the frame rate, is a
    // real idle-consumption bug (a bar disabled via reload never stops its
    // clocks but keeps dispatching).
    const s = gBar.state orelse return null;
    // A hidden bar paints nothing, so no per-frame deadline (clock tick,
    // caret blink, carousel scroll) can make progress...
    if (!s.vis.shown) return null;

    // Module hooks still speak in negatives ("no wake needed"); THIS is the
    // single place that turns that into absence, because it is the bar's
    // whole contribution to core's deadline reduction. Reducing to `null`
    // here is what keeps a hidden or empty-set bar from starving other tick
    // sources -- a bare -1 would slip past the reduce as an immediate
    // "want to wake NOW" preference.
    var nearest: ?i32 = null;
    for (bar_mods) |m| {
        if (m.pollTimeoutMs) |h| {
            const t = h();
            if (t >= 0 and (nearest == null or t < nearest.?)) nearest = t;
        }
    }
    return nearest;
}

/// Routes a keypress through every module that consumes one (the chrome
/// overlay segment).
pub fn chromeHandleKeypress(
    event: *const xcb.xcb_key_press_event_t,
    matched: ?*const types.Action,
) bool {
    // `Segment.handleKeypress` takes the OPAQUE `contract.KeyPressEvent`, so
    // the cast happens here: this is the one place a real X key-press event
    // enters the segment registry, and the bar is the only producer of it.
    const key_event: *const contract.KeyPressEvent = @ptrCast(event);
    return anyBoolHook(.handleKeypress, .{ key_event, matched });
}

/// Toggles the chrome overlay. Routed through the resolved title module's
/// onClick hook (right-click path): the overlay lives in the title module
/// and the bar must not name it.
pub fn chromeToggleOverlay() void {
    const s = gBar.state orelse return;
    if (input_events.titleIdBound(s)) |tb| {
        const is_right_click = true;
        input_events.dispatchClick(s, tb.id, 0, false, is_right_click);
    }
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

/// Bar-provided service handles for mechanism segments (the prompt), owned for
/// the whole bar lifetime. MUST NOT be a stack local in `init()`: the registry
/// init loop hands `&g_bar_handlers` to each segment, and the prompt retains
/// that pointer past init() to call back on every toggle/keystroke. A local
/// would dangle the moment init() returns and crash on the first prompt toggle
/// (use-after-return). The three handlers are stateless bar functions, so the
/// value is assigned once at init and never changes.
var g_bar_handlers: segmod.BarHandlers = undefined;

/// X11 connection and window handle; stable for the bar's lifetime.
const WindowCtx = struct {
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
    fn deinit(self: *WindowCtx) void {
        barwin.destroyBarWindow(self.conn, self.win_id, self.colormap);
    }
};

/// The live bar configuration. The render state used to hold its own
/// `types.BarConfig` copy and needed a `refreshConfig()` re-point on every
/// reload path -- a second source of truth that silently borrowed slices from
/// a config the caller frees a few lines later. One accessor, reading core,
/// means there is nothing to re-point and nothing to forget.
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
const max_frame_windows: usize = segmod.max_visible_windows;

/// Upper bound on recorded click bounds: one slot per clickable segment in
/// the configured layout. Configs with more clickable segments than this
/// simply lose clickability on the extras (rendering is unaffected).
const max_click_bounds: usize = bar_mods.len;

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

/// Cap on updateIfDirty's re-request redraw loop: a module that keeps
/// re-requesting a full redraw past this many iterations is treated as a
/// stall (logged), keeping a rogue module from busy-spinning the batch.
const max_batched_redraws: u8 = 4;

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
/// with no draw call anywhere near it. (20.1)
///
/// The split exists because geometry, hit-testing and painting were one unit
/// of change in drawAllInner: adding a segment meant editing a loop that
/// measured it, recorded its click bound, scoped its ticker, cleared its
/// region and drew it, all interleaved. Solve produces these; paint walks them.
const RowSlot = struct {
    /// Segment name, as it appears in the layout.
    name: []const u8,
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
const RowPlan = struct {
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
/// these in recorded order (first match wins). The name is borrowed from the
/// config's layout list (stable for the bar's lifetime).
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
    /// Asked-to-be-shown; cleared by the per-segment empty checks.
    shown: bool = true,
    /// Shown-ness after the fullscreen sink reported every screen occupied:
    /// the bar must hide even though no segment requested a hide.
    preferred: bool = true,
};

const Dirty = struct {
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

const Clock = struct {
    /// Shared clock-display width scratch: the bar-wide MERGED display width
    /// of the self-ticking segments (max across them), read by every
    /// naturalWidth hook as its clock budget and re-derived on a clock
    /// display-mode cycle.
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
    ws_has_windows: [constants.max_workspaces]bool = @splat(false),
    wins: [max_frame_windows]u32 = undefined,
    wins_len: usize = 0,
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

/// Title-data scratch: the current workspace's window title/geometry values
/// for the frame plus the minimized-set service. Titles are read from the
/// WM-owned title cache (wincache.peekTitle) and stale never: no async
/// fetch, no positional slot, no X11 in the draw path.
const TitleScratch = struct {
    minimized: std.AutoHashMapUnmanaged(u32, void) = .{},
    /// Title addon's minimized-state service, cached from the DrawCtx after
    /// the first draw so scanLiveFrame can synthesize the set each frame
    /// without bar.zig naming the minimize addon.
    minimized_api: segmod.MinimizedApi = .{},
    /// Per-window titles/geoms for the current frame, filled by fillDrawCtx
    /// from the title cache and the sync truth-rect (never the wire). Valid
    /// in [0, frame.wins_len) for the frame; the DrawCtx's title snapshot
    /// points into them and click hit-testing reuses them after the draw.
    titles_buf: [max_frame_windows][]const u8 = undefined,
    geoms_buf: [max_frame_windows]?model.Rect = undefined,
    /// Storage for the focused window's title. (11.9) The `titles_buf` entries
    /// above are copies; the focused title used to be a slice straight into
    /// the wincache's per-window `title_buf`, so the DrawCtx retained a
    /// borrowed pointer into a cache that a title change overwrites in place.
    /// That is the same window as often as not -- the focused window is
    /// usually also in `wins_slice`, and it is copied on the line above --
    /// so the one field with the widest lifetime had the only unguarded
    /// borrow. Copying costs one memcpy and removes the question of which
    /// readers may hold the slice across a cache write.
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
    /// scrolled segment's recorded bound (see redrawScrolledSegment) instead
    /// of forcing a full-bar redraw. Set around the dispatch in
    /// handleButtonPress and cleared before it returns.
    scroll_segment: ?usize = null,
    frame: FrameState = .{},
    title_data: TitleScratch = .{},
    facts: Facts = .{},

    fn init(
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
        // contributes 0).
        const clock_width = center_row.mergedClockWidth(dc, config, height, drawing.DrawContext.measureTextWidth);
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
        // Width caches for size-varying segments (workspaces/layout/variants)
        // are invalidated per bar creation via their uniform invalidate hooks.
        runVoidHook(.invalidate);
        return s;
    }

    fn deinit(self: *State) void {
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

    pub fn clearSegmentDirty(self: *State, name: []const u8) void {
        if (segmod.segId(name)) |id| setSegDirty(self, id, false);
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
    fn markDirtySource(self: *State, source: segmod.DirtySourcesSource) void {
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
    fn isSegmentRepaintable(self: *const State, name: []const u8) bool {
        const id = segmod.segId(name) orelse return false;
        if (segDirty(self, id)) return true;
        if (segAt(id).needsRepaint) |q| return q();
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
    /// scan would always match and defeat the fast-path early-exit).
    inline fn anyLayoutSegment(self: *const State, comptime pred: anytype) bool {
        for (renderBar().layout.items) |lay| {
            for (lay.segments.items) |seg| {
                if (pred(self, seg)) return true;
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
        for (renderBar().layout.items) |lay| {
            for (lay.segments.items) |name| {
                const id = segmod.segId(name) orelse continue;
                if (segDirty(self, id)) return true;
            }
        }
        return false;
    }

    /// Records the on-screen bounds of a clickable segment as the layout pass
    /// positions it, so handleButtonPress can hit-test against them without
    /// redoing the layout. Called unconditionally for every segment; segments
    /// whose module declares `clickable == false` are skipped.
    fn recordClickBound(self: *State, name: []const u8, x: u16, w: u16) void {
        const id = segmod.segId(name) orelse return;
        if (!segAt(id).clickable) return;
        if (self.clicks.len >= max_click_bounds) return;
        self.clicks.bounds[self.clicks.len] = .{ .id = id, .x = x, .w = w };
        self.clicks.len += 1;
    }

    pub fn recordedBound(self: *const State, id: usize) ?SegBound {
        for (self.clicks.bounds[0..self.clicks.len]) |b| {
            if (b.id == id) return b;
        }
        return null;
    }

    /// Measures a segment's natural (reserved) width via its uniform
    /// naturalWidth hook, or 0 for an unknown/removed segment name.
    fn measureSegmentWidth(self: *State, frame: *const segmod.Frame, name: []const u8) u16 {
        const id = segmod.segId(name) orelse return 0;
        // The hook takes a real `*const contract.Frame` (21.1), and
        // `segmod.Frame` is an alias for exactly that, so this passes the
        // frame through with no cast and no promise-in-a-comment.
        if (segAt(id).naturalWidth) |nw| return nw(frame, self.clock.width);
        return 0;
    }

    /// Records the last layout-pass bound of a self-ticking segment so its
    /// end-of-batch tick can region-scope a repaint (drawClockOnly). Written
    /// for every configured self-ticker in ANY cluster (left/center/right);
    /// unconfigured self-tickers stay invalid and are never repainted.
    fn recordSelfTickerScope(self: *State, name: []const u8, x: u16, w: u16) void {
        // `comptime` on the length: with no self-ticking segment compiled in,
        // `Clock.segs` is a zero-length array and the indexed store below is
        // still analyzed, which is a compile error. The length is a comptime
        // constant, so this drops the whole body before it is analyzed.
        if (comptime self_ticking_ids.len == 0) return;
        if (selfTickerIndex(name)) |i| {
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
        // arrays live on State, valid for the rest of the frame AND for
        // post-draw click handling through the cached `frame.last_ctx`.
        const wins_slice = self.frame.wins[0..self.frame.wins_len];
        for (wins_slice, 0..) |w, i| {
            self.title_data.titles_buf[i] = wincache.peekTitle(w);
            self.title_data.geoms_buf[i] = titleGeom(w, self.title_data.minimized.contains(w));
        }
        // Title of the minimized window, used in the single-window title case.
        var minimized_title: []const u8 = "";
        if (wins_slice.len > 0 and self.title_data.minimized.contains(wins_slice[0]))
            minimized_title = self.title_data.titles_buf[0];
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
        ctx.current_ws_wins = wins_slice;
        ctx.minimized_set = &self.title_data.minimized;
        ctx.titles = self.title_data.titles_buf[0..self.frame.wins_len];
        ctx.geoms = self.title_data.geoms_buf[0..self.frame.wins_len];
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
            self.frame.wins_len = 0;
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
                    self.frame.wins_len < max_frame_windows)
                {
                    self.frame.wins[self.frame.wins_len] = entry.win;
                    self.frame.wins_len += 1;
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
    pub fn drawSegment(self: *State, ctx: *segmod.DrawCtx, name: []const u8, x: u16, width: ?u16) Drawn {
        const id = segmod.segId(name) orelse return .{ .painted = reportDrewNothing(x), .drew = false };
        if (segAt(id).draw == null) return .{ .painted = reportDrewNothing(x), .drew = false };
        // The DrawCtx is shared mutable scratch: pin the reserved width into it
        // immediately before the draw so width-reading renderers (the title)
        // advance correctly. `name` goes in the same way, so a module can
        // resolve its own themed colors (the slider's fill reads
        // segmentValueFg(name)) without the draw hook carrying a per-segment
        // argument.
        ctx.name = name;
        ctx.width = width orelse self.measureSegmentWidth(&ctx.frame, name);
        const painted = segAt(id).draw.?(ctx, x) catch |e| {
            log.warnOnErr(e, "bar drawSegment");
            // A caught error is a broken segment, not a segment with nothing
            // to show: it painted nothing either way, but reporting it as a
            // zero-width PAINT would let the next layout collapse a slot that
            // only failed this once.
            return .{ .painted = contract.Painted.nothing(x), .drew = false };
        };
        return .{
            .painted = painted,
            .drew = scaffold.finishDraw(segAt(id), painted),
        };
    }

    /// Draws one segment of a left-to-right row, painting the inter-segment gap
    /// and advancing `x`. `w` is the reserved width; `omit_gap` suppresses the
    /// gap after a title so the next segment sits flush (center layout).
    /// Returns the new `x`.
    fn drawRowSegment(
        self: *State,
        ctx: *segmod.DrawCtx,
        name: []const u8,
        x: u16,
        w: u16,
        omit_gap: bool,
        scaled_spacing: u16,
    ) u16 {
        const x_before = x;
        const drawn = self.drawSegment(ctx, name, x, w);
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
                const w = self.measureSegmentWidth(frame, seg);
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
                        const is_center = (lay.position == .center) and isRole(seg, center_slot_ids);
                        // Center slots split the whole remaining budget evenly,
                        // left-to-right in config order, and stay contiguous
                        // (no gap) so duplicates cannot reach the right cluster.
                        const w: u16 = if (is_center)
                            center_row.centerShare(remaining, center_count, center_idx)
                        else
                            self.measureSegmentWidth(frame, seg);
                        // Center slots are contiguous, so neither the claim
                        // nor the paint cursor adds a gap after one.
                        claimed = claimed +% w +% (if (is_center) 0 else scaled_spacing);
                        plan.push(.{
                            .name = seg,
                            .w = w,
                            .omit_gap = is_center,
                            .center_idx = center_idx,
                            .repaintable = self.isSegmentRepaintable(seg),
                            .self_ticking = isRole(seg, self_ticking_ids),
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
                        const seg_w = if (widths) |ws| ws[i] else self.measureSegmentWidth(frame, lay.segments.items[i]);
                        // Saturating: a pathological width sum clamps at 0
                        // instead of wrapping into a rightward paint.
                        cur_x = cur_x -| seg_w;
                        if (pending_gap) cur_x = cur_x -| scaled_spacing;
                        plan.push(.{
                            .name = lay.segments.items[i],
                            .w = seg_w,
                            .x = cur_x,
                            .repaintable = self.isSegmentRepaintable(lay.segments.items[i]),
                            .self_ticking = isRole(lay.segments.items[i], self_ticking_ids),
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
            if (slot.self_ticking) self.recordSelfTickerScope(slot.name, slot_x, slot.w);
            self.recordClickBound(slot.name, slot_x, slot.w);

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
                const drew = self.drawSegment(ctx, slot.name, slot.x, slot.w).drew;
                if (drew and pending_gap) self.paintGap(slot.x +| slot.w, scaled_spacing);
                // A failed draw still occupies its slot as empty space, so the
                // next leftward segment gets the same gap solve computed. That
                // uniformity is what keeps placement from desyncing next frame.
                pending_gap = true;
            } else {
                const x_before = x;
                x = self.drawRowSegment(ctx, slot.name, x, slot.w, slot.omit_gap, scaled_spacing);
                if (x != x_before) self.extendDirtySpan(x_before, x - x_before);
            }
            self.clearSegmentDirty(slot.name);
        }
    }

    /// Repaints every self-ticking segment whose on-screen content is stale
    /// (second rolled over). Cheap region-scoped blits, one per ticker.
    fn drawClockOnly(self: *State) void {
        // Same comptime guard as recordSelfTickerScope: the loop body indexes
        // `segs`, which is zero-length when nothing self-ticks.
        if (comptime self_ticking_ids.len == 0) return;
        for (self_ticking_ids, 0..) |cid, i| {
            const sc = self.clock.segs[i];
            if (!sc.valid) continue;
            draw.redrawSlotScoped(self, cid, sc.x, sc.width, null, true);
        }
    }

    /// Re-derives the merged clock display width from the live width probes and
    /// adopts it, reporting whether it moved. Driven by a display-mode cycle:
    /// the next row layout must reserve the incoming mode's span, and the
    /// region-scoped tick blit cannot deliver that (it paints inside the
    /// previously laid-out slot).
    fn adoptFreshClockWidth(self: *State) bool {
        const fresh = center_row.mergedClockWidth(self.render.dc, renderBar(), self.render.height, drawing.DrawContext.measureTextWidth);
        if (fresh == self.clock.width) return false;
        self.clock.width = fresh;
        return true;
    }
};

/// Everything a fully-initialised bar owns; returned by createBar.
const BarSetup = struct {
    setup: barwin.BarWindowSetup,
    state: *State,
};

/// Creates the bar window, off-screen draw context, and live State.
/// On any failure, everything already created is freed before returning.
fn createBar(m: Metrics, y_pos: i16) !BarSetup {
    const height = m.height;
    const cs = core.getState();
    const setup = barwin.createBarWindow(height, y_pos, cs.config.bar.getAlpha16() < 0xFFFF);
    errdefer barwin.destroyBarWindow(cs.conn, setup.win_id, setup.colormap);
    barwin.setWindowProperties(setup.win_id, height);
    const dc = try barwin.createDrawContext(setup, height, m.font_size);
    errdefer dc.deinit();
    log.info(
        "Bar transparency: {s}",
        .{if (setup.has_argb) "enabled (ARGB)" else "disabled (opaque)"},
    );
    const state = try State.init(
        cs.alloc,
        cs.conn,
        setup.win_id,
        setup.colormap,
        cs.screen.width_in_pixels,
        height,
        dc,
        cs.config.bar,
    );
    return .{ .setup = setup, .state = state };
}

// Lifecycle

pub fn init() !void {
    const cs = core.getState();
    std.debug.assert(cs.config.bar.enabled);
    warnUnknownSegments();
    barwin.initAtoms();
    const m = resolveBarMetrics();
    const bar = try createBar(m, barwin.calcBarYPos(cs.config.bar.bar_position, cs.screen.height_in_pixels, m.height));
    gBar.state = bar.state;
    usable_area.setSurfaceWindow(bar.setup.win_id);
    // Map before the first draw (same rationale as applyVisibility: a blit to
    // an unmapped window is discarded, and compositors start remapped windows
    // blank until first damage).
    _ = xcb.xcb_map_window(cs.conn, bar.setup.win_id);
    draw.performDraw();
    _ = xcb.xcb_flush(cs.conn);
    // Uniform lifecycle: every registered mechanism segment (incl. the prompt,
    // whose init owns the vim addon lifecycle) is initialised with the
    // bar's one-way service handles. The handles live in the file-scope
    // g_bar_handlers (bar-lifetime storage); a pointer to a stack local would
    // dangle as soon as this init returns, and the prompt calls back through
    // it on the first toggle.
    g_bar_handlers = .{
        .presentForPrompt = presentForPrompt,
        .dismissAfterPrompt = dismissAfterPrompt,
        .isBarWindow = isBarWindow,
    };
    try contract.callAllTry(contract.Segment, bar_mods[0..], .init, .{ cs.alloc, cs.conn, &g_bar_handlers });
    visibility_glue.syncScreenClaim();
}

pub fn deinit() void {
    const alloc = core.getState().alloc;
    contract.callAll(contract.Segment, bar_mods[0..], .deinit, .{alloc});
    if (gBar.state) |s| {
        s.render.dc.deinit();
        s.deinit();
        gBar.state = null;
    }
    usable_area.releaseClaim(usable_area.bar_id);
    usable_area.clearSurfaceWindow();
}

/// Warns about every segment name in the live bar layout that does not resolve
/// to a registry entry. All four layout consumers skip an unresolvable name
/// (`segmod.segId(name) orelse continue`), so a typo -- or a segment dropped from the
/// build -- silently shortens the bar with nothing on stderr to say which entry
/// is the problem. The layout tree is flat (`BarLayout` is a position plus a
/// segment list), so one nested loop is the whole walk.
///
/// This lives here, not in `config.validate`, because the registry is a
/// `bar_modules` comptime table: config sits below the bar in the dependency
/// graph and importing upward would break the no-bar build.
fn warnUnknownSegments() void {
    if (comptime !segmod.hasRegisteredSegments()) return;
    const cfg = &core.getState().config.bar;
    for (cfg.layout.items) |lay| {
        for (lay.segments.items) |name| {
            if (segmod.segId(name) == null) log.warn(
                "Bar: segment '{s}' is not registered; ignoring it. Check the " ++
                    "spelling, or whether this build includes the module.",
                .{name},
            );
        }
    }
}

pub fn reload() void {
    const old = gBar.state orelse {
        if (core.getState().config.bar.enabled) {
            warnUnknownSegments();
            init() catch |err| log.err("Bar init failed: {}", .{err});
        }
        return;
    };
    if (!core.getState().config.bar.enabled) {
        deinit();
        return;
    }
    warnUnknownSegments();
    applyReload(old, resolveBarMetrics()) catch |err| {
        log.err("Bar reload failed ({s}), keeping old bar", .{@errorName(err)});
    };
}

fn applyReload(old: *State, m: Metrics) !void {
    const height = m.height;
    const cs = core.getState();
    // The reload tears down and rebuilds the bar window, so the whole swap has
    // to be atomic: without a grab the old bar can be destroyed and the new one
    // not yet mapped, which shows as a blank shelf. This path used to call
    // ungrabAndFlush() at the end while NOTHING here took a grab -- an unpaired
    // xcb_ungrab_server. grabOnly (not grabScoped) because the reload runs no
    // geometry pass: building a ctx here would run the pre-reconcile duties,
    // and with no reconcile to follow they would mutate the model for nothing.
    const grab = pipeline.grabOnly();
    defer grab.deinit();
    // Module caches (font widths, caret geometry) are built against the old
    // config; the new one is live from here on either way, so drop them up
    // front, including on the failure path below, where the surviving bar
    // re-points at the NEW live config too.
    runVoidHook(.invalidateReloadCaches);
    // The new bar's metrics were resolved from the NEW config (percentage
    // sizes refine against the new height). If it fails to materialize the
    // surviving bar keeps its OWN metrics -- they live on the old State's
    // value now, so there is no global left to save and put back (21.5).
    const new_bar = createBar(m, barwin.calcBarYPos(cs.config.bar.bar_position, cs.screen.height_in_pixels, height)) catch |err| {
        // The caller has already swapped cs.config to the new config and frees
        // the OLD config when this returns. The old bar survives this failed
        // reload; it used to need its cached config copy re-pointed here or the
        // next draw would read freed memory. It reads the live config now
        // (renderBar), so there is nothing to repair.
        return err;
    };
    const new_state = new_bar.state;
    new_state.vis.shown = old.vis.shown;
    new_state.vis.preferred = old.vis.preferred;
    gBar.state = new_state;
    usable_area.setSurfaceWindow(new_bar.setup.win_id);
    visibility_glue.syncScreenClaim();
    draw.submitDrawBlockingFull();
    if (new_state.vis.shown) _ = xcb.xcb_map_window(cs.conn, new_bar.setup.win_id);
    // No explicit destroy: `deinit` now owns the window and its colormap.
    old.render.dc.deinit();
    old.deinit();
}

// Public event handlers & queries

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

/// Moves the bar window to the edge the config now names, and publishes the
/// resulting screen claim. Returns the new edge-relative y.
///
/// Strictly the renderer's half of a position change: it moves its own window
/// and reports its new occupancy. It does NOT decide which edge that is (core
/// owns that flip), and it does NOT reconcile -- reconciling takes the X grab,
/// and doing that from a rendering module was the layering violation this
/// split exists to remove (20.2). The caller reconciles, after this has
/// published the claim, so window placement is re-derived from the new usable
/// area.
pub fn applyBarScreenPosition() i16 {
    const s = gBar.state orelse return 0;
    const cs = core.getState();
    const new_y = barwin.calcBarYPos(cs.config.bar.bar_position, cs.screen.height_in_pixels, s.render.height);
    barwin.setWindowProperties(s.win.win_id, s.render.height);
    draw.requestFullRedraw();
    // The shared bar window is being re-anchored; drop every recorded
    // self-ticker bound so a stale tick cannot region-scope a repaint before
    // the layout pass re-records them.
    for (&s.clock.segs) |*sc| sc.valid = false;
    // One token owns grab+ungrab+flush. The claim publish is inside the token
    // because it writes a core fact that a reconcile reads; publishing it
    // outside would leave a window between the move and the grab flush.
    const grab = pipeline.grabScoped();
    defer grab.deinit();
    _ = xcb.xcb_configure_window(
        cs.conn,
        s.win.win_id,
        xcb.XCB_CONFIG_WINDOW_Y,
        &[_]u32{model.toXcbCoord(new_y)},
    );
    // The bar window has already moved and bar_position changed, so this
    // publishes the new edge to core BEFORE the caller's reconcile re-derives
    // any placement from it. Core owns the area math; the bar only
    // contributes "I take this many pixels from this edge."
    visibility_glue.syncScreenClaim();
    return new_y;
}

/// The surface hook for the toggle-bar-position action: ask core to flip the
/// edge, then re-anchor. The reconcile that follows is the caller's (see
/// input.zig's `.toggle_bar_position` action), because it is a layout
/// decision made outside the renderer.
pub fn toggleBarSegmentAnchor() void {
    _ = core.toggleBarScreenPosition();
    _ = applyBarScreenPosition();
}

pub fn isBarWindow(win: u32) bool {
    return if (gBar.state) |s| s.win.win_id == win else false;
}

/// Forces the bar to the absolute top of the stacking order and guarantees it
/// is mapped, overriding whatever would normally keep it hidden or covered:
/// a fullscreen window, the user toggling the bar off, or another window
/// raised above it. Used by the inline prompt (prompt.zig) so it is always
/// visible and reachable while active.
///
/// Never touches window geometry or retiles: the bar overlays whatever is
/// already there (fullscreen included), the way a dock/OSD overlays fullscreen
/// video. Pair with `dismissAfterPrompt` so the bar returns to its prior state.
pub fn presentForPrompt() void {
    const s = gBar.state orelse return;
    if (!s.vis.shown) {
        // The bar is hidden; map it before drawing so the blit lands in a
        // mapped window (a draw queued while unmapped is discarded by the
        // server, leaving a blank bar until the next unrelated redraw) and a
        // compositor never presents an empty frame.
        gBar.prompt_forced_visible = true;
        s.vis.shown = true;
        runVoidHook(.onBarShown);
        _ = xcb.xcb_map_window(s.win.conn, s.win.win_id);
        draw.submitDrawBlockingFull();
    }
    visibility_glue.raiseBar();
    _ = xcb.xcb_flush(s.win.conn);
}

/// Undoes `presentForPrompt` once the prompt exits (entered or cancelled).
///
/// If the bar was shown solely to make the prompt visible, hides it again,
/// but only if it *should still* be hidden. The prompt can outlive the state
/// that justified the override (e.g. the fullscreen window closes on its own),
/// so this recomputes the bar's natural visibility at exit time rather than
/// trusting the decision made at activation.
///
/// If the bar was already visible, this leaves it as-is: the forced
/// top-of-stack position needs no explicit undo, since focusing any other
/// window already raises it above the bar again (see focus.zig).
pub fn dismissAfterPrompt() void {
    const s = gBar.state orelse return;
    if (!gBar.prompt_forced_visible) return;
    gBar.prompt_forced_visible = false;
    const current_ws = tracking.getCurrentWorkspace() orelse 0;
    const should_show = visibility.keepPromptOverride(pipeline.model(), current_ws, s.vis.preferred);
    if (should_show) return; // conditions changed while the prompt was open; stay visible
    s.vis.shown = false;
    _ = xcb.xcb_unmap_window(s.win.conn, s.win.win_id);
    _ = xcb.xcb_flush(s.win.conn);
}

/// Sets the bar's user-level visibility state. Only the user toggle path
/// arrives here (keybind / config action). Fullscreen-driven hide/show is NOT
/// a named call: the bar derives it reactively from the core fullscreen fact
/// revision in `applyFullscreenVisibility`, so no subsystem pokes the bar.
pub fn setBarState(action: types.Action) void {
    const s = gBar.state orelse return;
    if (action == .toggle_bar_visibility) s.vis.preferred = !s.vis.preferred;
    visibility_glue.applyFullscreenVisibility();
}

pub fn updateIfDirty() void {
    const s = gBar.state orelse return;

    // Fullscreen-occupancy reaction runs even when the bar is currently hidden
    // (it may need to become visible again on fullscreen exit). Diff the core
    // fact revision; when changed, we recompute shared-screen visibility. Core
    // owns the fact; we react over a one-way signal rather than being poked.
    const fullscreen_rev = core.fullscreen.rev();
    if (s.facts.fullscreen_rev != fullscreen_rev) {
        s.facts.fullscreen_rev = fullscreen_rev;
        visibility_glue.applyFullscreenVisibility();
    }
    if (!s.vis.shown) return;

    // Diff core's fact revisions against what we last drew. Core owns these
    // facts; we react over a one-way signal (revision counters) rather than
    // being poked by name. Layout changes force a full redraw; window/workspace
    // changes repaint all segments (split-view titles/tile counts); focus
    // changes cheaply mark only the title. Each revision is read once and
    // reused for both the check and the assignment below.
    const focus_rev = core.focus.rev();
    const window_rev = core.window.rev();
    const layout_rev = core.layout.rev();
    if (s.facts.focus_rev != focus_rev) s.markDirtySource(.focus);
    // window_rev previously skipped through blanket `markDirty()` even though
    // title and tags declare they want `.frame` dirtying; using the frame
    // source keeps the non-frame segments (clock, carousel, systatus) from
    // being swept along on every window churn fact bump.
    if (s.facts.window_rev != window_rev) s.markDirtySource(.frame);
    if (s.facts.layout_rev != layout_rev) {
        draw.requestFullRedraw();
    }
    s.facts.focus_rev = focus_rev;
    s.facts.window_rev = window_rev;
    s.facts.layout_rev = layout_rev;

    // Fold any module redraw request into a full dirty (as the poll
    // wakeup path does), then draw. Loop: a module may queue another request
    // while drawing (the variants segment collapses to zero width on a layout
    // switch and must re-lay the row in the SAME batch, before the
    // end-of-batch flush, so the gap closes seamlessly rather than waiting on
    // the next unrelated event). Each iteration clears the request it
    // consumed, so the loop terminates unless a module genuinely re-requests.
    // Cap the iterations so a misbehaving module that re-requests forever
    // can't busy-spin this batch.
    var redraw_iter: u8 = 0;
    while (redraw_iter < max_batched_redraws) : (redraw_iter += 1) {
        _ = draw.foldModuleRedraw(s);
        if (!s.dirty.flag) break;
        draw.performDraw();
    }
    if (redraw_iter == max_batched_redraws)
        log.info("bar: updateIfDirty redraw loop hit its iteration cap, stalling re-request", .{});
}

/// Asks each module whether it queued a redraw request the bar should honour
/// (e.g. the prompt's blink-tick reactivity).
pub fn barModsConsumeRedrawRequest() bool {
    return anyBoolHook(.consumeRedrawRequest, .{});
}

/// Redraws just the clock segment when its on-screen content is stale
/// (second rolled over, the display mode changed, or a config reload changed
/// the format). Cheap to call on every event batch: it no-ops unless staleness
/// is detected.
///
/// A display-mode cycle also changes a self-ticking segment's slot width, and
/// that case reflows the row rather than ticking in place. The check runs
/// BEFORE any paint, off the live width probes, because the region-scoped tick
/// blit can only paint inside the slot the last layout pass reserved: shipping
/// that first would show the new mode's text stranded in the outgoing mode's
/// (wider) slot while its neighbours stayed put.
pub fn updateClock() void {
    const s = gBar.state orelse return;
    if (!s.vis.shown) return;
    if (self_ticking_ids.len == 0) return;
    const fmt = drawing.clockFormat(core.getState().config.bar);
    if (!anyBoolHook(.secondsElapsed, .{fmt})) return;

    if (s.adoptFreshClockWidth()) {
        // Re-lay and repaint the row in this same call, then ship it. updateClock
        // is the last statement of the event loop body, i.e. it runs AFTER the
        // end-of-batch flush and after the batch's own updateIfDirty, so merely
        // flagging the redraw left the reflow to the next loop iteration --
        // up to a whole second on an idle bar, which is exactly the stale-length
        // window this path exists to close. performDraw queues its blit, so the
        // flush is ours to make.
        draw.requestFullRedraw();
        draw.performDraw();
        _ = xcb.xcb_flush(core.getState().conn);
        return;
    }
    s.drawClockOnly();
}

/// Comptime-registered UI-surface hooks for core's event loop (comptime
/// reference point: the one place the loop knows the bar exists). Core calls
/// these through a single `surfaces.Surfaces` alias; when the bar is absent the
/// whole set is `null` and every such call site compiles away. The emitter
/// lives in this module, so detaching the bar detaches its handlers. The hook
/// types themselves live in the core-owned `plugin` interface contract, not
/// here: this module only binds its functions to that contract.
pub const surfaces = @import("contract_x11").Surfaces{
    .init = init,
    .deinit = deinit,
    .handleExpose = input_events.handleExpose,
    .updateIfDirty = updateIfDirty,
    .pollTimeoutMs = pollTimeoutMs,
    .onPollWakeup = onPollWakeup,
    .updateClock = updateClock,
    .onReload = reload,
    .chromeHandleKeypress = chromeHandleKeypress,
    .isBarWindow = isBarWindow,
    .handleButtonPress = input_events.handleButtonPress,
    .handleButtonMotion = input_events.handleButtonMotion,
    .handleButtonRelease = input_events.handleButtonRelease,
    .setBarState = setBarState,
    .hideBarForFullscreen = visibility_glue.hideBarForFullscreen,
    .updateBarVisibilityForWorkspace = visibility_glue.updateBarVisibilityForWorkspace,
    .toggleBarSegmentAnchor = toggleBarSegmentAnchor,
    .barForcedHiddenByFullscreen = visibility.barForcedHiddenByFullscreen,
    .chromeToggleOverlay = chromeToggleOverlay,
};
