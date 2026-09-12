//! Status bar
//! Creates and manages the WM status bar, rendering all configured segments.
//!
//! Rendering uses per-segment dirty tracking: the dirty set is registry-sized
//! (one bool per bar_modules entry); only dirty segments are repainted on
//! each draw. The global force flag or a full dirty set triggers a complete
//! background clear + repaint. Coalescing happens through the dirty-mark
//! scheduling (scheduleRedraw & friends).
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
const segmod = @import("segment");
const barwin = @import("win");

// Bar visibility subsystem (pure decisions only; bar.zig keeps the wire glue).
const visibility = @import("visibility");

// Window-addon registry (generated): the fullscreen-hide decision is routed
// through the isWindowHidden/collectHiddenSet seams instead of naming the
// minimize or fullscreen module directly.
const window_mods = @import("window_modules").modules;

// Registry-resolved segment identity (comptime): the bar locates modules by
// name through the generated registry instead of importing them directly.
// Role/named lookups return null on an absent (even empty) registry, so the
// bar still compiles and no-ops when ALL segments are removed.
const bar_mods = @import("bar_modules").modules;

const self_ticking_role: ?usize = segmod.findByCapability(&bar_mods, "self_ticking");
const center_slot_role: ?usize = segmod.findByCapability(&bar_mods, "center_slot");

/// Registry index for `name`, or null when absent (also when the registry is
/// empty: `bar_mods` is then a zero-length slice and idByName finds nothing,
/// so the empty-registry case needs no separate comptime guard at call sites).
inline fn segId(name: []const u8) ?usize {
    return segmod.idByName(&bar_mods, name);
}

/// True when `name` resolves to the segment claiming the registry role `role`
/// (name-free; roles are the self-ticking clock and the reserved center
/// slot/title capabilities today).
fn isRole(name: []const u8, comptime role: ?usize) bool {
    const id = segId(name) orelse return false;
    return role != null and id == role.?;
}

fn runVoidHook(comptime hook: []const u8) void {
    inline for (bar_mods) |m| if (@field(m, hook)) |h| h();
}

