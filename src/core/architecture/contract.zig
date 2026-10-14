//! Pluggable composition contract types for optional subsystems; registration
//! is build-generated. ENTRY file: the two dispatch primitives (`providerOf`,
//! `callAll`), the tiling registry seam, and the layout interchange
//! vocabulary live here; the two closed vocabularies sit in sibling files and
//! are re-exported at their old positions below -- `contract_window.zig`
//! (WindowModule + classification assert) and `contract_segment.zig`
//! (Segment + bar primitives) -- chosen because they share no imports with
//! each other or with these sections. `@import("contract")` stays the single
//! path consumers need (KISS audit file split; the split is a DAG: no
//! sibling imports this entry). Pure core vocabulary, no X11, no feature
//! imports.

const std = @import("std");
const build_options = @import("build_options");
const model = @import("model");

const bounded = @import("bounded");
/// The tiling registry (build-generated). Re-exported here so consumers share
/// one conditional-import definition instead of copy-pasting the
/// `has_tiling` guard across files. Empty when the tiling subsystem is absent.
///
/// This is the file's ONE edge into a generated implementation module, and it
/// is intentional -- see `activeLayoutKind`'s comment for the correction to
/// the "no implementation-module edge" claim that used to sit here.
pub const tiling_mods =
    if (build_options.has_tiling) @import("tiling_modules").modules else &[_]Layout{};

/// The neutral layout: registry index 0, the fallback for an unresolvable
/// config layout name and for a restored `kind` that no longer resolves.
///
/// NAMED because the index alone hid the consequence. Every degradation path
/// (unresolvable name, removed layout, pre-init state) passed a bare `0`, so
/// "falls back to layout 0" was invisible at the call site while being the
/// single most consequential constant in the config layer: index 0 is whatever
/// the sorted registry happens to put first, and a typo in a layout name
/// therefore quietly selected a different layout. Now every use greps.
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
/// One caveat on "no implementation-module edge", because this file used to
/// claim it had none: it does have exactly one, the generated `tiling_modules`
/// registry re-exported at the top of this file (see `tiling_mods`). That edge
/// is deliberate -- it is what lets `moduleOf` resolve a name and a variant
/// count through the same registry the layout modules bind to -- and it is why
/// the claim, not the import, is what was wrong. Everything else here reaches
/// a module through the registry passed in by the caller, and the bar layer is
/// reached only as `*anyopaque` (see `Segment`).
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
/// The two callers were the section's only copy-paste and would have drifted
/// the moment a third consumer appeared; the shape that actually differs
/// between them is the fallback, so that is the only thing left parameterised.
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

// The WindowModule vocabulary lives in `contract_window.zig` (file split);
// this re-export keeps `contract.WindowModule` as the one import path.
pub const WindowModule = @import("contract_window").WindowModule;

/// Dispatch primitives for every generated registry element type
/// (`WindowModule`, `Segment`, ...): exactly TWO -- `providerOf` (first-match
/// lookup) and `callAll` (fan-out). Everything else the dispatch family used
/// to carry has collapsed: `callFirst`/`callFirstBool` were one-line
/// providerOf applications with a single consumer each (their bodies live in
/// the window layer's callHook/callHookBool now), and the fallible fan-out /
/// any-true shapes had one consumer per owner layer -- each states its
/// 3-line `for` where it binds, against the registry it owns, rather than
/// through a comptime-generic helper whose doc cost exceeded its body. All
/// scans honor the registry's deterministic scan order. (The KISS audit's
/// 6->2 collapse; the classification assert above is kept -- see its comment.)
///
/// The single canonical registry-lookup entry: the first module in `registry`
/// that binds the hook `field`, in the registry's deterministic scan order.
/// Returns null when no compiled-in module provides
/// the hook (the "no owner" fallback). Core callers use this to reach a
/// window/bar subsystem through the build-generated registry, never by naming a
/// module. The registry is passed in (not captured) so dispatch sites never
/// depend on the generated-registry layer. The one deliberate exception is
/// this file's own re-export of the generated `tiling_modules`
/// (`tiling_mods` above):
/// `tiling_mods` must shrink to an empty slice when no layout is compiled in,
/// which needs the registry visible here rather than at each of its callers.
/// Returns a POINTER into `registry`, not a copy of the element: a
/// `WindowModule` is 36 function-pointer fields, and returning it by value made
/// every single-binder dispatch copy the whole struct to reach one of them.
/// The registry is build-generated static data (`&[_]WindowModule{...}`), so
/// the pointer is as long-lived as the program; a caller that outlives the
/// registry slice it passed would have been broken before this too, since the
/// by-value return hid the aliasing rather than preventing it.
pub fn providerOf(
    comptime T: type,
    registry: []const T,
    comptime field: std.meta.FieldEnum(T),
) ?*const T {
    var i: usize = 0;
    while (i < registry.len) : (i += 1) {
        if (@field(registry[i], @tagName(field)) != null) return &registry[i];
    }
    return null;
}

