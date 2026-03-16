//! Title segment — shows the focused window title, or a split view for
//! multiple windows.
//!
//! draw() receives pre-computed snapshot data (conn, focused_window, workspace
//! windows, minimized set) instead of a *core.WM pointer, making it safe to
//! call from the bar rendering thread.
//!
//! Carousel logic lives in carousel.zig.
//! Monitor refresh-rate detection lives in hertz.zig.

const std      = @import("std");
const core     = @import("core");
const xcb      = core.xcb;
const drawing  = @import("drawing");
const utils    = @import("utils");
const carousel = @import("carousel");
const hertz    = @import("hertz");

// Atom cache

const Atoms = struct {
    net_wm_name: u32   = 0,
    utf8_string: u32   = 0,
    initialized: bool  = false,

    fn ensure(self: *Atoms) void {
        if (self.initialized) return;
        self.initialized = true;
        self.net_wm_name = utils.getAtomCached("_NET_WM_NAME") catch 0;
        self.utf8_string = utils.getAtomCached("UTF8_STRING")  catch 0;
    }

    inline fn utf8Type(self: *const Atoms) u32 {
        return if (self.utf8_string != 0) self.utf8_string else xcb.XCB_ATOM_STRING;
    }
};

var atoms: Atoms = .{};

// Types

const WindowInfo = struct {
    window:    u32,
    x:         i16,
    y:         i16,
    title:     []const u8,
    minimized: bool,
};

/// Fixed left indent independent of scaledSegmentPadding.
const TITLE_LEAD_PX: u16 = 4;

// draw — main entry point

/// Draw the title segment.
///
/// Parameters replacing the old `wm: *core.WM`:
///   `conn`              — XCB connection (thread-safe for I/O).
///   `focused_window`    — currently focused window ID, or null.
///   `focused_title`     — pre-fetched on the main thread in captureIntoSlot;
///                         the bar render thread makes zero blocking X11 calls.
///   `current_ws_wins`   — window IDs on the current workspace (snapshot copy).
///   `minimized_set`     — snapshot of minimized window IDs.
///   `title_invalidated` — when true, the cached title is stale and must be
///                         re-fetched.
pub fn draw(
    dc:                   *drawing.DrawContext,
    config:               core.BarConfig,
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
    // Ensure the monitor refresh rate is detected before any carousel call.
    // This is a no-op on every call after the first.
    hertz.ensureDetected(conn);

    const window_count = current_ws_wins.len;

    if (window_count == 0) {
        // No windows on this workspace — tear down any live carousel immediately
        // so it does not keep scrolling invisibly in the background.  When the
        // carousel becomes visible again (e.g. switching back to a workspace
        // with a long window title) it will be rebuilt from scratch and will
        // start scrolling from position 0.
        carousel.deinitCarousel();
        dc.fillRect(start_x, 0, width, height, config.bg);
        return start_x + width;
    }

    const scaled_padding = config.scaledSegmentPadding(height);
    const baseline_y     = dc.baselineY(height);

    if (window_count == 1) {
        const single_win   = current_ws_wins[0];
        const is_minimized = minimized_set.contains(single_win);
        const is_focused   = focused_window != null;

        const accent = if (is_minimized)
            config.getTitleMinimizedAccent()
        else if (is_focused)
            config.getTitleAccent()
        else
            config.bg;
        dc.fillRect(start_x, 0, width, height, accent);

        // Compute text bounds once; both the minimized and focused branches
        // use the same inset position for both static draw and carousel blit.
        const text_x  = start_x + scaled_padding + TITLE_LEAD_PX;
        const avail_w = width -| scaled_padding * 2 -| TITLE_LEAD_PX;

        if (is_minimized) {
            const title = getWindowTitle(conn, single_win, allocator) catch null;
            defer if (title) |t| allocator.free(t);
            if (title) |t| {
                try carousel.drawOrScrollTitle(dc, text_x, baseline_y, avail_w,
                    text_x, avail_w, t, accent, config.fg, single_win, title_invalidated);
            }
        } else {
            // focused_title was pre-fetched on the main thread — zero X11 I/O.
            if (focused_title.len > 0) {
                if (title_invalidated or cached_title_window.* != focused_window) {
                    cached_title.clearRetainingCapacity();
                    cached_title.appendSlice(allocator, focused_title) catch {};
                    cached_title_window.* = focused_window;
                }
                const fg = if (is_focused) config.selected_fg else config.fg;
                try carousel.drawOrScrollTitle(dc, text_x, baseline_y, avail_w,
                    text_x, avail_w, focused_title, accent, fg, focused_window, title_invalidated);
            }
        }
    } else {
        try drawSegmentedTitles(dc, config, height, start_x, width,
            conn, focused_window, current_ws_wins, minimized_set, allocator,
            scaled_padding, title_invalidated);
    }

    return start_x + width;
}

