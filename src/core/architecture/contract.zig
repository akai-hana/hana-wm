//! Pluggable composition contract types for optional subsystems; registration
//! is build-generated. Defines Surfaces and WindowModule hook shapes; pure core
//! vocabulary, no X11, no feature imports.

const std = @import("std");
const types = @import("types");
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
/// fifo metadata, and the persist restore fallback.
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

/// The window sub-system hook set. Every module under a window-owner's
/// `modules/` directory binds its `pub const module` value to this type,
/// binding only the hooks it owns (everything else stays `null`). Dispatch
/// order == the generated registry's order == deterministic filesystem scan
/// order.
pub const WindowModule = struct {
    /// The hooks whose contract is "at most one module binds this": dispatch is
    /// first-match (`providerOf`/`callFirst`/`callFirstBool`), so a second
    /// binder would be silently ignored. Every other hook is adopted by
    /// explicit registry loops (init/deinit, notifyConfigureIfPending,
    /// onWindowGone, the serialize/deserialize persistence seam,
    /// setEwmhFullscreenState, armPendingBarHide/Show) and may have many
    /// binders. The build-generated `window_modules` registry asserts at
    /// comptime that each field below has <= 1 binder.
    pub const single_binder_hooks = [_][]const u8{
        "hideWindow",          "restoreWindow",    "restoreCandidateOn",
        "restoreOnWs",         "latestHiddenOnWs", "isWindowHidden",
        "collectHiddenSet",    "toggleCovering",   "visibleCoveringOnWs",
        "releaseCovering",     "moveCoveringTo",   "sendToWs",
        "addToWs",             "removeFromWs",     "togglePin",
        "toggleAllView",       "setFloatingRect",  "honorConfigureRequest",
        "startDrag",           "stopDrag",         "updateDrag",
        "isDragging",          "isResizingWindow", "getDragLastRect",
        "cancelDragForWindow",
    };

    /// The complementary half of the classification: `WindowModule` hooks whose
    /// dispatch is an explicit registry LOOP, so several modules may bind them
    /// and every one is adopted. Together with `single_binder_hooks` this is a
    /// PARTITION of the contract, asserted below -- which is the point. The
    /// at-most-one check for a newly added first-match hook only runs if the
    /// name is listed, so an unlisted new hook silently escaped it; naming both
    /// halves makes a new hook a compile error instead.
    pub const multi_binder_hooks = [_][]const u8{
        "init",                     "deinit",
        "notifyConfigureIfPending", "onWindowGone",
        "serializeWindow",          "deserializeWindow",
        "setEwmhFullscreenState",   "armPendingBarHide",
        "armPendingBarShow",        "resolvePendingBarNow",
    };

    /// `WindowModule` fields that are DATA rather than hooks, so they belong
    /// in neither cardinality list: nothing dispatches them, and they have no
    /// binder count.
    ///
    /// This exists because the partition assert below used to be stated as
    /// "every field is a hook", which was true while the type carried nothing
    /// but hooks, and stopped being true the moment a stable identity field
    /// was added for persistence. The honest form of the invariant is "every
    /// field is classified, as single-dispatch, multi-dispatch, or data" --
    /// and a field still has to be classified to get here, so adding one
    /// without a decision is still a compile error.
    pub const non_hook_fields = [_][]const u8{"name"};

    /// Stable identity for this module, used by persistence to stamp a saved
    /// window with its CLAIMANT rather than the claimant's registry position.
    /// Required (non-empty, unique) for any module binding `serializeWindow`;
    /// the generated registry rejects the other case at compile time.
    ///
    /// Why a name and not the ordinal it replaces: the ordinal is a position
    /// in a build-generated list, so removing or reordering an unrelated module
    /// renumbers every module after it and a saved session's fast path starts
    /// pointing at a DIFFERENT module -- which then either declines (recovered
    /// by the magic-byte scan, after a wasted call that may mis-adopt) or
    /// claims a blob it does not own. A name cannot shift. The cost is that a
    /// rename invalidates that one module's saved blobs, which degrade to the
    /// same scan -- strictly less damage than a reordering.
    ///
    /// The magic-byte scan stays the fallback either way, because a name only
    /// narrows WHICH module is asked first; it is the payload's own self-
    /// identifying tag that decides.
    name: []const u8 = "",

    // Lifecycle. Uniform `anyerror!void` so the dispatch loop can `try` each.
    init: ?*const fn () anyerror!void = null,
    deinit: ?*const fn () void = null,
    // Fullscreen protocol-side (deferred bar hide/show, EWMH).
    notifyConfigureIfPending: ?*const fn (u32, u16, u16) void = null,
    onWindowGone: ?*const fn (u32) void = null,
    // Session persistence seam: modules marshal/unmarshal their per-window
    // state as an opaque blob; persist carries `[]u8` bytes and the
    // wire layer dispatches. `serializeWindow` null => nothing persisted.
    // The model is handed across the WRITE side as a read-only `*const
    // model.Model` (serialization never mutates; the caller holds the const
    // handle and does NOT @constCast), and each module decides from that
    // state whether it owns the window's blob (at most one module returns
    // bytes per window). `deserializeWindow` returns whether this module
    // claimed the blob; persist stamps the claiming module's registry ordinal
    // (plus a version) onto every blob, so adoption fast-paths on that ordinal
    // and falls back to the hooks' self-identifying format tag (magic byte)
    // when the ordinal no longer resolves.
    serializeWindow: ?*const fn (*const model.Model, u32, std.mem.Allocator) ?[]const u8 = null,
    deserializeWindow: ?*const fn (u32, []const u8, *model.Model) bool = null,
    setEwmhFullscreenState: ?*const fn (u32, bool) void = null,
    armPendingBarHide: ?*const fn (u32) void = null,
    armPendingBarShow: ?*const fn (u32) void = null,
    /// Retire a window's pending bar intent because the caller already answered
    /// the question itself (the fullscreen exit bump). Distinct from the arm
    /// pair: those DEFER a decision, this one CANCELS one.
    resolvePendingBarNow: ?*const fn (u32) void = null,
    // Hide/restore family (minimize module; model vocabulary)
    /// Hide a window (minimize): parks the model entry and stashes the
    /// tiled slot. At most one module binds this.
    hideWindow: ?*const fn (*model.Model, model.WindowId) anyerror!void = null,
    /// Restore a previously hidden window to its tiled slot (or floating
    /// rect if it was floating-originated). At most one module binds this.
    restoreWindow: ?*const fn (*model.Model, model.WindowId) void = null,
    /// Select the next restore candidate on `ws` in the given order
    /// (LIFO/FIFO). Returns null when nothing on ws is hidden.
    restoreCandidateOn: ?*const fn (
        *const model.Model,
        model.WSId,
        model.RestoreOrder,
    ) ?model.WindowId = null,
    /// Bulk-restore every hidden window on `ws`. At most one module binds
    /// this.
    restoreOnWs: ?*const fn (*model.Model, model.WSId) void = null,
    /// Most-recently-hidden plain window on `ws` (fullscreen-carrying
    /// windows excluded). Returns null when nothing qualifies.
    latestHiddenOnWs: ?*const fn (*const model.Model, model.WSId) ?model.WindowId = null,
    /// True when `win` currently holds a hidden record (parked state).
    isWindowHidden: ?*const fn (*const model.Model, model.WindowId) bool = null,
    /// Synthesize the full set of currently hidden windows on the model into
    /// `set` (clearing it first). At most one module binds this; the bar
    /// consumes it through the cached DrawCtx api so it never names the
    /// window addon.
    collectHiddenSet: ?*const fn (
        *const model.Model,
        *std.AutoHashMapUnmanaged(model.WindowId, void),
        std.mem.Allocator,
    ) void = null,

    // Screen-covering family (fullscreen module; model vocabulary)
    /// Toggle the covering (fullscreen) capture on/off for `win`.
    /// Returns true iff a state transition happened.
    toggleCovering: ?*const fn (*model.Model, model.WindowId) bool = null,
    // 12.4: `isCoveringMode`, `coveringWsOf` and `isCoveringOnWs` are GONE.
    // Each body was a pure read of the model's `covering_ws` field, so the
    // three hooks were three copies of a model query behind a dispatch that
    // returns null when no covering module is bound -- meaning "is this window
    // covering" answered FALSE in such a build while the model held the
    // intent. The queries are now `model.coveringWsOf` / `model.isCovering` /
    // `model.isCoveringOn`, which cannot be unbound.
    /// The STRICT covering occupant on `ws`: covering AND anchored AND visible
    /// (an AND of all three, where the model's `coveringOccupantOnWs` is an
    /// anchor-or-visible OR). Both exist and both are used: the model scan
    /// answers "who owns the screen", the strict one answers "which covering
    /// window is actually usable here". Renamed from `coveringOccupantOnWs`
    /// (12.5) because sharing a name with the model scan is what let the two
    /// different semantics read as interchangeable. At most one module binds
    /// this.
    visibleCoveringOnWs: ?*const fn (*const model.Model, model.WSId) ?model.WindowId = null,
    /// One-way covering release: clear `win`'s covering intent and presence.
    /// Unlike `toggleCovering` this never ENTERS covering mode, so a peer that
    /// means "demote" cannot turn into "promote" (12.8).
    releaseCovering: ?*const fn (*model.Model, model.WindowId) void = null,
    /// Retarget `win`'s covering intent to `ws` without dropping it (a
    /// covering window stays covering across a workspace move/tag change).
    /// Peer-service seam for the workspaces module; the binding module owns
    /// its record guard. At most one module binds this.
    moveCoveringTo: ?*const fn (*model.Model, model.WindowId, model.WSId) void = null,

    // Workspaces family (workspaces module)
    /// Move `win` to a single tag `ws` (mask replaces; home-list
    /// follows). At most one module binds this.
    sendToWs: ?*const fn (*model.Model, model.WindowId, model.WSId) void = null,
    /// Add tag `ws` to `win`'s mask (protect_current optionally keeps
    /// the current workspace bit).
    addToWs: ?*const fn (*model.Model, model.WindowId, model.WSId, bool) void = null,
    /// Remove tag `ws` from `win`'s mask (last-tag protected; returns
    /// true on success).
    removeFromWs: ?*const fn (*model.Model, model.WindowId, model.WSId) bool = null,
    /// Toggle pin: all-tags <-> current-only.
    togglePin: ?*const fn (*model.Model, model.WindowId) void = null,
    /// Toggle all-view mode; returns true when entering.
    toggleAllView: ?*const fn (*model.Model) bool = null,

    // Floating family (floating module; "floating" is model vocabulary)
    /// Update a floating window's rect on the model (no-op for
    /// tiled/unknown).
    setFloatingRect: ?*const fn (*model.Model, model.WindowId, model.Rect) void = null,
    /// Honor a configure request against a floating window record on the
    /// model. Returns the decision (geometry_applied / border_only /
    /// ignored).
    honorConfigureRequest: ?*const fn (
        *model.Model,
        model.WindowId,
        model.ConfigureReq,
    ) model.HonorDecision = null,

    // Floating drag/resize commands.
    startDrag: ?*const fn (u32, u8, i16, i16) void = null,
    stopDrag: ?*const fn () void = null,
    updateDrag: ?*const fn (i16, i16) void = null,
    isDragging: ?*const fn () bool = null,
    isResizingWindow: ?*const fn (u32) bool = null,
    getDragLastRect: ?*const fn () model.Rect = null,
    cancelDragForWindow: ?*const fn (u32) void = null,
};

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

