//! Status bar: renders segments via Cairo/Pango into an XCB override-redirect window.
//!
//! A dedicated bar thread owns the DrawContext and all rendering. The main thread
//! captures a lightweight BarSnapshot and posts it to a BarChannel; the bar thread
//! wakes, draws, and loops. Draws that must complete before the caller returns (e.g.
//! inside xcb_grab_server) use redrawInsideGrab(), which blocks until done.
//!
//! Clock-only updates bypass the snapshot path: the bar thread redraws just the
//! clock segment using its cached x-position.

const std   = @import("std");
const core = @import("core");
const xcb   = core.xcb;
const debug = @import("debug");

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

const bar_flags = @import("bar_flags");

pub const BarAction = enum { toggle, hide_fullscreen, show_fullscreen };
const build_options = @import("build_options");
const drawing       = @import("drawing");
const tiling        = if (build_options.has_tiling) @import("tiling") else struct {};
const drag          = @import("drag");
const utils         = @import("utils");
const workspaces    = @import("workspaces");
const focus         = @import("focus");
const constants     = @import("constants");
const minimize      = @import("minimize");
const scale         = @import("scale");

const workspaces_segment = if (bar_flags.has_tags) @import("tags") else struct {
    pub fn draw(_: *drawing.DrawContext, _: core.BarConfig, _: u16, x: u16, _: u8, _: []const bool) !u16 { return x; }
    pub fn invalidate() void {}
    pub fn getCachedWorkspaceWidth() u16 { return 0; }
};

const DrawOnlyStub = struct {
    pub fn draw(_: *drawing.DrawContext, _: core.BarConfig, _: u16, x: u16) !u16 { return x; }
};
const layout_segment     = if (bar_flags.has_layout)     @import("layout")     else DrawOnlyStub;
const variations_segment = if (bar_flags.has_variations) @import("variations") else DrawOnlyStub;

const prompt     = @import("prompt");
const fullscreen = @import("fullscreen");
const carousel   = @import("carousel");

const title_segment = if (bar_flags.has_title) @import("title") else struct {
    pub fn draw(
        _: *drawing.DrawContext, _: core.BarConfig, _: u16,
        x: u16, w: u16,
        _: *xcb.xcb_connection_t, _: ?u32,
        _: []const u32, _: []const u32,
        _: *std.ArrayList(u8), _: *?u32,
        _: bool, _: std.mem.Allocator,
    ) !u16 { return x + w; }
};

const clock_segment = if (bar_flags.has_clock) @import("clock") else struct {
    pub const SAMPLE_STRING: []const u8 = "";
    pub fn draw(_: *drawing.DrawContext, _: core.BarConfig, _: u16, x: u16) !u16 { return x; }
    pub fn setTimerFd(_: i32) void {}
    pub fn updateTimerState() void {}
    pub fn pollTimeoutMs() i32 { return -1; }
};

const status_segment = if (bar_flags.has_status) @import("status") else struct {
    pub fn draw(_: *drawing.DrawContext, _: core.BarConfig, _: u16, x: u16, _: []const u8) !u16 { return x; }
    pub fn update(_: *std.ArrayList(u8), _: std.mem.Allocator) !void {}
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
    status_text:       std.ArrayListUnmanaged(u8)    = .empty,
    title_invalidated: bool                          = false,
    dirty_all:   bool = true,  // ws_count changed or full-redraw forced
    dirty_ws:    bool = true,  // workspace state changed
    dirty_title: bool = true,  // title / focus / minimized state changed
    fn deinit(snap: *BarSnapshot, allocator: std.mem.Allocator) void {
        snap.focused_title.deinit(allocator);
        snap.current_ws_wins.deinit(allocator);
        snap.minimized_set.deinit(allocator);
        snap.ws_has_windows.deinit(allocator);
        snap.status_text.deinit(allocator);
    }
};

