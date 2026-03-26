//! Title segment — shows the focused window title, or a split view for
//! multiple windows.
//!
//! draw() and drawCached() receive a pre-computed TitleSnapshot captured on
//! the main thread, making it safe to call from the bar rendering thread.
//!
//! Threading contract
//!
//! All data in TitleSnapshot must be captured on the main thread before being
//! handed to the render thread.  This module makes zero blocking X11 calls on
//! the render thread.  Both focused_title and minimized_title are pre-fetched
//! via fetchWindowTitleInto by bar.captureIntoSlot on the main thread.
//!
//! Carousel logic lives in carousel.zig.
//! Monitor refresh-rate detection lives in carousel.zig.

// Zig stdlibs
const std = @import("std");

// core/
const core    = @import("core");
    const xcb = core.xcb;
const utils    = @import("utils");

// bar/
const drawing  = @import("drawing");
// bar/modules/
const carousel = @import("carousel");

// Atom cache 

const Atoms = struct {
    /// null until successfully resolved to avoid XCB_ATOM_NONE's sentinel (0).
    net_wm_name: ?u32 = null,
    utf8_string: ?u32 = null,
    initialized: bool = false,

    fn ensure(self: *Atoms) void {
        if (self.initialized) return;
        self.initialized = true;
        self.net_wm_name = utils.getAtomCached("_NET_WM_NAME") catch null;
        self.utf8_string = utils.getAtomCached("UTF8_STRING")  catch null;
    }

    /// Returns the UTF-8 atom when available, falling back to XCB_ATOM_STRING.
    inline fn utf8Type(self: *const Atoms) u32 {
        return self.utf8_string orelse xcb.XCB_ATOM_STRING;
    }
};

var atoms: Atoms = .{};

// Internal types 

const WindowInfo = struct {
    window:    u32,
    x:         i16,
    y:         i16,
    title:     []const u8,
    minimized: bool,
};

/// Fixed left indent, independent of scaledSegmentPadding.
/// Provides visual breathing room between the segment edge and the title text.
const TITLE_LEAD_PX: u16 = 4; //TODO: i feel like this is a very ugly solution, creating a constant with a fixed left indent, to band-aid a problem.

/// Maximum number of windows rendered in split-view.
/// Stack-allocated arrays in drawSegmentedTitles are bounded by this value.
/// Windows beyond this index are silently omitted from the bar.
/// 128 covers any practical workspace size while keeping stack usage bounded.
const MAX_WINS: usize = 128;

// Public input types 

/// Stable per-call rendering context: geometry, draw state, and connection.
/// Constructed once per bar frame and shared between draw() and drawCached().
pub const TitleRenderContext = struct {
    dc:      *drawing.DrawContext,
    config:  core.BarConfig,
    height:  u16,
    start_x: u16,
    width:   u16,
    conn:    *xcb.xcb_connection_t,
};

/// Per-frame volatile snapshot captured on the main thread.
///
/// `focused_title` and `minimized_title` must be pre-fetched on the main
/// thread via fetchWindowTitleInto before the render thread runs draw().
///
/// `minimized_title` is only used in the single-window-minimized case.  Pass
/// an empty slice when that case cannot occur (e.g. the drawCached fast path,
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
/// `cached_title`        — backing buffer updated by draw() on each full
///                          render; the bar passes its contents as
///                          snapshot.focused_title in subsequent drawCached()
///                          calls.
/// `cached_title_window` — window ID the buffer was fetched for; used to
///                          detect when focused_title belongs to a new window.
pub const TitleCache = struct {
    cached_title:        *std.ArrayListUnmanaged(u8),
    cached_title_window: *?u32,
};

// draw — main entry point 

/// Draw the title segment.
///
/// Updates `cache` as a side-effect so drawCached() has a valid slice on
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
        ctx.dc.createRectangle(ctx.start_x, 0, ctx.width, ctx.height, ctx.config.bg);
        return ctx.start_x + ctx.width;
    }

    if (window_count == 1) {
        try drawSingleWindow(ctx, snapshot, cache, allocator, title_invalidated);
    } else {
        try drawSegmentedTitles(ctx, snapshot, allocator, title_invalidated);
    }

    return ctx.start_x + ctx.width;
}

// drawCached — fast-path redraw 

