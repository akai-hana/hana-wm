//! Status bar
//! Creates and manages the WM status bar, rendering all configured segments.
//!
//! Rendering uses per-segment dirty tracking: the dirty set is registry-sized
//! (one bool per bar_modules entry, D13); only dirty segments are repainted on
//! each draw. The global force flag or a full dirty set triggers a complete
//! background clear + repaint. Coalescing happens through the dirty-mark
//! scheduling (scheduleRedraw & friends).
//!
//! Bar segments are an open, drop-in addon set (D3/B3): the build generates the
//! `bar_modules.modules` registry and this orchestrator owns NO segment logic.
//! Lifecycle/polls/draw/width/click/prompt-extras are all driven by uniform
//! loops over that registry, dispatching through the Segment contract. The bar
//! never names a specific segment module (D9/D10): services flow one-way
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

const window = @import("window");

const drawing = @import("drawing");
const segmod = @import("segment");
const barwin = @import("win");

// Window-addon registry (generated): the fullscreen-hide decision is routed
// through the coverageOn seam instead of naming the fullscreen module (D12).
const window_mods = @import("window_modules").modules;

// Registry-resolved segment identity (comptime): the bar locates modules by
// name through the generated registry instead of importing them directly.
// Every registry-indexing site is guarded by a comptime `registry_empty` check
// so the bar still compiles when ALL segments are removed (empty registry):
// the guards make the dead indexing expressions comptime-unreachable.
const bar_mods = @import("bar_modules").modules;
const registry_len = bar_mods.len;
const registry_empty = registry_len == 0;

const self_ticking_role: ?usize = segmod.findByCapability(&bar_mods, .{ .self_ticking = true });
const center_slot_role: ?usize = segmod.findByCapability(&bar_mods, .{ .center_slot = true });

inline fn segId(name: []const u8) ?usize {
    return segmod.idByName(&bar_mods, name);
}

// ---------------------------------------------------------------------------
// Bar height / font-size resolution (folded from metrics.zig).
//
// Owns everything needed to decide the bar's pixel height and effective font
// size from config + font metrics, including the percentage-font-size probe
// (which measures through drawing.probeFontMetrics' throwaway surface, no
// live DrawContext is touched). The documented config write in
// calcBarHeightAndFontSize (scaled_font_size is runtime state that happens
// to live on BarConfig) is the only side effect.

const min_bar_height: u32 = scale.bar_min_height_px;
const max_bar_height: u32 = 200;
const default_bar_height: u32 = 24;

fn measureFontMetrics() ?struct { asc: i32, desc: i32 } {
    const cs = core.getState();
    const sized = drawing.buildSizedFontList(cs.alloc, null) catch return null;
    defer drawing.freeSizedFontList(cs.alloc, sized);
    const m = drawing.probeFontMetrics(cs.alloc, core.dpi_info.load(.acquire), sized) orelse return null;
    return .{ .asc = m.ascent, .desc = m.descent };
}

fn resolvePercentageFontSize(bar_height: u16) ?u16 {
    // Probe metrics at a trial point size via the override parameter, so
    // there is no save/mutate/restore round on cs.config.
    const trial_pt: u16 = 100;
    const cs = core.getState();
    const sized = drawing.buildSizedFontList(cs.alloc, trial_pt) catch return null;
    defer drawing.freeSizedFontList(cs.alloc, sized);
    const m = drawing.probeFontMetrics(cs.alloc, core.dpi_info.load(.acquire), sized) orelse return null;
    const px_per_pt: f32 = @as(f32, @floatFromInt(@max(1, m.ascent + m.descent))) / @as(f32, @floatFromInt(trial_pt));
    const max_size_pt = @as(f32, @floatFromInt(bar_height)) / px_per_pt;
    const cfg_pct = cs.config.bar.font_size.value / 100.0;
    return @max(1, @as(u16, @intFromFloat(@round(max_size_pt * cfg_pct))));
}

fn calcBarHeightAndFontSize() !u16 {
    const cs = core.getState();
    if (cs.config.bar.height) |h| {
        const height = scale.scaleBarHeight(h, cs.screen.height_in_pixels);
        if (cs.config.bar.font_size.is_percentage) {
            if (resolvePercentageFontSize(height)) |sz|
                cs.config.bar.scaled_font_size = sz;
        }
        return height;
    }
    const m = measureFontMetrics() orelse return default_bar_height;
    return @intCast(std.math.clamp(@max(1, m.asc + m.desc), @as(i32, @intCast(min_bar_height)), @as(i32, @intCast(max_bar_height))));
}

// ---------------------------------------------------------------------------

/// Uniform poll wakeup: runs every module's onPollWakeup hook (prompt caret
/// blink, marquee repaint-marking, ...) then submits a draw. The bar never
/// names a segment.
pub fn onPollWakeup() void {
    for (bar_mods) |m| {
        if (m.onPollWakeup) |h| h();
    }
    // A module's poll hook (e.g. the prompt's caret-blink toggle) must reach
    // the draw's repaint gate: fold any queued module redraw request into the
    // force flag, exactly as the X-batch update path (updateIfDirty) does, so
    // the animation is visible even when the loop is waking only on the poll
    // timer with no X traffic to trigger that path.
    if (barModsConsumeRedrawRequest()) gBar.force = true;
    submitDraw();
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
        if (!s.is_visible) return -1;
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

fn monotonicMs() i64 {
    return @intCast(utils.monotonicNs() / std.time.ns_per_ms);
}

/// Routes a keypress through every module that consumes one (the chrome
/// overlay segment).
pub fn chromeHandleKeypress(event: *const xcb.xcb_key_press_event_t, matched: ?*const types.Action) bool {
    for (bar_mods) |m| {
        if (m.handleKeypress) |h| if (h(event, matched)) return true;
    }
    return false;
}

/// Toggles the chrome overlay. Routed through the resolved title module's
/// onClick hook (right-click path): the overlay lives in the title module
/// (D9) and the bar must not name it.
pub fn chromeToggleOverlay() void {
    const s = gBar.state orelse return;
    if (center_slot_role) |tid| {
        if (bar_mods[tid].onClick) |oc|
            _ = oc(0, false, true, s, titleClickTrampoline, redrawInsideGrab);
    }
}

/// Global bar coordination flags. Read and written exclusively on the main
/// thread; no mutex protection required.
const Bar = struct {
    state: ?*State = null,
    /// Forces the next draw to re-fetch title data (per-window titles +
    /// geometries, focused title) even when the cheap change-detection keys
    /// say nothing changed. Set by expose/reload/show/property-notify paths;
    /// normal ticks just redraw from live state. Consumed by every draw.
    force: bool = false,
    /// True when presentForPrompt() had to map an otherwise-hidden bar (e.g.
    /// hidden by a fullscreen window, or by the user toggling it off) purely
    /// so the inline prompt would be visible. dismissAfterPrompt() checks this
    /// to know whether hiding the bar again is part of "returning to normal".
    prompt_forced_visible: bool = false,
    /// When set, the next draw skips the title-data refetch (focused title
    /// + batched titles/geometries) and uses whatever was last cached. Set
    /// by the bar-toggle show path so the initial frame avoids blocking on
    /// XCB property reads; cleared after the first draw so the next event
    /// batch picks up fresh titles.
    skip_title_refetch: bool = false,
};

// PATTERN: Module-global state with explicit init/deinit lifecycle.
// This avoids allocator threading through every function call.
// The init/deinit pair is called from main.zig's startup/shutdown sequence.
// All functions operate on `g` directly, with no passing state as parameters.
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
    net_wm_name_atom: xcb.xcb_atom_t,

    fn deinit(self: *WindowCtx) void {
        if (self.colormap != 0) _ = xcb.xcb_free_colormap(self.conn, self.colormap);
    }
};