/// Double-buffered lock channel between main thread (producer) and bar thread (consumer).
/// Main writes into slots[write_idx] then flips write_idx under mutex;
/// bar reads from slots[1 - write_idx].
const BarChannel = struct {
    mutex:         Mutex     = .{},
    work_cond:     Condition = .{},
    done_cond:     Condition = .{},
    slots:         [2]BarSnapshot       = .{ .{}, .{} },
    write_idx:     u1                   = 0,
    snap_ready:       bool  = false,
    clock_dirty:      bool  = false,
    quit:             bool  = false,
    draw_gen:         u64   = 0,
    focus_dirty:      bool  = false,
    focus_new_win:    ?u32  = null,
    /// Forces a full bar redraw on the next submitDraw (expose, reload, position toggle, show).
    force_dirty_all:  bool  = false,
};

var g_channel: BarChannel     = .{};
var g_bar_thread: ?std.Thread = null;

const State = struct {
    window:               u32,
    colormap:             u32,
    width:                u16,
    height:               u16,
    dc:                   *drawing.DrawContext,
    conn:                 *xcb.xcb_connection_t,
    config:               core.BarConfig,
    status_text:          std.ArrayList(u8)                     = std.ArrayList(u8).empty,
    cached_title:         std.ArrayList(u8)                     = std.ArrayList(u8).empty,
    cached_title_window:  ?u32                                  = null,
    dirty:                bool                                  = false,
    title_invalidated:    bool                                  = false,
    visible:              bool                                  = true,
    global_visible:       bool                                  = true,
    allocator:            std.mem.Allocator,
    cached_clock_width:   u16,
    cached_clock_x:       ?u16                                  = null,
    cached_workspace_x:   u16                                   = 0,
    has_clock_segment:    bool,
    cached_title_x:       u16                                   = 0,
    cached_title_w:       u16                                   = 0,
    cached_ws_wins:       std.ArrayListUnmanaged(u32)           = .empty,
    cached_minimized_set: std.AutoHashMapUnmanaged(u32, void)   = .{},
    cached_focused_window: ?u32                                 = null,
    title_layout_valid:   bool                                  = false,
    cached_right_total:              u16                        = 0,
    cached_right_total_ws_count:     u32                        = std.math.maxInt(u32),
    last_monitored_window:       ?u32                           = null,
    net_wm_name_atom:            xcb.xcb_atom_t,
    fn init(
        allocator:        std.mem.Allocator,
        conn:             *xcb.xcb_connection_t,
        window:           u32,
        colormap:         u32,
        width:            u16,
        height:           u16,
        dc:               *drawing.DrawContext,
        config:           core.BarConfig,
    ) !*State {
        const s = try allocator.create(State);
        s.* = .{
            .window    = window,
            .colormap  = colormap,
            .width     = width,
            .height    = height,
            .dc        = dc,
            .conn      = conn,
            .config    = config,
            .allocator = allocator,
            .cached_clock_width = dc.textWidth(clock_segment.SAMPLE_STRING) + 2 * config.scaledSegmentPadding(height),
            .has_clock_segment  = blk: {
                if (comptime !bar_flags.has_clock) break :blk false;
                for (config.layout.items) |layout|
                    for (layout.segments.items) |seg|
                        if (seg == .clock) break :blk true;
                break :blk false;
            },
            .net_wm_name_atom = utils.getAtomCached("_NET_WM_NAME") catch 0,
        };
        try s.status_text.ensureTotalCapacity(allocator, 256);
        try s.cached_title.ensureTotalCapacity(allocator, 256);
        workspaces_segment.invalidate();
        return s;
    }

    fn deinit(self: *State) void {
        if (self.last_monitored_window) |win|
            _ = xcb.xcb_change_window_attributes(self.conn, win,
                xcb.XCB_CW_EVENT_MASK, &[_]u32{constants.EventMasks.MANAGED_WINDOW});
        if (self.colormap != 0) _ = xcb.xcb_free_colormap(self.conn, self.colormap);
        self.status_text.deinit(self.allocator);
        self.cached_title.deinit(self.allocator);
        self.cached_minimized_set.deinit(self.allocator);
        self.cached_ws_wins.deinit(self.allocator);
        self.allocator.destroy(self);
    }

    fn setDirty(self: *State) void { self.dirty = true; }
    fn invalidateLayout(self: *State) void { self.dirty = true; self.cached_clock_x = null; }
    fn calculateSegmentWidth(self: *State, snap: *const BarSnapshot, segment: core.BarSegment) u16 {
        return switch (segment) {
            .workspaces => if (snap.ws_count > 0)
                @intCast(snap.ws_count * workspaces_segment.getCachedWorkspaceWidth())
            else
                FALLBACK_WORKSPACES_WIDTH,
            .layout     => LAYOUT_SEGMENT_WIDTH,
            .variations => LAYOUT_SEGMENT_WIDTH,
            .title      => TITLE_SEGMENT_MIN_WIDTH,
            .clock      => self.cached_clock_width,
        };
    }

    fn drawSegment(self: *State, snap: *const BarSnapshot, segment: core.BarSegment, x: u16, width: ?u16) !u16 {
        if (segment == .workspaces) self.cached_workspace_x = x;
        return switch (segment) {
            .workspaces => try workspaces_segment.draw(
                self.dc, self.config, self.height, x,
                snap.ws_current, snap.ws_has_windows.items),
            .layout     => try layout_segment.draw(self.dc, self.config, self.height, x),
            .variations => try variations_segment.draw(self.dc, self.config, self.height, x),
            .title      => try prompt.draw(
                self.dc, self.config, self.height, x, width orelse 100,
                self.conn, snap.focused_window,
                snap.focused_title.items,
                snap.current_ws_wins.items, &snap.minimized_set,
                &self.cached_title, &self.cached_title_window,
                snap.title_invalidated, self.allocator),
            .clock      => try clock_segment.draw(self.dc, self.config, self.height, x),
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
        var right_x          = self.width;
        const scaled_spacing = self.config.scaledSpacing(self.height);
        // pending_gap: when true the segment to our right drew something and
        // "earned" a gap — we emit it only if the current segment also draws,
        // so gaps only appear between two non-empty neighbours.
        var pending_gap = false;
        var i = segments.len;
        while (i > 0) {
            i -= 1;
            right_x -= self.calculateSegmentWidth(snap, segments[i]);
            if (segments[i] == .clock) self.cached_clock_x = right_x;
            const drew_to = try self.drawSegment(snap, segments[i], right_x, null);
            const drew = drew_to != right_x;
            if (drew and pending_gap) {
                // Both neighbours are non-empty: paint the gap between them.
                // It sits immediately to the right of this segment's allocated width.
                const gap_x = right_x + self.calculateSegmentWidth(snap, segments[i]);
                self.dc.fillRect(gap_x, 0, scaled_spacing, self.height, self.config.bg);
                right_x -= scaled_spacing;
            } else if (!drew and pending_gap) {
                // Right neighbour drew but we are empty: close the gap that was
                // tentatively opened — move right_x back so the next leftward
                // segment doesn't inherit phantom spacing.
                // (no fillRect needed; dirty_all redraws handle the stale pixels)
            } else if (drew and !pending_gap and i < segments.len - 1) {
                // We drew but the right neighbour was empty: subtract spacing so
                // the next segment is spaced from us correctly.
                right_x -= scaled_spacing;
                self.dc.fillRect(right_x, 0, scaled_spacing, self.height, self.config.bg);
            }
            pending_gap = drew;
        }
    }

    fn drawAll(self: *State, snap: *const BarSnapshot) !void {
        if (snap.title_invalidated) self.cached_title_window = null;
        if (snap.dirty_all) self.dc.fillRect(0, 0, self.width, self.height, self.config.bg);
        const scaled_spacing = self.config.scaledSpacing(self.height);
        // Recompute right_total only when ws_count changes.
        if (snap.ws_count != self.cached_right_total_ws_count) {
            var right_total: u16 = 0;
            for (self.config.layout.items) |layout| {
                if (layout.position != .right) continue;
                for (layout.segments.items) |seg| right_total += self.calculateSegmentWidth(snap, seg) + scaled_spacing;
                if (layout.segments.items.len > 0) right_total -= scaled_spacing;
            }
            self.cached_right_total          = right_total;
            self.cached_right_total_ws_count = snap.ws_count;
        }
        const right_total = self.cached_right_total;
        var title_seg_x: u16 = 0;
        var title_seg_w: u16 = 0;
        var x: u16 = 0;
        for (self.config.layout.items) |layout| {
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
                            self.dc.fillRect(x, 0, scaled_spacing, self.height, self.config.bg);
                            x += scaled_spacing;
                        }
                    }
                },
                .center => {
                    const remaining = @max(100, self.width -| x -| right_total -| scaled_spacing);
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
                                self.dc.fillRect(x, 0, scaled_spacing, self.height, self.config.bg);
                                x += scaled_spacing;
                            }
                        }
                    }
                },
                .right => try self.drawRightSegments(snap, layout.segments.items),
            }
        }
        self.dc.flush();
        if (title_seg_w > 0) self.updateTitleCache(snap, title_seg_x, title_seg_w);
    }

    fn drawClockOnly(self: *State) void {
        const clock_x = self.cached_clock_x orelse return;
        _ = clock_segment.draw(self.dc, self.config, self.height, clock_x) catch |e| debug.warnOnErr(e, "drawClockOnly");
        self.dc.flush();
    }

    fn drawTitleOnly(self: *State, new_focused: ?u32) void {
        if (prompt.isActive()) return;
        if (!self.title_layout_valid or self.cached_title_w == 0) return;
        self.cached_focused_window = new_focused;
        // Fast path: carousel.drawCarouselTick handles its own flush and returns true on success.
        // Use minimized accent when the sole workspace window is minimized.
        if (carousel.isCarouselActive()) {
            const accent: u32 = if (self.cached_ws_wins.items.len == 1 and
                self.cached_minimized_set.contains(self.cached_ws_wins.items[0]))
                self.config.title_minimized_accent
            else
                self.config.title_accent_color;
            if (carousel.drawCarouselTick(self.dc, accent, self.height,
                    self.cached_title_x, self.cached_title_w)) return;
        }
        _ = title_segment.draw(
            self.dc, self.config, self.height,
            self.cached_title_x, self.cached_title_w,
            self.conn, new_focused,
            self.cached_title.items,
            self.cached_ws_wins.items, &self.cached_minimized_set,
            &self.cached_title, &self.cached_title_window,
            false, self.allocator,
        ) catch |e| { debug.warnOnErr(e, "drawTitleOnly"); return; };
        self.dc.flush();
    }

    fn updateTitleCache(self: *State, snap: *const BarSnapshot, x: u16, w: u16) void {
        self.cached_ws_wins.clearRetainingCapacity();
        self.cached_ws_wins.appendSlice(self.allocator, snap.current_ws_wins.items) catch {};
        self.cached_minimized_set.deinit(self.allocator);
        self.cached_minimized_set = snap.minimized_set.clone(self.allocator) catch .{};
        self.cached_focused_window = snap.focused_window;
        self.cached_title_x     = x;
        self.cached_title_w     = w;
        self.title_layout_valid = true;
    }
};

