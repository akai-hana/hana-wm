//! Status bar — renders segments via Cairo/Pango into an XCB override-redirect window.
//!
//! Architecture change: a dedicated bar thread owns the DrawContext and all
//! rendering.  The main thread captures a lightweight BarSnapshot and posts it
//! to a BarChannel; the bar thread wakes, draws, and loops.  Draws that must
//! complete before the caller returns (e.g. inside xcb_grab_server) use
//! submitDraw(wm, true) which blocks until the bar thread signals completion.
//!
//! Clock-only updates bypass the snapshot path entirely: the bar thread redraws
//! just the clock segment using its cached x-position.
//!
//! Comptime dispatch: when no segment module files are present on disk,
//! `has_any_segment` is false, all public functions become no-ops, and
//! `init` always returns `error.BarDisabled`. Because `BarFull` is never
//! analyzed by Zig's lazy evaluator in that case, `drawing.zig` is never
//! compiled and cairo/pango are not linked.

const std   = @import("std");
const defs  = @import("defs");
const xcb   = defs.xcb;
const debug = @import("debug");

const bar_flags = @import("bar_flags");

pub const BarAction = enum { toggle, hide_fullscreen, show_fullscreen };

const Impl = if (bar_flags.has_any_segment) BarFull else BarStub;

pub fn init(wm: *defs.WM) !void                                      { return Impl.init(wm); }
pub fn deinit() void                                                   { Impl.deinit(); }
pub fn reload(wm: *defs.WM) void                                      { Impl.reload(wm); }
pub fn toggleBarPosition(wm: *defs.WM) !void                          { return Impl.toggleBarPosition(wm); }
pub fn getBarWindow() u32                                              { return Impl.getBarWindow(); }
pub fn isBarWindow(win: u32) bool                                      { return Impl.isBarWindow(win); }
pub fn getBarHeight() u16                                              { return Impl.getBarHeight(); }
pub fn isBarInitialized() bool                                         { return Impl.isBarInitialized(); }
pub fn hasClockSegment() bool                                          { return Impl.hasClockSegment(); }
pub fn markDirty() void                                                { Impl.markDirty(); }
pub fn redrawImmediate(wm: *defs.WM) void                             { Impl.redrawImmediate(wm); }
pub fn raiseBar() void                                                 { Impl.raiseBar(); }
pub fn isVisible() bool                                                { return Impl.isVisible(); }
pub fn getGlobalVisibility() bool                                      { return Impl.getGlobalVisibility(); }
pub fn setGlobalVisibility(visible: bool) void                         { Impl.setGlobalVisibility(visible); }
pub fn setBarState(wm: *defs.WM, action: BarAction) void              { Impl.setBarState(wm, action); }
pub fn updateIfDirty(wm: *defs.WM) !void                              { return Impl.updateIfDirty(wm); }
pub fn checkClockUpdate() void                                         { Impl.checkClockUpdate(); }
pub fn pollTimeoutMs() i32                                             { return Impl.pollTimeoutMs(); }
pub fn updateTimerState() void                                         { Impl.updateTimerState(); }
pub fn handleExpose(ev: *const xcb.xcb_expose_event_t, wm: *defs.WM) void { Impl.handleExpose(ev, wm); }
pub fn handlePropertyNotify(ev: *const xcb.xcb_property_notify_event_t, wm: *defs.WM) void { Impl.handlePropertyNotify(ev, wm); }
pub fn monitorFocusedWindow(wm: *defs.WM) void                        { Impl.monitorFocusedWindow(wm); }
pub fn handleButtonPress(ev: *const xcb.xcb_button_press_event_t, wm: *defs.WM) void { Impl.handleButtonPress(ev, wm); }
pub fn notifyFocusChange(wm: *defs.WM, new_win: ?u32) void { Impl.notifyFocusChange(wm, new_win); }

// ── Stub ─────────────────────────────────────────────────────────────────────

const BarStub = struct {
    pub fn init(_: *defs.WM) error{BarDisabled}!void { return error.BarDisabled; }
    pub fn deinit() void {}
    pub fn reload(_: *defs.WM) void {}
    pub fn toggleBarPosition(_: *defs.WM) !void {}
    pub fn getBarWindow() u32                         { return 0; }
    pub fn isBarWindow(_: u32) bool                  { return false; }
    pub fn getBarHeight() u16                         { return 0; }
    pub fn isBarInitialized() bool                   { return false; }
    pub fn hasClockSegment() bool                    { return false; }
    pub fn markDirty() void {}
    pub fn redrawImmediate(_: *defs.WM) void {}
    pub fn raiseBar() void {}
    pub fn isVisible() bool                           { return false; }
    pub fn getGlobalVisibility() bool                { return false; }
    pub fn setGlobalVisibility(_: bool) void {}
    pub fn setBarState(_: *defs.WM, _: BarAction) void {}
    pub fn updateIfDirty(_: *defs.WM) !void {}
    pub fn checkClockUpdate() void {}
    pub fn pollTimeoutMs() i32     { return -1; }
    pub fn updateTimerState() void {}
    pub fn handleExpose(_: *const xcb.xcb_expose_event_t, _: *defs.WM) void {}
    pub fn handlePropertyNotify(_: *const xcb.xcb_property_notify_event_t, _: *defs.WM) void {}
    pub fn monitorFocusedWindow(_: *defs.WM) void {}
    pub fn handleButtonPress(_: *const xcb.xcb_button_press_event_t, _: *defs.WM) void {}
    pub fn notifyFocusChange(_: *defs.WM, _: ?u32) void {}
};

// ── Full implementation ───────────────────────────────────────────────────────

