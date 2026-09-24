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
const utils = @import("utils");
const screen = @import("screen");
const refresh = @import("refresh");
const scale = @import("scale");
const constants = @import("constants");
const debug = @import("debug");

const types = @import("types");

const tracking = @import("tracking");
const focus = @import("focus");
const pipeline = @import("pipeline");
const actions = @import("actions");
const model = @import("model");
const sync = @import("sync");
const wincache = @import("wincache");

const window = @import("window");

const drawing = @import("drawing");
const metrics = @import("metrics");
const segmod = @import("segment");
const barwin = @import("win");

// Bar visibility subsystem (pure decisions only; bar.zig keeps the wire glue).
const visibility = @import("visibility");

// Window-addon registry (generated): the hidden-set synthesis is routed
// through the collectHiddenSet seam instead of naming the minimize or
// fullscreen module directly.
const window_mods = @import("window_modules").modules;
const contract = @import("contract");

/// The hide-family provider bound to the generated window registry, resolved
/// once at file scope: the hidden-set synthesis and its collect dispatch
/// share one lookup (no module is ever named by the bar).
const collect_hidden_set = window.providerOf(.collectHiddenSet);

// Registry-resolved segment identity (comptime): the bar locates modules by
// name through the generated registry instead of importing them directly.
// Role/named lookups return null on an absent (even empty) registry, so the
// bar still compiles and no-ops when ALL segments are removed.
const bar_mods = @import("bar_modules").modules;

const self_ticking_ids: []const usize = segmod.findAllByCapability(&bar_mods, "self_ticking");
const center_slot_ids: []const usize = segmod.findAllByCapability(&bar_mods, "center_slot");

/// Primary center-slot segment: the FIRST center-slot binder in registry
/// order (config order within a center layout). Title-centric bar behaviors
/// (click-to-focus, chrome-overlay toggle) route through it; with a single
/// binder this is exactly the title, with several it is the leftmost one.
const title_id: ?usize = if (center_slot_ids.len != 0) center_slot_ids[0] else null;

/// Registry index for `name`, or null when absent (also when the registry is
/// empty: `bar_mods` is then a zero-length array and idByName finds nothing).
inline fn segId(name: []const u8) ?usize {
    return segmod.idByName(&bar_mods, name);
}

/// Registry entry at a resolved `id`. Callers reach this only after `segId`
/// (or a registry capability/role lookup) matched a name; a match is
/// impossible when the registry is empty.
inline fn segAt(id: usize) *const contract.Segment {
    if (comptime !hasRegisteredSegments()) unreachable;
    return &bar_mods[id];
}

/// True in builds with at least one registered bar segment, false in
/// segment-less builds.
inline fn hasRegisteredSegments() bool {
    return comptime bar_mods.len != 0;
}

/// Dirty-bit read for a resolved `id` (comptime guarded as segAt).
inline fn segDirty(self: *const State, id: usize) bool {
    if (comptime !hasRegisteredSegments()) unreachable;
    return self.dirty.segments[id];
}

/// Dirty-bit write for a resolved `id` (comptime guarded as segAt).
inline fn setSegDirty(self: *State, id: usize, v: bool) void {
    if (comptime !hasRegisteredSegments()) unreachable;
    self.dirty.segments[id] = v;
}