/// Carousel frame interval — 165 Hz (1_000_000_000 / 165 ≈ 6_060_606 ns).
const CAROUSEL_WAKE_NS: u64 = 6_060_606;

fn barThreadFn(s: *State) void {
    // Absolute monotonic deadline for next carousel frame; late wakes don't compound.
    var next_carousel_ns: u64 = 0;
    while (true) {
        g_channel.mutex.lock();
        while (!g_channel.quit and !g_channel.snap_ready and
               !g_channel.clock_dirty and !g_channel.focus_dirty)
        {
            if (carousel.isCarouselActive()) {
                const now_ns = monoNowNs();
                if (now_ns >= next_carousel_ns) {
                    break;
                }
                const remaining = next_carousel_ns - now_ns;
                g_channel.work_cond.timedWait(&g_channel.mutex, remaining) catch {};
                break;
            } else {
                next_carousel_ns = 0;
                g_channel.work_cond.wait(&g_channel.mutex);
            }
        }
        if (g_channel.quit) { g_channel.mutex.unlock(); return; }
        const snap_ready    = g_channel.snap_ready;
        const read_idx: u1  = 1 - g_channel.write_idx;
        const do_clock      = g_channel.clock_dirty and !snap_ready;
        const do_focus      = g_channel.focus_dirty and !snap_ready;
        const focus_new_win = g_channel.focus_new_win;
        g_channel.snap_ready    = false;
        g_channel.clock_dirty   = false;
        g_channel.focus_dirty   = false;
        g_channel.focus_new_win = null;
        g_channel.mutex.unlock();
        if (snap_ready) {
            s.drawAll(&g_channel.slots[read_idx]) catch |e| debug.warnOnErr(e, "bar thread drawAll");
            g_channel.mutex.lock();
            g_channel.draw_gen += 1;
            g_channel.done_cond.broadcast();
            g_channel.mutex.unlock();
        } else {
            if (do_focus) {
                s.drawTitleOnly(focus_new_win);
            } else if (carousel.isCarouselActive()) {
                s.drawTitleOnly(s.cached_focused_window);
                if (next_carousel_ns == 0) next_carousel_ns = monoNowNs();
                next_carousel_ns +%= CAROUSEL_WAKE_NS;
            }
            if (do_clock) s.drawClockOnly();
        }
    }
}

