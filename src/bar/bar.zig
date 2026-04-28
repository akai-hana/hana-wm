//! Status bar
//! Creates and manages the WM status bar, rendering all configured segments.

const std   = @import("std");
const build = @import("build_options");

// core/
const core      = @import("core");
    const xcb   = core.xcb;
const utils     = @import("utils");
const constants = @import("constants");
const scale     = @import("scale");
const debug     = @import("debug");

// config/
const types = @import("types");

// window/
const tracking   = @import("tracking");
const focus      = @import("focus");
const fullscreen = @import("fullscreen");
const minimize   = @import("minimize");
const workspaces = @import("workspaces");

// floating/
const drag   = @import("drag");
const window = @import("window");

// tiling/
const tiling = @import("tiling");

const drawing  = @import("drawing");
const prompt   = @import("prompt");
const carousel = @import("carousel");


const clock    = @import("clock");
const layout   = @import("layout");
const title    = @import("title");
const variants = @import("variants");
const tags     = @import("tags");

// Low-level threading primitives

/// Blocking mutex backed by pthread_mutex_t; `.{}` is safe (= PTHREAD_MUTEX_INITIALIZER).
const Mutex = struct {
    inner: std.c.pthread_mutex_t = .{},
    pub fn lock(m: *Mutex) void   { _ = std.c.pthread_mutex_lock(&m.inner); }
    pub fn unlock(m: *Mutex) void { _ = std.c.pthread_mutex_unlock(&m.inner); }
};

/// Condition variable backed by pthread_cond_t; `.{}` is safe (= PTHREAD_COND_INITIALIZER).
const Condition = struct {
    inner: std.c.pthread_cond_t = .{},

    pub fn wait(c: *Condition, m: *Mutex) void {
        _ = std.c.pthread_cond_wait(&c.inner, &m.inner);
    }

    /// Waits up to `timeout_ns` nanoseconds; returns error.Timeout on expiry
    /// (CLOCK_REALTIME absolute deadline).
    pub fn timedWait(c: *Condition, m: *Mutex, timeout_ns: u64) error{Timeout}!void {
        var ts: std.os.linux.timespec = undefined;
        _ = std.os.linux.clock_gettime(.REALTIME, &ts);
        const new_nsec = @as(u64, @intCast(ts.nsec)) + timeout_ns;
        ts.sec  += @intCast(new_nsec / std.time.ns_per_s);
        ts.nsec  = @intCast(new_nsec % std.time.ns_per_s);
        const rc = std.c.pthread_cond_timedwait(&c.inner, &m.inner, @ptrCast(&ts));
        if (rc == std.posix.E.TIMEDOUT) return error.Timeout;
    }

    pub fn signal(c: *Condition)    void { _ = std.c.pthread_cond_signal(&c.inner); }
    pub fn broadcast(c: *Condition) void { _ = std.c.pthread_cond_broadcast(&c.inner); }
};

// Public API types

pub const BarAction = enum { toggle, hide_fullscreen, show_fullscreen };

// Constants

const minBarHeight:            u32 = 20;
const maxBarHeight:            u32 = 200;
const defaultBarHeight:        u16 = 24;
const fallbackWorkspacesWidth: u16 = 270;
const layoutWidth:      u16 = 60;
const titleMinWidth:    u16 = 100;

// Core data structures 

/// Point-in-time bar state captured by the main thread and consumed by the bar thread.
const BarSnapshot = struct {
    focused_window:           ?u32                                = null,
    focused_title:            std.ArrayListUnmanaged(u8)          = .empty,
    current_workspace_windows: std.ArrayListUnmanaged(u32)        = .empty,
    minimized_windows:        std.AutoHashMapUnmanaged(u32, void) = .{},
    workspace_has_windows:    std.ArrayListUnmanaged(bool)        = .empty,
    current_workspace:        u8                                  = 0,
    workspace_count:          u32                                 = 0,
    is_all_view_active:       bool                                = false,
    is_title_invalidated:     bool                                = false,
    is_full_redraw:    bool = true,  // workspace_count changed or full-redraw forced
    is_workspace_dirty: bool = true, // workspace state changed
    is_title_dirty:    bool = true,  // title / focus / minimised state changed

    /// Flat buffer of concatenated window titles; pre-fetched on the main thread so
    /// the render thread never makes X11 calls for the segmented-title path.
    /// `window_title_ends[i]` is the exclusive byte offset of the i-th title; use `windowTitle(i)`.
    window_title_data: std.ArrayListUnmanaged(u8)  = .empty,
    window_title_ends: std.ArrayListUnmanaged(u32) = .empty,

    fn deinit(snap: *BarSnapshot, allocator: std.mem.Allocator) void {
        snap.focused_title.deinit(allocator);
        snap.current_workspace_windows.deinit(allocator);
        snap.minimized_windows.deinit(allocator);
        snap.workspace_has_windows.deinit(allocator);
        snap.window_title_data.deinit(allocator);
        snap.window_title_ends.deinit(allocator);
    }

    /// Returns empty slice when `idx` is out of range.
    pub fn windowTitle(snap: *const BarSnapshot, idx: usize) []const u8 {
        if (idx >= snap.window_title_ends.items.len) return "";
        const end: usize   = snap.window_title_ends.items[idx];
        const start: usize = if (idx == 0) 0 else snap.window_title_ends.items[idx - 1];
        return snap.window_title_data.items[start..end];
    }
};

/// Explicit work-item model for the bar render thread.
///
/// All fields are read/written under BarChannel.mutex. `kind` encodes the
/// primary action (mutually exclusive states); `has_clock_tick` is additive
/// and may accompany any non-snap primary action.
const BarWork = struct {
    kind:          Kind = .idle,
    focused_window: ?u32 = null,  // valid only when kind == .focusOnly
    has_clock_tick: bool = false, // additive clock tick; ignored when kind == .snapReady

    const Kind = enum { idle, snapReady, renderOnly, focusOnly, quit };

    fn hasPending(w: BarWork) bool {
        return w.kind != .idle or w.has_clock_tick;
    }
};

/// Double-buffered lock channel between main thread (producer) and bar thread (consumer).
///
/// Main writes into slots[write_index] then flips write_index under mutex;
/// the bar thread reads from slots[1 - write_index].
const BarChannel = struct {
    mutex:     Mutex     = .{},
    work_ready: Condition = .{},
    draw_done:  Condition = .{},
    slots:      [2]BarSnapshot = .{ .{}, .{} },
    write_index: u1  = 0,
    work:        BarWork = .{},
    draw_generation: u64  = 0,
    /// Forces a full bar redraw on the next submitDraw (expose, reload, position toggle, show).
    pending_force_full_redraw: bool = false,
};

