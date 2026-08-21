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
const fullscreen = @import("fullscreen");
const minimize = @import("minimize");
const workspaces = @import("workspaces");

const hooks = @import("hooks");
const window = @import("window");

const drawing = @import("drawing");
const prompt = @import("prompt");

const clock = @import("clock");
const layout = @import("layout");
const title = @import("title");
const variants = @import("variants");
const tags = @import("tags");

const build_options = @import("build_options");
const tiling = if (build_options.has_tiling) @import("tiling") else null;
const floating = if (build_options.has_floating) @import("floating") else null;

pub const plugin = hooks.Plugin{
    .init = init,
    .deinit = deinit,
    .reload = reload,
    .on_expose = handleExpose,
    .on_property_notify = handlePropertyNotify,
    .on_button_press = handleButtonPress,
    .post_batch = updateIfDirty,
    .iteration_end = updateClock,
    .poll_timeout_ms = promptBlinkPollTimeoutMs,
    .on_poll_wakeup = onPollWakeup,
};

fn onPollWakeup() void {
    submitDraw();
    prompt.blinkTick();
}

pub fn promptBlinkPollTimeoutMs() i32 {
    return prompt.blinkPollTimeoutMs();
}

pub fn promptHandleKeypress(event: *const xcb.xcb_key_press_event_t, matched: ?*const types.Action) bool {
    return prompt.handlePromptKeypress(event, matched);
}

pub fn promptToggle() void {
    prompt.toggle();
}

pub fn carouselSetEnabled(_: bool) void {}
pub fn carouselSetScrollSpeed(_: f64) void {}
pub fn carouselSetRefreshRateOverride(_: f64) void {}
pub fn carouselNotifyFocusChanged(_: ?u32) void {}

pub const Action = enum { toggle, hide_fullscreen, show_fullscreen };

const min_bar_height: u32 = scale.bar_min_height_px;
const max_bar_height: u32 = 200;
const default_bar_height: u32 = 24;
const fallback_workspaces_width: u16 = 270;
const layout_width: u16 = 60;
const title_min_width: u16 = 100;

/// Per-window title strings backed by a per-slot arena: every string in
/// `list` is a slice into `arena`'s memory, so clearing/dropping a list is
/// one arena reset, and duping a batch bumps a pointer into owned pages
/// instead of hitting the system allocator per window. `list`'s own buffer
/// lives on the caller's allocator, separate from the arena so `clear` can
/// reset the arena without invalidating the retained buffer.
const WindowTitles = struct {
    arena: std.heap.ArenaAllocator = undefined,
    list: std.ArrayListUnmanaged([]const u8) = .empty,

    fn init(backing: std.mem.Allocator) WindowTitles {
        return .{ .arena = std.heap.ArenaAllocator.init(backing) };
    }

    /// Allocator for title-string storage; bump-allocated and reclaimed by
    /// the next `clear`/`deinit`.
    pub fn allocator(self: *WindowTitles) std.mem.Allocator {
        return self.arena.allocator();
    }

    /// Empties the list and reclaims all title-string memory (capacity is
    /// retained for reuse by the next capture).
    pub fn clear(self: *WindowTitles) void {
        _ = self.arena.reset(.retain_capacity);
        self.list.clearRetainingCapacity();
    }

    /// Appends an owned dupe of `title_str`, allocated from the arena.
    pub fn append(self: *WindowTitles, list_allocator: std.mem.Allocator, title_str: []const u8) !void {
        const owned = try self.arena.allocator().dupe(u8, title_str);
        try self.list.append(list_allocator, owned);
    }

    /// Clears the list, then refills it with dupes of `titles`.
    /// Partial failures leave the list shorter than `titles` rather than erroring out.
    pub fn replaceWith(self: *WindowTitles, list_allocator: std.mem.Allocator, titles: []const []const u8) void {
        self.clear();
        for (titles) |t| self.append(list_allocator, t) catch break;
    }

    pub fn deinit(self: *WindowTitles, list_allocator: std.mem.Allocator) void {
        self.list.deinit(list_allocator);
        self.arena.deinit();
    }
};

