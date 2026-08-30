//! core/plugin.zig: the plugin interface contract.
//!
//! The pluggable-composition contract for the self-containment architecture.
//! This file defines the TYPES that optional subsystems bind to; it names no
//! subsystem by module name. Registration lives in build-GENERATED modules
//! (produced by build.zig): core never names an optional subsystem; the build
//! does.
//!
//! `Surfaces` is the interface the chrome-surface module (today: the bar)
//! binds to. It stays the sole export of the build-generated `plugins` module
//! (`plugins.Surfaces`), which is injected into every module, so chrome-
//! surface consumers never name the bar module directly and the bar family
//! stays byte-identical.
//!
//! `WindowModule` is the flat, all-optional-hook interface every module under
//! a window-owner's `modules/` directory binds to (see build.zig's per-owner
//! `modules` registry generation). Sub-system registration is build-time, not
//! merged here: build.zig scans `src/<owner>/modules/` and emits an array of
//! every discovered module's `module` value in a generated `<owner>_modules`
//! module, which core tiers iterate with uniform dispatch loops. No merged
//! single struct, no per-sub-system partial types; just one hook set with
//! `null` for hooks a module doesn't own.
//!
//! Key seams:
//!   - `coverageOn(m, ws)` -- who owns the screen on a workspace, if anyone
//!     (fullscreen). Called once per sync reconcile; `null` when no module
//!     claims the ws.
//!   - `serializeWindow(m-as-*anyopaque, win, alloc)` -- returns an opaque
//!     per-window blob for restart persistence, or null. The model is passed
//!     as `*anyopaque` so the seam stays free of a model type dependency;
//!     each module decides from the model state whether it owns the window's
//!     blob (presence-driven), so at most one blob exists per window.
//!   - `deserializeWindow(win, blob, m-as-*anyopaque)` -- returns a "claimed"
//!     bool. Hooks self-identify via a format tag (magic byte) inside the
//!     blob, so the registry adoption loop can't mis-claim another module's
//!     blob; unclaimed blobs leave the window in its default state.

const std = @import("std");
const core = @import("core");
const xcb = core.xcb;
const types = @import("types");
const utils = @import("utils");
const model = @import("model");

/// The chrome-surface hook set a surface module binds to. The bar binds its
/// `surfaces` value to this; when no surface is compiled in, core's
/// generated `plugins.Surfaces` is the comptime `null` type and every
/// `if (build_options.has_bar)` call site compiles away.
pub const Surfaces = struct {
    // Boot lifecycle, invoked from main.zig through plugins.Surfaces so the
    // boot sequence never needs to name the bar module directly.
    init: *const fn () anyerror!void,
    deinit: *const fn () void,
    // Event-loop hooks.
    handleExpose: *const fn (*const xcb.xcb_expose_event_t) void,
    handlePropertyNotify: *const fn (*const xcb.xcb_property_notify_event_t) void,
    updateIfDirty: *const fn () anyerror!void,
    pollTimeoutMs: *const fn () i32,
    onPollWakeup: *const fn () void,
    updateClock: *const fn () bool,
    onReload: *const fn () void,
    // Input routing. The chrome overlay pre-empts key handling (returns true
    // when it consumed the key), button presses on the surface window are
    // routed to it, and the three surface config actions mutate chrome state.
    chromeHandleKeypress: *const fn (*const xcb.xcb_key_press_event_t, ?*const types.Action) bool,
    isBarWindow: *const fn (u32) bool,
    handleButtonPress: *const fn (*const xcb.xcb_button_press_event_t) void,
    setBarState: *const fn (types.Action) void,
    toggleBarSegmentAnchor: *const fn () void,
    chromeToggleOverlay: *const fn () void,
};