/// All atoms needed to declare the bar window as a dock to the compositor.
const BarAtoms = struct {
    strut_partial:    xcb.xcb_atom_t = 0,
    window_type:      xcb.xcb_atom_t = 0,
    window_type_dock: xcb.xcb_atom_t = 0,
    wm_state:         xcb.xcb_atom_t = 0,
    state_above:      xcb.xcb_atom_t = 0,
    state_sticky:     xcb.xcb_atom_t = 0,
    allowed_actions:  xcb.xcb_atom_t = 0,
    action_close:     xcb.xcb_atom_t = 0,
    action_above:     xcb.xcb_atom_t = 0,
    action_stick:     xcb.xcb_atom_t = 0,
};

/// Owns all live bar state.
const Bar = struct {
    channel: BarChannel = .{},
    thread:  ?std.Thread = null,
    state:   ?*State    = null,
    atoms:   BarAtoms   = .{},
};

var gBar: Bar = .{};

// Sub-state types 

/// X11 connection and window handle; stable for the bar's lifetime.
const WindowCtx = struct {
    conn:                  *xcb.xcb_connection_t,
    win_id:                u32,
    colormap:              u32,
    net_wm_name_atom:      xcb.xcb_atom_t,
    last_monitored_window: ?u32 = null,

    fn deinit(self: *WindowCtx) void {
        if (self.last_monitored_window) |win|
            _ = xcb.xcb_change_window_attributes(self.conn, win,
                xcb.XCB_CW_EVENT_MASK, &[_]u32{constants.EventMasks.MANAGED_WINDOW});
        if (self.colormap != 0) _ = xcb.xcb_free_colormap(self.conn, self.colormap);
    }
};

const RenderCtx = struct {
    dc:        *drawing.DrawContext,
    config:    types.BarConfig,
    width:     u16,
    height:    u16,
    allocator: std.mem.Allocator,
};

/// Per-draw layout geometry; invalidated when workspace_count changes or the
/// clock position is reset.
const LayoutCache = struct {
    clock_width:           u16  = 0,
    clock_x:               ?u16 = null,
    workspace_x:           u16  = 0,
    right_section_width:   u16  = 0,
    cached_workspace_count: u32 = std.math.maxInt(u32),
};

/// Focus/title/workspace rendering cache; updated after each full draw.
const TitleCache = struct {
    title:              std.ArrayList(u8)                   = std.ArrayList(u8).empty,
    title_window:       ?u32                                = null,
    focused_window:     ?u32                                = null,
    workspace_windows:  std.ArrayListUnmanaged(u32)         = .empty,
    minimized_windows:  std.AutoHashMapUnmanaged(u32, void) = .{},
    /// Mirrors BarSnapshot.window_title_data/ends; populated by syncTitleCache so
    /// drawTitleOnly can pass cached titles without re-fetching from the X server.
    window_title_data:  std.ArrayListUnmanaged(u8)          = .empty,
    window_title_ends:  std.ArrayListUnmanaged(u32)         = .empty,
    title_x:            u16  = 0,
    title_width:        u16  = 0,
    is_layout_valid:    bool = false,
    is_invalidated:     bool = false,

    fn deinit(self: *TitleCache, allocator: std.mem.Allocator) void {
        self.title.deinit(allocator);
        self.workspace_windows.deinit(allocator);
        self.minimized_windows.deinit(allocator);
        self.window_title_data.deinit(allocator);
        self.window_title_ends.deinit(allocator);
    }
};

// State 