/// Index of `name` within the registry-id set `comptime ids` (the
/// self-ticking and center-slot capability sets today), or null when it is
/// not a member. Name-free: membership is by declared capability, and the set
/// is resolved from the generated registry.
fn roleIndexOf(name: []const u8, comptime ids: []const usize) ?usize {
    const id = segId(name) orelse return null;
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

/// Even split of `remaining` among `count` center slots, distributed left to
/// right in config order: every slot gets `remaining / count`, and the leading
/// `remaining % count` slots (the leftmost) carry one extra pixel, so the
/// shares sum exactly to `remaining` with no fractional residue.
fn centerShare(remaining: u16, count: u16, idx: u16) u16 {
    const base = @divFloor(remaining, count);
    const extra: u16 = @intCast(@rem(remaining, count));
    return if (idx < extra) base + 1 else base;
}

/// Center-row budget derivation: reserves a center layout's own non-center
/// segments (their widths plus trailing gaps) out of `avail`, returning what
/// remains for the center-slot segments and how many slots share it. For a
/// non-center layout the budget is empty (`.left`/`.right` rows carry no
/// center slots).
fn centerRowBudget(
    self: *State,
    frame: *const segmod.Frame,
    lay: types.BarLayout,
    avail: u16,
    scaled_spacing: u16,
) struct { remaining: u16, center_count: u16 } {
    var remaining: u16 = 0;
    var center_count: u16 = 0;
    if (lay.position != .center) return .{ .remaining = remaining, .center_count = center_count };
    // Reserve the layout's own non-center segments (their widths plus
    // trailing gaps) before the center-slot budget, so a center row that also
    // carries a clock or workspaces slot can't spill into the right cluster.
    const clamped = @min(
        @max(segmod.title_min_width, avail -| scaled_spacing),
        avail,
    );
    var claim: u16 = 0;
    for (lay.segments.items) |s| {
        if (isRole(s, center_slot_ids)) {
            center_count += 1;
            continue;
        }
        claim +|= self.measureSegmentWidth(frame, s);
        claim +|= scaled_spacing;
    }
    remaining = clamped -| claim;
    return .{ .remaining = remaining, .center_count = center_count };
}

fn runVoidHook(comptime hook: std.meta.FieldEnum(contract.Segment)) void {
    contract.callAll(contract.Segment, bar_mods[0..], hook, .{});
}

fn anyBoolHook(comptime hook: std.meta.FieldEnum(contract.Segment), args: anytype) bool {
    return contract.callFirstTrue(contract.Segment, bar_mods[0..], hook, args);
}

// ---------------------------------------------------------------------------
// Bar height / font-size resolution.
//
// Owns everything needed to decide the bar's pixel height and effective font
// size from config + font metrics, including the percentage-font-size probe
// (which measures through drawing.probeFontMetrics' throwaway surface, no
// live DrawContext is touched). The resolved font size is published to the
// bar-owned metrics module (metrics.zig) for drawing to read; no config is
// mutated.

fn probeMetrics(size_override: ?u16) ?drawing.FontMetrics {
    const cs = core.getState();
    const sized = drawing.buildSizedFontList(cs.alloc, size_override) catch return null;
    defer drawing.freeSizedFontList(cs.alloc, sized);
    return drawing.probeFontMetrics(
        cs.alloc,
        core.dpi_info,
        sized,
    );
}

fn resolvePercentageFontSize(bar_height: u16) ?u16 {
    // Probe metrics at a trial point size via the override parameter, so
    // there is no save/mutate/restore round on cs.config. 100 pt is an
    // arbitrary stable probe; only the ascent+descent ratio is used.
    const trial_pt: u16 = 100;
    const cs = core.getState();
    const m = probeMetrics(trial_pt) orelse return null;
    const px_per_pt: f32 = @as(f32, @floatFromInt(@max(1, m.ascent + m.descent))) /
        @as(f32, @floatFromInt(trial_pt));
    const max_size_pt = @as(f32, @floatFromInt(bar_height)) / px_per_pt;
    const cfg_pct = cs.config.bar.font_size.value / 100.0;
    // Clamp before casting, mirroring types.scaleToU16: a large font_size
    // percentage must not wrap the u16 cast into UB in ReleaseFast.
    const clamped = std.math.clamp(
        max_size_pt * cfg_pct,
        1.0,
        @as(f32, std.math.maxInt(u16)),
    );
    return @as(u16, @intFromFloat(@round(clamped)));
}

fn calcBarHeightAndFontSize() u16 {
    const cs = core.getState();
    metrics.recompute();
    if (cs.config.bar.height) |h| {
        const height = scale.scaleBarHeight(h, cs.screen.height_in_pixels);
        if (cs.config.bar.font_size.is_percentage) {
            if (resolvePercentageFontSize(height)) |sz|
                metrics.setScaledFontSize(sz);
        }
        return height;
    }
    const m = probeMetrics(null) orelse return scale.default_bar_height_px;
    return scale.clampBarHeight(@max(1, m.ascent + m.descent));
}

// ---------------------------------------------------------------------------

/// Uniform poll wakeup: runs every module's onPollWakeup hook (prompt caret
/// blink, marquee repaint-marking, ...) then submits a draw. The bar never
/// names a segment.
pub fn onPollWakeup() void {
    runVoidHook(.onPollWakeup);
    // A module's poll hook (e.g. the prompt's caret-blink toggle) must reach
    // the draw's repaint gate: fold any queued module redraw request into the
    // dirty state as a full redraw, exactly as the X-batch update path
    // (updateIfDirty) does, so the animation is visible even when the loop is
    // waking only on the poll timer with no X traffic to trigger that path.
    // performDraw consumes the redraw request itself; no consume here.
    if (gBar.state) |s| {
        _ = foldModuleRedraw(s);
    }
    performDraw();
}

/// Combines every module's poll deadline (clock tick, prompt caret blink,
/// carousel scroll) into the shortest non-negative wait. Negatives mean
/// "no wake needed" and are ignored; when every module returns negative the
/// bar sleeps without polling.
pub fn pollTimeoutMs() i32 {
    // A hidden bar paints nothing, so no per-frame deadline (clock tick,
    // caret blink, carousel scroll) can make progress: the modules would
    // re-arm polling forever without ever being drawn to, spinning the event
    // loop at the frame rate in the background (notably the title carousel,
    // whose offset only advances inside a draw). Suppress all deadlines while
    // hidden; the next visibility transition re-arms them.
    if (gBar.state) |s| {
        if (!s.vis.shown) return -1;
    }
    var timeout: i32 = -1;
    for (bar_mods) |m| {
        if (m.pollTimeoutMs) |h| {
            const t = h();
            if (t >= 0) timeout = if (timeout < 0) t else @min(timeout, t);
        }
    }
    return timeout;
}

/// Routes a keypress through every module that consumes one (the chrome
/// overlay segment).
pub fn chromeHandleKeypress(
    event: *const xcb.xcb_key_press_event_t,
    matched: ?*const types.Action,
) bool {
    return anyBoolHook(.handleKeypress, .{ event, matched });
}

/// Toggles the chrome overlay. Routed through the resolved title module's
/// onClick hook (right-click path): the overlay lives in the title module
/// and the bar must not name it.
pub fn chromeToggleOverlay() void {
    const s = gBar.state orelse return;
    if (titleIdBound(s)) |tb|
        if (segId(tb.name)) |tid| {
            const is_right_click = true;
            dispatchClick(s, tid, 0, false, is_right_click);
        };
}

/// The title segment's recorded on-screen bound, or null when the title
/// addon isn't registered (`title_id`) or the last layout pass never placed
/// it. Shared by the prompt-open click path and chromeToggleOverlay, so the
/// title id/name/bound resolution lives in one place.
fn titleIdBound(s: *State) ?SegBound {
    const center_id = title_id orelse return null;
    return s.recordedBound(segAt(center_id).name);
}

/// Routes one click at `offset` pixels into segment `id` to its onClick hook
/// (not present -> no-op). `is_left`/`is_right` select the click's semantics
/// for the module (e.g. cycle direction for the layout/clock, minimize vs
/// focus for the title). Exported as a `BarHandlers.dispatchClick`-shaped
/// trampoline (see titleClickTrampoline).
fn dispatchClick(s: *State, id: usize, offset: u16, is_left: bool, is_right: bool) void {
    if (segAt(id).onClick) |oc|
        _ = oc(offset, is_left, is_right, s, titleClickTrampoline, redrawInsideGrab);
}

/// Global bar coordination flags. Read and written exclusively on the main
/// thread; no mutex protection required.
const Bar = struct {
    state: ?*State = null,
    /// True when presentForPrompt() had to map an otherwise-hidden bar (e.g.
    /// hidden by a fullscreen window, or by the user toggling it off) purely
    /// so the inline prompt would be visible. dismissAfterPrompt() checks this
    /// to know whether hiding the bar again is part of "returning to normal".
    prompt_forced_visible: bool = false,
};

var gBar: Bar = .{};

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

    fn deinit(self: *WindowCtx) void {
        barwin.freeColormap(self.conn, self.colormap);
    }
};

const RenderCtx = struct {
    dc: *drawing.DrawContext,
    config: types.BarConfig,
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
    /// Reserved width the right cluster occupies: segment widths plus the
    /// inter-segment spacing, minus the trailing gap of each right layout.
    total: u16 = 0,
    /// Running draw index, advanced by `take` per right layout.
    ridx: usize = 0,
};

