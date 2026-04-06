//! Title segment — shows the focused window title, or a split view for
//! multiple windows.
//!
//! `draw()` and `drawCached()` receive a pre-computed `TitleSnapshot` captured
//! on the main thread, making it safe to call from the bar rendering thread.
//!
//! Threading contract
//!
//! All data in `TitleSnapshot` must be captured on the main thread before
//! being handed to the render thread.  This module makes zero blocking X11
//! calls on the render thread.  Both `focused_title` and `minimized_title`
//! are pre-fetched via `fetchWindowTitleInto` by `bar.captureIntoSlot` on
//! the main thread.
//!
//! Carousel logic lives in carousel.zig.
//! Monitor refresh-rate detection lives in carousel.zig.

const std      = @import("std");
const core     = @import("core");
const types    = @import("types");
const xcb      = core.xcb;
const utils    = @import("utils");
const drawing  = @import("drawing");
const carousel = @import("carousel");

// ---------------------------------------------------------------------------
// Module constants
// ---------------------------------------------------------------------------

/// Fixed left indent applied inside every title cell, independent of
/// `scaledSegmentPadding`.  Provides visual breathing room between the
/// segment edge and the title text.
const title_lead_px: u16 = 4;

/// Maximum number of windows rendered in split-view.
/// Stack-allocated arrays in `drawSegmentedTitles` are bounded by this value.
/// Windows beyond this index are silently omitted from the bar.
/// 128 covers any practical workspace size while keeping stack usage bounded.
const max_visible_windows: usize = 128;

// ---------------------------------------------------------------------------
// Atom cache
// ---------------------------------------------------------------------------

const Atoms = struct {
    /// null until successfully resolved, to avoid XCB_ATOM_NONE's sentinel (0).
    net_wm_name:    ?u32 = null,
    utf8_string:    ?u32 = null,
    is_initialized: bool = false,

    /// Resolves and caches the X11 atoms needed for title fetching.
    /// Subsequent calls are a no-op.
    fn ensureResolved(self: *Atoms) void {
        if (self.is_initialized) return;
        self.is_initialized = true;
        self.net_wm_name    = utils.getAtomCached("_NET_WM_NAME") catch null;
        self.utf8_string    = utils.getAtomCached("UTF8_STRING")  catch null;
    }

    /// Returns the UTF-8 atom when available, falling back to XCB_ATOM_STRING.
    inline fn utf8AtomType(self: *const Atoms) u32 {
        return self.utf8_string orelse xcb.XCB_ATOM_STRING;
    }
};

var atoms: Atoms = .{};

// ---------------------------------------------------------------------------
// Internal types
// ---------------------------------------------------------------------------

const WindowInfo = struct {
    window:    u32,
    x:         i16,
    y:         i16,
    title:     []const u8,
    minimized: bool,
};

// ---------------------------------------------------------------------------
// Public input types
// ---------------------------------------------------------------------------

/// Stable per-call rendering context: geometry, draw state, and connection.
/// Constructed once per bar frame and shared between `draw()` and `drawCached()`.
pub const TitleRenderContext = struct {
    dc:      *drawing.DrawContext,
    config:  types.BarConfig,
    height:  u16,
    start_x: u16,
    width:   u16,
    conn:    *xcb.xcb_connection_t,
};

/// Per-frame volatile snapshot captured on the main thread.
///
/// `focused_title` and `minimized_title` must be pre-fetched on the main
/// thread via `fetchWindowTitleInto` before the render thread runs `draw()`.
///
/// `minimized_title` is only used in the single-window-minimized case.  Pass
/// an empty slice when that case cannot occur (e.g. the `drawCached` fast path,
/// which has no cached minimized title).
pub const TitleSnapshot = struct {
    focused_window:  ?u32,
    focused_title:   []const u8,
    minimized_title: []const u8,
    current_ws_wins: []const u32,
    minimized_set:   *const std.AutoHashMapUnmanaged(u32, void),
};

/// Mutable title cache owned by the bar slot.
///
/// `cached_title`        — backing buffer updated by `draw()` on each full
///                          render; the bar passes its contents as
///                          `snapshot.focused_title` in subsequent `drawCached()`
///                          calls.
/// `cached_title_window` — window ID the buffer was fetched for; used to
///                          detect when `focused_title` belongs to a new window.
pub const TitleCache = struct {
    cached_title:        *std.ArrayListUnmanaged(u8),
    cached_title_window: *?u32,
};