inline fn monoNowNs() u64 {
    var ts: std.os.linux.timespec = undefined;
    _ = std.os.linux.clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * 1_000_000_000 + @as(u64, @intCast(ts.nsec));
}

inline fn startBarThread(s: *State) void {
    g_bar_thread = std.Thread.spawn(.{}, barThreadFn, .{s}) catch |e| {
        debug.warnOnErr(e, "Failed to start bar render thread"); return;
    };
}

fn stopBarThread() void {
    g_channel.mutex.lock();
    g_channel.quit        = true;
    g_channel.snap_ready  = false;
    g_channel.focus_dirty = false;
    g_channel.clock_dirty = false;
    g_channel.work_cond.signal();
    g_channel.mutex.unlock();
    if (g_bar_thread) |t| { t.join(); g_bar_thread = null; }
    g_channel.quit = false;
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
    const allocator = s.allocator;
    snap.status_text.clearRetainingCapacity();
    try snap.status_text.appendSlice(allocator, s.status_text.items);
    snap.minimized_set.clearRetainingCapacity();
    if (minimize.getStateOpt()) |ms| {
        try snap.minimized_set.ensureTotalCapacity(allocator, ms.minimized_info.count());
        var it = ms.minimized_info.keyIterator();
        while (it.next()) |key| snap.minimized_set.putAssumeCapacity(key.*, {});
    }

    const ws_state = workspaces.getState() orelse return;
    snap.ws_count   = @intCast(ws_state.workspaces.len);
    snap.ws_current = ws_state.current;
    try snap.ws_has_windows.resize(allocator, snap.ws_count);
    for (ws_state.workspaces, 0..) |*workspace, i|
        snap.ws_has_windows.items[i] = workspace.windows.count() > 0;
    snap.current_ws_wins.clearRetainingCapacity();
    if (ws_state.current < ws_state.workspaces.len)
        try snap.current_ws_wins.appendSlice(allocator, ws_state.workspaces[ws_state.current].windows.items());
    snap.focused_window = focus.getFocused();
    snap.title_invalidated = s.title_invalidated;
    s.title_invalidated    = false;
    snap.focused_title.clearRetainingCapacity();
    if (snap.focused_window) |fw| {
        if (snap.focused_window != prev.focused_window or snap.title_invalidated) {
            title_segment.fetchFocusedTitleInto(core.conn, fw, &snap.focused_title, allocator) catch {};
        } else {
            snap.focused_title.appendSlice(allocator, prev.focused_title.items) catch {};
        }
    }

    const forced = g_channel.force_dirty_all;
    g_channel.force_dirty_all = false;
    snap.dirty_all = forced or (snap.ws_count != prev.ws_count);
    snap.dirty_ws  = snap.dirty_all or
        snap.ws_current != prev.ws_current or
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
fn forceRedraw() void { g_channel.force_dirty_all = true; submitDraw(true); }

/// Ungrab the X server and flush. Always called as a pair.
inline fn ungrabAndFlush() void {
    _ = xcb.xcb_ungrab_server(core.conn);
    _ = xcb.xcb_flush(core.conn);
}

/// Posts a snapshot to the bar thread; `wait = true` blocks until the draw completes.
pub fn submitDraw(wait: bool) void {
    const s = state orelse return;
    if (!s.visible) return;
    const idx = g_channel.write_idx;
    captureIntoSlot(s, &g_channel.slots[idx], &g_channel.slots[1 - idx]) catch |e| {
        debug.warnOnErr(e, "bar captureIntoSlot");
        return;
    };
    g_channel.mutex.lock();
    defer g_channel.mutex.unlock();
    g_channel.write_idx ^= 1;
    g_channel.snap_ready = true;
    const gen_before = g_channel.draw_gen;
    g_channel.work_cond.signal();
    if (wait) {
        while (g_channel.draw_gen == gen_before)
            g_channel.done_cond.wait(&g_channel.mutex);
    }
}

var state: ?*State = null;

var g_atoms: struct {
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
} = .{};

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
        @field(g_atoms, e[0]) = utils.getAtomCached(e[1]) catch 0;
}

