//! Shared bar vocabulary for the segment modules.
//!
//! This is NOT a bar segment module: it holds the type-free vocabulary every
//! segment module (and bar.zig) imports -- `Frame` (live workspace visitability),
//! `DrawCtx` (the per-frame scratch bar builds for each segment's draw), the
//! title render/snapshot machinery, and the prompt service-handle struct.
//!
//! Segments are discovered under `src/bar/modules/` and register into the
//! build-generated `bar_modules.modules` array; the bar orchestrator iterates
//! that array with uniform loops. This file sits beside them (not inside the
//! scanned dir) so it is never itself registered.
//!
//! Rendering uses per-segment dirty tracking: only dirty segments are
//! repainted on each frame, and the dirty set is registry-sized (D13).

const std = @import("std");
const core = @import("core");
const xcb = core.xcb;
const utils = @import("utils");
const refresh = @import("refresh");
const build_options = @import("build_options");

const drawing = @import("drawing");
const types = @import("types");
const actions = @import("actions");
const focus = @import("focus");
const tracking = @import("tracking");
const sync = @import("sync");
const pipeline = @import("pipeline");
const wincache = @import("wincache");
const constants = @import("constants");

/// Service handles the bar passes into mechanism segments (the prompt) at
/// init. Passed once so segments never import the bar orchestrator (D10);
/// one-way bar -> segment only.
pub const BarHandlers = struct {
    /// Force the bar visible + top-of-stack while the prompt is active.
    presentForPrompt: *const fn () void,
    /// Return the bar to whatever pre-prompt state it was actually in.
    dismissAfterPrompt: *const fn () void,
    /// True when `win` is the bar window.
    isBarWindow: *const fn (u32) bool,
};

/// Live workspace state for one bar frame, collected fresh by bar.zig every
/// draw. The only segment-visible slice of WM state (besides what a segment
/// reads directly from core).
pub const Frame = struct {
    workspace_count: u32 = 0,
    current_workspace: u8 = 0,
    is_all_view_active: bool = false,
    workspace_has_windows: []const bool = &.{},
};

/// Minimized-state service the title addon exposes to the bar through the
/// shared DrawCtx (D12). The title segment owns all minimized-window
/// knowledge (gated on `build_options.has_minimize`); the bar invokes these
/// hooks through the registry-dispatched DrawCtx so bar.zig never names a
/// window addon. `m` is the live model passed as `*const anyopaque`
/// (type-free seam, D3); the title segment casts back.
pub const MinimizedApi = struct {
    /// Live per-window minimized query (bar's fetch-key diff + click routing).
    is_minimized: ?*const fn (m: *const anyopaque, win: u32) bool = null,
    /// Synthesize the full minimized-window set into `set` (bar's title shot).
    collect: ?*const fn (
        m: *const anyopaque,
        set: *std.AutoHashMapUnmanaged(u32, void),
        allocator: std.mem.Allocator,
    ) void = null,
};

/// Type-free cast of the bar-built `*anyopaque` back into `*DrawCtx`.
/// Every segment's draw adapter performs this identical cast, so it lives
/// here once instead of being copy-pasted per module.
pub inline fn castDraw(ctx: *anyopaque) *DrawCtx {
    return @ptrCast(@alignCast(ctx));
}

/// Per-frame scratch shared by every segment's `draw(ctx, x)` call. Built once
/// per frame by the bar; `width` is the segment's reserved row width, set by
/// the bar immediately before invoking each segment's draw hook (needed by the
/// title renderer to return its advanced x and by nothing else). The title
/// snapshot slots are filled by the bar each frame (moving the title-data
/// machinery that used to live on bar.zig here, D4).
pub const DrawCtx = struct {
    dc: *drawing.DrawContext,
    config: types.BarConfig,
    height: u16,
    conn: core.Connection,
    allocator: std.mem.Allocator,

    /// Reserved row width for the segment currently being drawn.
    width: u16 = 0,

    /// Title addon's minimized-state service (registered each draw, D12). The
    /// bar caches it into State so it can invoke the synthesis on every scan.
    minimized_api: MinimizedApi = .{},

    frame: Frame,

    // -- Title snapshot (filled by bar each frame) --
    focused_window: ?u32 = null,
    focused_title: []const u8 = "",
    minimized_title: []const u8 = "",
    current_ws_wins: []const u32 = &.{},
    minimized_set: *const std.AutoHashMapUnmanaged(u32, void) = &.{},
    titles: []const []const u8 = &.{},
    geoms: []const ?utils.Rect = &.{},

    /// The title renderer's stable per-frame context (dc/config/height/
    /// start_x/width/conn). The start_x/width are the segment's on-screen box.
    pub fn titleRenderContext(self: *const DrawCtx, start_x: u16, width: u16) TitleRenderContext {
        return .{
            .dc = self.dc,
            .config = self.config,
            .height = self.height,
            .start_x = start_x,
            .width = width,
            .conn = self.conn,
        };
    }

    /// The title renderer's per-frame snapshot, built from the bar-filled slots.
    pub fn titleSnapshot(self: *const DrawCtx) TitleSnapshot {
        return .{
            .focused_window = self.focused_window,
            .focused_title = self.focused_title,
            .minimized_title = self.minimized_title,
            .current_ws_wins = self.current_ws_wins,
            .minimized_set = self.minimized_set,
            .titles = self.titles,
            .geoms = self.geoms,
        };
    }
};

