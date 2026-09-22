//! The pluggable-composition contract for the self-containment architecture.
//! This file defines the TYPES that optional subsystems bind to; it names no
//! subsystem by module name. Registration lives in build-GENERATED modules
//! (produced by build.zig): core never names an optional subsystem; the build
//! does.
//!
//! `Surfaces` is the interface the chrome-surface module (today: the bar)
//! binds to. It stays the sole export of the build-generated `plugins` module
//! (`plugins.Surfaces`), injected into every module, so chrome-surface
//! consumers never name the bar module directly.
//!
//! `WindowModule` is the flat, all-optional-hook interface every module under
//! a window-owner's `modules/` directory binds to. Registration is build-time:
//! build.zig scans each owner's `modules/` and emits a generated
//! `<owner>_modules` module, which core tiers iterate with uniform dispatch
//! loops — no merged struct, no per-sub-system partial types, `null` for hooks
//! a module doesn't own.
//!
//! Key seams:
//!   - `serializeWindow(m-const, win, alloc)` -- returns an opaque per-window
//!     blob for restart persistence, or null. The model is passed as a
//!     READ-ONLY `*const model.Model` (writing through it is a compile error),
//!     cast from persist's const handle -- no `@constCast`. Each module
//!     decides from the model state whether it owns the window's blob
//!     (presence-driven), so at most one blob exists per window.
//!   - `deserializeWindow(win, blob, m)` -- returns a "claimed"
//!     bool. Hooks self-identify via a format tag (magic byte) inside the
//!     blob, so the registry adoption loop can't mis-claim another module's
//!     blob; unclaimed blobs leave the window in its default state. Adoption
//!     MAY WRITE model state, so the model arrives as a mutable `*model.Model`;
//!     it is dispatched only from the window layer's gate-holding restore path.

const std = @import("std");
const core = @import("core");
const xcb = core.xcb;
const types = @import("types");
const utils = @import("utils");
const build_options = @import("build_options");
const model = @import("model");

/// The tiling registry (build-generated). Re-exported here so consumers share
/// one conditional-import definition instead of copy-pasting the
/// `has_tiling` guard across files. Empty when the tiling subsystem is absent.
pub const tiling_mods =
    if (build_options.has_tiling) @import("tiling_modules").modules else &[_]Layout{};

/// The chrome-surface hook set a surface module binds to. The bar binds its
/// `surfaces` value to this; when no surface is compiled in, core's
/// generated `plugins.Surfaces` is the comptime `null` type and every
/// `if (build_options.has_bar)` call site compiles away.
pub const Surfaces = struct {
    // Boot lifecycle, invoked from startup through plugins.Surfaces so the
    // boot sequence never needs to name the bar module directly.
    init: *const fn () anyerror!void,
    deinit: *const fn () void,
    // Event-loop hooks.
    handleExpose: *const fn (*const xcb.xcb_expose_event_t) void,
    /// Optional: the window layer already handles PropertyNotify for managed
    /// windows, so a surface only binds this if it needs the notification
    /// (the bar does not). Null skips the forward.
    handlePropertyNotify: ?*const fn (*const xcb.xcb_property_notify_event_t) void = null,
    updateIfDirty: *const fn () anyerror!void,
    pollTimeoutMs: *const fn () i32,
    onPollWakeup: *const fn () void,
    updateClock: *const fn () void,
    // RandR hooks (refresh-rate detection). The engine lives with the bar
    // (render pacing is its only consumer); core's event loop forwards
    // extension events and defers re-detection through these when a bar is
    // compiled in, and drops the machinery entirely when it is not.
    randrFirstEvent: *const fn () u8,
    handleRandrEvent: *const fn (*anyopaque) void,
    runPendingRedetect: *const fn (core.Connection) void,
    onReload: *const fn () void,
    /// Re-points the bar's config copy at the live config without rebuilding
    /// the surface. Called on config reloads that leave the bar untouched
    /// (changes.bar == false); see bar.zig `reload`.
    refreshConfig: *const fn () void,
    // Input routing. The chrome overlay pre-empts key handling (returns true
    // when it consumed the key), button presses on the surface window are
    // routed to it, and the three surface config actions mutate chrome state.
    chromeHandleKeypress: *const fn (*const xcb.xcb_key_press_event_t, ?*const types.Action) bool,
    isBarWindow: *const fn (u32) bool,
    handleButtonPress: *const fn (*const xcb.xcb_button_press_event_t) void,
    /// Press-hold motion over the surface: X's implicit grab keeps delivering
    /// motion to the surface window while a button is held, so a scrub-drag
    /// (e.g. a slider sub, volume) can track the pointer even past the bar's
    /// edge. The surface decides whether a segment drag is live and routes it.
    handleButtonMotion: *const fn (*const xcb.xcb_motion_notify_event_t) void,
    /// Releases end a press-hold scrub on the surface; the surface clears its
    /// drag anchor here.
    handleButtonRelease: *const fn (*const xcb.xcb_button_release_event_t) void,
    setBarState: *const fn (types.Action) void,
    /// Pre-computes and applies bar visibility for `ws` (X-free, no
    /// reconcile) so the workspace-switch path gets the correct workarea on
    /// the first reconcile.
    updateBarVisibilityForWorkspace: *const fn (u8) void,
    /// Immediately unmaps the bar and updates the screen claim, without a
    /// separate reconcile. Called from the fullscreen-enter grab so the bar
    /// disappears atomically with the fullscreen geometry — no deferred
    /// ConfigureNotify wait. No-ops when the bar is already hidden.
    hideBarForFullscreen: *const fn () void,
    toggleBarSegmentAnchor: *const fn () void,
    chromeToggleOverlay: *const fn () void,
};

