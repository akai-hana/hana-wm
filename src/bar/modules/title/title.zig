//! Title bar segment
//! Displays the focused window title on the status bar, with a split view when minimized windows are present.

const std = @import("std");

const core = @import("core");
const xcb = core.xcb;
const utils = @import("utils");
const scale = @import("scale");
const debug = @import("debug");

const types = @import("types");

const drawing = @import("drawing");
const carousel = @import("carousel");
const tiling = @import("tiling");

// Module constants

/// Fixed left indent applied inside every title cell, independent of
/// `scaledSegmentPadding`.  Provides visual breathing room between the
/// segment edge and the title text.
const title_lead_px: u16 = 4;

/// Maximum number of windows rendered in split-view.
/// Stack-allocated arrays in `drawSegmentedTitles` are bounded by this value.
/// Windows beyond this index are silently omitted from the bar.
/// 128 covers any practical workspace size while keeping stack usage bounded.
const max_visible_windows: usize = 128;

/// Off-screen sentinel geometry for minimized or otherwise unresolvable
/// windows: position sorting places it last, and drawing is skipped.
pub const offscreen_rect: utils.Rect = .{ .x = std.math.maxInt(i16), .y = std.math.maxInt(i16), .width = 0, .height = 0 };

// Atom cache

const Atoms = struct {
    /// null until successfully resolved, to avoid XCB_ATOM_NONE's sentinel (0).
    net_wm_name: ?u32 = null,
    utf8_string: ?u32 = null,
    is_initialized: bool = false,

    /// Resolves and caches the X11 atoms needed for title fetching.
    /// Subsequent calls are a no-op.
    fn ensureResolved(self: *Atoms) void {
        if (self.is_initialized) return;
        self.is_initialized = true;
        self.net_wm_name = utils.getAtomCached("_NET_WM_NAME") catch null;
        self.utf8_string = utils.getAtomCached("UTF8_STRING") catch null;
    }

    /// Returns the UTF-8 atom when available, falling back to XCB_ATOM_STRING.
    inline fn utf8AtomType(self: *const Atoms) u32 {
        return self.utf8_string orelse xcb.XCB_ATOM_STRING;
    }
};

var atoms: Atoms = .{};

// Internal types

const WindowInfo = struct {
    window: u32,
    x: i16,
    y: i16,
    title: []const u8,
    minimized: bool,
};

// Public input types

/// Stable per-call rendering context: geometry, draw state, connection, and
/// (on the `draw()` path) the bar slot's title cache.
///
/// Constructed once per bar frame and shared between `draw()` and
/// `drawCached()`. `cached_title` / `cached_title_window` are left at their
/// null default on the `drawCached()` path, which never updates the cache —
/// only `draw()` passes them. Folding the cache fields directly into this
/// struct avoids a separate `TitleCache` struct that every caller would
/// otherwise have to construct and pass alongside this one.
pub const TitleRenderContext = struct {
    dc: *drawing.DrawContext,
    config: types.BarConfig,
    height: u16,
    start_x: u16,
    width: u16,
    conn: *xcb.xcb_connection_t,

    /// Backing buffer updated by `draw()` on each full render; the bar passes
    /// its contents as `snapshot.focused_title` in subsequent `drawCached()`
    /// calls. Null on the `drawCached()` path (read-only; no cache update).
    cached_title: ?*std.ArrayListUnmanaged(u8) = null,
    /// Window ID `cached_title` was fetched for; used to detect when
    /// `focused_title` belongs to a new window. Null alongside `cached_title`.
    cached_title_window: ?*?u32 = null,
};