const State = struct {
    win:               WindowCtx,
    render:            RenderCtx,
    layout_cache:      LayoutCache = .{},
    title_cache:       TitleCache  = .{},
    is_visible:        bool = true,
    is_globally_visible: bool = true,
    is_dirty:          bool = false,
    has_clock_segment: bool,
    /// Title geometry captured by drawAllInner; consumed by drawAll/drawAllNoFlush
    /// to call syncTitleCache after the flush decision.
    title_cache_pending_x: ?u16 = null,
    title_cache_pending_w: u16  = 0,

    fn init(
        allocator: std.mem.Allocator,
        conn:      *xcb.xcb_connection_t,
        win_id:    u32,
        colormap:  u32,
        width:     u16,
        height:    u16,
        dc:        *drawing.DrawContext,
        config:    types.BarConfig,
    ) !*State {
        const s = try allocator.create(State);
        s.* = .{
            .win = .{
                .conn             = conn,
                .win_id           = win_id,
                .colormap         = colormap,
                .net_wm_name_atom = utils.getAtomCached("_NET_WM_NAME") catch 0,
            },
            .render = .{
                .dc        = dc,
                .config    = config,
                .width     = width,
                .height    = height,
                .allocator = allocator,
            },
            .layout_cache = .{
                .clock_width = if (build.has_clock)
                    dc.measureTextWidth(clock.CLOCK_MEASURE_STRING) + 2 * config.scaledSegmentPadding(height)
                else
                    0,
            },
            .has_clock_segment = blk: {
                if (!build.has_clock) break :blk false;
                for (config.layout.items) |lay|
                    for (lay.segments.items) |seg|
                        if (seg == .clock) break :blk true;
                break :blk false;
            },
        };
        try s.title_cache.title.ensureTotalCapacity(allocator, 256);
        if (build.has_tags) tags.invalidate();
        return s;
    }

    fn deinit(self: *State) void {
        self.win.deinit();
        self.title_cache.deinit(self.render.allocator);
        self.render.allocator.destroy(self);
    }

    fn markDirty(self: *State) void { self.is_dirty = true; }

    fn invalidateLayoutCache(self: *State) void {
        self.is_dirty             = true;
        self.layout_cache.clock_x = null;
    }

    fn measureSegmentWidth(self: *State, snap: *const BarSnapshot, segment: types.BarSegment) u16 {
        return switch (segment) {
            .workspaces => blk: {
                if (!build.has_tags) break :blk fallbackWorkspacesWidth;
                break :blk if (snap.workspace_count > 0)
                    @intCast(snap.workspace_count * tags.getCachedWorkspaceWidth())
                else
                    fallbackWorkspacesWidth;
            },
            .layout, .variants => layoutWidth,
            .title             => titleMinWidth,
            .clock             => self.layout_cache.clock_width,
        };
    }

    fn drawSegment(self: *State, snap: *const BarSnapshot, segment: types.BarSegment, x: u16, width: ?u16) !u16 {
        if (segment == .workspaces) self.layout_cache.workspace_x = x;
        const r = &self.render;
        return switch (segment) {
            .workspaces => if (build.has_tags) try tags.draw(
                r.dc, r.config, r.height, x,
                snap.current_workspace, snap.workspace_has_windows.items, snap.is_all_view_active)
            else x,
            .layout   => if (build.has_layout)   try layout.draw(r.dc, r.config, r.height, x)   else x,
            .variants => if (build.has_variants)  try variants.draw(r.dc, r.config, r.height, x) else x,
            .title    => blk: {
                const wins = snap.current_workspace_windows.items;
                const minimized_title: []const u8 =
                    if (wins.len > 0 and snap.minimized_windows.contains(wins[0]))
                        snap.windowTitle(0)
                    else
                        "";
                break :blk try prompt.draw(
                    r.dc, r.config, r.height, x, width orelse 100,
                    self.win.conn, snap.focused_window,
                    snap.focused_title.items,
                    minimized_title,
                    snap.current_workspace_windows.items, &snap.minimized_windows,
                    snap.window_title_data.items, snap.window_title_ends.items,
                    &self.title_cache.title, &self.title_cache.title_window,
                    snap.is_title_invalidated, r.allocator);
            },
            .clock    => if (build.has_clock) try clock.draw(r.dc, r.config, r.height, x) else x,
        };
    }

    /// Returns true when `seg` should be skipped because its data has not changed
    /// since the last frame and a full redraw is not required.
    inline fn shouldSkipSegment(snap: *const BarSnapshot, seg: types.BarSegment) bool {
        if (snap.is_full_redraw) return false;
        return switch (seg) {
            .workspaces => !snap.is_workspace_dirty,
            .title      => !snap.is_title_dirty,
            else        => false,
        };
    }

    fn drawRightSegments(self: *State, snap: *const BarSnapshot, segments: []const types.BarSegment) !void {
        var right_x          = self.render.width;
        const scaled_spacing = self.render.config.scaledSpacing(self.render.height);
        // pending_gap: gap space is reserved BEFORE drawing the current segment so its
        // pixel position is correct, then the gap is painted only if the segment drew.
        // If the segment draws nothing, the reserved space is reclaimed.
        var pending_gap = false;
        var i = segments.len;
        while (i > 0) {
            i -= 1;
            const seg_w = self.measureSegmentWidth(snap, segments[i]);
            right_x -= seg_w;
            if (pending_gap) right_x -= scaled_spacing;
            if (segments[i] == .clock) self.layout_cache.clock_x = right_x;
            const drew_to = try self.drawSegment(snap, segments[i], right_x, null);
            const drew    = drew_to != right_x;

            if (drew and pending_gap) {
                self.render.dc.fillRect(right_x + seg_w, 0, scaled_spacing, self.render.height, self.render.config.bg);
            } else if (!drew and pending_gap) {
                right_x += scaled_spacing; // reclaim reserved gap
            }
            pending_gap = drew;
        }
    }

    fn drawAll(self: *State, snap: *const BarSnapshot) !void {
        try self.drawAllInner(snap);
        self.render.dc.blit();
        if (self.title_cache_pending_x) |x|
            self.syncTitleCache(snap, x, self.title_cache_pending_w);
        self.title_cache_pending_x = null;
    }

    /// No dc.blit() — safe to call from inside xcb_grab_server via submitRenderBlocking.
    fn drawAllNoFlush(self: *State, snap: *const BarSnapshot) !void {
        try self.drawAllInner(snap);
        // Cairo surface is flushed to the off-screen pixmap here (pure Cairo op,
        // no XCB traffic on the shared connection).
        self.render.dc.renderOnly();
        if (self.title_cache_pending_x) |x|
            self.syncTitleCache(snap, x, self.title_cache_pending_w);
        self.title_cache_pending_x = null;
    }

    /// Core drawing logic shared by drawAll and drawAllNoFlush; does not flush.
    fn drawAllInner(self: *State, snap: *const BarSnapshot) !void {
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
            self.layout_cache.right_section_width    = right_total;
            self.layout_cache.cached_workspace_count = snap.workspace_count;
        }

        const right_total = self.layout_cache.right_section_width;
        var title_seg_x: u16 = 0;
        var title_seg_w: u16 = 0;
        var x: u16 = 0;

        for (self.render.config.layout.items) |lay| {
            switch (lay.position) {
                .left => for (lay.segments.items) |seg| {
                    const seg_w = self.measureSegmentWidth(snap, seg);
                    if (seg == .title) { title_seg_x = x; title_seg_w = seg_w; }
                    if (shouldSkipSegment(snap, seg)) {
                        x += seg_w + scaled_spacing;
                        continue;
                    }
                    const x_before = x;
                    x = try self.drawSegment(snap, seg, x, null);
                    if (x != x_before) {
                        self.render.dc.fillRect(x, 0, scaled_spacing, self.render.height, self.render.config.bg);
                        x += scaled_spacing;
                    }
                },
                .center => {
                    const remaining = @max(100, self.render.width -| x -| right_total -| scaled_spacing);
                    for (lay.segments.items) |seg| {
                        const w = if (seg == .title) remaining else self.measureSegmentWidth(snap, seg);
                        if (seg == .title) { title_seg_x = x; title_seg_w = w; }
                        if (shouldSkipSegment(snap, seg)) {
                            x += w;
                            if (seg != .title) x += scaled_spacing;
                            continue;
                        }
                        const x_before = x;
                        x = try self.drawSegment(snap, seg, x, w);
                        if (seg != .title and x != x_before) {
                            self.render.dc.fillRect(x, 0, scaled_spacing, self.render.height, self.render.config.bg);
                            x += scaled_spacing;
                        }
                    }
                },
                .right => try self.drawRightSegments(snap, lay.segments.items),
            }
        }

        self.title_cache_pending_x = if (title_seg_w > 0) title_seg_x else null;
        self.title_cache_pending_w = title_seg_w;
    }

    fn drawClockOnly(self: *State) void {
        if (!build.has_clock) return;
        const clock_x = self.layout_cache.clock_x orelse return;
        _ = clock.draw(self.render.dc, self.render.config, self.render.height, clock_x) catch |e|
            debug.warnOnErr(e, "drawClockOnly");
        self.render.dc.blit();
    }

    fn drawTitleOnly(self: *State, new_focused: ?u32) void {
        if (!build.has_title) return;
        if (prompt.isActive()) return;
        if (!self.title_cache.is_layout_valid or self.title_cache.title_width == 0) return;
        self.title_cache.focused_window = new_focused;

        // Fast path: try to blit just the live carousel pixmap without a full Pango layout pass.
        if (carousel.isCarouselActive()) {
            const win_count = self.title_cache.workspace_windows.items.len;
            if (win_count > 1) {
                // Segmented mode: blit the focused segment directly from render.seg.
                // drawSegCarouselTickAuto reads seg_x/seg_w from the stored entry, so no
                // separate coordinate cache is needed here.
                if (carousel.drawSegCarouselTickAuto(self.render.dc,
                        self.render.config.title_accent_color)) return;
            } else {
                // Single-window mode: pass accent so the tick detects a bg change
                // (minimize/unminimize) and returns false to force a full rebuild.
                const accent: u32 = if (win_count == 1 and
                    self.title_cache.minimized_windows.contains(
                        self.title_cache.workspace_windows.items[0]))
                    self.render.config.title_minimized_accent
                else
                    self.render.config.title_accent_color;
                if (carousel.drawCarouselTick(self.render.dc, accent,
                        self.title_cache.title_x, self.title_cache.title_width)) return;
            }
        }

        // title_cache.title holds text for title_cache.title_window (the last full draw).
        // If new_focused differs, that text is stale — drawing it would build the carousel
        // with wrong content and reset start_ms, causing a visible restart on the next frame.
        // A snapReady draw is guaranteed to follow (scheduleFocusRedraw calls markDirty).
        if (new_focused != self.title_cache.title_window) return;

        _ = title.drawCached(
            .{
                .dc      = self.render.dc,
                .config  = self.render.config,
                .height  = self.render.height,
                .start_x = self.title_cache.title_x,
                .width   = self.title_cache.title_width,
                .conn    = self.win.conn,
            },
            .{
                .focused_window    = new_focused,
                .focused_title     = self.title_cache.title.items,
                .minimized_title   = "",
                .current_ws_wins   = self.title_cache.workspace_windows.items,
                .minimized_set     = &self.title_cache.minimized_windows,
                // Supply cached pre-fetched titles so drawSegmentedTitles skips
                // xcb_get_property calls on this fast-path redraw too.
                .window_title_data = self.title_cache.window_title_data.items,
                .window_title_ends = self.title_cache.window_title_ends.items,
            },
            self.render.allocator,
        ) catch |e| { debug.warnOnErr(e, "drawTitleOnly"); return; };
        self.render.dc.blit();
    }

    /// Replacements are built before the swap so a failed allocation leaves the cache
    /// showing stale data rather than going silently empty.
    fn syncTitleCache(self: *State, snap: *const BarSnapshot, x: u16, w: u16) void {
        var new_wins: std.ArrayListUnmanaged(u32) = .empty;
        if (new_wins.appendSlice(self.render.allocator, snap.current_workspace_windows.items)) {
            self.title_cache.workspace_windows.deinit(self.render.allocator);
            self.title_cache.workspace_windows = new_wins;
        } else |_| {
            new_wins.deinit(self.render.allocator);
        }
        if (snap.minimized_windows.clone(self.render.allocator)) |new_set| {
            self.title_cache.minimized_windows.deinit(self.render.allocator);
            self.title_cache.minimized_windows = new_set;
        } else |_| {
            // minimized_windows left stale rather than cleared.
        }

        // Keep cached titles in sync for the drawTitleOnly fast path.
        self.title_cache.window_title_data.clearRetainingCapacity();
        self.title_cache.window_title_data.appendSlice(
            self.render.allocator, snap.window_title_data.items) catch {};
        self.title_cache.window_title_ends.clearRetainingCapacity();
        self.title_cache.window_title_ends.appendSlice(
            self.render.allocator, snap.window_title_ends.items) catch {};

        self.title_cache.focused_window  = snap.focused_window;
        self.title_cache.title_x         = x;
        self.title_cache.title_width     = w;
        self.title_cache.is_layout_valid = true;
    }
};