// ============================================================================
// Title render/snapshot machinery (moved here from the title module so the bar
// can reach it without naming the title segment (D4)).
// ============================================================================

/// Minimum reserved row width for the title segment.
pub const title_min_width: u16 = 100;

/// Maximum number of windows rendered in split-view.
const max_visible_windows: usize = 128;

/// Maximum windows addressed by the batch pre-fetch scratch arrays at once.
const max_batch_windows: usize = constants.Limits.max_tiled_windows;

/// Off-screen sentinel: sorts last in position, drawing is skipped.
pub const offscreen_rect: utils.Rect = .{
    .x = std.math.maxInt(i16),
    .y = std.math.maxInt(i16),
    .width = 0,
    .height = 0,
};

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

pub const WindowInfo = struct {
    window: u32,
    x: i16,
    y: i16,
    title: []const u8,
    minimized: bool,
};

/// Stable per-call rendering context: geometry, draw state, connection, and
/// the bar slot's title cache.
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
pub const TitleSnapshot = struct {
    focused_window: ?u32,
    focused_title: []const u8,
    minimized_title: []const u8,
    current_ws_wins: []const u32,
    minimized_set: *const std.AutoHashMapUnmanaged(u32, void),

    titles: []const []const u8 = &.{},
    geoms: []const ?utils.Rect = &.{},
};

/// Extracts a UTF-8 string from an XCB get_property reply and dupes it into
/// `allocator`. Returns null when the reply carries no bytes.
fn extractPropertyString(
    r: *xcb.xcb_get_property_reply_t,
    allocator: std.mem.Allocator,
) !?[]const u8 {
    const len = xcb.xcb_get_property_value_length(r);
    if (len == 0) return null;
    const ptr: [*]const u8 = @ptrCast(xcb.xcb_get_property_value(r));
    return try allocator.dupe(u8, ptr[0..@intCast(len)]);
}

fn gatherAndSortWindowInfos(
    ctx: TitleRenderContext,
    snapshot: TitleSnapshot,
    allocator: std.mem.Allocator,
    windows: []const u32,
    win_count: usize,
    out_window_info_buf: *[max_visible_windows]WindowInfo,
    out_data: FetchedWindows,
) !?[]WindowInfo {
    const info_count = try gatherWindowInfos(
        ctx,
        snapshot,
        allocator,
        windows,
        win_count,
        out_window_info_buf,
        out_data,
    );
    if (info_count == 0) return null;
    const window_infos = out_window_info_buf[0..info_count];
    std.mem.sort(WindowInfo, window_infos, {}, compareWindows);
    return window_infos;
}

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

/// Caller-frame scratch for the gather phase, shared verbatim by hitTest and
/// the title module's draw.
pub const GatherScratch = struct {
    window_infos: [max_visible_windows]WindowInfo = undefined,
    titles: [max_visible_windows][]const u8 = undefined,
    geoms: [max_visible_windows]?utils.Rect = undefined,

    pub fn gather(
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

    pub fn freeBorrowedTitles(
        self: *GatherScratch,
        snapshot: TitleSnapshot,
        win_count: usize,
        allocator: std.mem.Allocator,
    ) void {
        if (!titlesNeedFree(snapshot, win_count)) return;
        for (self.titles[0..win_count]) |t| allocator.free(t);
    }
};

/// A window resolved from a click inside the title segment.
pub const ClickTarget = struct {
    window: u32,
    minimized: bool,
};

/// Resolves which window (if any) is displayed at `offset_x` pixels into the
/// title segment, relative to the segment's start_x.
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
    const sorted = (try scratch.gather(ctx, snapshot, allocator, windows, win_count)) orelse
        return null;

    const n: u32 = @intCast(sorted.len);
    const idx: usize = @intCast(@min(
        n - 1,
        @divFloor(@as(u32, offset_x) * n, @as(u32, ctx.width)),
    ));
    const info = sorted[idx];
    return .{ .window = info.window, .minimized = info.minimized };
}

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

