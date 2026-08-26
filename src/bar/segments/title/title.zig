//! Title bar segment
//! Displays the focused window title on the status bar, with a split view when minimized windows are present.

const std = @import("std");

const core = @import("core");
const xcb = core.xcb;
const utils = @import("utils");
const refresh_rate = @import("refresh_rate");
const debug = @import("debug");

const constants = @import("constants");
// x11wire's reply collectors are reached through utils' re-exports: Zig
// forbids a file belonging to two modules at once, so only utils may
// @import("x11wire.zig") directly.

const types = @import("types");

const drawing = @import("drawing");
const carousel = @import("carousel");
const build_options = @import("build_options");
const wincache = @import("wincache");
const sync = @import("sync");
const pipeline = @import("pipeline");

/// D3: minimum reserved row width for the title segment (moved here from
/// bar.zig — width policy belongs to the segment that owns the pixels).
pub const min_width: u16 = 100;

const SegmentGeometry = struct {
    seg_x: u16,
    seg_w: u16,
    text_x: u16,
    avail_w: u16,
};

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
/// `constants.Limits.max_tiled_windows`, larger than `max_visible_windows`,
/// as the snapshot carries a title/geometry entry per window regardless.
const max_batch_windows: usize = constants.Limits.max_tiled_windows;

/// Off-screen sentinel geometry for minimized or otherwise unresolvable
/// windows: position sorting places it last, and drawing is skipped.
pub const offscreen_rect: utils.Rect = .{ .x = std.math.maxInt(i16), .y = std.math.maxInt(i16), .width = 0, .height = 0 };

