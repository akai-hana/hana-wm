//! Status bar
//! Creates and manages the WM status bar, rendering all configured segments.

const std = @import("std");

const core = @import("core");
const xcb = core.xcb;
const utils = @import("utils");
const scale = @import("scale");
const debug = @import("debug");

const types = @import("types");

const tracking = @import("tracking");
const focus = @import("focus");
const fullscreen = @import("fullscreen");
const minimize = @import("minimize");
const workspaces = @import("workspaces");

const drag = @import("drag");
const window = @import("window");

const tiling = @import("tiling");

const drawing = @import("drawing");
const prompt = @import("prompt");
const carousel = @import("carousel");

const clock = @import("clock");
const layout = @import("layout");
const title = @import("title");
const variants = @import("variants");
const tags = @import("tags");

// Public API types

pub const BarAction = enum { toggle, hide_fullscreen, show_fullscreen };

// Constants

const MIN_BAR_HEIGHT: u32 = scale.BAR_MIN_HEIGHT_PX; // canonical value defined in scale.zig
const MAX_BAR_HEIGHT: u32 = 200;
const DEFAULT_BAR_HEIGHT: u32 = 24;
const FALLBACK_WORKSPACES_WIDTH: u16 = 270;
const LAYOUT_WIDTH: u16 = 60;
const TITLE_MIN_WIDTH: u16 = 100;

// Core data structures

/// List of per-window title strings, each individually heap-allocated.
///
/// Filled once per redraw (one dupe per window, in workspace order) and read
/// back by index with no offset arithmetic. Replaces an earlier flat-buffer-
/// plus-offset-array representation that forced every reader to reconstruct
/// a slice from a byte range instead of indexing directly.
const WindowTitles = struct {
    list: std.ArrayListUnmanaged([]const u8) = .empty,

    /// Frees every owned title string and empties the list.
    pub fn clear(self: *WindowTitles, allocator: std.mem.Allocator) void {
        for (self.list.items) |t| allocator.free(t);
        self.list.clearRetainingCapacity();
    }

    /// Appends an owned dupe of `title_str`.
    pub fn append(self: *WindowTitles, allocator: std.mem.Allocator, title_str: []const u8) !void {
        const owned = try allocator.dupe(u8, title_str);
        errdefer allocator.free(owned);
        try self.list.append(allocator, owned);
    }

    /// Clears the list, then refills it with dupes of `titles`.
    /// Partial failures leave the list shorter than `titles` rather than erroring out.
    pub fn replaceWith(self: *WindowTitles, allocator: std.mem.Allocator, titles: []const []const u8) void {
        self.clear(allocator);
        for (titles) |t| self.append(allocator, t) catch break;
    }

    pub fn deinit(self: *WindowTitles, allocator: std.mem.Allocator) void {
        self.clear(allocator);
        self.list.deinit(allocator);
    }
};

/// Point-in-time bar state, captured fresh before each draw and diffed
/// against the previous frame's snapshot (see captureStateIntoSlot) to
/// decide which segments actually need repainting.
const BarSnapshot = struct {
    focused_window: ?u32 = null,
    focused_title: std.ArrayListUnmanaged(u8) = .empty,
    current_workspace_windows: std.ArrayListUnmanaged(u32) = .empty,
    minimized_windows: std.AutoHashMapUnmanaged(u32, void) = .{},
    workspace_has_windows: std.ArrayListUnmanaged(bool) = .empty,
    current_workspace: u8 = 0,
    workspace_count: u32 = 0,
    is_all_view_active: bool = false,
    is_title_invalidated: bool = false,
    is_full_redraw: bool = true, // workspace_count changed or full-redraw forced
    is_workspace_dirty: bool = true, // workspace state changed
    is_title_dirty: bool = true, // title / focus / minimised state changed

    /// Pre-fetched window titles, indexed parallel to `current_workspace_windows`;
    /// fetched once per snapshot so the segmented-title draw path never issues
    /// its own xcb_get_property calls.
    window_titles: WindowTitles = .{},

    /// Pre-fetched window geometry, indexed parallel to `current_workspace_windows`
    /// (same indexing as `window_titles`). Fetched once per snapshot, on the main
    /// thread, so the segmented-title draw path — including drawTitleOnly's
    /// carousel-thread fast path via drawCached — never issues its own
    /// xcb_get_geometry round-trip for a window the tiling cache doesn't cover
    /// (e.g. a floating window).
    window_geoms: std.ArrayListUnmanaged(utils.Rect) = .empty,

    fn deinit(snap: *BarSnapshot, allocator: std.mem.Allocator) void {
        snap.focused_title.deinit(allocator);
        snap.current_workspace_windows.deinit(allocator);
        snap.minimized_windows.deinit(allocator);
        snap.workspace_has_windows.deinit(allocator);
        snap.window_titles.deinit(allocator);
        snap.window_geoms.deinit(allocator);
    }
};

/// Serializes access to the shared Cairo/XCB DrawContext. All bar drawing is
/// now called directly (no cross-thread work queue), except for two small
/// dedicated timers that still run on their own threads: clock.zig (ticks once
/// per wall-clock second) and carousel.zig (ticks once per display refresh
/// while a title is actively scrolling). This mutex is what keeps those two
/// threads from ever painting into the DrawContext at the same instant as the
/// main WM thread.
var draw_mutex: utils.Mutex = .{};

/// All atoms needed to declare the bar window as a dock to the compositor.
const BarAtoms = struct {
    strut_partial: xcb.xcb_atom_t = 0,
    window_type: xcb.xcb_atom_t = 0,
    window_type_dock: xcb.xcb_atom_t = 0,
    wm_state: xcb.xcb_atom_t = 0,
    state_above: xcb.xcb_atom_t = 0,
    state_sticky: xcb.xcb_atom_t = 0,
    allowed_actions: xcb.xcb_atom_t = 0,
    action_close: xcb.xcb_atom_t = 0,
    action_above: xcb.xcb_atom_t = 0,
    action_stick: xcb.xcb_atom_t = 0,
};

