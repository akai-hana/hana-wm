//! Status bar
//! Creates and manages the WM status bar, rendering all configured segments.
//!
//! Rendering uses per-segment dirty tracking: each segment has a dirty bit
//! in State.segment_dirty; only dirty segments are repainted on each draw.
//! The global force flag or a full dirty set triggers a complete background
//! clear + repaint. Coalescing happens through the dirty-mark scheduling
//! (scheduleRedraw & friends).

const std = @import("std");
const build_options = @import("build_options");

const core = @import("core");
const xcb = core.xcb;
const utils = @import("utils");
const refresh_rate = @import("refresh_rate");
const scale = @import("scale");
const constants = @import("constants");
const debug = @import("debug");

const types = @import("types");

const tracking = @import("tracking");
const focus = @import("focus");
const minimize = if (build_options.has_minimize) @import("minimize") else null;
const pipeline = @import("pipeline"); // PIPELINE: train a
const actions = @import("actions"); // PIPELINE: train a
const model = @import("model");
const workspaces = if (build_options.has_workspaces) @import("workspaces") else null;

const window = @import("window");

const drawing = @import("drawing");
const prompt = if (build_options.has_seg_prompt) @import("prompt") else struct {
    pub fn blinkTick() void {}
    pub fn blinkPollTimeoutMs() i32 {
        return std.math.maxInt(i32);
    }
    pub fn handlePromptKeypress(_: anytype, _: anytype) bool {
        return false;
    }
    pub fn toggle() void {}
    pub fn init(_: anytype, _: anytype) !void {}
    pub fn deinit() void {}
    pub fn invalidateReloadCaches() void {}
    pub fn consumeRedrawRequest() bool {
        return false;
    }
    pub fn draw(_: anytype, _: anytype, _: anytype, _: anytype) !u16 {
        return 0;
    }
    pub fn isActive() bool {
        return false;
    }
};
const vim = if (build_options.has_vim) @import("vim") else struct {};
const segmod = @import("segment");
const barwin = @import("win");
const tags = if (build_options.has_seg_tags) @import("tags") else struct {
    pub fn invalidate() void {}
};

const clock = if (build_options.has_seg_clock) @import("clock") else struct {
    pub const clock_measure_string = "";
    pub fn tickDeadlineMs() i32 {
        return std.math.maxInt(i32);
    }
    pub fn draw(_: anytype, _: anytype, _: anytype, x: u16) !u16 {
        return x;
    }
    pub fn secondElapsed(_: anytype) bool {
        return false;
    }
};
const title = if (build_options.has_seg_title) @import("title") else struct {
    const u = @import("utils");
    const t = @import("types");
    const d = @import("drawing");
    const c = @import("core");
    pub const min_width: u16 = 0;
    pub const offscreen_rect: u.Rect = .{ .x = std.math.maxInt(i16), .y = std.math.maxInt(i16), .width = 0, .height = 0 };
    pub const TitleRenderContext = struct {
        dc: *d.DrawContext,
        config: t.BarConfig,
        height: u16,
        start_x: u16,
        width: u16,
        conn: c.Connection,
    };
    pub const TitleSnapshot = struct {
        focused_window: ?u32,
        focused_title: []const u8,
        minimized_title: []const u8,
        current_ws_wins: []const u32,
        minimized_set: *const std.AutoHashMapUnmanaged(u32, void),
        titles: []const []const u8 = &.{},
        geoms: []const ?u.Rect = &.{},
    };
    pub const ClickTarget = struct { window: u32, minimized: bool };
    pub fn fetchWindowTitleInto(_: anytype, _: anytype, _: anytype, _: anytype) !void {}
    pub fn fetchTitlesAndGeoms(_: anytype, _: anytype, _: anytype, _: anytype, _: anytype, _: anytype) void {}
    pub fn hitTest(_: anytype, _: anytype, _: anytype, _: anytype) !?ClickTarget {
        return null;
    }
    pub fn draw(_: anytype, _: anytype, _: anytype, _: anytype) !u16 {
        return 0;
    }
};
const carousel = if (build_options.has_seg_carousel) @import("carousel") else struct {
    pub fn scrollingActive() bool {
        return false;
    }
    pub fn pollDeadlineMs(_: anytype, _: anytype, _: anytype) i32 {
        return -1;
    }
};