/// The window sub-system hook set. Every module under a window-owner's
/// `modules/` directory binds its `pub const module` value to this type,
/// binding only the hooks it owns (everything else stays `null`). Dispatch
/// order == the generated registry's order == deterministic filesystem scan
/// order.
pub const WindowModule = struct {
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
    // claimed the blob; hooks self-identify via a format tag so the registry
    // loop can't mis-claim.
    serializeWindow: ?*const fn (*const model.Model, u32, std.mem.Allocator) ?[]const u8 = null,
    deserializeWindow: ?*const fn (u32, []const u8, *model.Model) bool = null,
    setEwmhFullscreenState: ?*const fn (u32, bool) void = null,
    armPendingBarHide: ?*const fn (u32) void = null,
    armPendingBarShow: ?*const fn (u32) void = null,
    // ---------- Hide/restore family (minimize module; model vocabulary) ----------
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

    // ---------- Screen-covering family (fullscreen module; model vocabulary) ----------
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
    /// present-not-parked AND visibleOn. At most one module binds
    /// this.
    coveringOccupantOnWs: ?*const fn (*const model.Model, model.WSId) ?model.WindowId = null,
    /// Retarget `win`'s covering intent to `ws` without dropping it (a
    /// covering window stays covering across a workspace move/tag change).
    /// Peer-service seam for the workspaces module; the binding module owns
    /// its record guard. At most one module binds this.
    moveCoveringTo: ?*const fn (*model.Model, model.WindowId, model.WSId) void = null,

    // ---------- Workspaces family (workspaces module) ----------
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

    // ---------- Floating family (floating module; "floating" is model vocabulary) ----------
    /// Update a floating window's rect on the model (no-op for
    /// tiled/unknown).
    setFloatingRect: ?*const fn (*model.Model, model.WindowId, utils.Rect) void = null,
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
    getDragLastRect: ?*const fn () utils.Rect = null,
    cancelDragForWindow: ?*const fn (u32) void = null,
};

/// The `WindowModule` hooks whose contract is "at most one module binds
/// this": dispatch is first-match (`providerOf`/`callHook`/`callHookBool`), so
/// a second binder would be silently ignored. Every other hook is adopted
/// by explicit registry loops (init/deinit, notifyConfigureIfPending,
/// onWindowGone, the serialize/deserialize persistence seam,
/// setEwmhFullscreenState, armPendingBarHide/Show) and may have many
/// binders. The build-generated `window_modules` registry asserts at comptime
/// that each field below has <= 1 binder.
pub const single_binder_hooks = [_][]const u8{
    "hideWindow",       "restoreWindow",         "restoreCandidateOn",
    "restoreOnWs",      "latestHiddenOnWs",      "isWindowHidden",
    "collectHiddenSet", "toggleCovering",        "isCoveringMode",
    "coveringWsOf",     "isCoveringOnWs",        "coveringOccupantOnWs",
    "moveCoveringTo",   "sendToWs",              "addToWs",
    "removeFromWs",     "togglePin",             "toggleAllView",
    "setFloatingRect",  "honorConfigureRequest", "startDrag",
    "stopDrag",         "updateDrag",            "isDragging",
    "isResizingWindow", "getDragLastRect",       "cancelDragForWindow",
};

/// The single canonical registry-lookup entry: the first module in `registry`
/// that binds the hook `field`, in the registry's deterministic scan order.
/// Returns null when no compiled-in module provides
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

pub const Segment = struct {
    /// Config identity ("workspaces", "title", "clock", "layout", "variants").
    /// Unique across the registry; config text resolves to the module by name.
    name: []const u8 = "",
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
    onClick: ?*const fn (
        u16,
        bool,
        bool,
        *anyopaque,
        *const fn (*anyopaque, u16) void,
        *const fn () void,
    ) bool = null,
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
    handleKeypress: ?*const fn (*const xcb.xcb_key_press_event_t, ?*const types.Action) bool = null,
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
/// next to this contract below). `params` is `*model.LayoutParams` for the
/// per-layout pre-reconcile duty (scroll viewport snapping).
pub const Layout = struct {
    /// Canonical name ("master", "monocle", ...). Config text resolves to the
    /// module by name; names also drive the cycle order (config order wins).
    name: []const u8 = "",
    /// Placement computation; must append exactly one placement per window.
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
    margins: utils.Margins = .{},
    min_dim: u16 = 0,
    primary_on_right: bool = false,
    variant_idx: u8 = 0,
};