const Atoms = struct {
    /// null until successfully resolved, to avoid XCB_ATOM_NONE's sentinel (0).
    net_wm_name: ?u32 = null,
    utf8_string: ?u32 = null,
    is_initialized: bool = false,

    /// Subsequent calls are a no-op after the first successful resolution.
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

const WindowInfo = struct {
    window: u32,
    x: i16,
    y: i16,
    title: []const u8,
    minimized: bool,
};

/// Stable per-call rendering context: geometry, draw state, connection, and
/// the bar slot's title cache.
///
/// Constructed once per bar frame and shared by every draw entry point
/// (`draw()`, `hitTest()`). Folding the cache fields in avoids a separate
/// `TitleCache` struct every caller would otherwise have to construct and
/// pass.
pub const TitleRenderContext = struct {
    dc: *drawing.DrawContext,
    config: types.BarConfig,
    height: u16,
    start_x: u16,
    width: u16,
    conn: core.Connection,

    /// Backing buffer updated by `draw()` on each full render; the bar passes
    /// its contents as `snapshot.focused_title` on subsequent frames.
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
/// empty slice when that case can't occur.
pub const TitleSnapshot = struct {
    focused_window: ?u32,
    focused_title: []const u8,
    minimized_title: []const u8,
    current_ws_wins: []const u32,
    minimized_set: *const std.AutoHashMapUnmanaged(u32, void),

    /// Pre-fetched window titles, indexed parallel to `current_ws_wins`
    /// (`titles[i]` is the title of `current_ws_wins[i]`). Empty when no
    /// pre-fetched data is available (e.g. before the title cache has
    /// multi-window data).
    titles: []const []const u8 = &.{},

    /// Pre-fetched window geometry (see `fetchTitlesAndGeoms`), indexed like
    /// `titles`. Null means "no geometry known". The bar's refetch replaces
    /// failed live replies with the off-screen sentinel before publishing, so
    /// entries coming from there are always concrete. Empty means no
    /// pre-fetched data; fall back to live requests.
    geoms: []const ?utils.Rect = &.{},
};

/// Bounded cache of measured title text widths, indexed by window ID.
///
/// `drawSegmentedTitles` used to re-measure every visible segment on every
/// call; but most segments' text doesn't change between frames, so that was
/// wasted Pango/cairo work.
/// Mirrors the text width recovery pattern, generalised to the N-window
/// split view.
///
/// A hit requires both the window ID and the title slice's identity (pointer +
/// length) to match what was measured; anything else falls back to a fresh
/// measurement, so a stale entry costs an extra measurement, never a wrong
/// width.
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

/// `out_window_info_buf`/`out_data` are caller-owned storage, not locals of
/// this function: a `WindowInfo.title` in the returned slice may point into
/// `out_data.titles`' memory, and that memory must still be valid for as long
/// as the caller keeps reading `infos` afterwards. If these buffers were
/// declared here instead, they (and everything pointing into them) would
/// dangle the instant this function returns -- freed stack space the caller's
/// *next* calls (e.g. Pango/cairo text measurement and drawing) would promptly
/// overwrite. Requiring the caller to pass them in keeps them alive in the
/// caller's own frame for as long as it needs them.
fn gatherAndSortWindowInfos(
    ctx: TitleRenderContext,
    snapshot: TitleSnapshot,
    allocator: std.mem.Allocator,
    windows: []const u32,
    win_count: usize,
    out_window_info_buf: *[max_visible_windows]WindowInfo,
    out_data: FetchedWindows,
) !?[]WindowInfo {
    const info_count = try gatherWindowInfos(ctx, snapshot, allocator, windows, win_count, out_window_info_buf, out_data);
    if (info_count == 0) return null;
    const window_infos = out_window_info_buf[0..info_count];
    std.mem.sort(WindowInfo, window_infos, {}, compareWindows);
    return window_infos;
}

/// Caller-frame scratch for the gather phase, shared verbatim by hitTest and
/// drawSegmentedTitles: the buffer trio plus its memset/free bookkeeping,
/// which both entry points used to carry as duplicated locals.
///
/// The struct must be declared in the frame that keeps READING the returned
/// infos slice: a WindowInfo's `.title` may point into `titles`' memory, and
/// the callers' Pango/cairo work (width measurement, drawFittedTitle) runs
/// long after gather() returns -- so these arrays live in the *caller's*
/// frame, not inside a callee whose stack dies at return (same reasoning as
/// gatherWindowInfos' out-param note above).
const GatherScratch = struct {
    window_infos: [max_visible_windows]WindowInfo = undefined,
    titles: [max_visible_windows][]const u8 = undefined,
    geoms: [max_visible_windows]?utils.Rect = undefined,

    /// Blanks the title slots and runs the gather + spatial sort into `self`.
    fn gather(
        self: *GatherScratch,
        ctx: TitleRenderContext,
        snapshot: TitleSnapshot,
        allocator: std.mem.Allocator,
        windows: []const u32,
        win_count: usize,
    ) !?[]WindowInfo {
        @memset(self.titles[0..win_count], "");
        return gatherAndSortWindowInfos(
            ctx,
            snapshot,
            allocator,
            windows,
            win_count,
            &self.window_infos,
            .{ .titles = self.titles[0..win_count], .geoms = self.geoms[0..win_count] },
        );
    }

    /// Frees freshly-duped title entries once the caller is done reading
    /// (per-slot no-op when the snapshot owned them). Pair with gather()
    /// through the caller's defer.
    fn freeBorrowedTitles(self: *GatherScratch, snapshot: TitleSnapshot, win_count: usize, allocator: std.mem.Allocator) void {
        if (!titlesNeedFree(snapshot, win_count)) return;
        for (self.titles[0..win_count]) |t| allocator.free(t);
    }
};

/// Shared body of all draw entry points.
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
        try drawSegmentedTitles(ctx, snapshot, allocator);
    }

    return ctx.start_x + ctx.width;
}