fn tryCollectGeometryReply(
    conn: core.Connection,
    cookie: xcb.xcb_get_geometry_cookie_t,
) ?utils.Rect {
    const r = utils.collectGeometryReply(conn, cookie) orelse return null;
    defer std.c.free(r);
    return utils.rectFromXcb(r, false);
}

const WindowDataBatch = struct {
    conn: core.Connection,
    allocator: std.mem.Allocator,
    net_atom: ?u32,
    utf_type: u32,

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

    fn fire(
        self: *WindowDataBatch,
        windows: []const u32,
        minimized: *const std.AutoHashMapUnmanaged(u32, void),
        has_prefetched_titles: bool,
        has_prefetched_geoms: bool,
    ) void {
        for (windows, 0..) |win, i| {
            if (!has_prefetched_titles) {
                if (self.net_atom) |na| {
                    self.net_wm_cookies[i] = xcb.xcb_get_property(
                        self.conn,
                        0,
                        win,
                        na,
                        self.utf_type,
                        0,
                        8192,
                    );
                }
            }

            self.needs_xcb_geometry[i] = false;
            self.tiling_geoms[i] = null;
            if (!minimized.contains(win)) {
                // LAYERING NOTE: The title segment queries sync.truthRect() to get the
                // canonical geometry for window sorting. This is a deliberate layering
                // inversion: bar segments are read-path UI but need write-path truth data.
                self.tiling_geoms[i] = sync.truthRect(pipeline.model(), win);
                if (self.tiling_geoms[i] == null and !has_prefetched_geoms) {
                    self.geom_cookies[i] = xcb.xcb_get_geometry(self.conn, win);
                    self.needs_xcb_geometry[i] = true;
                }
            }
        }
    }

    fn fetchTitles(
        self: *WindowDataBatch,
        windows: []const u32,
        owned_titles: []?[]const u8,
    ) void {
        for (windows, 0..) |win, i| {
            owned_titles[i] = null;
            self.needs_fallback[i] = false;
            if (self.net_atom != null)
                owned_titles[i] = collectPropertyReply(
                    self.conn,
                    self.net_wm_cookies[i],
                    self.allocator,
                );
            if (owned_titles[i] == null) {
                self.fallback_cookies[i] = xcb.xcb_get_property(
                    self.conn,
                    0,
                    win,
                    xcb.XCB_ATOM_WM_NAME,
                    xcb.XCB_ATOM_STRING,
                    0,
                    8192,
                );
                self.needs_fallback[i] = true;
            }
        }

        for (windows, 0..) |_, i| {
            if (!self.needs_fallback[i]) continue;
            owned_titles[i] = collectPropertyReply(
                self.conn,
                self.fallback_cookies[i],
                self.allocator,
            );
        }
    }

    fn geometryFor(
        self: *WindowDataBatch,
        i: usize,
        minimized: bool,
        prefetched: ?utils.Rect,
    ) ?utils.Rect {
        if (minimized) return offscreen_rect;
        if (self.tiling_geoms[i]) |cached| return cached;
        if (self.needs_xcb_geometry[i])
            return tryCollectGeometryReply(self.conn, self.geom_cookies[i]);
        return prefetched orelse offscreen_rect;
    }
};

pub const Prefetch = struct {
    titles: ?[]const []const u8 = null,
    geoms: ?[]const ?utils.Rect = null,
};

pub const FetchedWindows = struct {
    titles: [][]const u8,
    geoms: []?utils.Rect,
};

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

fn collectPropertyReply(
    conn: core.Connection,
    cookie: xcb.xcb_get_property_cookie_t,
    allocator: std.mem.Allocator,
) ?[]const u8 {
    const r = utils.collectPropertyReply(conn, cookie) orelse return null;
    defer std.c.free(r);
    return extractPropertyString(r, allocator) catch null;
}

/// Non-blocking property-reply fetch: polls for the reply and returns it only
/// if it has ALREADY arrived; otherwise returns null WITHOUT consuming the
/// cookie (the caller may retry on a later event-loop pass). Uses
/// xcb_poll_for_reply, which consumes a cookie only when a reply or error was
/// actually produced, so a null return leaves the request outstanding.
fn tryPollPropertyReply(
    conn: core.Connection,
    cookie: xcb.xcb_get_property_cookie_t,
) ?*xcb.xcb_get_property_reply_t {
    var reply: ?*anyopaque = null;
    var err: ?*xcb.xcb_generic_error_t = null;
    _ = xcb.xcb_poll_for_reply(conn, cookie.sequence, &reply, &err);
    if (reply) |r| return @ptrCast(@alignCast(r));
    if (err) |e| {
        std.c.free(e);
        return null;
    }
    return null;
}