/// Owns all live bar state.
const Bar = struct {
    state: ?*State = null,
    atoms: BarAtoms = .{},
    /// Forces a full bar redraw on the next submitDraw (expose, reload, position toggle, show).
    /// Read and written exclusively on the main thread — does not require mutex protection.
    pending_force_full_redraw: bool = false,
};

var gBar: Bar = .{};

// Sub-state types

/// X11 connection and window handle; stable for the bar's lifetime.
const WindowCtx = struct {
    conn: *xcb.xcb_connection_t,
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

/// Per-draw layout geometry; invalidated when workspace_count changes or the
/// clock position is reset.
const LayoutCache = struct {
    clock_width: u16 = 0,
    clock_x: ?u16 = null,
    workspace_x: u16 = 0,
    right_section_width: u16 = 0,
    cached_workspace_count: u32 = std.math.maxInt(u32),
};

/// Focus/title/workspace rendering cache; updated after each full draw.
const TitleCache = struct {
    title: std.ArrayListUnmanaged(u8) = .empty,
    title_window: ?u32 = null,
    focused_window: ?u32 = null,
    workspace_windows: std.ArrayListUnmanaged(u32) = .empty,
    minimized_windows: std.AutoHashMapUnmanaged(u32, void) = .{},
    /// Mirrors BarSnapshot.window_titles; populated by syncTitleCache so
    /// drawTitleOnly can pass cached titles without re-fetching from the X server.
    window_titles: WindowTitles = .{},
    /// Mirrors BarSnapshot.window_geoms; populated by syncTitleCache so
    /// drawTitleOnly can pass cached geometry without an xcb_get_geometry
    /// round-trip from the carousel thread.
    window_geoms: std.ArrayListUnmanaged(utils.Rect) = .empty,
    title_x: u16 = 0,
    title_width: u16 = 0,
    is_layout_valid: bool = false,
    is_invalidated: bool = false,

    fn deinit(self: *TitleCache, allocator: std.mem.Allocator) void {
        self.title.deinit(allocator);
        self.workspace_windows.deinit(allocator);
        self.minimized_windows.deinit(allocator);
        self.window_titles.deinit(allocator);
        self.window_geoms.deinit(allocator);
    }
};

// State

const State = struct {
    win: WindowCtx,
    render: RenderCtx,
    layout_cache: LayoutCache = .{},
    title_cache: TitleCache = .{},
    is_visible: bool = true,
    is_globally_visible: bool = true,
    is_dirty: bool = false,
    has_clock_segment: bool,
    /// Title geometry captured by drawAllInner; consumed by drawAll/drawAllNoFlush
    /// to call syncTitleCache after the flush decision.
    title_cache_pending_x: ?u16 = null,
    title_cache_pending_w: u16 = 0,
    /// Ping-ponged snapshot pair used to diff this frame's state against the
    /// last one (see captureStateIntoSlot). snap_idx names the "current" slot;
    /// `1 - snap_idx` is "previous". Flipped after every draw.
    snapshots: [2]BarSnapshot = .{ .{}, .{} },
    snap_idx: u1 = 0,

    fn init(
        allocator: std.mem.Allocator,
        conn: *xcb.xcb_connection_t,
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
                .clock_width = dc.measureTextWidth(clock.CLOCK_MEASURE_STRING) + 2 * config.scaledSegmentPadding(height),
            },
            .has_clock_segment = blk: {
                for (config.layout.items) |lay|
                    for (lay.segments.items) |seg|
                        if (seg == .clock) break :blk true;
                break :blk false;
            },
        };
        try s.title_cache.title.ensureTotalCapacity(allocator, 256);
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

    fn measureSegmentWidth(self: *State, snap: *const BarSnapshot, segment: types.BarSegment) u16 {
        return switch (segment) {
            .workspaces => if (snap.workspace_count > 0)
                @intCast(snap.workspace_count * tags.getCachedWorkspaceWidth())
            else
                FALLBACK_WORKSPACES_WIDTH,
            .layout, .variants => LAYOUT_WIDTH,
            .title => TITLE_MIN_WIDTH,
            .clock => self.layout_cache.clock_width,
        };
    }

    fn drawSegment(self: *State, snap: *const BarSnapshot, segment: types.BarSegment, x: u16, width: ?u16) !u16 {
        if (segment == .workspaces) self.layout_cache.workspace_x = x;
        const r = &self.render;
        return switch (segment) {
            .workspaces => try tags.draw(r.dc, r.config, r.height, x, snap.current_workspace, snap.workspace_has_windows.items, snap.is_all_view_active),
            .layout => try layout.draw(r.dc, r.config, r.height, x),
            .variants => try variants.draw(r.dc, r.config, r.height, x),
            .title => blk: {
                const wins = snap.current_workspace_windows.items;
                const minimized_title: []const u8 =
                    if (wins.len > 0 and snap.minimized_windows.contains(wins[0]) and snap.window_titles.list.items.len > 0)
                        snap.window_titles.list.items[0]
                    else
                        "";
                break :blk try prompt.draw(
                    r.dc,
                    r.config,
                    r.height,
                    x,
                    width orelse TITLE_MIN_WIDTH,
                    self.win.conn,
                    snap.focused_window,
                    snap.focused_title.items,
                    minimized_title,
                    snap.current_workspace_windows.items,
                    &snap.minimized_windows,
                    snap.window_titles.list.items,
                    snap.window_geoms.items,
                    &self.title_cache.title,
                    &self.title_cache.title_window,
                    snap.is_title_invalidated,
                    r.allocator,
                );
            },
            .clock => try clock.draw(r.dc, r.config, r.height, x),
        };
    }

    /// Draws `segment`, catching and logging any error instead of propagating it.
    /// On failure, returns `x` unchanged — the same signal drawSegment's callers
    /// already use for "this segment drew nothing" — so a single broken segment
    /// (bad config value, transient allocation failure, ...) can neither corrupt
    /// the layout of the segments around it nor abort the rest of the frame,
    /// leaving the off-screen pixmap partially drawn and never blitted.
    fn drawSegmentSafe(self: *State, snap: *const BarSnapshot, segment: types.BarSegment, x: u16, width: ?u16) u16 {
        return self.drawSegment(snap, segment, x, width) catch |e| {
            debug.warnOnErr(e, "bar drawSegment");
            return x;
        };
    }

    /// Returns true when `seg` should be skipped because its data has not changed
    /// since the last frame and a full redraw is not required.
    inline fn shouldSkipSegment(snap: *const BarSnapshot, seg: types.BarSegment) bool {
        if (snap.is_full_redraw) return false;
        return switch (seg) {
            .workspaces => !snap.is_workspace_dirty,
            .title => !snap.is_title_dirty,
            else => false,
        };
    }

    fn drawRightSegments(self: *State, snap: *const BarSnapshot, segments: []const types.BarSegment) !void {
        var right_x = self.render.width;
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
            const drew_to = self.drawSegmentSafe(snap, segments[i], right_x, null);
            const drew = drew_to != right_x;

            if (drew and pending_gap) {
                self.render.dc.fillRect(right_x + seg_w, 0, scaled_spacing, self.render.height, self.render.config.bg);
            } else if (!drew) {
                // Segment drew nothing: reclaim its reserved space so the next
                // segment is not placed in a phantom dead zone.
                right_x += seg_w;
                if (pending_gap) right_x += scaled_spacing; // reclaim reserved gap too
            }
            pending_gap = drew;
        }
    }

    /// When `flush` is true, blits the off-screen pixmap to the window (event-loop path).
    /// When false, only flushes Cairo to the pixmap — safe inside xcb_grab_server.
    fn drawAll(self: *State, snap: *const BarSnapshot, flush: bool) !void {
        try self.drawAllInner(snap);
        if (flush) self.render.dc.blit() else self.render.dc.renderOnly();
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
            self.layout_cache.right_section_width = right_total;
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
                    if (seg == .title) {
                        title_seg_x = x;
                        title_seg_w = seg_w;
                    }
                    if (shouldSkipSegment(snap, seg)) {
                        x += seg_w + scaled_spacing;
                        continue;
                    }
                    const x_before = x;
                    x = self.drawSegmentSafe(snap, seg, x, null);
                    if (x != x_before) {
                        self.render.dc.fillRect(x, 0, scaled_spacing, self.render.height, self.render.config.bg);
                        x += scaled_spacing;
                    }
                },
                .center => {
                    const remaining = @max(TITLE_MIN_WIDTH, self.render.width -| x -| right_total -| scaled_spacing);
                    for (lay.segments.items) |seg| {
                        const w = if (seg == .title) remaining else self.measureSegmentWidth(snap, seg);
                        if (seg == .title) {
                            title_seg_x = x;
                            title_seg_w = w;
                        }
                        if (shouldSkipSegment(snap, seg)) {
                            x += w;
                            if (seg != .title) x += scaled_spacing;
                            continue;
                        }
                        const x_before = x;
                        x = self.drawSegmentSafe(snap, seg, x, w);
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
                const clock_x = self.layout_cache.clock_x orelse return;
        _ = clock.draw(self.render.dc, self.render.config, self.render.height, clock_x) catch |e|
            debug.warnOnErr(e, "drawClockOnly");
        // renderOnly() flushes Cairo to the off-screen pixmap; blitAndFlush()
        // copies only the clock region to the window and calls xcb_flush.
        // Splitting the flush this way avoids a full-window blit plus a
        // separate main-thread xcb_flush call.
        self.render.dc.renderOnly();
        self.render.dc.blitAndFlush(clock_x, self.layout_cache.clock_width);
    }

    fn drawTitleOnly(self: *State, new_focused: ?u32) void {
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
                if (carousel.drawSegCarouselTickAuto(self.render.dc, self.render.config.title_accent_color)) return;
            } else {
                // Single-window mode: pass accent so the tick detects a bg change
                // (minimize/unminimize) and returns false to force a full rebuild.
                const accent: u32 = if (win_count == 1 and
                    self.title_cache.minimized_windows.contains(self.title_cache.workspace_windows.items[0]))
                    self.render.config.title_minimized_accent
                else
                    self.render.config.title_accent_color;
                if (carousel.drawCarouselTick(self.render.dc, accent, self.title_cache.title_x, self.title_cache.title_width)) return;
            }
        }

        // title_cache.title holds text for title_cache.title_window (the last full draw).
        // If new_focused differs, that text is stale — drawing it would build the carousel
        // with wrong content and reset start_ms, causing a visible restart on the next frame.
        // A snapReady draw is guaranteed to follow (scheduleFocusRedraw calls markDirty).
        if (new_focused != self.title_cache.title_window) return;

        _ = title.drawCached(
            .{
                .dc = self.render.dc,
                .config = self.render.config,
                .height = self.render.height,
                .start_x = self.title_cache.title_x,
                .width = self.title_cache.title_width,
                .conn = self.win.conn,
            },
            .{
                .focused_window = new_focused,
                .focused_title = self.title_cache.title.items,
                .minimized_title = blk: {
                    const wins = self.title_cache.workspace_windows.items;
                    const cached_titles = self.title_cache.window_titles.list.items;
                    break :blk if (wins.len > 0 and cached_titles.len > 0 and
                        self.title_cache.minimized_windows.contains(wins[0]))
                        cached_titles[0]
                    else
                        "";
                },
                .current_ws_wins = self.title_cache.workspace_windows.items,
                .minimized_set = &self.title_cache.minimized_windows,
                // Supply cached pre-fetched titles so drawSegmentedTitles skips
                // xcb_get_property calls on this fast-path redraw too.
                .titles = self.title_cache.window_titles.list.items,
                // Supply cached pre-fetched geometry so drawSegmentedTitles skips
                // xcb_get_geometry calls on this fast-path redraw as well — this
                // path runs on the dedicated carousel thread, where a blocking
                // X11 round-trip would stall the scroll animation.
                .geoms = self.title_cache.window_geoms.items,
            },
            self.render.allocator,
        ) catch |e| {
            debug.warnOnErr(e, "drawTitleOnly");
            return;
        };
        self.render.dc.blit();
    }

    /// Replacements are built before the swap so a failed allocation leaves the cache
    /// showing stale data rather than going silently empty.
    fn syncTitleCache(self: *State, snap: *const BarSnapshot, x: u16, w: u16) void {
        const alloc = self.render.allocator;

        var new_wins: std.ArrayListUnmanaged(u32) = .empty;
        if (new_wins.appendSlice(alloc, snap.current_workspace_windows.items)) {
            self.title_cache.workspace_windows.deinit(alloc);
            self.title_cache.workspace_windows = new_wins;
        } else |_| {
            new_wins.deinit(alloc);
        }

        if (snap.minimized_windows.clone(alloc)) |new_set| {
            self.title_cache.minimized_windows.deinit(alloc);
            self.title_cache.minimized_windows = new_set;
        } else |_| {
            // minimized_windows left stale rather than cleared.
        }

        // Keep cached titles in sync for the drawTitleOnly fast path.
        // replaceWith frees the old owned strings before duping the new ones,
        // so a failed dupe simply truncates the cache rather than desyncing it.
        self.title_cache.window_titles.replaceWith(alloc, snap.window_titles.list.items);

        // Keep cached geometry in sync for the drawTitleOnly fast path. Rect is
        // POD (no owned allocations per element), so — like workspace_windows
        // above — build the replacement before swapping it in: a failed
        // allocation leaves the existing cache untouched rather than emptied.
        var new_geoms: std.ArrayListUnmanaged(utils.Rect) = .empty;
        if (new_geoms.appendSlice(alloc, snap.window_geoms.items)) {
            self.title_cache.window_geoms.deinit(alloc);
            self.title_cache.window_geoms = new_geoms;
        } else |_| {
            new_geoms.deinit(alloc);
        }

        self.title_cache.focused_window = snap.focused_window;
        self.title_cache.title_x = x;
        self.title_cache.title_width = w;
        self.title_cache.is_layout_valid = true;
    }
};

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
/// `prev` is mutable (not const) because the "nothing changed" branches below relay
/// ownership of `window_titles`/`window_geoms` back and forth between the two ping-pong
/// snapshot slots via std.mem.swap instead of duping them every frame — see the comment
/// at the swap sites for why this is safe.
fn captureStateIntoSlot(s: *State, snap: *BarSnapshot, prev: *BarSnapshot, forced: bool) !void {
    const allocator = s.render.allocator;
    snap.minimized_windows.clearRetainingCapacity();
    try minimize.collectMinimizedIntoSet(&snap.minimized_windows, allocator);

    {
        const ws_state = workspaces.getState() orelse return;
        snap.workspace_count = @intCast(ws_state.workspaces.len);
        snap.current_workspace = ws_state.current;
        snap.is_all_view_active = ws_state.all_view_temp_wins.items.len > 0;
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
    }

    snap.focused_window = focus.getFocused();
    snap.is_title_invalidated = s.title_cache.is_invalidated;
    s.title_cache.is_invalidated = false;

    snap.focused_title.clearRetainingCapacity();
    if (snap.focused_window) |fw| {
        if (snap.focused_window != prev.focused_window or snap.is_title_invalidated) {
            title.fetchWindowTitleInto(core.getState().conn, fw, &snap.focused_title, allocator) catch {};
        } else {
            snap.focused_title.appendSlice(allocator, prev.focused_title.items) catch {};
        }
    }

    // Pre-fetch titles so the segmented-title draw path never issues its own
    // X11 calls. Only run when title state has changed. (Clock and carousel
    // ticks call drawClockOnly/drawTitleOnly directly and never reach this
    // function at all, so there's no separate "no-op" case to handle here.)
    const title_changed =
        snap.focused_window != prev.focused_window or
        snap.is_title_invalidated or
        !std.mem.eql(u32, snap.current_workspace_windows.items, prev.current_workspace_windows.items) or
        hasMinimizedSetChanged(&snap.minimized_windows, &prev.minimized_windows);
    if (title_changed) {
        snap.window_titles.clear(allocator);
        snap.window_geoms.clearRetainingCapacity();
        var title_tmp: std.ArrayListUnmanaged(u8) = .empty;
        defer title_tmp.deinit(allocator);
        for (snap.current_workspace_windows.items) |win| {
            if (snap.focused_window == win) {
                snap.window_titles.append(allocator, snap.focused_title.items) catch {};
            } else {
                title_tmp.clearRetainingCapacity();
                title.fetchWindowTitleInto(core.getState().conn, win, &title_tmp, allocator) catch {};
                snap.window_titles.append(allocator, title_tmp.items) catch {};
            }
            // Skip the round-trip for minimized windows the same way
            // drawSegmentedTitles' sentinel does — they're never actually
            // positioned on screen.
            const geom: utils.Rect = if (snap.minimized_windows.contains(win))
                .{ .x = std.math.maxInt(i16), .y = std.math.maxInt(i16), .width = 0, .height = 0 }
            else
                title.fetchWindowGeom(core.getState().conn, win);
            snap.window_geoms.append(allocator, geom) catch {};
        }
    } else {
        // Nothing about titles/membership/minimized-state changed since the
        // previous frame: rather than freeing every owned string in `snap`
        // and re-duping every owned string from `prev` — an O(window count)
        // alloc+free pass on every redraw where the titles themselves didn't
        // actually change (e.g. a plain workspace-indicator repaint) — swap
        // list ownership between the two snapshot slots instead.
        //
        // `prev` is not read again after this point in the current frame, and
        // on the *next* frame the roles of the two slots flip (today's `snap`
        // becomes tomorrow's `prev`), so ownership simply relays back and
        // forth between the two slots forever with zero allocation traffic,
        // until a frame where title_changed is true refreshes it for real.
        std.mem.swap(WindowTitles, &snap.window_titles, &prev.window_titles);
        std.mem.swap(std.ArrayListUnmanaged(utils.Rect), &snap.window_geoms, &prev.window_geoms);
    }

    snap.is_full_redraw = forced or (snap.workspace_count != prev.workspace_count);
    snap.is_workspace_dirty = snap.is_full_redraw or
        snap.current_workspace != prev.current_workspace or
        snap.is_all_view_active != prev.is_all_view_active or
        !std.mem.eql(bool, snap.workspace_has_windows.items, prev.workspace_has_windows.items);
    snap.is_title_dirty =
        prompt.isActive() or
        snap.focused_window != prev.focused_window or
        snap.is_title_invalidated or
        !std.mem.eql(u8, snap.focused_title.items, prev.focused_title.items) or
        !std.mem.eql(u32, snap.current_workspace_windows.items, prev.current_workspace_windows.items) or
        hasMinimizedSetChanged(&snap.minimized_windows, &prev.minimized_windows);
}

