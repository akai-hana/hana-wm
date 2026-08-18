//! Title bar segment
//! Displays the focused window title on the status bar, with a split view when minimized windows are present.

const std = @import("std");

const core = @import("core");
const xcb = core.xcb;
const utils = @import("utils");
const refresh_rate = @import("refresh_rate");
const debug = @import("debug");

const constants = @import("constants");
const bench = @import("bench");

const types = @import("types");

const drawing = @import("drawing");
const carousel = @import("carousel");
const build_options = @import("build_options");
const tiling = if (build_options.has_tiling) @import("tiling") else null;

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

/// Maximum windows addressed by the batch pre-fetch scratch arrays at once.
/// `bar.captureStateIntoSlot` hands over the full workspace list, bounded by
/// `constants.Limits.MAX_TILED_WINDOWS`, larger than `max_visible_windows`,
/// as the snapshot carries a title/geometry entry per window regardless.
const max_batch_windows: usize = constants.Limits.MAX_TILED_WINDOWS;

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
/// `drawCached()`. `cached_title`/`cached_title_window` stay null on the
/// `drawCached()` path, which never updates the cache; only `draw()` passes
/// them. Folding the cache fields in avoids a separate `TitleCache` struct
/// every caller would otherwise have to construct and pass.
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
/// issues X11 property fetches.
///
/// `minimized_title` is used only in the single-window-minimized case; pass an
/// empty slice when that case can't occur (e.g. the `drawCached` fast path).
pub const TitleSnapshot = struct {
    focused_window: ?u32,
    focused_title: []const u8,
    minimized_title: []const u8,
    current_ws_wins: []const u32,
    minimized_set: *const std.AutoHashMapUnmanaged(u32, void),

    /// Pre-fetched window titles, indexed parallel to `current_ws_wins`
    /// (`titles[i]` is the title of `current_ws_wins[i]`). Empty when no
    /// pre-fetched data is available (e.g. the drawCached fast path before the
    /// title cache has multi-window data).
    titles: []const []const u8 = &.{},

    /// Pre-fetched window geometry (see `batchFetchWindowInfosInto`), indexed like
    /// `titles`. Non-blocking fallback for windows the tiling cache doesn't
    /// cover (e.g. floating), so this path, including the drawCached fast
    /// path on the carousel thread, never issues an xcb_get_geometry
    /// round-trip. Empty means no pre-fetched data; fall back to live.
    geoms: []const utils.Rect = &.{},
};

// Title width cache