/// An asynchronously-fired title/geometry prefetch batch. `fire` issues all
/// property (+ geometry where the in-process truth cache has no entry) requests
/// for a window set and flushes them, WITHOUT blocking on any reply, so the
/// caller can draw the current frame with stale data. `tryCollect` then pulls
/// the replies on a later event-loop pass once they've arrived.
///
/// Readiness gate: X11 delivers one flush batch's replies in request order, so
/// if the FIRST net_wm reply is available, the rest of the batch (subsequent
/// net_wm replies and every geometry reply) is already buffered. `tryCollect`
/// therefore polls the first cookie; only when it is ready does it drain the
/// whole batch (all non-blocking). A null return leaves the batch untouched
/// for the next pass.
pub const PendingPrefetch = struct {
    conn: core.Connection,
    allocator: std.mem.Allocator,
    net_atom: ?u32,
    utf_type: u32,
    win_count: usize = 0,
    net_wm_cookies: [max_batch_windows]xcb.xcb_get_property_cookie_t = undefined,
    geom_cookies: [max_batch_windows]xcb.xcb_get_geometry_cookie_t = undefined,
    needs_xcb_geometry: [max_batch_windows]bool = undefined,
    tiling_geoms: [max_batch_windows]?utils.Rect = undefined,

    pub fn init(conn: core.Connection, allocator: std.mem.Allocator) PendingPrefetch {
        atoms.ensureResolved();
        return .{
            .conn = conn,
            .allocator = allocator,
            .net_atom = atoms.net_wm_name,
            .utf_type = atoms.utf8AtomType(),
        };
    }

    /// Fires property (+ fallback geometry) requests for `wins` and flushes so
    /// the server can reply in the background. The caller renders the frame
    /// with stale data and calls `tryCollect` on a later pass.
    pub fn fire(
        self: *PendingPrefetch,
        windows: []const u32,
        minimized: *const std.AutoHashMapUnmanaged(u32, void),
    ) void {
        self.win_count = windows.len;
        for (windows, 0..) |win, i| {
            self.net_wm_cookies[i] = undefined;
            if (self.net_atom) |na| {
                self.net_wm_cookies[i] = xcb.xcb_get_property(
                    self.conn,
                    0,
                    win,
                    na,
                    self.utf_type,
                    0,
                    8192,
                );
            }
            self.needs_xcb_geometry[i] = false;
            self.tiling_geoms[i] = null;
            if (!minimized.contains(win)) {
                // LAYERING NOTE: mirrors WindowDataBatch.fire -- reuse the
                // in-process write-path truth when available; only fall back
                // to a wire geometry round-trip otherwise.
                self.tiling_geoms[i] = sync.truthRect(pipeline.model(), win);
                if (self.tiling_geoms[i] == null) {
                    self.geom_cookies[i] = xcb.xcb_get_geometry(self.conn, win);
                    self.needs_xcb_geometry[i] = true;
                }
            }
        }
        // No explicit flush: the property/geometry requests are sent by the
        // caller's end-of-event-batch flush right after this bar pass, so the
        // replies arrive while the WM is back in its event loop (see the
        // deferred-hydrate flow in bar.refreshTitleData). Issuing xcb_flush
        // here would trip the bar's no-explicit-flush layering rule.
    }

    /// Collects the batch into `out`. In `blocking` mode this waits for every
    /// reply (used on reload/prompt paths that need fresh data immediately);
    /// otherwise it is non-blocking and returns false (batch untouched, retry
    /// on a later event-loop pass) until the replies have arrived. Title
    /// strings are duped into `titles_arena` (the caller's title arena), which
    /// is reset only on the commit path so stale strings survive a
    /// not-yet-ready non-blocking return. `minimized` resolves minimized
    /// windows to the off-screen sentinel.
    pub fn collect(
        self: *PendingPrefetch,
        windows: []const u32,
        minimized: *const std.AutoHashMapUnmanaged(u32, void),
        out: FetchedWindows,
        titles_arena: *std.heap.ArenaAllocator,
        blocking: bool,
    ) bool {
        const win_count = windows.len;
        std.debug.assert(win_count <= max_batch_windows);
        std.debug.assert(out.titles.len >= win_count and out.geoms.len >= win_count);
        const allocator = titles_arena.allocator();

        // Readiness gate (non-blocking only): poll the first net_wm reply
        // without consuming on a miss. Missing net_atom means no property
        // request was fired -- nothing to wait on; proceed for geometry only
        // (mostly the in-process truth cache). Once the gate succeeds the whole
        // batch is buffered (in-order delivery), so we reset the arena and
        // re-dup fresh strings.
        var gate_reply: ?*xcb.xcb_get_property_reply_t = null;
        if (!blocking and self.net_atom != null and self.win_count > 0)
            gate_reply = tryPollPropertyReply(self.conn, self.net_wm_cookies[0]) orelse
                return false;
        defer if (gate_reply) |g| std.c.free(g);
        _ = titles_arena.reset(.retain_capacity);

        var owned: [max_batch_windows]?[]const u8 = undefined;
        for (windows, 0..) |win, i| {
            owned[i] = null;
            if (self.net_atom != null) {
                if (i == 0) {
                    if (gate_reply) |g| {
                        owned[0] = extractPropertyString(g, allocator) catch null;
                    }
                } else if (blocking) {
                    owned[i] = collectPropertyReply(
                        self.conn,
                        self.net_wm_cookies[i],
                        allocator,
                    );
                } else if (tryPollPropertyReply(self.conn, self.net_wm_cookies[i])) |r| {
                    defer std.c.free(r);
                    owned[i] = extractPropertyString(r, allocator) catch null;
                }
            }
            // Rare fallback: a window presenting only the legacy WM_NAME
            // property. Resolved synchronously regardless of mode (uncommon).
            if (owned[i] == null and self.net_atom != null) {
                const fb_cookie = xcb.xcb_get_property(
                    self.conn,
                    0,
                    win,
                    xcb.XCB_ATOM_WM_NAME,
                    xcb.XCB_ATOM_STRING,
                    0,
                    8192,
                );
                owned[i] = collectPropertyReply(self.conn, fb_cookie, allocator);
            }
            out.titles[i] = owned[i] orelse "";
            out.geoms[i] = self.geometryFor(i, minimized.contains(win));
        }
        return true;
    }

    fn geometryFor(self: *const PendingPrefetch, i: usize, minimized: bool) ?utils.Rect {
        if (minimized) return offscreen_rect;
        if (self.tiling_geoms[i]) |cached| return cached;
        if (self.needs_xcb_geometry[i])
            return tryCollectGeometryReply(self.conn, self.geom_cookies[i]);
        return null;
    }
};