/// The window sub-system hook set. Every module under a window-owner's
/// `modules/` directory binds its `pub const module` value to this type,
/// binding only the hooks it owns (everything else stays `null`). Core tiers
/// reach the compiled-in sub-systems by iterating the build-generated
/// `window_modules.modules` array with uniform dispatch loops (each loop
/// calls the hook on every module that provides it and the absent ones are
/// simply skipped, so nothing is merged and none of these is ever a no-op
/// stub. Dispatch order == the array's order == deterministic filesystem scan
/// order.
pub const WindowModule = struct {
    // Lifecycle. Uniform `anyerror!void` so the dispatch loop can `try` each.
    init: ?*const fn () anyerror!void = null,
    deinit: ?*const fn () void = null,
    // Fullscreen protocol-side (deferred bar hide/show, EWMH).
    notifyConfigureIfPending: ?*const fn (u32, u16, u16) void = null,
    onWindowGone: ?*const fn (u32) void = null,
    // Coverage seam: for a given workspace, which window owns the screen?
    // sync calls this once per reconcile (through the registry) instead of
    // scanning a store for fullscreen state. null => no module claims the ws.
    coverageOn: ?*const fn (*const model.Model, model.WSId) ?model.WindowId = null,
    // Session persistence seam: modules marshal/unmarshal their per-window
    // state as an opaque blob; persist carries `[]u8` bytes and the
    // wire layer dispatches. `serializeWindow` null => nothing persisted.
    // The model is passed as `*anyopaque` so this seam stays free of a model
    // type dependency; each module decides from the model state whether it
    // owns the window's blob (at most one module returns bytes per window).
    // `deserializeWindow` returns whether this module claimed the blob; hooks
    // self-identify via a format tag so the registry loop can't mis-claim.
    serializeWindow: ?*const fn (*anyopaque, u32, std.mem.Allocator) ?[]const u8 = null,
    deserializeWindow: ?*const fn (u32, []const u8, *anyopaque) bool = null,
    setEwmhFullscreenState: ?*const fn (u32, bool) void = null,
    armPendingBarHide: ?*const fn (u32) void = null,
    armPendingBarShow: ?*const fn (u32) void = null,
    // ----------------------------------------------------------------
    // Hide/restore family (bound by the minimize module; the module's own
    // file keeps its "minimize" words; the contract uses model vocabulary
    // for the seam — "hide" / "restore" / "hidden").
    // ----------------------------------------------------------------
    /// Hide a window (minimize): parks the model entry and stashes the
    /// tiled slot. At most one module binds this.
    hideWindow: ?*const fn (*model.Model, model.WindowId) anyerror!void = null,
    /// Restore a previously hidden window to its tiled slot (or floating
    /// rect if it was floating-originated). At most one module binds this.
    restoreWindow: ?*const fn (*model.Model, model.WindowId) void = null,
    /// Select the next restore candidate on `ws` in the given order
    /// (LIFO/FIFO). Returns null when nothing on ws is hidden.
    restoreCandidateOn: ?*const fn (*const model.Model, model.WSId, model.RestoreOrder) ?model.WindowId = null,
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
    collectHiddenSet: ?*const fn (*const model.Model, *std.AutoHashMapUnmanaged(model.WindowId, void), std.mem.Allocator) void = null,

    // ----------------------------------------------------------------
    // Screen-covering family (bound by the fullscreen module; contract
    // uses the model's own pattern vocabulary — the model doc names the
    // pattern `covering` for "owns the screen on some workspace"; the
    // module file keeps its "fullscreen" words).
    // ----------------------------------------------------------------
    /// Toggle the covering (fullscreen) capture on/off for `win`.
    /// Returns true iff a state transition happened.
    toggleCovering: ?*const fn (*model.Model, model.WindowId) bool = null,
    /// True when `win` holds a covering record (regardless of model
    /// presence — ghost state while minimized).
    isCoveringMode: ?*const fn (*const model.Model, model.WindowId) bool = null,
    /// The workspace `win` is covering, per its module record. Reports
    /// the ws even while the model presence is parked (ghost).
    coveringWsOf: ?*const fn (*const model.Model, model.WindowId) ?model.WSId = null,
    /// True when `win` has a covering record targeting `ws` (does NOT
    /// consult visibility).
    isCoveringOnWs: ?*const fn (*const model.Model, model.WindowId, model.WSId) bool = null,
    /// The first covering occupant on `ws`: rec.ws == ws AND
    /// present-not-parked AND visibleOn. DISTINCT from `coverageOn`
    /// which also matches cross-ws visibility. At most one module binds
    /// this.
    coveringOccupantOnWs: ?*const fn (*const model.Model, model.WSId) ?model.WindowId = null,

    // ----------------------------------------------------------------
    // Workspaces family (bound by the workspaces module; contract uses
    // model's `WSId` vocabulary).
    // ----------------------------------------------------------------
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

    // ----------------------------------------------------------------
    // Floating family (bound by the floating module; "floating" IS model
    // vocabulary — model.BaseMode.floating — so these names are fine).
    // ----------------------------------------------------------------
    /// Update a floating window's rect on the model (no-op for
    /// tiled/unknown).
    setFloatingRect: ?*const fn (*model.Model, model.WindowId, utils.Rect) void = null,
    /// Honor a configure request against a floating window record on the
    /// model. Returns the decision (geometry_applied / border_only /
    /// ignored).
    honorConfigureRequest: ?*const fn (*model.Model, model.WindowId, model.ConfigureReq) model.HonorDecision = null,

    // Floating drag/resize commands.
    startDrag: ?*const fn (u32, u8, i16, i16) void = null,
    stopDrag: ?*const fn () void = null,
    updateDrag: ?*const fn (i16, i16) void = null,
    isDragging: ?*const fn () bool = null,
    isResizingWindow: ?*const fn (u32) bool = null,
    getDragLastRect: ?*const fn () utils.Rect = null,
    cancelDragForWindow: ?*const fn (u32) void = null,
};