// Bar thread 

fn runBarThread(s: *State) void {
    var next_carousel_ns: u64 = 0;

    // Re-reads wakeIntervalNs() each advance so a config reload takes effect immediately.
    const advanceCarouselTimer = struct {
        inline fn f(next: *u64) void {
            const interval = carousel.wakeIntervalNs();
            const now = utils.monotonicNs();
            next.* = if (now >= next.*) now + interval else next.* +% interval;
        }
    }.f;

    while (true) {
        gBar.channel.mutex.lock();

        // Sleep until there is something to do or the carousel timer fires.
        while (!gBar.channel.work.hasPending()) {
            if (carousel.isCarouselActive()) {
                const now_ns = utils.monotonicNs();
                if (now_ns >= next_carousel_ns) break;
                const remaining = next_carousel_ns - now_ns;
                gBar.channel.work_ready.timedWait(&gBar.channel.mutex, remaining) catch {};
                break;
            }
            next_carousel_ns = 0;
            gBar.channel.work_ready.wait(&gBar.channel.mutex);
        }

        if (gBar.channel.work.kind == .quit) { gBar.channel.mutex.unlock(); return; }

        // Snapshot the pending work and clear it atomically under the mutex.
        const work      = gBar.channel.work;
        const read_idx: u1 = 1 - gBar.channel.write_index;
        gBar.channel.work = .{};
        gBar.channel.mutex.unlock();

        switch (work.kind) {
            .snapReady => {
                // Full draw covers the clock too — ignore work.has_clock_tick.
                s.drawAll(&gBar.channel.slots[read_idx]) catch |e|
                    debug.warnOnErr(e, "bar thread drawAll");
                gBar.channel.mutex.lock();
                gBar.channel.draw_generation +%= 1;
                gBar.channel.draw_done.broadcast();
                gBar.channel.mutex.unlock();
            },
            .renderOnly => {
                // No xcb_copy_area, no xcb_flush — caller queues the blit via
                // dc.blitQueued() so it is sent atomically with ungrabAndFlush().
                s.drawAllNoFlush(&gBar.channel.slots[read_idx]) catch |e|
                    debug.warnOnErr(e, "bar thread drawAllNoFlush");
                gBar.channel.mutex.lock();
                gBar.channel.draw_generation +%= 1;
                gBar.channel.draw_done.broadcast();
                gBar.channel.mutex.unlock();
            },
            .focusOnly => {
                s.drawTitleOnly(work.focused_window);
                if (carousel.isCarouselActive()) advanceCarouselTimer(&next_carousel_ns);
                if (work.has_clock_tick) s.drawClockOnly();
            },
            .idle => {
                // Carousel tick or clock-only wakeup with no focus change.
                if (carousel.isCarouselActive()) {
                    s.drawTitleOnly(s.title_cache.focused_window);
                    advanceCarouselTimer(&next_carousel_ns);
                }
                if (work.has_clock_tick) s.drawClockOnly();
            },
            .quit => unreachable,
        }
    }
}

inline fn spawnBarThread(s: *State) void {
    gBar.thread = std.Thread.spawn(.{}, runBarThread, .{s}) catch |e| {
        debug.warnOnErr(e, "Failed to start bar render thread"); return;
    };
}

/// Signals the bar thread to quit and waits for it to exit.
fn joinBarThread() void {
    gBar.channel.mutex.lock();
    gBar.channel.work = .{ .kind = .quit };
    gBar.channel.work_ready.signal();
    gBar.channel.mutex.unlock();
    if (gBar.thread) |t| { t.join(); gBar.thread = null; }
    gBar.channel.work = .{};  // reset for potential re-use after reload
}

// Snapshot capture 

/// Returns true when the two minimised sets differ in membership (not just count).
fn hasMinimizedSetChanged(
    a: *const std.AutoHashMapUnmanaged(u32, void),
    b: *const std.AutoHashMapUnmanaged(u32, void),
) bool {
    if (a.count() != b.count()) return true;
    var it = a.keyIterator();
    while (it.next()) |key| if (!b.contains(key.*)) return true;
    return false;
}