/// Per-frame volatile snapshot captured before drawing.
///
/// `focused_title` and `minimized_title` must be pre-fetched via
/// `fetchWindowTitleInto` before `draw()` runs, so `draw()` itself never
/// issues its own X11 property fetches.
///
/// `minimized_title` is only used in the single-window-minimized case.  Pass
/// an empty slice when that case cannot occur (e.g. the `drawCached` fast path,
/// which has no cached minimized title).
pub const TitleSnapshot = struct {
    focused_window: ?u32,
    focused_title: []const u8,
    minimized_title: []const u8,
    current_ws_wins: []const u32,
    minimized_set: *const std.AutoHashMapUnmanaged(u32, void),

    /// Pre-fetched window titles captured on the main thread, indexed parallel
    /// to `current_ws_wins` (i.e. `titles[i]` is the title of `current_ws_wins[i]`).
    /// An empty slice signals that no pre-fetched data is available (e.g. the
    /// drawCached fast path before the title cache has been populated with
    /// multi-window data).
    titles: []const []const u8 = &.{},

    /// Pre-fetched window geometry captured on the main thread (see
    /// `fetchWindowGeom`), indexed parallel to `current_ws_wins` the same way
    /// `titles` is. Used by drawSegmentedTitles as a non-blocking fallback for
    /// windows the tiling cache doesn't cover (e.g. floating windows), so that
    /// path — including the drawCached fast path, which can run on the
    /// carousel thread — never issues its own xcb_get_geometry round-trip.
    /// An empty slice signals no pre-fetched data is available, in which case
    /// drawSegmentedTitles falls back to fetching live.
    geoms: []const utils.Rect = &.{},
};

// Title width cache

/// Bounded cache of measured title text widths, indexed by window ID.
///
/// `drawSegmentedTitles` previously called `dc.measureTextWidth` for every
/// visible segment on every call — including calls that originate from the
/// `drawCached()` fast path, which can run once per carousel tick (up to the
/// display refresh rate). Most of those segments are not the actively
/// scrolling one and their title text does not change between ticks, so
/// re-measuring them every time was wasted Pango/cairo work.
///
/// This mirrors the text_w recovery `carousel.drawScrollingTitle` already
/// does for the single-window case, generalised to the N-window split view.
/// A cache hit requires both the window ID and the title slice's identity
/// (pointer + length) to match what was last measured; any difference falls
/// back to a fresh measurement, so a stale entry can only ever cost an extra
/// measurement, never return a wrong width.
const TitleWidthCache = struct {
    const Entry = struct {
        window: u32,
        title_ptr: [*]const u8,
        title_len: usize,
        width: u16,
    };

    /// Direct storage, not a hash map: bounded by `max_visible_windows` and
    /// lives for the process lifetime, so there is no per-frame allocation
    /// or initialization cost. Lookup is a linear scan, which is fine at the
    /// realistic window counts this bar renders (a handful of segments);
    /// even in the 128-window worst case, a scan of plain integer
    /// comparisons is far cheaper than the Pango call it replaces.
    entries: [max_visible_windows]?Entry = @splat(null),

    fn widthFor(self: *TitleWidthCache, dc: *drawing.DrawContext, window: u32, title: []const u8) u16 {
        var free_slot: ?usize = null;
        for (&self.entries, 0..) |*slot, i| {
            if (slot.*) |e| {
                if (e.window == window) {
                    if (e.title_ptr == title.ptr and e.title_len == title.len) return e.width;
                    const w = dc.measureTextWidth(title);
                    slot.* = .{ .window = window, .title_ptr = title.ptr, .title_len = title.len, .width = w };
                    return w;
                }
            } else if (free_slot == null) {
                free_slot = i;
            }
        }
        // No existing entry for this window: measure and store in a free
        // slot, or evict slot 0 if the cache is completely full (only
        // possible when `max_visible_windows` windows are simultaneously
        // visible — the cache degrades to more frequent misses there, but
        // stays correct).
        const w = dc.measureTextWidth(title);
        self.entries[free_slot orelse 0] = .{ .window = window, .title_ptr = title.ptr, .title_len = title.len, .width = w };
        return w;
    }
};

var title_width_cache: TitleWidthCache = .{};

