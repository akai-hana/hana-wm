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

const MIN_BAR_HEIGHT: u32 = scale.BAR_MIN_HEIGHT_PX;
const MAX_BAR_HEIGHT: u32 = 200;
const DEFAULT_BAR_HEIGHT: u32 = 24;
const FALLBACK_WORKSPACES_WIDTH: u16 = 270;
const LAYOUT_WIDTH: u16 = 60;
const TITLE_MIN_WIDTH: u16 = 100;

// Core data structures

/// List of per-window title strings, each individually heap-allocated.
///
/// Filled once per redraw (one dupe per window, in workspace order) and read
/// back by index with no offset arithmetic.
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

/// Serializes access to the shared Cairo/XCB DrawContext. Bar drawing runs on
/// the main WM thread, except for one small dedicated timer that runs on its
/// own thread: carousel.zig (ticks once per display refresh while a title is
/// actively scrolling) — and even that thread only ever performs the Pango-free
/// carousel-pixmap blit, never a full Pango layout. The clock thread no longer
/// touches the DrawContext at all: it formats the time string and flags the
/// main thread to redraw. This mutex keeps the carousel thread from painting
/// into the DrawContext at the same instant as the main WM thread, and Pango/
/// fontconfig work is confined to the main thread so no bar thread can block
/// the shutdown path inside a fontconfig lookup.
pub var draw_mutex: utils.Mutex = .{};

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
    /// Title geometry captured by drawAllInner; consumed by drawAll
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
        const r = &self.render;
        return switch (segment) {
            .workspaces => try tags.draw(r.dc, r.config, r.height, x, snap.current_workspace, snap.workspace_has_windows.items, snap.is_all_view_active),
            .layout => try layout.draw(r.dc, r.config, r.height, x),
            .variants => try variants.draw(r.dc, r.config, r.height, x),
            .title => prompt.draw(
                .{
                    .dc = r.dc,
                    .config = r.config,
                    .height = r.height,
                    .start_x = x,
                    .width = width orelse TITLE_MIN_WIDTH,
                    .conn = self.win.conn,
                    .cached_title = &self.title_cache.title,
                    .cached_title_window = &self.title_cache.title_window,
                },
                .{
                    .focused_window = snap.focused_window,
                    .focused_title = snap.focused_title.items,
                    .minimized_title = minimizedTitleFor(
                        snap.current_workspace_windows.items,
                        &snap.minimized_windows,
                        snap.window_titles.list.items,
                    ),
                    .current_ws_wins = snap.current_workspace_windows.items,
                    .minimized_set = &snap.minimized_windows,
                    .titles = snap.window_titles.list.items,
                    .geoms = snap.window_geoms.items,
                },
                r.allocator,
                snap.is_title_invalidated,
            ),
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

    /// Draws one segment of a left-to-right row, painting the inter-segment gap
    /// and advancing `x`. `w` is the reserved width (used when the segment is
    /// skipped, and as the title width); `omit_gap_after_title` suppresses the
    /// gap after a title segment so the next segment sits flush against it (the
    /// center layout). Returns the new `x`.
    fn drawRowSegment(
        self: *State,
        snap: *const BarSnapshot,
        seg: types.BarSegment,
        x: u16,
        w: u16,
        omit_gap_after_title: bool,
        scaled_spacing: u16,
    ) u16 {
        const omit_gap = omit_gap_after_title and seg == .title;
        if (shouldSkipSegment(snap, seg)) return x + w + @as(u16, @intFromBool(!omit_gap)) * scaled_spacing;

        const x_before = x;
        const drawn_x = self.drawSegmentSafe(snap, seg, x, w);
        if (!omit_gap and drawn_x != x_before) {
            self.render.dc.fillRect(drawn_x, 0, scaled_spacing, self.render.height, self.render.config.bg);
            return drawn_x + scaled_spacing;
        }
        return drawn_x;
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

    /// Core drawing logic shared by the flush and grab-safe draw paths; does not flush.
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
                    const w = self.measureSegmentWidth(snap, seg);
                    if (seg == .title) {
                        title_seg_x = x;
                        title_seg_w = w;
                    }
                    x = self.drawRowSegment(snap, seg, x, w, false, scaled_spacing);
                },
                .center => {
                    const remaining = @max(TITLE_MIN_WIDTH, self.render.width -| x -| right_total -| scaled_spacing);
                    for (lay.segments.items) |seg| {
                        const w = if (seg == .title) remaining else self.measureSegmentWidth(snap, seg);
                        if (seg == .title) {
                            title_seg_x = x;
                            title_seg_w = w;
                        }
                        x = self.drawRowSegment(snap, seg, x, w, true, scaled_spacing);
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
        if (self.drawTitleBlitOnly()) return;

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
                .minimized_title = minimizedTitleFor(
                    self.title_cache.workspace_windows.items,
                    &self.title_cache.minimized_windows,
                    self.title_cache.window_titles.list.items,
                ),
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

    /// Pango-free title fast path shared by the main-thread drawTitleOnly and
    /// the dedicated carousel thread. Blits the live carousel pixmap when
    /// possible and returns true. Returns false (drawing nothing) when a
    /// rebuild/colour/focus change is pending — those are handled by the main
    /// thread's full-redraw machinery, never by falling through to a Pango
    /// layout from the carousel thread.
    fn drawTitleBlitOnly(self: *State) bool {
        if (!carousel.isCarouselActive()) return false;
        const win_count = self.title_cache.workspace_windows.items.len;
        if (win_count > 1) {
            // Segmented mode: blit the focused segment directly from render.seg.
            // drawSegCarouselTickAuto reads seg_x/seg_w from the stored entry, so no
            // separate coordinate cache is needed here.
            return carousel.drawSegCarouselTickAuto(self.render.dc, self.render.config.title_accent_color);
        }
        // Single-window mode: pass accent so the tick detects a bg change
        // (minimize/unminimize) and returns false to force a full rebuild.
        const accent: u32 = if (win_count == 1 and
            self.title_cache.minimized_windows.contains(self.title_cache.workspace_windows.items[0]))
            self.render.config.title_minimized_accent
        else
            self.render.config.title_accent_color;
        return carousel.drawCarouselTick(self.render.dc, accent, self.title_cache.title_x, self.title_cache.title_width);
    }

    /// Replacements are built before the swap so a failed allocation leaves the cache
    /// showing stale data rather than going silently empty.
    fn syncTitleCache(self: *State, snap: *const BarSnapshot, x: u16, w: u16) void {
        const alloc = self.render.allocator;

        swapAlloc(u32, &self.title_cache.workspace_windows, alloc, snap.current_workspace_windows.items);

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
        swapAlloc(utils.Rect, &self.title_cache.window_geoms, alloc, snap.window_geoms.items);

        self.title_cache.focused_window = snap.focused_window;
        self.title_cache.title_x = x;
        self.title_cache.title_width = w;
        self.title_cache.is_layout_valid = true;
    }
};

// Snapshot capture

/// Builds a replacement list and swaps it into `dst` only on success, so a
/// failed allocation leaves the cache showing stale data rather than empty.
fn swapAlloc(comptime T: type, dst: *std.ArrayListUnmanaged(T), alloc: std.mem.Allocator, src: []const T) void {
    var replacement: std.ArrayListUnmanaged(T) = .empty;
    if (replacement.appendSlice(alloc, src)) {
        dst.deinit(alloc);
        dst.* = replacement;
    } else |_| {
        replacement.deinit(alloc);
    }
}

/// Title of the minimized window, used in the single-window title case.
/// Returns "" when no window is minimized or titles were not fetched.
fn minimizedTitleFor(wins: []const u32, minimized: *const std.AutoHashMapUnmanaged(u32, void), titles: []const []const u8) []const u8 {
    return if (wins.len > 0 and minimized.contains(wins[0]) and titles.len > 0) titles[0] else "";
}

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
                title.offscreen_rect
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
/// calling thread.
pub fn submitDraw() void {
    performDraw(true);
}

/// Renders only — no xcb_copy_area, no xcb_flush.
/// Use INSIDE xcb_grab_server; pair with dc.blitQueued() + ungrabAndFlush().
fn submitRenderBlocking() void {
    performDraw(false);
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

/// Everything a fully-initialised bar owns; returned by createBar.
const BarSetup = struct {
    setup: BarWindowSetup,
    dc: *drawing.DrawContext,
    state: *State,
};

/// Creates the bar window, off-screen draw context, and live State.
/// On any failure, everything already created is freed before returning.
fn createBar(height: u16, y_pos: i16) !BarSetup {
    const cs = core.getState();
    const setup = createBarWindow(height, y_pos);
    errdefer destroyBarWindow(cs.conn, setup.win_id, setup.colormap);
    setWindowProperties(setup.win_id, height);
    const dc = try createDrawContext(setup, height);
    errdefer dc.deinit();
    debug.info("Bar transparency: {s}", .{if (setup.has_argb) "enabled (ARGB)" else "disabled (opaque)"});
    const state = try State.init(cs.alloc, cs.conn, setup.win_id, setup.colormap, cs.screen.width_in_pixels, height, dc, cs.config.bar);
    return .{ .setup = setup, .dc = dc, .state = state };
}

fn createBarWindow(height: u16, y_pos: i16) BarWindowSetup {
    const cs = core.getState();
    const want_transparency = cs.config.bar.getAlpha16() < 0xFFFF;
    const visual_info = if (want_transparency)
        drawing.findVisualByDepth(cs.screen, 32)
    else
        drawing.VisualInfo{ .visual_id = cs.screen.root_visual };
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
    const entries = .{
        .{ "strut_partial", xcb.XCB_ATOM_CARDINAL, &strut },
        .{ "window_type", xcb.XCB_ATOM_ATOM, &[_]u32{gBar.atoms.window_type_dock} },
        .{ "wm_state", xcb.XCB_ATOM_ATOM, &[_]u32{ gBar.atoms.state_above, gBar.atoms.state_sticky } },
        .{ "allowed_actions", xcb.XCB_ATOM_ATOM, &[_]u32{ gBar.atoms.action_close, gBar.atoms.action_above, gBar.atoms.action_stick } },
    };
    inline for (entries) |e| {
        const atom = @field(gBar.atoms, e[0]);
        if (atom != 0) setAtomProperty(cs.conn, win_id, atom, e[1], e[2]);
    }
}

fn destroyBarWindow(conn: *xcb.xcb_connection_t, win_id: u32, colormap: u32) void {
    _ = xcb.xcb_destroy_window(conn, win_id);
    if (colormap != 0) _ = xcb.xcb_free_colormap(conn, colormap);
}

fn measureFontMetrics() ?struct { asc: i32, desc: i32 } {
    var mc = drawing.MeasureContext.init(core.getState().alloc, core.dpi_info) catch return null;
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
        core.dpi_info,
        setup.has_argb,
        cs.config.bar.transparency,
    );
    errdefer dc.deinit();
    try loadBarFonts(dc);
    return dc;
}

// Lifecycle

fn startBarThreads() void {
    const cs = core.getState();
    carousel.startThread();
    clock.startThread(cs.alloc, cs.config.bar.clock_format);
}

fn stopBarThreads() void {
    const cs = core.getState();
    clock.stopThread(cs.alloc);
    carousel.stopThread();
}

pub fn init() !void {
    const cs = core.getState();
    std.debug.assert(cs.config.bar.enabled);
    initAtoms();
    // Detect refresh rate before the carousel thread spawns so
    // carousel.wakeIntervalNs() returns the real rate from the first tick.
    scale.ensureRefreshRateDetected(cs.conn);
    const height = try calcBarHeight();
    const bar = try createBar(height, calcBarYPos(height));
    gBar.state = bar.state;
    startBarThreads();
    submitDraw();
    _ = xcb.xcb_map_window(cs.conn, bar.setup.win_id);
    _ = xcb.xcb_flush(cs.conn);
    try prompt.init(cs.alloc, cs.conn);
}

pub fn deinit() void {
    prompt.deinit();
    stopBarThreads();
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
    applyReload(old, height) catch |err| {
        debug.err("Bar reload failed ({s}), keeping old bar", .{@errorName(err)});
    };
}

fn applyReload(old: *State, height: u16) !void {
    const cs = core.getState();
    const new_bar = createBar(height, calcBarYPos(height)) catch |err| {
        // The caller (handleConfigReload) has already swapped cs.config to the
        // new config and frees the OLD config when this returns. The old bar
        // survives this failed reload, but its render.config is a shallow copy
        // of the old config's BarConfig (borrowed string/list slices) — so
        // re-point it at the live new config now, before old_config.deinit()
        // runs, or the next bar draw reads freed memory.
        old.render.config = cs.config.bar;
        return err;
    };
    const new_state = new_bar.state;
    new_state.is_visible = old.is_visible;
    new_state.is_globally_visible = old.is_globally_visible;
    stopBarThreads();
    gBar.state = new_state;
    startBarThreads();
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
    const new_y = calcBarYPos(s.render.height);
    setWindowProperties(s.win.win_id, s.render.height);
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
    if (show) submitFullRedrawWithCarouselReset(s);

    const conn = core.getState().conn;
    const grabbed = action == .toggle;
    if (grabbed) utils.grabServer(conn);
    if (show) _ = xcb.xcb_map_window(conn, s.win.win_id) else _ = xcb.xcb_unmap_window(conn, s.win.win_id);
    if (grabbed) {
        const effective_visible = if (is_fullscreen) s.is_globally_visible else s.is_visible;
        retileAllWorkspaces(effective_visible);
        window.updateFloatingWindowBorders();
        window.markBordersFlushed();
        ungrabAndFlush();
    } else {
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

/// Drains the clock thread's redraw request on the main WM thread. Draws just
/// the clock segment — Pango runs here, never on the clock thread. Returns
/// true when a redraw was actually performed. Cheap to call on every event
/// batch: it no-ops unless the clock thread published a new second.
pub fn updateClock() bool {
    const s = gBar.state orelse return false;
    if (!s.is_visible) return false;
    if (!clock.consumeClockDirty()) return false;
    draw_mutex.lock();
    defer draw_mutex.unlock();
    s.drawClockOnly();
    return true;
}

/// Called from the dedicated carousel thread (carousel.zig) roughly once per
/// display refresh while a title is actively scrolling. Blits the live
/// carousel pixmap if possible; draw_mutex keeps this safe against a
/// same-instant redraw from the main WM thread.
///
/// Never runs Pango: when the fast-path blit reports a pending rebuild/colour/
/// focus change, this draws nothing and lets the main thread's redraw
/// machinery (focus change, minimize/unminimize, bar resize) repaint the
/// title. Pango and fontconfig therefore never run off the main thread, which
/// removes the SIGTERM deadlock class where a bar thread held draw_mutex while
/// blocked inside a fontconfig lookup.
pub fn tickCarousel() void {
    const s = gBar.state orelse return;
    if (!s.is_visible) return;
    if (prompt.isActive()) return;
    if (!s.title_cache.is_layout_valid or s.title_cache.title_width == 0) return;
    // Skip the tick while the main WM thread holds the X server grab. This
    // thread's blit flushes the shared output buffer, which would release the
    // grab-batch requests mid-grab and split what must be one atomic frame —
    // and grabbing draw_mutex here could stall the main thread's
    // scheduleFocusRedraw inside its own grab. The grab window is
    // microseconds; skipping a scroll tick is imperceptible.
    if (utils.isGrabActive()) return;
    draw_mutex.lock();
    defer draw_mutex.unlock();
    _ = s.drawTitleBlitOnly();
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
    if (!isTilingActive()) {
        tiling.retileCurrentWorkspace();
        return;
    }
    for (ws_state.workspaces, 0..) |_, idx| {
        if (!tracking.hasWindowsOnWorkspace(@intCast(idx))) continue;
        if (fullscreen.getForWorkspace(@intCast(idx)) != null) continue;
        if (@as(u8, @intCast(idx)) != ws_state.current)
            tiling.retileInactiveWorkspace(@intCast(idx))
        else
            tiling.retileCurrentWorkspace();
    }
}