/// Captures current WM state into `snap`, diffing against `prev` to set dirty flags.
/// `forced` (caller must read and clear `pending_force_full_redraw`) overrides all dirty checks.
fn captureStateIntoSlot(s: *State, snap: *BarSnapshot, prev: *const BarSnapshot, forced: bool) !void {
    const allocator = s.render.allocator;
    snap.minimized_windows.clearRetainingCapacity();
    if (build.has_minimize)
        try minimize.collectMinimizedIntoSet(&snap.minimized_windows, allocator);

    if (build.has_workspaces) {
        const ws_state = workspaces.getState() orelse return;
        snap.workspace_count      = @intCast(ws_state.workspaces.len);
        snap.current_workspace    = ws_state.current;
        snap.is_all_view_active   = ws_state.all_view_temp_wins.items.len > 0;
        try snap.workspace_has_windows.resize(allocator, snap.workspace_count);
        for (ws_state.workspaces, 0..) |_, i|
            snap.workspace_has_windows.items[i] = tracking.hasWindowsOnWorkspace(@intCast(i));
        snap.current_workspace_windows.clearRetainingCapacity();
        if (ws_state.current < ws_state.workspaces.len) {
            const cur_bit = tracking.workspaceBit(ws_state.current);
            for (tracking.allWindows()) |entry| {
                if (entry.mask & cur_bit != 0)
                    try snap.current_workspace_windows.append(allocator, entry.win);
            }
        }
    } else {
        // No workspace subsystem — use workspace_count=1 so the first draw sees
        // a count change and triggers is_full_redraw to clear the background.
        snap.workspace_count = 1;
        snap.current_workspace_windows.clearRetainingCapacity();
        for (tracking.allWindows()) |entry|
            try snap.current_workspace_windows.append(allocator, entry.win);
    }

    snap.focused_window      = focus.getFocused();
    snap.is_title_invalidated = s.title_cache.is_invalidated;
    s.title_cache.is_invalidated = false;

    snap.focused_title.clearRetainingCapacity();
    if (build.has_title) if (snap.focused_window) |fw| {
        if (snap.focused_window != prev.focused_window or snap.is_title_invalidated) {
            title.fetchWindowTitleInto(core.conn, fw, &snap.focused_title, allocator) catch {};
        } else {
            snap.focused_title.appendSlice(allocator, prev.focused_title.items) catch {};
        }
    };

    // Pre-fetch titles on the main thread so the render thread never issues X11 calls.
    // IMPORTANT: fetchWindowTitleInto replaces its buffer, so each non-focused window
    // must be fetched into a temporary buffer and appended — not fetched directly into
    // window_title_data, which would overwrite all previously stored titles.
    snap.window_title_data.clearRetainingCapacity();
    snap.window_title_ends.clearRetainingCapacity();
    {
        var title_tmp: std.ArrayListUnmanaged(u8) = .empty;
        defer title_tmp.deinit(allocator);
        for (snap.current_workspace_windows.items) |win| {
            if (build.has_title) {
                if (snap.focused_window == win) {
                    snap.window_title_data.appendSlice(allocator, snap.focused_title.items) catch {};
                } else {
                    title_tmp.clearRetainingCapacity();
                    title.fetchWindowTitleInto(core.conn, win, &title_tmp, allocator) catch {};
                    snap.window_title_data.appendSlice(allocator, title_tmp.items) catch {};
                }
            }
            const end: u32 = @intCast(snap.window_title_data.items.len);
            snap.window_title_ends.append(allocator, end) catch {};
        }
    }

    snap.is_full_redraw = forced or (snap.workspace_count != prev.workspace_count);
    snap.is_workspace_dirty = snap.is_full_redraw or
        snap.current_workspace  != prev.current_workspace   or
        snap.is_all_view_active != prev.is_all_view_active  or
        !std.mem.eql(bool, snap.workspace_has_windows.items, prev.workspace_has_windows.items);
    snap.is_title_dirty =
        prompt.isActive() or
        snap.focused_window        != prev.focused_window        or
        snap.is_title_invalidated                                or
        !std.mem.eql(u8,  snap.focused_title.items,              prev.focused_title.items)             or
        !std.mem.eql(u32, snap.current_workspace_windows.items,  prev.current_workspace_windows.items) or
        hasMinimizedSetChanged(&snap.minimized_windows, &prev.minimized_windows);
}

// Draw submission 

fn submitDrawBlockingFull() void {
    gBar.channel.pending_force_full_redraw = true;
    submitDrawBlocking();
}

inline fn ungrabAndFlush() void { utils.ungrabAndFlush(core.conn); }

// Returns the write_index that was captured (and already flipped into the slot)
// on success, or null if the bar is not visible or capture failed.
fn prepareSnapshot() ?u1 {
    const s = gBar.state orelse return null;
    if (!s.is_visible) return null;
    const idx = gBar.channel.write_index;
    const forced = gBar.channel.pending_force_full_redraw;
    gBar.channel.pending_force_full_redraw = false;
    captureStateIntoSlot(s, &gBar.channel.slots[idx], &gBar.channel.slots[1 - idx], forced) catch |e| {
        debug.warnOnErr(e, "bar captureStateIntoSlot");
        return null;
    };
    return idx;
}

pub fn submitDraw() void {
    if (prepareSnapshot() == null) return;
    gBar.channel.mutex.lock();
    defer gBar.channel.mutex.unlock();
    gBar.channel.write_index  ^= 1;
    gBar.channel.work.kind     = .snapReady;
    gBar.channel.work_ready.signal();
}

/// Blocks until draw completes. Use only inside or immediately before xcb_ungrab_server.
pub fn submitDrawBlocking() void {
    if (prepareSnapshot() == null) return;
    gBar.channel.mutex.lock();
    defer gBar.channel.mutex.unlock();
    gBar.channel.write_index ^= 1;
    gBar.channel.work.kind    = .snapReady;
    const gen_before = gBar.channel.draw_generation;
    gBar.channel.work_ready.signal();
    while (gBar.channel.draw_generation == gen_before)
        gBar.channel.draw_done.wait(&gBar.channel.mutex);
}

/// Like submitDrawBlocking but renders only — no xcb_copy_area, no xcb_flush.
/// Use INSIDE xcb_grab_server; pair with dc.blitQueued() + ungrabAndFlush().
fn submitRenderBlocking() void {
    if (prepareSnapshot() == null) return;
    gBar.channel.mutex.lock();
    defer gBar.channel.mutex.unlock();
    gBar.channel.write_index ^= 1;
    gBar.channel.work.kind    = .renderOnly;
    const gen_before = gBar.channel.draw_generation;
    gBar.channel.work_ready.signal();
    while (gBar.channel.draw_generation == gen_before)
        gBar.channel.draw_done.wait(&gBar.channel.mutex);
}

// Window and atom setup 