// Private helpers

/// Extract a UTF-8 string from an XCB get_property reply and dupe it into
/// `allocator`. Returns null when the reply carries no bytes. Shared by
/// Phase 2 and Phase 3 of drawSegmentedTitles instead of duplicating an
/// identical three-line extract-and-dupe block in each.
fn extractPropertyString(
    r: *xcb.xcb_get_property_reply_t,
    allocator: std.mem.Allocator,
) !?[]const u8 {
    const len = xcb.xcb_get_property_value_length(r);
    if (len == 0) return null;
    const ptr: [*]const u8 = @ptrCast(xcb.xcb_get_property_value(r));
    return try allocator.dupe(u8, ptr[0..@intCast(len)]);
}

/// Shared body for draw() and drawCached(). `ctx.cached_title` is non-null
/// only on the draw() path, so this works unmodified for both callers.
fn drawInner(
    ctx: TitleRenderContext,
    snapshot: TitleSnapshot,
    allocator: std.mem.Allocator,
    title_invalidated: bool,
) !u16 {
    scale.ensureRefreshRateDetected(ctx.conn);
    const window_count = snapshot.current_ws_wins.len;
    if (emptyWorkspace(ctx, window_count)) |end_x| return end_x;

    if (window_count == 1) {
        try drawSingleWindow(ctx, snapshot, allocator, title_invalidated);
    } else {
        try drawSegmentedTitles(ctx, snapshot, allocator, title_invalidated);
    }

    return ctx.start_x + ctx.width;
}

// Public API — draw entry points

/// Draw the title segment.
///
/// Updates `ctx.cached_title` / `ctx.cached_title_window` as a side-effect so
/// `drawCached()` has a valid slice on the next tick. Caller must set both to
/// non-null — see `TitleRenderContext`.
///
/// `title_invalidated` must be true whenever the focused window's title
/// property changed since the last draw.
pub fn draw(
    ctx: TitleRenderContext,
    snapshot: TitleSnapshot,
    allocator: std.mem.Allocator,
    title_invalidated: bool,
) !u16 {
    return drawInner(ctx, snapshot, allocator, title_invalidated);
}

/// Draw the title segment using already-cached state.
///
/// Called from a fast-path redraw (focus-only or carousel tick) — either the
/// main thread (scheduleFocusRedraw) or the dedicated carousel thread
/// (carousel's per-refresh tick), serialized by bar.zig's draw_mutex.
/// Unlike `draw()`, this function:
///   - uses `snapshot.focused_title` as a read-only slice; the caller is
///     responsible for passing the bar slot's cached buffer contents here.
///   - never updates the title cache: `ctx.cached_title` / `ctx.cached_title_window`
///     must be left null (`draw()` is responsible for keeping the cache current).
///   - always passes `title_invalidated = false` to the carousel, since this
///     path only re-renders existing state.
///   - passes `minimized_title = ""` in the snapshot (the minimized title is not
///     cached by the bar slot; the full `draw()` path handles it).
pub fn drawCached(
    ctx: TitleRenderContext,
    snapshot: TitleSnapshot,
    allocator: std.mem.Allocator,
) !u16 {
    return drawInner(ctx, snapshot, allocator, false);
}

// Public API — title pre-fetch (main thread only)

/// Fetch the title of `win` into `buf`, reusing its existing capacity.
///
/// Must be called on the MAIN THREAD.  Used for both focused and minimized
/// windows so drawing never has to make blocking X11 round-trips itself.
///
/// `bar.captureStateIntoSlot` should call this once for the focused window and,
/// when the workspace has exactly one window and it is minimized, once for
/// that minimized window — storing the results in `TitleSnapshot.focused_title`
/// and `TitleSnapshot.minimized_title` respectively.
pub fn fetchWindowTitleInto(
    conn: *xcb.xcb_connection_t,
    win: u32,
    buf: *std.ArrayListUnmanaged(u8),
    allocator: std.mem.Allocator,
) !void {
    atoms.ensureResolved();
    const utf_type = atoms.utf8AtomType();

    if (atoms.net_wm_name) |na| {
        if (utils.fetchPropertyToBuffer(conn, win, na, utf_type, buf, allocator) catch null) |t| {
            if (t.len > 0) return;
        }
    }
    _ = utils.fetchPropertyToBuffer(
        conn,
        win,
        xcb.XCB_ATOM_WM_NAME,
        xcb.XCB_ATOM_STRING,
        buf,
        allocator,
    ) catch {};
}

