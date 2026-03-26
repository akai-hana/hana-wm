//! Status bar: renders segments via Cairo/Pango into an XCB override-redirect window.
//!
//! A dedicated bar thread owns the DrawContext and all rendering. The main thread
//! captures a lightweight BarSnapshot and posts it to a BarChannel; the bar thread
//! wakes, draws, and loops. Draws that must complete before the caller returns (e.g.
//! inside xcb_grab_server) use redrawInsideGrab(), which blocks until done.
//!
//! Clock-only updates bypass the snapshot path: the bar thread redraws just the
//! clock segment using its cached x-position.
//!
//! Error-handling policy
//! ---------------------
//! - Draw errors on the bar thread are always logged and non-fatal (the thread must
//!   not crash; the next frame will retry).
//! - Allocation errors during snapshot capture are propagated to submitDraw, which
//!   logs them and skips the frame.
//! - Cache-update failures leave the cache stale, never empty (see updateTitleCache).
const std        = @import("std");
const core       = @import("core");
const xcb        = core.xcb;
const debug      = @import("debug");
const windowTest = @import("window");


const build_options = @import("build_options");

/// Blocking mutex backed by pthread_mutex_t; `.{}` is safe (= PTHREAD_MUTEX_INITIALIZER).
const Mutex = struct {
    inner: std.c.pthread_mutex_t = .{},
    pub fn lock(m: *Mutex) void {
        _ = std.c.pthread_mutex_lock(&m.inner);
    }
    pub fn unlock(m: *Mutex) void {
        _ = std.c.pthread_mutex_unlock(&m.inner);
    }
};