fn initAtoms() void {
    const entries = .{
        .{ "strut_partial",    "_NET_WM_STRUT_PARTIAL"    },
        .{ "window_type",      "_NET_WM_WINDOW_TYPE"      },
        .{ "window_type_dock", "_NET_WM_WINDOW_TYPE_DOCK" },
        .{ "wm_state",         "_NET_WM_STATE"            },
        .{ "state_above",      "_NET_WM_STATE_ABOVE"      },
        .{ "state_sticky",     "_NET_WM_STATE_STICKY"     },
        .{ "allowed_actions",  "_NET_WM_ALLOWED_ACTIONS"  },
        .{ "action_close",     "_NET_WM_ACTION_CLOSE"     },
        .{ "action_above",     "_NET_WM_ACTION_ABOVE"     },
        .{ "action_stick",     "_NET_WM_ACTION_STICK"     },
    };
    inline for (entries) |e|
        @field(gBar.atoms, e[0]) = utils.getAtomCached(e[1]) catch 0;
}

fn calcBarYPos(height: u16) i16 {
    return if (core.config.bar.bar_position == .bottom)
        @intCast(@as(i32, core.screen.height_in_pixels) - height)
    else
        0;
}

const BarWindowSetup = struct { win_id: u32, visual_id: u32, has_argb: bool, colormap: u32 };

fn createBarWindow(height: u16, y_pos: i16) BarWindowSetup {
    const want_transparency = core.config.bar.getAlpha16() < 0xFFFF;
    const visual_info = if (want_transparency)
        drawing.findVisualByDepth(core.screen, 32)
    else
        drawing.VisualInfo{ .visual_type = null, .visual_id = core.screen.root_visual };
    const depth: u8      = if (want_transparency) 32 else xcb.XCB_COPY_FROM_PARENT;
    const visual_id      = visual_info.visual_id;
    const colormap: u32  = if (want_transparency) blk: {
        const cmap = xcb.xcb_generate_id(core.conn);
        _ = xcb.xcb_create_colormap(core.conn, xcb.XCB_COLORMAP_ALLOC_NONE, cmap, core.screen.root, visual_id);
        break :blk cmap;
    } else 0;
    const win_id     = xcb.xcb_generate_id(core.conn);
    const value_mask = xcb.XCB_CW_BACK_PIXEL | xcb.XCB_CW_BORDER_PIXEL |
                       xcb.XCB_CW_OVERRIDE_REDIRECT | xcb.XCB_CW_EVENT_MASK |
                       if (want_transparency) xcb.XCB_CW_COLORMAP else 0;
    const base_events = xcb.XCB_EVENT_MASK_EXPOSURE | xcb.XCB_EVENT_MASK_BUTTON_PRESS;
    const value_list  = [5]u32{ 0, 0, 1, base_events, colormap };
    _ = xcb.xcb_create_window(core.conn, depth, win_id, core.screen.root,
        0, y_pos, core.screen.width_in_pixels, height, 0,
        xcb.XCB_WINDOW_CLASS_INPUT_OUTPUT, visual_id,
        @intCast(value_mask), &value_list);
    return .{ .win_id = win_id, .visual_id = visual_id, .has_argb = want_transparency, .colormap = colormap };
}

fn loadBarFonts(dc: anytype) !void {
    const cfg         = core.config.bar;
    const alloc       = core.alloc;
    const scaled_size = cfg.scaled_font_size;
    const fonts       = cfg.fonts.items;
    if (fonts.len == 0) return;
    const sized = try alloc.alloc([]const u8, fonts.len);
    defer {
        for (sized, fonts) |s, orig| if (s.ptr != orig.ptr) alloc.free(s);
        alloc.free(sized);
    }
    for (fonts, sized) |f, *out| {
        out.* = if (scaled_size > 0)
            try std.fmt.allocPrint(alloc, "{s}:size={}", .{ f, scaled_size })
        else
            f;
    }
    return dc.loadFonts(sized);
}

/// Set an EWMH atom property on the bar window.
fn setAtomProperty(conn: *xcb.xcb_connection_t, win_id: u32, prop: u32, atom_type: u32, values: anytype) void {
    _ = xcb.xcb_change_property(conn, xcb.XCB_PROP_MODE_REPLACE, win_id, prop, atom_type,
        32, @intCast(values.len), values.ptr);
}

fn setWindowProperties(win_id: u32, height: u16) void {
    const strut: [12]u32 = if (core.config.bar.bar_position == .top)
        .{ 0, 0, 0, height, 0, 0, 0, 0, 0, 0, 0, core.screen.width_in_pixels }
    else
        .{ 0, 0, height, 0, 0, 0, 0, 0, 0, core.screen.width_in_pixels, 0, 0 };
    if (gBar.atoms.strut_partial    != 0) setAtomProperty(core.conn, win_id, gBar.atoms.strut_partial,    xcb.XCB_ATOM_CARDINAL, &strut);
    if (gBar.atoms.window_type      != 0) setAtomProperty(core.conn, win_id, gBar.atoms.window_type,      xcb.XCB_ATOM_ATOM, &[_]u32{gBar.atoms.window_type_dock});
    if (gBar.atoms.wm_state         != 0) setAtomProperty(core.conn, win_id, gBar.atoms.wm_state,         xcb.XCB_ATOM_ATOM, &[_]u32{gBar.atoms.state_above, gBar.atoms.state_sticky});
    if (gBar.atoms.allowed_actions  != 0) setAtomProperty(core.conn, win_id, gBar.atoms.allowed_actions,  xcb.XCB_ATOM_ATOM, &[_]u32{gBar.atoms.action_close, gBar.atoms.action_above, gBar.atoms.action_stick});
}

fn measureFontMetrics() ?struct { asc: i32, desc: i32 } {
    var mc = drawing.MeasureContext.init(core.alloc, core.dpi_info.dpi) catch return null;
    defer mc.deinit();
    loadBarFonts(&mc) catch return null;
    const asc, const desc = mc.getMetrics();
    return .{ .asc = asc, .desc = desc };
}

fn resolvePercentageFontSize(bar_height: u16) ?u16 {
    const trialPt: u16 = 100;
    const saved_size = core.config.bar.scaled_font_size;
    core.config.bar.scaled_font_size = trialPt;
    defer core.config.bar.scaled_font_size = saved_size;
    const m = measureFontMetrics() orelse return null;
    const px_per_pt: f32 = @as(f32, @floatFromInt(@max(1, m.asc + m.desc))) / @as(f32, @floatFromInt(trialPt));
    const max_size_pt    = @as(f32, @floatFromInt(bar_height)) / px_per_pt;
    return @max(1, @as(u16, @intFromFloat(@round(max_size_pt * (core.config.bar.font_size.value / 100.0)))));
}

fn calcBarHeight() !u16 {
    if (core.config.bar.height) |h| {
        const height = if (build.has_scale) scale.scaleBarHeight(h, core.screen.height_in_pixels) else blk: {
            const screen_h: f32 = @floatFromInt(core.screen.height_in_pixels);
            const px: f32 = if (h.is_percentage) screen_h * (h.value / 100.0) else h.value;
            break :blk @max(20, @as(u16, @intFromFloat(@round(px))));
        };
        if (core.config.bar.font_size.is_percentage) {
            if (resolvePercentageFontSize(height)) |sz|
                core.config.bar.scaled_font_size = sz;
        }
        return height;
    }
    const m = measureFontMetrics() orelse return defaultBarHeight;
    return @intCast(std.math.clamp(@as(u32, @intCast(m.asc + m.desc)), minBarHeight, maxBarHeight));
}