/// On-screen hit-test bound of one segment, recorded by recordClickBound
/// during the layout pass. THE click-bound storage: hit-testing iterates
/// these in recorded order (first match wins). The name is borrowed from the
/// config's layout list (stable for the bar's lifetime).
const SegBound = struct {
    name: []const u8,
    x: u16,
    w: u16,

    inline fn contains(self: SegBound, px: u16) bool {
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
    /// Reserved width from the same pass (its natural width at that frame's
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
    geoms_buf: [max_frame_windows]?utils.Rect = undefined,
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
const State = struct {
    win: WindowCtx,
    render: RenderCtx,

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
        var clock_width: u16 = 0;
        for (self_ticking_ids) |cid| {
            if (segAt(cid).measureString) |ms|
                clock_width = @max(clock_width, dc.measureTextWidth(ms()) + 2 * config.scaledSegmentPadding(height));
        }
        s.* = .{
            .win = .{
                .conn = conn,
                .win_id = win_id,
                .colormap = colormap,
            },
            .render = .{
                .dc = dc,
                .config = config,
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
    fn markDirty(self: *State) void {
        self.dirty.flag = true;
        @memset(&self.dirty.segments, true);
    }

    fn clearSegmentDirty(self: *State, name: []const u8) void {
        if (segId(name)) |id| setSegDirty(self, id, false);
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
    fn clearRegion(self: *State, x: u16, w: u16) void {
        self.render.dc.fillRect(x, 0, w, self.render.height, self.render.config.bg);
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
        const id = segId(name) orelse return false;
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
    fn pendingFullRedraw(self: *const State) bool {
        return self.dirty.flag and self.isFullDirty();
    }

    /// Scans the configured layout tree, returning true as soon as a segment
    /// matches `pred`. Layout-rendered segments only: the overlay-only prompt
    /// slot is excluded (its dirty flag is never cleared, so a registry-wide
    /// scan would always match and defeat the fast-path early-exit).
    inline fn anyLayoutSegment(self: *const State, comptime pred: anytype) bool {
        for (self.render.config.layout.items) |lay| {
            for (lay.segments.items) |seg| {
                if (pred(self, seg)) return true;
            }
        }
        return false;
    }

    /// True when the next draw would repaint at least one layout-rendered
    /// segment: a dirty flag or a live needsRepaint hook (the title marquee).
    fn hasPendingRepaintWork(self: *const State) bool {
        return self.anyLayoutSegment(State.isSegmentRepaintable);
    }

    /// True when any layout-rendered segment carries a set dirty bit (as
    /// opposed to only a self-animated needsRepaint hook). A dirty bit means
    /// the facts backing the drawn content changed, so the frame must be
    /// rescanned and the DrawCtx refilled before drawing; when no dirty bit is
    /// set and !dirty.flag, the only pending work is a marquee/overlay
    /// needsRepaint hook and the cached last_ctx snapshot is still accurate.
    fn hasLayoutSegmentDirty(self: *const State) bool {
        for (self.render.config.layout.items) |lay| {
            for (lay.segments.items) |name| {
                const id = segId(name) orelse continue;
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
        const id = segId(name) orelse return;
        if (!segAt(id).clickable) return;
        if (self.clicks.len >= max_click_bounds) return;
        self.clicks.bounds[self.clicks.len] = .{ .name = name, .x = x, .w = w };
        self.clicks.len += 1;
    }

    fn recordedBound(self: *const State, name: []const u8) ?SegBound {
        for (self.clicks.bounds[0..self.clicks.len]) |b| {
            if (std.mem.eql(u8, b.name, name)) return b;
        }
        return null;
    }

    /// Measures a segment's natural (reserved) width via its uniform
    /// naturalWidth hook, or 0 for an unknown/removed segment name.
    fn measureSegmentWidth(self: *State, frame: *const segmod.Frame, name: []const u8) u16 {
        const id = segId(name) orelse return 0;
        if (segAt(id).naturalWidth) |nw| return nw(frame, self.clock.width);
        return 0;
    }

    /// Records the last layout-pass bound of a self-ticking segment so its
    /// end-of-batch tick can region-scope a repaint (drawClockOnly). Written
    /// for every configured self-ticker in ANY cluster (left/center/right);
    /// unconfigured self-tickers stay invalid and are never repainted.
    fn recordSelfTickerScope(self: *State, frame: *const segmod.Frame, name: []const u8, x: u16) void {
        if (selfTickerIndex(name)) |i| {
            self.clock.segs[i] = .{
                .x = x,
                .width = self.measureSegmentWidth(frame, name),
                .valid = true,
            };
        }
    }

    /// Fills the shared per-frame DrawCtx the bar hands to every segment's
    /// draw hook, including the title snapshot slots.
    fn fillDrawCtx(self: *State, ctx: *segmod.DrawCtx) void {
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
        ctx.focused_title = if (ctx.focused_window) |fw| wincache.peekTitle(fw) else "";
        ctx.minimized_title = minimized_title;
        ctx.current_ws_wins = wins_slice;
        ctx.minimized_set = &self.title_data.minimized;
        ctx.titles = self.title_data.titles_buf[0..self.frame.wins_len];
        ctx.geoms = self.title_data.geoms_buf[0..self.frame.wins_len];
    }

    // -- Live-state collection ------------------------------------------------

    /// Reads workspace/window state into the frame fields. Pure model reads:
    /// no X11. The per-window titles/geoms are filled later (fillDrawCtx)
    /// straight from the WM-owned title cache and the sync truth-rect, so
    /// there is no fetch key to diff and nothing to prefetch.
    fn scanLiveFrame(self: *State) void {
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
            for (tracking.allWindows()) |entry| {
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
    fn titleGeom(win: u32, minimized: bool) ?utils.Rect {
        if (minimized) return segmod.offscreen_rect;
        return sync.truthRect(pipeline.model(), win) orelse segmod.offscreen_rect;
    }

    // -- Drawing ---------------------------------------------------------------

    /// Warns on a draw failure and reports the position unchanged, so a broken
    /// segment can't corrupt the layout.
    inline fn reportDrewNothing(x: u16) u16 {
        debug.warnOnErr(error.DrewInvalidSegment, "bar drawSegment");
        return x;
    }

    /// Draws a segment by registry dispatch, catching and logging errors
    /// instead of propagating them. On failure returns `x` unchanged (the
    /// "drew nothing" signal) so a broken segment can't corrupt the layout.
    fn drawSegment(self: *State, ctx: *segmod.DrawCtx, name: []const u8, x: u16, width: ?u16) u16 {
        const id = segId(name) orelse return reportDrewNothing(x);
        if (segAt(id).draw == null) return reportDrewNothing(x);
        // The DrawCtx is shared mutable scratch: pin the reserved width into it
        // immediately before the draw so width-reading renderers (the title)
        // advance correctly.
        ctx.width = width orelse self.measureSegmentWidth(&ctx.frame, name);
        return segAt(id).draw.?(ctx, x) catch |e| {
            debug.warnOnErr(e, "bar drawSegment");
            return x;
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
        const drew_x = self.drawSegment(ctx, name, x, w);
        const drew = drew_x != x_before;
        // A successful draw paints its trailing gap (omitted after the title so
        // the next center segment sits flush). On failure drawSegment returned
        // x unchanged, but the full reserved `w` (+ gap unless omitted) is
        // still consumed so the next segment leftward starts where the layout
        // pass expects -- leaving x unchanged would let it paint over this
        // failed slot and desync the cluster.
        if (drew and !omit_gap) self.paintGap(drew_x, scaled_spacing);
        return if (drew)
            drew_x + (if (omit_gap) 0 else scaled_spacing)
        else
            x_before + w;
    }

    fn paintGap(self: *State, gap_x: u16, scaled_spacing: u16) void {
        self.clearRegion(gap_x, scaled_spacing);
    }

    fn drawRightSegments(
        self: *State,
        ctx: *segmod.DrawCtx,
        names: []const []const u8,
        widths: ?[]const u16,
        is_full_redraw: bool,
        right_x: *u16,
    ) void {
        const frame = &ctx.frame;
        const scaled_spacing = self.render.config.scaledSpacing(self.render.height);
        // Runs across the whole right cluster, NOT per layout: multiple right
        // layouts butt against each other (no inter-layout spacing, matching
        // the reservation computed up front in drawAllInner) instead of each
        // restarting from the bar's right edge and overlapping the previous
        // layout's pixels.
        var cur_x = right_x.*;
        var pending_gap = false;
        var i = names.len;
        while (i > 0) {
            i -= 1;
            // Widths measured once up front in drawAllInner (null only when the
            // right cluster exceeds the scratch buffer, which falls back to the
            // original measure-at-draw re-measurement below).
            const seg_w = if (widths) |ws| ws[i] else self.measureSegmentWidth(frame, names[i]);
            // Saturating subtraction: a pathological width sum must clamp at 0,
            // not underflow into a wrap-around rightward paint.
            cur_x = cur_x -| seg_w;
            if (pending_gap) cur_x = cur_x -| scaled_spacing;

            if (isRole(names[i], self_ticking_ids)) self.recordSelfTickerScope(frame, names[i], cur_x);
            self.recordClickBound(names[i], cur_x, seg_w);

            if (self.isSegmentRepaintable(names[i])) {
                if (!is_full_redraw) {
                    self.clearRegion(cur_x, seg_w);
                }
                const drew = self.drawSegment(ctx, names[i], cur_x, null) != cur_x;
                if (drew) {
                    if (pending_gap) {
                        self.paintGap(cur_x + seg_w, scaled_spacing);
                    }
                }
                // A failed draw still occupies its reserved slot as empty
                // (background) space, so the next segment leftward gets the
                // same inter-segment gap the layout pass computed. Keeping the
                // bookkeeping uniform here prevents desyncing downstream
                // placement on the next frame.
                pending_gap = true;
                self.clearSegmentDirty(names[i]);
            } else {
                pending_gap = true;
            }
        }
        right_x.* = cur_x;
    }

    /// Repaints the bar into the off-screen pixmap. When every segment is
    /// dirty (full redraw) the whole background is cleared once;
    /// otherwise only the dirty segments' regions are repainted, leaving
    /// unchanged pixels from the previous frame untouched.
    fn drawAllInner(self: *State, ctx: *segmod.DrawCtx) void {
        const r = &self.render;
        const frame = &ctx.frame;
        const scaled_spacing = r.config.scaledSpacing(r.height);
        const is_full_redraw = self.isFullDirty();
        self.dirty.span_x = 0;
        self.dirty.span_w = 0;

        if (is_full_redraw) {
            self.clearRegion(0, r.width);
        }

        var right_widths: [max_right_segments]u16 = undefined;
        var right_count: usize = 0;
        var right_ridx: usize = 0;
        var right_total_raw: u32 = 0;
        // Measure every right-position segment once up front: reserved width
        // for left/center placement plus the per-segment widths the draw uses.
        // Accumulate the reservation in u32 (segment widths + gaps could push
        // past u16 on a very wide desktop) and clamp into the u16 handled below.
        for (r.config.layout.items) |lay| {
            if (lay.position != .right) continue;
            for (lay.segments.items) |seg| {
                const w = self.measureSegmentWidth(frame, seg);
                if (right_count < max_right_segments) right_widths[right_count] = w;
                right_count += 1;
                right_total_raw += @as(u32, w) + scaled_spacing;
            }
            if (lay.segments.items.len > 0) right_total_raw -= scaled_spacing;
        }
        const right_total: u16 = @intCast(@min(right_total_raw, std.math.maxInt(u16)));

        self.clicks.len = 0;
        var x: u16 = 0;
        // Continuation cursor for the right cluster. Shared across ALL right
        // layouts so they lay out back-to-back (measure reserves one span for
        // the whole cluster); see drawRightSegments.
        var right_x = r.width;
        for (r.config.layout.items) |lay| {
            switch (lay.position) {
                .left, .center => {
                    // Available horizontal space before the right cluster.
                    const avail = r.width -| x -| right_total;
                    const budget = centerRowBudget(self, frame, lay, avail, scaled_spacing);
                    const remaining = budget.remaining;
                    const center_count = budget.center_count;
                    var center_idx: u16 = 0;
                    for (lay.segments.items) |seg| {
                        const is_center = (lay.position == .center) and isRole(seg, center_slot_ids);
                        const omit_gap = is_center;
                        // Center-slot segments in a center row split the whole
                        // remaining budget evenly, left-to-right in config
                        // order (centerShare); widths stay contiguous (no gap),
                        // so duplicates can't overlap the right cluster.
                        const w: u16 = if (is_center)
                            centerShare(remaining, center_count, center_idx)
                        else
                            self.measureSegmentWidth(frame, seg);
                        self.recordClickBound(seg, x, w);
                        // The self-ticker bound must be recorded in ANY
                        // cluster (not just right): drawClockOnly relies on it
                        // regardless of where the clock is laid out.
                        if (isRole(seg, self_ticking_ids)) self.recordSelfTickerScope(frame, seg, x);
                        if (self.isSegmentRepaintable(seg)) {
                            if (!is_full_redraw) {
                                const clear_w = if (omit_gap) w else w + scaled_spacing;
                                self.clearRegion(x, clear_w);
                            }
                            const x_before = x;
                            x = self.drawRowSegment(
                                ctx,
                                seg,
                                x,
                                w,
                                omit_gap,
                                scaled_spacing,
                            );
                            if (x != x_before) self.extendDirtySpan(x_before, x - x_before);
                            self.clearSegmentDirty(seg);
                        } else {
                            x += w;
                            if (!omit_gap) x += scaled_spacing;
                        }
                        if (is_center) center_idx += 1;
                    }
                },
                .right => {
                    const start = right_ridx;
                    right_ridx += lay.segments.items.len;
                    // Null when the measurement buffer overflowed: the draw
                    // falls back to measure-at-draw per segment.
                    const widths: ?[]const u16 = if (right_count > max_right_segments)
                        null
                    else
                        right_widths[start..][0..lay.segments.items.len];
                    self.drawRightSegments(ctx, lay.segments.items, widths, is_full_redraw, &right_x);
                },
            }
        }
    }

    /// Repaints every self-ticking segment whose on-screen content is stale
    /// (second rolled over). Cheap region-scoped blits, one per ticker.
    fn drawClockOnly(self: *State) void {
        for (self_ticking_ids, 0..) |cid, i| {
            const sc = self.clock.segs[i];
            if (!sc.valid) continue;
            redrawSlotScoped(self, cid, sc.x, sc.width, null, true);
        }
    }
};

// Draw submission

/// Shared per-frame DrawCtx skeleton: dc/config/height/conn/allocator from the
/// live render context plus a defaulted frame. Callers fill the title-snapshot
/// slots afterward via `fillDrawCtx` (the clock-only path leaves them empty).
fn frameCtx(s: *State) segmod.DrawCtx {
    return .{
        .dc = s.render.dc,
        .config = s.render.config,
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
fn performDraw() void {
    const s = gBar.state orelse return;
    if (!s.vis.shown) return;
    // Fold any queued module redraw request into a full dirty (flag +
    // every-slot) -- the same gate the poll-wakeup and X-batch paths use -- so
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
    // re-walk tracking.allWindows() and rebuild the title/minute snapshot on
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

fn submitDrawBlockingFull() void {
    const s = gBar.state orelse return;
    s.markDirty();
    performDraw();
}

inline fn ungrabAndFlush() void {
    utils.ungrabAndFlush(core.getState().conn);
}

/// Requests the next draw to repaint every segment and mark the whole bar
/// dirty. Used by paths that need a full background-clear repaint (layout
/// facts, module redraw requests, bar re-anchoring).
fn requestFullRedraw() void {
    if (gBar.state) |s| s.markDirty();
}

/// Everything a fully-initialised bar owns; returned by createBar.
const BarSetup = struct {
    setup: barwin.BarWindowSetup,
    state: *State,
};

/// Creates the bar window, off-screen draw context, and live State.
/// On any failure, everything already created is freed before returning.
fn createBar(height: u16, y_pos: i16) !BarSetup {
    const cs = core.getState();
    const setup = barwin.createBarWindow(height, y_pos);
    errdefer barwin.destroyBarWindow(cs.conn, setup.win_id, setup.colormap);
    barwin.setWindowProperties(setup.win_id, height);
    const dc = try barwin.createDrawContext(setup, height);
    errdefer dc.deinit();
    debug.info(
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
    barwin.initAtoms();
    refresh.ensureRefreshRateDetected(cs.conn);
    const height = calcBarHeightAndFontSize();
    const bar = try createBar(height, barwin.calcBarYPos(height));
    gBar.state = bar.state;
    screen.setSurfaceWindow(bar.setup.win_id);
    // Map before the first draw (same rationale as applyVisibility: a blit to
    // an unmapped window is discarded, and compositors start remapped windows
    // blank until first damage).
    _ = xcb.xcb_map_window(cs.conn, bar.setup.win_id);
    performDraw();
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
    for (bar_mods) |m| {
        if (m.init) |h| try h(cs.alloc, cs.conn, &g_bar_handlers);
    }
    syncScreenClaim();
}

pub fn deinit() void {
    const alloc = core.getState().alloc;
    for (bar_mods) |m| {
        if (m.deinit) |h| h(alloc);
    }
    if (gBar.state) |s| {
        _ = xcb.xcb_destroy_window(s.win.conn, s.win.win_id);
        s.render.dc.deinit();
        s.deinit();
        gBar.state = null;
    }
    screen.releaseClaim(screen.bar_id);
    screen.clearSurfaceWindow();
}

pub fn reload() void {
    const old = gBar.state orelse {
        if (core.getState().config.bar.enabled) {
            init() catch |err| debug.err("Bar init failed: {}", .{err});
        }
        return;
    };
    if (!core.getState().config.bar.enabled) {
        deinit();
        return;
    }
    const height = calcBarHeightAndFontSize();
    applyReload(old, height) catch |err| {
        debug.err("Bar reload failed ({s}), keeping old bar", .{@errorName(err)});
    };
}

/// Re-points the bar's config copy at the LIVE config's bar section.
/// handleConfigReload only rebuilds the bar when changes.bar is set; a reload
/// that lands elsewhere in the config leaves render.config borrowing slices of
/// the OLD config, which the caller frees right after these hooks return -- the
/// next draw would read freed memory. Same re-point as the applyReload failure
/// path, just for the no-rebuild path.
pub fn refreshConfig() void {
    const s = gBar.state orelse return;
    s.render.config = core.getState().config.bar;
    requestFullRedraw();
}

fn applyReload(old: *State, height: u16) !void {
    const cs = core.getState();
    // Module caches (font widths, caret geometry) are built against the old
    // config; the new one is live from here on either way, so drop them up
    // front, including on the failure path below, where the surviving bar
    // re-points at the NEW live config too.
    runVoidHook(.invalidateReloadCaches);
    // calcBarHeightAndFontSize already re-derived the scaled font size from
    // the NEW config (percentage sizes refine against the new height); if the
    // new bar fails to materialize, the surviving bar must keep whatever font
    // size actually matches its own height.
    const old_scaled_font_size = metrics.getScaledFontSize();
    const new_bar = createBar(height, barwin.calcBarYPos(height)) catch |err| {
        // The caller has already swapped cs.config to the new config and frees
        // the OLD config when this returns. The old bar survives this failed
        // reload, but its render.config borrows slices from that config; so
        // re-point it at the live new config before old_config.deinit() runs,
        // or the next draw reads freed memory.
        old.render.config = cs.config.bar;
        metrics.setScaledFontSize(old_scaled_font_size);
        return err;
    };
    const new_state = new_bar.state;
    new_state.vis.shown = old.vis.shown;
    new_state.vis.preferred = old.vis.preferred;
    gBar.state = new_state;
    screen.setSurfaceWindow(new_bar.setup.win_id);
    syncScreenClaim();
    submitDrawBlockingFull();
    if (new_state.vis.shown) _ = xcb.xcb_map_window(cs.conn, new_bar.setup.win_id);
    _ = xcb.xcb_destroy_window(cs.conn, old.win.win_id);
    ungrabAndFlush();
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

pub fn toggleBarSegmentAnchor() void {
    const s = gBar.state orelse return;
    const cs = core.getState();
    cs.config.bar.bar_position = switch (cs.config.bar.bar_position) {
        .top => .bottom,
        .bottom => .top,
    };
    const new_y = barwin.calcBarYPos(s.render.height);
    barwin.setWindowProperties(s.win.win_id, s.render.height);
    requestFullRedraw();
    // The shared bar window is being re-anchored; drop every recorded
    // self-ticker bound so a stale tick cannot region-scope a repaint before
    // the layout pass re-records them.
    for (&s.clock.segs) |*sc| sc.valid = false;
    utils.grabServer(cs.conn);
    _ = xcb.xcb_configure_window(
        cs.conn,
        s.win.win_id,
        xcb.XCB_CONFIG_WINDOW_Y,
        &[_]u32{utils.toXcbCoord(new_y)},
    );
    // Publish the new edge BEFORE any early return. The bar window has
    // already moved and bar_position changed, so bailing out below without
    // syncing would leave core.screen claiming the old edge.
    syncScreenClaim();
    const current_ws = tracking.getCurrentWorkspace() orelse {
        window.updateWorkspaceBorders();
        window.markBordersFlushed();
        ungrabAndFlush();
        return;
    };
    const no_fullscreen = !visibility.barForcedHiddenByFullscreen(current_ws);
    // The bar's edge changed (claim synced above); the reconcile below
    // re-derives every placement from the new usable area.
    // LAYERING NOTE: The bar triggers reconciliation after visibility/position
    // changes because the work area geometry changed, affecting all window
    // placements. This is a write-path side effect from a rendering module,
    // documented in the check-layers.sh allowlist.
    if (no_fullscreen) pipeline.reconcileNow();
    window.updateFloatingWindowBorders();
    window.markBordersFlushed();
    ungrabAndFlush();
    debug.info("Bar position toggled to: {s}", .{@tagName(cs.config.bar.bar_position)});
}

pub fn isBarWindow(win: u32) bool {
    return if (gBar.state) |s| s.win.win_id == win else false;
}

/// Pushes the bar's current screen-space claim to core.screen. Called at each
/// point where the bar's occupancy of the screen changes (visibility toggle,
/// edge/position change) immediately before the reconcile that re-derives
/// window placement from the new usable area. Core owns the area math; the
/// bar only contributes "I take this many pixels from this edge."
fn syncScreenClaim() void {
    const s = gBar.state orelse return;
    const cs = core.getState();
    const edge: screen.Edge = if (cs.config.bar.bar_position == .bottom) .bottom else .top;
    const px: u16 = if (s.vis.shown) s.render.height else 0;
    screen.setClaim(screen.bar_id, edge, px);
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
fn redrawInsideGrab() void {
    const s = gBar.state orelse return;
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
    const tb = s.recordedBound(segAt(id).name) orelse return;
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
fn redrawSlotScoped(s: *State, id: usize, x: u16, bound_w: u16, pinned_w: ?u16, flush_blit: bool) void {
    if (segAt(id).draw == null) return;
    // Clear the whole reserved slot first: a display-mode shrink paints less
    // than the reservation, and the leftover region must show clean
    // background (not the previous wider frame's content) for the blit.
    s.clearRegion(x, bound_w);
    var ctx = frameCtx(s);
    // Shared harness: catches/logs draw errors; returns x unchanged
    // ("drew nothing") on failure, which must skip the blit below.
    const drawn_end = s.drawSegment(&ctx, segAt(id).name, x, pinned_w);
    if (drawn_end == x) return;
    const drawn_w: u16 = drawn_end -| x;
    if (flush_blit) {
        s.render.dc.blitRegion(x, @max(bound_w, drawn_w));
    } else {
        s.render.dc.queueBlit(x, @max(bound_w, drawn_w));
    }
    s.clearSegmentDirty(segAt(id).name);
}

/// Scoped repaint of the in-flight scrub/scroll target segment (`drag_segment`
/// for a button-1 drag motion, `scroll_segment` for an onScroll dispatch), so a
/// drag or fast wheel sweep never forces full-bar redraws. Used as the drag
/// motion `redraw` callback and the onScroll `redraw` callback.
fn redrawScopedSegment() void {
    const s = gBar.state orelse return;
    const id = s.drag_segment orelse s.scroll_segment orelse return;
    redrawSegmentScoped(s, id);
}

fn raiseBar() void {
    if (gBar.state) |s|
        _ = xcb.xcb_configure_window(
            s.win.conn,
            s.win.win_id,
            xcb.XCB_CONFIG_WINDOW_STACK_MODE,
            &[_]u32{xcb.XCB_STACK_MODE_ABOVE},
        );
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
        submitDrawBlockingFull();
    }
    raiseBar();
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
    const should_show = visibility.keepPromptOverride(current_ws, s.vis.preferred);
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
    applyFullscreenVisibility();
}

/// Applies a decided visibility change: updates `vis.shown`, draws when
/// shown, maps/unmaps, and re-derives the screen claim. `do_reconcile`
/// additionally grabs the server, reconciles (the usable area changed with
/// the claim) and flushes -- used by the fullscreen-fact reaction path, not
/// by the workspace-switch path whose caller runs its own reconcile. The
/// reconcile-show path also re-raises the bar LAST (inside the same flush,
/// after the reconcile's geometry sends), so a moved winner that got raised
/// above it (sync raises a placing winner on motion even without
/// force_restack) cannot leave a freshly shown bar buried under the window
/// it just stopped covering.
fn applyVisibility(s: *State, should_be_visible: bool, do_reconcile: bool) void {
    s.vis.shown = should_be_visible;
    const conn = core.getState().conn;
    if (do_reconcile) utils.grabServer(conn);
    _ = if (should_be_visible) xcb.xcb_map_window(conn, s.win.win_id) else xcb.xcb_unmap_window(conn, s.win.win_id);
    // Draw AFTER the map request so the blit lands in an already-mapped
    // window. A copy queued to an unmapped window is discarded by the server
    // (and, under a compositor, the view of a freshly remapped window starts
    // blank until the first damage), which is what left the bar invisible --
    // a bare gap in the shelf -- until an unrelated later redraw happened to
    // repaint it. Ordering the map before the draw in this same flush closes
    // that gap on every show (boot, workspace switch, fullscreen exit, Mod+B).
    if (should_be_visible) {
        // Tell continuous-motion segments the bar is (re)appearing, so the
        // title marquee resumes from its last shown offset instead of
        // teleporting across the whole hidden gap on this first frame.
        runVoidHook(.onBarShown);
        if (do_reconcile) {
            // Fullscreen toggle path: render to the off-screen pixmap inside
            // the grab so the caller's single ungrabAndFlush ships geometry +
            // blit as exactly one compositor frame.
            submitDrawBlockingFull();
        } else {
            // Workspace-switch path: skip the redundant inline render. The
            // switch already bumped the window fact, so updateIfDirty repaints
            // this bar once at end-of-batch (within the same batch as the
            // switch); an inline draw here would be a full duplicate render AND
            // would paint the stale pre-switch focused-title (model.focused has
            // not landed on the new workspace yet).
            requestFullRedraw();
        }
    }
    syncScreenClaim();
    if (do_reconcile) {
        pipeline.reconcileNow();
        if (should_be_visible) raiseBar();
        ungrabAndFlush();
    }
}

/// Pre-computes and applies the bar's visibility state for `ws` (X11
/// map/unmap + screen claim) WITHOUT triggering a reconcile. Used by the
/// workspace-switch path so the bar's screen claim (and thus the workarea
/// used by the FIRST reconcile on the new workspace) is correct from the
/// start, preventing the two-reconcile flicker caused by a deferred
/// visibility update. The reconcile comes from the caller's own switch
/// reconcile; the bar merely updates its occupancy state here.
pub fn updateBarVisibilityForWorkspace(ws: u8) void {
    applyVisibilityDecision(ws, false);
}

/// Immediately unmaps the bar and updates the screen claim, without a
/// separate reconcile. Called from the fullscreen-enter grab so the bar
/// disappears atomically with the fullscreen geometry. No-ops when the bar
/// is already hidden or not initialised.
pub fn hideBarForFullscreen() void {
    const s = gBar.state orelse return;
    if (!s.vis.shown) return;
    applyVisibility(s, false, false);
}

/// Reacts to a change in core's fullscreen-occupancy fact: recomputes whether
/// the bar must be hidden to share the screen with a fullscreen window on the
/// current workspace, then maps/unmaps and updates the screen claim. Core owns
/// the fact revision; the bar merely reads the model & screen facts it already
/// consumes. Calls `reconcileNow` after a visibility claim change because the
/// usable area geometry changed (a write-path side effect from a rendering
/// module: documented in the check-layers.sh allowlist).
pub fn applyFullscreenVisibility() void {
    applyVisibilityDecision(tracking.getCurrentWorkspace() orelse 0, true);
}

/// Computes the desired visibility for `ws` via the shared visibility policy
/// and, when it differs from current state, applies the change. `do_reconcile`
/// selects the workspace-switch flavor (no reconcile; the caller reconciles)
/// vs the fullscreen-fact reaction (reconciles inside the claim).
fn applyVisibilityDecision(ws: u8, do_reconcile: bool) void {
    const s = gBar.state orelse return;
    const decision = visibility.desiredVisibility(ws, s.vis.shown, s.vis.preferred);
    if (!decision.needs_change) return;
    applyVisibility(s, decision.should_be_visible, do_reconcile);
    debug.info(
        "Bar {s} for workspace {d}",
        .{ if (decision.should_be_visible) "shown" else "hidden", ws },
    );
}

pub fn updateIfDirty() !void {
    const s = gBar.state orelse return;

    // Fullscreen-occupancy reaction runs even when the bar is currently hidden
    // (it may need to become visible again on fullscreen exit). Diff the core
    // fact revision; when changed, we recompute shared-screen visibility. Core
    // owns the fact; we react over a one-way signal rather than being poked.
    const fullscreen_rev = core.fullscreen.rev();
    if (s.facts.fullscreen_rev != fullscreen_rev) {
        s.facts.fullscreen_rev = fullscreen_rev;
        applyFullscreenVisibility();
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
    if (s.facts.window_rev != window_rev) s.markDirty();
    if (s.facts.layout_rev != layout_rev) {
        requestFullRedraw();
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
        _ = foldModuleRedraw(s);
        if (!s.dirty.flag) break;
        performDraw();
    }
    if (redraw_iter == max_batched_redraws)
        debug.info("bar: updateIfDirty redraw loop hit its iteration cap, stalling re-request", .{});
}

/// Asks each module whether it queued a redraw request the bar should honour
/// (e.g. the prompt's blink-tick reactivity).
fn barModsConsumeRedrawRequest() bool {
    return anyBoolHook(.consumeRedrawRequest, .{});
}

/// Folds a queued module redraw request into the dirty state as a full
/// redraw (flag + every slot). Returns true when it consumed one. Single
/// shared fold for the poll wakeup, direct-submit, and X-batch paths so no
/// path can drop a request.
fn foldModuleRedraw(s: *State) bool {
    if (!barModsConsumeRedrawRequest()) return false;
    s.markDirty();
    return true;
}

/// Redraws just the clock segment when its on-screen content is stale
/// (second rolled over, or config reload changed the format). Cheap to call
/// on every event batch: it no-ops unless staleness is detected.
pub fn updateClock() void {
    const s = gBar.state orelse return;
    if (!s.vis.shown) return;
    if (self_ticking_ids.len == 0) return;
    const fmt = drawing.clockFormat(core.getState().config.bar);
    if (!anyBoolHook(.secondsElapsed, .{fmt})) return;
    s.drawClockOnly();
    // A display-mode cycle also changes a self-ticking segment's slot width:
    // re-derive the merged clock display width (max across the tickers'
    // natural widths) and re-lay the row so neighboring segments shift to the
    // narrowed/widened slot. Within a mode the reported width is stable (the
    // mode's probe), so the normal once-per-second clock repaint never trips
    // this re-layout.
    var merged = s.clock.width;
    for (self_ticking_ids, 0..) |cid, i| {
        const sc = &s.clock.segs[i];
        if (!sc.valid) continue;
        if (segAt(cid).naturalWidth) |nw| {
            const fresh = nw(&s.frame, s.clock.width);
            sc.width = fresh;
            merged = @max(merged, fresh);
        }
    }
    if (merged != s.clock.width) {
        s.clock.width = merged;
        requestFullRedraw();
    }
}

pub fn handleExpose(event: *const xcb.xcb_expose_event_t) void {
    if (gBar.state) |s| if (event.window == s.win.win_id and event.count == 0) {
        if (build_options.has_floating and actions.isDragging()) s.dirty.flag = true else performDraw();
    };
}

// Mouse click handling

/// Routes a ButtonPress on the bar window to whichever segment was clicked.
/// Called from input.zig before its managed-window click path: the bar is
/// never a managed window, so that path would just replay and swallow it.
///
/// Hit-testing walks the bounds RECORDED DURING THE LAST LAYOUT PASS in
/// record order (first containing bound wins), then delegates behavior to
/// the resolved module's single onClick hook (uniform registry dispatch).
///
/// Left-clicking a workspace icon switches to it; right-clicking one sends
/// the currently focused window to it. Right-clicking anywhere in the title
/// segment (empty or over any window's title, regardless of that window's
/// state) opens the prompt; left-clicking the title otherwise
/// focuses/minimizes/unminimizes the window shown there.
/// Left/right-clicking the layout indicator cycles the tiling layout
/// forward/backward; left/right-clicking the layout variants indicator
/// cycles the current layout's variant forward/backward the same way.
/// Left/right-clicking the clock cycles its display mode (date-time by
/// default, then time or date).
/// Scroll-wheel over a segment (buttons 4/5) routes to its `onScroll` hook
/// (the slider sub's clamp-step); a left press on a clickable segment arms
/// its `onDragMotion` hook for the duration of the press-hold.
pub fn handleButtonPress(event: *const xcb.xcb_button_press_event_t) void {
    const s = gBar.state orelse return;
    if (!s.vis.shown) return;
    if (event.event_x < 0) return;
    const x: u16 = @intCast(event.event_x);

    const h = for (s.clicks.bounds[0..s.clicks.len]) |b| {
        if (b.contains(x)) break b;
    } else return;
    const id = segId(h.name) orelse return;

    const detail = event.detail;
    if (detail == constants.mouse_button_left) {
        s.drag_segment = id;
        dispatchClick(s, id, x - h.x, true, false);
        return;
    }
    if (detail == constants.mouse_button_right) {
        dispatchClick(s, id, x - h.x, false, true);
        return;
    }
    // Scroll buttons 4/5: no click semantics, no drag anchor. The repaint is
    // segment-scoped (see redrawScrolledSegment) so a fast wheel sweep never
    // forces full-bar redraws.
    s.drag_segment = null;
    if (detail == constants.mouse_button_scroll_up or
        detail == constants.mouse_button_scroll_down)
    {
        if (segAt(id).onScroll) |scroll| {
            const dir: i8 = if (detail == constants.mouse_button_scroll_up) 1 else -1;
            s.scroll_segment = id;
            _ = scroll(dir, redrawScopedSegment);
            s.scroll_segment = null;
            return;
        }
    }
}

/// Routes press-hold motion over the bar to the segment that owns the
/// in-flight button-1 scrub (`drag_segment`), if it declares `onDragMotion`.
/// X's implicit grab delivers motion to the grabbing (bar) window even when
/// the pointer leaves the bar, so the offset can span outside the segment;
/// segments clamp their own state. No drag owner -> no-op.
pub fn handleButtonMotion(event: *const xcb.xcb_motion_notify_event_t) void {
    const s = gBar.state orelse return;
    const id = s.drag_segment orelse return;
    if (!s.vis.shown) return;
    if (segAt(id).onDragMotion) |drag| {
        const tb = s.recordedBound(segAt(id).name) orelse return;
        const off_i = @as(i32, event.event_x) - @as(i32, tb.x);
        const offset: u16 = @intCast(std.math.clamp(off_i, 0, std.math.maxInt(u16)));
        // Scoped repaint, not redrawInsideGrab: a scrub only mutates the
        // dragged segment's slot, and a full-bar redraw per motion is the
        // frame-rate killer for subprocess-bound segments.
        _ = drag(offset, redrawScopedSegment);
    }
}

/// Ends a press-hold scrub: clears the drag anchor and lets the segment
/// settle the drag (flush a throttled commit, leave its drag render mode).
pub fn handleButtonRelease(_: *const xcb.xcb_button_release_event_t) void {
    const s = gBar.state orelse return;
    const id = s.drag_segment orelse return;
    s.drag_segment = null;
    if (segAt(id).onDragEnd) |end| end(redrawInsideGrab);
}

/// `offset` is the click position relative to the title segment's start.
/// Resolves which window is under the click via the title snapshot captured
/// by the last draw (hitTest never touches X11: titles/geoms come from the
/// frame's in-process per-window caches), then:
///   - no window under the click -> no-op (empty title is handled by the
///     right-click prompt path in `handleButtonPress`, before this is called)
///   - the window is minimized -> unminimizes that window
///   - the window is already focused -> minimizes it
///   - otherwise -> focuses it
fn handleTitleClick(s: *State, offset: u16) void {
    if (s.frame.wins_len == 0) return;
    const tb = titleIdBound(s) orelse return;

    const target = segmod.hitTest(
        s.frame.last_ctx.titleRenderContext(tb.x, tb.w),
        s.frame.last_ctx.titleSnapshot(),
        offset,
    ) orelse return;

    // `target.minimized` comes from the title snapshot's minimized set, which
    // the title addon synthesizes fresh; bar.zig never names minimize.
    if (target.minimized)
        actions.restore(target.window)
    else if (focus.getFocused() == target.window)
        actions.minimize(target.window)
    else
        focus.grabFocus(target.window, .mouse_click);
}

fn titleClickTrampoline(ptr: *anyopaque, offset: u16) void {
    const s: *State = @ptrCast(@alignCast(ptr));
    handleTitleClick(s, offset);
}

/// Comptime-registered UI-surface hooks for core's event loop (comptime
/// reference point: the one place the loop knows the bar exists). Core calls
/// these through a single `surfaces.Surfaces` alias; when the bar is absent the
/// whole set is `null` and every such call site compiles away. The emitter
/// lives in this module, so detaching the bar detaches its handlers. The hook
/// types themselves live in the core-owned `plugin` interface contract, not
/// here: this module only binds its functions to that contract.
pub const surfaces = @import("contract").Surfaces{
    .init = init,
    .deinit = deinit,
    .handleExpose = handleExpose,
    .updateIfDirty = updateIfDirty,
    .pollTimeoutMs = pollTimeoutMs,
    .onPollWakeup = onPollWakeup,
    .updateClock = updateClock,
    .randrFirstEvent = refresh.randrFirstEvent,
    .handleRandrEvent = refresh.handleRandrNotifyEvent,
    .runPendingRedetect = refresh.runPendingRedetect,
    .onReload = reload,
    .refreshConfig = refreshConfig,
    .chromeHandleKeypress = chromeHandleKeypress,
    .isBarWindow = isBarWindow,
    .handleButtonPress = handleButtonPress,
    .handleButtonMotion = handleButtonMotion,
    .handleButtonRelease = handleButtonRelease,
    .setBarState = setBarState,
    .hideBarForFullscreen = hideBarForFullscreen,
    .updateBarVisibilityForWorkspace = updateBarVisibilityForWorkspace,
    .toggleBarSegmentAnchor = toggleBarSegmentAnchor,
    .chromeToggleOverlay = chromeToggleOverlay,
};