// Draw submission

/// Returns true on success, false if the bar is not visible or capture failed.
/// Captures into whichever snapshot slot is currently "current" (s.snap_idx),
/// diffing against the other slot ("previous").
fn prepareSnapshot(s: *State) bool {
    if (!s.is_visible) return false;
    const idx = s.snap_idx;
    const forced = gBar.pending_force_full_redraw;
    gBar.pending_force_full_redraw = false;
    captureStateIntoSlot(s, &s.snapshots[idx], &s.snapshots[1 - idx], forced) catch |e| {
        debug.warnOnErr(e, "bar captureStateIntoSlot");
        return false;
    };
    return true;
}

/// Captures a fresh snapshot and draws synchronously, holding draw_mutex for
/// the duration so the clock/carousel threads never paint at the same instant.
/// `flush` selects whether the result is blitted to the window immediately
/// (the normal event-loop path) or only rendered to the off-screen pixmap
/// (the xcb_grab_server-safe path — see redrawInsideGrab).
fn performDraw(flush: bool) void {
    const s = gBar.state orelse return;
    if (!prepareSnapshot(s)) return;
    draw_mutex.lock();
    defer draw_mutex.unlock();
    s.drawAll(&s.snapshots[s.snap_idx], flush) catch |e| debug.warnOnErr(e, "bar draw");
    s.snap_idx ^= 1;
}