/// Shared per-window title data embedded by both `BarSnapshot` and
/// `TitleCache` to avoid duplicating fields and deinit logic.
const TitleData = struct {
    focused_window: ?u32 = null,
    focused_title: std.ArrayListUnmanaged(u8) = .empty,
    workspace_windows: std.ArrayListUnmanaged(u32) = .empty,
    minimized_windows: std.AutoHashMapUnmanaged(u32, void) = .{},
    window_titles: WindowTitles = .{},
    window_geoms: std.ArrayListUnmanaged(utils.Rect) = .empty,

    fn deinit(self: *TitleData, allocator: std.mem.Allocator) void {
        self.focused_title.deinit(allocator);
        self.workspace_windows.deinit(allocator);
        self.minimized_windows.deinit(allocator);
        self.window_titles.deinit(allocator);
        self.window_geoms.deinit(allocator);
    }
};

/// Point-in-time bar state, captured fresh before each draw and diffed
/// against the previous frame's snapshot (see captureStateIntoSlot) to
/// decide which segments actually need repainting.
const BarSnapshot = struct {
    title_data: TitleData = .{},
    workspace_has_windows: std.ArrayListUnmanaged(bool) = .empty,
    current_workspace: u8 = 0,
    workspace_count: u32 = 0,
    is_all_view_active: bool = false,
    is_title_invalidated: bool = false,
    is_full_redraw: bool = true, // workspace_count changed or full-redraw forced
    is_workspace_dirty: bool = true, // workspace state changed
    is_title_dirty: bool = true, // title / focus / minimized state changed

    /// True when `window_titles`/`window_geoms` were freshly re-fetched this
    /// frame rather than relayed from the previous snapshot slot. syncTitleCache
    /// uses this to skip re-duping the cache's title strings when nothing changed
    /// : see the ownership-relay comment in captureStateIntoSlot.
    title_list_refreshed: bool = false,

    fn deinit(snap: *BarSnapshot, allocator: std.mem.Allocator) void {
        snap.title_data.deinit(allocator);
        snap.workspace_has_windows.deinit(allocator);
    }
};

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

