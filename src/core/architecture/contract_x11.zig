//! The X-aware half of the window/segment contract.
//!
//! `contract.zig` is the pure vocabulary: hook shapes, registries, geometry
//! value objects, and nothing that names an X type. Everything here needs X,
//! so it lives on the other side of the seam and is imported ONLY by the
//! composition roots that already talk to the server (the bar's hook
//! construction, and a module that must read the fields of an event it
//! receives).
//!
//! The split exists so the contract can be described without X: a headless
//! consumer -- a config-only tool, a test that never opens a display -- can
//! import `contract` and get the whole hook surface without dragging in a
//! connection type it has no way to produce.

const core = @import("core");
const xcb = core.xcb;
const types = @import("types");

/// The concrete X key-press event, for the `contract.KeyPressEvent` opaque.
pub const KeyPressEvent = xcb.xcb_key_press_event_t;

/// The chrome-surface hook set a surface module binds to. The bar binds its
/// `surfaces` value to this; when no surface is compiled in, the generated
/// `surfaces.Surfaces` is a full set of no-op hooks (see build.zig), so this is
/// ONE type in every build and call sites never test a build flag.
pub const Surfaces = struct {
    // Boot lifecycle, invoked from startup through surfaces.Surfaces so the
    // boot sequence never needs to name the bar module directly.
    init: *const fn () anyerror!void,
    deinit: *const fn () void,
    // Event-loop hooks.
    handleExpose: *const fn (*const xcb.xcb_expose_event_t) void,
    /// No error union: the bar records its own failures (module draw errors
    /// are logged and leave the segment dirty) rather than propagating, and an
    /// `anyerror!void` here forced every call site to write a `catch` arm that
    /// could only ever log the same thing.
    updateIfDirty: *const fn () void,
    /// The nearest wakeup this surface wants, or null for "block until an
    /// fd is ready". The loop reduces this over its own `Timers` list, so the
    /// surface reports ONE answer and does not re-state the min/absence rule.
    pollTimeoutMs: *const fn () ?i32,
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