/// First module in `registry` that binds the hook `field`, in the registry's
/// deterministic scan order. Returns null when no compiled-in module provides
/// the hook (the "no owner" fallback). Core callers use this to reach a
/// window subsystem through the build-generated registry, never by naming a
/// module. The registry is passed in (not captured) so the contract module
/// stays free of an import edge into the generated-registry layer.
pub fn providerOf(
    registry: []const WindowModule,
    comptime field: std.meta.FieldEnum(WindowModule),
) ?WindowModule {
    for (registry) |wm| if (@field(wm, @tagName(field)) != null) return wm;
    return null;
}

/// The bar-segment hook set. Every module under a bar-owner's `modules/`
/// directory (today `src/bar/modules/`) binds its `pub const module` value to
/// this type, binding only the hooks it owns (everything else stays `null`).
/// build.zig scans `src/bar/modules/` and emits a `bar_modules` registry array
/// of every discovered module's value (deterministic sorted-stem order); the
/// bar orchestrator iterates it with uniform loops, so adding a segment is a
/// drop-in file and removing one degrades to shorter loops. This is the
/// same open-addon contract as `WindowModule`, typed for bar segments.
///
/// Type-free seams: hooks that must carry bar-side structs (`Frame`, `Env`,
/// the title render/snapshot scratch) pass `*anyopaque`; the segment casts to
/// the shared bar vocabulary it imports (`@import("segment")`). This keeps the
/// contract free of an import edge into the bar layer.
/// Which core fact-revisions repaint a segment. A bitmask; a dirty segment is
/// repainted on the next draw. Declared per module; the bar marks dirty by
/// bit, name-free. At most one segment SHOULD claim any given role (see the
/// single-bit role fields below).
pub const DirtySources = packed struct(u2) {
    /// A focus change (focus_rev diff) repaints this segment.
    focus: bool = false,
    /// A frame change (window/workspace scan diff) repaints this segment.
    frame: bool = false,
};

pub const Segment = struct {
    /// Config identity ("workspaces", "title", "clock", "layout", "variants").
    /// Unique across the registry; config text resolves to the module by name.
    name: []const u8 = "",
    /// False for segments that exist as runtime overlays (the chrome
    /// overlay) and must not be selectable from config. Non-configurable
    /// segments still join the uniform lifecycle/poll loops.
    configurable: bool = true,
    /// Declares the segment drives its own refresh cadence (the wall-clock
    /// segment), so the bar's second-ticker targets it. At most one module
    /// SHOULD claim it (first-match wins, like idByName today); a bar with no
    /// self-ticking segment skips the whole timer path.
    self_ticking: bool = false,
    /// Declares the segment claims the reserved center slot (the title
    /// segment): the bar reserves/clamps that slot's width and omits the gap
    /// after it in the center cluster. At most one module SHOULD claim it.
    center_slot: bool = false,
    /// Which core fact-revisions repaint this segment (title: focus+frame;
    /// workspaces/tags: frame; everything else: none).
    dirty_sources: DirtySources = .{},
    /// Whether the segment participates in click-hit bounds (the clock does
    /// not).
    clickable: bool = true,
    // Lifecycle. `handlers` is a bar-provided service handle (function
    // pointers for chrome behaviors the segment must call back into); passed
    // once at init so segments never import the bar orchestrator.
    init: ?*const fn (std.mem.Allocator, core.Connection, ?*const anyopaque) anyerror!void = null,
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
    /// Reserved width in the row; `frame` is `*const segment.Frame`,
    /// `clock_width` the measured clock width for segments that need it.
    naturalWidth: ?*const fn (*const anyopaque, u16) u16 = null,
    /// Draw at `x`, return advanced `x`. `ctx` is `*segment.DrawCtx`
    /// (bar-built scratch shared by every segment draw).
    draw: ?*const fn (*anyopaque, u16) anyerror!u16 = null,
    /// Click dispatch for recorded bounds; mirrors the chrome-surface input
    /// routing (state/title_click/redraw are bar-provided fn pointers).
    onClick: ?*const fn (u16, bool, bool, *anyopaque, *const fn (*anyopaque, u16) void, *const fn () void) bool = null,
    // Chrome-overlay extras (bound into the chrome `Surfaces` hooks and polled
    // uniformly; the overlay segment is the only one that sets them).
    handleKeypress: ?*const fn (*const xcb.xcb_key_press_event_t, ?*const types.Action) bool = null,
    isActive: ?*const fn () bool = null,
    consumeRedrawRequest: ?*const fn () bool = null,
    invalidateReloadCaches: ?*const fn () void = null,
};

