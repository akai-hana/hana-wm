//! Shared bar vocabulary for the segment modules.
//!
//! This is NOT a bar segment module: it holds the shared vocabulary every
//! segment module (and bar.zig) imports -- `Frame` (live workspace visitability;
//! an alias for architecture/contract.zig's Frame, so the `naturalWidth` hook
//! can type its frame parameter), `DrawCtx` (the per-frame scratch bar builds
//! for each segment's draw), the shared title constants, and the prompt
//! service-handle struct. The title render/snapshot TYPES live with the title
//! module in `modules/title/vocab.zig` (Phase 4 step 25).
//!
//! It is also the bar's feature-probe surface: the registry-resolved
//! capability helpers (`segId`, `isRole`, `roleIndexOf`,
//! `hasRegisteredSegments`, and the role id-sets such as `self_ticking_ids`)
//! computed against the generated `bar_modules` array, so the bar and its
//! modules locate each other by NAME without importing each other directly.
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
const vocab = @import("vocab");
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

/// The bar's per-frame workspace facts, collected fresh by bar.zig every
/// draw -- the only segment-visible slice of WM state (besides what a segment
/// reads directly from core). The DEFINITION lives in
/// architecture/contract.zig so the `naturalWidth` hook can type its first
/// parameter as a real `*const Frame`; this alias keeps `segmod.Frame` as the
/// name every reader already uses.
pub const Frame = contract.Frame;

/// Minimized-state service the title addon exposes to the bar through the
/// shared DrawCtx. The title segment owns all minimized-window
/// knowledge (gated on `build_options.has_minimize`); the bar invokes these
/// hooks through the registry-dispatched DrawCtx so bar.zig never names a
/// window addon. `m` is the live model passed as `*const anyopaque`
/// (type-free contract); the title segment casts back.
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
    current_ws_entries: []const vocab.TitleEntry = &.{},
    minimized_set: *const std.AutoHashMapUnmanaged(u32, void) = &.{},

    /// The title renderer's stable per-frame context (dc/config/height/
    /// start_x/width/conn). The start_x/width are the segment's on-screen box.
    pub fn titleRenderContext(self: *const DrawCtx, start_x: u16, width: u16) vocab.TitleRenderContext {
        return .{
            .dc = self.dc,
            .config = self.config,
            .height = self.height,
            .start_x = start_x,
            .width = width,
        };
    }

    /// The title renderer's per-frame snapshot, built from the bar-filled slots.
    pub fn titleSnapshot(self: *const DrawCtx) vocab.TitleSnapshot {
        return .{
            .focused_window = self.focused_window,
            .focused_title = self.focused_title,
            .minimized_title = self.minimized_title,
            .entries = self.current_ws_entries,
            .minimized_set = self.minimized_set,
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

/// Which core fact-revision to mark-dirty with: the field names of
/// `contract.DirtySources` itself, so a rename there cannot drift from this
/// enum. The bar calls `markDirtySource(src)` and every module whose
/// `dirty_sources` declares that bit gets repainted.
pub const DirtySourcesSource = std.meta.FieldEnum(contract.DirtySources);

/// True when `sources` has the `source` bit set.
pub fn hasSource(sources: contract.DirtySources, source: DirtySourcesSource) bool {
    return switch (source) {
        inline else => |s| @field(sources, @tagName(s)),
    };
}

/// Resolves a configured segment name to its registry index, or null when no
/// module with that name is compiled in (segment removed or unknown).
fn idByName(modules: []const contract.Segment, name: []const u8) ?usize {
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

/// Registry capability sets (comptime, from the generated registry): the
/// center-slot segments that share the center-row budget, and the
/// self-ticking segments whose merged display width IS that budget's clock
/// reservation. The single home of the sets -- state.zig and center_row.zig
/// each used to resolve their own copy.
pub const center_slot_ids: []const usize = findAllByCapability(&bar_mods, .center_slot);
pub const self_ticking_ids: []const usize = findAllByCapability(&bar_mods, .self_ticking);

/// Index of the registry id `id` within the role set `comptime ids` (the
/// self-ticking and center-slot capability sets today), or null when it is
/// not a member. Name-free: membership is by declared capability, and the set
/// is resolved from the generated registry. A name that does not resolve
/// (null) is a member of nothing.
pub fn roleIndexOf(id: ?usize, comptime ids: []const usize) ?usize {
    const i = id orelse return null;
    inline for (ids, 0..) |rid, j| {
        if (i == rid) return j;
    }
    return null;
}

/// True when the registry id `id` is in the registry role set `ids`.
pub fn isRole(id: ?usize, comptime ids: []const usize) bool {
    return roleIndexOf(id, ids) != null;
}

/// A segment's natural (reserved) width via its uniform naturalWidth hook,
/// or 0 for an unknown/removed segment name (null id, or an empty registry).
/// `clock_width` is the merged clock width the hook receives as its fallback
/// reservation; the hook takes a real `*const contract.Frame`
/// (`segmod.Frame` is an alias for exactly that), so the frame passes
/// through with no cast.
pub fn naturalWidthOf(id: ?usize, frame: *const Frame, clock_width: u16) u16 {
    if (comptime !hasRegisteredSegments()) return 0;
    const i = id orelse return 0;
    if (bar_mods[i].naturalWidth) |nw| return nw(frame, clock_width);
    return 0;
}
/// The whole bar registry as a slice: the ONE way consumers reach the
/// generated array. Every raw `bar_modules` import outside this file routes
/// through here or the helpers above (Phase 4 step 26), so the registry has
/// a single home.
pub inline fn all() []const contract.Segment {
    return &bar_mods;
}

/// Registry entry at a resolved `id`. Callers reach this only after a
/// registry capability/role lookup matched a name; a match is impossible
/// when the registry is empty (guarded like every other index: a zero-length
/// array is a comptime error to index even under a runtime check).
pub inline fn segmentAt(id: usize) *const contract.Segment {
    if (comptime !hasRegisteredSegments()) unreachable;
    return &bar_mods[id];
}

/// Runs the void hook `hook` over every registered segment (the
/// init/teardown/notification family).
pub fn runVoidHook(comptime hook: std.meta.FieldEnum(contract.Segment)) void {
    contract.callAll(contract.Segment, bar_mods[0..], hook, .{});
}

/// True when ANY registered segment's `hook` returns true (short-circuiting
/// walk; the predicate family: keypress routing, elapsed-seconds fan-out,
/// redraw-request folding).
pub fn anyBoolHook(comptime hook: std.meta.FieldEnum(contract.Segment), args: anytype) bool {
    for (bar_mods) |seg| if (@field(seg, @tagName(hook))) |f| if (@call(.auto, f, args)) return true;
    return false;
}