fn anyBoolHook(comptime hook: []const u8, args: anytype) bool {
    inline for (bar_mods) |m| if (@field(m, hook)) |h| if (@call(.auto, h, args)) return true;
    return false;
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

fn probeMetrics(size_override: ?u16) ?struct { asc: i32, desc: i32 } {
    const cs = core.getState();
    const sized = drawing.buildSizedFontList(cs.alloc, size_override) catch return null;
    defer drawing.freeSizedFontList(cs.alloc, sized);
    const m = drawing.probeFontMetrics(
        cs.alloc,
        core.dpi_info.load(.acquire),
        sized,
    ) orelse return null;
    return .{ .asc = m.ascent, .desc = m.descent };
}

fn resolvePercentageFontSize(bar_height: u16) ?u16 {
    // Probe metrics at a trial point size via the override parameter, so
    // there is no save/mutate/restore round on cs.config.
    const trial_pt: u16 = 100;
    const cs = core.getState();
    const m = probeMetrics(trial_pt) orelse return null;
    const px_per_pt: f32 = @as(f32, @floatFromInt(@max(1, m.asc + m.desc))) /
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
    const m = probeMetrics(null) orelse return default_bar_height;
    return @intCast(std.math.clamp(
        @max(1, m.asc + m.desc),
        @as(i32, @intCast(min_bar_height)),
        @as(i32, @intCast(max_bar_height)),
    ));
}

// ---------------------------------------------------------------------------

/// Uniform poll wakeup: runs every module's onPollWakeup hook (prompt caret
/// blink, marquee repaint-marking, ...) then submits a draw. The bar never
/// names a segment.
pub fn onPollWakeup() void {
    runVoidHook("onPollWakeup");
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
    return anyBoolHook("handleKeypress", .{ event, matched });
}

/// Toggles the chrome overlay. Routed through the resolved title module's
/// onClick hook (right-click path): the overlay lives in the title module
/// and the bar must not name it.
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
    /// Forces the next draw to repaint every segment (full background clear)
    /// even when the change-detection keys say nothing changed. Set by
    /// expose/reload/show paths; normal ticks just redraw from live state.
    /// Consumed by every draw.
    force: bool = false,
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

/// Cap on updateIfDirty's re-request redraw loop: a module that keeps
/// re-requesting a full redraw past this many iterations is treated as a
/// stall (logged), keeping a rogue module from busy-spinning the batch.
const max_update_draws: u8 = 4;

/// Right-aligned cluster bookkeeping for one draw frame. Measures every
/// right-position segment once up front, deriving both the reserved width
/// (which left/center placement shrinks around) and the per-segment widths
/// the draw consumes. Falls back to measure-at-draw when the segment count
/// overflows `max_right_segments` (`take` then reports null).
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

    /// Measures all right segments across the bar's layouts.
    fn measure(self: *RightCluster, s: *State, frame: *const segmod.Frame, scaled_spacing: u16) void {
        // Accumulate the reservation in u32 (segment widths + gaps could push
        // past u16 on a very wide desktop) and clamp into the u16 field.
        var total: u32 = 0;
        for (s.render.config.layout.items) |lay| {
            if (lay.position != .right) continue;
            for (lay.segments.items) |seg| {
                const w = s.measureSegmentWidth(frame, seg);
                if (self.count < max_right_segments) self.widths[self.count] = w;
                self.count += 1;
                total += @as(u32, w) + scaled_spacing;
            }
            if (lay.segments.items.len > 0) total -= scaled_spacing;
        }
        self.total = @intCast(@min(total, std.math.maxInt(u16)));
    }

    /// Slices out the measured widths for one right layout's segments,
    /// advancing the internal index. Returns null when the measurement buffer
    /// overflowed, signalling the draw to re-measure per segment.
    fn take(self: *RightCluster, segments: []const []const u8) ?[]const u16 {
        const start = self.ridx;
        self.ridx += segments.len;
        if (self.count > max_right_segments) return null;
        return self.widths[start..][0..segments.len];
    }
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

/// All live bar state. The title-window scratch below is rebuilt every frame
/// from in-process caches (no X11, nothing to refetch); every other field is
/// recomputed per frame.
///
/// State is plain data owned by this file alone: the poll-driven loop reads
/// and mutates it directly, and segments receive only per-segment sub-views
/// (via the DrawCtx), never State itself.
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
    /// Width of the current draw's dirty span. 0 means "whole bar".
    span_w: u16 = 0,
};

const Clock = struct {
    /// Reserved width of the clock segment (measure string + padding).
    width: u16 = 0,
    /// Left edge of the clock from the last layout pass; enables the
    /// region-scoped clock blit in drawClockOnly.
    x: ?u16 = null,
};

const Clicks = struct {
    /// Click bounds recorded by the last layout pass, in record order.
    bounds: [max_click_bounds]SegBound = undefined,
    len: usize = 0,
};