const all_dirty: u5 = blk: {
    const fields = @typeInfo(types.BarSegment).@"enum".fields;
    var mask: u5 = 0;
    for (0..fields.len) |i| mask |= @as(u5, 1) << @intCast(i);
    break :blk mask;
};
const tiling = if (build_options.has_tiling) @import("tiling") else null;
const floating = if (build_options.has_floating) @import("floating") else null;

// ---------------------------------------------------------------------------
// Bar height / font-size resolution (folded from metrics.zig).
//
// Owns everything needed to decide the bar's pixel height and effective font
// size from config + font metrics, including the percentage-font-size probe
// (which measures through drawing.probeFontMetrics' throwaway surface — no
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
    // Probe metrics at a trial point size via the override parameter —
    // no save/mutate/restore round on cs.config.
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
    return @intCast(std.math.clamp(@as(u32, @intCast(m.asc + m.desc)), min_bar_height, max_bar_height));
}

// ---------------------------------------------------------------------------

pub fn onPollWakeup() void {
    if (gBar.state) |s| {
        if (s.is_visible and carousel.scrollingActive())
            s.markSegmentDirty(.title);
    }
    submitDraw();
    prompt.blinkTick();
}

pub fn pollTimeoutMs() i32 {
    const blink = prompt.blinkPollTimeoutMs();
    const tick = clock.tickDeadlineMs();
    var timeout = if (blink < 0) tick else @min(blink, tick);
    // Marquee frames: the carousel asks for wakes only while actually
    // scrolling, paced to the detected monitor refresh rate (see
    // carousel.pollDeadlineMs).
    const scroll = carousel.pollDeadlineMs(
        monotonicMs(),
        core.getState().config.bar.carousel_enabled,
        refresh_rate.detectedHz(),
    );
    if (scroll >= 0) timeout = @min(timeout, scroll);
    return timeout;
}

fn monotonicMs() i64 {
    return @intCast(utils.monotonicNs() / std.time.ns_per_ms);
}

pub fn promptHandleKeypress(event: *const xcb.xcb_key_press_event_t, matched: ?*const types.Action) bool {
    return prompt.handlePromptKeypress(event, matched);
}

pub fn promptToggle() void {
    prompt.toggle();
}

pub const Action = enum { toggle, hide_fullscreen, show_fullscreen };

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
// All functions operate on `g` directly — no passing state as parameters.
var gBar: Bar = .{};

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
/// title.zig's batch scratch limit (constants.Limits.max_tiled_windows).
const max_frame_windows: usize = constants.Limits.max_tiled_windows;

/// Upper bound on recorded click bounds: one slot per clickable segment in
/// the configured layout. Configs with more clickable segments than this
/// simply lose clickability on the extras (rendering is unaffected).
const max_click_bounds: usize = 8;

