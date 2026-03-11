//! Title segment — shows the focused window title, or a split view for multiple windows.
//!
//! draw() now receives pre-computed snapshot data (conn, focused_window, workspace
//! windows, minimized set) instead of a *defs.WM pointer, making it safe to call
//! from the bar rendering thread.

const std     = @import("std");
const defs    = @import("defs");
const xcb     = defs.xcb;
const drawing = @import("drawing");
const utils   = @import("utils");

const Atoms = struct {
    net_wm_name: u32 = 0,
    utf8_string: u32 = 0,
    initialized: bool = false,

    fn ensure(self: *Atoms) void {
        if (self.initialized) return;
        self.initialized = true;
        self.net_wm_name = utils.getAtomCached("_NET_WM_NAME") catch 0;
        self.utf8_string  = utils.getAtomCached("UTF8_STRING")  catch 0;
    }

    inline fn utf8Type(self: *const Atoms) u32 {
        return if (self.utf8_string != 0) self.utf8_string else xcb.XCB_ATOM_STRING;
    }

    fn invalidate(self: *Atoms) void { self.initialized = false; }
};

var atoms: Atoms = .{};

const WindowInfo = struct {
    window:    u32,
    x:         i16,
    y:         i16,
    title:     []const u8,
    minimized: bool,
};

/// Fixed left indent independent of scaledSegmentPadding.
const TITLE_LEAD_PX: u16 = 4;

// ── Carousel / ticker scroll ──────────────────────────────────────────────
//
// The title text is pre-rendered once into a CarouselPixmap (background +
// glyphs).  Every tick is then two xcb_copy_area blits — no Pango, no Cairo,
// no font shaping.  The pixmap is only re-rendered when the title changes.
//
// Leapfrog wrap: two logical copies sit `cycle_w` apart.  As `offset`
// advances 0 → cycle_w the first copy exits left while the second enters
// right.  At cycle_w the state is identical to 0 → seamless loop.

/// Horizontal scroll speed in pixels per millisecond (≈ 90 px/s).
const CAROUSEL_PX_PER_MS: f64 = 0.100;
/// Pixel gap between the end of one copy and the start of the next.
const CAROUSEL_GAP_PX: u16 = 60;

/// Pre-rendered title pixmap + invalidation key.
const CarouselCache = struct {
    cp:      drawing.CarouselPixmap,
    window:  ?u32,
    cycle_w: u16,  // cached: text_w + CAROUSEL_GAP_PX, never recomputed per tick
};

var g_carousel:        ?CarouselCache = null;
var g_carousel_active: bool           = false;

// ── Per-segment (split-view) carousel ────────────────────────────────────
//
// Only the *focused* window ever gets a carousel in split view.  Unfocused
// segments that overflow always show an ellipsis instead.
//
// `start_ms` records the monotonic timestamp at which the focused window
// gained focus (or the pixmap was first built).  The scroll offset is derived
// from `now - start_ms`, so the animation always begins at position 0 the
// moment a window gains focus.  Switching focus frees the old pixmap and
// rebuilds a fresh one for the new focused window.

const SegCarousel = struct {
    cp:       drawing.CarouselPixmap,
    window:   u32,
    cycle_w:  u16,
    start_ms: i64,
};

var g_seg_carousel:        ?SegCarousel = null;
var g_seg_carousel_active: bool         = false;

pub fn isCarouselActive() bool { return g_carousel_active or g_seg_carousel_active; }

/// Free all carousel pixmaps. Call on bar deinit or reload.
pub fn deinitCarousel() void {
    if (g_carousel)     |*cc| { cc.cp.deinit();  g_carousel     = null; }
    if (g_seg_carousel) |*sc| { sc.cp.deinit();  g_seg_carousel = null; }
    g_carousel_active     = false;
    g_seg_carousel_active = false;
}

fn nowMs() i64 {
    const ts = std.posix.clock_gettime(.MONOTONIC) catch return 0;
    return ts.sec * 1000 + @divTrunc(ts.nsec, 1_000_000);
}

/// Fast per-tick carousel redraw.  Skips Pango, Cairo surface flush, and the
/// full-bar blit.  Returns false if no carousel is active (caller must fall
/// back to a full title draw).
///
/// On the hot path this does exactly:
///   fillRect (background)  — one xcb_poly_fill_rectangle
///   blitFrame              — at most two xcb_copy_area
///   flushRect              — one targeted xcb_copy_area, no cairo_surface_flush
pub fn drawCarouselTick(
    dc:     *drawing.DrawContext,
    bg:     u32,
    height: u16,
    x:      u16,
    avail_w: u16,
) bool {
    const cc = g_carousel orelse return false;
    // Fill the segment background so the gap between copies shows the right colour.
    dc.fillRect(x, 0, avail_w, height, bg);
    const offset = carouselOffsetFrom(0, cc.cycle_w);
    cc.cp.blitFrame(dc.drawable, dc.gc, x, avail_w, offset, cc.cycle_w);
    dc.flushRect(x, avail_w);
    return true;
}