inline fn titlesNeedFree(snapshot: TitleSnapshot, win_count: usize) bool {
    return snapshot.titles.len < win_count;
}

/// Which core fact-revision to mark-dirty with. Mirrors the `DirtySources`
/// packed bitmask over bar segments; the bar calls `markDirtySource(src)` and
/// every module whose `dirty_sources` declares that bit gets repainted.
pub const DirtySourcesSource = enum { focus, frame };

/// True when `sources` has the `source` bit set.
pub fn hasSource(sources: @import("plugin").DirtySources, source: DirtySourcesSource) bool {
    return switch (source) {
        .focus => sources.focus,
        .frame => sources.frame,
    };
}

/// Resolves a configured segment name to its registry index, or null when no
/// module with that name is compiled in (segment removed or unknown).
pub fn idByName(modules: []const @import("plugin").Segment, name: []const u8) ?usize {
    for (modules, 0..) |m, i| {
        if (std.mem.eql(u8, m.name, name)) return i;
    }
    return null;
}

/// Resolves the registry index of the first module whose capability `check`
/// predicate holds, or null when no module claims it (first-match wins, like
/// `idByName`). `check` is a comptime predicate over a segment (e.g. a struct
/// literal `.{ .self_ticking = true }` compared by field); used by the bar to
/// locate role-bearing segments without naming them. Comptime-friendly: the
/// returned index can feed `const` role ids so role-null guards
/// dead-code-eliminate, just like the `registry_empty` comptime pattern.
pub fn findByCapability(
    modules: []const @import("plugin").Segment,
    comptime check: anytype,
) ?usize {
    for (modules, 0..) |m, i| {
        if (matchCapabilities(m, check)) return i;
    }
    return null;
}

fn matchCapabilities(m: @import("plugin").Segment, comptime check: anytype) bool {
    comptime var ok = true;
    inline for (std.meta.fields(@TypeOf(check))) |f| {
        if (@field(m, f.name) != @field(check, f.name)) {
            ok = false;
            break;
        }
    }
    return ok;
}
