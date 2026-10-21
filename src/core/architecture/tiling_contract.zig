//! The cross-engine tiling vocabulary: the layout registry, the interchange types
//! (`Layout`/`View`/`List`/`Placement`/`Env`/`HintsView`), and the registry
//! helpers. Lives in `core/architecture/` — NOT `src/tiling/` — because core and
//! the bar both reach this vocabulary while `src/tiling/` is deletable by the
//! modularity matrix. Pure vocabulary: no X11, no features.

const std = @import("std");
const build_options = @import("build_options");
const model = @import("model");
const bounded = @import("bounded");

/// The tiling registry (build-generated), re-exported here so consumers share ONE
/// conditional-import definition instead of copy-pasting the guard. Empty when the
/// tiling subsystem is absent.
///
/// Gated on `has_tiling_registry`, NOT `has_tiling`: the registry module is
/// generated only while at least one layout module binds `Layout`. Deleting every
/// layout file leaves the engine source in place but emits no `tiling_modules`, so
/// a `has_tiling` import would fail to resolve. An empty registry degrades the same
/// way the absent subsystem does: `moduleOf` returns null. This is the file's ONE
/// deliberate edge into a generated implementation module.
///
/// Typed as a SLICE (not inferred): the empty branch is a `*const [0]Layout`, and
/// `&tiling_mods` call sites would then pass a `*const *const [0]Layout` that no
/// longer coerces to `[]const Layout`. A slice type makes both branches coerce
/// uniformly and lets call sites pass the value without `&`.
pub const tiling_mods: []const Layout =
    if (build_options.has_tiling_registry) &@import("tiling_modules").modules else &.{};

/// The neutral layout: registry index 0, the fallback for an unresolvable config
/// layout name and for a restored `kind` that no longer resolves. NAMED because the
/// bare index hides the consequence -- index 0 is whatever the sorted registry puts
/// first, so a name typo would otherwise quietly pick a different layout. Every
/// degradation path names this constant so "falls back to layout 0" stays visible.
pub const default_kind: u8 = 0;

/// Bounds-checked registry lookup for `kind`; null when out of range (including
/// the absent-tiling empty registry). Takes the registry AS A PARAMETER matching
/// `providerOf`'s shape, so tests inject a fake layout set while production sites
/// pass `tiling_mods` via `moduleOf`. Every consumer wanting a layout module BY
/// INDEX dispatches through this: moduleName/variantCount/compute, the
/// pre-reconcile duty, viewport and fifo metadata, and the handoff restore
/// fallback.
pub fn moduleOfRegistry(mods: []const Layout, kind: u8) ?*const Layout {
    if (kind >= mods.len) return null;
    return &mods[kind];
}

/// Production wrapper over `tiling_mods`, so call sites don't each name the
/// registry; tests wanting a fake registry call `moduleOfRegistry` directly.
pub fn moduleOf(kind: u8) ?*const Layout {
    return moduleOfRegistry(tiling_mods, kind);
}

/// The active tiling layout registry index when the model-derived `kind` is live
/// for the built registry under the tiling-enabled config fact; null otherwise
/// (disabled, or subsystem absent: all windows float by definition). Takes `kind`
/// as a PARAMETER so callers pass the live value from
/// `pipeline.getCurrentLayout()` and this applies the registry/tiling gates once
/// instead of each caller repeating them. `tiling_enabled` is a parameter rather
/// than read from `core` because this file is X-free and `core` is not — which also
/// keeps the gate visible in the signature.
pub fn activeLayoutKind(kind: u8, tiling_enabled: bool) ?u8 {
    if (!tiling_enabled) return null;
    if (moduleOf(kind) == null) return null;
    return kind;
}

/// The active layout's bar metadata, as one call the layout and variants segments
/// share instead of each repeating the gate-plus-lookup pair and supplying its own
/// fallback. `pick` receives the resolved module, so the caller owns only its OWN
/// per-segment fallback text ("no variant icon" vs "><>") — the one shape that
/// genuinely differs between the two callers; a third consumer would otherwise
/// drift them.
///
/// The parameter is `Layout` by name, not `@TypeOf(tiling_mods[0])`: with the tiling
/// module removed the registry is EMPTY and indexing [0] to name a type is a compile
/// error in exactly the build that needs the signature. `pick` returns null when the
/// layout has no entry for this segment's dimension — a DIFFERENT condition from the
/// gates above — so null propagates to the caller's own fallback rather than becoming
/// an empty string the caller might want to draw.
pub fn activeLayoutMeta(
    kind: u8,
    tiling_enabled: bool,
    comptime pick: fn (Layout) ?[]const u8,
    fallback: []const u8,
) []const u8 {
    return activeLayoutMetaFrom(tiling_mods, kind, tiling_enabled, pick, fallback);
}

/// Registry-parameter form of `activeLayoutMeta`: same gates and lookup over
/// an injected `mods` slice. The production wrapper passes the `tiling_mods`
/// singleton; a test passes a fake layout set to exercise pick/fallback without
/// the build-generated registry.
pub fn activeLayoutMetaFrom(
    mods: []const Layout,
    kind: u8,
    tiling_enabled: bool,
    comptime pick: fn (Layout) ?[]const u8,
    fallback: []const u8,
) []const u8 {
    if (mods.len == 0) return fallback;
    if (!tiling_enabled) return fallback;
    const resolved = moduleOfRegistry(mods, kind) orelse return fallback;
    return pick(resolved.*) orelse fallback;
}