fn createDrawContext(setup: BarWindowSetup, height: u16) !*drawing.DrawContext {
    const dc = try drawing.DrawContext.initWithVisual(
        core.alloc, core.conn, setup.win_id, core.screen.width_in_pixels, height,
        setup.visual_id, core.dpi_info.dpi, setup.has_argb, core.config.bar.transparency,
    );
    errdefer dc.deinit();
    try loadBarFonts(dc);
    return dc;
}

// Lifecycle 

pub fn init() !void {
    std.debug.assert(core.config.bar.enabled);
    initAtoms();
    // Detect refresh rate before the bar thread spawns so carousel.wakeIntervalNs()
    // returns the real rate from the first tick.
    if (build.has_scale) scale.ensureRefreshRateDetected(core.conn);
    const height = try calcBarHeight();
    const y_pos  = calcBarYPos(height);
    const setup  = createBarWindow(height, y_pos);
    errdefer {
        _ = xcb.xcb_destroy_window(core.conn, setup.win_id);
        if (setup.colormap != 0) _ = xcb.xcb_free_colormap(core.conn, setup.colormap);
    }
    setWindowProperties(setup.win_id, height);
    const dc = try createDrawContext(setup, height);
    errdefer dc.deinit();
    debug.info("Bar transparency: {s}", .{if (setup.has_argb) "enabled (ARGB)" else "disabled (opaque)"});
    gBar.state = try State.init(core.alloc, core.conn, setup.win_id, setup.colormap,
        core.screen.width_in_pixels, height, dc, core.config.bar);
    spawnBarThread(gBar.state.?);
    submitDrawBlocking();
    _ = xcb.xcb_map_window(core.conn, setup.win_id);
    _ = xcb.xcb_flush(core.conn);
    try prompt.init(core.alloc, core.conn);
}

pub fn deinit() void {
    prompt.deinit();
    joinBarThread();
    if (gBar.state) |s| {
        carousel.deinitCarousel();
        for (&gBar.channel.slots) |*slot| slot.deinit(s.render.allocator);
        _ = xcb.xcb_destroy_window(s.win.conn, s.win.win_id);
        s.render.dc.deinit();
        drawing.deinitFontCache(s.render.allocator);
        s.deinit();
        gBar.state = null;
    }
}

pub fn reload() void {
    const old = gBar.state orelse {
        if (core.config.bar.enabled) {
            init() catch |err| debug.err("Bar init failed: {}", .{err});
        }
        return;
    };
    if (!core.config.bar.enabled) { deinit(); return; }
    const height = calcBarHeight() catch defaultBarHeight;
    const y_pos  = calcBarYPos(height);
    const setup  = createBarWindow(height, y_pos);
    applyReload(old, setup, height) catch |err| {
        _ = xcb.xcb_destroy_window(core.conn, setup.win_id);
        if (setup.colormap != 0) _ = xcb.xcb_free_colormap(core.conn, setup.colormap);
        debug.err("Bar reload failed ({s}), keeping old bar", .{@errorName(err)});
    };
}

fn applyReload(old: *State, setup: BarWindowSetup, height: u16) !void {
    setWindowProperties(setup.win_id, height);
    const new_dc = try createDrawContext(setup, height);
    errdefer new_dc.deinit();
    const new_state = try State.init(core.alloc, core.conn, setup.win_id, setup.colormap,
        core.screen.width_in_pixels, height, new_dc, core.config.bar);
    new_state.is_visible          = old.is_visible;
    new_state.is_globally_visible = old.is_globally_visible;
    joinBarThread();
    gBar.state = new_state;
    spawnBarThread(new_state);
    submitDrawBlockingFull();
    if (new_state.is_visible) _ = xcb.xcb_map_window(core.conn, setup.win_id);
    _ = xcb.xcb_destroy_window(core.conn, old.win.win_id);
    ungrabAndFlush();
    old.render.dc.deinit();
    old.deinit();
}

// Public event handlers & queries 

pub fn toggleBarSegmentAnchor() void {
    const s = gBar.state orelse return;
    core.config.bar.bar_position = switch (core.config.bar.bar_position) {
        .top    => .bottom,
        .bottom => .top,
    };
    const new_y = calcBarYPos(s.render.height);
    setWindowProperties(s.win.win_id, s.render.height);
    gBar.channel.pending_force_full_redraw = true;
    s.invalidateLayoutCache();
    _ = xcb.xcb_grab_server(core.conn);
    _ = xcb.xcb_configure_window(core.conn, s.win.win_id, xcb.XCB_CONFIG_WINDOW_Y,
        &[_]u32{@as(u32, @bitCast(@as(i32, new_y)))});
    const current_ws = tracking.getCurrentWorkspace() orelse {
        window.updateWorkspaceBorders();
        window.markBordersFlushed();
        ungrabAndFlush();
        return;
    };
    const no_fullscreen = if (build.has_fullscreen)
        fullscreen.getForWorkspace(current_ws) == null
    else
        true;
    if (no_fullscreen)
        if (build.has_tiling) tiling.retileCurrentWorkspace();
    window.updateWorkspaceBorders();
    window.markBordersFlushed();
    ungrabAndFlush();
    debug.info("Bar position toggled to: {s}", .{@tagName(core.config.bar.bar_position)});
}

/// Lightweight focus-only redraw; skipped when a full redraw is already pending.
pub fn scheduleFocusRedraw(new_win: ?u32) void {
    const s = gBar.state orelse return;
    if (!s.is_visible or s.is_dirty) return;
    gBar.channel.mutex.lock();
    // Only post a focus update when no higher-priority work is already queued.
    if (gBar.channel.work.kind == .idle) {
        gBar.channel.work = .{ .kind = .focusOnly, .focused_window = new_win };
        gBar.channel.work_ready.signal();
    }
    gBar.channel.mutex.unlock();
    // markDirty ensures a snapReady draw follows, which fetches the new window's title
    // and rebuilds the carousel correctly. Without it, a cross-window focus change with
    // no other dirty state would rely solely on the stale-title focusOnly path —
    // the combination that triggers the double-start flicker drawTitleOnly guards against.
    s.markDirty();
}

pub fn isBarWindow(win: u32) bool  { return if (gBar.state) |s| s.win.win_id == win else false; }
pub fn getBarHeight() u16          { return if (gBar.state) |s| s.render.height else 0; }
pub fn hasClockSegment() bool      { return if (gBar.state) |s| s.has_clock_segment else false; }

/// Schedules a full bar redraw, coalesced via updateIfDirty. Zero X11 I/O on the caller.
pub fn scheduleRedraw() void       { if (gBar.state) |s| if (s.is_visible) s.markDirty(); }

