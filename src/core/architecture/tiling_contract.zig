//! The cross-engine tiling vocabulary: the layout registry, the layout
//! interchange types (`Layout`/`View`/`List`/`Placement`/`Env`/`HintsView`),
//! and the registry helpers (`moduleOf`, `activeLayoutKind`,
//! `activeLayoutMeta`, `default_kind`, `parked_rect`, `tiling_mods`).
//! Lives in `core/architecture/` — NOT under `src/tiling/` — because core
//! (reconcile, pipeline) and the bar (layout/variants segments) both reach
//! this vocabulary, and `src/tiling/` is deletable by the modularity matrix.
//! Pure vocabulary, no X11, no feature imports.

const std = @import("std");
const build_options = @import("build_options");
const model = @import("model");
const bounded = @import("bounded");

/// The tiling registry (build-generated). Re-exported here so consumers share
/// one conditional-import definition instead of copy-pasting the
/// `has_tiling_registry` guard across files. Empty when the tiling subsystem
/// is absent.
///
/// Gated on `has_tiling_registry`, NOT `has_tiling`: the registry module is
/// generated only while at least one layout module binds the `Layout`
/// contract (see build.zig `hasTilingRegistry`). Deleting every layout file
/// -- which the modularity matrix does in its "all tiling layouts removed"
/// scenario -- leaves the engine source in place (`has_tiling` true) but
/// emits no `tiling_modules` module, so importing it behind `has_tiling`
/// would fail to resolve. An empty registry is the same degradation path the
/// absent subsystem takes: `moduleOf` returns null and everything floats.
///
/// This is the file's ONE edge into a generated implementation module, and it
/// is deliberate -- see `activeLayoutKind` for why.
pub const tiling_mods =
    if (build_options.has_tiling_registry) @import("tiling_modules").modules else &[_]Layout{};

/// The neutral layout: registry index 0, the fallback for an unresolvable
/// config layout name and for a restored `kind` that no longer resolves.
///
/// NAMED because the index alone hides the consequence: index 0 is whatever
/// the sorted registry happens to put first, so a typo in a layout name would
/// otherwise quietly select a different layout. Every degradation path
/// (unresolvable name, removed layout, pre-init state) names this constant, so
/// "falls back to layout 0" stays visible at the call site.
pub const default_kind: u8 = 0;

/// Bounds-checked registry lookup for `kind` (the single owner of the
/// `kind >= tiling_mods.len` guard). Returns the registry entry, or null when
/// kind is out of range (including the absent-tiling empty registry). Every
/// consumer that wants a layout module BY INDEX dispatches through this:
/// moduleName/variantCount/compute, the pre-reconcile duty, viewport and
/// fifo metadata, and the handoff restore fallback.
pub fn moduleOf(kind: u8) ?*const Layout {
    if (kind >= tiling_mods.len) return null;
    return &tiling_mods[kind];
}

/// The active tiling layout registry index, when the model-derived `kind` is
/// live for the built layout registry under the tiling-enabled config fact;
/// null otherwise (disabled, or the tiling subsystem absent: all windows float
/// by definition). Takes the kind as a PARAMETER, so callers pass the live
/// value from `pipeline.getCurrentLayout()` (the layout/variants bar segments)
/// and this applies the registry/tiling gates they would otherwise each repeat.
///
/// The generated `tiling_modules` registry re-exported at the top of this file
/// (see `tiling_mods`) is this file's ONE edge into an implementation module,
/// and it is deliberate -- it is what lets `moduleOf` resolve a name and a
/// variant count through the same registry the layout modules bind to.
/// Everything else here reaches a module through the registry passed in by the
/// caller, and the bar layer is reached only as `*anyopaque` (see `Segment`).
/// `tiling_enabled` is passed in rather than read from `core` because this file
/// is X-free and `core` is not: the caller already has the live config fact,
/// and making it a parameter is what keeps the gate visible in the signature
/// instead of hidden behind an import.
pub fn activeLayoutKind(kind: u8, tiling_enabled: bool) ?u8 {
    if (!tiling_enabled) return null;
    if (moduleOf(kind) == null) return null;
    return kind;
}

/// The active layout's bar metadata, as one call the layout and variants
/// segments share instead of each repeating the gate-plus-lookup pair and
/// supplying its own fallback. `pick` receives the resolved registry module so
/// the caller owns only its OWN fallback text, which is genuinely
/// per-segment ("no variant icon" vs "><>").
///
/// The two callers are the section's only copy-paste and would drift the
/// moment a third consumer appears; the shape that genuinely differs between
/// them is the fallback, so that is the only thing parameterised.
/// `kind` stays a parameter (the live value from `pipeline.getCurrentLayout()`)
/// for the same reason `activeLayoutKind` takes one: this file reads no
/// pipeline state.
///
/// The parameter is `Layout` by name, not `@TypeOf(tiling_mods[0])`: with the
/// tiling module removed the registry is EMPTY, and indexing [0] to name a
/// type is a compile error in exactly the build that needs the signature.
/// `pick` returns null when the layout has no entry for this segment's
/// dimension (no icon, no indicator, variant out of range), which is a
/// DIFFERENT condition from the gates above -- so null propagates to the
/// caller's own fallback rather than being an empty string the caller might
/// legitimately want to draw.
pub fn activeLayoutMeta(
    kind: u8,
    tiling_enabled: bool,
    comptime pick: fn (Layout) ?[]const u8,
    fallback: []const u8,
) []const u8 {
    if (tiling_mods.len == 0) return fallback;
    const resolved = activeLayoutKind(kind, tiling_enabled) orelse return fallback;
    return pick(tiling_mods[resolved]) orelse fallback;
}