/// On-screen hit-test bound of one segment, recorded by recordClickBound
/// during the layout pass. THE click-bound storage: hit-testing iterates
/// these in recorded order (first match wins).
const SegBound = struct {
    seg: types.BarSegment,
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
    /// Per-segment dirty bitfield. Bit i corresponds to
    /// @intFromEnum(types.BarSegment) variant i. When set, the segment is
    /// repainted on the next draw; cleared after painting.
    segment_dirty: u5 = all_dirty,

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
    /// Title-string arena: every slice in `titles_buf` points into it, so a
    /// refetch reclaims all strings with one reset (capacity retained).
    titles_arena: std.heap.ArenaAllocator = undefined,
    /// Batched per-window prefetch scratch (see title.fetchTitlesAndGeoms),
    /// valid in [0, fetched_len) until the next refetch. Failed geometry
    /// replies are padded with the off-screen sentinel at refetch time.
    titles_buf: [max_frame_windows][]const u8 = undefined,
    geoms_buf: [max_frame_windows]?utils.Rect = undefined,
    fetched_len: usize = 0,
    focused_title: std.ArrayListUnmanaged(u8) = .empty,
    /// Window the focused_title buffer was fetched for (null = never/stale).
    focused_title_window: ?u32 = null,

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
            .clock_width = dc.measureTextWidth(clock.clock_measure_string) + 2 * config.scaledSegmentPadding(height),
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
        tags.invalidate();
        if (build_options.has_seg_layout) segmod.invalidateCachedWidths();
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

    fn markSegmentDirty(self: *State, seg: types.BarSegment) void {
        self.is_dirty = true;
        self.segment_dirty |= @as(u5, 1) << @intFromEnum(seg);
    }

    fn clearSegmentDirty(self: *State, seg: types.BarSegment) void {
        self.segment_dirty &= ~(@as(u5, 1) << @intFromEnum(seg));
    }

    fn isSegmentDirty(self: *const State, seg: types.BarSegment) bool {
        return self.segment_dirty & (@as(u5, 1) << @intFromEnum(seg)) != 0;
    }

    fn markAllSegmentsDirty(self: *State) void {
        self.segment_dirty = all_dirty;
    }

    /// Records the on-screen bounds of a clickable segment as the layout pass
    /// positions it, so handleButtonPress can hit-test against them without
    /// redoing the layout. Called unconditionally for every clickable kind;
    /// the clock is absent from the participation table (onClick rejects it).
    fn recordClickBound(self: *State, seg: types.BarSegment, x: u16, w: u16) void {
        if (seg == .clock) return;
        if (self.bounds_len >= max_click_bounds) return;
        self.bounds[self.bounds_len] = .{ .seg = seg, .x = x, .w = w };
        self.bounds_len += 1;
    }

    fn recordedBound(self: *const State, seg: types.BarSegment) ?SegBound {
        for (self.bounds[0..self.bounds_len]) |b| if (b.seg == seg) return b;
        return null;
    }

    fn measureSegmentWidth(self: *State, frame: *const segmod.Frame, segment: types.BarSegment) u16 {
        return segmod.naturalWidth(segment, frame, self.clock_width);
    }

    /// Stable per-call title rendering context for the title/prompt adapter.
    fn titleCtx(self: *const State, x: u16, w: u16) title.TitleRenderContext {
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
    fn titleSnapshot(self: *const State) title.TitleSnapshot {
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

    // -- Live-state collection ------------------------------------------------

    /// Reads workspace/window state into the frame fields and diffs the
    /// batch-refetch key against the stored one. Pure model reads: no X11.
    /// Returns true when the key changed (batch refetch needed).
    fn scanLiveFrame(self: *State) bool {
        const m = pipeline.model();
        if (build_options.has_workspaces) {
            if (workspaces.getState()) |ws_state| {
                self.ws_count = @intCast(ws_state.workspaces.len);
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
        }

        // Diff the fetch key: ids plus minimized membership (a minimize flips
        // the window's title-view geometry to the off-screen sentinel, which
        // demotes it in the split-view sort — that IS a data change).
        var changed = !self.fetch_key_valid or self.fetch_key_len != self.wins_len;
        for (0..self.wins_len) |i| {
            const minf = if (build_options.has_minimize) minimize.isMinimized(self.wins[i]) else false;
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
            if (fw) |w| title.fetchWindowTitleInto(self.win.conn, w, &self.focused_title, alloc) catch {};
            self.focused_title_window = fw;
        }

        if (gBar.force or self.fetch_dirty) self.refetchBatchedTitleData();
        self.fetch_dirty = false;
    }

    /// Re-runs the batched title/geometry prefetch into the scratch buffers.
    /// One dupe per title, ~2 round-trips total, zero blocking waits beyond
    /// those replies themselves (see title.fetchTitlesAndGeoms).
    fn refetchBatchedTitleData(self: *State) void {
        _ = self.titles_arena.reset(.retain_capacity);
        title.fetchTitlesAndGeoms(
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
            if (g.* == null) g.* = title.offscreen_rect;
        }
    }

    // -- Drawing ---------------------------------------------------------------

    /// Draws `segment`, catching and logging errors instead of propagating them.
    /// On failure returns `x` unchanged (the "drew nothing" signal) so a broken
    /// segment can't corrupt the surrounding layout or leave the off-screen
    /// pixmap partially drawn and never blitted.
    fn drawSegmentSafe(self: *State, frame: *const segmod.Frame, segment: types.BarSegment, x: u16, width: ?u16) u16 {
        return self.drawSegment(frame, segment, x, width) catch |e| {
            debug.warnOnErr(e, "bar drawSegment");
            return x;
        };
    }

    fn drawSegment(self: *State, frame: *const segmod.Frame, segment: types.BarSegment, x: u16, width: ?u16) !u16 {
        // Title adapter (see segment.zig draw()): needs caller-owned title
        // data from State; stays local for now.
        if (segment == .title)
            return prompt.draw(
                self.titleCtx(x, width orelse title.min_width),
                self.titleSnapshot(),
                self.render.allocator,
                false,
            );
        return segmod.draw(
            segment,
            .{ .dc = self.render.dc, .config = self.render.config, .height = self.render.height },
            x,
            frame,
        );
    }

    /// Draws one segment of a left-to-right row, painting the inter-segment gap
    /// and advancing `x`. `w` is the reserved width; `omit_gap_after_title`
    /// suppresses the gap after a title so the next segment sits flush (center
    /// layout). Returns the new `x`.
    fn drawRowSegment(
        self: *State,
        frame: *const segmod.Frame,
        seg: types.BarSegment,
        x: u16,
        w: u16,
        omit_gap_after_title: bool,
        scaled_spacing: u16,
    ) u16 {
        const omit_gap = omit_gap_after_title and seg == .title;
        const x_before = x;
        const drawn_x = self.drawSegmentSafe(frame, seg, x, w);
        if (!omit_gap and drawn_x != x_before) {
            self.paintGap(drawn_x, scaled_spacing);
            return drawn_x + scaled_spacing;
        }
        return drawn_x;
    }

    fn paintGap(self: *State, gap_x: u16, scaled_spacing: u16) void {
        self.render.dc.fillRect(gap_x, 0, scaled_spacing, self.render.height, self.render.config.bg);
    }

    fn drawRightSegments(self: *State, frame: *const segmod.Frame, segments: []const types.BarSegment, is_full_redraw: bool) void {
        const scaled_spacing = self.render.config.scaledSpacing(self.render.height);
        var right_x = self.render.width;
        var pending_gap = false;
        var i = segments.len;
        while (i > 0) {
            i -= 1;
            const seg_w = self.measureSegmentWidth(frame, segments[i]);
            right_x -= seg_w;
            if (pending_gap) right_x -= scaled_spacing;

            if (segments[i] == .clock) self.clock_x = right_x;
            self.recordClickBound(segments[i], right_x, seg_w);

            if (self.isSegmentDirty(segments[i])) {
                if (!is_full_redraw) {
                    self.render.dc.fillRect(right_x, 0, seg_w, self.render.height, self.render.config.bg);
                }
                const drew = self.drawSegmentSafe(frame, segments[i], right_x, null) != right_x;
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
                self.clearSegmentDirty(segments[i]);
            } else {
                pending_gap = true;
            }
        }
    }

    /// Repaints the bar into the off-screen pixmap. When every segment is
    /// dirty (full redraw / force) the whole background is cleared once;
    /// otherwise only the dirty segments' regions are repainted, leaving
    /// unchanged pixels from the previous frame untouched.
    fn drawAllInner(self: *State, frame: *const segmod.Frame) void {
        const r = &self.render;
        const scaled_spacing = r.config.scaledSpacing(r.height);
        const is_full_redraw = self.segment_dirty == all_dirty;

        if (is_full_redraw) {
            r.dc.fillRect(0, 0, r.width, r.height, r.config.bg);
        }

        var right_total: u16 = 0;
        for (r.config.layout.items) |lay| {
            if (lay.position != .right) continue;
            for (lay.segments.items) |seg| right_total += self.measureSegmentWidth(frame, seg) + scaled_spacing;
            if (lay.segments.items.len > 0) right_total -= scaled_spacing;
        }

        self.bounds_len = 0;
        var x: u16 = 0;
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
                        @min(@max(title.min_width, avail -| scaled_spacing), avail)
                    else
                        0;
                    for (lay.segments.items) |seg| {
                        const w = if (seg == .title and lay.position == .center) remaining else self.measureSegmentWidth(frame, seg);
                        self.recordClickBound(seg, x, w);
                        if (self.isSegmentDirty(seg)) {
                            if (!is_full_redraw) {
                                const omit_gap = (lay.position == .center) and seg == .title;
                                const clear_w = if (omit_gap) w else w + scaled_spacing;
                                r.dc.fillRect(x, 0, clear_w, r.height, r.config.bg);
                            }
                            x = self.drawRowSegment(frame, seg, x, w, lay.position == .center, scaled_spacing);
                            self.clearSegmentDirty(seg);
                        } else {
                            const omit_gap = (lay.position == .center) and seg == .title;
                            x += w;
                            if (!omit_gap) x += scaled_spacing;
                        }
                    }
                },
                .right => self.drawRightSegments(frame, lay.segments.items, is_full_redraw),
            }
        }
    }

    fn drawClockOnly(self: *State) void {
        const clock_x = self.clock_x orelse return;
        const drawn_end = clock.draw(self.render.dc, self.render.config, self.render.height, clock_x) catch |e| {
            debug.warnOnErr(e, "drawClockOnly");
            return;
        };
        // Region-scoped blit: copies only the clock region and flushes (this
        // is a timer-driven path; no event-loop flush is coming). Blit at
        // least what was PAINTED (drawn_end can exceed the layout-time
        // reservation after font fallback or digit-width drift — blitting
        // only the cached width would clip digits) while keeping the full
        // reserved slot covered so stale pixels from a wider earlier frame
        // still get overwritten with the clean background the last full
        // frame left.
        const drawn_w: u16 = drawn_end -| clock_x;
        self.render.dc.blitRegion(clock_x, @max(self.clock_width, drawn_w));
        self.clearSegmentDirty(.clock);
    }
};