fn submitDrawBlockingFull() void {
    gBar.pending_force_full_redraw = true;
    performDraw(true);
}

/// Invalidates the title carousel cache and triggers a full redraw.
/// Shared by setBarState and applyReload, which would otherwise each repeat
/// an (is_invalidated = true; submitDrawBlockingFull()) pair inline.
fn submitFullRedrawWithCarouselReset(s: *State) void {
    s.title_cache.is_invalidated = true;
    submitDrawBlockingFull();
}

inline fn ungrabAndFlush() void {
    utils.ungrabAndFlush(core.getState().conn);
}

/// Draws and blits to the window. Drawing always happens inline on the
/// calling thread, so this is identical to submitDraw.
pub fn submitDrawBlocking() void {
    performDraw(true);
}

/// Renders only — no xcb_copy_area, no xcb_flush.
/// Use INSIDE xcb_grab_server; pair with dc.blitQueued() + ungrabAndFlush().
fn submitRenderBlocking() void {
    performDraw(false);
}

pub fn submitDraw() void {
    performDraw(true);
}

// Window and atom setup

fn initAtoms() void {
    const entries = .{
        .{ "strut_partial", "_NET_WM_STRUT_PARTIAL" },
        .{ "window_type", "_NET_WM_WINDOW_TYPE" },
        .{ "window_type_dock", "_NET_WM_WINDOW_TYPE_DOCK" },
        .{ "wm_state", "_NET_WM_STATE" },
        .{ "state_above", "_NET_WM_STATE_ABOVE" },
        .{ "state_sticky", "_NET_WM_STATE_STICKY" },
        .{ "allowed_actions", "_NET_WM_ALLOWED_ACTIONS" },
        .{ "action_close", "_NET_WM_ACTION_CLOSE" },
        .{ "action_above", "_NET_WM_ACTION_ABOVE" },
        .{ "action_stick", "_NET_WM_ACTION_STICK" },
    };
    inline for (entries) |e|
        @field(gBar.atoms, e[0]) = utils.getAtomCached(e[1]) catch 0;
}