/// Fan-out dispatch: calls EVERY module in `registry` that binds `field`, in
/// registry order. Used for lifecycle and multi-binder-capable hooks.
pub fn callAll(
    comptime T: type,
    registry: []const T,
    comptime field: std.meta.FieldEnum(T),
    args: anytype,
) void {
    for (registry) |m| if (@field(m, @tagName(field))) |f| @call(.auto, f, args);
}

// The Segment vocabulary + bar primitives live in `contract_segment.zig`
// (file split); these re-exports keep `contract.<name>` as the one import path.
pub const DirtySources = @import("contract_segment").DirtySources;
pub const BarOverlay = @import("contract_segment").BarOverlay;
pub const KeyPressEvent = @import("contract_segment").KeyPressEvent;
pub const Painted = @import("contract_segment").Painted;
pub const Frame = @import("contract_segment").Frame;
pub const ClickCtx = @import("contract_segment").ClickCtx;
pub const Segment = @import("contract_segment").Segment;

/// The binder lists live ON the contract type (`WindowModule.single_binder_hooks`
/// and `.multi_binder_hooks`) rather than as package-level lists, because the
/// at-most-one assert is a per-CONTRACT claim: the build-generated registry
/// finds it with `@hasDecl(T, "single_binder_hooks")` and enforces it on
/// whichever element type declares it. As package-level lists keyed off
/// `WindowModule` hook names, a `Segment` registry would have checked its own
/// fields against another contract's names -- and found nothing, silently,
/// leaving `Segment`'s at-most-one hooks unenforced.
/// True when `name` appears in `list`; called at comptime by the partition
/// check below.
fn isListed(list: []const []const u8, name: []const u8) bool {
    for (list) |hook| if (std.mem.eql(u8, hook, name)) return true;
    return false;
}

/// Every name in a contract's binder list must be a real field of that
/// contract, and must appear once. A renamed hook left behind in a list would
/// otherwise turn into an `@hasField` that quietly skips -- the exact "unlisted
/// new hook silently escaped" failure the lists exist to prevent, just pointing
/// the other way.
fn assertListedFields(comptime T: type, comptime list_name: []const u8, list: []const []const u8) void {
    for (list) |hook| {
        if (!@hasField(T, hook)) @compileError(
            "T." ++ list_name ++ " lists '" ++ hook ++ "', which is not a " ++ @typeName(T) ++ " field",
        );
    }
}