fn barYPos(height: u16) i16 {
    return if (core.config.bar.vertical_position == .bottom)
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
    const strut: [12]u32 = if (core.config.bar.vertical_position == .top)
        .{ 0, 0, 0, height, 0, 0, 0, 0, 0, 0, 0, core.screen.width_in_pixels }
    else
        .{ 0, 0, height, 0, 0, 0, 0, 0, 0, core.screen.width_in_pixels, 0, 0 };
    if (g_atoms.strut_partial    != 0) setPropAtom(core.conn, window, g_atoms.strut_partial,    xcb.XCB_ATOM_CARDINAL, &strut);
    if (g_atoms.window_type      != 0) setPropAtom(core.conn, window, g_atoms.window_type,      xcb.XCB_ATOM_ATOM, &[_]u32{g_atoms.window_type_dock});
    if (g_atoms.wm_state         != 0) setPropAtom(core.conn, window, g_atoms.wm_state,         xcb.XCB_ATOM_ATOM, &[_]u32{g_atoms.state_above, g_atoms.state_sticky});
    if (g_atoms.allowed_actions  != 0) setPropAtom(core.conn, window, g_atoms.allowed_actions,  xcb.XCB_ATOM_ATOM, &[_]u32{g_atoms.action_close, g_atoms.action_above, g_atoms.action_stick});
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
    state = try State.init(core.alloc, core.conn, setup.window, setup.colormap,
        core.screen.width_in_pixels, height, dc, core.config.bar);
    startBarThread(state.?);
    submitDraw(true);
    _ = xcb.xcb_map_window(core.conn, setup.window);
    _ = xcb.xcb_flush(core.conn);
}