fn calcBarYPos(height: u16) i16 {
    const cs = core.getState();
    return if (cs.config.bar.bar_position == .bottom)
        @intCast(@as(i32, cs.screen.height_in_pixels) - height)
    else
        0;
}

const BarWindowSetup = struct { win_id: u32, visual_id: u32, has_argb: bool, colormap: u32 };

fn createBarWindow(height: u16, y_pos: i16) BarWindowSetup {
    const cs = core.getState();
    const want_transparency = cs.config.bar.getAlpha16() < 0xFFFF;
    const visual_info = if (want_transparency)
        drawing.findVisualByDepth(cs.screen, 32)
    else
        drawing.VisualInfo{ .visual_type = null, .visual_id = cs.screen.root_visual };
    const depth: u8 = if (want_transparency) 32 else xcb.XCB_COPY_FROM_PARENT;
    const visual_id = visual_info.visual_id;
    const colormap: u32 = if (want_transparency) blk: {
        const cmap = xcb.xcb_generate_id(cs.conn);
        _ = xcb.xcb_create_colormap(cs.conn, xcb.XCB_COLORMAP_ALLOC_NONE, cmap, cs.screen.root, visual_id);
        break :blk cmap;
    } else 0;
    const win_id = xcb.xcb_generate_id(cs.conn);
    const value_mask = xcb.XCB_CW_BACK_PIXEL | xcb.XCB_CW_BORDER_PIXEL |
        xcb.XCB_CW_OVERRIDE_REDIRECT | xcb.XCB_CW_EVENT_MASK |
        if (want_transparency) xcb.XCB_CW_COLORMAP else 0;
    const base_events = xcb.XCB_EVENT_MASK_EXPOSURE | xcb.XCB_EVENT_MASK_BUTTON_PRESS;
    const value_list = [5]u32{ 0, 0, 1, base_events, colormap };
    _ = xcb.xcb_create_window(cs.conn, depth, win_id, cs.screen.root, 0, y_pos, cs.screen.width_in_pixels, height, 0, xcb.XCB_WINDOW_CLASS_INPUT_OUTPUT, visual_id, @intCast(value_mask), &value_list);
    return .{ .win_id = win_id, .visual_id = visual_id, .has_argb = want_transparency, .colormap = colormap };
}