/// Draw the title segment.
///
/// Updates `ctx.cached_title`/`ctx.cached_title_window` so the next frame has
/// a valid slice; caller must set both non-null (see `TitleRenderContext`).
/// `title_invalidated` must be true when the focused window's title changed
/// since the last draw.
pub fn draw(
    ctx: TitleRenderContext,
    snapshot: TitleSnapshot,
    allocator: std.mem.Allocator,
    title_invalidated: bool,
) !u16 {
    return drawInner(ctx, snapshot, allocator, title_invalidated);
}

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
/// cursor. Built from the bar's cached title state like the draw path,
/// this makes no blocking X11 round-trip when the cache is populated; a miss
/// falls back to the same live calls `drawSegmentedTitles` would make.
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

    var scratch: GatherScratch = .{};
    defer scratch.freeBorrowedTitles(snapshot, win_count, allocator);
    const sorted = (try scratch.gather(ctx, snapshot, allocator, windows, win_count)) orelse return null;

    const window_infos = sorted;

    const n: u32 = @intCast(window_infos.len);
    // Inverse of the pixel-perfect tiling formula drawSegmentedTitles uses
    // (x0(i) = floor(i*W/n)): floor(offset*n/W) lands in the same segment.
    const idx: usize = @intCast(@min(n - 1, @divFloor(@as(u32, offset_x) * n, @as(u32, ctx.width))));
    const info = window_infos[idx];
    return .{ .window = info.window, .minimized = info.minimized };
}

/// Fetch the title of `win` into `buf`, reusing its existing capacity.
///
/// Must be called on the MAIN THREAD, used for focused and minimized windows
/// so drawing never makes blocking X11 round-trips itself.
///
/// `bar.refreshTitleData` calls this for the focused window whenever focus
/// moved (or a redraw was forced); the split-view path gets its titles via
/// `fetchTitlesAndGeoms` instead.
pub fn fetchWindowTitleInto(
    conn: core.Connection,
    win: u32,
    buf: *std.ArrayListUnmanaged(u8),
    allocator: std.mem.Allocator,
) !void {
    atoms.ensureResolved();
    const utf_type = atoms.utf8AtomType();
    var stack_buf: [1024]u8 = undefined;

    if (atoms.net_wm_name) |na| {
        if (utils.fetchPropertyToBuffer(conn, win, na, utf_type, &stack_buf) catch null) |t| {
            if (t.len > 0) {
                buf.clearRetainingCapacity();
                try buf.appendSlice(allocator, t);
                return;
            }
        }
    }
    if (utils.fetchPropertyToBuffer(
        conn,
        win,
        xcb.XCB_ATOM_WM_NAME,
        xcb.XCB_ATOM_STRING,
        &stack_buf,
    ) catch null) |t| {
        buf.clearRetainingCapacity();
        try buf.appendSlice(allocator, t);
    }
}