/// Scroll offset in [0, cycle_w) relative to `start_ms`.
/// Pass `start_ms = 0` for the absolute-time (legacy single-window) behaviour.
fn carouselOffsetFrom(start_ms: i64, cycle_w: u16) u16 {
    const cycle_ms: i64 = @intFromFloat(
        @ceil(@as(f64, @floatFromInt(cycle_w)) / CAROUSEL_PX_PER_MS),
    );
    const elapsed = nowMs() - start_ms;
    const phase   = @mod(elapsed, cycle_ms);
    const px: f64 = @as(f64, @floatFromInt(phase)) * CAROUSEL_PX_PER_MS;
    return @intCast(@min(@as(u64, @intFromFloat(px)), @as(u64, cycle_w - 1)));
}

// ─────────────────────────────────────────────────────────────────────────────

/// Returns true when `win` appears in the minimized snapshot slice.
/// O(1) minimized membership check using the pre-built set from BarSnapshot.
inline fn isMinimizedInSnap(minimized_set: *const std.AutoHashMapUnmanaged(u32, void), win: u32) bool {
    return minimized_set.contains(win);
}

/// Draw the title segment.
///
/// Parameters replacing the old `wm: *defs.WM`:
///   `conn`              — XCB connection (thread-safe for I/O).
///   `focused_window`    — currently focused window ID, or null.
///   `current_ws_wins`   — window IDs on the current workspace (snapshot copy).
///   `minimized`         — snapshot of minimized window IDs (for isMinimized checks).
///   `title_invalidated` — when true, the cached title is stale and must be re-fetched.
/// Draw the title segment.
/// `focused_title` is pre-fetched on the main thread in captureIntoSlot —
/// the bar render thread makes zero blocking X11 calls for the focused window title.
pub fn draw(
    dc:                   *drawing.DrawContext,
    config:               defs.BarConfig,
    height:               u16,
    start_x:              u16,
    width:                u16,
    conn:                 *xcb.xcb_connection_t,
    focused_window:       ?u32,
    focused_title:        []const u8,
    current_ws_wins:      []const u32,
    minimized_set:        *const std.AutoHashMapUnmanaged(u32, void),
    cached_title:         *std.ArrayList(u8),
    cached_title_window:  *?u32,
    title_invalidated:    bool,
    allocator:            std.mem.Allocator,
) !u16 {
    const window_count = current_ws_wins.len;

    if (window_count == 0) {
        dc.fillRect(start_x, 0, width, height, config.bg);
        return start_x + width;
    }

    const scaled_padding = config.scaledSegmentPadding(height);
    // baselineY is constant for a given DC + height; compute once for both branches.
    const baseline_y = dc.baselineY(height);

    if (window_count == 1) {
        const single_win   = current_ws_wins[0];
        const is_minimized = isMinimizedInSnap(minimized_set, single_win);
        const is_focused   = focused_window != null;

        const accent = if (is_minimized)
            config.getTitleMinimizedAccent()
        else if (is_focused)
            config.getTitleAccent()
        else
            config.bg;
        dc.fillRect(start_x, 0, width, height, accent);

        if (is_minimized) {
            const title = getWindowTitle(conn, single_win, allocator) catch null;
            defer if (title) |t| allocator.free(t);
            if (title) |t| {
                try drawTitleText(dc, start_x + scaled_padding + TITLE_LEAD_PX, baseline_y,
                    width -| scaled_padding * 2 -| TITLE_LEAD_PX, height,
                    t, accent, config.fg, single_win, title_invalidated);
            }
        } else {
            // focused_title was pre-fetched on the main thread — zero X11 I/O here.
            if (focused_title.len > 0) {
                if (title_invalidated or cached_title_window.* != focused_window) {
                    cached_title.clearRetainingCapacity();
                    cached_title.appendSlice(allocator, focused_title) catch {};
                    cached_title_window.* = focused_window;
                }
                const fg = if (is_focused) config.selected_fg else config.fg;
                try drawTitleText(dc, start_x + scaled_padding + TITLE_LEAD_PX, baseline_y,
                    width -| scaled_padding * 2 -| TITLE_LEAD_PX, height,
                    focused_title, accent, fg, focused_window, title_invalidated);
            }
        }
    } else {
        try drawSegmentedTitles(dc, config, height, start_x, width,
            conn, focused_window, current_ws_wins, minimized_set, allocator, scaled_padding,
            title_invalidated);
    }

    return start_x + width;
}

