//! Status bar
//! Creates and manages the WM status bar, rendering all configured segments.

const std = @import("std");

const core = @import("core");
const xcb = core.xcb;
const utils = @import("utils");
const refresh_rate = @import("refresh_rate");
const scale = @import("scale");
const constants = @import("constants");
const debug = @import("debug");
const bench = @import("bench");

const types = @import("types");

const tracking = @import("tracking");
const focus = @import("focus");
const minimize = @import("minimize");
const pipeline = @import("pipeline"); // PIPELINE: train a
const actions = @import("actions"); // PIPELINE: train a

const window = @import("window");

const drawing = @import("drawing");
const prompt = @import("prompt");
const sn = @import("snapshot");
const segmod = @import("segment");
const metrics = @import("metrics");
const barwin = @import("win");

const clock = @import("clock");
const layout = @import("layout");
const title = @import("title");
const carousel = @import("carousel");
const variants = @import("variants");
const tags = @import("tags");

const build_options = @import("build_options");
const tiling = if (build_options.has_tiling) @import("tiling") else null;
const floating = if (build_options.has_floating) @import("floating") else null;

pub fn onPollWakeup() void {
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

/// Owns all live bar state.
const Bar = struct {
    state: ?*State = null,
    /// Forces a full bar redraw on the next submitDraw (expose, reload, position toggle, show).
    /// Read and written exclusively on the main thread; does not require mutex protection.
    pending_force_full_redraw: bool = false,
    /// Forces the next capture to re-fetch the title segment's per-window data
    /// (titles + geometry) even though focus / window-set / minimized state
    /// haven't changed, without a full bar clear (see scheduleTitleRedraw).
    /// Read and written exclusively on the main thread.
    pending_force_title_redraw: bool = false,
    /// True when presentForPrompt() had to map an otherwise-hidden bar (e.g.
    /// hidden by a fullscreen window, or by the user toggling it off) purely
    /// so the inline prompt would be visible. dismissAfterPrompt() checks this
    /// to know whether hiding the bar again is part of "returning to normal".
    prompt_forced_visible: bool = false,
};

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

/// On-screen hit-test bounds of a clickable segment, recorded by
/// recordClickBounds during the last full layout pass.
const SegBounds = struct {
    x: u16 = 0,
    w: u16 = 0,
    has: bool = false,

    inline fn contains(self: SegBounds, px: u16) bool {
        return self.has and px >= self.x and px < self.x + self.w;
    }
};

/// Per-draw layout geometry; invalidated when workspace_count changes or the
/// clock position is reset.
const LayoutCache = struct {
    clock_width: u16 = 0,
    clock_x: ?u16 = null,
    right_section_width: u16 = 0,
    cached_workspace_count: u32 = std.math.maxInt(u32),

    /// On-screen bounds of the workspaces segment, refreshed on every full
    /// layout pass (drawAllInner always walks the whole configured layout,
    /// regardless of dirty flags): see recordClickBounds. Used by
    /// handleButtonPress to hit-test workspace-icon clicks.
    workspaces_bounds: SegBounds = .{},

    /// On-screen bounds of the layout (tiling indicator) segment. Same
    /// refresh contract as workspaces_bounds above.
    layout_bounds: SegBounds = .{},

    /// On-screen bounds of the layout variants segment. Same refresh
    /// contract as workspaces_bounds above.
    variants_bounds: SegBounds = .{},
};

const State = struct {
    win: WindowCtx,
    render: RenderCtx,
    layout_cache: LayoutCache = .{},
    title_cache: sn.TitleCache = .{},
    is_visible: bool = true,
    is_globally_visible: bool = true,
    is_dirty: bool = false,
    /// Title geometry captured by drawAllInner; consumed by drawAll
    /// to call syncTitleCache after the flush decision.
    title_cache_pending_x: ?u16 = null,
    title_cache_pending_w: u16 = 0,
    /// Ping-ponged snapshot pair used to diff this frame's state against the
    /// last one (see captureStateIntoSlot). snap_idx names the "current" slot;
    /// `1 - snap_idx` is "previous". Flipped after every draw.
    snapshots: [2]sn.BarSnapshot = .{ .{}, .{} },
    snap_idx: u1 = 0,

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
            .layout_cache = .{
                .clock_width = dc.cachedTextWidth(clock.clock_measure_string) + 2 * config.scaledSegmentPadding(height),
            },
        };
        // Partial-failure mirror of deinit(), minus the X resources: the
        // caller's createBar errdefers own the window+colormap and the dc.
        // Safe to arm here — every fallible step below runs after all owned
        // sub-resources are initialized (WindowTitles.init is infallible; a
        // default .{} TitleData would carry an undefined arena).
        errdefer {
            s.title_cache.deinit(s.render.allocator);
            for (&s.snapshots) |*snap| snap.deinit(s.render.allocator);
            s.render.allocator.destroy(s);
        }
        for (&s.snapshots) |*snap| snap.title_data.window_titles = sn.WindowTitles.init(allocator);
        s.title_cache.title_data.window_titles = sn.WindowTitles.init(allocator);
        try s.title_cache.title_data.focused_title.ensureTotalCapacity(allocator, 256);
        tags.invalidate();
        return s;
    }

    fn deinit(self: *State) void {
        self.win.deinit();
        self.title_cache.deinit(self.render.allocator);
        for (&self.snapshots) |*snap| snap.deinit(self.render.allocator);
        self.render.allocator.destroy(self);
    }

    fn markDirty(self: *State) void {
        self.is_dirty = true;
    }

    fn invalidateLayoutCache(self: *State) void {
        self.is_dirty = true;
        self.layout_cache.clock_x = null;
    }

    /// Records the on-screen bounds of a clickable segment as drawAllInner
    /// positions it, so handleButtonPress can hit-test against them without
    /// redoing the layout pass. Called unconditionally, even for segments
    /// shouldSkipSegment skips; since the reserved screen position is stable
    /// whether or not the pixels were repainted. No-op for non-clickable kinds.
    fn recordClickBounds(self: *State, seg: types.BarSegment, x: u16, w: u16) void {
        // D3: which segments are clickable is the contract's table
        // (segment.isClickable). Only bound STORAGE stays here; title's
        // bounds keep their post-draw recording path (title_cache_pending_*),
        // so they are not touched in this switch.
        const b: ?*SegBounds = switch (seg) {
            .workspaces => &self.layout_cache.workspaces_bounds,
            .layout => &self.layout_cache.layout_bounds,
            .variants => &self.layout_cache.variants_bounds,
            else => null,
        };
        const bb = b orelse return;
        bb.x = x;
        bb.w = w;
        bb.has = true;
    }

    fn measureSegmentWidth(self: *State, snap: *const sn.BarSnapshot, segment: types.BarSegment) u16 {
        return segmod.naturalWidth(segment, snap, self.layout_cache.clock_width);
    }

    /// Stable per-call title rendering context; `cached_title`/`cached_title_window`
    /// are the bar slot's title cache on the `draw()` path, null elsewhere.
    fn titleCtx(self: *State, x: u16, w: u16, cached_title: ?*std.ArrayListUnmanaged(u8), cached_title_window: ?*?u32) title.TitleRenderContext {
        return .{
            .dc = self.render.dc,
            .config = self.render.config,
            .height = self.render.height,
            .start_x = x,
            .width = w,
            .conn = self.win.conn,
            .cached_title = cached_title,
            .cached_title_window = cached_title_window,
        };
    }

    fn drawSegment(self: *State, snap: *const sn.BarSnapshot, segment: types.BarSegment, x: u16, width: ?u16) !u16 {
        const r = &self.render;
        switch (segment) {
            // Title adapter (see segment.zig draw()): needs caller-owned
            // title-cache pointers from State; stays local for now.
            .title => return prompt.draw(
                self.titleCtx(x, width orelse title.min_width, &self.title_cache.title_data.focused_title, &self.title_cache.title_window),
                sn.makeTitleSnapshot(
                    snap.title_data.focused_window,
                    snap.title_data.focused_title.items,
                    snap.title_data.workspace_windows.items,
                    &snap.title_data.minimized_windows,
                    snap.title_data.window_titles.list.items,
                    snap.title_data.window_geoms.items,
                ),
                r.allocator,
                snap.is_title_invalidated,
            ),
            else => {},
        }
        return segmod.draw(
            segment,
            .{ .dc = r.dc, .config = r.config, .height = r.height },
            x,
            width orelse 0,
            snap,
            undefined,
        );
    }

    /// Draws `segment`, catching and logging errors instead of propagating them.
    /// On failure returns `x` unchanged (the "drew nothing" signal) so a broken
    /// segment can't corrupt the surrounding layout or leave the off-screen
    /// pixmap partially drawn and never blitted.
    fn drawSegmentSafe(self: *State, snap: *const sn.BarSnapshot, segment: types.BarSegment, x: u16, width: ?u16) u16 {
        return self.drawSegment(snap, segment, x, width) catch |e| {
            debug.warnOnErr(e, "bar drawSegment");
            return x;
        };
    }

    /// Draws one segment of a left-to-right row, painting the inter-segment gap
    /// and advancing `x`. `w` is the reserved width (also used when the segment
    /// is skipped); `omit_gap_after_title` suppresses the gap after a title so
    /// the next segment sits flush (center layout). Returns the new `x`.
    fn drawRowSegment(
        self: *State,
        snap: *const sn.BarSnapshot,
        seg: types.BarSegment,
        x: u16,
        w: u16,
        omit_gap_after_title: bool,
        scaled_spacing: u16,
    ) u16 {
        const omit_gap = omit_gap_after_title and seg == .title;
        if (shouldSkipSegment(snap, seg)) return x + w + (if (omit_gap) 0 else scaled_spacing);

        const x_before = x;
        const drawn_x = self.drawSegmentSafe(snap, seg, x, w);
        if (!omit_gap and drawn_x != x_before) {
            self.paintGap(drawn_x, scaled_spacing);
            return drawn_x + scaled_spacing;
        }
        return drawn_x;
    }

    /// Returns true when `seg` should be skipped because its data has not changed
    /// since the last frame and a full redraw is not required.
    inline fn shouldSkipSegment(snap: *const sn.BarSnapshot, seg: types.BarSegment) bool {
        // Marquee frames repaint moving pixels whose data hasn't changed, so
        // the title's clean diff must not suppress them while scrolling.
        if (seg == .title and carousel.scrollingActive()) return false;
        return segmod.shouldSkip(snap, seg);
    }

    fn paintGap(self: *State, gap_x: u16, scaled_spacing: u16) void {
        self.render.dc.fillRect(gap_x, 0, scaled_spacing, self.render.height, self.render.config.bg);
    }

    fn drawRightSegments(self: *State, snap: *const sn.BarSnapshot, segments: []const types.BarSegment) void {
        const scaled_spacing = self.render.config.scaledSpacing(self.render.height);
        var right_x = self.render.width;
        var pending_gap = false;
        var i = segments.len;
        while (i > 0) {
            i -= 1;
            const seg_w = self.measureSegmentWidth(snap, segments[i]);
            right_x -= seg_w;
            if (pending_gap) right_x -= scaled_spacing;

            if (segments[i] == .clock) self.layout_cache.clock_x = right_x;
            self.recordClickBounds(segments[i], right_x, seg_w);

            if (shouldSkipSegment(snap, segments[i])) {
                pending_gap = false;
                continue;
            }

            const drew = self.drawSegmentSafe(snap, segments[i], right_x, null) != right_x;
            if (drew) {
                if (pending_gap) self.paintGap(right_x + seg_w, scaled_spacing);
            } else {
                right_x += seg_w;
                if (pending_gap) right_x += scaled_spacing;
            }
            pending_gap = drew;
        }
    }

    /// When `flush` is true, blits the off-screen pixmap to the window (event-loop path).
    /// When false, only flushes Cairo to the pixmap: safe inside xcb_grab_server.
    fn drawAll(self: *State, snap: *const sn.BarSnapshot, flush: bool) void {
        self.drawAllInner(snap);
        if (flush) self.render.dc.blit() else self.render.dc.renderOnly();
        if (self.title_cache_pending_x) |x|
            self.syncTitleCache(snap, x, self.title_cache_pending_w);
        self.title_cache_pending_x = null;
    }

    /// Core drawing logic shared by the flush and grab-safe draw paths; does not flush.
    fn drawAllInner(self: *State, snap: *const sn.BarSnapshot) void {
        if (snap.is_title_invalidated) self.title_cache.title_window = null;
        if (snap.is_full_redraw) self.render.dc.fillRect(0, 0, self.render.width, self.render.height, self.render.config.bg);

        const scaled_spacing = self.render.config.scaledSpacing(self.render.height);

        // Recompute right_section_width only when workspace_count changes.
        if (snap.workspace_count != self.layout_cache.cached_workspace_count) {
            var right_total: u16 = 0;
            for (self.render.config.layout.items) |lay| {
                if (lay.position != .right) continue;
                for (lay.segments.items) |seg| right_total += self.measureSegmentWidth(snap, seg) + scaled_spacing;
                if (lay.segments.items.len > 0) right_total -= scaled_spacing;
            }
            self.layout_cache.right_section_width = right_total;
            self.layout_cache.cached_workspace_count = snap.workspace_count;
        }

        const right_total = self.layout_cache.right_section_width;
        var title_seg_x: u16 = 0;
        var title_seg_w: u16 = 0;
        var x: u16 = 0;

        for (self.render.config.layout.items) |lay| {
            switch (lay.position) {
                .left, .center => {
                    const remaining = if (lay.position == .center)
                        @max(title.min_width, self.render.width -| x -| right_total -| scaled_spacing)
                    else
                        0;
                    for (lay.segments.items) |seg| {
                        const w = if (seg == .title and lay.position == .center) remaining else self.measureSegmentWidth(snap, seg);
                        if (seg == .title) {
                            title_seg_x = x;
                            title_seg_w = w;
                        }
                        self.recordClickBounds(seg, x, w);
                        x = self.drawRowSegment(snap, seg, x, w, lay.position == .center, scaled_spacing);
                    }
                },
                .right => self.drawRightSegments(snap, lay.segments.items),
            }
        }

        self.title_cache_pending_x = if (title_seg_w > 0) title_seg_x else null;
        self.title_cache_pending_w = title_seg_w;
    }

    fn drawClockOnly(self: *State) void {
        const clock_x = self.layout_cache.clock_x orelse return;
        const drawn_end = clock.draw(self.render.dc, self.render.config, self.render.height, clock_x) catch |e| {
            debug.warnOnErr(e, "drawClockOnly");
            return;
        };
        // renderOnly() flushes Cairo to the pixmap; blitAndFlush() copies only the
        // clock region to the window and calls xcb_flush, avoiding a full-window
        // blit plus a separate main-thread xcb_flush.
        self.render.dc.renderOnly();
        // Blit at least what was PAINTED (drawn_end can exceed the layout-time
        // reservation after font fallback or digit-width drift — blitting only
        // the cached width would clip digits) while keeping the full reserved
        // slot covered so stale pixels from a wider earlier frame still get
        // overwritten with the clean background the last full frame left.
        const drawn_w: u16 = drawn_end -| clock_x;
        self.render.dc.blitAndFlush(clock_x, @max(self.layout_cache.clock_width, drawn_w));
    }

    /// Replacements are built before the swap so a failed allocation leaves the cache
    /// showing stale data rather than going silently empty.
    fn syncTitleCache(self: *State, snap: *const sn.BarSnapshot, x: u16, w: u16) void {
        const alloc = self.render.allocator;

        // Re-sync per-window data only when the capture re-fetched it
        // (snap.title_list_refreshed). Unchanged frames relay the same lists
        // between ping-pong slots, so the cache already matches; re-duping
        // every title was an O(window count) alloc+free pass for no-op data.
        if (snap.title_list_refreshed) {
            sn.swapAlloc(u32, &self.title_cache.title_data.workspace_windows, alloc, snap.title_data.workspace_windows.items);

            if (snap.title_data.minimized_windows.clone(alloc)) |new_set| {
                self.title_cache.title_data.minimized_windows.deinit(alloc);
                self.title_cache.title_data.minimized_windows = new_set;
            } else |_| {
                // minimized_windows left stale rather than cleared.
            }

            // Keep cached titles in sync for fast-path redraws.
            // replaceWith frees the old owned strings before duping the new ones,
            // so a failed dupe simply truncates the cache rather than desyncing it.
            self.title_cache.title_data.window_titles.replaceWith(alloc, snap.title_data.window_titles.list.items);

            // Keep cached geometry in sync for fast-path redraws. Rect is
            // POD, so, like workspace_windows above, build the replacement before
            // swapping it in: a failed allocation leaves the cache untouched.
            sn.swapAlloc(utils.Rect, &self.title_cache.title_data.window_geoms, alloc, snap.title_data.window_geoms.items);

            self.title_cache.title_data.focused_window = snap.title_data.focused_window;
        }

        self.title_cache.title_x = x;
        self.title_cache.title_width = w;
        self.title_cache.is_layout_valid = true;
    }
};

