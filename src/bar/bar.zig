//! Status bar: renders segments via Cairo/Pango into an XCB override-redirect window.
//!
//! A dedicated bar thread owns the DrawContext and all rendering. The main thread
//! captures a lightweight BarSnapshot and posts it to a BarChannel; the bar thread
//! wakes, draws, and loops. Draws that must complete before the caller returns (e.g.
//! inside xcb_grab_server) use submitDraw(wm, true), which blocks until done.
//!
//! Clock-only updates bypass the snapshot path: the bar thread redraws just the
//! clock segment using its cached x-position.

const std   = @import("std");
const defs  = @import("defs");
const xcb   = defs.xcb;
const debug = @import("debug");

const bar_flags = @import("bar_flags");

pub const BarAction = enum { toggle, hide_fullscreen, show_fullscreen };
    const drawing    = @import("drawing");
    const tiling     = @import("tiling");
    const utils      = @import("utils");
    const workspaces = @import("workspaces");
    const constants  = @import("constants");
    const dpi_mod    = @import("dpi");

    const workspaces_segment = if (bar_flags.has_tags) @import("tags") else struct {
        pub fn draw(_: *drawing.DrawContext, _: defs.BarConfig, _: u16, x: u16, _: u8, _: []const bool) !u16 { return x; }
        pub fn invalidate() void {}
        pub fn getCachedWorkspaceWidth() u16 { return 0; }
    };

    const DrawOnlyStub = struct {
        pub fn draw(_: *drawing.DrawContext, _: defs.BarConfig, _: u16, x: u16) !u16 { return x; }
    };
    const layout_segment     = if (bar_flags.has_layout)     @import("layout")     else DrawOnlyStub;
    const variations_segment = if (bar_flags.has_variations) @import("variations") else DrawOnlyStub;

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
        pub fn pollTimeoutMs() i32 { return -1; }
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

    /// Point-in-time bar state. Lives in BarChannel.slots[]; never heap-allocated.
    /// Variable-length fields use ArrayListUnmanaged so buffers grow only when
    /// workspace/window counts increase — reused across frames at stable capacity.
    const BarSnapshot = struct {
        focused_window:    ?u32                          = null,
        current_ws_wins:   std.ArrayListUnmanaged(u32)   = .empty,
        minimized:         std.ArrayListUnmanaged(u32)   = .empty,
        ws_has_windows:    std.ArrayListUnmanaged(bool)  = .empty,
        ws_current:        u8                            = 0,
        ws_count:          u32                           = 0,
        status_text:       std.ArrayListUnmanaged(u8)    = .empty,
        title_invalidated: bool                          = false,

        fn deinit(snap: *BarSnapshot, allocator: std.mem.Allocator) void {
            snap.current_ws_wins.deinit(allocator);
            snap.minimized.deinit(allocator);
            snap.ws_has_windows.deinit(allocator);
            snap.status_text.deinit(allocator);
        }
    };

    // ── Channel ───────────────────────────────────────────────────────────────

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
        snap_ready:    bool                 = false,
        clock_dirty:   bool                 = false,
        quit:          bool                 = false,
        draw_gen:      u64                  = 0,
        focus_dirty:   bool                 = false,
        focus_new_win: ?u32                 = null,
    };

    var g_channel: BarChannel     = .{};
    var g_bar_thread: ?std.Thread = null;

    // ── State ─────────────────────────────────────────────────────────────────

    const State = struct {
        window:               u32,
        colormap:             u32,
        width:                u16,
        height:               u16,
        dc:                   *drawing.DrawContext,
        conn:                 *xcb.xcb_connection_t,
        config:               defs.BarConfig,
        status_text:          std.ArrayList(u8),
        cached_title:         std.ArrayList(u8),
        cached_title_window:  ?u32,
        dirty:                bool,
        title_invalidated:    bool,
        visible:              bool,
        global_visible:       bool,
        has_transparency:     bool,
        allocator:            std.mem.Allocator,
        cached_clock_width:   u16,
        cached_clock_x:       ?u16,
        cached_workspace_x:   u16,
        has_clock_segment:    bool,
        cached_title_x:       u16,
        cached_title_w:       u16,
        cached_ws_wins:       []u32,
        cached_min_wins:      []u32,
        title_layout_valid:   bool,
        cached_right_total:          u16,
        cached_right_total_ws_count: u32, // invalidation key for cached_right_total
        last_monitored_window:       ?u32,
        last_monitored_base_mask:    u32,
        net_wm_name_atom:            xcb.xcb_atom_t,

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
                .cached_ws_wins       = &.{},
                .cached_min_wins      = &.{},
                .title_layout_valid   = false,
                .cached_right_total          = 0,
                .cached_right_total_ws_count = std.math.maxInt(u32),
                .last_monitored_window       = null,
                .last_monitored_base_mask    = 0,
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
                    xcb.XCB_CW_EVENT_MASK, &[_]u32{self.last_monitored_base_mask});
            if (self.colormap != 0) _ = xcb.xcb_free_colormap(self.conn, self.colormap);
            self.status_text.deinit(self.allocator);
            self.cached_title.deinit(self.allocator);
            self.allocator.free(self.cached_ws_wins);
            self.allocator.free(self.cached_min_wins);
            self.allocator.destroy(self);
        }

        fn markDirty(self: *State) void { self.dirty = true; self.cached_clock_x = null; }

        // Segment drawing (bar thread only)

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
                    snap.ws_current, snap.ws_has_windows.items),
                .layout     => try layout_segment.draw(self.dc, self.config, self.height, x),
                .variations => try variations_segment.draw(self.dc, self.config, self.height, x),
                .title      => try title_segment.draw(
                    self.dc, self.config, self.height, x, width orelse 100,
                    self.conn, snap.focused_window,
                    snap.current_ws_wins.items, snap.minimized.items,
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

        fn drawAll(self: *State, snap: *const BarSnapshot) !void {
            if (snap.title_invalidated) self.cached_title_window = null;
            if (self.has_transparency) self.dc.clearTransparent();
            self.dc.fillRect(0, 0, self.width, self.height, self.config.bg);

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
            if (title_seg_w > 0) self.updateTitleCache(snap, title_seg_x, title_seg_w);
        }

        fn drawClockOnly(self: *State) void {
            const clock_x = self.cached_clock_x orelse return;
            _ = clock_segment.draw(self.dc, self.config, self.height, clock_x) catch |e|
                debug.warnOnErr(e, "drawClockOnly");
            self.dc.flush();
        }

        fn drawTitleOnly(self: *State, new_focused: ?u32) void {
            if (!self.title_layout_valid or self.cached_title_w == 0) return;
            _ = title_segment.draw(
                self.dc, self.config, self.height,
                self.cached_title_x, self.cached_title_w,
                self.conn, new_focused,
                self.cached_ws_wins, self.cached_min_wins,
                &self.cached_title, &self.cached_title_window,
                true, self.allocator,
            ) catch |e| { debug.warnOnErr(e, "drawTitleOnly"); return; };
            self.dc.flush();
        }

        fn dupeIfChanged(allocator: std.mem.Allocator, cached: *[]u32, fresh: []const u32) void {
            if (std.mem.eql(u32, cached.*, fresh)) return;
            if (allocator.dupe(u32, fresh)) |d| { allocator.free(cached.*); cached.* = d; } else |_| {}
        }

        fn updateTitleCache(self: *State, snap: *const BarSnapshot, x: u16, w: u16) void {
            dupeIfChanged(self.allocator, &self.cached_ws_wins, snap.current_ws_wins.items);
            dupeIfChanged(self.allocator, &self.cached_min_wins, snap.minimized.items);
            self.cached_title_x     = x;
            self.cached_title_w     = w;
            self.title_layout_valid = true;
        }
    };

    // ── Bar thread ────────────────────────────────────────────────────────────

    fn barThreadFn(s: *State) void {
        while (true) {
            g_channel.mutex.lock();
            while (!g_channel.quit and !g_channel.snap_ready and
                   !g_channel.clock_dirty and !g_channel.focus_dirty)
            {
                g_channel.work_cond.wait(&g_channel.mutex);
            }
            if (g_channel.quit) { g_channel.mutex.unlock(); return; }

            const snap_ready    = g_channel.snap_ready;
            // read_idx is 1 - write_idx: the slot the main thread just filled.
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
        g_channel.snap_ready  = false;
        g_channel.focus_dirty = false;
        g_channel.clock_dirty = false;
        g_channel.work_cond.signal();
        g_channel.mutex.unlock();

        if (g_bar_thread) |t| { t.join(); g_bar_thread = null; }
        g_channel.quit = false;
    }

    // ── Snapshot capture (main thread) ───────────────────────────────────────

    /// Populates a pre-allocated BarSnapshot slot in-place.
    /// All variable-length fields use ArrayListUnmanaged that grow only when
    /// their content exceeds the previously allocated capacity.
    fn captureIntoSlot(wm: *defs.WM, s: *State, snap: *BarSnapshot) !void {
        const allocator = s.allocator;

        // Status text.
        snap.status_text.clearRetainingCapacity();
        try snap.status_text.appendSlice(allocator, s.status_text.items);

        // Minimized window IDs — count is known upfront, so no intermediate list needed.
        const min_count: usize = if (wm.minimize) |*ms| ms.minimized_info.count() else 0;
        snap.minimized.clearRetainingCapacity();
        try snap.minimized.ensureTotalCapacity(allocator, min_count);
        if (wm.minimize) |*ms| {
            var it = ms.minimized_info.keyIterator();
            while (it.next()) |key| snap.minimized.appendAssumeCapacity(key.*);
        }

        // Workspace state.
        const ws_state  = workspaces.getState();
        snap.ws_count   = if (ws_state) |ws| @intCast(ws.workspaces.len) else 0;
        snap.ws_current = if (ws_state) |ws| ws.current else 0;

        try snap.ws_has_windows.resize(allocator, snap.ws_count);
        if (ws_state) |ws| {
            for (ws.workspaces, 0..) |*workspace, i|
                snap.ws_has_windows.items[i] = workspace.windows.count() > 0;
        }

        // Current workspace window list.
        snap.current_ws_wins.clearRetainingCapacity();
        if (ws_state) |ws| {
            if (ws.current < ws.workspaces.len)
                try snap.current_ws_wins.appendSlice(allocator, ws.workspaces[ws.current].windows.items());
        }

        snap.focused_window    = wm.focused_window;
        snap.title_invalidated = s.title_invalidated;
        s.title_invalidated    = false;
    }

    /// Posts a snapshot to the bar thread. `wait = true` blocks until the draw
    /// completes — use this inside xcb_grab_server regions.
    ///
    /// write_idx is only mutated by the main thread, so reading it without the
    /// lock is safe here. The mutex acquire before the flip acts as the fence.
    fn submitDraw(wm: *defs.WM, wait: bool) void {
        const s = state orelse return;
        if (!s.visible) return;

        const idx = g_channel.write_idx;
        captureIntoSlot(wm, s, &g_channel.slots[idx]) catch |e| {
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

    // ── Module singleton ─────────────────────────────────────────────────────

    var state: ?*State = null;

    // ── Pre-interned atoms ───────────────────────────────────────────────────

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

    fn detectClockSegment(config: *const defs.BarConfig) bool {
        if (comptime !bar_flags.has_clock) return false;
        for (config.layout.items) |layout|
            for (layout.segments.items) |seg|
                if (seg == .clock) return true;
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
        const visual_info = if (want_transparency)
            drawing.findVisualByDepth(wm.screen, 32)
        else
            drawing.VisualInfo{ .visual_type = null, .visual_id = wm.screen.root_visual };
        const depth: u8 = if (want_transparency) 32 else xcb.XCB_COPY_FROM_PARENT;
        const visual_id = visual_info.visual_id;

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

    fn setWindowProperties(wm: *defs.WM, window: u32, height: u16) void {
        const strut: [12]u32 = if (wm.config.bar.vertical_position == .top)
            .{ 0, 0, 0, height, 0, 0, 0, 0, 0, 0, 0, wm.screen.width_in_pixels }
        else
            .{ 0, 0, height, 0, 0, 0, 0, 0, 0, wm.screen.width_in_pixels, 0, 0 };

        if (g_atoms.strut_partial    != 0) setPropAtom(wm.conn, window, g_atoms.strut_partial,    xcb.XCB_ATOM_CARDINAL, &strut);
        if (g_atoms.window_type      != 0) setPropAtom(wm.conn, window, g_atoms.window_type,      xcb.XCB_ATOM_ATOM, &[_]u32{g_atoms.window_type_dock});
        if (g_atoms.wm_state         != 0) setPropAtom(wm.conn, window, g_atoms.wm_state,         xcb.XCB_ATOM_ATOM, &[_]u32{g_atoms.state_above, g_atoms.state_sticky});
        if (g_atoms.allowed_actions  != 0) setPropAtom(wm.conn, window, g_atoms.allowed_actions,  xcb.XCB_ATOM_ATOM, &[_]u32{g_atoms.action_close, g_atoms.action_above, g_atoms.action_stick});
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
        const px_per_pt: f32  = @as(f32, @floatFromInt(@max(1, asc + desc))) / @as(f32, @floatFromInt(TRIAL_PT));
        const max_size_pt     = @as(f32, @floatFromInt(bar_height)) / px_per_pt;
        return @max(1, @as(u16, @intFromFloat(@round(max_size_pt * (wm.config.bar.font_size.value / 100.0)))));
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

        const asc, const desc = temp_dc.getMetrics();
        return @intCast(std.math.clamp(@as(u32, @intCast(asc + desc)), MIN_BAR_HEIGHT, MAX_BAR_HEIGHT));
    }

    // ── Public API ────────────────────────────────────────────────────────────

    pub fn init(wm: *defs.WM) !void {
        if (!wm.config.bar.enabled) return error.BarDisabled;

        initAtoms();
        drawing.initFontCache(wm.allocator);

        const height = try calculateBarHeight(wm);
        const y_pos  = barYPos(wm, height);
        const setup  = createBarWindow(wm, height, y_pos);
        errdefer { _ = xcb.xcb_destroy_window(wm.conn, setup.window); if (setup.colormap != 0) _ = xcb.xcb_free_colormap(wm.conn, setup.colormap); }

        setWindowProperties(wm, setup.window, height);

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
        submitDraw(wm, true);
        _ = xcb.xcb_map_window(wm.conn, setup.window);
        utils.flush(wm.conn);
    }

    pub fn deinit() void {
        stopBarThread();
        if (state) |s| {
            // Free the buffers grown inside the double-buffer channel slots.
            for (&g_channel.slots) |*slot| slot.deinit(s.allocator);
            _ = xcb.xcb_destroy_window(s.conn, s.window);
            s.dc.deinit();
            drawing.deinitFontCache(s.allocator);
            s.deinit();
            state = null;
        }
    }

    pub fn reload(wm: *defs.WM) void {
        const old = state orelse {
            init(wm) catch |err| {
                if (err != error.BarDisabled) debug.err("Bar init failed: {}", .{err});
            };
            return;
        };
        if (!wm.config.bar.enabled) { deinit(); return; }

        const height = calculateBarHeight(wm) catch DEFAULT_BAR_HEIGHT;
        const y_pos  = barYPos(wm, height);
        const setup  = createBarWindow(wm, height, y_pos);

        reloadImpl(wm, old, setup, height) catch |err| {
            _ = xcb.xcb_destroy_window(wm.conn, setup.window);
            if (setup.colormap != 0) _ = xcb.xcb_free_colormap(wm.conn, setup.colormap);
            debug.err("Bar reload failed ({s}), keeping old bar", .{@errorName(err)});
        };
    }

    fn reloadImpl(wm: *defs.WM, old: *State, setup: BarWindowSetup, height: u16) !void {
        setWindowProperties(wm, setup.window, height);

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

        stopBarThread();
        state = new_state;
        submitDraw(wm, true);
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

    pub fn toggleBarPosition(wm: *defs.WM) void {
        const s = state orelse return;
        wm.config.bar.vertical_position = switch (wm.config.bar.vertical_position) {
            .top    => .bottom,
            .bottom => .top,
        };
        const new_y = barYPos(wm, s.height);
        setWindowProperties(wm, s.window, s.height);
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

    /// Posts a focus-only update. Skipped when a full redraw is already pending.
    pub fn notifyFocusChange(_: *defs.WM, new_win: ?u32) void {
        const s = state orelse return;
        if (!s.visible) return;
        g_channel.mutex.lock();
        g_channel.focus_dirty   = true;
        g_channel.focus_new_win = new_win;
        g_channel.work_cond.signal();
        g_channel.mutex.unlock();
    }

    pub fn getBarWindow() u32        { return if (state) |s| s.window else 0; }
    pub fn isBarWindow(win: u32) bool { return if (state) |s| s.window == win else false; }
    pub fn getBarHeight() u16         { return if (state) |s| s.height else 0; }
    pub fn isBarInitialized() bool    { return state != null; }
    pub fn hasClockSegment() bool     { return if (state) |s| s.has_clock_segment else false; }
    pub fn markDirty() void           { if (state) |s| s.markDirty(); }
    pub fn isVisible() bool           { return if (state) |s| s.visible else false; }
    pub fn getGlobalVisibility() bool { return if (state) |s| s.global_visible else false; }
    pub fn setGlobalVisibility(visible: bool) void { if (state) |s| s.global_visible = visible; }

    pub fn redrawImmediate(wm: *defs.WM) void {
        const s = state orelse return;
        if (!s.visible) return;
        submitDraw(wm, true);
        s.dirty = false;
    }

    pub fn raiseBar() void {
        if (state) |s| _ = xcb.xcb_configure_window(s.conn, s.window,
            xcb.XCB_CONFIG_WINDOW_STACK_MODE, &[_]u32{xcb.XCB_STACK_MODE_ABOVE});
    }

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

    pub fn handleExpose(event: *const xcb.xcb_expose_event_t, wm: *defs.WM) void {
        if (state) |s| if (event.window == s.window and event.count == 0) {
            if (wm.drag_state.active) s.markDirty() else submitDraw(wm, false);
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

        const focused_win = wm.focused_window orelse return;
        if (event.window != focused_win) return;

        const net_wm_name = s.net_wm_name_atom;
        if (event.atom == xcb.XCB_ATOM_WM_NAME or (net_wm_name != 0 and event.atom == net_wm_name)) {
            s.title_invalidated = true;
            s.markDirty();
        }
    }

    pub fn monitorFocusedWindow(wm: *defs.WM) void {
        const win = wm.focused_window orelse return;
        const s   = state orelse return;
        if (s.last_monitored_window == win) return;

        if (s.last_monitored_window) |old_win|
            _ = xcb.xcb_change_window_attributes(wm.conn, old_win,
                xcb.XCB_CW_EVENT_MASK, &[_]u32{s.last_monitored_base_mask});

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

        if (!tiling_active) { tiling.retileCurrentWorkspace(wm); return; }

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