// Private — split-view segmented titles

fn drawSegmentedTitles(
    dc:                *drawing.DrawContext,
    config:            core.BarConfig,
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

    // Free the single-window carousel (mutually exclusive with segmented) and
    // prune the seg-carousel if its window has left the workspace.
    carousel.prepareSegCarousel(win_items);

    const MAX_WINS: usize = 128;
    const n_wins = @min(win_items.len, MAX_WINS);

    atoms.ensure();
    const net_atom = atoms.net_wm_name;
    const utf_type = atoms.utf8Type();

    // All XCB requests for this pass are fired in Phase 1 before any reply is
    // read.  XCB queues them into a single TCP segment (or kernel buffer), so
    // the server can answer all of them after one round-trip instead of one
    // round-trip per window.  With n windows this reduces latency from O(n)
    // to O(1) — critical for a bar that redraws on every key event.
    //
    // Phase 1: fire _NET_WM_NAME cookies AND geometry cookies together.
    var net_cookies:  [MAX_WINS]xcb.xcb_get_property_cookie_t = undefined;
    var geom_cookies: [MAX_WINS]xcb.xcb_get_geometry_cookie_t = undefined;
    var needs_geom:   [MAX_WINS]bool                          = @splat(false);

    for (win_items[0..n_wins], 0..) |win, i| {
        if (net_atom != 0)
            net_cookies[i] = xcb.xcb_get_property(conn, 0, win, net_atom, utf_type, 0, 8192);
        if (!minimized_set.contains(win)) {
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

    // Build WindowInfo list.  Geometry replies are already buffered from Phase 1.
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
    const baseline_y       = dc.baselineY(height);

    for (window_infos, 0..) |info, i| {
        // Pixel-perfect tiling: segment i spans [i*W/n, (i+1)*W/n).
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

            if (is_focused_win and carousel.isCarouselEnabled()) {
                // Focused + carousel enabled: pass the full segment bounds so
                // the scroll covers the entire segment width with no static
                // padding gaps on either side.
                const scrolled = try carousel.blitSegCarousel(
                    dc, segment_x, baseline_y, segment_width, text_w,
                    info.title, accent, text_fg, info.window, title_invalidated,
                );
                if (!scrolled) {
                    // Text fits — draw it inset with normal padding.
                    try dc.drawText(text_x, baseline_y, info.title, text_fg);
                }
            } else {
                // Non-focused or carousel disabled: ellipsis on overflow, never scroll.
                if (text_w <= avail_w)
                    try dc.drawText(text_x, baseline_y, info.title, text_fg)
                else
                    try dc.drawTextEllipsis(text_x, baseline_y, info.title, avail_w, text_fg);
            }
        }
    }
}

// Private helpers — sorting and title fetching

/// Sort order for the split-view segment layout:
///   1. Non-minimized windows before minimized windows (minimized are shown
///      last/rightmost in the bar, matching their visual demotion in tiling).
///   2. Within each group, left-to-right by x position, then top-to-bottom by
///      y position — this preserves the spatial order of tiled windows.
///   3. Tie-break by window ID for deterministic ordering.
fn compareWindows(_: void, a: WindowInfo, b: WindowInfo) bool {
    if (a.minimized != b.minimized) return !a.minimized;
    if (a.x != b.x) return a.x < b.x;
    if (a.y != b.y) return a.y < b.y;
    return a.window < b.window;
}

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

fn getWindowTitle(
    conn:      *xcb.xcb_connection_t,
    window:    u32,
    allocator: std.mem.Allocator,
) !?[]const u8 {
    atoms.ensure();
    if (atoms.net_wm_name != 0) {
        if (try fetchProperty(conn, window, atoms.net_wm_name, atoms.utf8Type(), allocator)) |t|
            return t;
    }
    return try fetchProperty(conn, window, xcb.XCB_ATOM_WM_NAME, xcb.XCB_ATOM_STRING, allocator);
}

// Public — title pre-fetch (called on the main thread by bar.captureIntoSlot)

/// Fetches the title of `win` into `buf`, reusing its existing capacity.
/// Called on the main thread so that the bar render thread never makes
/// blocking X11 round-trips.
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
    _ = utils.fetchPropertyToBuffer(
        conn, win, xcb.XCB_ATOM_WM_NAME, xcb.XCB_ATOM_STRING, buf, allocator,
    ) catch {};
}