// Draw submission

/// Returns true on success, false if the bar is not visible or capture failed.
/// Captures into whichever snapshot slot is currently "current" (s.snap_idx),
/// diffing against the other slot ("previous").
fn prepareSnapshot(s: *State) bool {
    if (!s.is_visible) return false;
    const idx = s.snap_idx;
    const forced = gBar.pending_force_full_redraw;
    gBar.pending_force_full_redraw = false;
    const pending_title = gBar.pending_force_title_redraw;
    gBar.pending_force_title_redraw = false;
    sn.captureStateIntoSlot(
        s.render.allocator,
        &s.title_cache,
        &s.snapshots[idx],
        &s.snapshots[1 - idx],
        forced,
        pending_title,
    ) catch |e| {
        debug.warnOnErr(e, "bar captureStateIntoSlot");
        return false;
    };
    return true;
}

/// Captures a fresh snapshot and draws synchronously. `flush` selects
/// whether the result is blitted to the window (normal path) or only rendered
/// to the off-screen pixmap (grab-safe path: see redrawInsideGrab).
fn performDraw(flush: bool) void {
    const s = gBar.state orelse return;
    if (!prepareSnapshot(s)) return;
    s.drawAll(&s.snapshots[s.snap_idx], flush);
    s.snap_idx ^= 1;
}