// ---------------------------------------------------------------------------
// Public API — draw entry points
// ---------------------------------------------------------------------------

/// Draw the title segment.
///
/// Updates `cache` as a side-effect so `drawCached()` has a valid slice on
/// the next tick.
///
/// `title_invalidated` must be true whenever the focused window's title
/// property changed since the last draw.
pub fn draw(
    ctx:               TitleRenderContext,
    snapshot:          TitleSnapshot,
    cache:             TitleCache,
    allocator:         std.mem.Allocator,
    title_invalidated: bool,
) !u16 {
    // Ensure the monitor refresh rate is detected before any carousel call.
    // This is a no-op on every call after the first.
    carousel.ensureDetected(ctx.conn);

    const window_count = snapshot.current_ws_wins.len;

    if (window_count == 0) {
        // No windows on this workspace — tear down any live carousel immediately
        // so it does not keep scrolling invisibly in the background.
        carousel.deinitCarousel();
        ctx.dc.fillRect(ctx.start_x, 0, ctx.width, ctx.height, ctx.config.bg);
        return ctx.start_x + ctx.width;
    }

    if (window_count == 1) {
        try drawSingleWindow(ctx, snapshot, cache, allocator, title_invalidated);
    } else {
        try drawSegmentedTitles(ctx, snapshot, allocator, title_invalidated);
    }

    return ctx.start_x + ctx.width;
}

/// Draw the title segment using already-cached state.
///
/// Called from the bar thread's fast-path redraw (focus-only or carousel tick).
/// Unlike `draw()`, this function:
///   - uses `snapshot.focused_title` as a read-only slice; the caller is
///     responsible for passing the bar slot's cached buffer contents here.
///   - never updates the title cache (`draw()` is responsible for keeping it current).
///   - always passes `title_invalidated = false` to the carousel, since this
///     path only re-renders existing state.
///   - passes `minimized_title = ""` in the snapshot (the minimized title is not
///     cached by the bar slot; the full `draw()` path handles it).
pub fn drawCached(
    ctx:       TitleRenderContext,
    snapshot:  TitleSnapshot,
    allocator: std.mem.Allocator,
) !u16 {
    carousel.ensureDetected(ctx.conn);

    const window_count = snapshot.current_ws_wins.len;

    if (window_count == 0) {
        carousel.deinitCarousel();
        ctx.dc.fillRect(ctx.start_x, 0, ctx.width, ctx.height, ctx.config.bg);
        return ctx.start_x + ctx.width;
    }

    if (window_count == 1) {
        // null cache — this path never updates the cache.
        try drawSingleWindow(ctx, snapshot, null, allocator, false);
    } else {
        try drawSegmentedTitles(ctx, snapshot, allocator, false);
    }

    return ctx.start_x + ctx.width;
}

// ---------------------------------------------------------------------------
// Public API — title pre-fetch (main thread only)
// ---------------------------------------------------------------------------

/// Fetch the title of `win` into `buf`, reusing its existing capacity.
///
/// Must be called on the MAIN THREAD.  Used for both focused and minimized
/// windows so the bar render thread never makes blocking X11 round-trips.
///
/// `bar.captureIntoSlot` should call this once for the focused window and,
/// when the workspace has exactly one window and it is minimized, once for
/// that minimized window — storing the results in `TitleSnapshot.focused_title`
/// and `TitleSnapshot.minimized_title` respectively.
pub fn fetchWindowTitleInto(
    conn:      *xcb.xcb_connection_t,
    win:       u32,
    buf:       *std.ArrayListUnmanaged(u8),
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
        conn, win, xcb.XCB_ATOM_WM_NAME, xcb.XCB_ATOM_STRING, buf, allocator,
    ) catch {};
}

// ---------------------------------------------------------------------------
// Private — single-window rendering
// ---------------------------------------------------------------------------