/// The tiling-layout hook set. Every module under the tiling owner's `modules/`
/// directory binds its `pub const module` value
/// to this type. build.zig scans the tiling `modules/` and emits a
/// `tiling_modules` registry; the engine resolves the active layout (a
/// `u8` registry index in `model.LayoutParams.kind`) and dispatches through
/// this contract, so adding a layout is a drop-in file and removing one just
/// shortens the registry (kind restore falls back to the first entry).
///
/// `compute` receives the interchange vocabulary typed directly: `view` is
/// `*const View` and `out` a `*List` to append placements to (both defined
/// next to this contract below). Layouts with a per-layout pre-reconcile
/// duty (scroll viewport snapping) bind `preReconcile`, which takes the
/// workspace's `LayoutParams` BY VALUE (see its doc).
pub const Layout = struct {
    /// Canonical name ("master", "monocle", ...). Config text resolves to the
    /// module by name; names also drive the cycle order (config order wins).
    name: []const u8 = "",
    /// Placement computation. CONTRACT: must append exactly one placement per
    /// window in `View.order` order -- the sink consumes `List` positionally,
    /// so a skipped, duplicated, or reordered window is a silently wrong
    /// screen rather than a visible failure. `tiling.compute` asserts this at
    /// the dispatch site.
    compute: ?*const fn (*const View, *List) void = null,
    /// Number of variants this layout exposes for cycle_variant actions.
    variant_count: u8 = 1,
    /// Variant index that toggles "fifo" spawn behavior (master-stack), if any.
    fifo_variant: ?u8 = null,
    /// Parses a config VALUE-STRING (e.g. "lifo", "fifo", "gaps", "gapless",
    /// "relaxed", "rigid") into this layout's variant index (< variant_count),
    /// or null when the string is not one of its values. Config-driven
    /// variant resolution calls this (see config/model_config.zig); a
    /// module that binds it decides which spellings map to which indices, so
    /// the variant tables are fully registry-driven. null = this layout does
    /// not accept per-variant value strings.
    variant_parse: ?*const fn ([]const u8) ?u8 = null,
    // Scroll viewport addon hooks (only the scroll layout registers them;
    // "is scroll in use" == "the active layout provides these hooks").
    slotWidth: ?*const fn (u16) i32 = null,
    maxOffset: ?*const fn (usize, i32, u16) i32 = null,
    /// Pure pre-reconcile duty: takes the workspace's layout params BY VALUE
    /// and returns the updated params (snap-right on count growth, viewport
    /// clamp). The pipeline choke point applies the returned delta; layout
    /// modules never receive a mutable pointer into the model.
    preReconcile: ?*const fn (model.LayoutParams, usize, u16) model.LayoutParams = null,
    // Bar rendering metadata (layout/variants segments render generically).
    icon: ?[]const u8 = null,
    indicators: ?[]const []const u8 = null,
};

/// The tiling-layout interchange vocabulary: the data handed between the
/// reconciler (sync) and any layout module's `compute`. These live on the
/// CONTRACT (not the engine module) so the always-compiled reconciler can
/// reference them even when no tiling modules are present — the engine
/// re-exports them (the tiling registry points at it) while sync and the layout
/// modules refer to them through the single owned definition, removing a
/// must-stay-in-lockstep duplicate.
pub const View = struct {
    order: []const model.WindowId,
    params: *const model.LayoutParams,
    workarea: model.Rect,
    /// BY VALUE, not a pointer to a caller's stack local: a pointer could let
    /// the `HintsView` outlive the frame that owned it for as long as any
    /// layout module kept the `View`, and nothing in the type would say so. A
    /// value cannot dangle, and every call site already has the struct in
    /// hand. The hints themselves are index-aligned with `order`; lookup goes
    /// through `hintsFor` so the order slice is not stored twice.
    hints: HintsView,
    focused: ?model.WindowId,
    // Environment resolved by the CALLER from config.
    env: Env = .{},

    /// Frozen size-hint lookup for one window: a scan over the (small)
    /// `order` slice, default fallback when the window is absent. Lives on
    /// `View` because `View` already owns `order` -- a standalone `HintsView`
    /// struct would carry its own copy of `order`, a second field that could
    /// only ever equal this one.
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

/// Frozen size-hint snapshot: one hint per window in `View.order`, same
/// length, same index. The caller materializes it each reconcile; lookup is
/// `View.hintsFor` (scan over the small order slice — no allocator, bounded
/// by `model.max_tiled_per_ws` (64), so a map would add nothing). A named
/// alias rather than a struct: a struct form would also carry an `order`
/// slice that could only ever duplicate `View.order`.
pub const HintsView = []const model.SizeHints;

/// Caller-resolved environment, one bundled field per layout knob instead of
/// per-layout booleans that each new layout would grow. Resolved from config
/// by the reconciler's caller; the core carries no layout-feature booleans.
/// The variant index is NOT a field here: it is config- and workspace-owned
/// state that lives in `View.params.variant_idx`. Storing it here as well
/// would give one fact two homes, with the copy the layout modules actually
/// read -- so a params change that forgot to refresh it would drive layout
/// from a stale variant. Each layout module reads `v.params.variant_idx` and
/// translates it to its own spelling.
pub const Env = struct {
    margins: model.Margins = .{},
    min_dim: u16 = 0,
    primary_on_right: bool = false,
};