fn submitDrawBlockingFull() void {
    gBar.pending_force_full_redraw = true;
    performDraw(true);
}

/// Invalidates the title cache and triggers a full redraw.
fn submitFullRedrawWithTitleReset(s: *State) void {
    s.title_cache.is_invalidated = true;
    submitDrawBlockingFull();
}

inline fn ungrabAndFlush() void {
    utils.ungrabAndFlush(core.getState().conn);
}

/// Draws and blits to the window. Drawing always happens inline on the
/// calling thread.
pub fn submitDraw() void {
    performDraw(true);
}

/// Renders only: no xcb_copy_area, no xcb_flush.
/// Use INSIDE xcb_grab_server; pair with dc.blitQueued() + ungrabAndFlush().
fn submitRenderBlocking() void {
    performDraw(false);
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
    const height = try metrics.calcBarHeightAndFontSize();
    const bar = try createBar(height, barwin.calcBarYPos(height));
    gBar.state = bar.state;
    submitDraw();
    _ = xcb.xcb_map_window(cs.conn, bar.setup.win_id);
    _ = xcb.xcb_flush(cs.conn);
    try prompt.init(cs.alloc, cs.conn);
}

pub fn deinit() void {
    prompt.deinit();
    if (gBar.state) |s| {
        _ = xcb.xcb_destroy_window(s.win.conn, s.win.win_id);
        s.render.dc.deinit();
        drawing.deinitFontCache(s.render.allocator);
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
    const height = metrics.calcBarHeightAndFontSize() catch metrics.default_bar_height;
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
    gBar.pending_force_full_redraw = true;
    s.invalidateLayoutCache();
    utils.grabServer(cs.conn);
    _ = xcb.xcb_configure_window(cs.conn, s.win.win_id, xcb.XCB_CONFIG_WINDOW_Y, &[_]u32{utils.toXcbCoord(new_y)});
    const current_ws = tracking.getCurrentWorkspace() orelse {
        window.updateWorkspaceBorders();
        window.markBordersFlushed();
        ungrabAndFlush();
        return;
    };
    const no_fullscreen = !actions.fullscreenOccupiedOnWs(@intCast(current_ws));
    // WP6: the work area changed with the bar's new edge; one model
    // reconcile re-derives every placement from it (legacy retile deleted).
    if (no_fullscreen) pipeline.reconcileInGrab();
    window.updateFloatingWindowBorders();
    window.markBordersFlushed();
    ungrabAndFlush();
    debug.info("Bar position toggled to: {s}", .{@tagName(cs.config.bar.bar_position)});
}

/// Lightweight focus-only redraw; skipped when a full redraw is already pending.
pub fn scheduleFocusRedraw(_: ?u32) void {
    const s = gBar.state orelse return;
    if (!s.is_visible or s.is_dirty) return;
    // markDirty ensures a full redraw follows at end-of-batch via
    // updateIfDirty, which re-captures window state and renders the
    // entire bar. A per-frame redraw during rapid window opening would
    // produce O(N²) property queries and Pango renders. Skipping the
    // early draw lets the post-batch hook do one full redraw instead.
    s.markDirty();
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

/// Like scheduleRedraw but forces a full bar clear+redraw regardless of dirty flags.
///
/// Use when a segment's presence or width changes (e.g. layout switch) so stale
/// pixels from the previous render are guaranteed to be erased.
pub fn scheduleFullRedraw() void {
    if (gBar.state) |s| if (s.is_visible) {
        gBar.pending_force_full_redraw = true;
        s.markDirty();
    };
}

/// Schedules a redraw that re-captures the title segment's per-window data
/// (re-running the batched pre-fetch) without clearing the whole bar.
///
/// Use when window positions change but focus and the window-ID set don't
/// (e.g. a master swap): the segmented title view sorts by position, so its
/// segment order is stale. Cheaper than scheduleFullRedraw; no background
/// clear, and the other segments skip via shouldSkipSegment.
pub fn scheduleTitleRedraw() void {
    if (gBar.state) |s| if (s.is_visible) {
        gBar.pending_force_title_redraw = true;
        s.markDirty();
    };
}

pub fn isVisible() bool {
    return if (gBar.state) |s| s.is_visible else false;
}

/// Synchronous bar update safe to call inside xcb_grab_server.
///
/// Phase 1 (inside grab): render to the off-screen pixmap: cairo_surface_flush
/// only, no xcb_copy_area/flush, so the compositor sees no intermediate frame.
/// Phase 2: blitQueued() enqueues xcb_copy_area without flushing; the caller's
/// ungrabAndFlush() sends configure_window + copy_area + ungrab in one flush,
/// producing exactly one compositor frame.
///
/// Frames whose diff says title data changed are DEFERRED instead of rendered:
/// their recapture runs blocking property round trips under this grab --
/// every client stalls until the replies arrive, and each reply's implicit
/// flush tears the caller's queued configure/map batch apart mid-operation,
/// exactly what the grab exists to prevent (see the O(N²)-in-grab note in
/// window.zig). Those frames fall back to the coalesced post-batch redraw;
/// cheap frames (unchanged focus/window set) still render inline as before.
pub fn redrawInsideGrab() void {
    const s = gBar.state orelse return;
    if (!s.is_visible) return;
    if (sn.snapshotNeedsRefetch(
        gBar.pending_force_title_redraw,
        &s.snapshots[1 - s.snap_idx],
        s.title_cache.is_invalidated,
    )) {
        s.markDirty();
        return;
    }
    // Phase 1: render to pixmap without any XCB flush.
    submitRenderBlocking();
    // Phase 2: queue the blit; will be sent with ungrabAndFlush().
    s.render.dc.blitQueued();
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
        submitFullRedrawWithTitleReset(s);
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
    const is_fullscreen = actions.fullscreenOccupiedOnWs(@intCast(current_ws));
    const should_show = !is_fullscreen and s.is_globally_visible;
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
        actions.fullscreenOccupiedOnWs(@intCast(current_ws));
    const should_be_visible = !bar_forced_hidden_by_fullscreen and s.is_globally_visible and action != .hide_fullscreen;
    if (s.is_visible == should_be_visible and action != .toggle) return;
    s.is_visible = should_be_visible;
    if (should_be_visible) submitFullRedrawWithTitleReset(s);

    const conn = core.getState().conn;
    const grabbed = action == .toggle;
    if (grabbed) utils.grabServer(conn);
    if (should_be_visible) _ = xcb.xcb_map_window(conn, s.win.win_id) else _ = xcb.xcb_unmap_window(conn, s.win.win_id);
    if (grabbed) { // PIPELINE: WP6 — legacy retileAllWorkspaces deleted
        pipeline.reconcileInGrab();
        ungrabAndFlush();
    } else {
        pipeline.reconcileNow(); // PIPELINE: WP6
    }
    debug.info("Bar {s} ({s})", .{ if (should_be_visible) "shown" else "hidden", @tagName(action) });
}

pub fn updateIfDirty() !void {
    const s = gBar.state orelse return;
    if (!s.is_visible) return;
    if (prompt.consumeRedrawRequest()) {
        gBar.pending_force_full_redraw = true;
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
        gBar.pending_force_full_redraw = true;
        const dragging = if (build_options.has_floating) floating.isDragging() else false;
        if (dragging) s.is_dirty = true else submitDraw();
    };
}

pub fn handlePropertyNotify(event: *const xcb.xcb_property_notify_event_t) void {
    const s = gBar.state orelse return;
    const focused_win = focus.getFocused() orelse return;
    if (event.window != focused_win) return;
    const net_wm_name = s.win.net_wm_name_atom;
    if (event.atom == xcb.XCB_ATOM_WM_NAME or (net_wm_name != 0 and event.atom == net_wm_name)) {
        s.title_cache.is_invalidated = true;
        s.markDirty();
    }
}

// Mouse click handling

/// Routes a ButtonPress on the bar window to whichever segment was clicked.
/// Called from input.zig before its managed-window click path: the bar is
/// never a managed window, so that path would just replay and swallow it.
///
/// Left-clicking a workspace icon switches to it; right-clicking one sends
/// the currently focused window to it. Right-clicking anywhere in the title
/// segment (empty or over any window's title, regardless of that window's
/// state) opens the prompt; left-clicking the title otherwise
/// focuses/minimizes/unminimizes the window shown there.
/// Left/right-clicking the layout indicator cycles the tiling layout
/// forward/backward; left/right-clicking the layout variants indicator
/// cycles the current layout's variant forward/backward the same way.
///
pub fn handleButtonPress(event: *const xcb.xcb_button_press_event_t) void {
    const s = gBar.state orelse return;
    if (!s.is_visible) return;
    if (event.event_x < 0) return;
    const x: u16 = @intCast(event.event_x);

    const left = event.detail == constants.mouse_button_left;
    const right = event.detail == constants.mouse_button_right;
    if (!left and !right) return;

    // D3: hit-test against the recorded segment bounds (same evaluation
    // ORDER as the pre-refactor chain), then delegate behavior to the
    // segment contract's single onClick dispatch.
    const Hit = struct { seg: types.BarSegment, offset: u16 };
    const hit: ?Hit = blk: {
        const lb = &s.layout_cache;
        if (lb.workspaces_bounds.contains(x))
            break :blk Hit{ .seg = .workspaces, .offset = x - lb.workspaces_bounds.x };
        if (s.title_cache.is_layout_valid and
            x >= s.title_cache.title_x and x < s.title_cache.title_x + s.title_cache.title_width)
            break :blk Hit{ .seg = .title, .offset = x - s.title_cache.title_x };
        if (lb.layout_bounds.contains(x))
            break :blk Hit{ .seg = .layout, .offset = 0 };
        if (lb.variants_bounds.contains(x))
            break :blk Hit{ .seg = .variants, .offset = 0 };
        break :blk null;
    };
    const h = hit orelse return;
    _ = segmod.onClick(h.seg, h.offset, left, right, s, titleClickTrampoline, redrawInsideGrab);
}

/// `offset` is the click position relative to the title segment's start.
/// Resolves which window is under the click via the per-window title/geometry
/// data `syncTitleCache` cached on the last full draw, then:
///   - no window under the click -> no-op (empty title is handled by the
///     right-click prompt path in `handleButtonPress`, before this is called)
///   - the window is minimized -> unminimizes that window
///   - the window is already focused -> minimizes it
///   - otherwise -> focuses it
fn handleTitleClick(s: *State, offset: u16) void {
    if (s.title_cache.title_data.workspace_windows.items.len == 0) return;

    const ctx = s.titleCtx(s.title_cache.title_x, s.title_cache.title_width, null, null);
    const snapshot = sn.makeTitleSnapshot(
        s.title_cache.title_data.focused_window,
        "",
        s.title_cache.title_data.workspace_windows.items,
        &s.title_cache.title_data.minimized_windows,
        s.title_cache.title_data.window_titles.list.items,
        s.title_cache.title_data.window_geoms.items,
    );

    const target = (title.hitTest(ctx, snapshot, s.render.allocator, offset) catch |e| {
        debug.warnOnErr(e, "bar title click hitTest");
        return;
    }) orelse return;

    if (minimize.isMinimized(target.window)) { // WP6 — pipeline-only
        actions.restore(&action_ctx, target.window);
    } else if (focus.getFocused() == target.window) {
        actions.minimize(&action_ctx, target.window);
    } else {
        focus.setFocus(target.window, .mouse_click);
    }
}

/// WP6 — shared bar action context for title-click actions.
var action_ctx: actions.Ctx = .{};

fn titleClickTrampoline(ptr: *anyopaque, offset: u16) void {
    const s: *State = @ptrCast(@alignCast(ptr));
    handleTitleClick(s, offset);
}
