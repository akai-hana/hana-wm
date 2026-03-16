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

const bar_flags = @import("bar_flags");

pub const BarAction = enum { toggle, hide_fullscreen, show_fullscreen };
const build_options = @import("build_options");
const drawing    = @import("drawing");
const tiling     = if (build_options.has_tiling) @import("tiling") else struct {};
const drag       = @import("drag");
const utils      = @import("utils");
const workspaces = @import("workspaces");
const focus    = @import("focus");
const constants  = @import("constants");
const minimize   = @import("minimize");
const dpi_mod    = @import("dpi");

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

// Snapshot 

/// Point-in-time bar state. Lives in BarChannel.slots[]; never heap-allocated.
/// Variable-length fields use ArrayListUnmanaged so buffers grow only when
/// workspace/window counts increase — reused across frames at stable capacity.
const BarSnapshot = struct {
    focused_window:    ?u32                          = null,
    /// Title of the focused window, fetched on the main thread during
    /// captureIntoSlot — never fetched by the bar thread.
    focused_title:     std.ArrayListUnmanaged(u8)    = .empty,
    current_ws_wins:   std.ArrayListUnmanaged(u32)   = .empty,
    /// O(1) set for minimized window membership checks during rendering.
    minimized_set:     std.AutoHashMapUnmanaged(u32, void)  = .{},
    ws_has_windows:    std.ArrayListUnmanaged(bool)  = .empty,
    ws_current:        u8                            = 0,
    ws_count:          u32                           = 0,
    status_text:       std.ArrayListUnmanaged(u8)    = .empty,
    title_invalidated: bool                          = false,
    /// Per-segment dirty flags, computed during captureIntoSlot by comparing
    /// against the previous snapshot. drawAll uses these to skip segments
    /// whose inputs have not changed, avoiding unnecessary Pango layout passes.
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

// Channel 

/// Lock-based channel between main thread (producer) and bar thread (consumer).
///
/// Double-buffer protocol — zero heap allocation per frame:
///   - main  writes into slots[write_idx], then flips write_idx under mutex
///   - bar   reads  from slots[1 - write_idx] (the just-filled slot)
/// Since write_idx is only mutated by the main thread, reading it outside
/// the lock before writing is safe; the mutex acquire before the flip
/// establishes the required memory fence for the bar thread.
const BarChannel = struct {
    mutex:         std.Thread.Mutex     = .{},
    work_cond:     std.Thread.Condition = .{},
    done_cond:     std.Thread.Condition = .{},
    slots:         [2]BarSnapshot       = .{ .{}, .{} },
    write_idx:     u1                   = 0,
    snap_ready:       bool  = false,
    clock_dirty:      bool  = false,
    quit:             bool  = false,
    draw_gen:         u64   = 0,
    focus_dirty:      bool  = false,
    focus_new_win:    ?u32  = null,
    /// Set by callers (main thread only) that require a full bar redraw
    /// regardless of per-segment dirty state: expose events, bar show/hide,
    /// config reload, bar position toggle.  Consumed and cleared by
    /// captureIntoSlot on the next submitDraw.
    force_dirty_all:  bool  = false,
};

var g_channel: BarChannel     = .{};
var g_bar_thread: ?std.Thread = null;

// State 

const State = struct {
    window:               u32,
    colormap:             u32,
    width:                u16,
    height:               u16,
    dc:                   *drawing.DrawContext,
    conn:                 *xcb.xcb_connection_t,
    config:               core.BarConfig,
    status_text:          std.ArrayList(u8),
    cached_title:         std.ArrayList(u8),
    cached_title_window:  ?u32,
    dirty:                bool,
    title_invalidated:    bool,
    visible:              bool,
    global_visible:       bool,
    allocator:            std.mem.Allocator,
    cached_clock_width:   u16,
    cached_clock_x:       ?u16,
    cached_workspace_x:   u16,
    has_clock_segment:    bool,
    cached_title_x:       u16,
    cached_title_w:       u16,
    cached_ws_wins:       std.ArrayListUnmanaged(u32),
    cached_minimized_set: std.AutoHashMapUnmanaged(u32, void),
    /// Focused window ID cached from the last full draw; used for carousel
    /// partial redraws that need the current focus without a new snapshot.
    cached_focused_window: ?u32,
    title_layout_valid:   bool,
    cached_right_total:              u16,
    cached_right_total_ws_count:     u32, // invalidation key for cached_right_total
    last_monitored_window:       ?u32,
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
            .window               = window,
            .colormap             = colormap,
            .width                = width,
            .height               = height,
            .dc                   = dc,
            .conn                 = conn,
            .config               = config,
            .status_text          = std.ArrayList(u8).empty,
            .cached_title         = std.ArrayList(u8).empty,
            .cached_title_window  = null,
            .dirty                = false,
            .title_invalidated    = false,
            .visible              = true,
            .global_visible       = true,
            .allocator            = allocator,
            .cached_clock_width   = dc.textWidth(clock_segment.SAMPLE_STRING) + 2 * config.scaledSegmentPadding(height),
            .cached_clock_x       = null,
            .cached_workspace_x   = 0,
            .has_clock_segment    = blk: {
                if (comptime !bar_flags.has_clock) break :blk false;
                for (config.layout.items) |layout|
                    for (layout.segments.items) |seg|
                        if (seg == .clock) break :blk true;
                break :blk false;
            },
            .cached_title_x       = 0,
            .cached_title_w       = 0,
            .cached_ws_wins       = .empty,
            .cached_minimized_set = .{},
            .cached_focused_window = null,
            .title_layout_valid   = false,
            .cached_right_total          = 0,
            .cached_right_total_ws_count = std.math.maxInt(u32),
            .last_monitored_window       = null,
            .net_wm_name_atom            = utils.getAtomCached("_NET_WM_NAME") catch 0,
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

    /// Marks the bar content as stale so the next updateIfDirty triggers a full
    /// redraw. Does NOT invalidate cached_clock_x: the clock's X position is
    /// determined solely by bar width and layout config, both of which are fixed
    /// between reloads. Nulling it on every dirty mark would cause drawClockOnly
    /// to silently bail for any clock tick that races a concurrent full-redraw,
    /// delaying the clock display by up to one second unnecessarily.
    fn setDirty(self: *State) void { self.dirty = true; }

    /// Marks the bar dirty AND resets all layout-derived position caches.
    /// Call this whenever the bar geometry or config changes (resize, reload,
    /// position toggle, transparency toggle) — i.e. whenever the clock's pixel
    /// X position may have moved.
    fn invalidateLayout(self: *State) void {
        self.dirty          = true;
        self.cached_clock_x = null;
    }

    // Segment drawing (bar thread only)

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

    fn drawRightSegments(self: *State, snap: *const BarSnapshot, segments: []const core.BarSegment) !void {
        var right_x          = self.width;
        const scaled_spacing = self.config.scaledSpacing(self.height);
        var i = segments.len;
        while (i > 0) {
            i -= 1;
            right_x -= self.calculateSegmentWidth(snap, segments[i]);
            if (segments[i] == .clock) self.cached_clock_x = right_x;
            _ = try self.drawSegment(snap, segments[i], right_x, null);
            if (i > 0) right_x -= scaled_spacing;
        }
    }

    fn drawAll(self: *State, snap: *const BarSnapshot) !void {
        if (snap.title_invalidated) self.cached_title_window = null;
        // Fill the whole bar background only on a full redraw.  Partial redraws
        // skip this: non-dirty segments retain their previous pixels (which are
        // correct since their inputs did not change), and every "always-draw"
        // segment (layout, variations, clock, status) fills its own background.
        if (snap.dirty_all) self.dc.fillRect(0, 0, self.width, self.height, self.config.bg);

        const scaled_spacing = self.config.scaledSpacing(self.height);

        // Recompute right_total only when workspace count changes; the layout
        // config is constant between reloads, and ws_count is the only runtime
        // variable that affects right-side segment widths.
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
                    const skip = !snap.dirty_all and switch (seg) {
                        .workspaces => !snap.dirty_ws,
                        .title      => !snap.dirty_title,
                        else        => false,
                    };
                    if (skip) { x += seg_w; } else { x = try self.drawSegment(snap, seg, x, null); }
                    x += scaled_spacing;
                },
                .center => {
                    const remaining = @max(100, self.width -| x -| right_total -| scaled_spacing);
                    for (layout.segments.items) |seg| {
                        const w = if (seg == .title) remaining else self.calculateSegmentWidth(snap, seg);
                        if (seg == .title) { title_seg_x = x; title_seg_w = w; }
                        const skip = !snap.dirty_all and switch (seg) {
                            .workspaces => !snap.dirty_ws,
                            .title      => !snap.dirty_title,
                            else        => false,
                        };
                        if (skip) { x += w; } else { x = try self.drawSegment(snap, seg, x, w); }
                        if (seg != .title) x += scaled_spacing;
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
        _ = clock_segment.draw(self.dc, self.config, self.height, clock_x) catch |e|
            debug.warnOnErr(e, "drawClockOnly");
        self.dc.flush();
    }

    fn drawTitleOnly(self: *State, new_focused: ?u32) void {
        if (prompt.isActive()) return;
        if (!self.title_layout_valid or self.cached_title_w == 0) return;

        // Keep cached_focused_window current so that carousel ticks fired
        // after a do_focus draw use the correct focused window.
        // When called from the carousel tick path new_focused IS already
        // cached_focused_window, so this is a no-op in the common case.
        self.cached_focused_window = new_focused;

        // Fast path: if the single-window carousel is active, skip the full
        // title.draw() — no Pango, no cairo_surface_flush, no full-bar blit.
        // carousel.drawCarouselTick includes its own targeted flushRect, so
        // the outer dc.flush() at the end of this function is intentionally
        // skipped when the fast path fires.
        // Use the minimized accent when the sole workspace window is minimized
        // so the gap area (filled by fillRect) matches the pixmap background.
        if (carousel.isCarouselActive()) {
            const accent: u32 = if (self.cached_ws_wins.items.len == 1 and
                self.cached_minimized_set.contains(self.cached_ws_wins.items[0]))
                self.config.getTitleMinimizedAccent()
            else
                self.config.getTitleAccent();
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
        // Sync the window list using clearRetainingCapacity + appendSlice so
        // the buffer grows only when needed, matching the pattern used by all
        // other cached collections on State.
        self.cached_ws_wins.clearRetainingCapacity();
        self.cached_ws_wins.appendSlice(self.allocator, snap.current_ws_wins.items) catch {};
        // Mirror the snapshot's minimized set so drawTitleOnly renders correct
        // segment order and colors without a full redraw.
        self.cached_minimized_set.clearRetainingCapacity();
        var it = snap.minimized_set.keyIterator();
        while (it.next()) |key|
            self.cached_minimized_set.put(self.allocator, key.*, {}) catch {};
        self.cached_focused_window = snap.focused_window;
        self.cached_title_x     = x;
        self.cached_title_w     = w;
        self.title_layout_valid = true;
    }
};

// Bar thread 

/// Interval at which the bar thread self-wakes to advance the carousel, in ns.
/// Matches 165 Hz (1_000_000_000 / 165 ≈ 6_060_606 ns).
const CAROUSEL_WAKE_NS: u64 = 6_060_606;

fn barThreadFn(s: *State) void {
    // Absolute deadline for the next carousel frame.
    // Tracked in monotonic nanoseconds so each sleep targets the next fixed
    // point in time — late wakes don't compound into accumulated drift.
    var next_carousel_ns: u64 = 0;

    while (true) {
        g_channel.mutex.lock();

        while (!g_channel.quit and !g_channel.snap_ready and
               !g_channel.clock_dirty and !g_channel.focus_dirty)
        {
            if (carousel.isCarouselActive()) {
                // Compute remaining sleep to the next absolute deadline.
                const now_ns = monoNowNs();
                if (now_ns >= next_carousel_ns) {
                    // Deadline already passed (first frame or we slept long) — fire now.
                    break;
                }
                const remaining = next_carousel_ns - now_ns;
                g_channel.work_cond.timedWait(&g_channel.mutex, remaining) catch {};
                break;
            } else {
                next_carousel_ns = 0; // reset so first active frame fires immediately
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
                // Advance deadline by exactly one frame interval so cadence is
                // steady regardless of how long the draw + OS scheduling took.
                if (next_carousel_ns == 0) next_carousel_ns = monoNowNs();
                next_carousel_ns +%= CAROUSEL_WAKE_NS;
            }
            if (do_clock) s.drawClockOnly();
        }
    }
}

/// Monotonic clock in nanoseconds. Used for absolute-deadline carousel sleep.
inline fn monoNowNs() u64 {
    const ts = std.posix.clock_gettime(.MONOTONIC) catch return 0;
    return @as(u64, @intCast(ts.sec)) * 1_000_000_000 + @as(u64, @intCast(ts.nsec));
}

fn startBarThread(s: *State) void {
    g_bar_thread = std.Thread.spawn(.{}, barThreadFn, .{s}) catch |e| {
        debug.warnOnErr(e, "Failed to start bar render thread");
        return;
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
    g_channel.quit = false; // Reset so the channel can be reused on the next init/reload.
}

// Snapshot capture (main thread) 

/// Populates a pre-allocated BarSnapshot slot in-place.
/// All variable-length fields use ArrayListUnmanaged that grow only when
/// their content exceeds the previously allocated capacity.
fn captureIntoSlot(s: *State, snap: *BarSnapshot, prev: *const BarSnapshot) !void {
    const allocator = s.allocator;

    // Status text.
    snap.status_text.clearRetainingCapacity();
    try snap.status_text.appendSlice(allocator, s.status_text.items);

    // Minimized window set — O(1) membership checks during rendering.
    snap.minimized_set.clearRetainingCapacity();
    if (minimize.getStateOpt()) |ms| {
        try snap.minimized_set.ensureTotalCapacity(allocator, ms.minimized_info.count());
        var it = ms.minimized_info.keyIterator();
        while (it.next()) |key| snap.minimized_set.putAssumeCapacity(key.*, {});
    }

    // Workspace state.
    const ws_state = workspaces.getState() orelse return;
    snap.ws_count   = @intCast(ws_state.workspaces.len);
    snap.ws_current = ws_state.current;

    try snap.ws_has_windows.resize(allocator, snap.ws_count);
    for (ws_state.workspaces, 0..) |*workspace, i|
        snap.ws_has_windows.items[i] = workspace.windows.count() > 0;

    // Current workspace window list.
    snap.current_ws_wins.clearRetainingCapacity();
    if (ws_state.current < ws_state.workspaces.len)
        try snap.current_ws_wins.appendSlice(allocator, ws_state.workspaces[ws_state.current].windows.items());

    snap.focused_window = focus.getFocused();
    snap.title_invalidated = s.title_invalidated;
    s.title_invalidated    = false;

    // Fetch the focused window title here, on the main thread, so the bar
    // thread never makes blocking X11 round-trips during rendering.
    // fetchPropertyToBuffer reuses the existing ArrayList buffer, growing
    // only when the title exceeds the previously allocated capacity.
    snap.focused_title.clearRetainingCapacity();
    if (snap.focused_window) |fw| {
        title_segment.fetchFocusedTitleInto(core.conn, fw, &snap.focused_title, allocator) catch {};
    }

    // Compute per-segment dirty flags by comparing against the previous snapshot.
    // force_dirty_all is set by callers that need a full redraw regardless of
    // content changes (expose, show, reload, position toggle).
    const forced = g_channel.force_dirty_all;
    g_channel.force_dirty_all = false;

    snap.dirty_all = forced or (snap.ws_count != prev.ws_count);
    snap.dirty_ws  = snap.dirty_all or
        snap.ws_current != prev.ws_current or
        !std.mem.eql(bool, snap.ws_has_windows.items, prev.ws_has_windows.items);
    snap.dirty_title =
        snap.focused_window != prev.focused_window or
        snap.title_invalidated or
        !std.mem.eql(u8,  snap.focused_title.items,  prev.focused_title.items)   or
        !std.mem.eql(u32, snap.current_ws_wins.items, prev.current_ws_wins.items) or
        snap.minimized_set.count() != prev.minimized_set.count();
}

/// Posts a snapshot to the bar thread. `wait = true` blocks until the draw
/// completes — use this inside xcb_grab_server regions.
///
/// write_idx is only mutated by the main thread, so reading it without the
/// lock is safe here. The mutex acquire before the flip acts as the fence.
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


// Module singleton 

var state: ?*State = null;

// Pre-interned atoms 

/// All atoms needed by setWindowProperties, interned once at bar init.
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
    // colormap is 0 when opaque; value_mask omits XCB_CW_COLORMAP in that case,
    // so XCB reads only the first four values and the trailing 0 is ignored.
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
    const scaled_size = core.config.bar.scaled_font_size;
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

fn resolvePercentageFontSize(bar_height: u16) ?u16 {
    const TRIAL_PT: u16 = 100;
    const saved_size = core.config.bar.scaled_font_size;
    core.config.bar.scaled_font_size = TRIAL_PT;
    defer core.config.bar.scaled_font_size = saved_size;

    var mc = drawing.MeasureContext.init(core.alloc, core.dpi_info.dpi) catch |e| {
        debug.warnOnErr(e, "MeasureContext.init in resolvePercentageFontSize");
        return null;
    };
    defer mc.deinit();
    loadBarFonts(&mc) catch return null;

    const asc, const desc = mc.getMetrics();
    const px_per_pt: f32  = @as(f32, @floatFromInt(@max(1, asc + desc))) / @as(f32, @floatFromInt(TRIAL_PT));
    const max_size_pt     = @as(f32, @floatFromInt(bar_height)) / px_per_pt;
    return @max(1, @as(u16, @intFromFloat(@round(max_size_pt * (core.config.bar.font_size.value / 100.0)))));
}

fn calculateBarHeight() !u16 {
    if (core.config.bar.height) |h| {
        const height = dpi_mod.scaleBarHeight(h, core.screen.height_in_pixels);
        if (core.config.bar.font_size.is_percentage) {
            if (resolvePercentageFontSize(height)) |sz|
                core.config.bar.scaled_font_size = sz;
        }
        return height;
    }

    var mc = drawing.MeasureContext.init(core.alloc, core.dpi_info.dpi) catch |e| {
        debug.warnOnErr(e, "MeasureContext.init in calculateBarHeight");
        return DEFAULT_BAR_HEIGHT;
    };
    defer mc.deinit();
    loadBarFonts(&mc) catch {
        debug.warn("Failed to load fonts for height calculation, using default", .{});
        return DEFAULT_BAR_HEIGHT;
    };

    const asc, const desc = mc.getMetrics();
    return @intCast(std.math.clamp(@as(u32, @intCast(asc + desc)), MIN_BAR_HEIGHT, MAX_BAR_HEIGHT));
}

// Public API 

pub fn init() !void {
    // Precondition: caller must check core.config.bar.enabled before calling.
    std.debug.assert(core.config.bar.enabled);
    initAtoms();
    drawing.initFontCache(core.alloc);

    const height = try calculateBarHeight();
    const y_pos  = barYPos(height);
    const setup  = createBarWindow(height, y_pos);
    errdefer { _ = xcb.xcb_destroy_window(core.conn, setup.window); if (setup.colormap != 0) _ = xcb.xcb_free_colormap(core.conn, setup.colormap); }

    setWindowProperties(setup.window, height);

    const dc = try drawing.DrawContext.initWithVisual(
        core.alloc, core.conn, setup.window, core.screen.width_in_pixels, height,
        setup.visual_id, core.dpi_info.dpi, setup.has_argb, core.config.bar.transparency,
    );
    errdefer dc.deinit();
    try loadBarFonts(dc);

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
        // Free the buffers grown inside the double-buffer channel slots.
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

    const new_dc = try drawing.DrawContext.initWithVisual(
        core.alloc, core.conn, setup.window, core.screen.width_in_pixels, height,
        setup.visual_id, core.dpi_info.dpi, setup.has_argb, core.config.bar.transparency,
    );
    errdefer new_dc.deinit();
    try loadBarFonts(new_dc);

    const new_state = try State.init(core.alloc, core.conn, setup.window, setup.colormap,
        core.screen.width_in_pixels, height, new_dc, core.config.bar);
    new_state.visible        = old.visible;
    new_state.global_visible = old.global_visible;

    stopBarThread();
    state = new_state;
    startBarThread(new_state);
    // Config changed (fonts, colors, spacing) — force a full redraw so the
    // new state is not compared against stale slot data from the old config.
    g_channel.force_dirty_all = true;
    submitDraw(true);

    _ = xcb.xcb_grab_server(core.conn);
    if (new_state.visible) _ = xcb.xcb_map_window(core.conn, setup.window);
    _ = xcb.xcb_destroy_window(core.conn, old.window);
    _ = xcb.xcb_flush(core.conn);
    _ = xcb.xcb_ungrab_server(core.conn);
    _ = xcb.xcb_flush(core.conn);

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
    // The bar window moves to a new y position — all pixels must be redrawn.
    g_channel.force_dirty_all = true;
    s.invalidateLayout();
    _ = xcb.xcb_grab_server(core.conn);
    _ = xcb.xcb_configure_window(core.conn, s.window, xcb.XCB_CONFIG_WINDOW_Y,
        &[_]u32{@as(u32, @bitCast(@as(i32, new_y)))});
    const current_ws = workspaces.getCurrentWorkspace() orelse {
        _ = xcb.xcb_ungrab_server(core.conn);
        _ = xcb.xcb_flush(core.conn);
        return;
    };
    if (fullscreen.getForWorkspace(current_ws) == null)
        if (comptime build_options.has_tiling) tiling.retileCurrentWorkspace();
    _ = xcb.xcb_ungrab_server(core.conn);
    _ = xcb.xcb_flush(core.conn);
    debug.info("Bar position toggled to: {s}", .{@tagName(core.config.bar.vertical_position)});
}

/// Schedules a lightweight focus-only redraw. Skips the full snapshot capture
/// and posts only the new focused window ID to the bar thread, which runs the
/// fast drawTitleOnly path instead of a full drawAll. Skipped when a full
/// redraw is already pending — the full draw will include the focus state.
pub fn scheduleFocusRedraw(new_win: ?u32) void {
    const s = state orelse return;
    if (!s.visible) return;
    // If a full redraw is already scheduled (dirty) or already in-flight in the
    // channel (snap_ready), the bar thread will run drawAll which supersedes
    // drawTitleOnly — skip the lightweight update entirely.
    g_channel.mutex.lock();
    if (!s.dirty and !g_channel.snap_ready) {
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
/// Schedule a full bar redraw, coalesced to the end of the current XCB event
/// batch via updateIfDirty. Zero X11 I/O on the caller's stack.
///
/// DEFAULT choice for everything outside a server grab: focus changes, window
/// map/unmap, layout toggles, workspace membership changes, etc.
pub fn scheduleRedraw() void        { if (state) |s| if (s.visible) s.setDirty(); }
pub fn isVisible() bool             { return if (state) |s| s.visible else false; }
pub fn getGlobalVisibility() bool   { return if (state) |s| s.global_visible else false; }
pub fn setGlobalVisibility(visible: bool) void { if (state) |s| s.global_visible = visible; }

/// Redraw the bar synchronously, blocking until the bar thread finishes.
///
/// ONLY for use inside or directly before xcb_ungrab_server: the bar thread
/// cannot render while the server is grabbed, so the draw must complete before
/// the grab is released or the bar will show stale content.
///
/// For everything outside a grab, use scheduleRedraw().
pub fn redrawInsideGrab() void {
    const s = state orelse return;
    if (!s.visible) return;
    submitDraw(true);
    s.dirty = false;
}

pub fn raiseBar() void {
    if (state) |s| _ = xcb.xcb_configure_window(s.conn, s.window,
        xcb.XCB_CONFIG_WINDOW_STACK_MODE, &[_]u32{xcb.XCB_STACK_MODE_ABOVE});
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
        if (show) g_channel.force_dirty_all = true;
        if (show) submitDraw(true);
        _ = xcb.xcb_grab_server(core.conn);
        if (show) _ = xcb.xcb_map_window(core.conn, s.window)
        else      _ = xcb.xcb_unmap_window(core.conn, s.window);
        const saved = s.visible;
        if (is_fullscreen) s.visible = s.global_visible;
        retileAllWorkspacesNoGrab();
        if (is_fullscreen) s.visible = saved;
        _ = xcb.xcb_ungrab_server(core.conn);
        _ = xcb.xcb_flush(core.conn);
    } else {
        if (show) {
            // Freshly mapped window has uninitialised pixels — force full redraw.
            g_channel.force_dirty_all = true;
            submitDraw(true);
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
    if (s.dirty) {
        submitDraw(false);
        s.dirty = false;
    }
}

pub fn checkClockUpdate() void {
    const s = state orelse return;
    if (!s.visible) return;
    g_channel.mutex.lock();
    g_channel.clock_dirty = true;
    g_channel.work_cond.signal();
    g_channel.mutex.unlock();
}

pub fn pollTimeoutMs() i32     { return clock_segment.pollTimeoutMs(); }
pub fn updateTimerState() void { clock_segment.updateTimerState(); }

pub fn handleExpose(event: *const xcb.xcb_expose_event_t) void {
    if (state) |s| if (event.window == s.window and event.count == 0) {
        // The bar was covered and is now exposed — all pixels must be redrawn.
        g_channel.force_dirty_all = true;
        if (drag.isDragging()) s.setDirty() else submitDraw(false);
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

    // Restore old window's mask. The WM is the only entity that has set
    // this mask, so it is always exactly MANAGED_WINDOW — no round-trip
    // needed to ask the server to reflect it back.
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

    // Use retileInactiveWorkspace for non-current workspaces: it computes
    // correct geometry and pushes windows back offscreen without mutating
    // ws_state.current, avoiding a re-entrant event handler seeing a wrong
    // current workspace during the retile window.
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