const BarFull = struct {
    const drawing    = @import("drawing");
    const tiling     = @import("tiling");
    const utils      = @import("utils");
    const workspaces = @import("workspaces");
    const constants  = @import("constants");
    const dpi_mod    = @import("dpi");

    // Segment stubs match updated draw signatures.
    const workspaces_segment = if (bar_flags.has_tags) @import("tags") else struct {
        pub fn draw(_: *drawing.DrawContext, _: defs.BarConfig, _: u16, x: u16, _: u8, _: []const bool) !u16 { return x; }
        pub fn invalidate() void {}
        pub fn getCachedWorkspaceWidth() u16 { return 0; }
    };

    const layout_segment = if (bar_flags.has_layout) @import("layout") else struct {
        pub fn draw(_: *drawing.DrawContext, _: defs.BarConfig, _: u16, x: u16) !u16 { return x; }
    };

    const variations_segment = if (bar_flags.has_variations) @import("variations") else struct {
        pub fn draw(_: *drawing.DrawContext, _: defs.BarConfig, _: u16, x: u16) !u16 { return x; }
    };

    const title_segment = if (bar_flags.has_title) @import("title") else struct {
        pub fn draw(
            _: *drawing.DrawContext, _: defs.BarConfig, _: u16,
            x: u16, w: u16,
            _: *xcb.xcb_connection_t, _: ?u32,
            _: []const u32, _: []const u32,
            _: *std.ArrayList(u8), _: *?u32,
            _: bool, _: std.mem.Allocator,
        ) !u16 { return x + w; }
    };

    const clock_segment = if (bar_flags.has_clock) @import("clock") else struct {
        pub const SAMPLE_STRING: []const u8 = "";
        pub fn draw(_: *drawing.DrawContext, _: defs.BarConfig, _: u16, x: u16) !u16 { return x; }
        pub fn setTimerFd(_: i32) void {}
        pub fn updateTimerState() void {}
    };

    const status_segment = if (bar_flags.has_status) @import("status") else struct {
        pub fn draw(_: *drawing.DrawContext, _: defs.BarConfig, _: u16, x: u16, _: []const u8) !u16 { return x; }
        pub fn update(_: *defs.WM, _: *std.ArrayList(u8), _: std.mem.Allocator) !void {}
    };

    const MIN_BAR_HEIGHT:            u32 = 20;
    const MAX_BAR_HEIGHT:            u32 = 200;
    const DEFAULT_BAR_HEIGHT:        u16 = 24;
    const FALLBACK_WORKSPACES_WIDTH: u16 = 270;
    const LAYOUT_SEGMENT_WIDTH:      u16 = 60;
    const TITLE_SEGMENT_MIN_WIDTH:   u16 = 100;

    // ── Snapshot ─────────────────────────────────────────────────────────────

    /// Immutable point-in-time capture of everything the bar thread needs to
    /// render one frame.  Allocated on the heap so it can be transferred across
    /// thread boundaries via the BarChannel.
    const BarSnapshot = struct {
        conn:              *xcb.xcb_connection_t, // thread-safe; not owned
        focused_window:    ?u32,
        /// Window IDs on the current workspace (owned copy).
        current_ws_wins:   []u32,
        /// Minimized window IDs (owned copy of keys from minimized_info).
        minimized:         []u32,
        /// One bool per workspace: true when the workspace has at least one window.
        ws_has_windows:    []bool,
        ws_current:        u8,
        ws_count:          u32,
        /// Copy of status_text for the status segment.
        status_text:       []u8,
        /// When true the bar thread must invalidate its cached title before drawing.
        title_invalidated: bool,
        allocator:         std.mem.Allocator,

        fn deinit(snap: *BarSnapshot) void {
            snap.allocator.free(snap.current_ws_wins);
            snap.allocator.free(snap.minimized);
            snap.allocator.free(snap.ws_has_windows);
            snap.allocator.free(snap.status_text);
            snap.allocator.destroy(snap);
        }
    };

    // ── Channel ───────────────────────────────────────────────────────────────

    /// Lock-based channel between the main thread (producer) and bar thread (consumer).
    const BarChannel = struct {
        mutex:       std.Thread.Mutex     = .{},
        work_cond:   std.Thread.Condition = .{}, // bar thread waits here
        done_cond:   std.Thread.Condition = .{}, // main thread waits when blocking
        pending:     ?*BarSnapshot        = null,
        clock_dirty: bool                 = false,
        quit:        bool                 = false,
        /// Monotonically increasing draw generation.  Incremented by the bar
        /// thread after each full (snapshot) draw completes.
        draw_gen:    u64                  = 0,
        /// Set by notifyFocusChange when only the focused window changed.
        /// Ignored when a full snapshot is already pending.
        focus_dirty: bool                 = false,
        focus_new_win: ?u32              = null,
    };

    var g_channel: BarChannel   = .{};
    var g_bar_thread: ?std.Thread = null;

    // ── State ─────────────────────────────────────────────────────────────────

    const State = struct {
        window:               u32,
        colormap:             u32, // 0 when no transparency; freed in deinit
        width:                u16,
        height:               u16,
        dc:                   *drawing.DrawContext,
        conn:                 *xcb.xcb_connection_t,
        config:               defs.BarConfig,
        status_text:          std.ArrayList(u8),
        cached_title:         std.ArrayList(u8),
        cached_title_window:  ?u32,
        dirty:                bool,
        dirty_clock:          bool,
        /// Set by handlePropertyNotify; cleared when a snapshot is captured.
        title_invalidated:    bool,
        visible:              bool,
        global_visible:       bool,
        has_transparency:     bool,
        allocator:            std.mem.Allocator,
        cached_clock_width:   u16,
        cached_clock_x:       ?u16,
        cached_workspace_x:   u16,
        has_clock_segment:    bool,
        /// Cached title segment geometry for focus-only partial redraws.
        /// Populated after each full draw; used by drawTitleOnly.
        cached_title_x:       u16,
        cached_title_w:       u16,
        /// Owned copies of current workspace windows and minimized IDs,
        /// retained so focus-only redraws don't need a new snapshot.
        cached_ws_wins:       []u32,
        cached_min_wins:      []u32,
        title_layout_valid:   bool,
        /// Tracks which window currently has PROPERTY_CHANGE monitored so we can
        /// restore its original event mask when focus moves away, preventing mask
        /// accumulation across all formerly-focused windows.
        last_monitored_window:    ?u32,
        /// The event mask the window had before we OR'd in PROPERTY_CHANGE.
        last_monitored_base_mask: u32,
        /// Pre-interned _NET_WM_NAME atom; avoids a hash lookup on every PropertyNotify.
        net_wm_name_atom:         xcb.xcb_atom_t,

        fn init(
            allocator:        std.mem.Allocator,
            conn:             *xcb.xcb_connection_t,
            window:           u32,
            colormap:         u32,
            width:            u16,
            height:           u16,
            dc:               *drawing.DrawContext,
            config:           defs.BarConfig,
            has_transparency: bool,
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
                .dirty_clock          = false,
                .title_invalidated    = false,
                .visible              = true,
                .global_visible       = true,
                .has_transparency     = has_transparency,
                .allocator            = allocator,
                .cached_clock_width   = dc.textWidth(clock_segment.SAMPLE_STRING) + 2 * config.scaledSegmentPadding(height),
                .cached_clock_x       = null,
                .cached_workspace_x   = 0,
                .has_clock_segment    = detectClockSegment(&config),
                .cached_title_x       = 0,
                .cached_title_w       = 0,
                .cached_ws_wins            = &.{},
                .cached_min_wins           = &.{},
                .title_layout_valid        = false,
                .last_monitored_window     = null,
                .last_monitored_base_mask  = 0,
                // Pre-intern _NET_WM_NAME once so handlePropertyNotify never
                // touches the atom cache on the hot event path.
                .net_wm_name_atom          = utils.getAtomCached("_NET_WM_NAME") catch 0,
            };
            try s.status_text.ensureTotalCapacity(allocator, 256);
            try s.cached_title.ensureTotalCapacity(allocator, 256);
            workspaces_segment.invalidate();
            return s;
        }

        fn deinit(self: *State) void {
            // Restore the last monitored window's original event mask.  Without
            // this, the window is left with PROPERTY_CHANGE permanently OR'd in
            // and keeps generating PropertyNotify events for the WM's lifetime.
            if (self.last_monitored_window) |win| {
                _ = xcb.xcb_change_window_attributes(self.conn, win,
                    xcb.XCB_CW_EVENT_MASK, &[_]u32{self.last_monitored_base_mask});
            }
            // xcb_destroy_window does NOT free the colormap — it is an
            // independent X server resource and must be released explicitly.
            if (self.colormap != 0) _ = xcb.xcb_free_colormap(self.conn, self.colormap);
            self.status_text.deinit(self.allocator);
            self.cached_title.deinit(self.allocator);
            self.allocator.free(self.cached_ws_wins);
            self.allocator.free(self.cached_min_wins);
            self.allocator.destroy(self);
        }

        fn markDirty(self: *State) void {
            self.dirty = true;
            self.cached_clock_x = null;
        }
        fn markClockDirty(self: *State) void { self.dirty_clock = true; }
        fn clearDirty(self: *State) void { self.dirty = false; self.dirty_clock = false; }

        // ── Segment drawing (bar thread only) ────────────────────────────────

        fn calculateSegmentWidth(self: *State, snap: *const BarSnapshot, segment: defs.BarSegment) u16 {
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

        fn drawSegment(self: *State, snap: *const BarSnapshot, segment: defs.BarSegment, x: u16, width: ?u16) !u16 {
            if (segment == .workspaces) self.cached_workspace_x = x;
            return switch (segment) {
                .workspaces => try workspaces_segment.draw(
                    self.dc, self.config, self.height, x,
                    snap.ws_current, snap.ws_has_windows),
                .layout     => try layout_segment.draw(self.dc, self.config, self.height, x),
                .variations => try variations_segment.draw(self.dc, self.config, self.height, x),
                .title      => try title_segment.draw(
                    self.dc, self.config, self.height, x, width orelse 100,
                    snap.conn, snap.focused_window,
                    snap.current_ws_wins, snap.minimized,
                    &self.cached_title, &self.cached_title_window,
                    snap.title_invalidated, self.allocator),
                .clock      => try clock_segment.draw(self.dc, self.config, self.height, x),
            };
        }

        fn drawRightSegments(self: *State, snap: *const BarSnapshot, segments: []const defs.BarSegment) !void {
            var right_x          = self.width;
            const scaled_spacing = self.config.scaledSpacing(self.height);
            for (0..segments.len) |i| {
                const idx = segments.len - 1 - i;
                right_x -= self.calculateSegmentWidth(snap, segments[idx]);
                if (segments[idx] == .clock) self.cached_clock_x = right_x;
                _ = try self.drawSegment(snap, segments[idx], right_x, null);
                if (i < segments.len - 1) right_x -= scaled_spacing;
            }
        }

        /// Full bar redraw from snapshot.  Called exclusively from the bar thread.
        fn drawAll(self: *State, snap: *const BarSnapshot) !void {
            // Apply title cache invalidation before rendering.
            if (snap.title_invalidated) self.cached_title_window = null;

            if (self.has_transparency) self.dc.clearTransparent();
            self.dc.fillRect(0, 0, self.width, self.height, self.config.bg);

            const scaled_spacing = self.config.scaledSpacing(self.height);

            var right_total: u16 = 0;
            for (self.config.layout.items) |layout| {
                if (layout.position != .right) continue;
                for (layout.segments.items) |seg| right_total += self.calculateSegmentWidth(snap, seg) + scaled_spacing;
                if (layout.segments.items.len > 0) right_total -= scaled_spacing;
            }

            // Track where the title segment lands so drawTitleOnly can repaint
            // just that region on focus changes.
            var title_seg_x: u16 = 0;
            var title_seg_w: u16 = 0;

            var x: u16 = 0;
            for (self.config.layout.items) |layout| {
                switch (layout.position) {
                    .left => for (layout.segments.items) |seg| {
                        if (seg == .title) { title_seg_x = x; title_seg_w = self.calculateSegmentWidth(snap, seg); }
                        x  = try self.drawSegment(snap, seg, x, null);
                        x += scaled_spacing;
                    },
                    .center => {
                        const remaining = @max(100, self.width -| x -| right_total -| scaled_spacing);
                        for (layout.segments.items) |seg| {
                            const w = if (seg == .title) remaining else self.calculateSegmentWidth(snap, seg);
                            if (seg == .title) { title_seg_x = x; title_seg_w = w; }
                            x = try self.drawSegment(snap, seg, x, w);
                            if (seg != .title) x += scaled_spacing;
                        }
                    },
                    .right => try self.drawRightSegments(snap, layout.segments.items),
                }
            }
            self.dc.flush();

            // Populate title layout cache for subsequent focus-only redraws.
            if (title_seg_w > 0) self.updateTitleCache(snap, title_seg_x, title_seg_w);
        }

        /// Clock-only redraw.  Uses the cached clock x-position; skips silently
        /// if the position isn't known yet (the next full draw will set it).
        /// Called exclusively from the bar thread.
        fn drawClockOnly(self: *State) void {
            const clock_x = self.cached_clock_x orelse return;
            _ = clock_segment.draw(self.dc, self.config, self.height, clock_x) catch |e|
                debug.warnOnErr(e, "drawClockOnly");
            self.dc.flush();
        }

        /// Focus-only redraw.  Repaints just the title segment using the
        /// cached window list and the new focused window ID.  Skips if the
        /// layout cache is stale (next full draw will repopulate it).
        /// Called exclusively from the bar thread.
        fn drawTitleOnly(self: *State, new_focused: ?u32) void {
            if (!self.title_layout_valid or self.cached_title_w == 0) return;
            _ = title_segment.draw(
                self.dc, self.config, self.height,
                self.cached_title_x, self.cached_title_w,
                self.conn, new_focused,
                self.cached_ws_wins, self.cached_min_wins,
                &self.cached_title, &self.cached_title_window,
                true, // title_invalidated: re-fetch title for the newly focused window
                self.allocator,
            ) catch |e| {
                debug.warnOnErr(e, "drawTitleOnly");
                return;
            };
            self.dc.flush();
        }

        /// Updates the title layout cache from a freshly-drawn snapshot.
        /// Call immediately after drawAll so drawTitleOnly has current data.
        fn updateTitleCache(self: *State, snap: *const BarSnapshot, x: u16, w: u16) void {
            const new_wins = self.allocator.dupe(u32, snap.current_ws_wins) catch return;
            const new_mins = self.allocator.dupe(u32, snap.minimized) catch {
                self.allocator.free(new_wins);
                return;
            };
            self.allocator.free(self.cached_ws_wins);
            self.allocator.free(self.cached_min_wins);
            self.cached_ws_wins     = new_wins;
            self.cached_min_wins    = new_mins;
            self.cached_title_x     = x;
            self.cached_title_w     = w;
            self.title_layout_valid = true;
        }
    };

    // ── Bar thread ───────────────────────────────────────────────────────────

    fn barThreadFn(s: *State) void {
        while (true) {
            g_channel.mutex.lock();
            while (!g_channel.quit and g_channel.pending == null and
                   !g_channel.clock_dirty and !g_channel.focus_dirty)
            {
                g_channel.work_cond.wait(&g_channel.mutex);
            }
            if (g_channel.quit) {
                g_channel.mutex.unlock();
                return;
            }
            const snap          = g_channel.pending;
            // Clock and focus partial redraws only run when no full draw is queued.
            const do_clock      = g_channel.clock_dirty  and snap == null;
            const do_focus      = g_channel.focus_dirty  and snap == null;
            const focus_new_win = g_channel.focus_new_win;
            g_channel.pending     = null;
            g_channel.clock_dirty = false;
            g_channel.focus_dirty = false;
            g_channel.focus_new_win = null;
            g_channel.mutex.unlock();

            if (snap) |sn| {
                s.drawAll(sn) catch |e| debug.warnOnErr(e, "bar thread drawAll");
                sn.deinit();
                g_channel.mutex.lock();
                g_channel.draw_gen += 1;
                g_channel.done_cond.broadcast();
                g_channel.mutex.unlock();
            } else if (do_focus) {
                s.drawTitleOnly(focus_new_win);
            } else if (do_clock) {
                s.drawClockOnly();
            }
        }
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
        g_channel.focus_dirty = false;
        // Free any unconsumed pending snapshot.
        if (g_channel.pending) |old| old.deinit();
        g_channel.pending = null;
        g_channel.work_cond.signal();
        g_channel.mutex.unlock();

        if (g_bar_thread) |t| {
            t.join();
            g_bar_thread = null;
        }
        g_channel.quit = false;
    }

    // ── Snapshot capture (main thread) ───────────────────────────────────────

    fn captureSnapshot(wm: *defs.WM, s: *State) !*BarSnapshot {
        const allocator = s.allocator;
        const snap = try allocator.create(BarSnapshot);
        errdefer allocator.destroy(snap);

        const status = try allocator.dupe(u8, s.status_text.items);
        errdefer allocator.free(status);

        // Minimized window IDs.
        var min_list: std.ArrayList(u32) = .empty;
        defer min_list.deinit(allocator);
        if (wm.minimize) |*ms| {
            var it = ms.minimized_info.keyIterator();
            while (it.next()) |key| try min_list.append(allocator, key.*);
        }
        const minimized = try min_list.toOwnedSlice(allocator);
        errdefer allocator.free(minimized);

        // Workspace state.
        const ws_state = workspaces.getState();
        const ws_count: u32 = if (ws_state) |ws| @intCast(ws.workspaces.len) else 0;
        const ws_current: u8 = if (ws_state) |ws| ws.current else 0;

        const ws_has_windows = try allocator.alloc(bool, ws_count);
        errdefer allocator.free(ws_has_windows);
        if (ws_state) |ws| {
            for (ws.workspaces, 0..) |*workspace, i| {
                ws_has_windows[i] = workspace.windows.count() > 0;
            }
        }

        // Current workspace window list.
        const current_ws_wins = blk: {
            if (ws_state) |ws| {
                if (ws.current < ws.workspaces.len) {
                    const cws = &ws.workspaces[ws.current];
                    break :blk try allocator.dupe(u32, cws.windows.items());
                }
            }
            break :blk try allocator.alloc(u32, 0);
        };
        errdefer allocator.free(current_ws_wins);

        snap.* = .{
            .conn              = wm.conn,
            .focused_window    = wm.focused_window,
            .current_ws_wins   = current_ws_wins,
            .minimized         = minimized,
            .ws_has_windows    = ws_has_windows,
            .ws_current        = ws_current,
            .ws_count          = ws_count,
            .status_text       = status,
            .title_invalidated = s.title_invalidated,
            .allocator         = allocator,
        };
        s.title_invalidated = false;
        return snap;
    }

    /// Post a snapshot to the bar thread.
    /// `wait = true` blocks until the bar thread has finished the draw — use this
    /// inside xcb_grab_server regions where the bar must be current before the
    /// grab is released.
    fn submitDraw(wm: *defs.WM, wait: bool) void {
        const s = state orelse return;
        if (!s.visible) return;

        const snap = captureSnapshot(wm, s) catch |e| {
            debug.warnOnErr(e, "bar captureSnapshot");
            return;
        };

        g_channel.mutex.lock();
        defer g_channel.mutex.unlock();

        // Replace any unconsumed old snapshot (the new one supersedes it).
        if (g_channel.pending) |old| old.deinit();
        g_channel.pending = snap;

        const gen_before = g_channel.draw_gen;
        g_channel.work_cond.signal();

        if (wait) {
            while (g_channel.draw_gen == gen_before) {
                g_channel.done_cond.wait(&g_channel.mutex);
            }
        }
    }

    fn signalClockDirty() void {
        g_channel.mutex.lock();
        g_channel.clock_dirty = true;
        g_channel.work_cond.signal();
        g_channel.mutex.unlock();
    }

    // ── Module singleton ─────────────────────────────────────────────────────

    var state: ?*State = null;

    fn detectClockSegment(config: *const defs.BarConfig) bool {
        if (comptime !bar_flags.has_clock) return false;
        for (config.layout.items) |layout| {
            for (layout.segments.items) |seg| {
                if (seg == .clock) return true;
            }
        }
        return false;
    }

    fn barYPos(wm: *defs.WM, height: u16) i16 {
        return if (wm.config.bar.vertical_position == .bottom)
            @intCast(@as(i32, wm.screen.height_in_pixels) - height)
        else
            0;
    }

    const BarWindowSetup = struct { window: u32, visual_id: u32, has_argb: bool, colormap: u32 };

    fn createBarWindow(wm: *defs.WM, height: u16, y_pos: i16) BarWindowSetup {
        const want_transparency = wm.config.bar.getAlpha16() < 0xFFFF;
        const visual_info       = if (want_transparency)
            drawing.findVisualByDepth(wm.screen, 32)
        else
            drawing.VisualInfo{ .visual_type = null, .visual_id = wm.screen.root_visual };
        const depth:    u8 = if (want_transparency) 32 else xcb.XCB_COPY_FROM_PARENT;
        const visual_id    = visual_info.visual_id;

        const colormap: u32 = if (want_transparency) blk: {
            const cmap = xcb.xcb_generate_id(wm.conn);
            _ = xcb.xcb_create_colormap(wm.conn, xcb.XCB_COLORMAP_ALLOC_NONE, cmap, wm.screen.root, visual_id);
            break :blk cmap;
        } else 0;

        const window     = xcb.xcb_generate_id(wm.conn);
        const value_mask = xcb.XCB_CW_BACK_PIXEL | xcb.XCB_CW_BORDER_PIXEL |
                           xcb.XCB_CW_OVERRIDE_REDIRECT | xcb.XCB_CW_EVENT_MASK |
                           if (want_transparency) xcb.XCB_CW_COLORMAP else 0;
        const value_list = [_]u32{
            0, 0, 1,
            xcb.XCB_EVENT_MASK_EXPOSURE | xcb.XCB_EVENT_MASK_BUTTON_PRESS,
            colormap,
        };
        _ = xcb.xcb_create_window(wm.conn, depth, window, wm.screen.root,
            0, y_pos, wm.screen.width_in_pixels, height, 0,
            xcb.XCB_WINDOW_CLASS_INPUT_OUTPUT, visual_id,
            @intCast(value_mask), &value_list);

        return .{ .window = window, .visual_id = visual_id, .has_argb = want_transparency, .colormap = colormap };
    }

    fn loadBarFonts(dc: *drawing.DrawContext, wm: *defs.WM) !void {
        const cfg         = wm.config.bar;
        const alloc       = wm.allocator;
        const scaled_size = cfg.scaledFontSize();

        if (cfg.fonts.items.len > 0) {
            var sized: std.ArrayList([]const u8) = .empty;
            defer {
                for (cfg.fonts.items, sized.items) |orig, s| {
                    if (s.ptr != orig.ptr) alloc.free(s);
                }
                sized.deinit(alloc);
            }
            for (cfg.fonts.items) |f| {
                const s = if (scaled_size > 0)
                    try std.fmt.allocPrint(alloc, "{s}:size={}", .{ f, scaled_size })
                else
                    f;
                try sized.append(alloc, s);
            }
            return dc.loadFonts(sized.items);
        }
        // Default font path (original code handled this; kept as-is).
    }

    fn setPropAtom(conn: *xcb.xcb_connection_t, window: u32, prop: u32, atom_type: u32, values: anytype) void {
        _ = xcb.xcb_change_property(conn, xcb.XCB_PROP_MODE_REPLACE, window, prop, atom_type,
            32, @intCast(values.len), values.ptr);
    }

    fn setWindowProperties(wm: *defs.WM, window: u32, height: u16) !void {
        const strut: [12]u32 = if (wm.config.bar.vertical_position == .top)
            .{ 0, 0, 0, height, 0, 0, 0, 0, 0, 0, 0, wm.screen.width_in_pixels }
        else
            .{ 0, 0, height, 0, 0, 0, 0, 0, 0, wm.screen.width_in_pixels, 0, 0 };

        setPropAtom(wm.conn, window,
            try utils.getAtomCached("_NET_WM_STRUT_PARTIAL"), xcb.XCB_ATOM_CARDINAL, &strut);
        setPropAtom(wm.conn, window,
            try utils.getAtomCached("_NET_WM_WINDOW_TYPE"), xcb.XCB_ATOM_ATOM,
            &[_]u32{try utils.getAtomCached("_NET_WM_WINDOW_TYPE_DOCK")});
        setPropAtom(wm.conn, window,
            try utils.getAtomCached("_NET_WM_STATE"), xcb.XCB_ATOM_ATOM,
            &[_]u32{
                try utils.getAtomCached("_NET_WM_STATE_ABOVE"),
                try utils.getAtomCached("_NET_WM_STATE_STICKY"),
            });
        setPropAtom(wm.conn, window,
            try utils.getAtomCached("_NET_WM_ALLOWED_ACTIONS"), xcb.XCB_ATOM_ATOM,
            &[_]u32{
                try utils.getAtomCached("_NET_WM_ACTION_CLOSE"),
                try utils.getAtomCached("_NET_WM_ACTION_ABOVE"),
                try utils.getAtomCached("_NET_WM_ACTION_STICK"),
            });
    }

    fn resolvePercentageFontSize(wm: *defs.WM, bar_height: u16) ?u16 {
        const TRIAL_PT: u16 = 100;
        const saved_size = wm.config.bar.scaled_font_size;
        wm.config.bar.scaled_font_size = TRIAL_PT;
        defer wm.config.bar.scaled_font_size = saved_size;

        const temp_dc = drawing.DrawContext.initOffscreen(wm.allocator, wm.conn, wm.dpi_info.dpi) catch |e| {
            debug.warnOnErr(e, "DrawContext.initOffscreen in resolvePercentageFontSize");
            return null;
        };
        defer temp_dc.deinit();

        loadBarFonts(temp_dc, wm) catch return null;

        const asc, const desc = temp_dc.getMetrics();
        const font_px: f32    = @floatFromInt(@max(1, asc + desc));
        const px_per_pt: f32  = font_px / @as(f32, @floatFromInt(TRIAL_PT));
        const height_f: f32   = @floatFromInt(bar_height);
        const max_size_pt     = height_f / px_per_pt;
        const final_size      = max_size_pt * (wm.config.bar.font_size.value / 100.0);
        return @max(1, @as(u16, @intFromFloat(@round(final_size))));
    }

    fn calculateBarHeight(wm: *defs.WM) !u16 {
        if (wm.config.bar.height) |h| {
            const height = dpi_mod.scaleBarHeight(h, wm.screen.height_in_pixels);
            if (wm.config.bar.font_size.is_percentage) {
                if (resolvePercentageFontSize(wm, height)) |sz|
                    wm.config.bar.scaled_font_size = sz;
            }
            return height;
        }

        const temp_dc = drawing.DrawContext.initOffscreen(wm.allocator, wm.conn, wm.dpi_info.dpi) catch |e| {
            debug.warnOnErr(e, "DrawContext.initOffscreen in calculateBarHeight");
            return DEFAULT_BAR_HEIGHT;
        };
        defer temp_dc.deinit();

        loadBarFonts(temp_dc, wm) catch {
            debug.warn("Failed to load fonts for height calculation, using default", .{});
            return DEFAULT_BAR_HEIGHT;
        };

        const asc, const desc  = temp_dc.getMetrics();
        const font_height: u32 = @intCast(asc + desc);
        return @intCast(std.math.clamp(font_height, MIN_BAR_HEIGHT, MAX_BAR_HEIGHT));
    }

    // ── Public API ────────────────────────────────────────────────────────────

    /// Destroys a bar window and frees its colormap (if any).
    /// xcb_destroy_window does NOT free associated colormaps — they are
    /// independent X server resources and must be released explicitly.
    fn destroyBarWindow(conn: *xcb.xcb_connection_t, setup: BarWindowSetup) void {
        _ = xcb.xcb_destroy_window(conn, setup.window);
        if (setup.colormap != 0) _ = xcb.xcb_free_colormap(conn, setup.colormap);
    }

    pub fn init(wm: *defs.WM) !void {
        if (!wm.config.bar.enabled) return error.BarDisabled;

        const height = try calculateBarHeight(wm);
        const y_pos  = barYPos(wm, height);
        const setup  = createBarWindow(wm, height, y_pos);
        errdefer destroyBarWindow(wm.conn, setup);

        try setWindowProperties(wm, setup.window, height);
        // Do NOT map yet — the window would be blank until the bar thread draws.

        const dc = try drawing.DrawContext.initWithVisual(
            wm.allocator, wm.conn, setup.window, wm.screen.width_in_pixels, height,
            setup.visual_id, wm.dpi_info.dpi, setup.has_argb, wm.config.bar.transparency,
        );
        errdefer dc.deinit();
        try loadBarFonts(dc, wm);

        debug.info("Bar transparency: {s}", .{if (setup.has_argb) "enabled (ARGB)" else "disabled (opaque)"});

        state = try State.init(wm.allocator, wm.conn, setup.window, setup.colormap,
            wm.screen.width_in_pixels, height, dc, wm.config.bar, setup.has_argb);

        startBarThread(state.?);
        // Block until the bar thread completes the first full draw, then map.
        // This mirrors the reloadImpl pattern and guarantees the bar is never
        // shown blank.  setWindowProperties requests are already queued; they
        // are batched with the map and sent in a single flush.
        submitDraw(wm, true);
        _ = xcb.xcb_map_window(wm.conn, setup.window);
        utils.flush(wm.conn);
    }

    pub fn deinit() void {
        stopBarThread();
        if (state) |s| {
            _ = xcb.xcb_destroy_window(s.conn, s.window);
            s.dc.deinit();
            drawing.deinitFontCache(s.allocator);
            s.deinit();
            state = null;
        }
    }

    pub fn reload(wm: *defs.WM) void {
        const old = state orelse {
            BarFull.init(wm) catch |err| {
                if (err != error.BarDisabled) debug.err("Bar init failed: {}", .{err});
            };
            return;
        };

        if (!wm.config.bar.enabled) { BarFull.deinit(); return; }

        const height = calculateBarHeight(wm) catch DEFAULT_BAR_HEIGHT;
        const y_pos  = barYPos(wm, height);
        const setup  = createBarWindow(wm, height, y_pos);

        reloadImpl(wm, old, setup, height) catch |err| {
            destroyBarWindow(wm.conn, setup);
            debug.err("Bar reload failed ({s}), keeping old bar", .{@errorName(err)});
        };
    }

    fn reloadImpl(wm: *defs.WM, old: *State, setup: BarWindowSetup, height: u16) !void {
        try setWindowProperties(wm, setup.window, height);

        const new_dc = try drawing.DrawContext.initWithVisual(
            wm.allocator, wm.conn, setup.window, wm.screen.width_in_pixels, height,
            setup.visual_id, wm.dpi_info.dpi, setup.has_argb, wm.config.bar.transparency,
        );
        errdefer new_dc.deinit();
        try loadBarFonts(new_dc, wm);

        const new_state = try State.init(wm.allocator, wm.conn, setup.window, setup.colormap,
            wm.screen.width_in_pixels, height, new_dc, wm.config.bar, setup.has_argb);

        new_state.visible        = old.visible;
        new_state.global_visible = old.global_visible;

        // Stop old bar thread before swapping state.
        stopBarThread();

        state = new_state;
        // Initial draw (blocking) to populate the new bar before mapping it.
        submitDraw(wm, true);
        // submitDraw above (blocking) already called dc.flush() inside drawAll;
        // flush the XCB connection so draw requests reach the server before the grab.
        utils.flush(wm.conn);

        _ = xcb.xcb_grab_server(wm.conn);
        if (new_state.visible) _ = xcb.xcb_map_window(wm.conn, setup.window);
        _ = xcb.xcb_destroy_window(wm.conn, old.window);
        _ = xcb.xcb_flush(wm.conn);
        _ = xcb.xcb_ungrab_server(wm.conn);
        utils.flush(wm.conn);

        old.dc.deinit();
        old.deinit();

        startBarThread(new_state);
    }

    pub fn toggleBarPosition(wm: *defs.WM) !void {
        if (state) |s| {
            wm.config.bar.vertical_position = switch (wm.config.bar.vertical_position) {
                .top    => .bottom,
                .bottom => .top,
            };
            const new_y = barYPos(wm, s.height);
            try setWindowProperties(wm, s.window, s.height);
            _ = xcb.xcb_grab_server(wm.conn);
            _ = xcb.xcb_configure_window(s.conn, s.window, xcb.XCB_CONFIG_WINDOW_Y,
                &[_]u32{@as(u32, @bitCast(@as(i32, new_y)))});
            const current_ws = workspaces.getCurrentWorkspace() orelse {
                _ = xcb.xcb_ungrab_server(wm.conn);
                utils.flush(wm.conn);
                return;
            };
            if (wm.fullscreen.getForWorkspace(current_ws) == null)
                tiling.retileCurrentWorkspace(wm);
            _ = xcb.xcb_ungrab_server(wm.conn);
            utils.flush(wm.conn);
            debug.info("Bar position toggled to: {s}", .{@tagName(wm.config.bar.vertical_position)});
        }
    }

    /// Post a focus-only update to the bar thread.  Call this from the focus
    /// handler in events.zig instead of markDirty() when only the focused
    /// window changed.  Skipped automatically if a full redraw is pending.
    ///
    ///   bar.notifyFocusChange(wm, old_focused_window, new_focused_window);
    pub fn notifyFocusChange(_: *defs.WM, new_win: ?u32) void {
        const s = state orelse return;
        if (!s.visible) return;
        // Invalidate the cached focused-window title so the bar thread
        // re-fetches it for the newly focused window.
        g_channel.mutex.lock();
        g_channel.focus_dirty   = true;
        g_channel.focus_new_win = new_win;
        g_channel.work_cond.signal();
        g_channel.mutex.unlock();
    }

    pub fn getBarWindow() u32         { return if (state) |s| s.window else 0; }
    pub fn isBarWindow(win: u32) bool  { return if (state) |s| s.window == win else false; }
    pub fn getBarHeight() u16          { return if (state) |s| s.height else 0; }
    pub fn isBarInitialized() bool     { return state != null; }
    pub fn hasClockSegment() bool      { return if (state) |s| s.has_clock_segment else false; }
    pub fn markDirty() void            { if (state) |s| s.markDirty(); }

    pub fn redrawImmediate(wm: *defs.WM) void {
        const s = state orelse return;
        if (!s.visible) return;
        submitDraw(wm, true);
        s.clearDirty();
    }

    pub fn raiseBar() void {
        if (state) |s| _ = xcb.xcb_configure_window(s.conn, s.window,
            xcb.XCB_CONFIG_WINDOW_STACK_MODE, &[_]u32{xcb.XCB_STACK_MODE_ABOVE});
    }

    pub fn isVisible() bool            { return if (state) |s| s.visible else false; }
    pub fn getGlobalVisibility() bool  { return if (state) |s| s.global_visible else false; }
    pub fn setGlobalVisibility(visible: bool) void { if (state) |s| s.global_visible = visible; }

    pub fn setBarState(wm: *defs.WM, action: BarAction) void {
        const s = state orelse return;

        if (action == .toggle) s.global_visible = !s.global_visible;

        const current_ws    = workspaces.getCurrentWorkspace() orelse 0;
        const is_fullscreen = action != .hide_fullscreen and
            wm.fullscreen.getForWorkspace(current_ws) != null;

        const show = !is_fullscreen and s.global_visible and action != .hide_fullscreen;
        if (s.visible == show and action != .toggle) return;

        s.visible = show;

        if (action == .toggle) {
            if (show) submitDraw(wm, true);
            _ = xcb.xcb_grab_server(wm.conn);
            if (show) _ = xcb.xcb_map_window(s.conn, s.window)
            else      _ = xcb.xcb_unmap_window(s.conn, s.window);
            const saved = s.visible;
            if (is_fullscreen) s.visible = s.global_visible;
            retileAllWorkspacesNoGrab(wm);
            if (is_fullscreen) s.visible = saved;
            _ = xcb.xcb_ungrab_server(wm.conn);
            utils.flush(wm.conn);
        } else {
            if (show) {
                // Draw first so the window is fully painted before it becomes
                // visible.  submitDraw calls dc.flush internally so the draw
                // data reaches the server before xcb_map_window is sent.
                submitDraw(wm, true);
                _ = xcb.xcb_map_window(s.conn, s.window);
            } else {
                _ = xcb.xcb_unmap_window(s.conn, s.window);
            }
            utils.flush(wm.conn);
            tiling.retileCurrentWorkspace(wm);
        }

        debug.info("Bar {s} ({s})", .{ if (show) "shown" else "hidden", @tagName(action) });
        clock_segment.updateTimerState();
    }

    pub fn updateIfDirty(wm: *defs.WM) !void {
        const s = state orelse return;
        if (!s.visible) return;
        if (s.dirty) {
            submitDraw(wm, false);
            s.clearDirty();
        } else if (s.dirty_clock) {
            signalClockDirty();
            s.dirty_clock = false;
        }
    }

    pub fn checkClockUpdate() void {
        const s = state orelse return;
        if (!s.visible) return;
        signalClockDirty();
    }

    pub fn pollTimeoutMs() i32 {
        return clock_segment.pollTimeoutMs();
    }

    pub fn updateTimerState() void {
        clock_segment.updateTimerState();
    }

    pub fn handleExpose(event: *const xcb.xcb_expose_event_t, wm: *defs.WM) void {
        if (state) |s| if (event.window == s.window and event.count == 0) {
            if (wm.drag_state.active) {
                s.markDirty();
            } else {
                submitDraw(wm, false);
            }
        };
    }

    pub fn handlePropertyNotify(event: *const xcb.xcb_property_notify_event_t, wm: *defs.WM) void {
        const s = state orelse return;

        if (event.window == wm.root and event.atom == xcb.XCB_ATOM_WM_NAME) {
            status_segment.update(wm, &s.status_text, s.allocator) catch |e|
                debug.warnOnErr(e, "status_segment.update");
            s.markDirty();
            return;
        }

        if (wm.focused_window) |focused_win| {
            if (event.window != focused_win) return;
            // Use the atom pre-interned at State init — avoids a hash lookup on
            // every PropertyNotify event.  A zero atom means the intern failed at
            // startup; fall back to skipping the _NET_WM_NAME check.
            const net_wm_name = s.net_wm_name_atom;
            if (event.atom == xcb.XCB_ATOM_WM_NAME or
                (net_wm_name != 0 and event.atom == net_wm_name))
            {
                // Mark the title as stale; the bar thread will see this flag in
                // the next snapshot and clear its cached title before drawing.
                s.title_invalidated = true;
                s.markDirty();
            }
        }
    }

    pub fn monitorFocusedWindow(wm: *defs.WM) void {
        const win = wm.focused_window orelse return;
        const s   = state orelse return;

        // Nothing to do if we're already monitoring this exact window.
        if (s.last_monitored_window == win) return;

        // Restore the previous window's event mask to what it was before we
        // added PROPERTY_CHANGE.  Without this, every formerly-focused window
        // retains the extra mask and keeps generating PropertyNotify events
        // that the WM must receive, wake up for, and discard.
        if (s.last_monitored_window) |old_win| {
            _ = xcb.xcb_change_window_attributes(wm.conn, old_win,
                xcb.XCB_CW_EVENT_MASK, &[_]u32{s.last_monitored_base_mask});
        }

        // Read the new window's current event mask so we can restore it later
        // instead of blindly replacing it.  _unchecked skips the error cookie
        // overhead; we treat a missing reply as mask == 0.
        const cookie = xcb.xcb_get_window_attributes_unchecked(wm.conn, win);
        const reply  = xcb.xcb_get_window_attributes_reply(wm.conn, cookie, null);
        const base: u32 = if (reply) |r| blk: {
            const m = r.your_event_mask;
            std.c.free(r);
            break :blk m;
        } else 0;

        s.last_monitored_base_mask = base;
        s.last_monitored_window    = win;
        _ = xcb.xcb_change_window_attributes(wm.conn, win,
            xcb.XCB_CW_EVENT_MASK, &[_]u32{base | xcb.XCB_EVENT_MASK_PROPERTY_CHANGE});
    }

    pub fn handleButtonPress(event: *const xcb.xcb_button_press_event_t, wm: *defs.WM) void {
        if (state) |s| if (event.event == s.window) {
            const ws_state = workspaces.getState() orelse return;
            const ws_w     = workspaces_segment.getCachedWorkspaceWidth();
            if (ws_w == 0) return;
            const click_x           = @max(0, event.event_x - s.cached_workspace_x);
            const clicked_ws: usize = @intCast(@divFloor(click_x, ws_w));
            if (clicked_ws < ws_state.workspaces.len) {
                workspaces.switchTo(wm, clicked_ws);
                s.markDirty();
            }
        };
    }

    fn retileAllWorkspacesNoGrab(wm: *defs.WM) void {
        const ws_state = workspaces.getState() orelse return;
        const tiling_active = wm.config.tiling.enabled and
            if (tiling.getState()) |t| t.enabled else false;

        if (!tiling_active) {
            tiling.retileCurrentWorkspace(wm);
            return;
        }

        const original_ws = ws_state.current;

        for (ws_state.workspaces, 0..) |*ws, idx| {
            if (ws.windows.items().len == 0) continue;
            if (wm.fullscreen.getForWorkspace(@intCast(idx)) != null) continue;

            ws_state.current = @intCast(idx);
            tiling.retileCurrentWorkspace(wm);

            if (@as(u8, @intCast(idx)) != original_ws) {
                for (ws.windows.items()) |win| {
                    _ = xcb.xcb_configure_window(wm.conn, win,
                        xcb.XCB_CONFIG_WINDOW_X, &[_]u32{@bitCast(@as(i32, constants.OFFSCREEN_X_POSITION))});
                    tiling.invalidateGeomCache(win);
                }
            }
        }

        ws_state.current = original_ws;
    }
};