/// Fetch the geometry of `win`, preferring the tiling cache (zero round-trips)
/// and falling back to a blocking xcb_get_geometry round-trip on a cache miss.
/// Returns an offscreen sentinel rect if the reply can't be read.
///
/// Must be called on the MAIN THREAD — same contract as `fetchWindowTitleInto`.
/// `bar.captureStateIntoSlot` calls this once per non-minimized workspace
/// window so `drawSegmentedTitles` — including the `drawCached` fast path,
/// which can run on the carousel thread — never has to issue its own
/// xcb_get_geometry round-trip for a window the tiling cache doesn't cover
/// (e.g. a floating window).
pub fn fetchWindowGeom(conn: *xcb.xcb_connection_t, win: u32) utils.Rect {
    if (tiling.getWindowGeom(win)) |cached| return cached;
    const cookie = xcb.xcb_get_geometry(conn, win);
    const r = xcb.xcb_get_geometry_reply(conn, cookie, null) orelse return offscreen_rect;
    defer std.c.free(r);
    return .{
        .x = @intCast(r.*.x),
        .y = @intCast(r.*.y),
        .width = r.*.width,
        .height = r.*.height,
    };
}

// Empty workspace fast path

/// If `count` is zero: tears down the carousel, fills the segment background,
/// and returns the segment's end x so the caller can return immediately.
/// Returns null when there are windows present and rendering should proceed.
inline fn emptyWorkspace(ctx: TitleRenderContext, count: usize) ?u16 {
    if (count != 0) return null;
    // No windows on this workspace — tear down any live carousel immediately
    // so it does not keep scrolling invisibly in the background.
    // Runs under draw_mutex (drawAll), so use the non-locking teardown;
    // deinitCarousel() would recursively re-lock draw_mutex (not recursive).
    carousel.deinitCarouselLocked();
    ctx.dc.fillRect(ctx.start_x, 0, ctx.width, ctx.height, ctx.config.bg);
    return ctx.start_x + ctx.width;
}

// Single-window rendering

