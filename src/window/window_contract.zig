//! The window sub-system hook set (`WindowModule`): every module under
//! `src/window/modules/` binds its `pub const module` value to this type.
//! Engine-local — lives beside the window subsystem, not in core — because
//! the window engine is never deleted by the modularity matrix and only the
//! window owner consumes this contract. The shared dispatch primitives
//! (`providerOf`, `callAll`) live in `contract_dispatch.zig`; the cross-engine
//! tiling vocabulary lives in `tiling_contract.zig`. Pure vocabulary, no
//! X11, no feature imports.

const std = @import("std");
const model = @import("model");
const dispatch = @import("contract_dispatch");

/// The window sub-system hook set. Every module under a window-owner's
/// `modules/` directory binds its `pub const module` value to this type,
/// binding only the hooks it owns (everything else stays `null`). Dispatch
/// order == the generated registry's order == deterministic filesystem scan
/// order.
pub const WindowModule = struct {
    /// The hooks whose contract is "at most one module binds this": dispatch is
    /// first-match (`providerOf`, invoked inline by the owner's wrapper), so a
    /// second binder would be silently ignored. Every other hook is adopted by
    /// explicit registry loops (init/deinit, notifyConfigureIfPending,
    /// onWindowGone, the serialize/deserialize persistence hooks,
    /// setEwmhFullscreenState, armPendingBarHide/Show) and may have many
    /// binders. The build-generated `window_modules` registry asserts at
    /// comptime that each field below has <= 1 binder.
    pub const single_binder_hooks = [_][]const u8{
        "hideWindow",             "restoreWindow",       "restoreCandidateOn",
        "restoreOnWs",            "latestHiddenOnWs",    "isWindowHidden",
        "collectHiddenSet",       "toggleCovering",      "visibleCoveringOnWs",
        "releaseCovering",        "moveCoveringTo",      "sendToWs",
        "addToWs",                "removeFromWs",        "togglePin",
        "toggleAllView",          "setFloatingRect",     "honorConfigureRequest",
        "startDrag",              "stopDrag",            "updateDrag",
        "isDragging",             "isResizingWindow",    "getDragLastRect",
        "cancelDragForWindow",    "switchWorkspace",     "moveToWorkspace",
        "toggleTag",              "pinWindow",           "allWorkspaces",
        "toggleFullscreenWindow", "setFullscreenWindow", "minimizeWindow",
        "unminimize",             "unminimizeOrdered",   "unminimizeAll",
        "toggleFloatingWindow",
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
    // Session persistence hooks: modules marshal/unmarshal their per-window
    // state as an opaque blob; handoff carries `[]u8` bytes and the
    // wire layer dispatches. `serializeWindow` null => nothing persisted.
    // The model is handed across the WRITE side as a read-only `*const
    // model.Model` (serialization never mutates; the caller holds the const
    // handle and does NOT @constCast), and each module decides from that
    // state whether it owns the window's blob (at most one module returns
    // bytes per window). `deserializeWindow` returns whether this module
    // claimed the blob; handoff stamps the claiming module's name onto every
    // blob, so adoption fast-paths on that name and falls back to the legacy
    // registry ordinal -- then the hooks' self-identifying format tag (magic
    // byte) -- when the name no longer resolves.
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
    /// (LIFO/FIFO). Returns null when nothing on `ws` is hidden.
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
    // `isCoveringMode`, `coveringWsOf` and `isCoveringOnWs` are GONE.
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
    /// Because sharing a name with the model scan is what let the two
    /// different semantics read as interchangeable. At most one module binds
    /// this.
    visibleCoveringOnWs: ?*const fn (*const model.Model, model.WSId) ?model.WindowId = null,
    /// One-way covering release: clear `win`'s covering intent and presence.
    /// Unlike `toggleCovering` this never ENTERS covering mode, so a peer that
    /// means "demote" cannot turn into "promote".
    releaseCovering: ?*const fn (*model.Model, model.WindowId) void = null,
    /// Retarget `win`'s covering intent to `ws` without dropping it (a
    /// covering window stays covering across a workspace move/tag change).
    /// Peer-service hook for the workspaces module; the binding module owns
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

    // User-facing commands (the dissolved action layer).
    //
    // The old `src/actions/` hub held each command's WHOLE transition -- one
    // model write plus the reconcile that follows it -- split off from the
    // module that owns the state it writes. The commands now live in that
    // module, and these hooks are how the core/input and bar call sites
    // reach them: the core never names an optional module directly, so a
    // tree without the module simply has no binder and the command no-ops
    // (exactly what the old `providerOf(...) orelse return` guards did).
    // Command hooks take no `*model.Model`: the command resolves the live
    // model through the pipeline itself, which is what makes it a command
    // rather than a model transition.

    // Workspace commands (workspaces module).
    /// Switch the viewed workspace to `ws` (the `switch_workspace` bind).
    switchWorkspace: ?*const fn (u8) void = null,
    /// Move a window to a single tag (`move_to_workspace`).
    moveToWorkspace: ?*const fn (model.WindowId, u8) void = null,
    /// Toggle tag `ws` on a window (`toggle_tag`); `protect_current` keeps
    /// the current-workspace bit on add.
    toggleTag: ?*const fn (model.WindowId, u8, bool) void = null,
    /// Pin/unpin a window across all tags (`pin_window`).
    pinWindow: ?*const fn (model.WindowId) void = null,
    /// Enter/exit all-workspaces view (`all_workspaces`).
    allWorkspaces: ?*const fn () void = null,

    // Screen-covering commands (fullscreen module).
    /// Toggle a window between present and covering (`toggle_fullscreen`).
    toggleFullscreenWindow: ?*const fn (model.WindowId) void = null,
    /// The SET form of the same transition, for EWMH requests that carry the
    /// intended end state (`want` null = flip).
    setFullscreenWindow: ?*const fn (model.WindowId, ?bool) void = null,

    // Hide/restore commands (minimize module).
    /// Park the focused window (`minimize_window`); null focus = no-op.
    minimizeWindow: ?*const fn (?model.WindowId) void = null,
    /// Restore one specific hidden window (title-bar click path).
    unminimize: ?*const fn (model.WindowId) void = null,
    /// Restore the next hidden window in slot order (`unminimize`).
    unminimizeOrdered: ?*const fn (model.RestoreOrder) void = null,
    /// Restore every hidden window on the current workspace
    /// (`unminimize_all`).
    unminimizeAll: ?*const fn () void = null,

    // Floating commands (floating module).
    /// Toggle a window between tiled and floating (`toggle_floating_window`).
    toggleFloatingWindow: ?*const fn (model.WindowId) void = null,
};

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
        if (dispatch.isListed(&WindowModule.non_hook_fields, f.name)) continue;
        const s = dispatch.isListed(&WindowModule.single_binder_hooks, f.name);
        const m = dispatch.isListed(&WindowModule.multi_binder_hooks, f.name);
        if (s == m) @compileError(
            "WindowModule hook '" ++ f.name ++ "' must be listed in EXACTLY one of " ++
                "single_binder_hooks / multi_binder_hooks (single=" ++
                (if (s) "yes" else "no") ++ ", multi=" ++ (if (m) "yes" else "no") ++
                "); it is the dispatch cardinality, not a detail",
        );
    }
    dispatch.assertListedFields(WindowModule, "single_binder_hooks", &WindowModule.single_binder_hooks);
    dispatch.assertListedFields(WindowModule, "multi_binder_hooks", &WindowModule.multi_binder_hooks);
    dispatch.assertListedFields(WindowModule, "non_hook_fields", &WindowModule.non_hook_fields);
}