/// Shared rendering logic for both `draw()` and `drawCached()`.
///
/// `cache` is non-null on the `draw()` path and is updated as a side-effect.
/// `cache` is null on the `drawCached()` path (read-only; no cache update).
/// `title_invalidated` is always false on the `drawCached()` path.
fn drawSingleWindow(
    ctx:               TitleRenderContext,
    snapshot:          TitleSnapshot,
    cache:             ?TitleCache,
    allocator:         std.mem.Allocator,
    title_invalidated: bool,
) !void {
    const single_win   = snapshot.current_ws_wins[0];
    const is_minimized = snapshot.minimized_set.contains(single_win);
    // `has_focus` is true when any window on this workspace is focused,
    // meaning the segment gets the accent colour rather than plain bg.
    const has_focus    = snapshot.focused_window != null;

    const accent = if (is_minimized)
        ctx.config.title_minimized_accent
    else if (has_focus)
        ctx.config.title_accent_color
    else
        ctx.config.bg;
    ctx.dc.fillRect(ctx.start_x, 0, ctx.width, ctx.height, accent);

    const scaled_padding = ctx.config.scaledSegmentPadding(ctx.height);
    const baseline_y     = ctx.dc.baselineY(ctx.height);
    const text_x         = ctx.start_x + scaled_padding + title_lead_px;
    // Saturating arithmetic guards against extreme padding values before the
    // saturating subtraction, preventing a u16 wrap in the intermediate result.
    const avail_w        = ctx.width -| scaled_padding *| 2 -| title_lead_px;
    const geom           = carousel.SegmentGeometry{
        .seg_x   = ctx.start_x,
        .seg_w   = ctx.width,
        .text_x  = text_x,
        .avail_w = avail_w,
    };

    if (is_minimized) {
        // Pre-fetched on the main thread via fetchWindowTitleInto — zero X11
        // I/O here, upholding the render-thread threading contract.
        if (snapshot.minimized_title.len > 0)
            try carousel.drawScrollingTitle(
                ctx.dc, baseline_y, geom,
                snapshot.minimized_title, accent, ctx.config.fg,
                single_win, false,
            );
        return;
    }

    if (snapshot.focused_title.len == 0) return;

    // Update the bar slot's title cache for the next drawCached() tick.
    // Only the draw() path passes a non-null cache.
    if (cache) |slot| {
        if (title_invalidated or slot.cached_title_window.* != snapshot.focused_window) {
            slot.cached_title.clearRetainingCapacity();
            slot.cached_title.appendSlice(allocator, snapshot.focused_title) catch {};
            slot.cached_title_window.* = snapshot.focused_window;
        }
    }

    const fg = if (has_focus) ctx.config.selected_fg else ctx.config.fg;
    try carousel.drawScrollingTitle(
        ctx.dc, baseline_y, geom,
        snapshot.focused_title, accent, fg,
        snapshot.focused_window, title_invalidated,
    );
}

// ---------------------------------------------------------------------------
// Private — split-view segmented titles
// ---------------------------------------------------------------------------