/// Shared rendering logic for both `draw()` and `drawCached()`.
///
/// `ctx.cached_title` is non-null on the `draw()` path and is updated as a
/// side-effect. It is null on the `drawCached()` path (read-only; no cache
/// update). `title_invalidated` is always false on the `drawCached()` path.
fn drawSingleWindow(
    ctx: TitleRenderContext,
    snapshot: TitleSnapshot,
    allocator: std.mem.Allocator,
    title_invalidated: bool,
) !void {
    // Free the segmented carousel: the single and segmented paths are
    // mutually exclusive.  Leaving render.seg alive after a workspace switch
    // from a multi-window workspace keeps carousel.isCarouselActive() true,
    // which keeps the carousel thread calling drawCached on every tick.
    // drawCached passes minimized_title = "" (it has no cache for it), so
    // drawSingleWindow would fill the accent background but draw no text —
    // erasing the correctly rendered minimized title after the first full draw
    // and leaving a blank rectangle for as long as render.seg survives.
    // Mirrors the deinitSingleCarousel() call in drawSegmentedTitles.
    carousel.deinitSegmentedCarousel();

    const single_win = snapshot.current_ws_wins[0];
    const is_minimized = snapshot.minimized_set.contains(single_win);
    // `has_focus` is true when any window on this workspace is focused,
    // meaning the segment gets the accent colour rather than plain bg.
    const has_focus = snapshot.focused_window != null;

    const accent = if (is_minimized)
        ctx.config.title_minimized_accent
    else if (has_focus)
        ctx.config.title_accent_color
    else
        ctx.config.bg;
    ctx.dc.fillRect(ctx.start_x, 0, ctx.width, ctx.height, accent);

    const scaled_padding = ctx.config.scaledSegmentPadding(ctx.height);
    const baseline_y = ctx.dc.baselineY(ctx.height);
    const text_x = ctx.start_x + scaled_padding + title_lead_px;
    // Saturating arithmetic guards against extreme padding values before the
    // saturating subtraction, preventing a u16 wrap in the intermediate result.
    const avail_w = ctx.width -| scaled_padding *| 2 -| title_lead_px;
    const geom = carousel.SegmentGeometry{
        .seg_x = ctx.start_x,
        .seg_w = ctx.width,
        .text_x = text_x,
        .avail_w = avail_w,
    };

    if (is_minimized) {
        // Pre-fetched on the main thread via fetchWindowTitleInto — zero X11
        // I/O here, keeping this call free of blocking round-trips.
        if (snapshot.minimized_title.len > 0)
            try carousel.drawScrollingTitle(
                ctx.dc,
                baseline_y,
                geom,
                snapshot.minimized_title,
                accent,
                ctx.config.fg,
                single_win,
                false,
            );
        return;
    }

    if (snapshot.focused_title.len == 0) return;

    // Update the bar slot's title cache for the next drawCached() tick.
    // Only the draw() path passes non-null cache fields.
    if (ctx.cached_title) |buf| {
        const window_slot = ctx.cached_title_window.?;
        if (title_invalidated or window_slot.* != snapshot.focused_window) {
            buf.clearRetainingCapacity();
            buf.appendSlice(allocator, snapshot.focused_title) catch {};
            window_slot.* = snapshot.focused_window;
        }
    }

    const fg = if (has_focus) ctx.config.selected_fg else ctx.config.fg;
    try carousel.drawScrollingTitle(
        ctx.dc,
        baseline_y,
        geom,
        snapshot.focused_title,
        accent,
        fg,
        snapshot.focused_window,
        title_invalidated,
    );
}

// Split-view segmented titles