fn loadBarFonts(dc: anytype) !void {
    const cs = core.getState();
    const fonts = cs.config.bar.fonts.items;
    if (fonts.len == 0) return;
    const sized = try cs.alloc.alloc([]const u8, fonts.len);
    defer {
        for (sized, fonts) |s, orig| if (s.ptr != orig.ptr) cs.alloc.free(s);
        cs.alloc.free(sized);
    }
    for (fonts, sized) |f, *out| {
        out.* = if (cs.config.bar.scaled_font_size > 0)
            try std.fmt.allocPrint(cs.alloc, "{s}:size={}", .{ f, cs.config.bar.scaled_font_size })
        else
            f;
    }
    return dc.loadFonts(sized);
}

/// Set an EWMH atom property on the bar window.
fn setAtomProperty(conn: *xcb.xcb_connection_t, win_id: u32, prop: u32, atom_type: u32, values: anytype) void {
    _ = xcb.xcb_change_property(conn, xcb.XCB_PROP_MODE_REPLACE, win_id, prop, atom_type, 32, @intCast(values.len), values.ptr);
}

fn setWindowProperties(win_id: u32, height: u16) void {
    const cs = core.getState();
    // _NET_WM_STRUT_PARTIAL layout: index 2 = top strut, index 3 = bottom strut.
    const strut: [12]u32 = if (cs.config.bar.bar_position == .top)
        .{ 0, 0, height, 0, 0, 0, 0, 0, 0, cs.screen.width_in_pixels, 0, 0 }
    else
        .{ 0, 0, 0, height, 0, 0, 0, 0, 0, 0, 0, cs.screen.width_in_pixels };
    if (gBar.atoms.strut_partial != 0) setAtomProperty(cs.conn, win_id, gBar.atoms.strut_partial, xcb.XCB_ATOM_CARDINAL, &strut);
    if (gBar.atoms.window_type != 0) setAtomProperty(cs.conn, win_id, gBar.atoms.window_type, xcb.XCB_ATOM_ATOM, &[_]u32{gBar.atoms.window_type_dock});
    if (gBar.atoms.wm_state != 0) setAtomProperty(cs.conn, win_id, gBar.atoms.wm_state, xcb.XCB_ATOM_ATOM, &[_]u32{ gBar.atoms.state_above, gBar.atoms.state_sticky });
    if (gBar.atoms.allowed_actions != 0) setAtomProperty(cs.conn, win_id, gBar.atoms.allowed_actions, xcb.XCB_ATOM_ATOM, &[_]u32{ gBar.atoms.action_close, gBar.atoms.action_above, gBar.atoms.action_stick });
}

fn measureFontMetrics() ?struct { asc: i32, desc: i32 } {
    var mc = drawing.MeasureContext.init(core.getState().alloc, core.dpi_info.dpi) catch return null;
    defer mc.deinit();
    loadBarFonts(&mc) catch return null;
    const asc, const desc = mc.getMetrics();
    return .{ .asc = asc, .desc = desc };
}

fn resolvePercentageFontSize(bar_height: u16) ?u16 {
    const trialPt: u16 = 100;
    const cs = core.getState();
    const saved_size = cs.config.bar.scaled_font_size;
    cs.config.bar.scaled_font_size = trialPt;
    defer cs.config.bar.scaled_font_size = saved_size;
    const m = measureFontMetrics() orelse return null;
    const px_per_pt: f32 = @as(f32, @floatFromInt(@max(1, m.asc + m.desc))) / @as(f32, @floatFromInt(trialPt));
    const max_size_pt = @as(f32, @floatFromInt(bar_height)) / px_per_pt;
    return @max(1, @as(u16, @intFromFloat(@round(max_size_pt * (cs.config.bar.font_size.value / 100.0)))));
}

fn calcBarHeight() !u16 {
    const cs = core.getState();
    if (cs.config.bar.height) |h| {
        const height = scale.scaleBarHeight(h, cs.screen.height_in_pixels);
        if (cs.config.bar.font_size.is_percentage) {
            if (resolvePercentageFontSize(height)) |sz|
                cs.config.bar.scaled_font_size = sz;
        }
        return height;
    }
    const m = measureFontMetrics() orelse return DEFAULT_BAR_HEIGHT;
    return @intCast(std.math.clamp(@as(u32, @intCast(m.asc + m.desc)), MIN_BAR_HEIGHT, MAX_BAR_HEIGHT));
}

fn createDrawContext(setup: BarWindowSetup, height: u16) !*drawing.DrawContext {
    const cs = core.getState();
    const dc = try drawing.DrawContext.initWithVisual(
        cs.alloc,
        cs.conn,
        setup.win_id,
        cs.screen.width_in_pixels,
        height,
        setup.visual_id,
        core.dpi_info.dpi,
        setup.has_argb,
        cs.config.bar.transparency,
    );
    errdefer dc.deinit();
    try loadBarFonts(dc);
    return dc;
}

// Lifecycle