fn drawSegmentedTitles(
    ctx:               TitleRenderContext,
    snapshot:          TitleSnapshot,
    allocator:         std.mem.Allocator,
    title_invalidated: bool,
) !void {
    const windows = snapshot.current_ws_wins;
    if (windows.len == 0) return;

    const win_count = @min(windows.len, max_visible_windows);

    // Free the single-window carousel: the single and segmented paths are
    // mutually exclusive.  Leaving it alive would cause the carousel timer
    // to blit the stale single-window pixmap over the correct split view.
    carousel.deinitSingleCarousel();

    // Prune the seg-carousel if its window has left the workspace so we never
    // blit a title for a window that was closed or moved to another workspace.
    if (carousel.getSegmentedCarouselWindow()) |tracked_win| {
        const still_present = for (windows[0..win_count]) |w| {
            if (w == tracked_win) break true;
        } else false;
        if (!still_present) carousel.deinitSegmentedCarousel();
    }

    atoms.ensureResolved();
    const net_atom = atoms.net_wm_name;
    const utf_type = atoms.utf8AtomType();

    // All XCB requests for this pass are fired in Phase 1 before any reply is
    // read.  XCB queues them into a single kernel write so the server can
    // answer all of them after one round-trip rather than one per window.
    // With n windows this reduces latency from O(n) to O(1) — critical for a
    // bar that redraws on every key event.

    // Phase 1 — fire _NET_WM_NAME cookies AND geometry cookies together.
    var net_wm_cookies: [max_visible_windows]xcb.xcb_get_property_cookie_t = undefined;
    var geom_cookies:   [max_visible_windows]xcb.xcb_get_geometry_cookie_t = undefined;
    var needs_geometry: [max_visible_windows]bool                          = @splat(false);
    // Explicit minimized array avoids the dual-purpose !needs_geometry[i] sentinel.
    var is_minimized:   [max_visible_windows]bool                          = @splat(false);

    for (windows[0..win_count], 0..) |win, i| {
        if (net_atom) |na|
            net_wm_cookies[i] = xcb.xcb_get_property(ctx.conn, 0, win, na, utf_type, 0, 8192);
        is_minimized[i] = snapshot.minimized_set.contains(win);
        if (!is_minimized[i]) {
            geom_cookies[i]   = xcb.xcb_get_geometry(ctx.conn, win);
            needs_geometry[i] = true;
        }
    }

    // Phase 2 — collect _NET_WM_NAME replies; queue WM_NAME fallbacks.
    var titles:          [max_visible_windows]?[]const u8                   = @splat(null);
    var fallback_cookies:[max_visible_windows]xcb.xcb_get_property_cookie_t = undefined;
    var needs_fallback:  [max_visible_windows]bool                          = @splat(false);

    for (windows[0..win_count], 0..) |win, i| {
        got: {
            if (net_atom != null) {
                const r = xcb.xcb_get_property_reply(ctx.conn, net_wm_cookies[i], null) orelse break :got;
                defer std.c.free(r);
                const len = xcb.xcb_get_property_value_length(r);
                if (len > 0) {
                    const ptr: [*]const u8 = @ptrCast(xcb.xcb_get_property_value(r));
                    titles[i] = try allocator.dupe(u8, ptr[0..@intCast(len)]);
                    break :got;
                }
            }
            fallback_cookies[i] = xcb.xcb_get_property(
                ctx.conn, 0, win, xcb.XCB_ATOM_WM_NAME, xcb.XCB_ATOM_STRING, 0, 8192);
            needs_fallback[i] = true;
        }
    }

    // Phase 3 — collect WM_NAME fallback replies.
    for (0..win_count) |i| {
        if (!needs_fallback[i]) continue;
        const r = xcb.xcb_get_property_reply(ctx.conn, fallback_cookies[i], null) orelse continue;
        defer std.c.free(r);
        const len = xcb.xcb_get_property_value_length(r);
        if (len > 0) {
            const ptr: [*]const u8 = @ptrCast(xcb.xcb_get_property_value(r));
            titles[i] = try allocator.dupe(u8, ptr[0..@intCast(len)]);
        }
    }
    defer for (titles[0..win_count]) |t| if (t) |s| allocator.free(s);

    // Build WindowInfo list. Geometry replies are already buffered in Phase 1.
    var window_info_buf: [max_visible_windows]WindowInfo = undefined;
    var info_count:      usize                           = 0;

    for (windows[0..win_count], 0..) |win, i| {
        const geom: utils.Rect = if (needs_geometry[i]) blk: {
            const r = xcb.xcb_get_geometry_reply(ctx.conn, geom_cookies[i], null) orelse continue;
            defer std.c.free(r);
            break :blk utils.Rect{
                .x      = @intCast(r.*.x),
                .y      = @intCast(r.*.y),
                .width  = r.*.width,
                .height = r.*.height,
            };
        } else .{ .x = std.math.maxInt(i16), .y = std.math.maxInt(i16), .width = 0, .height = 0 };

        window_info_buf[info_count] = .{
            .window    = win,
            .x         = geom.x,
            .y         = geom.y,
            .title     = titles[i] orelse "",
            .minimized = is_minimized[i],
        };
        info_count += 1;
    }

    if (info_count == 0) return;

    const window_infos = window_info_buf[0..info_count];
    // void context: sort order is purely spatial + window ID, never dependent
    // on focus (see `compareWindows`).  This prevents segment reordering on
    // focus changes, which would be visually jarring.
    std.mem.sort(WindowInfo, window_infos, {}, compareWindows);

    const window_count:    u32 = @intCast(window_infos.len);
    const scaled_padding       = ctx.config.scaledSegmentPadding(ctx.height);
    const baseline_y           = ctx.dc.baselineY(ctx.height);

    for (window_infos, 0..) |info, i| {
        // Pixel-perfect tiling: segment i spans [i*W/n, (i+1)*W/n).
        const x0: u16 = @intCast(@divFloor(@as(u32, @intCast(i))     * ctx.width, window_count));
        const x1: u16 = @intCast(@divFloor(@as(u32, @intCast(i + 1)) * ctx.width, window_count));
        const segment_x:     u16 = ctx.start_x + x0;
        const segment_width: u16 = x1 - x0;
        if (segment_width == 0) continue;

        const is_focused_win = snapshot.focused_window == info.window;

        const accent = if (is_focused_win)  ctx.config.title_accent_color
            else if (info.minimized)         ctx.config.title_minimized_accent
            else                             ctx.config.title_unfocused_accent;

        ctx.dc.fillRect(segment_x, 0, segment_width, ctx.height, accent);

        if (info.title.len == 0 or segment_width <= scaled_padding *| 2) continue;

        const text_x  = segment_x + scaled_padding + title_lead_px;
        const avail_w = segment_width -| scaled_padding *| 2 -| title_lead_px;
        const text_fg = if (is_focused_win) ctx.config.selected_fg else ctx.config.fg;
        const text_w  = ctx.dc.measureTextWidth(info.title);
        const geom    = carousel.SegmentGeometry{
            .seg_x   = segment_x,
            .seg_w   = segment_width,
            .text_x  = text_x,
            .avail_w = avail_w,
        };

        if (is_focused_win and carousel.isCarouselEnabled()) {
            // Focused + carousel enabled: pass full segment bounds so
            // the scroll covers the entire segment width.
            const scrolled = try carousel.drawSegmentedCarousel(
                ctx.dc, baseline_y, geom, text_w,
                info.title, accent, text_fg, info.window, title_invalidated,
            );
            if (!scrolled) {
                // Text fits — draw it inset with normal padding.
                try ctx.dc.drawText(text_x, baseline_y, info.title, text_fg);
            }
        } else {
            // Non-focused or carousel disabled: ellipsis on overflow.
            if (text_w <= avail_w)
                try ctx.dc.drawText(text_x, baseline_y, info.title, text_fg)
            else
                try ctx.dc.drawTextEllipsis(text_x, baseline_y, info.title, avail_w, text_fg);
        }
    }
}