/// The tiling-layout hook set. Every module under a tiling-owner's `modules/`
/// directory (today `src/tiling/modules/`) binds its `pub const module` value
/// to this type. build.zig scans `src/tiling/modules/` and emits a
/// `tiling_modules` registry; the engine resolves the active layout (a
/// `u8` registry index in `model.LayoutParams.kind`) and dispatches through
/// this contract, so adding a layout is a drop-in file and removing one just
/// shortens the registry (kind restore falls back to the first entry).
///
/// Type-free seams: `view`/`out` are `*const View`/`*List` (the interchange
/// vocabulary defined next to this contract below); the cast happens inside
/// each module. `params` is `*model.LayoutParams` for the per-layout
/// pre-reconcile duty (scroll viewport snapping).
pub const Layout = struct {
    /// Canonical name ("master", "monocle", ...). Config text resolves to the
    /// module by name; names also drive the cycle order (config order wins).
    name: []const u8 = "",
    /// Placement computation; must append exactly one placement per window.
    compute: ?*const fn (*const anyopaque, *anyopaque) void = null,
    /// Number of variants this layout exposes for cycle_variant actions.
    variant_count: u8 = 1,
    /// True when config may declare variants for this layout.
    has_variants: bool = false,
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
    /// The variant index at which this layout honours window gaps (see
    /// monocle's "gaps" variant). pipeline computes gap flags from the ACTIVE
    /// module's metadata (gap_mode) instead of matching on layout names, so a
    /// layout that varies gap behavior pins the index here. null = no variant
    /// toggles gaps for this layout.
    gap_mode: ?u8 = null,
    /// The variant index at which this layout switches to its relaxed mode
    /// (see grid's "relaxed" variant). The engine's per-layout "relaxed" hint
    /// derives from this, name-free, like gap_mode. null = no variant toggles
    /// a relaxed mode for this layout.
    relax_mode: ?u8 = null,
    // Scroll viewport addon hooks (only the scroll layout registers them;
    // "is scroll in use" == "the active layout provides these hooks").
    slotWidth: ?*const fn (u16) i32 = null,
    maxOffset: ?*const fn (usize, i32, u16) i32 = null,
    /// Pre-reconcile duty (snap-right on count growth, clamp viewport).
    preReconcile: ?*const fn (*anyopaque, usize, u16) void = null,
    // Bar rendering metadata (layout/variants segments render generically).
    icon: ?[]const u8 = null,
    indicators: ?[]const []const u8 = null,
};

/// The tiling-layout interchange vocabulary: the data handed between the
/// reconciler (sync) and any layout module's `compute`. These live on the
/// CONTRACT (not the engine module) so the always-compiled reconciler can
/// reference them even when no tiling modules are present — the engine
/// re-exports them and every module refers to them as `engine.List` etc.
/// Keeping this single owned definition (instead of sync mirroring the
/// engine) removes a must-stay-in-lockstep duplicate.
pub const View = struct {
    order: []const model.WindowId,
    params: *const model.LayoutParams,
    workarea: utils.Rect,
    hints: *const HintsView,
    focused: ?model.WindowId,
    // Environment resolved by the CALLER from config.
    env: Env = .{},
};

/// Sentinel rect for parked placements: the zero rect. The sync layer derives
/// parked geometry from its own policy, never from this.
pub const parked_rect: utils.Rect = .{ .x = 0, .y = 0, .width = 0, .height = 0 };

/// A placement computed for one window (see View.order).
pub const Placement = struct {
    win: model.WindowId,
    rect: utils.Rect,
    visible: bool,
};

/// Zero-allocation placement buffer (one entry per stored window).
pub const List = utils.BoundedList(Placement, model.store_capacity);

/// Frozen size-hint snapshot aligned index-for-index with View.order. The
/// caller materializes one hint per ordered window; lookup is a scan over the
/// (small) order slice only — rebuilt each layout pass, no allocator, and
/// bounded by `model.max_tiled_per_ws` (64), so a map would add nothing.
pub const HintsView = struct {
    order: []const model.WindowId,
    hints: []const model.SizeHints,

    /// Returns hints BY VALUE with a default fallback.
    pub fn forWin(self: *const HintsView, win: model.WindowId) model.SizeHints {
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
pub const Env = struct {
    margins: utils.Margins = .{ .gap = 0, .border = 0 },
    min_dim: u16 = 0,
    primary_on_right: bool = false,
    variant_idx: u8 = 0,
};