/// Bounded cache of measured title text widths, indexed by window ID.
///
/// `drawSegmentedTitles` used to re-measure every visible segment on every
/// call, including the `drawCached()` fast path, which can run once per
/// carousel tick; but most segments' text doesn't change between ticks, so
/// that was wasted Pango/cairo work. Mirrors the text_w recovery
/// `carousel.drawScrollingTitle` does for the single-window case, generalised
/// to the N-window split view.
///
/// A hit requires both the window ID and the title slice's identity (pointer +
/// length) to match what was measured; anything else falls back to a fresh
/// measurement, so a stale entry costs an extra measurement, never a wrong
/// width.
const TitleWidthCache = struct {
    const Entry = struct {
        window: u32,
        title_ptr: [*]const u8,
        title_len: usize,
        width: u16,
    };

    /// Direct storage, not a hash map: bounded by `max_visible_windows` and
    /// process-lifetime, so no per-frame alloc/init cost. A linear scan is
    /// fine at realistic window counts; even the 128-window worst case is
    /// far cheaper than the Pango call it replaces.
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
        // No entry for this window: measure and store in a free slot, or
        // evict slot 0 if full (only when `max_visible_windows` are visible;
        // more misses, still correct).
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

const SortedWindowInfos = struct {
    infos: []WindowInfo,
};

/// `out_window_info_buf`/`out_owned_titles` are caller-owned storage, not
/// locals of this function: a `WindowInfo.title` in the returned slice may
/// point into `out_owned_titles`' memory, and that memory must still be
/// valid for as long as the caller keeps reading `infos` afterwards. If
/// these buffers were declared here instead, they (and everything pointing
/// into them) would dangle the instant this function returns -- freed stack
/// space the caller's *next* calls (e.g. Pango/cairo text measurement and
/// drawing) would promptly overwrite. Requiring the caller to pass them in
/// keeps them alive in the caller's own frame for as long as it needs them.
fn gatherAndSortWindowInfos(
    ctx: TitleRenderContext,
    snapshot: TitleSnapshot,
    allocator: std.mem.Allocator,
    windows: []const u32,
    win_count: usize,
    out_window_info_buf: *[max_visible_windows]WindowInfo,
    out_owned_titles: *[max_visible_windows]?[]const u8,
) !?SortedWindowInfos {
    @memset(out_owned_titles[0..win_count], null);
    const info_count = try gatherWindowInfos(ctx, snapshot, allocator, windows[0..win_count], out_window_info_buf, out_owned_titles);
    if (info_count == 0) {
        for (out_owned_titles[0..win_count]) |t| if (t) |s| allocator.free(s);
        return null;
    }
    const window_infos = out_window_info_buf[0..info_count];
    std.mem.sort(WindowInfo, window_infos, {}, compareWindows);
    return .{ .infos = window_infos };
}

/// Shared body for draw() and drawCached(). `ctx.cached_title` is non-null
/// only on the draw() path, so this works unmodified for both callers.
fn drawInner(
    ctx: TitleRenderContext,
    snapshot: TitleSnapshot,
    allocator: std.mem.Allocator,
    title_invalidated: bool,
) !u16 {
    refresh_rate.ensureRefreshRateDetected(ctx.conn);
    std.debug.assert((ctx.cached_title != null) == (ctx.cached_title_window != null));
    const window_count = snapshot.current_ws_wins.len;
    if (emptyWorkspace(ctx, window_count)) |end_x| return end_x;

    if (window_count == 1) {
        try drawSingleWindow(ctx, snapshot, allocator, title_invalidated);
    } else {
        try drawSegmentedTitles(ctx, snapshot, allocator, title_invalidated);
    }

    return ctx.start_x + ctx.width;
}

// Public API: draw entry points

/// Draw the title segment.
///
/// Updates `ctx.cached_title`/`ctx.cached_title_window` so `drawCached()` has
/// a valid slice next tick; caller must set both non-null (see
/// `TitleRenderContext`). `title_invalidated` must be true when the focused
/// window's title changed since the last draw.
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
/// Called from a fast-path redraw (focus-only or carousel tick) on the main
/// thread (scheduleFocusRedraw) or the carousel thread, serialized by
/// bar.zig's draw_mutex. Unlike `draw()`, this function:
///   - uses `snapshot.focused_title` as a read-only slice (the caller passes
///     the bar slot's cached buffer contents).
///   - never updates the title cache: `ctx.cached_title`/`cached_title_window`
///     must be left null (`draw()` keeps the cache current).
    ///   - always passes `title_invalidated = false`; it only re-renders existing
///     state.
///   - passes `minimized_title = ""` (the minimized title isn't cached by the
///     bar slot; the full `draw()` path handles it).
pub fn drawCached(
    ctx: TitleRenderContext,
    snapshot: TitleSnapshot,
    allocator: std.mem.Allocator,
) !u16 {
    return drawInner(ctx, snapshot, allocator, false);
}

// Public API: click hit-testing

/// A window resolved from a click inside the title segment, along with
/// whether it was minimized at the time of the click.
pub const ClickTarget = struct {
    window: u32,
    minimized: bool,
};

/// Resolves which window (if any) is displayed at `offset_x` pixels into the
/// title segment, relative to the segment's start_x (`click_x - ctx.start_x`,
/// in `[0, ctx.width)`).
///
/// Handles both single-window and split-view layouts: split-view replicates
/// the exact sort order and pixel-perfect tiling `drawSegmentedTitles` uses,
/// so the click resolves to whichever window's title is visually under the
/// cursor. Built from the bar's cached title state like `drawCached`/
/// `drawTitleOnly`, this makes no blocking X11 round-trip when the cache is
/// populated; a miss falls back to the same live calls `drawSegmentedTitles`
/// would make.
///
/// Returns null when the segment shows no window (empty workspace); callers
/// distinguish "clicked an empty title segment" from "clicked a window's".
pub fn hitTest(
    ctx: TitleRenderContext,
    snapshot: TitleSnapshot,
    allocator: std.mem.Allocator,
    offset_x: u16,
) !?ClickTarget {
    const windows = snapshot.current_ws_wins;
    if (windows.len == 0) return null;

    if (windows.len == 1) {
        const win = windows[0];
        return .{ .window = win, .minimized = snapshot.minimized_set.contains(win) };
    }

    if (ctx.width == 0) return null;
    const win_count = @min(windows.len, max_visible_windows);

    // Declared here (not inside gatherAndSortWindowInfos) so they stay alive
    // in this frame for the entire time `window_infos` is read below -- see
    // the comment on gatherAndSortWindowInfos.
    var window_info_buf: [max_visible_windows]WindowInfo = undefined;
    var owned_titles: [max_visible_windows]?[]const u8 = undefined;
    const sorted = (try gatherAndSortWindowInfos(ctx, snapshot, allocator, windows, win_count, &window_info_buf, &owned_titles)) orelse return null;
    defer for (owned_titles[0..win_count]) |t| if (t) |s| allocator.free(s);

    const window_infos = sorted.infos;

    const n: u32 = @intCast(window_infos.len);
    // Inverse of the pixel-perfect tiling formula drawSegmentedTitles uses
    // (x0(i) = floor(i*W/n)): floor(offset*n/W) lands in the same segment.
    const idx: usize = @intCast(@min(n - 1, @divFloor(@as(u32, offset_x) * n, @as(u32, ctx.width))));
    const info = window_infos[idx];
    return .{ .window = info.window, .minimized = info.minimized };
}

// Public API: title pre-fetch (main thread only)

/// Fetch the title of `win` into `buf`, reusing its existing capacity.
///
/// Must be called on the MAIN THREAD, used for focused and minimized windows
/// so drawing never makes blocking X11 round-trips itself.
///
/// `bar.captureStateIntoSlot` calls this once for the focused window and, when
/// the workspace has exactly one minimized window, once for it; storing the
/// results in `TitleSnapshot.focused_title`/`minimized_title`.
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

/// Collect the reply for a fired `xcb_get_geometry` request without a blocking
/// wait when the reply is already buffered (see `bench.pollReply`). In a
/// non-bench build this reduces to a single blocking reply call. Returns the
/// geometry, or null when the reply can't be read.
fn tryCollectGeometryReply(conn: *xcb.xcb_connection_t, cookie: xcb.xcb_get_geometry_cookie_t) ?utils.Rect {
    if (bench.pollReply(conn, cookie.sequence)) |rep| {
        const r: *xcb.xcb_get_geometry_reply_t = @ptrCast(@alignCast(rep));
        defer std.c.free(r);
        return geometryFromReply(r);
    }
    const r = xcb.xcb_get_geometry_reply(conn, cookie, null) orelse return null;
    defer std.c.free(r);
    return geometryFromReply(r);
}

fn geometryFromReply(r: *xcb.xcb_get_geometry_reply_t) utils.Rect {
    return .{
        .x = @intCast(r.*.x),
        .y = @intCast(r.*.y),
        .width = r.*.width,
        .height = r.*.height,
    };
}

/// Batches the X11 title/geometry requests for a workspace's windows so N
/// windows cost ~2 round-trips (plus one per window needing a `WM_NAME`
/// fallback) instead of up to 2N blocking waits: every request is fired up
/// front (Phase 1), replies are collected (Phase 2), and fallbacks resolved
/// (Phase 3). Both `batchFetchWindowInfosInto` and `gatherWindowInfos` run
/// this same fire -> collect -> assemble skeleton and differ only in how they
/// use the collected data.
///
/// `fire` skips the requests the caller already has answers for: a fully
/// pre-fetched snapshot (`has_prefetched_*`) or the focused window's
/// separately-fetched title (`focused_idx`) need no `_NET_WM_NAME`; the
/// tiling cache covers tiled geometry with zero round-trips; minimized
/// windows are never positioned on screen and get no geometry request.
const WindowDataBatch = struct {
    conn: *xcb.xcb_connection_t,
    allocator: std.mem.Allocator,
    net_atom: ?u32,
    utf_type: u32,

    /// Per-window request bookkeeping, indexed parallel to the window list.
    /// Left `undefined` rather than zero-filled: every slot read is
    /// unconditionally written by the phases below.
    net_wm_cookies: [max_batch_windows]xcb.xcb_get_property_cookie_t = undefined,
    fallback_cookies: [max_batch_windows]xcb.xcb_get_property_cookie_t = undefined,
    needs_fallback: [max_batch_windows]bool = undefined,
    geom_cookies: [max_batch_windows]xcb.xcb_get_geometry_cookie_t = undefined,
    needs_xcb_geometry: [max_batch_windows]bool = undefined,
    tiling_geoms: [max_batch_windows]?utils.Rect = undefined,

    fn init(conn: *xcb.xcb_connection_t, allocator: std.mem.Allocator) WindowDataBatch {
        atoms.ensureResolved();
        return .{
            .conn = conn,
            .allocator = allocator,
            .net_atom = atoms.net_wm_name,
            .utf_type = atoms.utf8AtomType(),
        };
    }

    /// Phase 1: fire every request up front.
    fn fire(
        self: *WindowDataBatch,
        windows: []const u32,
        focused_idx: ?usize,
        minimized: *const std.AutoHashMapUnmanaged(u32, void),
        has_prefetched_titles: bool,
        has_prefetched_geoms: bool,
    ) void {
        for (windows, 0..) |win, i| {
            // Skip the title request for windows whose title is already
            // known (pre-fetched snapshot, or the focused window's separate
            // fetch); only fire when the UTF-8 atom resolved.
            if (!has_prefetched_titles and focused_idx != i) {
                if (self.net_atom) |na| {
                    self.net_wm_cookies[i] = xcb.xcb_get_property(self.conn, 0, win, na, self.utf_type, 0, 8192);
                }
            }

            // Prefer the tiling cache; only cache-missing, non-minimized
            // windows (that aren't covered by a pre-fetched snapshot) get a
            // batched get_geometry.
            self.needs_xcb_geometry[i] = false;
            self.tiling_geoms[i] = null;
            if (!minimized.contains(win)) {
                self.tiling_geoms[i] = if (build_options.has_tiling) tiling.getWindowGeom(win) else null;
                if (self.tiling_geoms[i] == null and !has_prefetched_geoms) {
                    self.geom_cookies[i] = xcb.xcb_get_geometry(self.conn, win);
                    self.needs_xcb_geometry[i] = true;
                }
            }
        }
    }

    /// Phases 2+3: collect the fired `_NET_WM_NAME` replies, then fire and
    /// collect `WM_NAME` fallbacks for windows whose `_NET_WM_NAME` came up
    /// empty. Writes each window's title (or null) into `owned_titles[i]`;
    /// the duped strings are allocated from `self.allocator` and owned by the
    /// caller, which frees them once done reading.
    fn fetchTitles(
        self: *WindowDataBatch,
        windows: []const u32,
        focused_idx: ?usize,
        owned_titles: []?[]const u8,
    ) void {
        // Phase 2: collect _NET_WM_NAME replies; queue WM_NAME fallbacks.
        for (windows, 0..) |win, i| {
            owned_titles[i] = null;
            self.needs_fallback[i] = false;
            if (focused_idx == i) continue;
            if (self.net_atom != null)
                owned_titles[i] = collectPropertyReply(self.conn, self.net_wm_cookies[i], self.allocator);
            if (owned_titles[i] == null) {
                self.fallback_cookies[i] = xcb.xcb_get_property(self.conn, 0, win, xcb.XCB_ATOM_WM_NAME, xcb.XCB_ATOM_STRING, 0, 8192);
                self.needs_fallback[i] = true;
            }
        }

        // Phase 3: collect WM_NAME fallback replies.
        for (windows, 0..) |_, i| {
            if (focused_idx == i or !self.needs_fallback[i]) continue;
            owned_titles[i] = collectPropertyReply(self.conn, self.fallback_cookies[i], self.allocator);
        }
    }

    /// Geometry for window `i`, in preference order: off-screen sentinel for
    /// minimized windows, the tiling cache, a live `xcb_get_geometry` reply
    /// (null when that reply fails, callers skip the window), then the
    /// pre-fetched `prefetched` snapshot geometry, falling back to the
    /// off-screen sentinel.
    fn geometryFor(self: *WindowDataBatch, i: usize, minimized: bool, prefetched: ?utils.Rect) ?utils.Rect {
        if (minimized) return offscreen_rect;
        if (self.tiling_geoms[i]) |cached| return cached;
        if (self.needs_xcb_geometry[i]) return tryCollectGeometryReply(self.conn, self.geom_cookies[i]);
        return prefetched orelse offscreen_rect;
    }
};

/// Batch pre-fetch of title and geometry for every window in `wins`, writing
/// one entry per window into `out_titles`/`out_geoms` in parallel order.
/// Replaces the sequential per-window `fetchWindowTitleInto` loop in
/// `bar.captureStateIntoSlot`.
///
/// `focused_idx` is the focused window's index; its already-fetched
/// `focused_title` is duped in with no X11 traffic.
///
/// Each title dupe is owned by `out_titles`, allocated from `title_allocator`
/// (the caller's per-batch arena); freed in bulk via `WindowTitles.clear`.
pub fn batchFetchWindowInfosInto(
    conn: *xcb.xcb_connection_t,
    wins: []const u32,
    focused_idx: ?usize,
    focused_title: []const u8,
    minimized: *const std.AutoHashMapUnmanaged(u32, void),
    out_titles: *std.ArrayListUnmanaged([]const u8),
    out_geoms: *std.ArrayListUnmanaged(utils.Rect),
    title_allocator: std.mem.Allocator,
    allocator: std.mem.Allocator,
) void {
    const win_count = wins.len;
    std.debug.assert(win_count <= max_batch_windows);

    var batch = WindowDataBatch.init(conn, title_allocator);
    batch.fire(wins, focused_idx, minimized, false, false);

    // Titles are duped into the per-batch arena, owned by the caller's
    // `out_titles` and freed in bulk via `WindowTitles.clear`.
    var owned_titles: [max_batch_windows]?[]const u8 = undefined;
    batch.fetchTitles(wins, focused_idx, owned_titles[0..win_count]);

    // Assemble the parallel output lists. A missing title becomes "" so
    // `out_titles` stays index-aligned with `out_geoms` and `wins`.
    for (wins, 0..) |win, i| {
        // Duped like every other title: `focused_title` lives in the
        // snapshot's separate buffer, freed independently of window_titles,
        // an alias would dangle once that deinit's.
        const title: []const u8 = if (focused_idx == i)
            title_allocator.dupe(u8, focused_title) catch ""
        else
            owned_titles[i] orelse "";
        out_titles.append(allocator, title) catch {};

        const geom: utils.Rect = batch.geometryFor(i, minimized.contains(win), null) orelse offscreen_rect;
        out_geoms.append(allocator, geom) catch {};
    }
}

/// Collect the reply for a fired `xcb_get_property` request without a blocking
/// wait when the reply is already buffered (see `bench.pollReply`); the reply's
/// string value is duped into `allocator`. In a non-bench build this reduces to
/// a single blocking reply call.
fn collectPropertyReply(
    conn: *xcb.xcb_connection_t,
    cookie: xcb.xcb_get_property_cookie_t,
    allocator: std.mem.Allocator,
) ?[]const u8 {
    if (bench.pollReply(conn, cookie.sequence)) |rep| {
        const r: *xcb.xcb_get_property_reply_t = @ptrCast(@alignCast(rep));
        defer std.c.free(r);
        return extractPropertyString(r, allocator) catch null;
    }
    const r = xcb.xcb_get_property_reply(conn, cookie, null) orelse return null;
    defer std.c.free(r);
    return extractPropertyString(r, allocator) catch null;
}

// Empty workspace fast path

/// If `count` is zero: tears down the carousel, fills the segment background,
/// and returns the segment's end x so the caller can return immediately.
/// Returns null when there are windows present and rendering should proceed.
inline fn emptyWorkspace(ctx: TitleRenderContext, count: usize) ?u16 {
    if (count != 0) return null;
    // No windows: tear down any live carousel so it doesn't keep scrolling
    // invisibly. Runs under draw_mutex, so use the non-locking teardown;
    // deinitCarousel() would recursively re-lock (not a recursive mutex).
    carousel.deinitCarouselLocked();
    ctx.dc.fillRect(ctx.start_x, 0, ctx.width, ctx.height, ctx.config.bg);
    return ctx.start_x + ctx.width;
}

// Single-window rendering

/// Shared rendering logic for both `draw()` and `drawCached()`.
///
/// `ctx.cached_title` is non-null only on the `draw()` path (updated as a
/// side-effect); null on `drawCached()` (read-only). `title_invalidated` is
/// always false on the `drawCached()` path.
fn drawSingleWindow(
    ctx: TitleRenderContext,
    snapshot: TitleSnapshot,
    allocator: std.mem.Allocator,
    title_invalidated: bool,
) !void {
    // Free the segmented carousel: the single and segmented paths are
    // mutually exclusive. Leaving render.seg alive keeps isCarouselActive()
    // true, so the carousel thread keeps calling drawCached every tick;
    // drawCached passes minimized_title = "" (no cache for it), so the
    // single-window draw would blank the minimized title. Mirrors
    // deinitSingleCarousel() in drawSegmentedTitles.
    carousel.deinitSegmentedCarousel();

    const single_win = snapshot.current_ws_wins[0];
    const is_minimized = snapshot.minimized_set.contains(single_win);
    // `workspace_has_focus` is true when any window on this workspace is focused,
    // meaning the segment gets the accent colour rather than plain bg.
    const workspace_has_focus = snapshot.focused_window != null;

    const accent = if (is_minimized)
        ctx.config.title_minimized_accent
    else if (workspace_has_focus)
        ctx.config.title_accent_color
    else
        ctx.config.bg;
    ctx.dc.fillRect(ctx.start_x, 0, ctx.width, ctx.height, accent);

    const baseline_y = ctx.dc.baselineY(ctx.height);
    const geom = titleTextGeom(ctx, ctx.start_x, ctx.width);

    if (is_minimized) {
        // Pre-fetched on the main thread via fetchWindowTitleInto, zero X11
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

    const fg = if (workspace_has_focus) ctx.config.selected_fg else ctx.config.fg;
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

/// Pixel-perfect tiling: segment i of `count` spans [i*W/count, (i+1)*W/count).
/// Returns a zero width when the final division collapses the segment away.
fn segmentBounds(total_width: u16, i: usize, count: u32) struct { x: u16, w: u16 } {
    const x0: u16 = @intCast(@divFloor(@as(u32, @intCast(i)) * total_width, count));
    const x1: u16 = @intCast(@divFloor(@as(u32, @intCast(i + 1)) * total_width, count));
    return .{ .x = x0, .w = x1 - x0 };
}

/// Accent colour for a title segment: focused wins, then minimized, then the
/// unfocused fallback.
inline fn accentFor(config: types.BarConfig, is_focused: bool, is_minimized: bool) u32 {
    return if (is_focused)
        config.title_accent_color
    else if (is_minimized)
        config.title_minimized_accent
    else
        config.title_unfocused_accent;
}

/// Computes the text geometry for a `seg_w`-wide title box starting at `seg_x`:
/// the text x-offset honors the segment padding plus the title lead-in, and the
/// available width uses saturating arithmetic (guarding against a u16 wrap from
/// extreme padding values before the saturating subtraction).
fn titleTextGeom(ctx: TitleRenderContext, seg_x: u16, seg_w: u16) carousel.SegmentGeometry {
    const scaled_padding = ctx.config.scaledSegmentPadding(ctx.height);
    return .{
        .seg_x = seg_x,
        .seg_w = seg_w,
        .text_x = seg_x + scaled_padding + title_lead_px,
        .avail_w = seg_w -| scaled_padding *| 2 -| title_lead_px,
    };
}

/// Renders one segment's title text: scrolls it across the full segment bounds
/// when the focused window has the carousel enabled (drawSegmentedCarousel
/// returns false exactly when the text fits), otherwise draws it plainly or
/// ellipsized to the available width.
fn drawSegmentTitle(
    ctx: TitleRenderContext,
    baseline_y: u16,
    geom: carousel.SegmentGeometry,
    text_w: u16,
    window: u32,
    title: []const u8,
    accent: u32,
    text_fg: u32,
    is_focused: bool,
    title_invalidated: bool,
) !void {
    if (is_focused and carousel.isCarouselEnabled()) {
        if (try carousel.drawSegmentedCarousel(ctx.dc, baseline_y, geom, text_w, title, accent, text_fg, window, title_invalidated)) return;
    }
    // Text fits (or carousel disabled / not focused): ellipsis on overflow.
    if (text_w <= geom.avail_w)
        try ctx.dc.drawText(geom.text_x, baseline_y, title, text_fg)
    else
        try ctx.dc.drawTextEllipsis(geom.text_x, baseline_y, title, geom.avail_w, text_fg);
}

/// Renders one title segment per window in a horizontal split-view layout.
/// Windows are sorted spatially so each segment position is stable across focus changes.
fn drawSegmentedTitles(
    ctx: TitleRenderContext,
    snapshot: TitleSnapshot,
    allocator: std.mem.Allocator,
    title_invalidated: bool,
) !void {
    const windows = snapshot.current_ws_wins;
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

    // `window_info_buf`/`owned_titles` must outlive the loop below -- a
    // WindowInfo's `.title` may point into `owned_titles`' memory, and the
    // loop's Pango/cairo calls (widthFor, drawSegmentTitle) have plenty of
    // stack depth of their own. So they're declared here, in the same frame
    // as the loop that reads them, rather than inside
    // gatherAndSortWindowInfos: that function's own scratch (XCB cookies,
    // bool flags, several KB) is reclaimed when it returns, but these two
    // buffers must not be -- passing them in as out-params keeps them alive
    // in *this* frame instead of a callee frame that's already gone by the
    // time the loop runs.
    var window_info_buf: [max_visible_windows]WindowInfo = undefined;
    var owned_titles: [max_visible_windows]?[]const u8 = undefined;
    const sorted = (try gatherAndSortWindowInfos(ctx, snapshot, allocator, windows, win_count, &window_info_buf, &owned_titles)) orelse return;
    defer for (owned_titles[0..win_count]) |t| if (t) |s| allocator.free(s);

    const window_infos = sorted.infos;

    const window_count: u32 = @intCast(window_infos.len);
    const baseline_y = ctx.dc.baselineY(ctx.height);

    for (window_infos, 0..) |info, i| {
        const bounds = segmentBounds(ctx.width, i, window_count);
        if (bounds.w == 0) continue;
        const segment_x = ctx.start_x + bounds.x;

        const is_focused_win = snapshot.focused_window == info.window;
        const accent = accentFor(ctx.config, is_focused_win, info.minimized);
        ctx.dc.fillRect(segment_x, 0, bounds.w, ctx.height, accent);

        if (info.title.len == 0 or bounds.w <= ctx.config.scaledSegmentPadding(ctx.height) *| 2) continue;

        const text_fg = if (is_focused_win) ctx.config.selected_fg else ctx.config.fg;
        try drawSegmentTitle(
            ctx,
            baseline_y,
            titleTextGeom(ctx, segment_x, bounds.w),
            title_width_cache.widthFor(ctx.dc, info.window, info.title),
            info.window,
            info.title,
            accent,
            text_fg,
            is_focused_win,
            title_invalidated,
        );
    }
}

/// Phase 1-3 of drawSegmentedTitles: resolves each window in `windows` to a
/// WindowInfo (position, title, minimized state), writing up to `windows.len`
/// entries into `out_infos` and returning the count written. A window is
/// skipped (not padded) if its live xcb_get_geometry reply fails, see the
/// `orelse continue` below, so the count can be less than `windows.len`.
///
/// Live-fetched title strings are duped into `out_owned_titles[i]` (parallel
/// to `windows`, pre-sized by the caller) because `out_infos[*].title` may
/// point into that memory; the caller frees its entries once done reading
/// `out_infos`.
///
/// Kept separate from drawSegmentedTitles so its scratch arrays (XCB cookies,
/// per-window bool flags, several KB) leave the stack as soon as it returns,
/// rather than coexisting with drawSegmentedTitles' locals for the whole call.
fn gatherWindowInfos(
    ctx: TitleRenderContext,
    snapshot: TitleSnapshot,
    allocator: std.mem.Allocator,
    windows: []const u32,
    out_infos: *[max_visible_windows]WindowInfo,
    out_owned_titles: *[max_visible_windows]?[]const u8,
) !usize {
    const win_count = windows.len;

    // When the snapshot carries a title/geometry entry for every window, all
    // N round-trips were already done in captureStateIntoSlot and are skipped.
    const has_prefetched_titles = snapshot.titles.len >= win_count;
    const has_prefetched_geoms = snapshot.geoms.len >= win_count;

    var batch = WindowDataBatch.init(ctx.conn, allocator);
    batch.fire(windows, null, snapshot.minimized_set, has_prefetched_titles, has_prefetched_geoms);
    // Live-fetched titles are duped into the caller's `out_owned_titles`,
    // which it frees once done reading `out_infos`.
    if (!has_prefetched_titles)
        batch.fetchTitles(windows, null, out_owned_titles[0..win_count]);

    // Build the WindowInfo list, skipping windows whose live geometry reply
    // failed, their info is dropped, not padded.
    var info_count: usize = 0;
    for (windows, 0..) |win, i| {
        const is_minimized = snapshot.minimized_set.contains(win);
        const geom = batch.geometryFor(i, is_minimized, if (has_prefetched_geoms) snapshot.geoms[i] else null) orelse continue;

        const title_str: []const u8 = if (has_prefetched_titles)
            snapshot.titles[i]
        else
            out_owned_titles[i] orelse "";

        out_infos[info_count] = .{
            .window = win,
            .x = geom.x,
            .y = geom.y,
            .title = title_str,
            .minimized = is_minimized,
        };
        info_count += 1;
    }

    return info_count;
}

/// Sort order for the split-view segment layout:
///
///   1. Non-minimized windows first (minimized shown last/rightmost, matching
///      their visual demotion in tiling).
///   2. On-screen before off-screen.  Negative-x windows (monocle background)
///      are off-screen; demoting them stops artificial coordinates overriding
///      real spatial ordering.
///   3. Left-to-right by x, then top-to-bottom by y, keeps each window's
///      segment stable across focus changes.
///   4. Tie-break by window ID for deterministic ordering.
///
/// Focus is intentionally NOT a sort key: using it as a tie-break would
/// reorder segments when two windows share coordinates, making the bar jump
/// on focus changes. The focused window is highlighted via accent colour.
fn compareWindows(_: void, a: WindowInfo, b: WindowInfo) bool {
    if (a.minimized != b.minimized) return !a.minimized;
    const a_offscreen = a.x < 0;
    const b_offscreen = b.x < 0;
    if (a_offscreen != b_offscreen) return !a_offscreen;
    if (a.x != b.x) return a.x < b.x;
    if (a.y != b.y) return a.y < b.y;
    return a.window < b.window;
}