/// Like scheduleRedraw but forces a full bar clear+redraw regardless of dirty flags.
///
/// Use when a segment's presence or width changes (e.g. layout switch) so stale
/// pixels from the previous render are guaranteed to be erased.
pub fn scheduleFullRedraw() void {
    if (gBar.state) |s| if (s.is_visible) {
        gBar.channel.pending_force_full_redraw = true;
        s.markDirty();
    };
}

pub fn isVisible() bool              { return if (gBar.state) |s| s.is_visible else false; }

/// Synchronous bar update safe to call inside xcb_grab_server.
///
/// Phase 1 (inside grab): render to the off-screen pixmap — cairo_surface_flush only,
/// no xcb_copy_area, no xcb_flush, so the compositor sees no intermediate frame.
/// Phase 2 (still inside grab): blitQueued() enqueues xcb_copy_area without flushing.
///
/// configure_window + xcb_copy_area + xcb_ungrab_server are sent in one flush by
/// the caller's ungrabAndFlush(), producing exactly one compositor frame.
pub fn redrawInsideGrab() void {
    const s = gBar.state orelse return;
    if (!s.is_visible) return;
    // Phase 1: render to pixmap without any XCB flush.
    submitRenderBlocking();
    // Phase 2: queue the blit — will be sent with ungrabAndFlush().
    s.render.dc.blitQueued();
    s.is_dirty = false;
}

pub fn raiseBar() void {
    if (gBar.state) |s|
        _ = xcb.xcb_configure_window(s.win.conn, s.win.win_id,
            xcb.XCB_CONFIG_WINDOW_STACK_MODE, &[_]u32{xcb.XCB_STACK_MODE_ABOVE});
}

pub fn setBarState(action: BarAction) void {
    const s = gBar.state orelse return;
    if (action == .toggle) s.is_globally_visible = !s.is_globally_visible;
    const current_ws    = tracking.getCurrentWorkspace() orelse 0;
    const is_fullscreen = action != .hide_fullscreen and
        (comptime build.has_fullscreen) and fullscreen.getForWorkspace(current_ws) != null;
    const show = !is_fullscreen and s.is_globally_visible and action != .hide_fullscreen;
    if (s.is_visible == show and action != .toggle) return;
    s.is_visible = show;
    if (action == .toggle) {
        if (show) {
            s.title_cache.is_invalidated = true; // force carousel reset from pos 0 on re-show
            submitDrawBlockingFull();
        }
        _ = xcb.xcb_grab_server(core.conn);
        if (show) _ = xcb.xcb_map_window(core.conn, s.win.win_id)
        else      _ = xcb.xcb_unmap_window(core.conn, s.win.win_id);
        const saved = s.is_visible;
        if (is_fullscreen) s.is_visible = s.is_globally_visible;
        retileAllWorkspaces();
        if (is_fullscreen) s.is_visible = saved;
        window.updateWorkspaceBorders();
        window.markBordersFlushed();
        ungrabAndFlush();
    } else {
        if (show) {
            s.title_cache.is_invalidated = true; // force carousel reset from pos 0 on re-show
            submitDrawBlockingFull();
            _ = xcb.xcb_map_window(core.conn, s.win.win_id);
        } else {
            _ = xcb.xcb_unmap_window(core.conn, s.win.win_id);
        }
        if (build.has_tiling) tiling.retileCurrentWorkspace();
    }
    debug.info("Bar {s} ({s})", .{ if (show) "shown" else "hidden", @tagName(action) });
    if (build.has_clock) clock.updateTimerState();
}

pub fn updateIfDirty() !void {
    const s = gBar.state orelse return;
    if (!s.is_visible) return;
    if (prompt.consumeRedrawRequest()) {
        gBar.channel.pending_force_full_redraw = true;
        s.is_dirty = true;
    }
    if (s.is_dirty) { submitDraw(); s.is_dirty = false; }
}

pub fn checkClockUpdate() bool {
    const s = gBar.state orelse return false;
    if (!s.is_visible) return false;
    gBar.channel.mutex.lock();
    gBar.channel.work.has_clock_tick = true;
    gBar.channel.work_ready.signal();
    gBar.channel.mutex.unlock();
    return true;
}

pub fn pollTimeoutMs() i32     { return if (build.has_clock) clock.pollTimeoutMs() else -1; }
pub fn updateTimerState() void { if (build.has_clock) clock.updateTimerState(); }

pub fn handleExpose(event: *const xcb.xcb_expose_event_t) void {
    if (gBar.state) |s| if (event.window == s.win.win_id and event.count == 0) {
        gBar.channel.pending_force_full_redraw = true;
        if (drag.isDragging()) s.is_dirty = true else submitDraw();
    };
}

pub fn handlePropertyNotify(event: *const xcb.xcb_property_notify_event_t) void {
    const s           = gBar.state orelse return;
    const focused_win = focus.getFocused() orelse return;
    if (event.window != focused_win) return;
    const net_wm_name = s.win.net_wm_name_atom;
    if (event.atom == xcb.XCB_ATOM_WM_NAME or (net_wm_name != 0 and event.atom == net_wm_name)) {
        s.title_cache.is_invalidated = true;
        s.markDirty();
    }
}

pub fn handleButtonPress(event: *const xcb.xcb_button_press_event_t) void {
    const s = gBar.state orelse return;
    if (event.event != s.win.win_id) return;
    if (!build.has_workspaces) return;
    if (!build.has_tags) return;
    const ws_state = workspaces.getState() orelse return;
    const ws_w     = tags.getCachedWorkspaceWidth();
    if (ws_w == 0) return;
    const click_x           = @max(0, event.event_x - s.layout_cache.workspace_x);
    const clicked_ws: usize = @intCast(@divFloor(click_x, ws_w));
    if (clicked_ws >= ws_state.workspaces.len) return;
    switchToWorkspace(clicked_ws);
    s.markDirty();
}

inline fn switchToWorkspace(ws_arg: u8) void {
    if (build.has_workspaces) workspaces.switchTo(ws_arg);
}

fn isTilingActive() bool {
    if (!build.has_tiling) return false;
    return core.config.tiling.enabled and
        if (tiling.getStateOpt()) |t| t.is_enabled else false;
}

/// Must be called without holding the X server grab.
fn retileAllWorkspaces() void {
    if (!build.has_tiling) return;
    if (!build.has_workspaces) { tiling.retileCurrentWorkspace(); return; }
    const ws_state = workspaces.getState() orelse return;
    if (!isTilingActive()) { tiling.retileCurrentWorkspace(); return; }
    for (ws_state.workspaces, 0..) |_, idx| {
        if (!tracking.hasWindowsOnWorkspace(@intCast(idx))) continue;
        if (build.has_fullscreen) {
            if (fullscreen.getForWorkspace(@intCast(idx)) != null) continue;
        }
        if (@as(u8, @intCast(idx)) != ws_state.current) {
            tiling.retileInactiveWorkspace(@intCast(idx));
            continue;
        }
        tiling.retileCurrentWorkspace();
    }
}