/// Condition variable backed by pthread_cond_t; `.{}` is safe (= PTHREAD_COND_INITIALIZER).
const Condition = struct {
    inner: std.c.pthread_cond_t = .{},
    pub fn wait(c: *Condition, m: *Mutex) void {
        _ = std.c.pthread_cond_wait(&c.inner, &m.inner);
    }

    /// Waits up to `timeout_ns` ns; returns error.Timeout on expiry (CLOCK_REALTIME absolute deadline).
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

pub const BarAction = enum { toggle, hide_fullscreen, show_fullscreen };

const drawing    = @import("drawing");
const tiling     = if (build_options.has_tiling) @import("tiling") else struct {};
const drag       = @import("drag");
const utils      = @import("utils");
const tracking   = @import("tracking");
const workspaces = if (build_options.has_workspaces) @import("workspaces") else struct {};
const WsState    = if (build_options.has_workspaces) workspaces.State else struct {};
fn wsGetState() ?*WsState              { return if (comptime build_options.has_workspaces) workspaces.getState() else null; }
inline fn wsSwitchTo(ws_arg: u8) void  { if (comptime build_options.has_workspaces) workspaces.switchTo(ws_arg); }
const focus      = @import("focus");
const constants  = @import("constants");
const minimize   = if (build_options.has_minimize) @import("minimize") else struct {};
const scale      = if (build_options.has_scale) @import("scale") else struct {
    pub fn scaleBarHeight(value: anytype, screen_height: u16) u16 {
        const h: f32 = @floatFromInt(screen_height);
        const px: f32 = if (value.is_percentage) h * (value.value / 100.0) else value.value;
        return @max(20, @as(u16, @intFromFloat(@round(px))));
    }
};

const workspaces_segment = if (build_options.has_tags) @import("tags") else struct {
    pub fn draw(_: *drawing.DrawContext, _: core.BarConfig, _: u16, x: u16, _: u8, _: []const bool, _: bool) !u16 { return x; }
    pub fn invalidate() void {}
    pub fn getCachedWorkspaceWidth() u16 { return 0; }
};

const drawStub = struct {
    pub fn draw(_: *drawing.DrawContext, _: core.BarConfig, _: u16, x: u16) !u16 { return x; }
};
const layout_segment   = if (build_options.has_layout)   @import("layout")   else drawStub;
const variants_segment = if (build_options.has_variants) @import("variants") else drawStub;

const prompt     = @import("prompt");
const fullscreen = if (build_options.has_fullscreen) @import("fullscreen") else struct {};
const carousel   = @import("carousel");

const title_segment = if (build_options.has_title) @import("title") else struct {
    pub fn draw(
        _: *drawing.DrawContext, _: core.BarConfig, _: u16,
        x: u16, w: u16,
        _: *xcb.xcb_connection_t, _: ?u32,
        _: []const u32, _: []const u32,
        _: *std.ArrayList(u8), _: *?u32,
        _: bool, _: std.mem.Allocator,
    ) !u16 { return x + w; }
};

const clock_segment = if (build_options.has_clock) @import("clock") else struct {
    pub const SAMPLE_STRING: []const u8 = "";
    pub fn draw(_: *drawing.DrawContext, _: core.BarConfig, _: u16, x: u16) !u16 { return x; }
    pub fn setTimerFd(_: i32) void {}
    pub fn updateTimerState() void {}
    pub fn pollTimeoutMs() i32 { return -1; }
};


const MIN_BAR_HEIGHT:            u32 = 20;
const MAX_BAR_HEIGHT:            u32 = 200;
const DEFAULT_BAR_HEIGHT:        u16 = 24;
const FALLBACK_WORKSPACES_WIDTH: u16 = 270;
const LAYOUT_SEGMENT_WIDTH:      u16 = 60;
const TITLE_SEGMENT_MIN_WIDTH:   u16 = 100;

/// Point-in-time bar state captured by the main thread and consumed by the bar thread.
/// Variable-length fields use ArrayListUnmanaged; buffers grow only when needed and are
/// reused across frames.
const BarSnapshot = struct {
    focused_window:    ?u32                          = null,
    focused_title:     std.ArrayListUnmanaged(u8)    = .empty,
    current_ws_wins:   std.ArrayListUnmanaged(u32)   = .empty,
    minimized_set:     std.AutoHashMapUnmanaged(u32, void)  = .{},
    ws_has_windows:    std.ArrayListUnmanaged(bool)  = .empty,
    ws_current:        u8                            = 0,
    ws_count:          u32                           = 0,
    ws_all_active:     bool                          = false,
    title_invalidated: bool                          = false,
    dirty_all:   bool = true,  // ws_count changed or full-redraw forced
    dirty_ws:    bool = true,  // workspace state changed
    dirty_title: bool = true,  // title / focus / minimized state changed
    fn deinit(snap: *BarSnapshot, allocator: std.mem.Allocator) void {
        snap.focused_title.deinit(allocator);
        snap.current_ws_wins.deinit(allocator);
        snap.minimized_set.deinit(allocator);
        snap.ws_has_windows.deinit(allocator);
    }
};

/// Explicit work-item model for the bar render thread.  All fields are read/written
/// under BarChannel.mutex.  `kind` encodes the primary action (mutually exclusive
/// states); `clock` is additive and may accompany any non-snap primary action.
const BarWork = struct {
    kind:      Kind  = .idle,
    focus_win: ?u32  = null,  // valid only when kind == .focus_only
    clock:     bool  = false, // additive clock tick; ignored when kind == .snap_ready

    const Kind = enum { idle, snap_ready, focus_only, quit };

    /// True when there is at least one unit of work pending.
    fn hasPending(w: BarWork) bool {
        return w.kind != .idle or w.clock;
    }
};

/// Double-buffered lock channel between main thread (producer) and bar thread (consumer).
/// Main writes into slots[write_idx] then flips write_idx under mutex;
/// bar reads from slots[1 - write_idx].
const BarChannel = struct {
    mutex:     Mutex     = .{},
    work_cond: Condition = .{},
    done_cond: Condition = .{},
    slots:     [2]BarSnapshot = .{ .{}, .{} },
    write_idx: u1             = 0,
    work:      BarWork        = .{},
    draw_gen:  u64            = 0,
    /// Forces a full bar redraw on the next submitDraw (expose, reload, position toggle, show).
    force_dirty_all: bool = false,
};

/// Owns all live bar state; a single var replaces the previous four module-level globals.
const Bar = struct {
    channel: BarChannel  = .{},
    thread:  ?std.Thread = null,
    state:   ?*State     = null,
    atoms: struct {
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
    } = .{},
};

var g_bar: Bar = .{};

/// X11 connection and window handle; stable for the bar's lifetime.
const WindowCtx = struct {
    conn:                  *xcb.xcb_connection_t,
    window:                u32,
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

/// Cairo/Pango drawing context plus bar configuration.
const RenderCtx = struct {
    dc:        *drawing.DrawContext,
    config:    core.BarConfig,
    width:     u16,
    height:    u16,
    allocator: std.mem.Allocator,
};

/// Per-draw layout geometry; invalidated when ws_count changes or the clock position resets.
const LayoutCache = struct {
    clock_width:          u16  = 0,
    clock_x:              ?u16 = null,
    workspace_x:          u16  = 0,
    right_total:          u16  = 0,
    right_total_ws_count: u32  = std.math.maxInt(u32),
};

/// Focus/title/workspace rendering cache; updated after each full draw.
const TitleCache = struct {
    title:          std.ArrayList(u8)                   = std.ArrayList(u8).empty,
    title_window:   ?u32                                = null,
    focused_window: ?u32                                = null,
    ws_wins:        std.ArrayListUnmanaged(u32)         = .empty,
    minimized_set:  std.AutoHashMapUnmanaged(u32, void) = .{},
    title_x:        u16  = 0,
    title_w:        u16  = 0,
    layout_valid:   bool = false,
    invalidated:    bool = false,

    fn deinit(self: *TitleCache, allocator: std.mem.Allocator) void {
        self.title.deinit(allocator);
        self.ws_wins.deinit(allocator);
        self.minimized_set.deinit(allocator);
    }
};

const State = struct {
    win:    WindowCtx,
    render: RenderCtx,
    layout: LayoutCache = .{},
    title:  TitleCache  = .{},
    visible:           bool = true,
    global_visible:    bool = true,
    dirty:             bool = false,
    has_clock_segment: bool,

    fn init(
        allocator: std.mem.Allocator,
        conn:      *xcb.xcb_connection_t,
        window:    u32,
        colormap:  u32,
        width:     u16,
        height:    u16,
        dc:        *drawing.DrawContext,
        config:    core.BarConfig,
    ) !*State {
        const s = try allocator.create(State);
        s.* = .{
            .win = .{
                .conn             = conn,
                .window           = window,
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
            .layout = .{
                .clock_width = dc.textWidth(clock_segment.SAMPLE_STRING) + 2 * config.scaledSegmentPadding(height),
            },
            .has_clock_segment = blk: {
                if (comptime !build_options.has_clock) break :blk false;
                for (config.layout.items) |layout|
                    for (layout.segments.items) |seg|
                        if (seg == .clock) break :blk true;
                break :blk false;
            },
        };
        try s.title.title.ensureTotalCapacity(allocator, 256);
        workspaces_segment.invalidate();
        return s;
    }

    fn deinit(self: *State) void {
        self.win.deinit();
        self.title.deinit(self.render.allocator);
        self.render.allocator.destroy(self);
    }

    fn setDirty(self: *State) void { self.dirty = true; }
    fn invalidateLayout(self: *State) void { self.dirty = true; self.layout.clock_x = null; }

    fn calculateSegmentWidth(self: *State, snap: *const BarSnapshot, segment: core.BarSegment) u16 {
        return switch (segment) {
            .workspaces => if (snap.ws_count > 0)
                @intCast(snap.ws_count * workspaces_segment.getCachedWorkspaceWidth())
            else
                FALLBACK_WORKSPACES_WIDTH,
            .layout, .variants => LAYOUT_SEGMENT_WIDTH,
            .title             => TITLE_SEGMENT_MIN_WIDTH,
            .clock             => self.layout.clock_width,
        };
    }

    fn drawSegment(self: *State, snap: *const BarSnapshot, segment: core.BarSegment, x: u16, width: ?u16) !u16 {
        if (segment == .workspaces) self.layout.workspace_x = x;
        return switch (segment) {
            .workspaces => try workspaces_segment.draw(
                self.render.dc, self.render.config, self.render.height, x,
                snap.ws_current, snap.ws_has_windows.items, snap.ws_all_active),
            .layout   => try layout_segment.draw(self.render.dc, self.render.config, self.render.height, x),
            .variants => try variants_segment.draw(self.render.dc, self.render.config, self.render.height, x),
            .title    => try prompt.draw(
                self.render.dc, self.render.config, self.render.height, x, width orelse 100,
                self.win.conn, snap.focused_window,
                snap.focused_title.items,
                snap.current_ws_wins.items, &snap.minimized_set,
                &self.title.title, &self.title.title_window,
                snap.title_invalidated, self.render.allocator),
            .clock    => try clock_segment.draw(self.render.dc, self.render.config, self.render.height, x),
        };
    }

    inline fn segmentSkip(snap: *const BarSnapshot, seg: core.BarSegment) bool {
        if (snap.dirty_all) return false;
        return switch (seg) {
            .workspaces => !snap.dirty_ws,
            .title      => !snap.dirty_title,
            else        => false,
        };
    }

    fn drawRightSegments(self: *State, snap: *const BarSnapshot, segments: []const core.BarSegment) !void {
        var right_x          = self.render.width;
        const scaled_spacing = self.render.config.scaledSpacing(self.render.height);
        // pending_gap: when true the segment to our right drew something and
        // "earned" a gap — we emit it only if the current segment also draws,
        // so gaps only appear between two non-empty neighbours.
        var pending_gap = false;
        var i = segments.len;
        while (i > 0) {
            i -= 1;
            right_x -= self.calculateSegmentWidth(snap, segments[i]);
            if (segments[i] == .clock) self.layout.clock_x = right_x;
            const drew_to = try self.drawSegment(snap, segments[i], right_x, null);
            const drew = drew_to != right_x;
            if (drew and pending_gap) {
                // Both neighbours are non-empty: paint the gap between them.
                // It sits immediately to the right of this segment's allocated width.
                const gap_x = right_x + self.calculateSegmentWidth(snap, segments[i]);
                self.render.dc.createRectangle(gap_x, 0, scaled_spacing, self.render.height, self.render.config.bg);
                right_x -= scaled_spacing;
            } else if (drew and !pending_gap and i < segments.len - 1) {
                // We drew but the right neighbour was empty: subtract spacing so
                // the next segment is spaced from us correctly.
                right_x -= scaled_spacing;
                self.render.dc.createRectangle(right_x, 0, scaled_spacing, self.render.height, self.render.config.bg);
            }
            pending_gap = drew;
        }
    }

    fn drawAll(self: *State, snap: *const BarSnapshot) !void {
        if (snap.title_invalidated) self.title.title_window = null;
        if (snap.dirty_all) self.render.dc.createRectangle(0, 0, self.render.width, self.render.height, self.render.config.bg);
        const scaled_spacing = self.render.config.scaledSpacing(self.render.height);
        // Recompute right_total only when ws_count changes.
        if (snap.ws_count != self.layout.right_total_ws_count) {
            var right_total: u16 = 0;
            for (self.render.config.layout.items) |layout| {
                if (layout.position != .right) continue;
                for (layout.segments.items) |seg| right_total += self.calculateSegmentWidth(snap, seg) + scaled_spacing;
                if (layout.segments.items.len > 0) right_total -= scaled_spacing;
            }
            self.layout.right_total          = right_total;
            self.layout.right_total_ws_count = snap.ws_count;
        }
        const right_total = self.layout.right_total;
        var title_seg_x: u16 = 0;
        var title_seg_w: u16 = 0;
        var x: u16 = 0;
        for (self.render.config.layout.items) |layout| {
            switch (layout.position) {
                .left => for (layout.segments.items) |seg| {
                    const seg_w = self.calculateSegmentWidth(snap, seg);
                    if (seg == .title) { title_seg_x = x; title_seg_w = seg_w; }
                    if (segmentSkip(snap, seg)) {
                        x += seg_w + scaled_spacing;
                    } else {
                        const x_before = x;
                        x = try self.drawSegment(snap, seg, x, null);
                        if (x != x_before) {
                            self.render.dc.createRectangle(x, 0, scaled_spacing, self.render.height, self.render.config.bg);
                            x += scaled_spacing;
                        }
                    }
                },
                .center => {
                    const remaining = @max(100, self.render.width -| x -| right_total -| scaled_spacing);
                    for (layout.segments.items) |seg| {
                        const w = if (seg == .title) remaining else self.calculateSegmentWidth(snap, seg);
                        if (seg == .title) { title_seg_x = x; title_seg_w = w; }
                        if (segmentSkip(snap, seg)) {
                            x += w;
                            if (seg != .title) x += scaled_spacing;
                        } else {
                            const x_before = x;
                            x = try self.drawSegment(snap, seg, x, w);
                            if (seg != .title and x != x_before) {
                                self.render.dc.createRectangle(x, 0, scaled_spacing, self.render.height, self.render.config.bg);
                                x += scaled_spacing;
                            }
                        }
                    }
                },
                .right => try self.drawRightSegments(snap, layout.segments.items),
            }
        }
        self.render.dc.flush();
        if (title_seg_w > 0) self.updateTitleCache(snap, title_seg_x, title_seg_w);
    }

    fn drawClockOnly(self: *State) void {
        const clock_x = self.layout.clock_x orelse return;
        _ = clock_segment.draw(self.render.dc, self.render.config, self.render.height, clock_x) catch |e| debug.warnOnErr(e, "drawClockOnly");
        self.render.dc.flush();
    }

    fn drawTitleOnly(self: *State, new_focused: ?u32) void {
        if (prompt.isActive()) return;
        if (!self.title.layout_valid or self.title.title_w == 0) return;
        self.title.focused_window = new_focused;
        // Fast path: carousel.drawCarouselTick handles its own flush and returns true on success.
        // Use minimized accent when the sole workspace window is minimized.
        if (carousel.isCarouselActive()) {
            const accent: u32 = if (self.title.ws_wins.items.len == 1 and
                self.title.minimized_set.contains(self.title.ws_wins.items[0]))
                self.render.config.title_minimized_accent
            else
                self.render.config.title_accent_color;
            if (carousel.drawCarouselTick(self.render.dc, accent, self.render.height,
                    self.title.title_x, self.title.title_w)) return;
        }
        _ = title_segment.drawCached(
            .{
                .dc      = self.render.dc,
                .config  = self.render.config,
                .height  = self.render.height,
                .start_x = self.title.title_x,
                .width   = self.title.title_w,
                .conn    = self.win.conn,
            },
            .{
                .focused_window  = new_focused,
                .focused_title   = self.title.title.items,
                .minimized_title = "",
                .current_ws_wins = self.title.ws_wins.items,
                .minimized_set   = &self.title.minimized_set,
            },
            self.render.allocator,
        ) catch |e| { debug.warnOnErr(e, "drawTitleOnly"); return; };
        self.render.dc.flush();
    }

    fn updateTitleCache(self: *State, snap: *const BarSnapshot, x: u16, w: u16) void {
        // Build replacements first; only swap into the live cache on success so a
        // failed allocation leaves it stale (showing old data) rather than silently empty.
        var new_wins: std.ArrayListUnmanaged(u32) = .empty;
        if (new_wins.appendSlice(self.render.allocator, snap.current_ws_wins.items)) {
            self.title.ws_wins.deinit(self.render.allocator);
            self.title.ws_wins = new_wins;
        } else |_| {
            new_wins.deinit(self.render.allocator);
            // title.ws_wins left as-is; stale data is preferable to an empty list.
        }
        if (snap.minimized_set.clone(self.render.allocator)) |new_set| {
            self.title.minimized_set.deinit(self.render.allocator);
            self.title.minimized_set = new_set;
        } else |_| {
            // title.minimized_set left stale rather than cleared.
        }
        self.title.focused_window = snap.focused_window;
        self.title.title_x        = x;
        self.title.title_w        = w;
        self.title.layout_valid   = true;
    }
};

/// Carousel frame interval — 165 Hz (1_000_000_000 / 165 ≈ 6_060_606 ns).
const CAROUSEL_WAKE_NS: u64 = 6_060_606;

fn barThreadFn(s: *State) void {
    // Absolute monotonic deadline for next carousel frame; late wakes don't compound.
    var next_carousel_ns: u64 = 0;
    while (true) {
        g_bar.channel.mutex.lock();
        // Sleep until there is something to do or the carousel timer fires.
        while (!g_bar.channel.work.hasPending()) {
            if (carousel.isCarouselActive()) {
                const now_ns = monoNowNs();
                if (now_ns >= next_carousel_ns) break;
                const remaining = next_carousel_ns - now_ns;
                g_bar.channel.work_cond.timedWait(&g_bar.channel.mutex, remaining) catch {};
                break;
            } else {
                next_carousel_ns = 0;
                g_bar.channel.work_cond.wait(&g_bar.channel.mutex);
            }
        }
        if (g_bar.channel.work.kind == .quit) { g_bar.channel.mutex.unlock(); return; }
        // Snapshot the pending work and clear it atomically under the mutex.
        const work      = g_bar.channel.work;
        const read_idx: u1 = 1 - g_bar.channel.write_idx;
        g_bar.channel.work = .{};
        g_bar.channel.mutex.unlock();

        switch (work.kind) {
            .snap_ready => {
                // Full draw covers the clock too — ignore work.clock.
                s.drawAll(&g_bar.channel.slots[read_idx]) catch |e| debug.warnOnErr(e, "bar thread drawAll");
                g_bar.channel.mutex.lock();
                g_bar.channel.draw_gen += 1;
                g_bar.channel.done_cond.broadcast();
                g_bar.channel.mutex.unlock();
            },
            .focus_only => {
                s.drawTitleOnly(work.focus_win);
                if (work.clock) s.drawClockOnly();
            },
            .idle => {
                // No primary work — service a carousel tick if active.
                if (carousel.isCarouselActive()) {
                    s.drawTitleOnly(s.title.focused_window);
                    if (next_carousel_ns == 0) next_carousel_ns = monoNowNs();
                    next_carousel_ns +%= CAROUSEL_WAKE_NS;
                }
                if (work.clock) s.drawClockOnly();
            },
            .quit => unreachable,
        }
    }
}

inline fn monoNowNs() u64 {
    var ts: std.os.linux.timespec = undefined;
    _ = std.os.linux.clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * 1_000_000_000 + @as(u64, @intCast(ts.nsec));
}

inline fn startBarThread(s: *State) void {
    g_bar.thread = std.Thread.spawn(.{}, barThreadFn, .{s}) catch |e| {
        debug.warnOnErr(e, "Failed to start bar render thread"); return;
    };
}

fn stopBarThread() void {
    g_bar.channel.mutex.lock();
    g_bar.channel.work = .{ .kind = .quit };
    g_bar.channel.work_cond.signal();
    g_bar.channel.mutex.unlock();
    if (g_bar.thread) |t| { t.join(); g_bar.thread = null; }
    g_bar.channel.work = .{};  // reset for potential re-use after reload
}

/// Returns true when the two minimized sets differ in membership (not just count).
fn minimizedSetChanged(
    a: *const std.AutoHashMapUnmanaged(u32, void),
    b: *const std.AutoHashMapUnmanaged(u32, void),
) bool {
    if (a.count() != b.count()) return true;
    var it = a.keyIterator();
    while (it.next()) |key| if (!b.contains(key.*)) return true;
    return false;
}

/// Populates a pre-allocated BarSnapshot slot in-place from current WM state.
fn captureIntoSlot(s: *State, snap: *BarSnapshot, prev: *const BarSnapshot) !void {
    const allocator = s.render.allocator;
    snap.minimized_set.clearRetainingCapacity();
    if (comptime build_options.has_minimize)
        try minimize.populateSet(&snap.minimized_set, allocator);

    if (comptime build_options.has_workspaces) {
        const ws_state = wsGetState() orelse return;
        snap.ws_count   = @intCast(ws_state.workspaces.len);
        snap.ws_current = ws_state.current;
        snap.ws_all_active = ws_state.all_view_temp_wins.items.len > 0;
        try snap.ws_has_windows.resize(allocator, snap.ws_count);
        for (ws_state.workspaces, 0..) |*workspace, i|
            snap.ws_has_windows.items[i] = workspace.windows.len > 0;
        snap.current_ws_wins.clearRetainingCapacity();
        if (ws_state.current < ws_state.workspaces.len)
            try snap.current_ws_wins.appendSlice(allocator, ws_state.workspaces[ws_state.current].windows.items());
    } else {
        // No workspace subsystem — treat as single workspace so ws_count
        // differs from prev.ws_count (0) on the first draw, ensuring dirty_all
        // fires and the background is cleared before any segments are drawn.
        snap.ws_count = 1;
        snap.current_ws_wins.clearRetainingCapacity();
        if (tracking.allWindowsIterator()) |it| {
            var iter = it;
            while (iter.next()) |wp| try snap.current_ws_wins.append(allocator, wp.*);
        }
    }
    snap.focused_window = focus.getFocused();
    snap.title_invalidated = s.title.invalidated;
    s.title.invalidated    = false;
    snap.focused_title.clearRetainingCapacity();
    if (snap.focused_window) |fw| {
        if (snap.focused_window != prev.focused_window or snap.title_invalidated) {
            title_segment.fetchWindowTitleInto(core.conn, fw, &snap.focused_title, allocator) catch {};
        } else {
            snap.focused_title.appendSlice(allocator, prev.focused_title.items) catch {};
        }
    }

    const forced = g_bar.channel.force_dirty_all;
    g_bar.channel.force_dirty_all = false;
    snap.dirty_all = forced or (snap.ws_count != prev.ws_count);
    snap.dirty_ws  = snap.dirty_all or
        snap.ws_current != prev.ws_current or
        snap.ws_all_active != prev.ws_all_active or
        !std.mem.eql(bool, snap.ws_has_windows.items, prev.ws_has_windows.items);
    snap.dirty_title =
        prompt.isActive() or
        snap.focused_window != prev.focused_window or
        snap.title_invalidated or
        !std.mem.eql(u8,  snap.focused_title.items,  prev.focused_title.items)   or
        !std.mem.eql(u32, snap.current_ws_wins.items, prev.current_ws_wins.items) or
        minimizedSetChanged(&snap.minimized_set, &prev.minimized_set);
}

/// Forces a full redraw: sets force_dirty_all and blocks until the bar thread finishes.
fn forceRedraw() void { g_bar.channel.force_dirty_all = true; submitDraw(true); }

/// Ungrab the X server and flush. Always called as a pair.
inline fn ungrabAndFlush() void {
    _ = xcb.xcb_ungrab_server(core.conn);
    _ = xcb.xcb_flush(core.conn);
}

/// Posts a snapshot to the bar thread; `wait = true` blocks until the draw completes.
pub fn submitDraw(wait: bool) void {
    const s = g_bar.state orelse return;
    if (!s.visible) return;
    const idx = g_bar.channel.write_idx;
    captureIntoSlot(s, &g_bar.channel.slots[idx], &g_bar.channel.slots[1 - idx]) catch |e| {
        debug.warnOnErr(e, "bar captureIntoSlot");
        return;
    };
    g_bar.channel.mutex.lock();
    defer g_bar.channel.mutex.unlock();
    g_bar.channel.write_idx ^= 1;
    g_bar.channel.work.kind = .snap_ready;
    const gen_before = g_bar.channel.draw_gen;
    g_bar.channel.work_cond.signal();
    if (wait) {
        while (g_bar.channel.draw_gen == gen_before)
            g_bar.channel.done_cond.wait(&g_bar.channel.mutex);
    }
}



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
        @field(g_bar.atoms, e[0]) = utils.getAtomCached(e[1]) catch 0;
}

fn barYPos(height: u16) i16 {
    return if (core.config.bar.bar_position == .bottom)
        @intCast(@as(i32, core.screen.height_in_pixels) - height)
    else
        0;
}

const BarWindowSetup = struct { window: u32, visual_id: u32, has_argb: bool, colormap: u32 };

fn createBarWindow(height: u16, y_pos: i16) BarWindowSetup {
    const want_transparency = core.config.bar.getAlpha16() < 0xFFFF;
    const visual_info = if (want_transparency)
        drawing.findVisualByDepth(core.screen, 32)
    else
        drawing.VisualInfo{ .visual_type = null, .visual_id = core.screen.root_visual };
    const depth: u8 = if (want_transparency) 32 else xcb.XCB_COPY_FROM_PARENT;
    const visual_id = visual_info.visual_id;
    const colormap: u32 = if (want_transparency) blk: {
        const cmap = xcb.xcb_generate_id(core.conn);
        _ = xcb.xcb_create_colormap(core.conn, xcb.XCB_COLORMAP_ALLOC_NONE, cmap, core.screen.root, visual_id);
        break :blk cmap;
    } else 0;
    const window     = xcb.xcb_generate_id(core.conn);
    const value_mask = xcb.XCB_CW_BACK_PIXEL | xcb.XCB_CW_BORDER_PIXEL |
                       xcb.XCB_CW_OVERRIDE_REDIRECT | xcb.XCB_CW_EVENT_MASK |
                       if (want_transparency) xcb.XCB_CW_COLORMAP else 0;
    const base_events = xcb.XCB_EVENT_MASK_EXPOSURE | xcb.XCB_EVENT_MASK_BUTTON_PRESS;
    const value_list = [5]u32{ 0, 0, 1, base_events, colormap };
    _ = xcb.xcb_create_window(core.conn, depth, window, core.screen.root,
        0, y_pos, core.screen.width_in_pixels, height, 0,
        xcb.XCB_WINDOW_CLASS_INPUT_OUTPUT, visual_id,
        @intCast(value_mask), &value_list);
    return .{ .window = window, .visual_id = visual_id, .has_argb = want_transparency, .colormap = colormap };
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

fn setPropAtom(conn: *xcb.xcb_connection_t, window: u32, prop: u32, atom_type: u32, values: anytype) void {
    _ = xcb.xcb_change_property(conn, xcb.XCB_PROP_MODE_REPLACE, window, prop, atom_type,
        32, @intCast(values.len), values.ptr);
}

fn setWindowProperties(window: u32, height: u16) void {
    const strut: [12]u32 = if (core.config.bar.bar_position == .top)
        .{ 0, 0, 0, height, 0, 0, 0, 0, 0, 0, 0, core.screen.width_in_pixels }
    else
        .{ 0, 0, height, 0, 0, 0, 0, 0, 0, core.screen.width_in_pixels, 0, 0 };
    if (g_bar.atoms.strut_partial    != 0) setPropAtom(core.conn, window, g_bar.atoms.strut_partial,    xcb.XCB_ATOM_CARDINAL, &strut);
    if (g_bar.atoms.window_type      != 0) setPropAtom(core.conn, window, g_bar.atoms.window_type,      xcb.XCB_ATOM_ATOM, &[_]u32{g_bar.atoms.window_type_dock});
    if (g_bar.atoms.wm_state         != 0) setPropAtom(core.conn, window, g_bar.atoms.wm_state,         xcb.XCB_ATOM_ATOM, &[_]u32{g_bar.atoms.state_above, g_bar.atoms.state_sticky});
    if (g_bar.atoms.allowed_actions  != 0) setPropAtom(core.conn, window, g_bar.atoms.allowed_actions,  xcb.XCB_ATOM_ATOM, &[_]u32{g_bar.atoms.action_close, g_bar.atoms.action_above, g_bar.atoms.action_stick});
}

fn measureFontMetrics() ?struct { asc: i32, desc: i32 } {
    var mc = drawing.MeasureContext.init(core.alloc, core.dpi_info.dpi) catch return null;
    defer mc.deinit();
    loadBarFonts(&mc) catch return null;
    const asc, const desc = mc.getMetrics();
    return .{ .asc = asc, .desc = desc };
}

fn resolvePercentageFontSize(bar_height: u16) ?u16 {
    const TRIAL_PT: u16 = 100;
    const saved_size = core.config.bar.scaled_font_size;
    core.config.bar.scaled_font_size = TRIAL_PT;
    defer core.config.bar.scaled_font_size = saved_size;
    const m = measureFontMetrics() orelse return null;
    const px_per_pt: f32 = @as(f32, @floatFromInt(@max(1, m.asc + m.desc))) / @as(f32, @floatFromInt(TRIAL_PT));
    const max_size_pt    = @as(f32, @floatFromInt(bar_height)) / px_per_pt;
    return @max(1, @as(u16, @intFromFloat(@round(max_size_pt * (core.config.bar.font_size.value / 100.0)))));
}

fn calculateBarHeight() !u16 {
    if (core.config.bar.height) |h| {
        const height = scale.scaleBarHeight(h, core.screen.height_in_pixels);
        if (core.config.bar.font_size.is_percentage) {
            if (resolvePercentageFontSize(height)) |sz|
                core.config.bar.scaled_font_size = sz;
        }
        return height;
    }
    const m = measureFontMetrics() orelse return DEFAULT_BAR_HEIGHT;
    return @intCast(std.math.clamp(@as(u32, @intCast(m.asc + m.desc)), MIN_BAR_HEIGHT, MAX_BAR_HEIGHT));
}

fn createDC(setup: BarWindowSetup, height: u16) !*drawing.DrawContext {
    const dc = try drawing.DrawContext.initWithVisual(
        core.alloc, core.conn, setup.window, core.screen.width_in_pixels, height,
        setup.visual_id, core.dpi_info.dpi, setup.has_argb, core.config.bar.transparency,
    );
    errdefer dc.deinit();
    try loadBarFonts(dc);
    return dc;
}

pub fn init() !void {
    std.debug.assert(core.config.bar.enabled);
    initAtoms();
    const height = try calculateBarHeight();
    const y_pos  = barYPos(height);
    const setup  = createBarWindow(height, y_pos);
    errdefer { _ = xcb.xcb_destroy_window(core.conn, setup.window); if (setup.colormap != 0) _ = xcb.xcb_free_colormap(core.conn, setup.colormap); }
    setWindowProperties(setup.window, height);
    const dc = try createDC(setup, height);
    errdefer dc.deinit();
    debug.info("Bar transparency: {s}", .{if (setup.has_argb) "enabled (ARGB)" else "disabled (opaque)"});
    g_bar.state = try State.init(core.alloc, core.conn, setup.window, setup.colormap,
        core.screen.width_in_pixels, height, dc, core.config.bar);
    startBarThread(g_bar.state.?);
    submitDraw(true);
    _ = xcb.xcb_map_window(core.conn, setup.window);
    _ = xcb.xcb_flush(core.conn);
    try prompt.init(core.alloc, core.conn);
}

pub fn deinit() void {
    prompt.deinit();
    stopBarThread();
    if (g_bar.state) |s| {
        carousel.deinitCarousel();
        for (&g_bar.channel.slots) |*slot| slot.deinit(s.render.allocator);
        _ = xcb.xcb_destroy_window(s.win.conn, s.win.window);
        s.render.dc.deinit();
        drawing.deinitFontCache(s.render.allocator);
        s.deinit();
        g_bar.state = null;
    }
}

pub fn reload() void {
    const old = g_bar.state orelse {
        if (core.config.bar.enabled) {
            init() catch |err| debug.err("Bar init failed: {}", .{err});
        }
        return;
    };
    if (!core.config.bar.enabled) { deinit(); return; }
    const height = calculateBarHeight() catch DEFAULT_BAR_HEIGHT;
    const y_pos  = barYPos(height);
    const setup  = createBarWindow(height, y_pos);
    reloadImpl(old, setup, height) catch |err| {
        _ = xcb.xcb_destroy_window(core.conn, setup.window);
        if (setup.colormap != 0) _ = xcb.xcb_free_colormap(core.conn, setup.colormap);
        debug.err("Bar reload failed ({s}), keeping old bar", .{@errorName(err)});
    };
}

fn reloadImpl(old: *State, setup: BarWindowSetup, height: u16) !void {
    setWindowProperties(setup.window, height);
    const new_dc = try createDC(setup, height);
    errdefer new_dc.deinit();
    const new_state = try State.init(core.alloc, core.conn, setup.window, setup.colormap,
        core.screen.width_in_pixels, height, new_dc, core.config.bar);
    new_state.visible        = old.visible;
    new_state.global_visible = old.global_visible;
    stopBarThread();
    g_bar.state = new_state;
    startBarThread(new_state);
    forceRedraw();
    if (new_state.visible) _ = xcb.xcb_map_window(core.conn, setup.window);
    _ = xcb.xcb_destroy_window(core.conn, old.win.window);
    ungrabAndFlush();
    old.render.dc.deinit();
    old.deinit();
}

pub fn toggleBarSegmentAnchor() void {
    const s = g_bar.state orelse return;
    core.config.bar.bar_position = switch (core.config.bar.bar_position) {
        .top    => .bottom,
        .bottom => .top,
    };
    const new_y = barYPos(s.render.height);
    setWindowProperties(s.win.window, s.render.height);
    g_bar.channel.force_dirty_all = true;
    s.invalidateLayout();
    _ = xcb.xcb_grab_server(core.conn);
    _ = xcb.xcb_configure_window(core.conn, s.win.window, xcb.XCB_CONFIG_WINDOW_Y,
        &[_]u32{@as(u32, @bitCast(@as(i32, new_y)))});
    const current_ws = tracking.getCurrentWorkspace() orelse {
        // No active workspace — border sweep is a no-op, but mark it done so
        // the event loop does not fire a redundant second sweep.
        windowTest.updateWorkspaceBorders();
        windowTest.markBordersFlushed();
        ungrabAndFlush();
        return;
    };
    const no_fullscreen = if (comptime build_options.has_fullscreen)
        fullscreen.getForWorkspace(current_ws) == null
    else
        true;
    if (no_fullscreen)
        if (comptime build_options.has_tiling) tiling.retileCurrentWorkspace();
    // Sweep border colors inside the grab so they land in the same atomic
    // batch as the configure and retile commands above.
    windowTest.updateWorkspaceBorders();
    windowTest.markBordersFlushed();
    ungrabAndFlush();
    debug.info("Bar position toggled to: {s}", .{@tagName(core.config.bar.bar_position)});
}

/// Lightweight focus-only redraw; skipped when a full redraw is already pending.
pub fn scheduleFocusRedraw(new_win: ?u32) void {
    const s = g_bar.state orelse return;
    if (!s.visible or s.dirty) return;
    g_bar.channel.mutex.lock();
    // Only post a focus update when no higher-priority work is already queued.
    if (g_bar.channel.work.kind == .idle) {
        g_bar.channel.work = .{ .kind = .focus_only, .focus_win = new_win };
        g_bar.channel.work_cond.signal();
    }
    g_bar.channel.mutex.unlock();
}

pub fn getBarWindow() u32        { return if (g_bar.state) |s| s.win.window else 0; }
pub fn isBarWindow(win: u32) bool { return if (g_bar.state) |s| s.win.window == win else false; }
pub fn getBarHeight() u16         { return if (g_bar.state) |s| s.render.height else 0; }
pub fn isBarInitialized() bool    { return g_bar.state != null; }
pub fn hasClockSegment() bool     { return if (g_bar.state) |s| s.has_clock_segment else false; }
/// Schedules a full bar redraw, coalesced via updateIfDirty. Zero X11 I/O on caller.
pub fn scheduleRedraw() void        { if (g_bar.state) |s| if (s.visible) s.setDirty(); }
/// Like scheduleRedraw but forces a full bar clear+redraw regardless of dirty flags.
/// Use when a segment's presence or width changes (e.g. layout switch) so stale
/// pixels from the previous render are guaranteed to be erased.
pub fn scheduleFullRedraw() void {
    if (g_bar.state) |s| if (s.visible) {
        g_bar.channel.force_dirty_all = true;
        s.setDirty();
    };
}
pub fn isVisible() bool             { return if (g_bar.state) |s| s.visible else false; }
pub fn getGlobalVisibility() bool   { return if (g_bar.state) |s| s.global_visible else false; }
pub fn setGlobalVisibility(visible: bool) void { if (g_bar.state) |s| s.global_visible = visible; }

/// Synchronous redraw — blocks until done. Use only inside/before xcb_ungrab_server.
pub fn redrawInsideGrab() void {
    const s = g_bar.state orelse return;
    if (s.visible) { submitDraw(true); s.dirty = false; }
}

pub fn raiseBar() void {
    if (g_bar.state) |s| _ = xcb.xcb_configure_window(s.win.conn, s.win.window, xcb.XCB_CONFIG_WINDOW_STACK_MODE, &[_]u32{xcb.XCB_STACK_MODE_ABOVE});
}

pub fn setBarState(action: BarAction) void {
    const s = g_bar.state orelse return;
    if (action == .toggle) s.global_visible = !s.global_visible;
    const current_ws    = tracking.getCurrentWorkspace() orelse 0;
    const is_fullscreen = action != .hide_fullscreen and
        (comptime build_options.has_fullscreen) and fullscreen.getForWorkspace(current_ws) != null;
    const show = !is_fullscreen and s.global_visible and action != .hide_fullscreen;
    if (s.visible == show and action != .toggle) return;
    s.visible = show;
    if (action == .toggle) {
        if (show) forceRedraw();
        _ = xcb.xcb_grab_server(core.conn);
        if (show) _ = xcb.xcb_map_window(core.conn, s.win.window)
        else      _ = xcb.xcb_unmap_window(core.conn, s.win.window);
        const saved = s.visible;
        if (is_fullscreen) s.visible = s.global_visible;
        retileAllWorkspaces();
        if (is_fullscreen) s.visible = saved;
        // Sweep border colors inside the grab so they land in the same atomic
        // batch as the map/unmap and retile commands above.
        windowTest.updateWorkspaceBorders();
        windowTest.markBordersFlushed();
        ungrabAndFlush();
    } else {
        if (show) {
            forceRedraw();
            _ = xcb.xcb_map_window(core.conn, s.win.window);
        } else {
            _ = xcb.xcb_unmap_window(core.conn, s.win.window);
        }
        if (comptime build_options.has_tiling) tiling.retileCurrentWorkspace();
    }

    debug.info("Bar {s} ({s})", .{ if (show) "shown" else "hidden", @tagName(action) });
    clock_segment.updateTimerState();
}

pub fn updateIfDirty() !void {
    const s = g_bar.state orelse return;
    if (!s.visible) return;
    if (prompt.consumeRedrawRequest()) { g_bar.channel.force_dirty_all = true; s.dirty = true; }
    if (s.dirty) { submitDraw(false); s.dirty = false; }
}

pub fn checkClockUpdate() void {
    const s = g_bar.state orelse return;
    if (!s.visible) return;
    // Acquire the mutex before writing work.clock to avoid the data race that
    // the previous bare `clock_dirty = true` outside the lock introduced.
    g_bar.channel.mutex.lock();
    g_bar.channel.work.clock = true;
    g_bar.channel.work_cond.signal();
    g_bar.channel.mutex.unlock();
}

pub fn pollTimeoutMs() i32     { return clock_segment.pollTimeoutMs(); }
pub fn updateTimerState() void { clock_segment.updateTimerState(); }

pub fn handleExpose(event: *const xcb.xcb_expose_event_t) void {
    if (g_bar.state) |s| if (event.window == s.win.window and event.count == 0) {
        g_bar.channel.force_dirty_all = true; if (drag.isDragging()) s.dirty = true else submitDraw(false);
    };
}

pub fn handlePropertyNotify(event: *const xcb.xcb_property_notify_event_t) void {
    const s = g_bar.state orelse return;
    const focused_win = focus.getFocused() orelse return;
    if (event.window != focused_win) return;

    const net_wm_name = s.win.net_wm_name_atom;
    if (event.atom == xcb.XCB_ATOM_WM_NAME or (net_wm_name != 0 and event.atom == net_wm_name)) {
        s.title.invalidated = true;
        s.setDirty();
    }
}

pub fn monitorFocusedWindow() void {
    const win = focus.getFocused() orelse return;
    const s   = g_bar.state orelse return;
    if (s.win.last_monitored_window == win) return;
    if (s.win.last_monitored_window) |old_win|
        _ = xcb.xcb_change_window_attributes(core.conn, old_win,
            xcb.XCB_CW_EVENT_MASK, &[_]u32{constants.EventMasks.MANAGED_WINDOW});
    s.win.last_monitored_window = win;
    _ = xcb.xcb_change_window_attributes(core.conn, win,
        xcb.XCB_CW_EVENT_MASK,
        &[_]u32{constants.EventMasks.MANAGED_WINDOW | xcb.XCB_EVENT_MASK_PROPERTY_CHANGE});
}

pub fn handleButtonPress(event: *const xcb.xcb_button_press_event_t) void {
    if (g_bar.state) |s| if (event.event == s.win.window) {
        if (comptime !build_options.has_workspaces) return;
        const ws_state = wsGetState() orelse return;
        const ws_w     = workspaces_segment.getCachedWorkspaceWidth();
        if (ws_w == 0) return;
        const click_x           = @max(0, event.event_x - s.layout.workspace_x);
        const clicked_ws: usize = @intCast(@divFloor(click_x, ws_w));
        if (clicked_ws < ws_state.workspaces.len) {
            wsSwitchTo(clicked_ws);
            s.setDirty();
        }
    };
}

/// Returns true when tiling is both globally enabled and currently active.
inline fn isTilingActive() bool {
    if (comptime !build_options.has_tiling) return false;
    return core.config.tiling.enabled and
        if (tiling.getStateOpt()) |t| t.enabled else false;
}

/// Retiles every workspace that has windows, honouring fullscreen guards.
/// Must be called without holding the X server grab (grab is the caller's responsibility).
fn retileAllWorkspaces() void {
    if (comptime !build_options.has_tiling) return;
    // wsGetState() already returns null when !has_workspaces, so no second
    // comptime guard is needed here.
    const ws_state = wsGetState() orelse return;
    if (!isTilingActive()) { tiling.retileCurrentWorkspace(); return; }
    for (ws_state.workspaces, 0..) |*ws, idx| {
        if (ws.windows.len == 0) continue;
        if (comptime build_options.has_fullscreen) {
            if (fullscreen.getForWorkspace(@intCast(idx)) != null) continue;
        }
        if (@as(u8, @intCast(idx)) == ws_state.current) {
            tiling.retileCurrentWorkspace();
        } else {
            tiling.retileInactiveWorkspace(@intCast(idx));
        }
    }
}