/// Render a window title into `avail_w` pixels starting at `x`.
///
/// Fits: drawn directly via Pango/Cairo as normal.
/// Overflows: uses a pre-rendered CarouselPixmap blitted via xcb_copy_area.
/// The pixmap is rebuilt only when `window` or `title_invalidated` changes.
fn drawTitleText(
    dc:                *drawing.DrawContext,
    x:                 u16,
    y:                 u16,
    avail_w:           u16,
    bar_h:             u16,
    text:              []const u8,
    bg:                u32,
    fg:                u32,
    window:            ?u32,
    title_invalidated: bool,
) !void {
    const text_w = dc.textWidth(text);

    if (text_w <= avail_w) {
        // Text fits — no carousel needed.  Free any stale pixmap.
        if (g_carousel != null) deinitCarousel();
        g_carousel_active = false;
        try dc.drawText(x, y, text, fg);
        return;
    }

    g_carousel_active = true;

    // Rebuild the pixmap if the window changed or the title is stale.
    const stale = g_carousel == null
        or g_carousel.?.window != window
        or title_invalidated;

    if (stale) {
        if (g_carousel) |*cc| { cc.cp.deinit(); g_carousel = null; }

        var cp = try drawing.CarouselPixmap.init(dc, text_w);
        errdefer cp.deinit();
        try cp.render(dc, text, bg, fg, y);
        const cycle_w: u16 = text_w + CAROUSEL_GAP_PX;
        g_carousel = .{ .cp = cp, .window = window, .cycle_w = cycle_w };
    }

    const cc = g_carousel.?;
    const offset = carouselOffsetFrom(0, cc.cycle_w);
    cc.cp.blitFrame(dc.drawable, dc.gc, x, avail_w, offset, cc.cycle_w);
    _ = bar_h;
}