/// Draw the title segment using already-cached state.
///
/// Called from the bar thread's fast-path redraw (focus-only or carousel tick).
/// Unlike draw(), this function:
///   - uses snapshot.focused_title as a read-only slice; the caller is
///     responsible for passing the bar slot's cached buffer contents here.
///   - never updates the title cache (draw() is responsible for keeping it
///     current).
///   - always passes title_invalidated=false to the carousel, since this path
///     only re-renders existing state.
///   - passes minimized_title="" in the snapshot (the minimized title is not
///     cached by the bar slot; the full draw() path handles it).
pub fn drawCached(
    ctx:      TitleRenderContext,
    snapshot: TitleSnapshot,
    allocator: std.mem.Allocator,
) !u16 {
    carousel.ensureDetected(ctx.conn);

    const window_count = snapshot.current_ws_wins.len;

    if (window_count == 0) {
        carousel.deinitCarousel();
        ctx.dc.createRectangle(ctx.start_x, 0, ctx.width, ctx.height, ctx.config.bg);
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

// Private — shared single-window rendering 

/// Shared rendering logic for both draw() and drawCached().
///
/// `cache` is non-null on the draw() path and is updated as a side-effect.
/// `cache` is null on the drawCached() path (read-only; no cache update).
/// `title_invalidated` is always false on the drawCached() path.
fn drawSingleWindow(
    ctx:               TitleRenderContext,
    snapshot:          TitleSnapshot,
    cache:             ?TitleCache,
    allocator:         std.mem.Allocator,
    title_invalidated: bool,
) !void {
    const single_win   = snapshot.current_ws_wins[0];
    const is_minimized = snapshot.minimized_set.contains(single_win);
    const is_focused   = snapshot.focused_window != null;

    const accent = if (is_minimized)
        ctx.config.title_minimized_accent
    else if (is_focused)
        ctx.config.title_accent_color
    else
        ctx.config.bg;
    ctx.dc.createRectangle(ctx.start_x, 0, ctx.width, ctx.height, accent);

    const scaled_padding = ctx.config.scaledSegmentPadding(ctx.height);
    const baseline_y     = ctx.dc.baselineY(ctx.height);
    const text_x         = ctx.start_x + scaled_padding + TITLE_LEAD_PX;
    // Use saturating multiply to guard against extreme padding values before
    // the saturating subtraction, preventing a u16 wrap in the intermediate.
    const avail_w        = ctx.width -| scaled_padding *| 2 -| TITLE_LEAD_PX;
    const geom           = carousel.SegmentGeometry{
        .seg_x   = ctx.start_x,
        .seg_w   = ctx.width,
        .text_x  = text_x,
        .avail_w = avail_w,
    };

    if (is_minimized) {
        // Pre-fetched on the main thread via fetchWindowTitleInto — zero X11
        // I/O here, upholding the render-thread threading contract.
        if (snapshot.minimized_title.len > 0) {
            try carousel.drawOrScrollTitle(
                ctx.dc, baseline_y, geom,
                snapshot.minimized_title, accent, ctx.config.fg,
                single_win, false,
            );
        }
    } else if (snapshot.focused_title.len > 0) {
        // Update the bar slot's title cache for the next drawCached() tick.
        // Only the draw() path passes a non-null cache.
        if (cache) |c| {
            if (title_invalidated or c.cached_title_window.* != snapshot.focused_window) {
                c.cached_title.clearRetainingCapacity();
                c.cached_title.appendSlice(allocator, snapshot.focused_title) catch {};
                c.cached_title_window.* = snapshot.focused_window;
            }
        }
        const fg = if (is_focused) ctx.config.selected_fg else ctx.config.fg;
        try carousel.drawOrScrollTitle(
            ctx.dc, baseline_y, geom,
            snapshot.focused_title, accent, fg,
            snapshot.focused_window, title_invalidated,
        );
    }
}

// Private — split-view segmented titles 

fn drawSegmentedTitles(
    ctx:               TitleRenderContext,
    snapshot:          TitleSnapshot,
    allocator:         std.mem.Allocator,
    title_invalidated: bool,
) !void {
    const win_items = snapshot.current_ws_wins;
    if (win_items.len == 0) return;

    const n_wins = @min(win_items.len, MAX_WINS);

    // Free the single-window carousel: the single and segmented paths are
    // mutually exclusive, and leaving it alive would cause the carousel timer
    // to blit the stale single-window pixmap over the correct split view.
    carousel.deinitSingleCarousel();

    // Prune the seg-carousel if its window has left the workspace so we never
    // blit a title for a window that was closed or moved to another workspace.
    if (carousel.getSegCarouselWindow()) |sw| {
        const still_here = for (win_items[0..n_wins]) |w| {
            if (w == sw) break true;
        } else false;
        if (!still_here) carousel.deinitSegCarousel();
    }

    atoms.ensure();
    const net_atom = atoms.net_wm_name;
    const utf_type = atoms.utf8Type();

    // All XCB requests for this pass are fired in Phase 1 before any reply is
    // read.  XCB queues them into a single kernel write so the server can
    // answer all of them after one round-trip rather than one per window.
    // With n windows this reduces latency from O(n) to O(1) — critical for a
    // bar that redraws on every key event.

    // Phase 1 — fire _NET_WM_NAME cookies AND geometry cookies together.
    var net_cookies:  [MAX_WINS]xcb.xcb_get_property_cookie_t = undefined;
    var geom_cookies: [MAX_WINS]xcb.xcb_get_geometry_cookie_t = undefined;
    var needs_geom:   [MAX_WINS]bool                          = @splat(false);
    // Explicit minimized array avoids the dual-purpose !needs_geom[i] sentinel.
    var is_min_arr:   [MAX_WINS]bool                          = @splat(false);

    for (win_items[0..n_wins], 0..) |win, i| {
        if (net_atom) |na|
            net_cookies[i] = xcb.xcb_get_property(ctx.conn, 0, win, na, utf_type, 0, 8192);
        is_min_arr[i] = snapshot.minimized_set.contains(win);
        if (!is_min_arr[i]) {
            geom_cookies[i] = xcb.xcb_get_geometry(ctx.conn, win);
            needs_geom[i]   = true;
        }
    }

    // Phase 2 — collect _NET_WM_NAME replies; queue WM_NAME fallbacks.
    var titles:     [MAX_WINS]?[]const u8                   = @splat(null);
    var fb_cookies: [MAX_WINS]xcb.xcb_get_property_cookie_t = undefined;
    var needs_fb:   [MAX_WINS]bool                          = @splat(false);

    for (win_items[0..n_wins], 0..) |win, i| {
        got: {
            if (net_atom != null) {
                const r = xcb.xcb_get_property_reply(ctx.conn, net_cookies[i], null) orelse break :got;
                defer std.c.free(r);
                const len = xcb.xcb_get_property_value_length(r);
                if (len > 0) {
                    const ptr: [*]const u8 = @ptrCast(xcb.xcb_get_property_value(r));
                    titles[i] = try allocator.dupe(u8, ptr[0..@intCast(len)]);
                    break :got;
                }
            }
            fb_cookies[i] = xcb.xcb_get_property(
                ctx.conn, 0, win, xcb.XCB_ATOM_WM_NAME, xcb.XCB_ATOM_STRING, 0, 8192);
            needs_fb[i] = true;
        }
    }

    // Phase 3 — collect WM_NAME fallback replies.
    for (0..n_wins) |i| {
        if (!needs_fb[i]) continue;
        const r = xcb.xcb_get_property_reply(ctx.conn, fb_cookies[i], null) orelse continue;
        defer std.c.free(r);
        const len = xcb.xcb_get_property_value_length(r);
        if (len > 0) {
            const ptr: [*]const u8 = @ptrCast(xcb.xcb_get_property_value(r));
            titles[i] = try allocator.dupe(u8, ptr[0..@intCast(len)]);
        }
    }
    defer for (titles[0..n_wins]) |t| if (t) |s| allocator.free(s);

    // Build WindowInfo list.  Geometry replies are already buffered in Phase 1.
    var infos_buf: [MAX_WINS]WindowInfo = undefined;
    var n_infos:   usize                = 0;

    for (win_items[0..n_wins], 0..) |win, i| {
        const geom: utils.Rect = if (needs_geom[i]) blk: {
            const r = xcb.xcb_get_geometry_reply(ctx.conn, geom_cookies[i], null) orelse continue;
            defer std.c.free(r);
            break :blk utils.Rect{
                .x      = @intCast(r.*.x),
                .y      = @intCast(r.*.y),
                .width  = r.*.width,
                .height = r.*.height,
            };
        } else .{ .x = std.math.maxInt(i16), .y = std.math.maxInt(i16), .width = 0, .height = 0 };

        infos_buf[n_infos] = .{
            .window    = win,
            .x         = geom.x,
            .y         = geom.y,
            .title     = titles[i] orelse "",
            .minimized = is_min_arr[i],
        };
        n_infos += 1;
    }

    if (n_infos == 0) return;

    const window_infos = infos_buf[0..n_infos];
    // void context: sort order is purely spatial + window ID, never dependent
    // on focus (see compareWindows).  This prevents segment reordering on focus
    // changes, which would be visually jarring.
    std.mem.sort(WindowInfo, window_infos, {}, compareWindows);

    const num_windows:  u32 = @intCast(window_infos.len);
    const scaled_padding    = ctx.config.scaledSegmentPadding(ctx.height);
    const baseline_y        = ctx.dc.baselineY(ctx.height);

    for (window_infos, 0..) |info, i| {
        // Pixel-perfect tiling: segment i spans [i*W/n, (i+1)*W/n).
        const x0: u16 = @intCast(@divFloor(@as(u32, @intCast(i))     * ctx.width, num_windows));
        const x1: u16 = @intCast(@divFloor(@as(u32, @intCast(i + 1)) * ctx.width, num_windows));
        const segment_x:     u16 = ctx.start_x + x0;
        const segment_width: u16 = x1 - x0;
        if (segment_width == 0) continue;

        const is_focused_win = snapshot.focused_window == info.window;

        const accent = if (is_focused_win)  ctx.config.title_accent_color
            else if (info.minimized)         ctx.config.title_minimized_accent
            else                             ctx.config.title_unfocused_accent;

        ctx.dc.createRectangle(segment_x, 0, segment_width, ctx.height, accent);

        if (info.title.len > 0 and segment_width > scaled_padding *| 2) {
            const text_x  = segment_x + scaled_padding + TITLE_LEAD_PX;
            const avail_w = segment_width -| scaled_padding *| 2 -| TITLE_LEAD_PX;
            const text_fg = if (is_focused_win) ctx.config.selected_fg else ctx.config.fg;
            const text_w  = ctx.dc.textWidth(info.title);
            const geom    = carousel.SegmentGeometry{
                .seg_x   = segment_x,
                .seg_w   = segment_width,
                .text_x  = text_x,
                .avail_w = avail_w,
            };

            if (is_focused_win and carousel.isCarouselEnabled()) {
                // Focused + carousel enabled: pass full segment bounds so
                // the scroll covers the entire segment width.
                const scrolled = try carousel.blitSegCarousel(
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
}

// Private helpers — sorting 

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
/// Focus is intentionally NOT a sort key.  Using focus as a tiebreak would
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

// Private helpers — title fetching 

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

/// Fetch the title of `window`, trying _NET_WM_NAME then WM_NAME.
/// Makes blocking X11 round-trips — MAIN THREAD ONLY.
fn getWindowTitle(
    conn:      *xcb.xcb_connection_t,
    window:    u32,
    allocator: std.mem.Allocator,
) !?[]const u8 {
    atoms.ensure();
    if (atoms.net_wm_name) |na| {
        if (try fetchProperty(conn, window, na, atoms.utf8Type(), allocator)) |t|
            return t;
    }
    return try fetchProperty(conn, window, xcb.XCB_ATOM_WM_NAME, xcb.XCB_ATOM_STRING, allocator);
}

// Public — title pre-fetch 

/// Fetch the title of `win` into `buf`, reusing its existing capacity.
///
/// Must be called on the MAIN THREAD.  Used for both focused and minimized
/// windows so the bar render thread never makes blocking X11 round-trips.
///
/// bar.captureIntoSlot should call this once for the focused window and, when
/// the workspace has exactly one window and it is minimized, once for that
/// minimized window, storing the results in TitleSnapshot.focused_title and
/// TitleSnapshot.minimized_title respectively.
pub fn fetchWindowTitleInto(
    conn:      *xcb.xcb_connection_t,
    win:       u32,
    buf:       *std.ArrayListUnmanaged(u8),
    allocator: std.mem.Allocator,
) !void {
    atoms.ensure();
    const utf_type = atoms.utf8Type();

    if (atoms.net_wm_name) |na| {
        if (utils.fetchPropertyToBuffer(conn, win, na, utf_type, buf, allocator) catch null) |t| {
            if (t.len > 0) return;
        }
    }
    _ = utils.fetchPropertyToBuffer(
        conn, win, xcb.XCB_ATOM_WM_NAME, xcb.XCB_ATOM_STRING, buf, allocator,
    ) catch {};
}