/// Renders one title segment per window in a horizontal split-view layout.
/// Windows are sorted spatially so each segment position is stable across focus changes.
fn drawSegmentedTitles(
    ctx: TitleRenderContext,
    snapshot: TitleSnapshot,
    allocator: std.mem.Allocator,
    title_invalidated: bool,
) !void {
    const windows = snapshot.current_ws_wins;
    if (windows.len == 0) return;

    if (windows.len > max_visible_windows)
        debug.warn("Workspace has {} windows; only the first {} are rendered in split-view", .{ windows.len, max_visible_windows });
    const win_count = @min(windows.len, max_visible_windows);

    // Free the single-window carousel: the single and segmented paths are
    // mutually exclusive.  Leaving it alive would cause the carousel timer
    // to blit the stale single-window pixmap over the correct split view.
    carousel.deinitSingleCarousel();

    // Prune the seg-carousel if its window has left the workspace so we never
    // blit a title for a window that was closed or moved to another workspace.
    if (carousel.getSegmentedCarouselWindow()) |tracked_win| {
        if (std.mem.indexOfScalar(u32, windows[0..win_count], tracked_win) == null)
            carousel.deinitSegmentedCarousel();
    }

    // `window_info_buf` and `owned_titles` must outlive gatherWindowInfos —
    // a WindowInfo's `.title` may point into `owned_titles`' memory — so they
    // live here rather than inside that function. Everything else
    // gatherWindowInfos needs (XCB cookie arrays, per-window bool flags —
    // several KB combined) is scoped entirely to its own stack frame and is
    // reclaimed as soon as it returns, before any of the drawing below runs.
    var window_info_buf: [max_visible_windows]WindowInfo = undefined;
    // Only the first `win_count` slots are read (see the defer below and
    // gatherWindowInfos), so only those need initializing — previously this
    // zero-filled all `max_visible_windows` slots on every call regardless
    // of how many windows were actually visible.
    var owned_titles: [max_visible_windows]?[]const u8 = undefined;
    for (owned_titles[0..win_count]) |*t| t.* = null;
    defer for (owned_titles[0..win_count]) |t| if (t) |s| allocator.free(s);

    const info_count = try gatherWindowInfos(
        ctx,
        snapshot,
        allocator,
        windows[0..win_count],
        &window_info_buf,
        &owned_titles,
    );
    if (info_count == 0) return;

    const window_infos = window_info_buf[0..info_count];
    // void context: sort order is purely spatial + window ID, never dependent
    // on focus (see `compareWindows`).  This prevents segment reordering on
    // focus changes, which would be visually jarring.
    std.mem.sort(WindowInfo, window_infos, {}, compareWindows);

    const window_count: u32 = @intCast(window_infos.len);
    const scaled_padding = ctx.config.scaledSegmentPadding(ctx.height);
    const baseline_y = ctx.dc.baselineY(ctx.height);

    for (window_infos, 0..) |info, i| {
        // Pixel-perfect tiling: segment i spans [i*W/n, (i+1)*W/n).
        const x0: u16 = @intCast(@divFloor(@as(u32, @intCast(i)) * ctx.width, window_count));
        const x1: u16 = @intCast(@divFloor(@as(u32, @intCast(i + 1)) * ctx.width, window_count));
        const segment_x: u16 = ctx.start_x + x0;
        const segment_width: u16 = x1 - x0;
        if (segment_width == 0) continue;

        const is_focused_win = snapshot.focused_window == info.window;

        const accent = if (is_focused_win) ctx.config.title_accent_color else if (info.minimized) ctx.config.title_minimized_accent else ctx.config.title_unfocused_accent;

        ctx.dc.fillRect(segment_x, 0, segment_width, ctx.height, accent);

        if (info.title.len == 0 or segment_width <= scaled_padding *| 2) continue;

        const text_x = segment_x + scaled_padding + title_lead_px;
        const avail_w = segment_width -| scaled_padding *| 2 -| title_lead_px;
        const text_fg = if (is_focused_win) ctx.config.selected_fg else ctx.config.fg;
        const text_w = title_width_cache.widthFor(ctx.dc, info.window, info.title);
        const geom = carousel.SegmentGeometry{
            .seg_x = segment_x,
            .seg_w = segment_width,
            .text_x = text_x,
            .avail_w = avail_w,
        };

        var scrolled = false;
        if (is_focused_win and carousel.isCarouselEnabled()) {
            // Focused + carousel enabled: pass full segment bounds so
            // the scroll covers the entire segment width. Returns false
            // exactly when the text fits.
            scrolled = try carousel.drawSegmentedCarousel(
                ctx.dc,
                baseline_y,
                geom,
                text_w,
                info.title,
                accent,
                text_fg,
                info.window,
                title_invalidated,
            );
        }
        if (!scrolled) {
            // Text fits (or carousel disabled / not focused): ellipsis on overflow.
            if (text_w <= avail_w)
                try ctx.dc.drawText(text_x, baseline_y, info.title, text_fg)
            else
                try ctx.dc.drawTextEllipsis(text_x, baseline_y, info.title, avail_w, text_fg);
        }
    }
}