fn drawSegmentedTitles(
    dc:                *drawing.DrawContext,
    config:            defs.BarConfig,
    height:            u16,
    start_x:           u16,
    width:             u16,
    conn:              *xcb.xcb_connection_t,
    focused_window:    ?u32,
    win_items:         []const u32,
    minimized_set:     *const std.AutoHashMapUnmanaged(u32, void),
    allocator:         std.mem.Allocator,
    scaled_padding:    u16,
    title_invalidated: bool,
) !void {
    if (win_items.len == 0) return;

    // If the focused window left the workspace, free the stale carousel now
    // so we don't blit a pixmap for a window that no longer exists on-screen.
    if (g_seg_carousel) |sc| {
        var still_present = false;
        for (win_items) |w| if (w == sc.window) { still_present = true; break; };
        if (!still_present) { g_seg_carousel.?.cp.deinit(); g_seg_carousel = null; }
    }
    g_seg_carousel_active = false;

    const MAX_WINS: usize = 128;
    const n_wins = @min(win_items.len, MAX_WINS);

    atoms.ensure();
    const net_atom = atoms.net_wm_name;
    const utf_type = atoms.utf8Type();

    // Phase 1: fire all _NET_WM_NAME cookies AND geometry cookies without waiting.
    // Both sets are independent requests; sending them together means the server
    // can answer all of them in a single round-trip.  By the time Phase 2 and
    // Phase 3 finish collecting title replies, the geometry replies are already
    // sitting in the receive buffer — zero additional wait at consumption time.
    var net_cookies:  [MAX_WINS]xcb.xcb_get_property_cookie_t = undefined;
    var geom_cookies: [MAX_WINS]xcb.xcb_get_geometry_cookie_t = undefined;
    var needs_geom:   [MAX_WINS]bool                          = @splat(false);

    for (win_items[0..n_wins], 0..) |win, i| {
        if (net_atom != 0)
            net_cookies[i] = xcb.xcb_get_property(conn, 0, win, net_atom, utf_type, 0, 8192);
        if (!isMinimizedInSnap(minimized_set, win)) {
            geom_cookies[i] = xcb.xcb_get_geometry(conn, win);
            needs_geom[i]   = true;
        }
    }

    // Phase 2: collect _NET_WM_NAME replies; queue WM_NAME fallbacks.
    var titles:     [MAX_WINS]?[]const u8                   = @splat(null);
    var fb_cookies: [MAX_WINS]xcb.xcb_get_property_cookie_t = undefined;
    var needs_fb:   [MAX_WINS]bool                          = @splat(false);

    for (win_items[0..n_wins], 0..) |win, i| {
        got: {
            if (net_atom != 0) {
                const r = xcb.xcb_get_property_reply(conn, net_cookies[i], null) orelse break :got;
                defer std.c.free(r);
                const len = xcb.xcb_get_property_value_length(r);
                if (len > 0) {
                    const ptr: [*]const u8 = @ptrCast(xcb.xcb_get_property_value(r));
                    titles[i] = try allocator.dupe(u8, ptr[0..@intCast(len)]);
                    break :got;
                }
            }
            fb_cookies[i] = xcb.xcb_get_property(
                conn, 0, win, xcb.XCB_ATOM_WM_NAME, xcb.XCB_ATOM_STRING, 0, 8192);
            needs_fb[i] = true;
        }
    }

    // Phase 3: collect WM_NAME fallback replies.
    for (0..n_wins) |i| {
        if (!needs_fb[i]) continue;
        const r = xcb.xcb_get_property_reply(conn, fb_cookies[i], null) orelse continue;
        defer std.c.free(r);
        const len = xcb.xcb_get_property_value_length(r);
        if (len > 0) {
            const ptr: [*]const u8 = @ptrCast(xcb.xcb_get_property_value(r));
            titles[i] = try allocator.dupe(u8, ptr[0..@intCast(len)]);
        }
    }
    defer for (titles[0..n_wins]) |t| if (t) |s| allocator.free(s);

    // Build WindowInfo list. Geometry replies were pre-fired in Phase 1 and are
    // already buffered — xcb_get_geometry_reply returns immediately from cache.
    var infos_buf: [MAX_WINS]WindowInfo = undefined;
    var n_infos: usize = 0;

    for (win_items[0..n_wins], 0..) |win, i| {
        const is_min = !needs_geom[i];
        const geom: utils.Rect = if (needs_geom[i]) blk: {
            const r = xcb.xcb_get_geometry_reply(conn, geom_cookies[i], null) orelse continue;
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
            .minimized = is_min,
        };
        n_infos += 1;
    }

    if (n_infos == 0) return;

    const window_infos = infos_buf[0..n_infos];
    std.mem.sort(WindowInfo, window_infos, {}, compareWindows);

    const num_windows: u32 = @intCast(window_infos.len);
    // n_infos > 0 is guaranteed above, so window_infos.len > 0 here.

    // baselineY is identical for every segment — hoist it once outside the loop.
    const baseline_y = dc.baselineY(height);

    for (window_infos, 0..) |info, i| {
        // Pixel-perfect tiling: segment i spans [i*W/n, (i+1)*W/n).
        // Each remainder pixel is handed to a later segment naturally, so
        // segments always sum to exactly `width` with zero rounding gap.
        const x0: u16 = @intCast(@divFloor(@as(u32, @intCast(i))     * width, num_windows));
        const x1: u16 = @intCast(@divFloor(@as(u32, @intCast(i + 1)) * width, num_windows));
        const segment_x:     u16 = start_x + x0;
        const segment_width: u16 = x1 - x0;
        if (segment_width == 0) continue;

        const is_focused_win = focused_window == info.window;

        const accent = if (is_focused_win)  config.getTitleAccent()
            else if (info.minimized)         config.getTitleMinimizedAccent()
            else                             config.getTitleUnfocusedAccent();

        dc.fillRect(segment_x, 0, segment_width, height, accent);

        if (info.title.len > 0 and segment_width > scaled_padding * 2) {
            const text_x  = segment_x + scaled_padding + TITLE_LEAD_PX;
            const avail_w = segment_width -| scaled_padding * 2 -| TITLE_LEAD_PX;
            const text_fg = if (is_focused_win) config.selected_fg else config.fg;
            const text_w  = dc.textWidth(info.title);

            if (!is_focused_win) {
                // Non-focused window: never scroll — always ellipsis if overflow.
                if (text_w <= avail_w)
                    try dc.drawText(text_x, baseline_y, info.title, text_fg)
                else
                    try dc.drawTextEllipsis(text_x, baseline_y, info.title, avail_w, text_fg);
            } else if (text_w <= avail_w) {
                // Focused and fits — no carousel needed; free any stale pixmap.
                if (g_seg_carousel) |*sc| { sc.cp.deinit(); g_seg_carousel = null; }
                try dc.drawText(text_x, baseline_y, info.title, text_fg);
            } else {
                // Focused and overflows — build or reuse the single seg carousel.
                g_seg_carousel_active = true;

                const expected_cycle_w: u16 = text_w + CAROUSEL_GAP_PX;

                // Detect stale pixmap: wrong window (focus switched) or title changed.
                const stale = if (g_seg_carousel) |sc|
                    sc.window != info.window or
                    title_invalidated or
                    sc.cycle_w != expected_cycle_w
                else
                    true;

                if (stale) {
                    if (g_seg_carousel) |*sc| { sc.cp.deinit(); g_seg_carousel = null; }
                    var cp = try drawing.CarouselPixmap.init(dc, text_w);
                    errdefer cp.deinit();
                    try cp.render(dc, info.title, accent, text_fg, baseline_y);
                    g_seg_carousel = .{
                        .cp       = cp,
                        .window   = info.window,
                        .cycle_w  = expected_cycle_w,
                        // Record when focus was gained so offset starts at 0.
                        .start_ms = nowMs(),
                    };
                }

                const sc  = g_seg_carousel.?;
                const off = carouselOffsetFrom(sc.start_ms, sc.cycle_w);
                sc.cp.blitFrame(dc.drawable, dc.gc, text_x, avail_w, off, sc.cycle_w);
            }
        }
    }
}