pub fn deinit() void {
    stopBarThread();
    if (state) |s| {
        carousel.deinitCarousel();
        for (&g_channel.slots) |*slot| slot.deinit(s.allocator);
        _ = xcb.xcb_destroy_window(s.conn, s.window);
        s.dc.deinit();
        drawing.deinitFontCache(s.allocator);
        s.deinit();
        state = null;
    }
}

pub fn reload() void {
    const old = state orelse {
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
    state = new_state;
    startBarThread(new_state);
    forceRedraw();
    if (new_state.visible) _ = xcb.xcb_map_window(core.conn, setup.window);
    _ = xcb.xcb_destroy_window(core.conn, old.window);
    ungrabAndFlush();
    old.dc.deinit();
    old.deinit();
}

pub fn toggleBarPosition() void {
    const s = state orelse return;
    core.config.bar.vertical_position = switch (core.config.bar.vertical_position) {
        .top    => .bottom,
        .bottom => .top,
    };
    const new_y = barYPos(s.height);
    setWindowProperties(s.window, s.height);
    g_channel.force_dirty_all = true;
    s.invalidateLayout();
    _ = xcb.xcb_grab_server(core.conn);
    _ = xcb.xcb_configure_window(core.conn, s.window, xcb.XCB_CONFIG_WINDOW_Y,
        &[_]u32{@as(u32, @bitCast(@as(i32, new_y)))});
    const current_ws = workspaces.getCurrentWorkspace() orelse {
        ungrabAndFlush();
        return;
    };
    if (fullscreen.getForWorkspace(current_ws) == null)
        if (comptime build_options.has_tiling) tiling.retileCurrentWorkspace();
    ungrabAndFlush();
    debug.info("Bar position toggled to: {s}", .{@tagName(core.config.bar.vertical_position)});
}

/// Lightweight focus-only redraw; skipped when a full redraw is already pending.
pub fn scheduleFocusRedraw(new_win: ?u32) void {
    const s = state orelse return;
    if (!s.visible or s.dirty) return;
    g_channel.mutex.lock();
    if (!g_channel.snap_ready) {
        g_channel.focus_dirty   = true;
        g_channel.focus_new_win = new_win;
        g_channel.work_cond.signal();
    }
    g_channel.mutex.unlock();
}

pub fn getBarWindow() u32        { return if (state) |s| s.window else 0; }
pub fn isBarWindow(win: u32) bool { return if (state) |s| s.window == win else false; }
pub fn getBarHeight() u16         { return if (state) |s| s.height else 0; }
pub fn isBarInitialized() bool    { return state != null; }
pub fn hasClockSegment() bool     { return if (state) |s| s.has_clock_segment else false; }
/// Schedules a full bar redraw, coalesced via updateIfDirty. Zero X11 I/O on caller.
pub fn scheduleRedraw() void        { if (state) |s| if (s.visible) s.setDirty(); }
/// Like scheduleRedraw but forces a full bar clear+redraw regardless of dirty flags.
/// Use when a segment's presence or width changes (e.g. layout switch) so stale
/// pixels from the previous render are guaranteed to be erased.
pub fn scheduleFullRedraw() void {
    if (state) |s| if (s.visible) {
        g_channel.force_dirty_all = true;
        s.setDirty();
    };
}
pub fn isVisible() bool             { return if (state) |s| s.visible else false; }
pub fn getGlobalVisibility() bool   { return if (state) |s| s.global_visible else false; }
pub fn setGlobalVisibility(visible: bool) void { if (state) |s| s.global_visible = visible; }

/// Synchronous redraw — blocks until done. Use only inside/before xcb_ungrab_server.
pub fn redrawInsideGrab() void {
    const s = state orelse return;
    if (s.visible) { submitDraw(true); s.dirty = false; }
}

pub fn raiseBar() void {
    if (state) |s| _ = xcb.xcb_configure_window(s.conn, s.window, xcb.XCB_CONFIG_WINDOW_STACK_MODE, &[_]u32{xcb.XCB_STACK_MODE_ABOVE});
}

pub fn setBarState(action: BarAction) void {
    const s = state orelse return;
    if (action == .toggle) s.global_visible = !s.global_visible;
    const current_ws    = workspaces.getCurrentWorkspace() orelse 0;
    const is_fullscreen = action != .hide_fullscreen and
        fullscreen.getForWorkspace(current_ws) != null;
    const show = !is_fullscreen and s.global_visible and action != .hide_fullscreen;
    if (s.visible == show and action != .toggle) return;
    s.visible = show;
    if (action == .toggle) {
        if (show) forceRedraw();
        _ = xcb.xcb_grab_server(core.conn);
        if (show) _ = xcb.xcb_map_window(core.conn, s.window)
        else      _ = xcb.xcb_unmap_window(core.conn, s.window);
        const saved = s.visible;
        if (is_fullscreen) s.visible = s.global_visible;
        retileAllWorkspacesNoGrab();
        if (is_fullscreen) s.visible = saved;
        ungrabAndFlush();
    } else {
        if (show) {
            forceRedraw();
            _ = xcb.xcb_map_window(core.conn, s.window);
        } else {
            _ = xcb.xcb_unmap_window(core.conn, s.window);
        }
        _ = xcb.xcb_flush(core.conn);
        if (comptime build_options.has_tiling) tiling.retileCurrentWorkspace();
    }

    debug.info("Bar {s} ({s})", .{ if (show) "shown" else "hidden", @tagName(action) });
    clock_segment.updateTimerState();
}

pub fn updateIfDirty() !void {
    const s = state orelse return;
    if (!s.visible) return;
    if (prompt.consumeRedrawRequest()) { g_channel.force_dirty_all = true; s.dirty = true; }
    if (s.dirty) { submitDraw(false); s.dirty = false; }
}

inline fn signalWork() void {
    g_channel.mutex.lock();
    g_channel.work_cond.signal();
    g_channel.mutex.unlock();
}

pub fn checkClockUpdate() void {
    const s = state orelse return;
    if (s.visible) { g_channel.clock_dirty = true; signalWork(); }
}

pub fn pollTimeoutMs() i32     { return clock_segment.pollTimeoutMs(); }
pub fn updateTimerState() void { clock_segment.updateTimerState(); }

pub fn handleExpose(event: *const xcb.xcb_expose_event_t) void {
    if (state) |s| if (event.window == s.window and event.count == 0) {
        g_channel.force_dirty_all = true; if (drag.isDragging()) s.dirty = true else submitDraw(false);
    };
}

pub fn handlePropertyNotify(event: *const xcb.xcb_property_notify_event_t) void {
    const s = state orelse return;
    if (event.window == core.root and event.atom == xcb.XCB_ATOM_WM_NAME) {
        status_segment.update(&s.status_text, s.allocator) catch |e|
            debug.warnOnErr(e, "status_segment.update");
        s.setDirty();
        return;
    }

    const focused_win = focus.getFocused() orelse return;
    if (event.window != focused_win) return;
    const net_wm_name = s.net_wm_name_atom;
    if (event.atom == xcb.XCB_ATOM_WM_NAME or (net_wm_name != 0 and event.atom == net_wm_name)) {
        s.title_invalidated = true;
        s.setDirty();
    }
}

pub fn monitorFocusedWindow() void {
    const win = focus.getFocused() orelse return;
    const s   = state orelse return;
    if (s.last_monitored_window == win) return;
    if (s.last_monitored_window) |old_win|
        _ = xcb.xcb_change_window_attributes(core.conn, old_win,
            xcb.XCB_CW_EVENT_MASK, &[_]u32{constants.EventMasks.MANAGED_WINDOW});
    s.last_monitored_window = win;
    _ = xcb.xcb_change_window_attributes(core.conn, win,
        xcb.XCB_CW_EVENT_MASK,
        &[_]u32{constants.EventMasks.MANAGED_WINDOW | xcb.XCB_EVENT_MASK_PROPERTY_CHANGE});
}

pub fn handleButtonPress(event: *const xcb.xcb_button_press_event_t) void {
    if (state) |s| if (event.event == s.window) {
        const ws_state = workspaces.getState() orelse return;
        const ws_w     = workspaces_segment.getCachedWorkspaceWidth();
        if (ws_w == 0) return;
        const click_x           = @max(0, event.event_x - s.cached_workspace_x);
        const clicked_ws: usize = @intCast(@divFloor(click_x, ws_w));
        if (clicked_ws < ws_state.workspaces.len) {
            workspaces.switchTo(clicked_ws);
            s.setDirty();
        }
    };
}

fn retileAllWorkspacesNoGrab() void {
    if (comptime !build_options.has_tiling) return;
    const ws_state = workspaces.getState() orelse return;
    const tiling_active = core.config.tiling.enabled and
        if (tiling.getStateOpt()) |t| t.enabled else false;
    if (!tiling_active) { tiling.retileCurrentWorkspace(); return; }
    for (ws_state.workspaces, 0..) |*ws, idx| {
        if (ws.windows.isEmpty()) continue;
        if (fullscreen.getForWorkspace(@intCast(idx)) != null) continue;
        if (@as(u8, @intCast(idx)) == ws_state.current) {
            tiling.retileCurrentWorkspace();
        } else {
            tiling.retileInactiveWorkspace(@intCast(idx));
        }
    }
}