pub fn init() !void {
    const cs = core.getState();
    std.debug.assert(cs.config.bar.enabled);
    initAtoms();
    // Detect refresh rate before the carousel thread spawns so
    // carousel.wakeIntervalNs() returns the real rate from the first tick.
    scale.ensureRefreshRateDetected(cs.conn);
    const height = try calcBarHeight();
    const y_pos = calcBarYPos(height);
    const setup = createBarWindow(height, y_pos);
    errdefer {
        _ = xcb.xcb_destroy_window(cs.conn, setup.win_id);
        if (setup.colormap != 0) _ = xcb.xcb_free_colormap(cs.conn, setup.colormap);
    }
    setWindowProperties(setup.win_id, height);
    const dc = try createDrawContext(setup, height);
    errdefer dc.deinit();
    debug.info("Bar transparency: {s}", .{if (setup.has_argb) "enabled (ARGB)" else "disabled (opaque)"});
    gBar.state = try State.init(cs.alloc, cs.conn, setup.win_id, setup.colormap, cs.screen.width_in_pixels, height, dc, cs.config.bar);
    carousel.startThread();
    clock.startThread();
    submitDrawBlocking();
    _ = xcb.xcb_map_window(cs.conn, setup.win_id);
    _ = xcb.xcb_flush(cs.conn);
    try prompt.init(cs.alloc, cs.conn);
}