comptime {
    // 36 fields x up to 27 names, twice over.
    @setEvalBranchQuota(20_000);
    // KEPT by the KISS audit's judgment (the "drop the validation layer"
    // option was considered and rejected): the lists are not documentation
    // dressed as code -- build.zig's generated registry consumes
    // `single_binder_hooks` to reject a second binder at comptime, and that
    // check only runs for names the lists contain. The partition below is
    // what makes "added a hook, forgot to classify it" a compile error
    // instead of an escape from the at-most-one enforcement. ~40 lines of
    // comptime is cheap for that; the dispatch COLLAPSE (6->2) is where the
    // machinery went.
    //
    // Every `WindowModule` field is classified exactly once across the two
    // cardinality lists plus the data list, and no list names a field that no
    // longer exists. `s == m` fails for BOTH the "added a hook, forgot to
    // classify it" case and the "classified it as both" case; a field in
    // `non_hook_fields` skips the check and is instead held to the inverse
    // assert below (a data list naming a removed field is also an error).
    //
    // This is a `WindowModule`-only property, unlike the at-most-one binder
    // count: it holds because every `WindowModule` field is either a hook with
    // a dispatch cardinality or one of the named data fields. `Segment` carries
    // data fields too (name, props, dirty_sources, clickable) and is not
    // partitioned at all -- it declares only the at-most-one hooks and the
    // generated registry enforces the count.
    for (std.meta.fields(WindowModule)) |f| {
        if (isListed(&WindowModule.non_hook_fields, f.name)) continue;
        const s = isListed(&WindowModule.single_binder_hooks, f.name);
        const m = isListed(&WindowModule.multi_binder_hooks, f.name);
        if (s == m) @compileError(
            "WindowModule hook '" ++ f.name ++ "' must be listed in EXACTLY one of " ++
                "single_binder_hooks / multi_binder_hooks (single=" ++
                if (s) "yes" else "no" ++ ", multi=" ++ if (m) "yes" else "no" ++
                    "); it is the dispatch cardinality, not a detail",
        );
    }
    assertListedFields(WindowModule, "single_binder_hooks", &WindowModule.single_binder_hooks);
    assertListedFields(WindowModule, "multi_binder_hooks", &WindowModule.multi_binder_hooks);
    assertListedFields(WindowModule, "non_hook_fields", &WindowModule.non_hook_fields);
    assertListedFields(Segment, "single_binder_hooks", &Segment.single_binder_hooks);
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
    /// the dispatch seam.
    compute: ?*const fn (*const View, *List) void = null,
    /// Number of variants this layout exposes for cycle_variant actions.
    variant_count: u8 = 1,
    /// Variant index that toggles "fifo" spawn behavior (master-stack), if any.
    fifo_variant: ?u8 = null,
    /// Parses a config VALUE-STRING (e.g. "lifo", "fifo", "gaps", "gapless",
    /// "relaxed", "rigid") into this layout's variant index (< variant_count),
    /// or null when the string is not one of its values. Config-driven
    /// variant resolution calls this (see actions.seedParamsFromConfig); a
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
/// re-exports them (the tiling seam points at it) while sync and the layout
/// modules refer to them through the single owned definition, removing a
/// must-stay-in-lockstep duplicate.
pub const View = struct {
    order: []const model.WindowId,
    params: *const model.LayoutParams,
    workarea: model.Rect,
    /// BY VALUE (13.5), not a pointer to a caller's stack local. The pointer
    /// form was the tree's only intra-frame dangling-pointer hazard: the
    /// `HintsView` outlived the frame that owned it for as long as any layout
    /// module kept the `View`, and nothing in the type said so. A value cannot
    /// dangle, and every call site already had the struct in hand. The hints
    /// themselves are index-aligned with `order`; lookup goes through
    /// `hintsFor` so the order slice is not stored twice.
    hints: HintsView,
    focused: ?model.WindowId,
    // Environment resolved by the CALLER from config.
    env: Env = .{},

    /// Frozen size-hint lookup for one window: a scan over the (small)
    /// `order` slice, default fallback when the window is absent. Lives on
    /// `View` because `View` already owns `order` -- the standalone
    /// `HintsView` struct that used to wrap this carried its own copy of
    /// `order`, a second field that could only ever equal this one.
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
/// alias rather than a struct: the struct form also held an `order` slice,
/// which was always assigned the identical `View.order` and so only ever
/// duplicated the field it had to stay in lockstep with.
pub const HintsView = []const model.SizeHints;

/// Caller-resolved environment, one bundled field per layout knob instead of
/// per-layout booleans that each new layout would grow. Resolved from config
/// by the reconciler's caller; the core carries no layout-feature booleans.
/// The variant index is NOT a field here: it is config- and workspace-owned
/// state that lives in `View.params.variant_idx`, and it used to be copied into
/// this struct as well. Two homes for one fact, with the copy the layout
/// modules actually read, so a params change that forgot to refresh the copy
/// would have driven layout from a stale variant. Each layout module reads
/// `v.params.variant_idx` and translates it to its own spelling.
pub const Env = struct {
    margins: model.Margins = .{},
    min_dim: u16 = 0,
    primary_on_right: bool = false,
};