// Draw submission

/// Collects live state, repaints every segment into the off-screen pixmap,
/// and queues the single xcb_copy_area blit (cairo_surface_flush included,
/// xcb_flush NOT: the caller's context flushes — event-loop end-of-batch on
/// normal paths, ungrabAndFlush inside grabs).
fn performDraw() void {
    const s = gBar.state orelse return;
    if (!s.is_visible) return;
    if (gBar.force) s.markAllSegmentsDirty();
    if (build_options.has_minimize) minimize.collectMinimizedIntoSet(&s.minimized, s.render.allocator) catch {};
    s.fetch_dirty = s.scanLiveFrame();
    s.refreshTitleData();
    const frame = segmod.Frame{
        .workspace_count = s.ws_count,
        .current_workspace = s.current_ws,
        .is_all_view_active = s.all_view,
        .workspace_has_windows = s.ws_has_windows[0..s.ws_count],
    };
    s.drawAllInner(&frame);
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
    refresh_rate.ensureRefreshRateDetected(cs.conn);
    const height = try calcBarHeightAndFontSize();
    const bar = try createBar(height, barwin.calcBarYPos(height));
    gBar.state = bar.state;
    submitDraw();
    _ = xcb.xcb_map_window(cs.conn, bar.setup.win_id);
    _ = xcb.xcb_flush(cs.conn);
    if (build_options.has_vim) {
        vim.register();
        try vim.init(cs.alloc, prompt.default_max_input);
    }
    try prompt.init(cs.alloc, cs.conn);
}