fn compareWindows(_: void, a: WindowInfo, b: WindowInfo) bool {
    if (a.minimized != b.minimized) return !a.minimized;
    if (a.x != b.x) return a.x < b.x;
    if (a.y != b.y) return a.y < b.y;
    return a.window < b.window;
}

fn fetchProperty(conn: *xcb.xcb_connection_t, win: u32, atom: u32, atom_type: u32, allocator: std.mem.Allocator) !?[]const u8 {
    const cookie = xcb.xcb_get_property(conn, 0, win, atom, atom_type, 0, 8192);
    const reply  = xcb.xcb_get_property_reply(conn, cookie, null) orelse return null;
    defer std.c.free(reply);
    const len = xcb.xcb_get_property_value_length(reply);
    if (len <= 0) return null;
    const value: [*]const u8 = @ptrCast(xcb.xcb_get_property_value(reply));
    return try allocator.dupe(u8, value[0..@intCast(len)]);
}

fn getWindowTitle(conn: *xcb.xcb_connection_t, window: u32, allocator: std.mem.Allocator) !?[]const u8 {
    atoms.ensure();
    if (atoms.net_wm_name != 0) {
        if (try fetchProperty(conn, window, atoms.net_wm_name, atoms.utf8Type(), allocator)) |t| return t;
    }
    return try fetchProperty(conn, window, xcb.XCB_ATOM_WM_NAME, xcb.XCB_ATOM_STRING, allocator);
}

fn getFocusedWindowTitle(
    conn:                 *xcb.xcb_connection_t,
    focused_window:       ?u32,
    cached_title:         *std.ArrayList(u8),
    cached_title_window:  *?u32,
    title_invalidated:    bool,
    allocator:            std.mem.Allocator,
) ![]const u8 {
    const win = focused_window orelse {
        cached_title_window.* = null;
        return "";
    };

    // Use cache if the window matches and the title hasn't been invalidated.
    if (!title_invalidated and cached_title_window.* == win and cached_title.items.len > 0)
        return cached_title.items;

    atoms.ensure();
    const utf_type = atoms.utf8Type();

    if (atoms.net_wm_name != 0) {
        if (try utils.fetchPropertyToBuffer(conn, win, atoms.net_wm_name, utf_type, cached_title, allocator)) |title| {
            if (title.len > 0) { cached_title_window.* = win; return title; }
        }
    }

    const title = (try utils.fetchPropertyToBuffer(conn, win, xcb.XCB_ATOM_WM_NAME, xcb.XCB_ATOM_STRING, cached_title, allocator)) orelse "";
    if (title.len > 0) cached_title_window.* = win;
    return title;
}

/// Fetches the title of `win` into `buf` (an ArrayListUnmanaged), reusing its
/// existing capacity. Called by bar.captureIntoSlot on the main thread so that
/// the bar render thread never makes blocking X11 round-trips.
pub fn fetchFocusedTitleInto(
    conn:      *xcb.xcb_connection_t,
    win:       u32,
    buf:       *std.ArrayListUnmanaged(u8),
    allocator: std.mem.Allocator,
) !void {
    atoms.ensure();
    const utf_type = atoms.utf8Type();

    if (atoms.net_wm_name != 0) {
        if (utils.fetchPropertyToBuffer(conn, win, atoms.net_wm_name, utf_type, buf, allocator) catch null) |t| {
            if (t.len > 0) return;
        }
    }
    _ = utils.fetchPropertyToBuffer(conn, win, xcb.XCB_ATOM_WM_NAME, xcb.XCB_ATOM_STRING, buf, allocator) catch {};
}
