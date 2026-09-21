//! Shared bar vocabulary for the segment modules.
//!
//! This is NOT a bar segment module: it holds the type-free vocabulary every
//! segment module (and bar.zig) imports -- `Frame` (live workspace visitability),
//! `DrawCtx` (the per-frame scratch bar builds for each segment's draw), the
//! title render/snapshot machinery, and the prompt service-handle struct.
//!
//! Segments are discovered under the bar's `modules/` directory and register
//! into the build-generated `bar_modules.modules` array; the bar orchestrator
//! iterates that array with uniform loops. This file sits beside them (not
//! inside the scanned dir) so it is never itself registered.
//!
//! Rendering uses per-segment dirty tracking: only dirty segments are
//! repainted on each frame, and the dirty set is registry-sized.

const std = @import("std");
const core = @import("core");
const constants = @import("constants");
const utils = @import("utils");
const build_options = @import("build_options");

const drawing = @import("drawing");
const types = @import("types");
const pipeline = @import("pipeline");
const plugin = @import("plugin");

/// Service handles the bar passes into mechanism segments (the prompt) at
/// init. Passed once so segments never import the bar orchestrator;
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
/// shared DrawCtx. The title segment owns all minimized-window
/// knowledge (gated on `build_options.has_minimize`); the bar invokes these
/// hooks through the registry-dispatched DrawCtx so bar.zig never names a
/// window addon. `m` is the live model passed as `*const anyopaque`
/// (type-free seam); the title segment casts back.
pub const MinimizedApi = struct {
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
/// snapshot slots below are filled by the bar each frame from in-process
/// caches.
pub const DrawCtx = struct {
    dc: *drawing.DrawContext,
    config: types.BarConfig,
    height: u16,
    conn: core.Connection,
    allocator: std.mem.Allocator,

    /// Reserved row width for the segment currently being drawn.
    width: u16 = 0,

    /// Title addon's minimized-state service (registered each draw). The
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
// can reach it without naming the title segment).
// ============================================================================

/// Minimum reserved row width for the title segment.
pub const title_min_width: u16 = 100;

/// Maximum number of windows rendered in split-view; the single bar-wide cap
/// (whole batch, per-window scratch, and title gather all bound to it).
pub const max_visible_windows = constants.max_tiled_windows;

/// Off-screen sentinel: sorts last in position, drawing is skipped.
pub const offscreen_rect: utils.Rect = .{
    .x = std.math.maxInt(i16),
    .y = std.math.maxInt(i16),
    .width = 0,
    .height = 0,
};

pub const WindowInfo = struct {
    window: u32,
    x: i16,
    y: i16,
    title: []const u8,
    minimized: bool,
};

/// Stable per-call rendering context: geometry, draw state, and connection.
pub const TitleRenderContext = struct {
    dc: *drawing.DrawContext,
    config: types.BarConfig,
    height: u16,
    start_x: u16,
    width: u16,
    conn: core.Connection,
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

/// Builds the sorted WindowInfo list for the split view from the snapshot's
/// per-window titles/geoms. The bar already resolved both per window id from
/// in-process caches (WM title cache + sync truth-rect), so nothing here
/// touches the wire and no positional batch exists to scramble. Windows with
/// an unknown geometry are dropped, not padded.
fn gatherAndSortWindowInfos(
    snapshot: TitleSnapshot,
    windows: []const u32,
    win_count: usize,
    out_window_info_buf: *[max_visible_windows]WindowInfo,
) !?[]WindowInfo {
    var info_count: usize = 0;
    for (windows[0..win_count], 0..) |win, i| {
        const geom = snapshot.geoms[i] orelse continue;
        out_window_info_buf[info_count] = .{
            .window = win,
            .x = geom.x,
            .y = geom.y,
            .title = snapshot.titles[i],
            .minimized = snapshot.minimized_set.contains(win),
        };
        info_count += 1;
    }
    if (info_count == 0) return null;
    const window_infos = out_window_info_buf[0..info_count];
    std.mem.sort(WindowInfo, window_infos, {}, compareWindows);
    return window_infos;
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

    pub fn gather(
        self: *GatherScratch,
        snapshot: TitleSnapshot,
        windows: []const u32,
        win_count: usize,
    ) !?[]WindowInfo {
        return gatherAndSortWindowInfos(snapshot, windows, win_count, &self.window_infos);
    }
};

/// A window resolved from a click inside the title segment.
pub const ClickTarget = struct {
    window: u32,
    minimized: bool,
};

/// Resolves which window (if any) is displayed at `offset_x` pixels into the
/// title segment, relative to the segment's start_x.
/// Pure in-process hit-testing: titles/geoms come from the snapshot's cached
/// per-window values, so it never touches the wire.
pub fn hitTest(
    ctx: TitleRenderContext,
    snapshot: TitleSnapshot,
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
    const sorted = (try scratch.gather(snapshot, windows, win_count)) orelse
        return null;

    const n: u32 = @intCast(sorted.len);
    const idx: usize = @intCast(@min(
        n - 1,
        @divFloor(@as(u32, offset_x) * n, @as(u32, ctx.width)),
    ));
    const info = sorted[idx];
    return .{ .window = info.window, .minimized = info.minimized };
}

/// Which core fact-revision to mark-dirty with. Mirrors the `DirtySources`
/// packed bitmask over bar segments; the bar calls `markDirtySource(src)` and
/// every module whose `dirty_sources` declares that bit gets repainted.
pub const DirtySourcesSource = enum { focus, frame };

/// True when `sources` has the `source` bit set.
pub fn hasSource(sources: plugin.DirtySources, source: DirtySourcesSource) bool {
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

/// Resolves the registry index of the first module whose capability field
/// `name` is set (e.g. "self_ticking"), or null when no module claims it
/// (first-match wins, like `idByName`). Used by the bar to locate role-bearing
/// segments without naming them. Comptime-friendly: the returned index can
/// feed `const` role ids so role-null guards dead-code-eliminate.
pub fn findByCapability(
    modules: []const @import("plugin").Segment,
    comptime name: []const u8,
) ?usize {
    for (modules, 0..) |m, i| {
        if (@field(m, name)) return i;
    }
    return null;
}

/// Index of the currently active tiling layout in the build-generated layout
/// registry, or null when tiling is disabled or the tiling subsystem is absent
/// (all windows float by definition). Bounded to the registry length so the
/// caller can index `tiling_mods` directly. Shared by the layout/variants bar
/// segments, which disagree only on what metadata they render from it.
pub fn currentLayoutKind() ?u8 {
    if (!core.getState().config.tiling.enabled) return null;
    if (!build_options.has_tiling) return null;
    const kind = pipeline.getCurrentLayout();
    if (kind >= plugin.tiling_mods.len) return null;
    return kind;
}