pub fn deinit() void {
    prompt.deinit();
    if (build_options.has_vim) vim.deinit(core.getState().alloc);
    if (gBar.state) |s| {
        _ = xcb.xcb_destroy_window(s.win.conn, s.win.win_id);
        s.render.dc.deinit();
        s.deinit();
        gBar.state = null;
    }
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
    // Prompt caches (font widths, caret geometry) are built against the old
    // config; the new one is live from here on either way, so drop them up
    // front — including on the failure path below, where the surviving bar
    // re-points at the NEW live config too.
    prompt.invalidateReloadCaches();
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
    submitDrawBlockingFull();
    if (new_state.is_visible) _ = xcb.xcb_map_window(cs.conn, new_bar.setup.win_id);
    _ = xcb.xcb_destroy_window(cs.conn, old.win.win_id);
    ungrabAndFlush();
    old.render.dc.deinit();
    old.deinit();
}

// Public event handlers & queries

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
    const no_fullscreen = model.fullscreenOccupantOnWs(pipeline.model(), @intCast(current_ws)) == null;
    // The work area changed with the bar's new edge; one model reconcile
    // re-derives every placement from it.
    // LAYERING NOTE: The bar triggers reconciliation after visibility/position
    // changes because the work area geometry changed, affecting all window
    // placements. This is a write-path side effect from a rendering module —
    // documented in the check-layers.sh allowlist.
    if (no_fullscreen) pipeline.reconcileNow();
    window.updateFloatingWindowBorders();
    window.markBordersFlushed();
    ungrabAndFlush();
    debug.info("Bar position toggled to: {s}", .{@tagName(cs.config.bar.bar_position)});
}