/// Dispatch family for every generated registry element type (`WindowModule`,
/// `Segment`, ...). The SINGLE canonical loops every owner layer routes its
/// adopt-claims through, so a hook's dispatch semantics live here once and
/// are shared by name across otherwise-unrelated owner tiers: an owner never
/// reimplements a scan, only binds values. All loops honor the registry's
/// deterministic scan order.
/// The single canonical registry-lookup entry: the first module in `registry`
/// that binds the hook `field`, in the registry's deterministic scan order.
/// Returns null when no compiled-in module provides
/// the hook (the "no owner" fallback). Core callers use this to reach a
/// window/bar subsystem through the build-generated registry, never by naming a
/// module. The registry is passed in (not captured) so dispatch sites never
/// depend on the generated-registry layer. The one deliberate exception is
/// this file's own re-export of the generated `tiling_modules` (:48-49):
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

/// First-match dispatch: calls the first module in `registry` that binds
/// `field` with the tuple `args`; does nothing when none does. This is the
/// "adopt by name" seam for single-binder hooks (see `single_binder_hooks`).
pub fn callFirst(
    comptime T: type,
    registry: []const T,
    comptime field: std.meta.FieldEnum(T),
    args: anytype,
) void {
    if (providerOf(T, registry, field)) |m| @call(.auto, @field(m, @tagName(field)).?, args);
}