const RenderCtx = struct {
    dc: *drawing.DrawContext,
    config: types.BarConfig,
    width: u16,
    height: u16,
    allocator: std.mem.Allocator,
};

/// Per-frame window-count bound for the title scratch buffers. Matches
/// segment.zig's batch scratch limit (constants.Limits.max_tiled_windows).
const max_frame_windows: usize = constants.Limits.max_tiled_windows;

/// Upper bound on recorded click bounds: one slot per clickable segment in
/// the configured layout. Configs with more clickable segments than this
/// simply lose clickability on the extras (rendering is unaffected).
const max_click_bounds: usize = 8;

/// Scratch bound for the per-draw right-cluster segment widths. Right segments
/// are measured once into this buffer and reused for both the total-width
/// calculation and the draw; a config with more than this many right segments
/// falls back to re-measuring at draw time (layout math identical, no win).
const max_right_segments: usize = 16;

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

/// All live bar state. The title-data scratch below is refetched only when
/// its tiny change-detection key (window ids + minimized flags) changes or a
/// draw is forced; every other field is recomputed per frame.
const State = struct {
    win: WindowCtx,
    render: RenderCtx,

    is_visible: bool = true,
    is_globally_visible: bool = true,
    is_dirty: bool = false,
    /// Per-segment dirty flags, one per entry in the generated bar_modules
    /// registry (D13). When set, the segment is repainted on the next draw;
    /// cleared after painting. Every segment starts dirty so the first draw
    /// is a full redraw.
    segment_dirty: [bar_mods.len]bool = @splat(true),

    /// Reserved width of the clock segment (measure string + padding).
    clock_width: u16 = 0,
    /// Left edge of the clock from the last layout pass; enables the
    /// region-scoped clock blit in drawClockOnly.
    clock_x: ?u16 = null,

    /// Click bounds recorded by the last layout pass, in record order.
    bounds: [max_click_bounds]SegBound = undefined,
    bounds_len: usize = 0,

    // -- Live frame state (recollected on every draw; see scanLiveFrame) --

    ws_count: u32 = 0,
    current_ws: u8 = 0,
    all_view: bool = false,
    ws_has_windows: [constants.max_workspaces]bool = @splat(false),
    wins: [max_frame_windows]u32 = undefined,
    wins_len: usize = 0,

    // -- Title data scratch --

    /// Change-detection key for the batched prefetch: the current
    /// workspace's window ids plus their minimized membership. Compared
    /// against the previous frame's key; a mismatch is what triggers the
    /// (blocking) X11 batch refetch.
    fetch_key_ids: [max_frame_windows]u32 = undefined,
    fetch_key_minimized: [max_frame_windows]bool = undefined,
    fetch_key_len: usize = 0,
    fetch_key_valid: bool = false,
    /// Set by scanLiveFrame when the key changed since the stored key.
    fetch_dirty: bool = false,

    minimized: std.AutoHashMapUnmanaged(u32, void) = .{},
    /// Title addon's minimized-state service, cached from the DrawCtx after
    /// the first draw so scanLiveFrame can synthesize the set each frame
    /// without bar.zig naming the minimize addon (D12).
    minimized_api: segmod.MinimizedApi = .{},
    /// Title-string arena: every slice in `titles_buf` points into it, so a
    /// refetch reclaims all strings with one reset (capacity retained).
    titles_arena: std.heap.ArenaAllocator = undefined,
    /// Batched per-window prefetch scratch (see segmod.fetchTitlesAndGeoms),
    /// valid in [0, fetched_len) until the next refetch. Failed geometry
    /// replies are padded with the off-screen sentinel at refetch time.
    titles_buf: [max_frame_windows][]const u8 = undefined,
    geoms_buf: [max_frame_windows]?utils.Rect = undefined,
    fetched_len: usize = 0,
    focused_title: std.ArrayListUnmanaged(u8) = .empty,
    /// Window the focused_title buffer was fetched for (null = never/stale).
    focused_title_window: ?u32 = null,

    // -- Last-seen core fact revisions (see core.Facts) --

    /// Last focus_rev we diffed in updateIfDirty. A change marks the title
    /// segment dirty (cheap). Initialized sentinel so the first update draws.
    last_focus_rev: u32 = std.math.maxInt(u32),
    /// Last window_rev we diffed. A change marks all segments dirty (the
    /// workspaces/title segments reflect window & workspace state).
    last_window_rev: u32 = std.math.maxInt(u32),
    /// Last layout_rev we diffed. A change forces a full redraw (all segments
    /// + a title-data refetch).
    last_layout_rev: u32 = std.math.maxInt(u32),
    /// Last fullscreen_rev we diffed. A change means fullscreen occupancy of
    /// the current workspace changed; the bar recomputes its forced hidden/
    /// shown state (shared-screen reaction) from the core fact.
    last_fullscreen_rev: u32 = std.math.maxInt(u32),

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
        // Reserved clock width comes from the resolved clock module's
        // measureString hook (at most one module provides it).
        var clock_width: u16 = 0;
        if (self_ticking_role) |cid| {
            if (bar_mods[cid].measureString) |ms|
                clock_width = dc.measureTextWidth(ms()) + 2 * config.scaledSegmentPadding(height);
        }
        s.* = .{
            .win = .{
                .conn = conn,
                .win_id = win_id,
                .colormap = colormap,
                .net_wm_name_atom = utils.getAtomCached("_NET_WM_NAME") catch 0,
            },
            .render = .{
                .dc = dc,
                .config = config,
                .width = width,
                .height = height,
                .allocator = allocator,
            },
            .clock_width = clock_width,
        };
        s.titles_arena = std.heap.ArenaAllocator.init(allocator);
        // Partial-failure mirror of deinit(); the caller's errdefers own the
        // window+colormap and the dc.
        errdefer {
            s.minimized.deinit(allocator);
            s.focused_title.deinit(allocator);
            s.titles_arena.deinit();
            allocator.destroy(s);
        }
        try s.focused_title.ensureTotalCapacity(allocator, 256);
        // Width caches for size-varying segments (workspaces/layout/variants)
        // are invalidated per bar creation via their uniform invalidate hooks.
        for (bar_mods) |m| {
            if (m.invalidate) |iv| iv();
        }
        return s;
    }

    fn deinit(self: *State) void {
        self.win.deinit();
        const alloc = self.render.allocator;
        self.minimized.deinit(alloc);
        self.focused_title.deinit(alloc);
        self.titles_arena.deinit();
        alloc.destroy(self);
    }

    fn markDirty(self: *State) void {
        self.is_dirty = true;
        self.markAllSegmentsDirty();
    }

    fn clearSegmentDirty(self: *State, name: []const u8) void {
        if (comptime registry_empty) return;
        if (segId(name)) |id| self.segment_dirty[id] = false;
    }

    /// Marks dirty every segment whose declared `dirty_sources` has bit
    /// `source` set, and flags the bar dirty. Name-free: the bit masks are a
    /// declared contract capability, not a name-keyed lookup.
    fn markDirtySource(self: *State, source: segmod.DirtySourcesSource) void {
        self.is_dirty = true;
        if (comptime registry_empty) return;
        for (bar_mods, 0..) |m, i| {
            if (segmod.hasSource(m.dirty_sources, source)) self.segment_dirty[i] = true;
        }
    }

    /// True when the segment must be repainted on this draw: its dirty bit
    /// is set, or it declares the self-animated repaint capability and its
    /// runtime query reports active (e.g. a scrolling marquee: the motion
    /// only advances while the segment is drawn, so change detection must
    /// not skip it). Uniform: resolved by registry, never by segment name.
    fn isSegmentRepaintable(self: *const State, name: []const u8) bool {
        if (comptime registry_empty) return false;
        const id = segId(name) orelse return false;
        if (self.segment_dirty[id]) return true;
        if (bar_mods[id].needsRepaint) |q| return q();
        return false;
    }

    fn markAllSegmentsDirty(self: *State) void {
        @memset(&self.segment_dirty, true);
    }

    /// True when every registry slot is dirty (the complete-background-clear
    /// trigger). Non-configured segments (e.g. the prompt overlay) are never
    /// drawn and never cleared, so an all-dirty set only occurs on force.
    fn isFullDirty(self: *const State) bool {
        for (self.segment_dirty) |d| {
            if (!d) return false;
        }
        return true;
    }

    /// Records the on-screen bounds of a clickable segment as the layout pass
    /// positions it, so handleButtonPress can hit-test against them without
    /// redoing the layout. Called unconditionally for every segment; segments
    /// whose module declares `clickable == false` (the clock) are skipped.
    fn recordClickBound(self: *State, name: []const u8, x: u16, w: u16) void {
        if (comptime registry_empty) return;
        const id = segId(name) orelse return;
        if (!bar_mods[id].clickable) return;
        if (self.bounds_len >= max_click_bounds) return;
        self.bounds[self.bounds_len] = .{ .name = name, .x = x, .w = w };
        self.bounds_len += 1;
    }

    fn recordedBound(self: *const State, name: []const u8) ?SegBound {
        for (self.bounds[0..self.bounds_len]) |b| {
            if (std.mem.eql(u8, b.name, name)) return b;
        }
        return null;
    }

    /// True when `name` resolves to the segment claiming the reserved center
    /// slot (name-free; the role is the title capability today).
    fn isCenterSlot(self: *const State, name: []const u8) bool {
        _ = self;
        if (comptime registry_empty) return false;
        const id = segId(name) orelse return false;
        return center_slot_role != null and id == center_slot_role.?;
    }

    /// True when `name` resolves to the self-ticking segment (name-free; the
    /// role is the clock capability today).
    fn isSelfTicking(self: *const State, name: []const u8) bool {
        _ = self;
        if (comptime registry_empty) return false;
        const id = segId(name) orelse return false;
        return self_ticking_role != null and id == self_ticking_role.?;
    }

    /// Measures a segment's natural (reserved) width via its uniform
    /// naturalWidth hook, or 0 for an unknown/removed segment name.
    fn measureSegmentWidth(self: *State, frame: *const segmod.Frame, name: []const u8) u16 {
        if (comptime registry_empty) return 0;
        const id = segId(name) orelse return 0;
        if (bar_mods[id].naturalWidth) |nw| return nw(frame, self.clock_width);
        return 0;
    }

    /// Stable per-call title rendering context for post-draw hit testing.
    fn titleCtx(self: *const State, x: u16, w: u16) segmod.TitleRenderContext {
        return .{
            .dc = self.render.dc,
            .config = self.render.config,
            .height = self.render.height,
            .start_x = x,
            .width = w,
            .conn = self.win.conn,
        };
    }

    /// Builds the title segment's view of the live frame from scratch state.
    /// All backing memory lives on State (titles arena, focused-title buffer),
    /// valid for the rest of the frame AND for post-draw click handling.
    fn titleSnapshot(self: *const State) segmod.TitleSnapshot {
        const wins_slice = self.wins[0..self.wins_len];
        // Title of the minimized window, used in the single-window title case.
        var minimized_title: []const u8 = "";
        if (wins_slice.len > 0 and self.minimized.contains(wins_slice[0]) and self.fetched_len > 0)
            minimized_title = self.titles_buf[0];
        return .{
            .focused_window = focus.getFocused(),
            .focused_title = self.focused_title.items,
            .minimized_title = minimized_title,
            .current_ws_wins = wins_slice,
            .minimized_set = &self.minimized,
            .titles = self.titles_buf[0..self.fetched_len],
            .geoms = self.geoms_buf[0..self.fetched_len],
        };
    }

    /// Fills the shared per-frame DrawCtx the bar hands to every segment's
    /// draw hook, including the title snapshot slots.
    fn fillDrawCtx(self: *State, ctx: *segmod.DrawCtx) void {
        ctx.frame = .{
            .workspace_count = self.ws_count,
            .current_workspace = self.current_ws,
            .is_all_view_active = self.all_view,
            .workspace_has_windows = self.ws_has_windows[0..self.ws_count],
        };
        // The minimized-state service is drawn from the window module registry
        // here (upfront, per frame) so the title segment need not name the
        // addon that owns it (D12). All hooks null => empty api => scanLiveFrame
        // no-ops, matching prior boot ordering.
        ctx.minimized_api = minimizedApiFromRegistry();
        const wins_slice = self.wins[0..self.wins_len];
        var minimized_title: []const u8 = "";
        if (wins_slice.len > 0 and self.minimized.contains(wins_slice[0]) and self.fetched_len > 0)
            minimized_title = self.titles_buf[0];
        ctx.focused_window = focus.getFocused();
        ctx.focused_title = self.focused_title.items;
        ctx.minimized_title = minimized_title;
        ctx.current_ws_wins = wins_slice;
        ctx.minimized_set = &self.minimized;
        ctx.titles = self.titles_buf[0..self.fetched_len];
        ctx.geoms = self.geoms_buf[0..self.fetched_len];
    }

    // -- Live-state collection ------------------------------------------------

    /// Reads workspace/window state into the frame fields and diffs the
    /// batch-refetch key against the stored one. Pure model reads: no X11.
    /// Returns true when the key changed (batch refetch needed).
    fn scanLiveFrame(self: *State) bool {
        const m = pipeline.model();
        // The minimized set feeds the fetch-key diff below and the title
        // snapshot; the title addon owns the synthesis (D12), exposed through
        // the cached DrawCtx api. Synthesizing fresh each scan makes set
        // membership equivalent to a live per-window query.
        if (build_options.has_minimize) {
            if (self.minimized_api.collect) |f| f(m, &self.minimized, self.render.allocator);
        }
        if (build_options.has_workspaces) {
            self.ws_count = @intCast(tracking.getWorkspaceCount());
            self.current_ws = @intCast(m.current);
            self.all_view = m.all_view_active;
            @memset(&self.ws_has_windows, false);
            self.wins_len = 0;
            const cur_bit: u64 = if (self.current_ws < self.ws_count)
                tracking.workspaceBit(self.current_ws)
            else
                0;
            // OR-accumulate all window masks in a single pass, collecting the
            // current workspace's windows on the way.
            var combined_mask: u64 = 0;
            for (tracking.allWindows()) |entry| {
                combined_mask |= entry.mask;
                if (cur_bit != 0 and entry.mask & cur_bit != 0 and self.wins_len < max_frame_windows) {
                    self.wins[self.wins_len] = entry.win;
                    self.wins_len += 1;
                }
            }
            for (0..self.ws_count) |i| {
                self.ws_has_windows[i] = combined_mask & tracking.workspaceBit(@as(u8, @intCast(i))) != 0;
            }
        }

        // Diff the fetch key: ids plus minimized membership (a minimize flips
        // the window's title-view geometry to the off-screen sentinel, which
        // demotes it in the split-view sort, and that IS a data change).
        var changed = !self.fetch_key_valid or self.fetch_key_len != self.wins_len;
        for (0..self.wins_len) |i| {
            const minf = if (build_options.has_minimize)
                (if (self.minimized_api.is_minimized) |f| f(m, self.wins[i]) else false)
            else
                false;
            if (!changed and (self.fetch_key_ids[i] != self.wins[i] or self.fetch_key_minimized[i] != minf))
                changed = true;
            self.fetch_key_ids[i] = self.wins[i];
            self.fetch_key_minimized[i] = minf;
        }
        self.fetch_key_len = self.wins_len;
        self.fetch_key_valid = true;
        return changed;
    }

    /// Refreshes title data: the focused window's title (one buffered
    /// property read, only when focus moved or forced) and the batched
    /// per-window titles/geometries (only when the fetch key changed or
    /// forced). Everything else reuses the scratch from the last fetch.
    fn refreshTitleData(self: *State) void {
        if (gBar.skip_title_refetch) {
            gBar.skip_title_refetch = false;
            return;
        }

        const alloc = self.render.allocator;

        const fw = focus.getFocused();
        if (fw != self.focused_title_window or gBar.force) {
            self.focused_title.clearRetainingCapacity();
            if (fw) |w| segmod.fetchWindowTitleInto(self.win.conn, w, &self.focused_title, alloc) catch {};
            self.focused_title_window = fw;
        }

        if (gBar.force or self.fetch_dirty) self.refetchBatchedTitleData();
        self.fetch_dirty = false;
    }

    /// Re-runs the batched title/geometry prefetch into the scratch buffers.
    /// One dupe per title, ~2 round-trips total, zero blocking waits beyond
    /// those replies themselves (see segmod.fetchTitlesAndGeoms).
    fn refetchBatchedTitleData(self: *State) void {
        _ = self.titles_arena.reset(.retain_capacity);
        segmod.fetchTitlesAndGeoms(
            self.win.conn,
            self.wins[0..self.wins_len],
            &self.minimized,
            .{},
            .{
                .titles = self.titles_buf[0..self.wins_len],
                .geoms = self.geoms_buf[0..self.wins_len],
            },
            self.titles_arena.allocator(),
        );
        self.fetched_len = self.wins_len;
        // Pad failed live geometry replies with the off-screen sentinel so a
        // dead window sorts last instead of vanishing from the split view.
        for (self.geoms_buf[0..self.fetched_len]) |*g| {
            if (g.* == null) g.* = segmod.offscreen_rect;
        }
    }

    // -- Drawing ---------------------------------------------------------------

    /// Draws a segment by registry dispatch, catching and logging errors
    /// instead of propagating them. On failure returns `x` unchanged (the
    /// "drew nothing" signal) so a broken segment can't corrupt the layout.
    fn drawSegmentSafe(self: *State, ctx: *segmod.DrawCtx, name: []const u8, x: u16, width: ?u16) u16 {
        return self.drawSegment(ctx, name, x, width) catch |e| {
            debug.warnOnErr(e, "bar drawSegment");
            return x;
        };
    }

    fn drawSegment(self: *State, ctx: *segmod.DrawCtx, name: []const u8, x: u16, width: ?u16) !u16 {
        if (comptime registry_empty) return error.DrewInvalidSegment;
        const id = segId(name) orelse return error.DrewInvalidSegment;
        if (bar_mods[id].draw == null) return error.DrewInvalidSegment;
        // The DrawCtx is shared mutable scratch: pin the reserved width into it
        // immediately before the draw so width-reading renderers (the title)
        // advance correctly.
        ctx.width = width orelse self.measureSegmentWidth(&ctx.frame, name);
        return bar_mods[id].draw.?(ctx, x);
    }

    /// Draws one segment of a left-to-right row, painting the inter-segment gap
    /// and advancing `x`. `w` is the reserved width; `omit_gap_after_title`
    /// suppresses the gap after a title so the next segment sits flush (center
    /// layout). Returns the new `x`.
    fn drawRowSegment(
        self: *State,
        ctx: *segmod.DrawCtx,
        name: []const u8,
        x: u16,
        w: u16,
        omit_gap_after_title: bool,
        scaled_spacing: u16,
    ) u16 {
        const omit_gap = omit_gap_after_title and self.isCenterSlot(name);
        const x_before = x;
        const drawn_x = self.drawSegmentSafe(ctx, name, x, w);
        const drew = drawn_x != x_before;
        if (!omit_gap) {
            // On success advance past the drawn text plus the trailing gap.
            if (drew) {
                self.paintGap(drawn_x, scaled_spacing);
                return drawn_x + scaled_spacing;
            }
            // On failure drawSegmentSafe returns x unchanged ("drew nothing").
            // Still consume the full reserved slot + gap so the NEXT segment
            // leftward starts where the layout pass expects; returning the
            // unchanged x would let that segment paint over this failed slot
            // (and, on the follow-up frame, desync the whole cluster). Matches
            // drawRightSegments' failed-draw handling.
            return x + w + scaled_spacing;
        }
        return drawn_x;
    }

    fn paintGap(self: *State, gap_x: u16, scaled_spacing: u16) void {
        self.render.dc.fillRect(gap_x, 0, scaled_spacing, self.render.height, self.render.config.bg);
    }

    fn drawRightSegments(
        self: *State,
        ctx: *segmod.DrawCtx,
        names: []const []const u8,
        widths: ?[]const u16,
        is_full_redraw: bool,
    ) void {
        const frame = &ctx.frame;
        const scaled_spacing = self.render.config.scaledSpacing(self.render.height);
        var right_x = self.render.width;
        var pending_gap = false;
        var i = names.len;
        while (i > 0) {
            i -= 1;
            // Widths measured once up front in drawAllInner (null only when the
            // right cluster exceeds the scratch buffer, which falls back to the
            // original measure-at-draw re-measurement below).
            const seg_w = if (widths) |ws| ws[i] else self.measureSegmentWidth(frame, names[i]);
            right_x -= seg_w;
            if (pending_gap) right_x -= scaled_spacing;

            if (self.isSelfTicking(names[i])) self.clock_x = right_x;
            self.recordClickBound(names[i], right_x, seg_w);

            if (self.isSegmentRepaintable(names[i])) {
                if (!is_full_redraw) {
                    self.render.dc.fillRect(right_x, 0, seg_w, self.render.height, self.render.config.bg);
                }
                const drew = self.drawSegmentSafe(ctx, names[i], right_x, null) != right_x;
                if (drew) {
                    if (pending_gap) self.paintGap(right_x + seg_w, scaled_spacing);
                } else {
                    right_x += seg_w;
                    if (pending_gap) right_x += scaled_spacing;
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
    }

    /// Repaints the bar into the off-screen pixmap. When every segment is
    /// dirty (full redraw / force) the whole background is cleared once;
    /// otherwise only the dirty segments' regions are repainted, leaving
    /// unchanged pixels from the previous frame untouched.
    fn drawAllInner(self: *State, ctx: *segmod.DrawCtx) void {
        const r = &self.render;
        const frame = &ctx.frame;
        const scaled_spacing = r.config.scaledSpacing(r.height);
        const is_full_redraw = self.isFullDirty();

        if (is_full_redraw) {
            r.dc.fillRect(0, 0, r.width, r.height, r.config.bg);
        }

        var right_total: u16 = 0;
        var right_widths: [max_right_segments]u16 = undefined;
        var right_widx: usize = 0;
        for (r.config.layout.items) |lay| {
            if (lay.position != .right) continue;
            for (lay.segments.items) |seg| {
                // One measurement per right segment per draw; the reserved
                // widths feed BOTH the right-cluster total (used by the
                // left/center placement below) and the draw itself.
                const w = self.measureSegmentWidth(frame, seg);
                if (right_widx < max_right_segments) right_widths[right_widx] = w;
                right_widx += 1;
                right_total += w + scaled_spacing;
            }
            if (lay.segments.items.len > 0) right_total -= scaled_spacing;
        }
        const right_measured = right_widx <= max_right_segments;

        self.bounds_len = 0;
        var x: u16 = 0;
        var right_ridx: usize = 0;
        for (r.config.layout.items) |lay| {
            switch (lay.position) {
                .left, .center => {
                    // Available horizontal space before the right cluster.
                    const avail = r.width -| x -| right_total;
                    const remaining = if (lay.position == .center)
                        // Clamp the reserved title width to the space actually
                        // available so a tight right+left row can't overflow the
                        // title into the right-segment area (min_width is a floor
                        // only when the space exists; otherwise it shrinks).
                        @min(@max(segmod.title_min_width, avail -| scaled_spacing), avail)
                    else
                        0;
                    for (lay.segments.items) |seg| {
                        const is_center = self.isCenterSlot(seg);
                        const omit_gap = (lay.position == .center) and is_center;
                        const w = if (is_center) remaining else self.measureSegmentWidth(frame, seg);
                        self.recordClickBound(seg, x, w);
                        // clock_x must be recorded for a self-ticking segment
                        // in ANY cluster (not just right): drawClockOnly relies
                        // on it regardless of where the clock is laid out.
                        if (self.isSelfTicking(seg)) self.clock_x = x;
                        if (self.isSegmentRepaintable(seg)) {
                            if (!is_full_redraw) {
                                const clear_w = if (omit_gap) w else w + scaled_spacing;
                                r.dc.fillRect(x, 0, clear_w, r.height, r.config.bg);
                            }
                            x = self.drawRowSegment(ctx, seg, x, w, lay.position == .center, scaled_spacing);
                            self.clearSegmentDirty(seg);
                        } else {
                            x += w;
                            if (!omit_gap) x += scaled_spacing;
                        }
                    }
                },
                .right => {
                    const ws = if (right_measured) right_widths[right_ridx..][0..lay.segments.items.len] else null;
                    self.drawRightSegments(ctx, lay.segments.items, ws, is_full_redraw);
                    right_ridx += lay.segments.items.len;
                },
            }
        }
    }

    /// Redraws just the clock segment when its on-screen content is stale
    /// (second rolled over). Cheap region-scoped blit.
    fn drawClockOnly(self: *State) void {
        const clock_x = self.clock_x orelse return;
        const cid = self_ticking_role orelse return;
        if (bar_mods[cid].draw == null) return;
        var ctx = segmod.DrawCtx{
            .dc = self.render.dc,
            .config = self.render.config,
            .height = self.render.height,
            .conn = self.win.conn,
            .allocator = self.render.allocator,
            .frame = .{},
        };
        const drawn_end = bar_mods[cid].draw.?(&ctx, clock_x) catch |e| {
            debug.warnOnErr(e, "drawClockOnly");
            return;
        };
        // Region-scoped blit: copies only the clock region and flushes (this
        // is a timer-driven path; no event-loop flush is coming). Blit at
        // least what was PAINTED (drawn_end can exceed the layout-time
        // reservation after font fallback or digit-width drift: blitting
        // only the cached width would clip digits) while keeping the full
        // reserved slot covered so stale pixels from a wider earlier frame
        // still get overwritten with the clean background the last full
        // frame left.
        const drawn_w: u16 = drawn_end -| clock_x;
        self.render.dc.blitRegion(clock_x, @max(self.clock_width, drawn_w));
        self.clearSegmentDirty(bar_mods[cid].name);
    }
};

// Draw submission

/// Collects live state, repaints every segment into the off-screen pixmap,
/// and queues the single xcb_copy_area blit (cairo_surface_flush included,
/// xcb_flush NOT: the caller's context flushes (event-loop end-of-batch on
/// normal paths, ungrabAndFlush inside grabs).
fn performDraw() void {
    const s = gBar.state orelse return;
    if (!s.is_visible) return;
    if (gBar.force) s.markAllSegmentsDirty();
    s.fetch_dirty = s.scanLiveFrame();
    s.refreshTitleData();
    var ctx = segmod.DrawCtx{
        .dc = s.render.dc,
        .config = s.render.config,
        .height = s.render.height,
        .conn = s.win.conn,
        .allocator = s.render.allocator,
        .frame = .{},
    };
    s.fillDrawCtx(&ctx);
    s.drawAllInner(&ctx);
    // Cache the minimized-state service (built by fillDrawCtx from the window
    // module registry) so scanLiveFrame can synthesize the set each frame
    // (D12). Guarded so an empty api still leaves the prior snapshot intact.
    if (ctx.minimized_api.is_minimized != null) s.minimized_api = ctx.minimized_api;
    s.render.dc.queueBlit();
    gBar.force = false;
}

fn submitDrawBlockingFull() void {
    gBar.force = true;
    performDraw();
}

inline fn ungrabAndFlush() void {
    utils.ungrabAndFlush(core.getState().conn);
}

/// Draws and blits to the window. Drawing always happens inline on the
/// calling thread.
pub fn submitDraw() void {
    performDraw();
}

/// Everything a fully-initialised bar owns; returned by createBar.
const BarSetup = struct {
    setup: barwin.BarWindowSetup,
    dc: *drawing.DrawContext,
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
    debug.info("Bar transparency: {s}", .{if (setup.has_argb) "enabled (ARGB)" else "disabled (opaque)"});
    const state = try State.init(cs.alloc, cs.conn, setup.win_id, setup.colormap, cs.screen.width_in_pixels, height, dc, cs.config.bar);
    return .{ .setup = setup, .dc = dc, .state = state };
}

// Lifecycle

pub fn init() !void {
    const cs = core.getState();
    std.debug.assert(cs.config.bar.enabled);
    barwin.initAtoms();
    refresh.ensureRefreshRateDetected(cs.conn);
    const height = try calcBarHeightAndFontSize();
    const bar = try createBar(height, barwin.calcBarYPos(height));
    gBar.state = bar.state;
    screen.setSurfaceWindow(bar.setup.win_id);
    submitDraw();
    _ = xcb.xcb_map_window(cs.conn, bar.setup.win_id);
    _ = xcb.xcb_flush(cs.conn);
    // Uniform lifecycle: every registered mechanism segment (incl. the prompt,
    // whose init owns the vim addon lifecycle, D11) is initialised with the
    // bar's one-way service handles (D10). The handles live in the file-scope
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
    screen.releaseClaim(screen.bar_id.?);
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
    const height = calcBarHeightAndFontSize() catch default_bar_height;
    applyReload(old, height) catch |err| {
        debug.err("Bar reload failed ({s}), keeping old bar", .{@errorName(err)});
    };
}

fn applyReload(old: *State, height: u16) !void {
    const cs = core.getState();
    // Module caches (font widths, caret geometry) are built against the old
    // config; the new one is live from here on either way, so drop them up
    // front, including on the failure path below, where the surviving bar
    // re-points at the NEW live config too.
    for (bar_mods) |m| {
        if (m.invalidateReloadCaches) |h| h();
    }
    const new_bar = createBar(height, barwin.calcBarYPos(height)) catch |err| {
        // The caller has already swapped cs.config to the new config and frees
        // the OLD config when this returns. The old bar survives this failed
        // reload, but its render.config borrows slices from that config; so
        // re-point it at the live new config before old_config.deinit() runs,
        // or the next draw reads freed memory.
        old.render.config = cs.config.bar;
        return err;
    };
    const new_state = new_bar.state;
    new_state.is_visible = old.is_visible;
    new_state.is_globally_visible = old.is_globally_visible;
    gBar.state = new_state;
    screen.setSurfaceWindow(new_bar.setup.win_id);
    syncScreenClaim();
    submitDrawBlockingFull();
    if (new_state.is_visible) _ = xcb.xcb_map_window(cs.conn, new_bar.setup.win_id);
    _ = xcb.xcb_destroy_window(cs.conn, old.win.win_id);
    ungrabAndFlush();
    old.render.dc.deinit();
    old.deinit();
}

// Public event handlers & queries

/// Builds the minimized-state service the title segment consumes, from the
/// window module registry's hide family (D12). The bar never names the addon;
/// it only forwards the registry's `isWindowHidden`/`collectHiddenSet` hooks
/// through the shared DrawCtx. All hooks null (no hide module compiled in) =>
/// the empty api, so the bar's synthesis loops no-op.
fn minimizedApiFromRegistry() segmod.MinimizedApi {
    var api: segmod.MinimizedApi = .{};
    if (@import("plugin").providerOf(window_mods[0..], .isWindowHidden) != null) api.is_minimized = minimizedIsHidden;
    if (@import("plugin").providerOf(window_mods[0..], .collectHiddenSet) != null) api.collect = minimizedCollect;
    return api;
}

/// Live per-window hidden query forwarded to the hide-family provider
/// (DrawCtx api signature, D12). `m` is the bar-passed model behind
/// `*const anyopaque` (type-free seam, D3).
fn minimizedIsHidden(m: *const anyopaque, win: u32) bool {
    const mm: *const model.Model = @ptrCast(@alignCast(m));
    if (@import("plugin").providerOf(window_mods[0..], .isWindowHidden)) |wm| return wm.isWindowHidden.?(mm, @intCast(win));
    return false;
}

/// Full hidden-set synthesis forwarded to the hide-family provider
/// (DrawCtx api signature, D12).
fn minimizedCollect(m: *const anyopaque, set: *std.AutoHashMapUnmanaged(u32, void), allocator: std.mem.Allocator) void {
    const mm: *const model.Model = @ptrCast(@alignCast(m));
    if (@import("plugin").providerOf(window_mods[0..], .collectHiddenSet)) |wm| wm.collectHiddenSet.?(mm, set, allocator);
}

/// Whether a window module (the fullscreen addon) claims the screen on `ws`
/// via the core model helper (coveringOccupantOnWs). Non-null means the bar
/// must hide to share the screen.
fn fullscreenScreenClaimer(ws: u8) ?u32 {
    return model.coveringOccupantOnWs(pipeline.model(), @intCast(ws));
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
    gBar.force = true;
    s.markDirty();
    s.clock_x = null;
    utils.grabServer(cs.conn);
    _ = xcb.xcb_configure_window(cs.conn, s.win.win_id, xcb.XCB_CONFIG_WINDOW_Y, &[_]u32{utils.toXcbCoord(new_y)});
    const current_ws = tracking.getCurrentWorkspace() orelse {
        window.updateWorkspaceBorders();
        window.markBordersFlushed();
        ungrabAndFlush();
        return;
    };
    const no_fullscreen = if (build_options.has_fullscreen) fullscreenScreenClaimer(current_ws) == null else true;
    // The bar's edge changed; update its claim so the reconcile below
    // re-derives every placement from the new usable area.
    syncScreenClaim();
    // The work area changed with the bar's new edge; one model reconcile
    // re-derives every placement from it.
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
    const px: u16 = if (s.is_visible) s.render.height else 0;
    screen.setClaim(screen.bar_id.?, edge, px);
}

/// Window id of the bar, or null before init(). Lets the boot-time
/// window adoption skip the WM's own window.
pub fn winId() ?u32 {
    return if (gBar.state) |s| s.win.win_id else null;
}

/// Synchronous bar update safe to call inside xcb_grab_server.
///
/// Phase 1 (inside grab): render to the off-screen pixmap; queueBlit does
/// cairo_surface_flush and ENQUEUES xcb_copy_area without flushing, so the
/// compositor sees no intermediate frame.
/// Phase 2: the caller's ungrabAndFlush() sends configure_window +
/// copy_area + ungrab in one flush, producing exactly one compositor frame.
///
/// Frames whose refresh would run blocking property round trips under this
/// grab are DEFERRED instead of rendered: every client stalls until the
/// replies arrive, and each reply's implicit flush tears the caller's queued
/// configure/map batch apart mid-operation, exactly what the grab exists to
/// prevent (see the O(N*N)-in-grab note in window.zig). Those frames fall
/// back to the coalesced post-batch redraw; cheap frames still render inline.
pub fn redrawInsideGrab() void {
    const s = gBar.state orelse return;
    if (!s.is_visible) return;
    if (gBar.force) {
        s.markDirty();
        return;
    }
    const focus_changed = s.focused_title_window != focus.getFocused();
    const frame_changed = s.scanLiveFrame();
    if (focus_changed or frame_changed) {
        if (focus_changed) s.markDirtySource(.focus);
        if (frame_changed) s.markDirtySource(.frame);
        return;
    }
    // Phase 1+2a: render to pixmap, queue the blit; sent with ungrabAndFlush().
    performDraw();
    s.is_dirty = false;
}

pub fn raiseBar() void {
    if (gBar.state) |s|
        _ = xcb.xcb_configure_window(s.win.conn, s.win.win_id, xcb.XCB_CONFIG_WINDOW_STACK_MODE, &[_]u32{xcb.XCB_STACK_MODE_ABOVE});
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
    if (!s.is_visible) {
        // The bar is hidden; draw fresh content into it before mapping
        // (same ordering setBarState's show path uses) so the compositor
        // never shows a blank or stale bar for a frame.
        gBar.prompt_forced_visible = true;
        s.is_visible = true;
        submitDrawBlockingFull();
        _ = xcb.xcb_map_window(s.win.conn, s.win.win_id);
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
    const no_fullscreen = if (build_options.has_fullscreen) fullscreenScreenClaimer(current_ws) == null else true;
    const should_show = no_fullscreen and s.is_globally_visible;
    if (should_show) return; // conditions changed while the prompt was open; stay visible
    s.is_visible = false;
    _ = xcb.xcb_unmap_window(s.win.conn, s.win.win_id);
    _ = xcb.xcb_flush(s.win.conn);
}

/// Sets the bar's user-level visibility state. Only the user toggle path
/// arrives here (keybind / config action). Fullscreen-driven hide/show is NOT
/// a named call: the bar derives it reactively from the core fullscreen fact
/// revision in `applyFullscreenVisibility`, so no subsystem pokes the bar.
pub fn setBarState(action: types.Action) void {
    const s = gBar.state orelse return;
    if (action == .toggle_bar_visibility) s.is_globally_visible = !s.is_globally_visible;
    applyFullscreenVisibility();
}

/// Pre-computes and applies the bar's visibility state for `ws` (X11
/// map/unmap + screen claim) WITHOUT triggering a reconcile. Used by the
/// workspace-switch path so the bar's screen claim (and thus the workarea
/// used by the FIRST reconcile on the new workspace) is correct from the
/// start, preventing the two-reconcile flicker caused by a deferred
/// visibility update. The reconcile comes from the caller's own switch
/// reconcile; the bar merely updates its occupancy state here.
pub fn updateBarVisibilityForWorkspace(ws: u8) void {
    const s = gBar.state orelse return;
    const bar_forced_hidden_by_fullscreen = if (build_options.has_fullscreen) fullscreenScreenClaimer(ws) != null else false;
    const should_be_visible = !bar_forced_hidden_by_fullscreen and s.is_globally_visible;
    if (s.is_visible == should_be_visible) return;
    s.is_visible = should_be_visible;
    if (should_be_visible) {
        gBar.skip_title_refetch = true;
        submitDrawBlockingFull();
    }
    const conn = core.getState().conn;
    if (should_be_visible) _ = xcb.xcb_map_window(conn, s.win.win_id) else _ = xcb.xcb_unmap_window(conn, s.win.win_id);
    // The bar's screen occupancy changed with its visibility; update the claim
    // so the caller's switch reconcile re-derives placement from the new area.
    syncScreenClaim();
    debug.info("Bar {s} for workspace {}", .{ if (should_be_visible) "shown" else "hidden", ws });
}

/// Reacts to a change in core's fullscreen-occupancy fact: recomputes whether
/// the bar must be hidden to share the screen with a fullscreen window on the
/// current workspace, then maps/unmaps and updates the screen claim. Core owns
/// the fact revision; the bar merely reads the model & screen facts it already
/// consumes. Calls `reconcileNow` after a visibility claim change because the
/// usable area geometry changed (a write-path side effect from a rendering
/// module: documented in the check-layers.sh allowlist).
pub fn applyFullscreenVisibility() void {
    const s = gBar.state orelse return;
    const current_ws = tracking.getCurrentWorkspace() orelse 0;
    const bar_forced_hidden_by_fullscreen = if (build_options.has_fullscreen) fullscreenScreenClaimer(current_ws) != null else false;
    const should_be_visible = !bar_forced_hidden_by_fullscreen and s.is_globally_visible;
    if (s.is_visible == should_be_visible) return;
    s.is_visible = should_be_visible;
    if (should_be_visible) {
        gBar.skip_title_refetch = true;
        submitDrawBlockingFull();
    }

    const conn = core.getState().conn;
    utils.grabServer(conn);
    if (should_be_visible) _ = xcb.xcb_map_window(conn, s.win.win_id) else _ = xcb.xcb_unmap_window(conn, s.win.win_id);
    // The bar's screen occupancy changed with its visibility; update the
    // claim so the reconcile below re-derives placement from the new area.
    syncScreenClaim();
    pipeline.reconcileNow();
    ungrabAndFlush();
    debug.info("Bar {s} due to fullscreen-occupancy fact change", .{if (should_be_visible) "shown" else "hidden"});
}

pub fn updateIfDirty() !void {
    const s = gBar.state orelse return;

    // Fullscreen-occupancy reaction runs even when the bar is currently hidden
    // (it may need to become visible again on fullscreen exit). Diff the core
    // fact revision; when changed, we recompute shared-screen visibility. Core
    // owns the fact; we react over a one-way signal rather than being poked.
    const fullscreen_rev = core.fullscreenRev();
    if (s.last_fullscreen_rev != fullscreen_rev) {
        s.last_fullscreen_rev = fullscreen_rev;
        applyFullscreenVisibility();
    }
    if (!s.is_visible) return;

    // Diff core's fact revisions against what we last drew. Core owns these
    // facts; we react over a one-way signal (revision counters) rather than
    // being poked by name. Layout changes force a full redraw (title-data
    // refetch); window/workspace changes repaint all segments; focus changes
    // cheaply mark only the title.
    if (s.last_focus_rev != core.focusRev()) s.markDirtySource(.focus);
    if (s.last_window_rev != core.windowRev()) s.markDirty();
    if (s.last_layout_rev != core.layoutRev()) {
        gBar.force = true;
        s.markDirty();
    }
    s.last_focus_rev = core.focusRev();
    s.last_window_rev = core.windowRev();
    s.last_layout_rev = core.layoutRev();

    // Fold any module redraw request into the force flag (as the poll
    // wakeup path does), then draw. Loop: a module may queue another request
    // while drawing (the variants segment collapses to zero width on a layout
    // switch and must re-lay the row in the SAME batch, before the
    // end-of-batch flush, so the gap closes seamlessly rather than waiting on
    // the next unrelated event). Each iteration clears the request it
    // consumed, so the loop terminates unless a module genuinely re-requests.
    while (true) {
        if (barModsConsumeRedrawRequest()) {
            gBar.force = true;
            s.is_dirty = true;
        }
        if (!s.is_dirty) break;
        s.is_dirty = false;
        submitDraw();
    }
}

/// Asks each module whether it queued a redraw request the bar should honour
/// (e.g. the prompt's blink-tick reactivity).
fn barModsConsumeRedrawRequest() bool {
    for (bar_mods) |m| {
        if (m.consumeRedrawRequest) |h| if (h()) return true;
    }
    return false;
}

/// Redraws just the clock segment when its on-screen content is stale
/// (second rolled over, or config reload changed the format). Cheap to call
/// on every event batch: it no-ops unless staleness is detected.
pub fn updateClock() bool {
    const s = gBar.state orelse return false;
    if (!s.is_visible) return false;
    if (self_ticking_role == null) return false;
    const fmt = cs_configClockFormat();
    var redraw_clock = false;
    for (bar_mods) |m| {
        if (m.secondsElapsed) |h| {
            if (h(fmt)) {
                redraw_clock = true;
                break;
            }
        }
    }
    if (!redraw_clock) return false;
    s.drawClockOnly();
    return true;
}

fn cs_configClockFormat() []const u8 {
    const cs = core.getState();
    return cs.config.bar.clock_format orelse types.default_clock_format;
}

pub fn handleExpose(event: *const xcb.xcb_expose_event_t) void {
    if (gBar.state) |s| if (event.window == s.win.win_id and event.count == 0) {
        gBar.force = true;
        const dragging = if (build_options.has_floating) actions.isDragging() else false;
        if (dragging) {
            s.is_dirty = true;
            s.markAllSegmentsDirty();
        } else submitDraw();
    };
}

pub fn handlePropertyNotify(event: *const xcb.xcb_property_notify_event_t) void {
    const s = gBar.state orelse return;
    const focused_win = focus.getFocused() orelse return;
    if (event.window != focused_win) return;
    const net_wm_name = s.win.net_wm_name_atom;
    if (event.atom == xcb.XCB_ATOM_WM_NAME or (net_wm_name != 0 and event.atom == net_wm_name)) {
        // Renamed focused window: force the title data refetch on the next
        // draw (the fetch key alone wouldn't notice a text-only change).
        gBar.force = true;
        s.markDirtySource(.focus);
    }
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
pub fn handleButtonPress(event: *const xcb.xcb_button_press_event_t) void {
    const s = gBar.state orelse return;
    if (!s.is_visible) return;
    if (event.event_x < 0) return;
    const x: u16 = @intCast(event.event_x);

    const left = event.detail == constants.mouse_button_left;
    const right = event.detail == constants.mouse_button_right;
    if (!left and !right) return;

    const h = for (s.bounds[0..s.bounds_len]) |b| {
        if (b.contains(x)) break b;
    } else return;
    if (comptime registry_empty) return;
    const id = segId(h.name) orelse return;
    if (bar_mods[id].onClick == null) return;
    _ = bar_mods[id].onClick.?(x - h.x, left, right, s, titleClickTrampoline, redrawInsideGrab);
}

/// `offset` is the click position relative to the title segment's start.
/// Resolves which window is under the click via the title scratch data
/// (populated by the last draw; hitTest makes no X11 round-trips when the
/// prefetched lists cover the window set), then:
///   - no window under the click -> no-op (empty title is handled by the
///     right-click prompt path in `handleButtonPress`, before this is called)
///   - the window is minimized -> unminimizes that window
///   - the window is already focused -> minimizes it
///   - otherwise -> focuses it
fn handleTitleClick(s: *State, offset: u16) void {
    if (s.wins_len == 0) return;
    if (comptime registry_empty) return;
    const center_id = center_slot_role orelse return;
    const tb = s.recordedBound(bar_mods[center_id].name) orelse return;

    const target = (segmod.hitTest(s.titleCtx(tb.x, tb.w), s.titleSnapshot(), s.render.allocator, offset) catch |e| {
        debug.warnOnErr(e, "bar title click hitTest");
        return;
    }) orelse return;

    // `target.minimized` comes from the title snapshot's minimized set, which
    // the title addon synthesizes fresh (D12); bar.zig never names minimize.
    if (target.minimized) {
        actions.restore(target.window);
    } else if (focus.getFocused() == target.window) {
        actions.minimize(target.window);
    } else {
        focus.grabFocus(target.window, .mouse_click);
    }
}

fn titleClickTrampoline(ptr: *anyopaque, offset: u16) void {
    const s: *State = @ptrCast(@alignCast(ptr));
    handleTitleClick(s, offset);
}

/// Comptime-registered UI-surface hooks for core's event loop (comptime
/// reference point: the one place the loop knows the bar exists). Core calls
/// these through a single `plugins.Surfaces` alias; when the bar is absent the
/// whole set is `null` and every such call site compiles away. The emitter
/// lives in this module, so detaching the bar detaches its handlers. The hook
/// types themselves live in the core-owned `plugin` interface contract, not
/// here: this module only binds its functions to that contract.
pub const surfaces = @import("plugin").Surfaces{
    .init = init,
    .deinit = deinit,
    .handleExpose = handleExpose,
    .handlePropertyNotify = handlePropertyNotify,
    .updateIfDirty = updateIfDirty,
    .pollTimeoutMs = pollTimeoutMs,
    .onPollWakeup = onPollWakeup,
    .updateClock = updateClock,
    .onReload = reload,
    .chromeHandleKeypress = chromeHandleKeypress,
    .isBarWindow = isBarWindow,
    .handleButtonPress = handleButtonPress,
    .setBarState = setBarState,
    .updateBarVisibilityForWorkspace = updateBarVisibilityForWorkspace,
    .toggleBarSegmentAnchor = toggleBarSegmentAnchor,
    .chromeToggleOverlay = chromeToggleOverlay,
};