// ---------------------------------------------------------------------------
// Private helpers — window sorting
// ---------------------------------------------------------------------------

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

// ---------------------------------------------------------------------------
// Private helpers — title fetching (main thread only)
// ---------------------------------------------------------------------------

fn fetchProperty(
    conn:      *xcb.xcb_connection_t,
    win:       u32,
    atom:      u32,
    atom_type: u32,
    allocator: std.mem.Allocator,
) !?[]const u8 {
    const cookie = xcb.xcb_get_property(conn, 0, win, atom, atom_type, 0, 8192);
    const reply  = xcb.xcb_get_property_reply(conn, cookie, null) orelse return null;
    defer std.c.free(reply);
    const len = xcb.xcb_get_property_value_length(reply);
    if (len <= 0) return null;
    const value: [*]const u8 = @ptrCast(xcb.xcb_get_property_value(reply));
    return try allocator.dupe(u8, value[0..@intCast(len)]);
}

/// Fetch the title of `window`, trying `_NET_WM_NAME` then `WM_NAME`.
/// Makes blocking X11 round-trips — MAIN THREAD ONLY.
fn fetchWindowTitle(
    conn:      *xcb.xcb_connection_t,
    window:    u32,
    allocator: std.mem.Allocator,
) !?[]const u8 {
    atoms.ensureResolved();
    if (atoms.net_wm_name) |na| {
        if (try fetchProperty(conn, window, na, atoms.utf8AtomType(), allocator)) |t|
            return t;
    }
    return try fetchProperty(conn, window, xcb.XCB_ATOM_WM_NAME, xcb.XCB_ATOM_STRING, allocator);
}