/// Collect a fired `xcb_get_geometry` request's reply via x11wire's
/// poll-first collector (no blocking wait when the reply is already
/// buffered). Returns the geometry, or null when the reply can't be read.
fn tryCollectGeometryReply(conn: core.Connection, cookie: xcb.xcb_get_geometry_cookie_t) ?utils.Rect {
    const r = utils.collectGeometryReply(conn, cookie) orelse return null;
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
/// (Phase 3). `fetchTitlesAndGeoms` drives this batch; the fire -> collect ->
/// assemble skeleton lives there.
///
/// `fire` skips the requests the caller already has answers for: a fully
/// pre-fetched snapshot (`has_prefetched_*`) needs no `_NET_WM_NAME`; the
/// tiling cache covers tiled geometry with zero round-trips; minimized
/// windows are never positioned on screen and get no geometry request.
const WindowDataBatch = struct {
    conn: core.Connection,
    allocator: std.mem.Allocator,
    net_atom: ?u32,
    utf_type: u32,

    /// Per-window request bookkeeping, indexed parallel to the window list.
    net_wm_cookies: [max_batch_windows]xcb.xcb_get_property_cookie_t = undefined,
    fallback_cookies: [max_batch_windows]xcb.xcb_get_property_cookie_t = undefined,
    needs_fallback: [max_batch_windows]bool = undefined,
    geom_cookies: [max_batch_windows]xcb.xcb_get_geometry_cookie_t = undefined,
    needs_xcb_geometry: [max_batch_windows]bool = undefined,
    tiling_geoms: [max_batch_windows]?utils.Rect = undefined,

    fn init(conn: core.Connection, allocator: std.mem.Allocator) WindowDataBatch {
        atoms.ensureResolved();
        return .{
            .conn = conn,
            .allocator = allocator,
            .net_atom = atoms.net_wm_name,
            .utf_type = atoms.utf8AtomType(),
        };
    }

    /// Fire every request up front.
    fn fire(
        self: *WindowDataBatch,
        windows: []const u32,
        minimized: *const std.AutoHashMapUnmanaged(u32, void),
        has_prefetched_titles: bool,
        has_prefetched_geoms: bool,
    ) void {
        for (windows, 0..) |win, i| {
            // Skip the title request for windows whose title is already
            // known (pre-fetched snapshot); only fire when the UTF-8 atom
            // resolved.
            if (!has_prefetched_titles) {
                if (self.net_atom) |na| {
                    self.net_wm_cookies[i] = xcb.xcb_get_property(self.conn, 0, win, na, self.utf_type, 0, 8192);
                }
            }

            // Geometry truth from model/sync; only cache-missing,
            // non-minimized windows (that aren't covered by a pre-fetched
            // snapshot) get a batched get_geometry.
            self.needs_xcb_geometry[i] = false;
            self.tiling_geoms[i] = null;
            if (!minimized.contains(win)) {
                // LAYERING NOTE: The title segment queries sync.truthRect() to get the
            // canonical geometry for window sorting. This is a deliberate layering
            // inversion — bar segments are read-path UI but need write-path truth data.
            // The alternative (passing geometry through the bar's frame snapshot) would
            // require plumbing geometry through 3 abstraction layers for no benefit.
            self.tiling_geoms[i] = sync.truthRect(pipeline.model(), win);
                if (self.tiling_geoms[i] == null and !has_prefetched_geoms) {
                    self.geom_cookies[i] = xcb.xcb_get_geometry(self.conn, win);
                    self.needs_xcb_geometry[i] = true;
                }
            }
        }
    }

    /// Collect the fired `_NET_WM_NAME` replies, then fire and collect
    /// `WM_NAME` fallbacks for windows whose `_NET_WM_NAME` came up empty.
    /// Writes each window's title (or null) into `owned_titles[i]`; the
    /// duped strings are allocated from `self.allocator` and owned by the
    /// caller, which frees them once done reading.
    fn fetchTitles(
        self: *WindowDataBatch,
        windows: []const u32,
        owned_titles: []?[]const u8,
    ) void {
        // Collect _NET_WM_NAME replies; queue WM_NAME fallbacks.
        for (windows, 0..) |win, i| {
            owned_titles[i] = null;
            self.needs_fallback[i] = false;
            if (self.net_atom != null)
                owned_titles[i] = collectPropertyReply(self.conn, self.net_wm_cookies[i], self.allocator);
            if (owned_titles[i] == null) {
                self.fallback_cookies[i] = xcb.xcb_get_property(self.conn, 0, win, xcb.XCB_ATOM_WM_NAME, xcb.XCB_ATOM_STRING, 0, 8192);
                self.needs_fallback[i] = true;
            }
        }

        // Collect WM_NAME fallback replies.
        for (windows, 0..) |_, i| {
            if (!self.needs_fallback[i]) continue;
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

/// Borrowed per-window answers a caller may already hold (from a previous
/// batched fetch). Either slice covers the whole window list or neither is
/// used -- there is no per-window mixing of prefetched and live data.
pub const Prefetch = struct {
    titles: ?[]const []const u8 = null,
    geoms: ?[]const ?utils.Rect = null,
};

/// Caller-sized output buffers for `fetchTitlesAndGeoms`, one entry per
/// window in parallel order.
pub const FetchedWindows = struct {
    /// "" where no title could be read. Entries are dupes from
    /// `title_allocator` unless `Prefetch.titles` covered them (then they're
    /// borrowed and must not be freed).
    titles: [][]const u8,
    /// Off-screen sentinel for minimized windows, then tiling cache, then a
    /// live `xcb_get_geometry` reply; null ONLY when that reply failed
    /// (callers decide: skip the window vs pad with the sentinel).
    geoms: []?utils.Rect,
};

/// The one title/geometry fetch pipeline. Batches the X11 requests for a
/// workspace's windows so N windows cost ~2 round-trips (plus one per window
/// needing a `WM_NAME` fallback) instead of up to 2N blocking waits: every
/// request is fired up front (Phase 1), replies are collected (Phase 2), and
/// fallbacks resolved (Phase 3).
///
/// `prefetch` skips requests the caller already has answers for: a fully
/// covered snapshot needs no `_NET_WM_NAME`/geometry traffic at all; the
/// tiling cache covers tiled geometry with zero round-trips; minimized
/// windows are never positioned on screen and get no geometry request.
///
/// Title dupes are owned by `title_allocator`: the bar's refetch passes its
/// arena (freed in bulk by the next reset); read-only callers pass their own
/// allocator and free each non-borrowed entry once done reading.
pub fn fetchTitlesAndGeoms(
    conn: core.Connection,
    wins: []const u32,
    minimized: *const std.AutoHashMapUnmanaged(u32, void),
    prefetch: Prefetch,
    out: FetchedWindows,
    title_allocator: std.mem.Allocator,
) void {
    const win_count = wins.len;
    std.debug.assert(win_count <= max_batch_windows);
    std.debug.assert(out.titles.len >= win_count and out.geoms.len >= win_count);

    // Prefetch covers either the whole window list or none of it.
    const has_titles = if (prefetch.titles) |p| p.len >= win_count else false;
    const has_geoms = if (prefetch.geoms) |p| p.len >= win_count else false;

    var batch = WindowDataBatch.init(conn, title_allocator);
    batch.fire(wins, minimized, has_titles, has_geoms);

    var owned: [max_batch_windows]?[]const u8 = undefined;
    if (!has_titles)
        batch.fetchTitles(wins, owned[0..win_count]);

    for (wins, 0..) |win, i| {
        out.titles[i] = if (has_titles)
            prefetch.titles.?[i]
        else
            (owned[i] orelse "");
        out.geoms[i] = batch.geometryFor(
            i,
            minimized.contains(win),
            if (has_geoms) prefetch.geoms.?[i] else null,
        );
    }
}

/// Collect a fired `xcb_get_property` request's reply via x11wire's
/// poll-first collector (no blocking wait when the reply is already
/// buffered); the reply's string value is duped into `allocator`.
fn collectPropertyReply(
    conn: core.Connection,
    cookie: xcb.xcb_get_property_cookie_t,
    allocator: std.mem.Allocator,
) ?[]const u8 {
    const r = utils.collectPropertyReply(conn, cookie) orelse return null;
    defer std.c.free(r);
    return extractPropertyString(r, allocator) catch null;
}

/// If `count` is zero: fills the segment background and returns the
/// segment's end x so the caller can return immediately.
/// Returns null when there are windows present and rendering should proceed.
inline fn emptyWorkspace(ctx: TitleRenderContext, count: usize) ?u16 {
    if (count != 0) return null;
    ctx.dc.fillRect(ctx.start_x, 0, ctx.width, ctx.height, ctx.config.bg);
    return ctx.start_x + ctx.width;
}

/// Shared rendering logic for the single-window case.
///
/// `ctx.cached_title` is non-null on the bar's normal draw path (updated as a
/// side-effect); null callers are read-only.
fn drawSingleWindow(
    ctx: TitleRenderContext,
    snapshot: TitleSnapshot,
    allocator: std.mem.Allocator,
    title_invalidated: bool,
) !void {
    const single_win = snapshot.current_ws_wins[0];
    const is_minimized = snapshot.minimized_set.contains(single_win);
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
        // Same fit-or-truncate placement as every other cell, with scrolling
        // disabled: minimized cells never marquee (see drawFittedTitle).
        if (snapshot.minimized_title.len > 0)
            try drawFittedTitle(
                ctx,
                baseline_y,
                geom,
                single_win,
                snapshot.minimized_title,
                ctx.dc.measureTextWidth(snapshot.minimized_title),
                ctx.config.fg,
                false,
            );
        return;
    }

    if (snapshot.focused_title.len == 0) return;

    // Update the bar slot's title cache for the next frame.
    // Only callers with cache fields set participate.
    if (ctx.cached_title) |buf| {
        const window_slot = ctx.cached_title_window.?;
        if (title_invalidated or window_slot.* != snapshot.focused_window) {
            buf.clearRetainingCapacity();
            buf.appendSlice(allocator, snapshot.focused_title) catch {};
            window_slot.* = snapshot.focused_window;
        }
    }

    const fg = if (workspace_has_focus) ctx.config.selected_fg else ctx.config.fg;
    try drawFittedTitle(
        ctx,
        baseline_y,
        geom,
        single_win,
        snapshot.focused_title,
        ctx.dc.measureTextWidth(snapshot.focused_title),
        fg,
        workspace_has_focus,
    );
}

/// Draws the focused window's overflowing title as a marquee cell: scrolled
/// copies when the carousel is enabled (see carousel.zig), ellipsis
/// truncation otherwise. Unfocused and minimized cells never scroll.
///
/// The scroll runs edge-to-edge across the WHOLE segment box (no padding
/// indent): the clip is the cell itself, so text slides fully out of one
/// edge while re-entering at the other.
fn drawMarqueeCell(
    ctx: TitleRenderContext,
    baseline_y: u16,
    geom: SegmentGeometry,
    win: u32,
    txt: []const u8,
    text_w: u16,
    fg: u32,
) !void {
    const off = carousel.offsetFor(
        win,
        txt,
        text_w,
        geom.avail_w,
        ctx.config.carousel_enabled,
        ctx.config.carousel_speed_px_s,
        nowMs(),
    );
    if (!carousel.scrollingActive()) {
        try ctx.dc.drawTextEllipsis(geom.text_x, baseline_y, txt, geom.avail_w, fg);
        return;
    }
    const cycle: f32 = @as(f32, @floatFromInt(text_w)) + @as(f32, carousel.gap_px);
    const x0: f64 = @as(f64, @floatFromInt(geom.seg_x)) - off;
    try ctx.dc.drawTextScrolled(geom.seg_x, geom.seg_w, baseline_y, .{ x0, x0 + cycle }, txt, fg);
}

fn nowMs() i64 {
    return @intCast(utils.monotonicNs() / std.time.ns_per_ms);
}

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
fn titleTextGeom(ctx: TitleRenderContext, seg_x: u16, seg_w: u16) SegmentGeometry {
    const scaled_padding = ctx.config.scaledSegmentPadding(ctx.height);
    return .{
        .seg_x = seg_x,
        .seg_w = seg_w,
        .text_x = seg_x + scaled_padding + title_lead_px,
        .avail_w = seg_w -| scaled_padding *| 2 -| title_lead_px,
    };
}

/// Shared fit-or-truncate text placement, used by both draw entry points:
/// draws statically when the text fits; otherwise the focused cell scrolls
/// (marquee, when enabled — `scroll_enabled`) and every other cell truncates
/// with an ellipsis.
fn drawFittedTitle(
    ctx: TitleRenderContext,
    baseline_y: u16,
    geom: SegmentGeometry,
    window: u32,
    title: []const u8,
    text_w: u16,
    text_fg: u32,
    scroll_enabled: bool,
) !void {
    if (text_w <= geom.avail_w)
        try ctx.dc.drawText(geom.text_x, baseline_y, title, text_fg)
    else if (scroll_enabled)
        try drawMarqueeCell(ctx, baseline_y, geom, window, title, text_w, text_fg)
    else
        try ctx.dc.drawTextEllipsis(geom.text_x, baseline_y, title, geom.avail_w, text_fg);
}

/// Renders one title segment per window in a horizontal split-view layout.
/// Windows are sorted spatially so each segment position is stable across focus changes.
fn drawSegmentedTitles(
    ctx: TitleRenderContext,
    snapshot: TitleSnapshot,
    allocator: std.mem.Allocator,
) !void {
    const windows = snapshot.current_ws_wins;
    if (windows.len > max_visible_windows)
        debug.warn("Workspace has {} windows; only the first {} are rendered in split-view", .{ windows.len, max_visible_windows });
    const win_count = @min(windows.len, max_visible_windows);

    // The gather scratch must outlive the loop below -- a WindowInfo's
    // `.title` may point into `scratch.titles`' memory, and the loop's
    // Pango/cairo calls (width measurement, drawFittedTitle) have plenty of
    // stack depth of their own. So it's declared here, in the same frame
    // as the loop that reads them, rather than inside gatherWindowInfos:
    // that function's own scratch (XCB cookies, bool flags, several KB) is
    // reclaimed when it returns, but these buffers must not be -- see the
    // lifetime note on GatherScratch.
    var scratch: GatherScratch = .{};
    defer scratch.freeBorrowedTitles(snapshot, win_count, allocator);
    const sorted = (try scratch.gather(ctx, snapshot, allocator, windows, win_count)) orelse return;

    const window_infos = sorted;

    const window_count: u32 = @intCast(window_infos.len);
    const baseline_y = ctx.dc.baselineY(ctx.height);
    // Loop-invariant: same config/height every iteration.
    const min_cell_w = ctx.config.scaledSegmentPadding(ctx.height) *| 2;

    for (window_infos, 0..) |info, i| {
        const bounds = segmentBounds(ctx.width, i, window_count);
        if (bounds.w == 0) continue;
        const segment_x = ctx.start_x + bounds.x;

        const is_focused_win = snapshot.focused_window == info.window;
        const accent = accentFor(ctx.config, is_focused_win, info.minimized);
        ctx.dc.fillRect(segment_x, 0, bounds.w, ctx.height, accent);

        if (info.title.len == 0 or bounds.w <= min_cell_w) continue;

        const text_fg = if (is_focused_win) ctx.config.selected_fg else ctx.config.fg;
        try drawFittedTitle(
            ctx,
            baseline_y,
            titleTextGeom(ctx, segment_x, bounds.w),
            info.window,
            info.title,
            ctx.dc.measureTextWidth(info.title),
            text_fg,
            is_focused_win,
        );
    }
}

/// Phase 1-3 of drawSegmentedTitles: resolves each window in `windows` to a
/// WindowInfo (position, title, minimized state), writing up to `windows.len`
/// entries into `out_infos` and returning the count written. A window is
/// skipped (not padded) if its live xcb_get_geometry reply failed, see the
/// `orelse continue` below, so the count can be less than `windows.len`.
///
/// All title/geometry X11 traffic goes through `fetchTitlesAndGeoms`. When
/// the snapshot carries a title/geometry entry for every window (the bar's
/// refetch ran this frame), that call issues no requests at all.
///
/// Builds per-window render info from XCB replies. Title strings are borrowed
/// from the snapshot when available, otherwise duped from `allocator` — the
/// caller frees non-borrowed entries once done with `out_infos`. Separated
/// from drawSegmentedTitles to keep scratch arrays off the draw path.
fn gatherWindowInfos(
    ctx: TitleRenderContext,
    snapshot: TitleSnapshot,
    allocator: std.mem.Allocator,
    windows: []const u32,
    win_count: usize,
    out_infos: *[max_visible_windows]WindowInfo,
    out_data: FetchedWindows,
) !usize {
    fetchTitlesAndGeoms(
        ctx.conn,
        windows[0..win_count],
        snapshot.minimized_set,
        .{ .titles = snapshot.titles, .geoms = snapshot.geoms },
        out_data,
        allocator,
    );

    // Build the WindowInfo list, skipping windows whose live geometry reply
    // failed -- their info is dropped, not padded.
    var info_count: usize = 0;
    for (windows, 0..) |win, i| {
        const geom = out_data.geoms[i] orelse continue;
        out_infos[info_count] = .{
            .window = win,
            .x = geom.x,
            .y = geom.y,
            .title = out_data.titles[i],
            .minimized = snapshot.minimized_set.contains(win),
        };
        info_count += 1;
    }

    return info_count;
}

/// True when `snapshot` did NOT carry titles covering `win_count` windows,
/// i.e. `data.titles` holds fresh dupes the caller must free. Zero-length
/// entries ("") free as no-ops, so every entry can go through the same loop.
inline fn titlesNeedFree(snapshot: TitleSnapshot, win_count: usize) bool {
    return snapshot.titles.len < win_count;
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