/// Lightweight focus-only redraw; skipped when a full redraw is already pending.
pub fn scheduleFocusRedraw(_: ?u32) void {
    const s = gBar.state orelse return;
    if (!s.is_visible or s.is_dirty) return;
    // Only the title segment needs repainting on a focus change; mark it
    // dirty without forcing a full-bar redraw. A per-frame redraw during
    // rapid window opening would produce O(N²) property queries and Pango
    // renders — skipping the early draw lets the post-batch hook do one
    // coalesced redraw instead.
    s.markSegmentDirty(.title);
}

pub fn isBarWindow(win: u32) bool {
    return if (gBar.state) |s| s.win.win_id == win else false;
}
pub fn getBarWindow() u32 {
    return if (gBar.state) |s| s.win.win_id else 0;
}
pub fn getBarHeight() u16 {
    return if (gBar.state) |s| s.render.height else 0;
}

/// Screen area not covered by the bar, as a Rect (x=0, y=bar inset or 0).
/// Window id of the bar, or null before init(). Lets the boot-time
/// window adoption skip the WM's own window.
pub fn winId() ?u32 {
    return if (gBar.state) |s| s.win.win_id else null;
}

pub fn workAreaRect() utils.Rect {
    const cs = core.getState();
    const bar_height: u16 = if (isVisible()) getBarHeight() else 0;
    const at_bottom = cs.config.bar.bar_position == .bottom;
    return .{
        .x = 0,
        .y = if (at_bottom) 0 else @intCast(bar_height),
        .width = cs.screen.width_in_pixels,
        .height = cs.screen.height_in_pixels -| bar_height,
    };
}

/// Schedules a full bar redraw, coalesced via updateIfDirty. Zero X11 I/O on the caller.
pub fn scheduleRedraw() void {
    if (gBar.state) |s| if (s.is_visible) s.markDirty();
}

/// Like scheduleRedraw but also forces a title-data refetch on the next draw.
///
/// Use when a segment's presence or width may change (e.g. layout switch) or
/// when cached title data must be re-read from X11 despite an unchanged
/// fetch key; stale pixels are erased by the unconditional background clear.
pub fn scheduleFullRedraw() void {
    if (gBar.state) |s| if (s.is_visible) {
        gBar.force = true;
        s.markDirty();
    };
}