/// Like `callFirst` but returns the first provider's hook result; false when
/// no module binds the hook.
pub fn callFirstBool(
    comptime T: type,
    registry: []const T,
    comptime field: std.meta.FieldEnum(T),
    args: anytype,
) bool {
    if (providerOf(T, registry, field)) |m| return @call(.auto, @field(m, @tagName(field)).?, args);
    return false;
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

/// Fan-out dispatch for a FALLIBLE hook: calls every module that binds `field`,
/// in registry order, and propagates the first error -- so a module whose
/// lifecycle init fails stops the fan-out, exactly as the hand-rolled
/// `for ... try` loop it replaces did. The point is ONE dispatch family for
/// lifecycle hooks, not a different failure policy; the lifecycle sites that
/// are infallible (every `deinit` hook) use `callAll`.
pub fn callAllTry(
    comptime T: type,
    registry: []const T,
    comptime field: std.meta.FieldEnum(T),
    args: anytype,
) anyerror!void {
    for (registry) |m| if (@field(m, @tagName(field))) |f| try @call(.auto, f, args);
}

/// Fan-out bool dispatch: true as soon as any module whose hook binds `field`
/// returns true; false when none binds it or none returns true.
pub fn callFirstTrue(
    comptime T: type,
    registry: []const T,
    comptime field: std.meta.FieldEnum(T),
    args: anytype,
) bool {
    for (registry) |m| if (@field(m, @tagName(field))) |f| {
        if (@call(.auto, f, args)) return true;
    };
    return false;
}

/// The bar-segment hook set. Every module under a bar-owner's `modules/`
/// directory binds its `pub const module` value to
/// this type, binding only the hooks it owns (everything else stays `null`).
/// build.zig scans the bar's `modules/` and emits a `bar_modules` registry array
/// of every discovered module's value (deterministic sorted-stem order); the
/// bar orchestrator iterates it with uniform loops, so adding a segment is a
/// drop-in file and removing one degrades to shorter loops. This is the
/// same open-addon contract as `WindowModule`, typed for bar segments.
///
/// Type-free seams: hooks that must carry bar-side structs (`Frame`, `Env`,
/// the title render/snapshot scratch) pass `*anyopaque`; the segment casts to
/// the shared bar vocabulary it imports (`@import("segment")`). This keeps the
/// contract free of an import edge into the bar layer.
///
/// Which core fact-revisions repaint a segment. A bitmask; a dirty segment is
/// repainted on the next draw. Declared per module; the bar marks dirty by
/// bit, name-free. The role capabilities (`self_ticking`, `center_slot`) are
/// multi-binder sets (see their fields); everything else is free-binding.
pub const DirtySources = packed struct(u2) {
    /// A focus change (focus_rev diff) repaints this segment.
    focus: bool = false,
    /// A frame change (window/workspace scan diff) repaints this segment.
    frame: bool = false,
};

/// A bar-segment runtime overlay value: a segment that owns a slot can bind
/// itself as an overlay provider (the prompt over the title slot), and the
/// slot's core (the title segment) finds it through the generated segment
/// registry rather than naming the overlay module. The draw fn shares the
/// opaque `*anyopaque` convention of `Segment.draw`; the overlay's own draw
/// adapter performs the same cast to the bar vocabulary it imports.
pub const BarOverlay = struct {
    /// True while the overlay is actively covering the slot.
    is_active: *const fn () bool,
    /// Toggle the overlay open/closed.
    toggle: *const fn () void,
    /// Render the overlay across the slot at `x`, returning the advanced `x`.
    draw: *const fn (ctx: *anyopaque, x: u16) anyerror!u16,
    /// Runtime "repaint me" query, mirroring `Segment.needsRepaint`: true while
    /// the overlay holds visual state (a caret-blink toggle) that only reaches
    /// the screen when its draw runs. The host slot's `needsRepaint` forwards
    /// this, so the bar repaints just that slot instead of forcing a whole-bar
    /// redraw. The overlay clears the state inside its own draw.
    needsRepaint: *const fn () bool,
};

/// The X key-press event a segment's `handleKeypress` hook receives, opaque.
///
/// The concrete struct lives in `contract_x11` (the X-aware half of the
/// contract, which also holds `Surfaces`). Declaring it opaque here is what
/// keeps this file importable by a non-X consumer -- a headless test, a
/// config-only tool -- while still letting the one consumer that needs the
/// fields (the prompt module) name the real type. An opaque type has no
/// fields, so a hook that wants them must import `contract_x11` and cast,
/// which is the correct place for that requirement to live.
pub const KeyPressEvent = opaque {};

/// Everything a segment's click hook needs, by name.
///
/// This was six positional parameters -- offset, two direction bools, the bar
/// state, and two bar-provided fn pointers -- and every implementation had to
/// restate the whole list to ignore most of it: the clock's hook discarded four
/// of six, the tags hook three. Positionally, `offset: u16` and the two bools
/// are indistinguishable at the call site, so a transposed pair type-checked.
/// One named struct makes the ignored fields `_ = ctx.redraw` instead of six
/// `_:` parameters, and leaves room to add a field (a timestamp, a modifier
/// mask) without touching any implementation's signature.
/// Live workspace facts every segment's hooks may read. Pure data, no bar
/// types, so it lives HERE rather than in bar/segment.zig: the `naturalWidth`
/// hook below takes it as a real `*const Frame`, and a hook signature cannot
/// name a type the contract may not import. bar/segment.zig re-exports this
/// (`pub const Frame = contract.Frame`), so every existing reader is
/// unaffected -- and the hook no longer has to be documented as "the caller
/// promises this is a Frame", which is a promise `*const anyopaque` cannot
/// check.
/// What a segment actually painted, returned rather than inferred.
///
/// `draw` used to return only the advanced `x`, and the bar decided whether a
/// segment had drawn anything by comparing it against the `x` it passed in.
/// That conflates "painted nothing" with "failed", and the two are not the
/// same: a readout with nothing to show (no battery, unreadable file) is a
/// SUCCESS that occupies zero width, while a failed draw is a success-shaped
/// fallback the bar substitutes. Both happen to end up advancing the row by the
/// reserved width, so the confusion was invisible -- but a segment that meant
/// to paint an empty cell and keep its slot could not say so, and the bar had
/// no way to tell that apart from an error it had just caught.
pub const Painted = struct {
    /// x just past the painted content.
    end_x: u16,
    /// The width really occupied, padding included. 0 means "nothing painted",
    /// which is a valid outcome and NOT an error.
    width: u16 = 0,

    /// The common case: painted from `start_x` to `end_x`.
    pub inline fn span(start_x: u16, end_x: u16) Painted {
        return .{ .end_x = end_x, .width = end_x -| start_x };
    }

    /// Painted nothing -- a valid, successful outcome. The row still advances
    /// by the reservation the layout made.
    pub inline fn nothing(start_x: u16) Painted {
        return .{ .end_x = start_x, .width = 0 };
    }
};

pub const Frame = struct {
    workspace_count: u32 = 0,
    current_workspace: u8 = 0,
    is_all_view_active: bool = false,
    workspace_has_windows: []const bool = &.{},
};

pub const ClickCtx = struct {
    /// Pixels from the segment's recorded left edge. Compare against the width
    /// the row reserved (`naturalWidth`), not the last painted width.
    offset: u16,
    /// True for button 1. Modules that step a direction read this as the sign
    /// (left = +1, right = -1).
    is_left: bool,
    /// True for button 3.
    is_right: bool,
    /// The bar's segment state, kept opaque so modules do not depend on
    /// `bar.zig`. The title module re-passes it to `title_click`, which is
    /// why the field is a pointer and not a copy.
    state: *anyopaque,
    /// Bar-provided: route a left-click at `offset` into the title segment.
    /// Takes the same `state` pointer, so the two travel together.
    title_click: *const fn (*anyopaque, u16) void,
    /// Bar-provided full redraw, safe to call inside an input grab.
    redraw: *const fn () void,
};

pub const Segment = struct {
    /// The `Segment` hooks whose contract is "at most one segment binds this".
    /// `measureString` supplies THE row's reserved-width probe and `overlay`
    /// the single runtime overlay; both are reached by first-match lookup, so a
    /// second binder would be silently ignored. Declared on the TYPE (not as a
    /// package-level list of `WindowModule` names) so the generated
    /// `bar_modules` registry finds it with `@hasDecl(T, "single_binder_hooks")`
    /// and enforces the count on the fields that actually carry it.
    ///
    /// `naturalWidth` is deliberately NOT listed: every segment binds its own
    /// (it is that segment's reserved width, not a shared facility), so
    /// listing it would be false and the count assert would reject every
    /// two-segment bar.
    pub const single_binder_hooks = [_][]const u8{
        "measureString", "overlay",
    };
    /// Config identity ("workspaces", "title", "clock", "layout", "variants").
    /// Unique across the registry; config text resolves to the module by name.
    name: []const u8 = "",
    /// Declares the segment drives its own refresh cadence (the wall-clock
    /// segment), so the bar's secondsElapsed ticker targets it. Multi-binder:
    /// every self-ticking segment is ticked fan-out on each second boundary
    /// and receives a region-scoped repaint of its own slot. A bar with no
    /// self-ticking segment skips the whole timer path.
    self_ticking: bool = false,
    /// Declares the segment claims a share of the reserved center slot (the
    /// title segment). A center row's center-slot segments split the clamped
    /// center budget EVENLY, left-to-right in config order, with no
    /// inter-segment gap inside the cluster. The first binder (config order)
    /// additionally owns the title-centric bar behaviors (click-to-focus,
    /// chrome-overlay toggle).
    center_slot: bool = false,
    /// Which core fact-revisions repaint this segment (title: focus+frame;
    /// workspaces/tags: frame; everything else: none).
    dirty_sources: DirtySources = .{},
    /// Runtime "repaint me on every draw" query. A segment whose content
    /// advances on its own cadence (e.g. a scrolling title marquee) claims
    /// this hook and returns true while that motion is active: the bar then
    /// repaints the segment on every draw submission even when change
    /// detection says nothing changed, because the motion only advances while
    /// the segment's draw runs. Name-free: the segment owns the query's
    /// state; the bar merely honours the declared capability.
    needsRepaint: ?*const fn () bool = null,
    /// Whether the segment participates in click-hit bounds. Segments opt out
    /// by setting this false.
    clickable: bool = true,
    // Lifecycle. `handlers` is a bar-provided service handle (function
    // pointers for chrome behaviors the segment must call back into); passed
    // once at init so segments never import the bar orchestrator.
    /// `conn` is the X connection, carried as `*const anyopaque` for the same
    /// reason `KeyPressEvent` is: this file names no X type. The bar is the
    /// only producer, and exactly one segment (the prompt, for
    /// `xcb_key_symbols_alloc`) reads it.
    init: ?*const fn (std.mem.Allocator, *const anyopaque, ?*const anyopaque) anyerror!void = null,
    deinit: ?*const fn (std.mem.Allocator) void = null,
    // Bar-frame services: uniform polls the orchestrator runs each loop,
    // regardless of whether the segment is configured.
    pollTimeoutMs: ?*const fn () i32 = null,
    onPollWakeup: ?*const fn () void = null,
    secondsElapsed: ?*const fn ([]const u8) bool = null,
    invalidate: ?*const fn () void = null,
    // Metrics, draw and click for configured segments.
    /// Reserved row width probe (clock's measure string; bar measures the
    /// string at layout width). At most one module provides it.
    measureString: ?*const fn () []const u8 = null,
    /// Reserved width in the row. `frame` is a real `*const Frame` (above) and
    /// `clock_width` the measured clock width for segments that need it.
    naturalWidth: ?*const fn (*const Frame, u16) u16 = null,
    /// Draw at `x`, return what it painted. `ctx` is `*segment.DrawCtx`
    /// (bar-built scratch shared by every segment draw).
    draw: ?*const fn (*anyopaque, u16) anyerror!Painted = null,
    /// The bar reports back the width the segment ACTUALLY painted, after
    /// every draw, so the reservation can follow the content.
    ///
    /// The bar owns the row reservation, so a segment should not have to
    /// remember to record its own drawn width -- forgetting to is silent and
    /// shows up as a segment locked onto its startup width, its neighbours
    /// overlapping it forever. The sink stays a hook because the width belongs
    /// to the segment: a multi-slot module splits it across its slots, and a
    /// module with no measured width (the clock, layout) leaves this null.
    onPainted: ?*const fn (u16) void = null,
    /// Click dispatch for recorded bounds; mirrors the chrome-surface input
    /// routing (state/title_click/redraw are bar-provided fn pointers). All of
    /// it arrives in one named `ClickCtx`.
    onClick: ?*const fn (*const ClickCtx) bool = null,
    /// Scroll-wheel dispatch for recorded bounds (buttons 4/5, positive =
    /// wheel up; the bar maps button 4 -> +1, button 5 -> -1). Receives the
    /// scroll direction and the bar's redraw hook.
    onScroll: ?*const fn (i8, *const fn () void) bool = null,
    /// Press-hold motion dispatch for recorded bounds: a clickable segment
    /// that claims this hook is scrubbed while button 1 is held (the bar
    /// delivers every motion during the press, offset relative to the
    /// segment's recorded origin; X's implicit grab covers motion past the
    /// bar's edge). Null for every segment that only needs click semantics.
    onDragMotion: ?*const fn (u16, *const fn () void) bool = null,
    /// Fired when a press-hold scrub ends (button-1 release): lets a module
    /// that defers work during the scrub (the slider sub throttles its
    /// subprocess commits to every few motions) flush its final value and
    /// leave its drag render mode. Receives the bar's full redraw hook. Null
    /// for every segment that needs only click semantics.
    onDragEnd: ?*const fn (*const fn () void) void = null,
    // Chrome-overlay extras (bound into the chrome `Surfaces` hooks and polled
    // uniformly; the overlay segment is the only one that sets them).
    //
    // `KeyPressEvent` is OPAQUE here and the X struct in `contract_x11`: this
    // file is X-free, so the field cannot name an xcb type. The bar casts the
    // real event into it and is the only producer, so the one `@ptrCast` in
    // the system is at the seam that produces the value.
    handleKeypress: ?*const fn (*const KeyPressEvent, ?*const types.Action) bool = null,
    consumeRedrawRequest: ?*const fn () bool = null,
    invalidateReloadCaches: ?*const fn () void = null,
    /// Fired by the bar on every show (map). Lets continuous-motion segments
    /// (the title marquee) resume without teleporting across the hidden gap.
    onBarShown: ?*const fn () void = null,
    /// Runtime-overlay binding: when set, this segment overlays ANOTHER
    /// segment's slot (the prompt over the title). The slot's core finds the
    /// value through the segment registry (never by naming this module) and
    /// delegates its draw/click/poll duty to it while `is_active`. At most
    /// one module binds this.
    overlay: ?BarOverlay = null,
};

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
    /// dangle, and every call site already had the struct in hand.
    hints: HintsView,
    focused: ?model.WindowId,
    // Environment resolved by the CALLER from config.
    env: Env = .{},
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

/// Frozen size-hint snapshot aligned index-for-index with View.order. The
/// caller materializes one hint per ordered window; lookup is a scan over the
/// (small) order slice only — rebuilt each reconcile, no allocator, and
/// bounded by `model.max_tiled_per_ws` (64), so a map would add nothing.
pub const HintsView = struct {
    order: []const model.WindowId,
    hints: []const model.SizeHints,

    /// Returns hints BY VALUE with a default fallback.
    pub fn forWin(self: HintsView, win: model.WindowId) model.SizeHints {
        std.debug.assert(self.order.len == self.hints.len);
        for (self.order, self.hints) |w, h| {
            if (w == win) return h;
        }
        return .{};
    }
};

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
