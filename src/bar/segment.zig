//! Shared bar vocabulary for the segment modules.
//!
//! This is NOT a bar segment module: it holds the shared vocabulary every
//! segment module (and bar.zig) imports -- `Frame` (live workspace visitability;
//! an alias for architecture/contract.zig's Frame, so the `naturalWidth` hook
//! can type its frame parameter), `DrawCtx` (the per-frame scratch bar builds
//! for each segment's draw), the title render/snapshot machinery, and the
//! prompt service-handle struct.
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

const drawing = @import("drawing");
const types = @import("types");
const contract = @import("contract");
const model = @import("model");

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
/// The bar's per-frame workspace facts. The DEFINITION lives in
/// architecture/contract.zig so the `naturalWidth` hook can type its first
/// parameter as a real `*const Frame`; this alias keeps `segmod.Frame` as the
/// name every reader already uses.
pub const Frame = contract.Frame;

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

    /// The configured name of the segment currently being drawn, e.g. "cpu" or
    /// "volume". Set by bar.drawSegment from the name it already had in hand,
    /// so a module can resolve its OWN themed colors without a second argument
    /// threaded through the registry draw hook (which is shared by every
    /// segment). Empty when a caller builds a DrawCtx without drawing a
    /// specific segment.
    name: []const u8 = "",

    /// Title addon's minimized-state service (registered each draw). The
    /// bar caches it into State so it can invoke the synthesis on every scan.
    minimized_api: MinimizedApi = .{},

    frame: Frame,

    // Title snapshot (filled by bar each frame)
    focused_window: ?u32 = null,
    focused_title: []const u8 = "",
    minimized_title: []const u8 = "",
    current_ws_wins: []const u32 = &.{},
    minimized_set: *const std.AutoHashMapUnmanaged(u32, void) = &.{},
    titles: []const []const u8 = &.{},
    geoms: []const ?model.Rect = &.{},

    /// The title renderer's stable per-frame context (dc/config/height/
    /// start_x/width/conn). The start_x/width are the segment's on-screen box.
    pub fn titleRenderContext(self: *const DrawCtx, start_x: u16, width: u16) TitleRenderContext {
        return .{
            .dc = self.dc,
            .config = self.config,
            .height = self.height,
            .start_x = start_x,
            .width = width,
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

// Title render/snapshot machinery (moved here from the title module so the bar
// can reach it without naming the title segment).

/// Minimum reserved row width for the title segment.
pub const title_min_width: u16 = 100;

/// Maximum number of windows rendered in split-view; the single bar-wide cap
/// (whole batch, per-window scratch, and title gather all bound to it).
pub const max_visible_windows = constants.max_tiled_windows;

/// Off-screen sentinel: sorts last in position, drawing is skipped.
pub const offscreen_rect: model.Rect = .{
    .x = std.math.maxInt(i16),
    .y = std.math.maxInt(i16),
    .width = 0,
    .height = 0,
};

// The title segment's geometry -- its window list, the pixel-perfect tiling
// shared by its draw and the bar's hit-test -- is not shared segment
// vocabulary. It lives in modules/title/geom.zig, next to the only thing that
// renders it (21.6).

/// Stable per-call rendering context: geometry and draw state. It carries no
/// X connection: the title draw had one only to call
/// `hz.ensureRefreshRateDetected`, which boot (`main`) primes at startup, and
/// a render that mutates global detection state is a phase violation.
pub const TitleRenderContext = struct {
    dc: *drawing.DrawContext,
    config: types.BarConfig,
    height: u16,
    start_x: u16,
    width: u16,
};

/// Per-frame volatile snapshot captured before drawing.
pub const TitleSnapshot = struct {
    focused_window: ?u32,
    focused_title: []const u8,
    minimized_title: []const u8,
    current_ws_wins: []const u32,
    minimized_set: *const std.AutoHashMapUnmanaged(u32, void),

    titles: []const []const u8 = &.{},
    geoms: []const ?model.Rect = &.{},
};

/// Which core fact-revision to mark-dirty with. Mirrors the `DirtySources`
/// packed bitmask over bar segments; the bar calls `markDirtySource(src)` and
/// every module whose `dirty_sources` declares that bit gets repainted.
pub const DirtySourcesSource = enum { focus, frame };

/// True when `sources` has the `source` bit set.
pub fn hasSource(sources: contract.DirtySources, source: DirtySourcesSource) bool {
    return switch (source) {
        .focus => sources.focus,
        .frame => sources.frame,
    };
}

/// Resolves a configured segment name to its registry index, or null when no
/// module with that name is compiled in (segment removed or unknown).
pub fn idByName(modules: []const contract.Segment, name: []const u8) ?usize {
    for (modules, 0..) |m, i| {
        if (std.mem.eql(u8, m.name, name)) return i;
    }
    return null;
}

/// The bar's own registry (the build-generated `bar_modules`
/// array), named here once so the registry-index helpers below
/// serve every consumer -- bar.zig and center_row.zig used to
/// each carry a private copy (review 05-input round 2).
const bar_mods = @import("bar_modules").modules;

/// Registry index for `name` in the bar's own registry, or null
/// when absent (also when the registry is empty: `bar_mods` is
/// then a zero-length array and idByName finds nothing).
pub inline fn segId(name: []const u8) ?usize {
    return idByName(&bar_mods, name);
}

/// True in builds with at least one registered bar segment, false
/// in segment-less builds. Guards every registry index: indexing
/// a zero-length array is a compile error even under a runtime
/// guard, so the empty build drops the whole body before it is
/// analyzed (the `segAt` pattern from bar.zig).
pub inline fn hasRegisteredSegments() bool {
    return comptime bar_mods.len != 0;
}

/// Resolves the registry index of every module whose capability field `name`
/// is set, in registry order. Used by the bar as its ROLE SET: capabilities
/// with multiple binders (self_ticking, center_slot) fan out / split evenly
/// over the whole set rather than first-match wins.
///
/// `name` is a FIELD, not a string: it is typed `std.meta.FieldEnum(Segment)`
/// so a renamed or removed capability is a compile error at every call site.
/// The string form made a typo silently resolve the empty set, which is the
/// same shape as "this role has no binders" -- the failure mode that reads as
/// a working bar with one segment missing.
///
/// Comptime-friendly: when `modules` is comptime-known (a generated registry)
/// the returned slice is a comptime value, so empty-set guards
/// (`.len == 0`) dead-code-eliminate.
pub fn findAllByCapability(
    modules: []const contract.Segment,
    comptime name: std.meta.FieldEnum(contract.Segment),
) []const usize {
    var result: []const usize = &.{};
    for (modules, 0..) |m, idx| {
        if (@field(m, @tagName(name))) {
            result = result ++ [_]usize{idx};
        }
    }
    return result;
}