/// Focus/title/workspace rendering cache; updated after each full draw.
const TitleCache = struct {
    title_data: TitleData = .{},
    title_window: ?u32 = null,
    title_x: u16 = 0,
    title_width: u16 = 0,
    is_layout_valid: bool = false,
    is_invalidated: bool = false,

    fn deinit(self: *TitleCache, allocator: std.mem.Allocator) void {
        self.title_data.deinit(allocator);
    }
};

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
                .clock_width = dc.measureTextWidth(clock.clock_measure_string) + 2 * config.scaledSegmentPadding(height),
            },
        };
        for (&s.snapshots) |*snap| snap.title_data.window_titles = WindowTitles.init(allocator);
        s.title_cache.title_data.window_titles = WindowTitles.init(allocator);
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
        const b = switch (seg) {
            .workspaces => &self.layout_cache.workspaces_bounds,
            .layout => &self.layout_cache.layout_bounds,
            .variants => &self.layout_cache.variants_bounds,
            .title, .clock => return,
        };
        b.x = x;
        b.w = w;
        b.has = true;
    }

    fn measureSegmentWidth(self: *State, snap: *const BarSnapshot, segment: types.BarSegment) u16 {
        return switch (segment) {
            .workspaces => if (snap.workspace_count > 0)
                @intCast(snap.workspace_count * tags.getCachedWorkspaceWidth())
            else
                fallback_workspaces_width,
            .layout, .variants => layout_width,
            .title => title_min_width,
            .clock => self.layout_cache.clock_width,
        };
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

    fn drawSegment(self: *State, snap: *const BarSnapshot, segment: types.BarSegment, x: u16, width: ?u16) !u16 {
        const r = &self.render;
        return switch (segment) {
            .workspaces => try tags.draw(r.dc, r.config, r.height, x, snap.current_workspace, snap.workspace_has_windows.items, snap.is_all_view_active),
            .layout => try layout.draw(r.dc, r.config, r.height, x),
            .variants => try variants.draw(r.dc, r.config, r.height, x),
            .title => prompt.draw(
                self.titleCtx(x, width orelse title_min_width, &self.title_cache.title_data.focused_title, &self.title_cache.title_window),
                makeTitleSnapshot(
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
            .clock => try clock.draw(r.dc, r.config, r.height, x),
        };
    }

    /// Draws `segment`, catching and logging errors instead of propagating them.
    /// On failure returns `x` unchanged (the "drew nothing" signal) so a broken
    /// segment can't corrupt the surrounding layout or leave the off-screen
    /// pixmap partially drawn and never blitted.
    fn drawSegmentSafe(self: *State, snap: *const BarSnapshot, segment: types.BarSegment, x: u16, width: ?u16) u16 {
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
        snap: *const BarSnapshot,
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
    inline fn shouldSkipSegment(snap: *const BarSnapshot, seg: types.BarSegment) bool {
        if (snap.is_full_redraw) return false;
        return switch (seg) {
            .workspaces => !snap.is_workspace_dirty,
            .title => !snap.is_title_dirty,
            else => false,
        };
    }

    fn paintGap(self: *State, gap_x: u16, scaled_spacing: u16) void {
        self.render.dc.fillRect(gap_x, 0, scaled_spacing, self.render.height, self.render.config.bg);
    }

    fn drawRightSegments(self: *State, snap: *const BarSnapshot, segments: []const types.BarSegment) void {
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
    fn drawAll(self: *State, snap: *const BarSnapshot, flush: bool) void {
        self.drawAllInner(snap);
        if (flush) self.render.dc.blit() else self.render.dc.renderOnly();
        if (self.title_cache_pending_x) |x|
            self.syncTitleCache(snap, x, self.title_cache_pending_w);
        self.title_cache_pending_x = null;
    }

    /// Core drawing logic shared by the flush and grab-safe draw paths; does not flush.
    fn drawAllInner(self: *State, snap: *const BarSnapshot) void {
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
                        @max(title_min_width, self.render.width -| x -| right_total -| scaled_spacing)
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
        _ = clock.draw(self.render.dc, self.render.config, self.render.height, clock_x) catch |e|
            debug.warnOnErr(e, "drawClockOnly");
        // renderOnly() flushes Cairo to the pixmap; blitAndFlush() copies only the
        // clock region to the window and calls xcb_flush, avoiding a full-window
        // blit plus a separate main-thread xcb_flush.
        self.render.dc.renderOnly();
        self.render.dc.blitAndFlush(clock_x, self.layout_cache.clock_width);
    }

    /// Replacements are built before the swap so a failed allocation leaves the cache
    /// showing stale data rather than going silently empty.
    fn syncTitleCache(self: *State, snap: *const BarSnapshot, x: u16, w: u16) void {
        const alloc = self.render.allocator;

        // Re-sync per-window data only when the capture re-fetched it
        // (snap.title_list_refreshed). Unchanged frames relay the same lists
        // between ping-pong slots, so the cache already matches; re-duping
        // every title was an O(window count) alloc+free pass for no-op data.
        if (snap.title_list_refreshed) {
            swapAlloc(u32, &self.title_cache.title_data.workspace_windows, alloc, snap.title_data.workspace_windows.items);

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
            swapAlloc(utils.Rect, &self.title_cache.title_data.window_geoms, alloc, snap.title_data.window_geoms.items);

            self.title_cache.title_data.focused_window = snap.title_data.focused_window;
        }

        self.title_cache.title_x = x;
        self.title_cache.title_width = w;
        self.title_cache.is_layout_valid = true;
    }
};

// Snapshot capture

/// Builds a replacement list and swaps it into `dst` only on success, so a
/// failed allocation leaves the cache showing stale data rather than empty.
fn swapAlloc(comptime T: type, dst: *std.ArrayListUnmanaged(T), alloc: std.mem.Allocator, src: []const T) void {
    if (dst.capacity >= src.len) {
        dst.items.len = 0;
        dst.appendSlice(alloc, src) catch return;
        return;
    }
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

fn makeTitleSnapshot(
    focused_window: ?u32,
    focused_title: []const u8,
    workspace_windows: []const u32,
    minimized: *const std.AutoHashMapUnmanaged(u32, void),
    titles: []const []const u8,
    geoms: []const utils.Rect,
) title.TitleSnapshot {
    return .{
        .focused_window = focused_window,
        .focused_title = focused_title,
        .minimized_title = minimizedTitleFor(workspace_windows, minimized, titles),
        .current_ws_wins = workspace_windows,
        .minimized_set = minimized,
        .titles = titles,
        .geoms = geoms,
    };
}

/// Returns true when the two minimized sets differ in membership (not just count).
fn hasMinimizedSetChanged(
    a: *const std.AutoHashMapUnmanaged(u32, void),
    b: *const std.AutoHashMapUnmanaged(u32, void),
) bool {
    if (a.count() != b.count()) return true;
    var it = a.keyIterator();
    while (it.next()) |key| if (!b.contains(key.*)) return true;
    return false;
}

/// Collect the minimized window set for the current snapshot.
fn captureMinimizedSet(snap: *BarSnapshot, allocator: std.mem.Allocator) !void {
    snap.title_data.minimized_windows.clearRetainingCapacity();
    try minimize.collectMinimizedIntoSet(&snap.title_data.minimized_windows, allocator);
}

/// Capture the workspace-derived state: count, current workspace, all-view
/// mode, per-workspace occupancy, and the current workspace's window list.
/// OR-accumulates all window masks in a single pass, then derives per-workspace
/// occupancy from the combined bitmask in O(workspace_count).
fn captureWorkspaceState(snap: *BarSnapshot, allocator: std.mem.Allocator) !void {
    const ws_state = workspaces.getState() orelse return;
    snap.workspace_count = @intCast(ws_state.workspaces.len);
    snap.current_workspace = ws_state.current;
    snap.is_all_view_active = ws_state.all_view_temp_wins.items.len > 0;
    try snap.workspace_has_windows.resize(allocator, snap.workspace_count);
    @memset(snap.workspace_has_windows.items, false);
    snap.title_data.workspace_windows.clearRetainingCapacity();
    const cur_bit: u64 = if (ws_state.current < ws_state.workspaces.len)
        tracking.workspaceBit(ws_state.current)
    else
        0;
    var combined_mask: u64 = 0;
    for (tracking.allWindows()) |entry| {
        combined_mask |= entry.mask;
        if (cur_bit != 0 and entry.mask & cur_bit != 0)
            try snap.title_data.workspace_windows.append(allocator, entry.win);
    }
    for (0..snap.workspace_count) |i| {
        snap.workspace_has_windows.items[i] = combined_mask & tracking.workspaceBit(@as(u8, @intCast(i))) != 0;
    }
}

/// Capture the focused window and its title. The title is re-fetched from X
/// only when the focused window or the title changed; otherwise the previous
/// frame's copy is reused.
fn captureFocusedTitle(s: *State, snap: *BarSnapshot, prev: *BarSnapshot) void {
    snap.title_data.focused_window = focus.getFocused();
    snap.is_title_invalidated = s.title_cache.is_invalidated;
    s.title_cache.is_invalidated = false;

    snap.title_data.focused_title.clearRetainingCapacity();
    if (snap.title_data.focused_window) |fw| {
        if (snap.title_data.focused_window != prev.title_data.focused_window or snap.is_title_invalidated) {
            title.fetchWindowTitleInto(core.getState().conn, fw, &snap.title_data.focused_title, s.render.allocator) catch {};
        } else {
            std.mem.swap(std.ArrayListUnmanaged(u8), &snap.title_data.focused_title, &prev.title_data.focused_title);
        }
    }
}

/// (Re)fetch the batched window titles/geometry; or, when nothing changed,
/// relay the previous frame's lists between the two ping-pong slots instead
/// of re-fetching (an O(window count) alloc+free pass saved on redraws where
/// the titles didn't change, e.g. a workspace-indicator repaint). `prev` is
/// not read again this frame, and next frame the roles flip, so ownership
/// relays between the slots with zero allocation traffic until a
/// `title_data_changed` frame refreshes it for real.
fn prefetchWindowTitles(s: *State, snap: *BarSnapshot, prev: *BarSnapshot, title_data_changed: bool) void {
    if (title_data_changed) {
        const focused_idx: ?usize = if (snap.title_data.focused_window) |fw|
            std.mem.indexOfScalar(u32, snap.title_data.workspace_windows.items, fw)
        else
            null;

        // Batch pre-fetch replaces the sequential per-window round-trips:
        // one dupe per title, ~2 round-trips total, zero blocking waits on
        // the draw path itself (see title.batchFetchWindowInfosInto).
        snap.title_data.window_titles.clear();
        snap.title_data.window_geoms.clearRetainingCapacity();
        title.batchFetchWindowInfosInto(
            core.getState().conn,
            snap.title_data.workspace_windows.items,
            focused_idx,
            snap.title_data.focused_title.items,
            &snap.title_data.minimized_windows,
            &snap.title_data.window_titles.list,
            &snap.title_data.window_geoms,
            snap.title_data.window_titles.allocator(),
            s.render.allocator,
        );
    } else {
        std.mem.swap(WindowTitles, &snap.title_data.window_titles, &prev.title_data.window_titles);
        std.mem.swap(std.ArrayListUnmanaged(utils.Rect), &snap.title_data.window_geoms, &prev.title_data.window_geoms);
    }
}

/// Captures current WM state into `snap`, diffing against `prev` to set dirty
/// flags. `forced` (caller must read/clear `pending_force_full_redraw`)
/// overrides all dirty checks. `prev` is mutable because the "nothing changed"
/// branch swaps ownership of `window_titles`/`window_geoms` between the two
/// ping-pong slots instead of duping them: see `prefetchWindowTitles`.
fn captureStateIntoSlot(s: *State, snap: *BarSnapshot, prev: *BarSnapshot, forced: bool) !void {
    const allocator = s.render.allocator;
    bench.beginTitleCapture();
    const capture_start_ns: u64 = if (bench.enabled) utils.monotonicNs() else 0;
    // Consume the title-only redraw request. Unlike `forced` (which clears the
    // whole bar), it only forces the title pre-fetch to re-run so the
    // segmented title view picks up new per-window geometry after a swap.
    const forced_title_redraw = gBar.pending_force_title_redraw;
    gBar.pending_force_title_redraw = false;

    try captureMinimizedSet(snap, allocator);
    try captureWorkspaceState(snap, allocator);
    captureFocusedTitle(s, snap, prev);

    // Pre-fetch titles so the segmented-title draw path never issues its own
    // X11 calls. Only run when title state changed; clock ticks never reach
    // this function at all, so there's no separate "no-op" case.
    const title_data_changed =
        forced_title_redraw or
        snap.title_data.focused_window != prev.title_data.focused_window or
        snap.is_title_invalidated or
        !std.mem.eql(u32, snap.title_data.workspace_windows.items, prev.title_data.workspace_windows.items) or
        hasMinimizedSetChanged(&snap.title_data.minimized_windows, &prev.title_data.minimized_windows);
    prefetchWindowTitles(s, snap, prev, title_data_changed);

    snap.title_list_refreshed = title_data_changed;
    snap.is_full_redraw = forced or (snap.workspace_count != prev.workspace_count);
    snap.is_workspace_dirty = snap.is_full_redraw or
        snap.current_workspace != prev.current_workspace or
        snap.is_all_view_active != prev.is_all_view_active or
        !std.mem.eql(bool, snap.workspace_has_windows.items, prev.workspace_has_windows.items);
    snap.is_title_dirty = title_data_changed or
        prompt.isActive() or
        !std.mem.eql(u8, snap.title_data.focused_title.items, prev.title_data.focused_title.items);

    if (bench.enabled) bench.reportTitleCapture(
        utils.monotonicNs() -| capture_start_ns,
        snap.title_data.workspace_windows.items.len,
    );
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
    const visual_id = if (want_transparency)
        drawing.findVisualByDepth(cs.screen, 32)
    else
        cs.screen.root_visual;
    const depth: u8 = if (want_transparency) 32 else xcb.XCB_COPY_FROM_PARENT;
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
    // Positional slots, in the same order as the CW_* bits above:
    // [0]=BACK_PIXEL, [1]=BORDER_PIXEL, [2]=OVERRIDE_REDIRECT,
    // [3]=EVENT_MASK, [4]=COLORMAP.
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
    try dc.font.loadFonts(sized);
    if (sized.len > 1) debug.info("Loaded {} fonts with fallback support", .{sized.len});
}

/// Set an EWMH atom property on the bar window.
fn setAtomProperty(conn: core.Connection, win_id: u32, prop: u32, atom_type: u32, values: anytype) void {
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

fn destroyBarWindow(conn: core.Connection, win_id: u32, colormap: u32) void {
    _ = xcb.xcb_destroy_window(conn, win_id);
    if (colormap != 0) _ = xcb.xcb_free_colormap(conn, colormap);
}

fn measureFontMetrics() ?struct { asc: i32, desc: i32 } {
    var mc = drawing.MeasureContext.init(core.getState().alloc, core.dpi_info.load(.acquire)) catch return null;
    defer mc.deinit();
    loadBarFonts(&mc) catch return null;
    const asc, const desc = mc.font.getMetrics();
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

fn createDrawContext(setup: BarWindowSetup, height: u16) !*drawing.DrawContext {
    const cs = core.getState();
    const dc = try drawing.DrawContext.initWithVisual(
        cs.alloc,
        cs.conn,
        setup.win_id,
        cs.screen.width_in_pixels,
        height,
        setup.visual_id,
        core.dpi_info.load(.acquire),
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
    clock.startThread(cs.alloc, cs.config.bar.clock_format orelse types.default_clock_format);
}

fn stopBarThreads() void {
    const cs = core.getState();
    clock.stopThread(cs.alloc);
}

pub fn init() !void {
    const cs = core.getState();
    std.debug.assert(cs.config.bar.enabled);
    initAtoms();
    refresh_rate.ensureRefreshRateDetected(cs.conn);
    const height = try calcBarHeightAndFontSize();
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
    const height = calcBarHeightAndFontSize() catch default_bar_height;
    applyReload(old, height) catch |err| {
        debug.err("Bar reload failed ({s}), keeping old bar", .{@errorName(err)});
    };
}

fn applyReload(old: *State, height: u16) !void {
    const cs = core.getState();
    const new_bar = createBar(height, calcBarYPos(height)) catch |err| {
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
    const no_fullscreen = fullscreen.getForWorkspace(core.WorkspaceId.fromIndex(current_ws)) == null;
    if (build_options.has_tiling and no_fullscreen)
        tiling.retileCurrentWorkspace();
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

/// Read-only prediction of whether captureStateIntoSlot would take its
/// expensive path (fresh focused-title fetch plus the batched per-window
/// title/geometry prefetch -- both issue blocking X11 property round trips).
/// Mirrors the `title_data_changed` computation there WITHOUT consuming any
/// flags or touching X11, so grab-held callers can defer the whole capture
/// instead of blocking under xcb_grab_server.
fn snapshotNeedsRefetch(s: *State) bool {
    if (gBar.pending_force_title_redraw) return true;
    const prev = &s.snapshots[1 - s.snap_idx];
    if (focus.getFocused() != prev.title_data.focused_window) return true;
    if (s.title_cache.is_invalidated) return true;

    // Rebuild the current workspace's window list on the stack (same source
    // and order as captureWorkspaceState) and compare against last frame's.
    const cur = tracking.getCurrentWorkspace() orelse return false;
    const cur_bit = tracking.workspaceBit(cur);
    var wins: [256]u32 = undefined;
    var n: usize = 0;
    for (tracking.allWindows()) |entry| {
        if (entry.mask & cur_bit == 0) continue;
        if (n == wins.len) return true; // over-capacity: let the real capture handle it
        wins[n] = entry.win;
        n += 1;
    }
    if (!std.mem.eql(u32, wins[0..n], prev.title_data.workspace_windows.items)) return true;

    // Minimized-set equality without allocating: membership of every
    // currently-minimized window plus an equal count covers both directions.
    var min_count: usize = 0;
    for (tracking.allWindows()) |entry| {
        if (!minimize.isMinimized(entry.win)) continue;
        min_count += 1;
        if (!prev.title_data.minimized_windows.contains(entry.win)) return true;
    }
    if (min_count != prev.title_data.minimized_windows.count()) return true;

    return false;
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
    if (snapshotNeedsRefetch(s)) {
        s.markDirty();
        return;
    }
    // Phase 1: render to pixmap without any XCB flush.
    submitRenderBlocking();
    // Phase 2: queue the blit; will be sent with ungrabAndFlush().
    s.render.dc.blitQueued();
    s.is_dirty = false;
}

/// Commit a grab-held batch: render the bar to the off-screen pixmap and queue
/// the copy, then release the server grab and flush everything to the
/// compositor atomically: exactly one frame, no intermediate states.
pub fn commitInsideGrab() void {
    redrawInsideGrab();
    ungrabAndFlush();
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
    const is_fullscreen = fullscreen.getForWorkspace(core.WorkspaceId.fromIndex(current_ws)) != null;
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
        fullscreen.getForWorkspace(core.WorkspaceId.fromIndex(current_ws)) != null;
    const should_be_visible = !bar_forced_hidden_by_fullscreen and s.is_globally_visible and action != .hide_fullscreen;
    if (s.is_visible == should_be_visible and action != .toggle) return;
    s.is_visible = should_be_visible;
    if (should_be_visible) submitFullRedrawWithTitleReset(s);

    const conn = core.getState().conn;
    const grabbed = action == .toggle;
    if (grabbed) utils.grabServer(conn);
    if (should_be_visible) _ = xcb.xcb_map_window(conn, s.win.win_id) else _ = xcb.xcb_unmap_window(conn, s.win.win_id);
    if (grabbed) {
        const effective_visible = if (bar_forced_hidden_by_fullscreen) s.is_globally_visible else s.is_visible;
        retileAllWorkspaces(s, effective_visible);
        window.updateFloatingWindowBorders();
        window.markBordersFlushed();
        ungrabAndFlush();
    } else {
        if (build_options.has_tiling) tiling.retileCurrentWorkspace();
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

/// Drains the clock thread's redraw request on the main WM thread. Draws just
/// the clock segment: Pango runs here, never on the clock thread. Returns
/// true when a redraw was actually performed. Cheap to call on every event
/// batch: it no-ops unless the clock thread published a new second.
pub fn updateClock() bool {
    const s = gBar.state orelse return false;
    if (!s.is_visible) return false;
    if (!clock.consumeClockDirty()) return false;
    s.drawClockOnly();
    return true;
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

    if (s.layout_cache.workspaces_bounds.contains(x)) {
        const offset = x - s.layout_cache.workspaces_bounds.x;
        if (left) handleWorkspacesClick(offset) else handleWorkspacesRightClick(offset);
        return;
    }

    if (s.title_cache.is_layout_valid and
        x >= s.title_cache.title_x and x < s.title_cache.title_x + s.title_cache.title_width)
    {
        if (right) {
            if (!prompt.isActive()) prompt.toggle();
        } else if (!prompt.isActive()) {
            handleTitleClick(s, x - s.title_cache.title_x);
        }
        return;
    }

    if (s.layout_cache.layout_bounds.contains(x)) {
        if (left) withTilingGrabForClick(tilingToggleLayout) else withTilingGrabForClick(tilingToggleLayoutReverse);
        return;
    }

    if (s.layout_cache.variants_bounds.contains(x)) {
        if (left) withTilingGrabForClick(tilingStepLayoutVariant) else withTilingGrabForClick(tilingStepLayoutVariantReverse);
        return;
    }
}

fn resolveWorkspaceClick(offset: u16) ?usize {
    const cell_w = tags.getCachedWorkspaceWidth();
    if (cell_w == 0) return null;
    const ws_state = workspaces.getState() orelse return null;
    const idx: usize = @intCast(offset / cell_w);
    if (idx >= ws_state.workspaces.len) return null;
    return idx;
}

/// `offset` is the click position relative to the workspaces segment's start.
fn handleWorkspacesClick(offset: u16) void {
    const idx = resolveWorkspaceClick(offset) orelse return;
    workspaces.switchTo(core.WorkspaceId.fromIndex(@intCast(idx)));
}

/// `offset` is the click position relative to the workspaces segment's start.
/// Sends the currently focused window to the clicked workspace; a no-op when
/// there's no focused window or it's already exclusively on that workspace
/// (see `workspaces.moveWindowTo`).
fn handleWorkspacesRightClick(offset: u16) void {
    const idx = resolveWorkspaceClick(offset) orelse return;
    const win = focus.getFocused() orelse return;
    workspaces.moveWindowTo(win, core.WorkspaceId.fromIndex(@intCast(idx))) catch |e| debug.warnOnErr(e, "bar workspace right-click move");
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
    const snapshot = makeTitleSnapshot(
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

    if (minimize.isMinimized(target.window)) {
        minimize.unminimizeSpecific(target.window);
    } else if (focus.getFocused() == target.window) {
        minimize.minimizeWindow();
    } else {
        focus.setFocus(target.window, .mouse_click);
    }
}

/// Mirrors input.zig's withTilingGrab (mouse-driven variant, which resyncs
/// pointer-based focus after the reflow). Reimplemented locally rather than
/// exposed from input.zig because input.zig already imports this module;
/// importing back would cycle.
fn withTilingGrabForClick(op: anytype) void {
    const conn = core.getState().conn;
    utils.grabServer(conn);
    focus.setSuppressReason(.tiling_operation);
    op();
    window.updateFloatingWindowBorders();
    window.markBordersFlushed();
    redrawInsideGrab();
    focus.beginPointerSync();
    utils.ungrabAndFlush(conn);
}

fn tilingToggleLayout() void {
    if (build_options.has_tiling) tiling.toggleLayout();
}
fn tilingToggleLayoutReverse() void {
    if (build_options.has_tiling) tiling.toggleLayoutReverse();
}
fn tilingStepLayoutVariant() void {
    if (build_options.has_tiling) tiling.stepLayoutVariant();
}
fn tilingStepLayoutVariantReverse() void {
    if (build_options.has_tiling) tiling.stepLayoutVariantReverse();
}

fn isTilingActive() bool {
    return core.getState().config.tiling.enabled and build_options.has_tiling and tiling.isEnabled();
}

/// Must be called without holding the X server grab.
/// `effective_visible` is the bar-visibility value that tilers should observe;
/// it may differ from `s.is_visible` when a fullscreen override is in effect.
fn retileAllWorkspaces(s: *State, effective_visible: bool) void {
    // Temporarily expose the effective visibility so tiling code reading
    // isVisible() sees the intended value, not the transitional state, for the
    // duration of this function.
    const saved_visible = s.is_visible;
    s.is_visible = effective_visible;
    defer s.is_visible = saved_visible;
    const multi_ws = core.getState().config.workspaces.enabled and isTilingActive();
    if (!multi_ws) {
        if (build_options.has_tiling) tiling.retileCurrentWorkspace();
        return;
    }
    const ws_state = workspaces.getState() orelse return;
    for (ws_state.workspaces, 0..) |_, idx| {
        const ws_idx: u8 = @intCast(idx);
        if (tracking.countWindowsOnWorkspace(core.WorkspaceId.fromIndex(ws_idx)) == 0) continue;
        if (fullscreen.getForWorkspace(core.WorkspaceId.fromIndex(ws_idx)) != null) continue;
        if (!build_options.has_tiling) continue;
        if (ws_idx != ws_state.current)
            tiling.retileInactiveWorkspace(core.WorkspaceId.fromIndex(ws_idx))
        else
            tiling.retileCurrentWorkspace();
    }
}