/// Phase 1-3 of drawSegmentedTitles: resolves each window in `windows` to a
/// WindowInfo (position, title text, minimized state), writing up to
/// `windows.len` entries into `out_infos` and returning the count actually
/// written (a window is skipped rather than padded with a sentinel if its
/// live xcb_get_geometry reply fails — see the `orelse continue` below — so
/// this can be less than `windows.len`).
///
/// Title strings fetched live from X are duped into `out_owned_titles[i]`
/// (parallel to `windows`, pre-sized/zeroed by the caller) because
/// `out_infos[*].title` may point into that memory; the caller owns
/// `out_owned_titles` and is responsible for freeing its entries once done
/// reading `out_infos`.
///
/// Kept separate from drawSegmentedTitles so its scratch arrays — XCB cookie
/// buffers and per-window bool flags, several KB combined — are off the
/// stack again as soon as this function returns, rather than coexisting with
/// drawSegmentedTitles' own locals for the whole call, including its drawing
/// loop.
fn gatherWindowInfos(
    ctx: TitleRenderContext,
    snapshot: TitleSnapshot,
    allocator: std.mem.Allocator,
    windows: []const u32,
    out_infos: *[max_visible_windows]WindowInfo,
    out_owned_titles: *[max_visible_windows]?[]const u8,
) !usize {
    const win_count = windows.len;

    // Determine whether pre-fetched title/geometry data is available.
    // When titles is populated with the correct count of entries, all N title
    // round-trips are skipped here (they were already fetched in
    // captureStateIntoSlot); same for geoms and xcb_get_geometry round-trips.
    const has_prefetched_titles = snapshot.titles.len >= win_count;
    const has_prefetched_geoms = snapshot.geoms.len >= win_count;

    atoms.ensureResolved();
    const net_atom = atoms.net_wm_name;
    const utf_type = atoms.utf8AtomType();

    // XCB cookie arrays — only populated for windows whose titles are not
    // available from the pre-fetched snapshot data.
    //
    // These are left `undefined` rather than zero-filled: every slot actually
    // read below (indices `0..win_count`) is unconditionally written first by
    // the loops that follow, so the remaining `max_visible_windows - win_count`
    // slots never need initializing. Previously these were `@splat`-filled
    // across all 128 slots on every call regardless of how many windows were
    // actually visible.
    var net_wm_cookies: [max_visible_windows]xcb.xcb_get_property_cookie_t = undefined;
    var geom_cookies: [max_visible_windows]xcb.xcb_get_geometry_cookie_t = undefined;
    var needs_xcb_geometry: [max_visible_windows]bool = undefined;
    var is_minimized: [max_visible_windows]bool = undefined;
    // Tiling-cache lookup result per window, resolved once here in Phase 1
    // and reused by the "Build WindowInfo list" loop below instead of that
    // loop calling tiling.getWindowGeom(win) a second time for the same
    // window.
    var tiling_geom: [max_visible_windows]?utils.Rect = undefined;

    // Phase 1 — fire only the cookies we actually need.
    // Tiled windows: geometry comes from the tiling CacheMap (zero round-trips).
    // Pre-fetched titles: skip xcb_get_property entirely.
    for (windows, 0..) |win, i| {
        is_minimized[i] = snapshot.minimized_set.contains(win);

        if (!has_prefetched_titles) {
            if (net_atom) |na|
                net_wm_cookies[i] = xcb.xcb_get_property(ctx.conn, 0, win, na, utf_type, 0, 8192);
        }

        needs_xcb_geometry[i] = false;
        tiling_geom[i] = null;
        if (!is_minimized[i]) {
            // Tiling cache hit: geometry is already known, no round-trip needed.
            // Otherwise, prefer the pre-fetched snapshot data (captured on the
            // main thread ahead of time) over a live round-trip — this is what
            // keeps this path (including the carousel-thread drawCached call)
            // free of blocking X11 I/O for floating/untracked windows.
            tiling_geom[i] = tiling.getWindowGeom(win);
            if (tiling_geom[i] == null and !has_prefetched_geoms) {
                geom_cookies[i] = xcb.xcb_get_geometry(ctx.conn, win);
                needs_xcb_geometry[i] = true;
            }
        }
    }

    // Phase 2 — collect _NET_WM_NAME replies; queue WM_NAME fallbacks.
    var fallback_cookies: [max_visible_windows]xcb.xcb_get_property_cookie_t = undefined;
    var needs_fallback: [max_visible_windows]bool = undefined;

    if (!has_prefetched_titles) {
        for (windows, 0..) |win, i| {
            needs_fallback[i] = false;
            got: {
                if (net_atom != null) {
                    const r = xcb.xcb_get_property_reply(ctx.conn, net_wm_cookies[i], null) orelse break :got;
                    defer std.c.free(r);
                    if (try extractPropertyString(r, allocator)) |title| {
                        out_owned_titles[i] = title;
                        break :got;
                    }
                }
                fallback_cookies[i] = xcb.xcb_get_property(ctx.conn, 0, win, xcb.XCB_ATOM_WM_NAME, xcb.XCB_ATOM_STRING, 0, 8192);
                needs_fallback[i] = true;
            }
        }

        // Phase 3 — collect WM_NAME fallback replies.
        for (0..win_count) |i| {
            if (!needs_fallback[i]) continue;
            const r = xcb.xcb_get_property_reply(ctx.conn, fallback_cookies[i], null) orelse continue;
            defer std.c.free(r);
            out_owned_titles[i] = try extractPropertyString(r, allocator);
        }
    }

    // Build WindowInfo list.
    // Geometry: tiling cache → xcb_get_geometry reply → pre-fetched snapshot data → offscreen sentinel.
    var info_count: usize = 0;

    for (windows, 0..) |win, i| {
        const geom: utils.Rect = if (is_minimized[i])
            offscreen_rect
        else if (tiling_geom[i]) |cached|
            cached
        else if (needs_xcb_geometry[i]) blk: {
            const r = xcb.xcb_get_geometry_reply(ctx.conn, geom_cookies[i], null) orelse continue;
            defer std.c.free(r);
            break :blk utils.Rect{
                .x = @intCast(r.*.x),
                .y = @intCast(r.*.y),
                .width = r.*.width,
                .height = r.*.height,
            };
        } else if (has_prefetched_geoms)
            snapshot.geoms[i]
        else
            offscreen_rect;

        const title_str: []const u8 = if (has_prefetched_titles)
            snapshot.titles[i]
        else
            out_owned_titles[i] orelse "";

        out_infos[info_count] = .{
            .window = win,
            .x = geom.x,
            .y = geom.y,
            .title = title_str,
            .minimized = is_minimized[i],
        };
        info_count += 1;
    }

    return info_count;
}

/// Sort order for the split-view segment layout:
///
///   1. Non-minimized windows before minimized windows (minimized are shown
///      last/rightmost, matching their visual demotion in tiling).
///   2. On-screen windows before off-screen windows.  Windows with negative x
///      are off-screen (monocle background windows); demoting them prevents
///      artificial coordinates from overriding real spatial ordering.
///   3. Left-to-right by x, then top-to-bottom by y.  Preserves the spatial
///      order of tiled windows so each window's segment is stable across
///      focus changes.
///   4. Tie-break by window ID for deterministic ordering.
///
/// Focus is intentionally NOT a sort key.  Using focus as a tie-break would
/// cause segments to reorder when two windows share identical coordinates
/// (e.g. in a future stacking mode), making the bar jump on every focus
/// change.  The focused window is highlighted via accent colour instead.
fn compareWindows(_: void, a: WindowInfo, b: WindowInfo) bool {
    if (a.minimized != b.minimized) return !a.minimized;
    const a_offscreen = a.x < 0;
    const b_offscreen = b.x < 0;
    if (a_offscreen != b_offscreen) return !a_offscreen;
    if (a.x != b.x) return a.x < b.x;
    if (a.y != b.y) return a.y < b.y;
    return a.window < b.window;
}