pub fn isVisible() bool {
    return if (gBar.state) |s| s.is_visible else false;
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
/// prevent (see the O(N²)-in-grab note in window.zig). Those frames fall
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
        if (focus_changed) s.markSegmentDirty(.title);
        if (frame_changed) {
            s.markSegmentDirty(.workspaces);
            s.markSegmentDirty(.title);
        }
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
    const should_show = model.fullscreenOccupantOnWs(pipeline.model(), @intCast(current_ws)) == null and s.is_globally_visible;
    if (should_show) return; // conditions changed while the prompt was open; stay visible
    s.is_visible = false;
    _ = xcb.xcb_unmap_window(s.win.conn, s.win.win_id);
    _ = xcb.xcb_flush(s.win.conn);
}

pub fn setBarState(action: Action) void {
    const s = gBar.state orelse return;
    if (action == .toggle) s.is_globally_visible = !s.is_globally_visible;
    const current_ws = tracking.getCurrentWorkspace() orelse 0;
    const bar_forced_hidden_by_fullscreen = action != .hide_fullscreen and
        model.fullscreenOccupantOnWs(pipeline.model(), @intCast(current_ws)) != null;
    const should_be_visible = !bar_forced_hidden_by_fullscreen and s.is_globally_visible and action != .hide_fullscreen;
    if (s.is_visible == should_be_visible and action != .toggle) return;
    s.is_visible = should_be_visible;
    if (should_be_visible) {
        gBar.skip_title_refetch = true;
        submitDrawBlockingFull();
    }

    const conn = core.getState().conn;
    utils.grabServer(conn);
    if (should_be_visible) _ = xcb.xcb_map_window(conn, s.win.win_id) else _ = xcb.xcb_unmap_window(conn, s.win.win_id);
    // LAYERING NOTE: The bar triggers reconciliation after visibility/position
    // changes because the work area geometry changed, affecting all window
    // placements. This is a write-path side effect from a rendering module —
    // documented in the check-layers.sh allowlist.
    pipeline.reconcileNow();
    ungrabAndFlush();
    debug.info("Bar {s} ({s})", .{ if (should_be_visible) "shown" else "hidden", @tagName(action) });
}

pub fn updateIfDirty() !void {
    const s = gBar.state orelse return;
    if (!s.is_visible) return;
    if (prompt.consumeRedrawRequest()) {
        gBar.force = true;
        s.is_dirty = true;
    }
    if (s.is_dirty) {
        submitDraw();
        s.is_dirty = false;
    }
}

/// Redraws just the clock segment when its on-screen content is stale
/// (second rolled over, or config reload changed the format). Cheap to call
/// on every event batch: it no-ops unless staleness is detected.
pub fn updateClock() bool {
    const s = gBar.state orelse return false;
    if (!s.is_visible) return false;
    if (!clock.secondElapsed(cs_configClockFormat())) return false;
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
        const dragging = if (build_options.has_floating) floating.isDragging() else false;
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
        s.markSegmentDirty(.title);
    }
}

// Mouse click handling

/// Routes a ButtonPress on the bar window to whichever segment was clicked.
/// Called from input.zig before its managed-window click path: the bar is
/// never a managed window, so that path would just replay and swallow it.
///
/// Hit-testing walks the bounds RECORDED DURING THE LAST LAYOUT PASS in
/// record order (first containing bound wins), then delegates behavior to
/// the segment contract's single onClick dispatch.
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

    const hit: ?SegBound = blk: {
        for (s.bounds[0..s.bounds_len]) |b| {
            if (b.contains(x)) break :blk b;
        }
        break :blk null;
    };
    const h = hit orelse return;
    _ = segmod.onClick(h.seg, x - h.x, left, right, s, titleClickTrampoline, redrawInsideGrab);
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
    const tb = s.recordedBound(.title) orelse return;

    const target = (title.hitTest(s.titleCtx(tb.x, tb.w), s.titleSnapshot(), s.render.allocator, offset) catch |e| {
        debug.warnOnErr(e, "bar title click hitTest");
        return;
    }) orelse return;

    if (build_options.has_minimize and minimize.isMinimized(target.window)) {
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
