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
    // Input routing. The prompt pre-empts key handling (returns true when it
    // consumed the key), button presses on the bar window are routed to it,
    // and the three bar config actions mutate bar state.
    promptHandleKeypress: *const fn (*const xcb.xcb_key_press_event_t, ?*const types.Action) bool,
    isBarWindow: *const fn (u32) bool,
    handleButtonPress: *const fn (*const xcb.xcb_button_press_event_t) void,
    setBarState: *const fn (types.Action) void,
    toggleBarSegmentAnchor: *const fn () void,
    promptToggle: *const fn () void,
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
    // state as an opaque blob; restart_state carries `[]u8` bytes and the
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
    // Floating drag/resize commands.
    startDrag: ?*const fn (u32, u8, i16, i16) void = null,
    stopDrag: ?*const fn () void = null,
    updateDrag: ?*const fn (i16, i16) void = null,
    isDragging: ?*const fn () bool = null,
    isResizingWindow: ?*const fn (u32) bool = null,
    getDragLastRect: ?*const fn () utils.Rect = null,
    cancelDragForWindow: ?*const fn (u32) void = null,
};