pub fn deinit() void {
    prompt.deinit();
    clock.stopThread();
    carousel.stopThread();
    if (gBar.state) |s| {
        carousel.deinitCarousel();
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
    const height = calcBarHeight() catch DEFAULT_BAR_HEIGHT;
    const y_pos = calcBarYPos(height);
    const setup = createBarWindow(height, y_pos);
    applyReload(old, setup, height) catch |err| {
        const conn = core.getState().conn;
        _ = xcb.xcb_destroy_window(conn, setup.win_id);
        if (setup.colormap != 0) _ = xcb.xcb_free_colormap(conn, setup.colormap);
        debug.err("Bar reload failed ({s}), keeping old bar", .{@errorName(err)});
    };
}

fn applyReload(old: *State, setup: BarWindowSetup, height: u16) !void {
    setWindowProperties(setup.win_id, height);
    const new_dc = try createDrawContext(setup, height);
    errdefer new_dc.deinit();
    const cs = core.getState();
    const new_state = try State.init(cs.alloc, cs.conn, setup.win_id, setup.colormap, cs.screen.width_in_pixels, height, new_dc, cs.config.bar);
    new_state.is_visible = old.is_visible;
    new_state.is_globally_visible = old.is_globally_visible;
    clock.stopThread();
    carousel.stopThread();
    gBar.state = new_state;
    carousel.startThread();
    clock.startThread();
    submitDrawBlockingFull();
    if (new_state.is_visible) _ = xcb.xcb_map_window(cs.conn, setup.win_id);
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
    const new_y = calcBarYPos(s.render.height);
    setWindowProperties(s.win.win_id, s.render.height);
    gBar.pending_force_full_redraw = true;
    s.invalidateLayoutCache();
    _ = xcb.xcb_grab_server(cs.conn);
    _ = xcb.xcb_configure_window(cs.conn, s.win.win_id, xcb.XCB_CONFIG_WINDOW_Y, &[_]u32{@as(u32, @bitCast(@as(i32, new_y)))});
    const current_ws = tracking.getCurrentWorkspace() orelse {
        window.updateWorkspaceBorders();
        window.markBordersFlushed();
        ungrabAndFlush();
        return;
    };
    const no_fullscreen = fullscreen.getForWorkspace(current_ws) == null;
    if (no_fullscreen)
        tiling.retileCurrentWorkspace();
    window.updateFloatingWindowBorders();
    window.markBordersFlushed();
    ungrabAndFlush();
    debug.info("Bar position toggled to: {s}", .{@tagName(cs.config.bar.bar_position)});
}

/// Lightweight focus-only redraw; skipped when a full redraw is already pending.
pub fn scheduleFocusRedraw(new_win: ?u32) void {
    const s = gBar.state orelse return;
    if (!s.is_visible or s.is_dirty) return;
    draw_mutex.lock();
    s.drawTitleOnly(new_win);
    draw_mutex.unlock();
    // markDirty ensures a full redraw follows, which fetches the new window's title
    // and rebuilds the carousel correctly. Without it, a cross-window focus change with
    // no other dirty state would rely solely on the stale-title drawTitleOnly path —
    // the combination that triggers the double-start flicker drawTitleOnly guards against.
    s.markDirty();
}

pub fn isBarWindow(win: u32) bool {
    return if (gBar.state) |s| s.win.win_id == win else false;
}
pub fn getBarHeight() u16 {
    return if (gBar.state) |s| s.render.height else 0;
}
pub fn hasClockSegment() bool {
    return if (gBar.state) |s| s.has_clock_segment else false;
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

pub fn isVisible() bool {
    return if (gBar.state) |s| s.is_visible else false;
}

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

/// Pre-render phase for a fullscreen exit: captures bar state (may issue X
/// round-trips for title fetches) and renders to the off-screen pixmap.
///
/// Call BEFORE xcb_grab_server.  captureStateIntoSlot's round-trips trigger an
/// implicit XCB flush; if xcb_grab_server were already queued, that flush would
/// deliver it early — holding the grab for the entire Cairo render and allowing
/// the compositor to miss a vsync.  By calling this before the grab the send
/// buffer is empty when the flush fires, matching the pattern the toggle path
/// already uses.
///
/// Sets is_visible = true so that prepareSnapshot() does not short-circuit.
/// Pair with commitShowInsideGrab() inside the grab.
pub fn prerenderForShow() void {
    const s = gBar.state orelse return;
    s.is_visible = true;
    s.title_cache.is_invalidated = true; // force carousel reset from pos 0 on re-show
    gBar.pending_force_full_redraw = true;
    // Render to pixmap; round-trips in captureStateIntoSlot fire here on an
    // empty send buffer, not inside a grab.
    submitRenderBlocking();
}

/// Commit phase for a fullscreen show: queues xcb_copy_area and maps the bar
/// window atomically with the caller's ungrabAndFlush().
///
/// Call INSIDE xcb_grab_server, after prerenderForShow().  Caller is responsible
/// for retile and ungrabAndFlush().
pub fn commitShowInsideGrab() void {
    const s = gBar.state orelse return;
    s.render.dc.blitQueued();
    _ = xcb.xcb_map_window(core.getState().conn, s.win.win_id);
    s.is_dirty = false;
    debug.info("Bar shown (show_fullscreen)", .{});
}

pub fn raiseBar() void {
    if (gBar.state) |s|
        _ = xcb.xcb_configure_window(s.win.conn, s.win.win_id, xcb.XCB_CONFIG_WINDOW_STACK_MODE, &[_]u32{xcb.XCB_STACK_MODE_ABOVE});
}

pub fn setBarState(action: BarAction) void {
    const s = gBar.state orelse return;
    if (action == .toggle) s.is_globally_visible = !s.is_globally_visible;
    const current_ws = tracking.getCurrentWorkspace() orelse 0;
    const is_fullscreen = action != .hide_fullscreen and
        fullscreen.getForWorkspace(current_ws) != null;
    const show = !is_fullscreen and s.is_globally_visible and action != .hide_fullscreen;
    if (s.is_visible == show and action != .toggle) return;
    s.is_visible = show;
    if (action == .toggle) {
        if (show) submitFullRedrawWithCarouselReset(s);
        const conn = core.getState().conn;
        _ = xcb.xcb_grab_server(conn);
        if (show) _ = xcb.xcb_map_window(conn, s.win.win_id) else _ = xcb.xcb_unmap_window(conn, s.win.win_id);
        const effective_visible = if (is_fullscreen) s.is_globally_visible else s.is_visible;
        retileAllWorkspaces(effective_visible);
        window.updateFloatingWindowBorders();
        window.markBordersFlushed();
        ungrabAndFlush();
    } else {
        if (show) {
            submitFullRedrawWithCarouselReset(s);
            _ = xcb.xcb_map_window(core.getState().conn, s.win.win_id);
        } else {
            _ = xcb.xcb_unmap_window(core.getState().conn, s.win.win_id);
        }
        tiling.retileCurrentWorkspace();
    }
    debug.info("Bar {s} ({s})", .{ if (show) "shown" else "hidden", @tagName(action) });
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

/// Called from the dedicated clock thread (clock.zig) once per real-time
/// second boundary. Draws just the clock segment; draw_mutex keeps this safe
/// against a same-instant redraw from the main WM thread or the carousel thread.
pub fn checkClockUpdate() bool {
    const s = gBar.state orelse return false;
    if (!s.is_visible) return false;
    draw_mutex.lock();
    s.drawClockOnly();
    draw_mutex.unlock();
    return true;
}

/// Called from the dedicated carousel thread (carousel.zig) roughly once per
/// display refresh while a title is actively scrolling. Advances and redraws
/// just the title segment; draw_mutex keeps this safe against a same-instant
/// redraw from the main WM thread or the clock thread.
pub fn tickCarousel() void {
    const s = gBar.state orelse return;
    if (!s.is_visible) return;
    draw_mutex.lock();
    s.drawTitleOnly(s.title_cache.focused_window);
    draw_mutex.unlock();
}

pub fn handleExpose(event: *const xcb.xcb_expose_event_t) void {
    if (gBar.state) |s| if (event.window == s.win.win_id and event.count == 0) {
        gBar.pending_force_full_redraw = true;
        if (drag.isDragging()) s.is_dirty = true else submitDraw();
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

pub fn handleButtonPress(event: *const xcb.xcb_button_press_event_t) void {
    const s = gBar.state orelse return;
    if (event.event != s.win.win_id) return;
    if (!core.getState().config.workspaces.enabled) return;
    const ws_state = workspaces.getState() orelse return;
    const ws_w = tags.getCachedWorkspaceWidth();
    if (ws_w == 0) return;
    const click_x = @max(0, event.event_x - s.layout_cache.workspace_x);
    const clicked_ws: usize = @intCast(@divFloor(click_x, ws_w));
    if (clicked_ws >= ws_state.workspaces.len) return;
    switchToWorkspace(clicked_ws);
    s.markDirty();
}

inline fn switchToWorkspace(ws_arg: usize) void {
    workspaces.switchTo(ws_arg);
}

fn isTilingActive() bool {
    return core.getState().config.tiling.enabled and
        if (tiling.getStateOpt()) |t| t.is_enabled else false;
}

/// Must be called without holding the X server grab.
/// `effective_visible` is the bar-visibility value that tilers should observe;
/// it may differ from `s.is_visible` when a fullscreen override is in effect.
fn retileAllWorkspaces(effective_visible: bool) void {
    // Temporarily expose the effective visibility so tiling code that reads
    // isVisible() sees the intended value rather than the transitional state.
    //
    // NOTE: the save/restore is scoped to the whole function, not to this
    // `if` block — a `defer` written inside `if (gBar.state) |st| { ... }`
    // would fire as soon as that block ends (i.e. immediately, before any
    // retiling below runs), which would silently defeat this override.
    const st_opt = gBar.state;
    const saved_visible = if (st_opt) |st| st.is_visible else false;
    if (st_opt) |st| st.is_visible = effective_visible;
    defer if (st_opt) |st| {
        st.is_visible = saved_visible;
    };
    if (!core.getState().config.workspaces.enabled) {
        tiling.retileCurrentWorkspace();
        return;
    }
    const ws_state = workspaces.getState() orelse return;
    if (!isTilingActive()) { tiling.retileCurrentWorkspace(); return; }
    for (ws_state.workspaces, 0..) |_, idx| {
        if (!tracking.hasWindowsOnWorkspace(@intCast(idx))) continue;
        if (fullscreen.getForWorkspace(@intCast(idx)) != null) continue;
        if (@as(u8, @intCast(idx)) != ws_state.current)
            tiling.retileInactiveWorkspace(@intCast(idx))
        else
            tiling.retileCurrentWorkspace();
    }
}