/// Live frame state (recollected on every draw; see scanLiveFrame).
const FrameState = struct {
    ws_count: u32 = 0,
    current_ws: u8 = 0,
    all_view: bool = false,
    ws_has_windows: [constants.max_workspaces]bool = @splat(false),
    wins: [max_frame_windows]u32 = undefined,
    wins_len: usize = 0,
    /// Per-frame title rendering context from the last draw, reused for
    /// post-draw click hit-testing (backing buffers are stable for the rest
    /// of the event-loop batch: they live on State, and nothing reallocates
    /// them between draws).
    last_ctx: segmod.DrawCtx = undefined,
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

const State = struct {
    win: WindowCtx,
    render: RenderCtx,

    vis: Visibility = .{},
    dirty: Dirty = .{},
    clock: Clock = .{},
    clicks: Clicks = .{},
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
        runVoidHook("invalidate");
        return s;
    }

    fn deinit(self: *State) void {
        self.win.deinit();
        const alloc = self.render.allocator;
        self.title_data.minimized.deinit(alloc);
        alloc.destroy(self);
    }

    fn markDirty(self: *State) void {
        self.dirty.flag = true;
        self.markAllSegmentsDirty();
    }

    fn clearSegmentDirty(self: *State, name: []const u8) void {
        if (segId(name)) |id| self.dirty.segments[id] = false;
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
        if (self.dirty.segments[id]) return true;
        if (bar_mods[id].needsRepaint) |q| return q();
        return false;
    }

    fn markAllSegmentsDirty(self: *State) void {
        @memset(&self.dirty.segments, true);
    }

    /// True when every registry slot is dirty (the complete-background-clear
    /// trigger). Non-configured segments (e.g. the prompt overlay) are never
    /// drawn and never cleared, so an all-dirty set only occurs on force.
    fn isFullDirty(self: *const State) bool {
        for (self.dirty.segments) |d| {
            if (!d) return false;
        }
        return true;
    }

    /// True when the next draw would repaint at least one layout-rendered
    /// segment: a dirty flag or a live needsRepaint hook (the title marquee).
    /// Iterates only segments that actually render — the overlay-only prompt
    /// slot's dirty flag is never cleared, so a registry-wide scan would
    /// always report work and defeat the P2 draw early-exit.
    fn hasPendingRepaintWork(self: *const State) bool {
        for (self.render.config.layout.items) |lay| {
            for (lay.segments.items) |seg| {
                if (self.isSegmentRepaintable(seg)) return true;
            }
        }
        return false;
    }

    /// Records the on-screen bounds of a clickable segment as the layout pass
    /// positions it, so handleButtonPress can hit-test against them without
    /// redoing the layout. Called unconditionally for every segment; segments
    /// whose module declares `clickable == false` (the clock) are skipped.
    fn recordClickBound(self: *State, name: []const u8, x: u16, w: u16) void {
        const id = segId(name) orelse return;
        if (!bar_mods[id].clickable) return;
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
        if (bar_mods[id].naturalWidth) |nw| return nw(frame, self.clock.width);
        return 0;
    }

    /// Fills the shared per-frame DrawCtx the bar hands to every segment's
    /// draw hook, including the title snapshot slots.
    fn fillDrawCtx(self: *State, ctx: *segmod.DrawCtx) void {
        ctx.frame = .{
            .workspace_count = self.frame.ws_count,
            .current_workspace = self.frame.current_ws,
            .is_all_view_active = self.frame.all_view,
            .workspace_has_windows = self.frame.ws_has_windows[0..self.frame.ws_count],
        };
        // The minimized-state service is drawn from the window module registry
        // here (upfront, per frame) so the title segment need not name the
        // addon that owns it. All hooks null => empty api => scanLiveFrame
        // no-ops, matching prior boot ordering.
        ctx.minimized_api = minimizedApiFromRegistry();
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
            self.frame.ws_count = @intCast(tracking.getWorkspaceCount());
            self.frame.current_ws = @intCast(m.current);
            self.frame.all_view = m.all_view_active;
            @memset(&self.frame.ws_has_windows, false);
            self.frame.wins_len = 0;
            const cur_bit: u64 = if (self.frame.current_ws < self.frame.ws_count)
                tracking.workspaceBit(self.frame.current_ws)
            else
                0;
            // OR-accumulate all window masks in a single pass, collecting the
            // current workspace's windows on the way.
            var combined_mask: u64 = 0;
            for (tracking.allWindows()) |entry| {
                combined_mask |= entry.mask;
                if (cur_bit != 0 and entry.mask & cur_bit != 0 and
                    self.frame.wins_len < max_frame_windows)
                {
                    self.frame.wins[self.frame.wins_len] = entry.win;
                    self.frame.wins_len += 1;
                }
            }
            for (0..self.frame.ws_count) |i| {
                self.frame.ws_has_windows[i] = combined_mask &
                    tracking.workspaceBit(@as(u8, @intCast(i))) != 0;
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

    /// Draws a segment by registry dispatch, catching and logging errors
    /// instead of propagating them. On failure returns `x` unchanged (the
    /// "drew nothing" signal) so a broken segment can't corrupt the layout.
    fn drawSegmentSafe(
        self: *State,
        ctx: *segmod.DrawCtx,
        name: []const u8,
        x: u16,
        width: ?u16,
    ) u16 {
        return self.drawSegment(ctx, name, x, width) catch |e| {
            debug.warnOnErr(e, "bar drawSegment");
            return x;
        };
    }

    fn drawSegment(self: *State, ctx: *segmod.DrawCtx, name: []const u8, x: u16, width: ?u16) !u16 {
        const id = segId(name) orelse return error.DrewInvalidSegment;
        if (bar_mods[id].draw == null) return error.DrewInvalidSegment;
        // The DrawCtx is shared mutable scratch: pin the reserved width into it
        // immediately before the draw so width-reading renderers (the title)
        // advance correctly.
        ctx.width = width orelse self.measureSegmentWidth(&ctx.frame, name);
        return bar_mods[id].draw.?(ctx, x);
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
        const drew_x = self.drawSegmentSafe(ctx, name, x, w);
        const drew = drew_x != x_before;
        if (!omit_gap) {
            // On success advance past the drawn text plus the trailing gap.
            if (drew) {
                self.paintGap(drew_x, scaled_spacing);
                return advancedX(drew_x, x_before, w, scaled_spacing);
            }
            // On failure drawSegmentSafe returns x unchanged ("drew nothing").
            // Still consume the full reserved slot + gap so the NEXT segment
            // leftward starts where the layout pass expects; returning the
            // unchanged x would let that segment paint over this failed slot
            // (and, on the follow-up frame, desync the whole cluster). Matches
            // drawRightSegments' failed-draw handling.
            return advancedX(drew_x, x_before, w, scaled_spacing);
        }
        return drew_x;
    }

    /// Slot + trailing-gap accounting for a draw that may have failed: on
    /// success the row advances past `drew_x` plus `gap`; on failure
    /// `drawSegmentSafe` returned `x_before` unchanged, so the full reserved
    /// `w` + gap is still consumed (see the failure comments in both draw
    /// paths). Shared by drawRowSegment and drawRightSegments.
    inline fn advancedX(drew_x: u16, x_before: u16, w: u16, gap: u16) u16 {
        return if (drew_x != x_before) drew_x + gap else x_before + w + gap;
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
            // Saturating subtraction: a pathological width sum must clamp at 0,
            // not underflow into a wrap-around rightward paint.
            right_x = right_x -| seg_w;
            if (pending_gap) right_x = right_x -| scaled_spacing;

            if (isRole(names[i], self_ticking_role)) self.clock.x = right_x;
            self.recordClickBound(names[i], right_x, seg_w);

            if (self.isSegmentRepaintable(names[i])) {
                if (!is_full_redraw) {
                    self.clearRegion(right_x, seg_w);
                }
                const drew = self.drawSegmentSafe(ctx, names[i], right_x, null) != right_x;
                if (drew) {
                    self.extendDirtySpan(right_x, seg_w);
                    if (pending_gap) {
                        self.extendDirtySpan(right_x + seg_w, scaled_spacing);
                        self.paintGap(right_x + seg_w, scaled_spacing);
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
        self.dirty.span_x = 0;
        self.dirty.span_w = 0;

        if (is_full_redraw) {
            self.clearRegion(0, r.width);
        }

        var right = RightCluster{};
        right.measure(self, frame, scaled_spacing);

        self.clicks.len = 0;
        var x: u16 = 0;
        for (r.config.layout.items) |lay| {
            switch (lay.position) {
                .left, .center => {
                    // Available horizontal space before the right cluster.
                    const avail = r.width -| x -| right.total;
                    const remaining = if (lay.position == .center)
                        // Clamp to available space so a tight right+left row
                        // can't overflow into the right-segment area.
                        @min(
                            @max(segmod.title_min_width, avail -| scaled_spacing),
                            avail,
                        )
                    else
                        0;
                    for (lay.segments.items) |seg| {
                        const is_center = isRole(seg, center_slot_role);
                        const omit_gap = (lay.position == .center) and is_center;
                        const w = if (is_center)
                            remaining
                        else
                            self.measureSegmentWidth(frame, seg);
                        self.recordClickBound(seg, x, w);
                        // clock.x must be recorded for a self-ticking segment
                        // in ANY cluster (not just right): drawClockOnly relies
                        // on it regardless of where the clock is laid out.
                        if (isRole(seg, self_ticking_role)) self.clock.x = x;
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
                    }
                },
                .right => {
                    self.drawRightSegments(ctx, lay.segments.items, right.take(lay.segments.items), is_full_redraw);
                },
            }
        }
    }

    /// Redraws just the clock segment when its on-screen content is stale
    /// (second rolled over). Cheap region-scoped blit.
    fn drawClockOnly(self: *State) void {
        const clock_x = self.clock.x orelse return;
        const cid = self_ticking_role orelse return;
        if (bar_mods[cid].draw == null) return;
        var ctx = frameCtx(self);
        // Shared harness: catches/logs draw errors; returns x unchanged
        // ("drew nothing") on failure, which must skip the blit below.
        const drawn_end = self.drawSegmentSafe(&ctx, bar_mods[cid].name, clock_x, null);
        if (drawn_end == clock_x) return;
        // Region-scoped blit: copies only the clock region and flushes (this
        // is a timer-driven path; no event-loop flush is coming). Blit at
        // least what was PAINTED (drawn_end can exceed the layout-time
        // reservation after font fallback or digit-width drift: blitting
        // only the cached width would clip digits) while keeping the full
        // reserved slot covered so stale pixels from a wider earlier frame
        // still get overwritten with the clean background the last full
        // frame left.
        const drawn_w: u16 = drawn_end -| clock_x;
        self.render.dc.blitRegion(clock_x, @max(self.clock.width, drawn_w));
        self.clearSegmentDirty(bar_mods[cid].name);
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
    // Fold any queued module redraw request into the force flag (the same
    // gate the poll-wakeup and X-batch paths use) so a direct submitDraw can
    // never drop it; the onPollWakeup / updateIfDirty callers have typically
    // already consumed, in which case this is a false no-op.
    if (!gBar.force and barModsConsumeRedrawRequest()) gBar.force = true;
    // P2: a timer-only wake with zero repaint work (nothing forced, nothing
    // whole-bar dirty, no segment dirty or needsRepaint) must not run the full
    // scan + measure pass. The clock's own repaint on the same wake is handled
    // separately by the region-scoped updateClock blit.
    if (!gBar.force and !s.dirty.flag and !s.hasPendingRepaintWork()) return;
    if (gBar.force) s.markAllSegmentsDirty();
    s.scanLiveFrame();

    // Titles/geoms are read from in-process caches (wincache + sync
    // truth-rect) with no X11 round-trip, so every frame renders inline:
    // there is no async prefetch to fire, defer, or commit.
    var ctx = frameCtx(s);
    s.fillDrawCtx(&ctx);
    s.drawAllInner(&ctx);
    // Cache the minimized-state service (built by fillDrawCtx from the window
    // module registry) so scanLiveFrame can synthesize the set each frame
    // Guarded so an empty api still leaves the prior snapshot intact.
    if (ctx.minimized_api.is_minimized != null) s.title_data.minimized_api = ctx.minimized_api;
    s.frame.last_ctx = ctx;
    // Only enqueue the dirty span: drawAllInner tracks the bounding x/w of
    // every repainted segment; skip the XCopyArea entirely when nothing
    // changed. No flush here (queueBlit), matching the grab-path contract.
    if (s.dirty.span_w > 0)
        s.render.dc.queueBlit(s.dirty.span_x, s.dirty.span_w);
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

/// Forces the next draw to repaint every segment and mark the whole bar dirty.
/// Used by paths that need a full background-clear repaint (layout facts,
/// module redraw requests, bar re-anchoring).
fn requestFullRedraw() void {
    gBar.force = true;
    if (gBar.state) |s| s.dirty.flag = true;
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
    runVoidHook("invalidateReloadCaches");
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

/// Builds the minimized-state service the title segment consumes, from the
/// window module registry's hide family. The bar never names the addon;
/// it only forwards the registry's `isWindowHidden`/`collectHiddenSet` hooks
/// through the shared DrawCtx. All hooks null (no hide module compiled in) =>
/// the empty api, so the bar's synthesis loops no-op.
fn minimizedApiFromRegistry() segmod.MinimizedApi {
    var api: segmod.MinimizedApi = .{};
    if (@import("plugin").providerOf(window_mods[0..], .isWindowHidden) != null)
        api.is_minimized = minimizedIsHidden;
    if (@import("plugin").providerOf(window_mods[0..], .collectHiddenSet) != null)
        api.collect = minimizedCollect;
    return api;
}

/// Live per-window hidden query forwarded to the hide-family provider
/// (DrawCtx api signature). `m` is the bar-passed model behind
/// `*const anyopaque` (type-free seam).
fn minimizedIsHidden(m: *const anyopaque, win: u32) bool {
    const mm: *const model.Model = @ptrCast(@alignCast(m));
    if (@import("plugin").providerOf(window_mods[0..], .isWindowHidden)) |wm|
        return wm.isWindowHidden.?(mm, @intCast(win));
    return false;
}

/// Full hidden-set synthesis forwarded to the hide-family provider
/// (DrawCtx api signature).
fn minimizedCollect(
    m: *const anyopaque,
    set: *std.AutoHashMapUnmanaged(u32, void),
    allocator: std.mem.Allocator,
) void {
    const mm: *const model.Model = @ptrCast(@alignCast(m));
    if (@import("plugin").providerOf(window_mods[0..], .collectHiddenSet)) |wm|
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
    s.clock.x = null;
    utils.grabServer(cs.conn);
    _ = xcb.xcb_configure_window(
        cs.conn,
        s.win.win_id,
        xcb.XCB_CONFIG_WINDOW_Y,
        &[_]u32{utils.toXcbCoord(new_y)},
    );
    const current_ws = tracking.getCurrentWorkspace() orelse {
        window.updateWorkspaceBorders();
        window.markBordersFlushed();
        ungrabAndFlush();
        return;
    };
    const no_fullscreen = !visibility.barForcedHiddenByFullscreen(current_ws);
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
    const px: u16 = if (s.vis.shown) s.render.height else 0;
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
/// Title data is sourced from in-process caches (wincache + sync truth-rect),
/// so no frame blocks or defers under the grab: a click-triggered redraw here
/// is as cheap as any other frame.
pub fn redrawInsideGrab() void {
    const s = gBar.state orelse return;
    if (!s.vis.shown) return;
    if (gBar.force) {
        s.markDirty();
        return;
    }
    performDraw();
    s.dirty.flag = false;
}

pub fn raiseBar() void {
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
        // The bar is hidden; draw fresh content into it before mapping
        // (same ordering setBarState's show path uses) so the compositor
        // never shows a blank or stale bar for a frame.
        gBar.prompt_forced_visible = true;
        s.vis.shown = true;
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
/// by the workspace-switch path whose caller runs its own reconcile.
fn applyVisibility(s: *State, should_be_visible: bool, do_reconcile: bool) void {
    s.vis.shown = should_be_visible;
    if (should_be_visible) {
        submitDrawBlockingFull();
    }
    const conn = core.getState().conn;
    if (do_reconcile) utils.grabServer(conn);
    _ = if (should_be_visible) xcb.xcb_map_window(conn, s.win.win_id) else xcb.xcb_unmap_window(conn, s.win.win_id);
    syncScreenClaim();
    if (do_reconcile) {
        pipeline.reconcileNow();
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
    const s = gBar.state orelse return;
    const decision = visibility.desiredVisibility(ws, s.vis.shown, s.vis.preferred);
    if (!decision.needs_change) return;
    applyVisibility(s, decision.should_be_visible, false);
    debug.info("Bar {s} for workspace {}", .{ if (decision.should_be_visible) "shown" else "hidden", ws });
}

/// Immediately unmaps the bar and updates the screen claim, without a
/// separate reconcile. Called from the fullscreen-enter grab so the bar
/// disappears atomically with the fullscreen geometry. No-ops when the bar
/// is already hidden or not initialised.
pub fn hideBarForFullscreen() void {
    const s = gBar.state orelse return;
    if (!s.vis.shown) return;
    s.vis.shown = false;
    const conn = core.getState().conn;
    _ = xcb.xcb_unmap_window(conn, s.win.win_id);
    syncScreenClaim();
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
    const decision = visibility.desiredVisibility(current_ws, s.vis.shown, s.vis.preferred);
    if (!decision.needs_change) return;
    applyVisibility(s, decision.should_be_visible, true);
    debug.info(
        "Bar {s} due to fullscreen-occupancy fact change",
        .{if (decision.should_be_visible) "shown" else "hidden"},
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
    // changes cheaply mark only the title.
    if (s.facts.focus_rev != core.focus.rev()) s.markDirtySource(.focus);
    if (s.facts.window_rev != core.window.rev()) s.markDirty();
    if (s.facts.layout_rev != core.layout.rev()) {
        requestFullRedraw();
    }
    s.facts.focus_rev = core.focus.rev();
    s.facts.window_rev = core.window.rev();
    s.facts.layout_rev = core.layout.rev();

    // Fold any module redraw request into the force flag (as the poll
    // wakeup path does), then draw. Loop: a module may queue another request
    // while drawing (the variants segment collapses to zero width on a layout
    // switch and must re-lay the row in the SAME batch, before the
    // end-of-batch flush, so the gap closes seamlessly rather than waiting on
    // the next unrelated event). Each iteration clears the request it
    // consumed, so the loop terminates unless a module genuinely re-requests.
    // Cap the iterations so a misbehaving module that re-requests forever
    // can't busy-spin this batch.
    var redraw_iter: u8 = 0;
    while (redraw_iter < max_update_draws) : (redraw_iter += 1) {
        if (barModsConsumeRedrawRequest()) {
            requestFullRedraw();
        }
        if (!s.dirty.flag) break;
        s.dirty.flag = false;
        submitDraw();
    }
    if (redraw_iter == max_update_draws)
        debug.info("bar: updateIfDirty redraw loop hit its iteration cap, stalling re-request", .{});
}

/// Asks each module whether it queued a redraw request the bar should honour
/// (e.g. the prompt's blink-tick reactivity).
fn barModsConsumeRedrawRequest() bool {
    return anyBoolHook("consumeRedrawRequest", .{});
}

/// Redraws just the clock segment when its on-screen content is stale
/// (second rolled over, or config reload changed the format). Cheap to call
/// on every event batch: it no-ops unless staleness is detected.
pub fn updateClock() bool {
    const s = gBar.state orelse return false;
    if (!s.vis.shown) return false;
    if (self_ticking_role == null) return false;
    const fmt = drawing.clockFormat(core.getState().config.bar);
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

pub fn handleExpose(event: *const xcb.xcb_expose_event_t) void {
    if (gBar.state) |s| if (event.window == s.win.win_id and event.count == 0) {
        if (build_options.has_floating and actions.isDragging()) s.dirty.flag = true else submitDraw();
    };
}

/// Property-notify on the bar surface needs no title handling: title changes
/// are refreshed by the WM window layer (window.handlePropertyNotify), which
/// bumps the window fact so the next updateIfDirty pass repaints. Kept as a
/// slot-filling no-op for the surfaces contract; all other property-notifies
/// are already ignored by the bar.
pub fn handlePropertyNotify(_: *const xcb.xcb_property_notify_event_t) void {}

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
    if (!s.vis.shown) return;
    if (event.event_x < 0) return;
    const x: u16 = @intCast(event.event_x);

    const left = event.detail == constants.mouse_button_left;
    const right = event.detail == constants.mouse_button_right;
    if (!left and !right) return;

    const h = for (s.clicks.bounds[0..s.clicks.len]) |b| {
        if (b.contains(x)) break b;
    } else return;
    const id = segId(h.name) orelse return;
    if (bar_mods[id].onClick == null) return;
    _ = bar_mods[id].onClick.?(x - h.x, left, right, s, titleClickTrampoline, redrawInsideGrab);
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
    const center_id = center_slot_role orelse return;
    const tb = s.recordedBound(bar_mods[center_id].name) orelse return;

    const target = (segmod.hitTest(
        s.frame.last_ctx.titleRenderContext(tb.x, tb.w),
        s.frame.last_ctx.titleSnapshot(),
        offset,
    ) catch |e| {
        debug.warnOnErr(e, "bar title click hitTest");
        return;
    }) orelse return;

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
    .hideBarForFullscreen = hideBarForFullscreen,
    .updateBarVisibilityForWorkspace = updateBarVisibilityForWorkspace,
    .toggleBarSegmentAnchor = toggleBarSegmentAnchor,
    .chromeToggleOverlay = chromeToggleOverlay,
};