/// The tiling-layout hook set. Every module under the tiling owner's `modules/`
/// directory binds its `pub const module` to this type. build.zig scans that
/// directory and emits a `tiling_modules` registry; the engine resolves the active
/// layout (a `u8` registry index in `model.LayoutParams.kind`) and dispatches
/// through this contract, so adding a layout is a drop-in file and removing one
/// just shortens the registry.
pub const Layout = struct {
    /// Canonical name ("master", "monocle", ...): config text resolves to the
    /// module by name, and names also drive the cycle order (config order wins).
    name: []const u8 = "",
    /// Placement computation. CONTRACT: must append exactly one placement per window
    /// in `View.order` order — the sink consumes `List` positionally, so a skipped,
    /// duplicated, or reordered window is a silently wrong screen rather than a
    /// visible failure. `tiling.compute` asserts this at the dispatch site.
    compute: ?*const fn (*const View, *List) void = null,
    /// Number of variants this layout exposes for cycle_variant actions.
    variant_count: u8 = 1,
    /// Variant index that toggles "fifo" spawn behavior (master-stack), if any.
    fifo_variant: ?u8 = null,
    /// Parses a config VALUE-STRING (e.g. "lifo", "fifo", "gaps", "gapless",
    /// "relaxed", "rigid") into this layout's variant index (< variant_count), or
    /// null when the string is not one of its values. The module decides which
    /// spellings map to which indices, so variant tables are fully registry-driven.
    /// null = this layout takes no per-variant value strings.
    variant_parse: ?*const fn ([]const u8) ?u8 = null,
    // Scroll viewport addon hooks (only the scroll layout registers them;
    // "is scroll in use" == "the active layout provides these hooks").
    slotWidth: ?*const fn (u16) i32 = null,
    maxOffset: ?*const fn (usize, i32, u16) i32 = null,
    /// Pure pre-reconcile duty: takes `LayoutParams` BY VALUE and returns the
    /// updated params (snap-right on count growth, viewport clamp). The
    /// pipeline choke point applies the delta; layout modules never receive a
    /// mutable pointer into the model.
    preReconcile: ?*const fn (model.LayoutParams, usize, u16) model.LayoutParams = null,
    // Bar rendering metadata (layout/variants segments render generically).
    icon: ?[]const u8 = null,
    indicators: ?[]const []const u8 = null,
};

/// The tiling-layout interchange vocabulary: data handed between the reconciler
/// (sync) and any layout module's `compute`. It lives on the CONTRACT (not the
/// engine module) so the always-compiled reconciler can reference it even when no
/// tiling modules are present — everything goes through this one owned definition
/// instead of a must-stay-in-lockstep duplicate.
pub const View = struct {
    order: []const model.WindowId,
    params: *const model.LayoutParams,
    workarea: model.Rect,
    /// BY VALUE, not a pointer to a caller's stack local: a pointer could let the
    /// `HintsView` outlive the frame that owned it for as long as any layout module
    /// kept the `View`, and nothing in the type would say so. A value cannot dangle.
    /// Index-aligned with `order`; lookups go through `hintsFor` so the order slice
    /// is not stored twice.
    hints: HintsView,
    focused: ?model.WindowId,
    // Environment resolved by the CALLER from config.
    env: Env = .{},

    /// Frozen size-hint lookup for one window: a scan over the (small) `order`
    /// slice, default fallback when absent. A method on `View` because `View`
    /// already owns `order`.
    pub fn hintsFor(self: View, win: model.WindowId) model.SizeHints {
        std.debug.assert(self.order.len == self.hints.len);
        for (self.order, self.hints) |w, h| {
            if (w == win) return h;
        }
        return .{};
    }
};

/// Sentinel rect for parked placements: the zero rect. The sync layer derives
/// parked geometry from its own policy, never from this.
pub const parked_rect: model.Rect = .{ .x = 0, .y = 0, .width = 0, .height = 0 };

/// A placement computed for one window (see View.order).
pub const Placement = struct {
    win: model.WindowId,
    rect: model.Rect,
    visible: bool,
};

/// Zero-allocation placement buffer (one entry per stored window).
pub const List = bounded.BoundedList(Placement, model.store_capacity);

/// Frozen size-hint snapshot: one hint per window in `View.order`, same length,
/// same index; materialized by the caller each reconcile. A named alias rather
/// than a struct, which would also carry a duplicate `order` slice.
pub const HintsView = []const model.SizeHints;

/// Caller-resolved environment, one bundled field per layout knob instead of
/// per-layout booleans each new layout would grow. Resolved from config by the
/// reconciler's caller; the core carries no layout-feature booleans.
///
/// The variant index is NOT a field here: it is config- and workspace-owned state
/// living in `View.params.variant_idx`. A second home here would be the copy layout
/// modules actually read, so a params change that forgot to refresh it would drive
/// layout from a stale variant. Each module reads `v.params.variant_idx` and
/// translates it to its own spelling.
pub const Env = struct {
    margins: model.Margins = .{},
    min_dim: u16 = 0,
    primary_on_right: bool = false,
};
