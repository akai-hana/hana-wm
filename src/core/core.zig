//! Process-wide XCB state and shared types.
//! Must call core.init() before any module accesses core.getState().

const std = @import("std");

const types = @import("types");
const composed = @import("composed");
const scaling = @import("scaling");
const build_options = @import("build_options");

// Centralized here to avoid repeated @cImport translation across compilation units.
const xcbmod = @import("xcb");
const log = @import("log");
pub const xcb = xcbmod.xcb;

/// X11 keysym constants, matching <X11/keysymdef.h>. Cast to xcb_keysym_t with @intFromEnum.
pub const XK = enum(u32) {
    BackSpace = 0xff08,
    Tab = 0xff09,
    Return = 0xff0d,
    Escape = 0xff1b,
    Home = 0xff50,
    Left = 0xff51,
    Right = 0xff53,
    End = 0xff57,
    Delete = 0xffff,
};

/// Thin wrappers over raw XCB types, decoupling public APIs from the C binding.
/// Re-exported from the x11 leaf (`x11/xcb.zig`) so there is one definition of
/// each alias and the x11 layer never has to reach back into this hub.
pub const Connection = xcbmod.Connection;
pub const Screen = xcbmod.Screen;

/// Narrows a queued `*anyopaque` event to its concrete xcb event type. Lives in
/// the x11 leaf beside the cImport; re-exported here because the event loop
/// and display/hz.zig's randr notify handler are its callers and both already
/// speak through `core`.
pub const eventCast = xcbmod.eventCast;

/// Alias of the canonical `model.WindowId` (xcb_window_t); see the model
/// header for the single-definition rationale.
pub const WindowId = @import("model").WindowId;

/// Workspace index wrapper. `model.WSId` is this same type; see the model
/// header for the single-definition rationale.
pub const WorkspaceId = @import("model").WorkspaceId;

/// The single workspace-index range check (model.isValidWorkspaceIndex);
/// re-exported here so callers outside core speak the same predicate as
/// `WorkspaceId.isValid`.
pub const isValidWorkspaceIndex = @import("model").isValidWorkspaceIndex;

/// Why keyboard focus is temporarily withheld from a window.
pub const FocusSuppressReason = enum {
    none,
    window_spawn,
    tiling_operation,
};

// conn, screen, root, and alloc are written once during startup.
// config is a heap-allocated pointer swapped atomically on reload
// (see reload.zig handleConfigReload). Bundled into one optional State,
// rather than five `undefined` globals, so any access before init()
// panics cleanly instead of reading undefined memory.
pub const State = struct {
    conn: Connection,
    screen: Screen,
    root: WindowId,
    alloc: std.mem.Allocator,
    /// Display DPI, set by `main` once the config is loaded (a config override
    /// wins over detection) and re-derived on a RandR size change. Default is
    /// the baseline so a build that somehow never sets it still reads a
    /// defined value; `main` always sets it before any surface exists.
    dpi_info: f32 = baseline_dpi,
    config: *composed.Config,
    /// Monotonic fact revisions, bumped by the module owning each fact (see
    /// Facts); consumers diff against their last-seen value to decide what
    /// to redraw.
    facts: Facts = .{},
};

/// Revisions for the facts core publishes. Each counter increments when its
/// owning module changes the corresponding fact set. Consumers compare the
/// current value to their cached one to detect "something I render changed".
pub const Facts = struct {
    /// Bumped when keyboard/window focus changes (bar: title segment).
    focus_rev: u32 = 0,
    /// Bumped when window/workspace state changes (arrange, minimize, tag,
    /// admit, remove) that re-derive placements (bar: all segments).
    window_rev: u32 = 0,
    /// Bumped when the fullscreen occupancy of the current workspace changes
    /// (a window enters or exits fullscreen, or workspaces switch). Surfaces
    /// that must hide/show to share the screen (the bar) react to this.
    fullscreen_rev: u32 = 0,
    /// Bumped when the tiling/layout kind or variants change (bar: full
    /// redraw, including a title-data refetch).
    layout_rev: u32 = 0,
    /// Bumped by `replaceOwnedConfig` on every live-config swap, including the
    /// initial one. It exists so a table of POINTERS INTO the config's data --
    /// the keybind dispatch map, which holds `*const Action` into the
    /// keybindings slice -- can tell that it is stale without dereferencing
    /// anything. The old config is freed at the swap, so reading through a
    /// stale entry is a use-after-free; comparing a counter is not. See
    /// `keybind.KeybindResolver.rebuildDispatchMap`.
    config_rev: u32 = 0,
};

fn factAccessors(comptime field: []const u8) type {
    return struct {
        pub inline fn rev() u32 {
            return @field(getState().facts, field);
        }
        pub inline fn bump() void {
            @field(getState().facts, field) +%= 1;
        }
    };
}

pub const focus = factAccessors("focus_rev");
pub const window = factAccessors("window_rev");
pub const fullscreen = factAccessors("fullscreen_rev");
pub const layout = factAccessors("layout_rev");
pub const config_rev = factAccessors("config_rev");

// Config-derived windowing facts (owned by core).
// These are the only tiling facts other modules need; they read them here
// instead of importing `tiling`, so `tiling` stays a true contract. They are
// thin config reads core can answer from its own config.

/// Whether the tiling windowing paradigm is compiled in (build fact).
pub inline fn tilingEnabled() bool {
    return build_options.has_tiling;
}

/// Scaled tiling border width in pixels (config fact).
pub inline fn borderWidth() u16 {
    if (comptime !build_options.has_tiling) return 0; // neutral: no tiled chrome
    const cs = getState();
    return scaling.scaleBorderWidth(
        cs.config.tiling.border_width,
        cs.screen.height_in_pixels,
    );
}

var state: ?State = null;

/// How far boot has progressed toward a usable model. Independent of `state`
/// by design: a headless fixture can have a model with no X connection, so
/// "is State live" (isReady) and "is the model live" (this) are two facts.
const Phase = enum {
    /// No model yet: state()/mut() would panic.
    uninit,
    /// pipeline.init() has run: the model instance and its sink exist, so
    /// state()/mut() are safe to call. Terminal.
    model_ready,
};

var phase: Phase = .uninit;

/// Records that the model pipeline is live. Deliberately does NOT require
/// core.init() first: a headless unit-test fixture has no X connection and so
/// can never establish State, yet still needs a model. In production the
/// order is core.init() then pipeline.init(), fixed by main's call sequence.
pub inline fn markModelReady() void {
    phase = .model_ready;
}

/// True once core.init() ran, i.e. State (conn/screen/config/alloc) is live.
/// Guards boot-time config latches (e.g. the query workspace-count latch)
/// that a test harness may invoke before core is ready. Reads State itself
/// rather than the phase: "is State populated" is a fact about State, and a
/// headless fixture legitimately answers no while still having a model.
pub inline fn isReady() bool {
    return state != null;
}

/// True once the model exists and state()/mut() are safe. The one answer
/// every model consumer reads.
pub inline fn isModelReady() bool {
    return phase == .model_ready;
}

/// Panics if called before init().
pub inline fn getState() *State {
    if (state) |*s| return s;
    @panic("core: getState() called before init()");
}

/// Establishes the process-wide core state. Must be called exactly once,
/// after the X connection is open and config is loaded, before any
/// other module calls getState(). Takes ownership of the config pointer;
/// the caller must not free it.
pub fn init(
    conn: Connection,
    screen: Screen,
    root: WindowId,
    alloc: std.mem.Allocator,
    config: *composed.Config,
    initial_dpi: f32,
) void {
    // Asserts boot starts clean: a second core.init() would silently orphan
    // the first State and the config box it owns.
    std.debug.assert(state == null);
    state = .{
        .conn = conn,
        .screen = screen,
        .root = root,
        .alloc = alloc,
        .config = config,
        .dpi_info = initial_dpi,
    };
}

/// Re-reads the current screen size and writes it into the cached `Screen`,
/// returning true if it actually changed.
///
/// `State.screen` is a pointer into the `xcb_screen_t` the server handed back
/// at setup time, captured once in `main.zig` before the WM role was claimed.
/// A RandR mode change -- resolution switch, rotate, a monitor being plugged
/// in -- changes the screen's real size, and that setup-time struct never
/// learns about it. Every consumer then reasons from the size the display had
/// at startup: the work area, percentage bar heights, font scaling, the
/// surface claim. A resolution change therefore left the whole bar sized for
/// the old screen with nothing to indicate it, which is why this belongs here
/// in core, once, rather than patched per consumer.
///
/// Only the pixel dimensions are re-read. Root depth, the root visual and the
/// allowed-depth list are properties of the screen's visual class, not of the
/// current mode, and the millimetre size is a physical property a mode change
/// does not alter. The root's origin is pinned at 0,0 by the server, so
/// re-reading it too would only risk writing a transient mid-resize value.
///
/// Deliberately does NOT reconcile. This is called from event dispatch, and a
/// reconcile takes the X grab; reconciling from inside dispatch is the
/// re-entrancy this is meant to remove. It reports the change and the caller
/// lets the existing debounced re-detect path do the rest of the work at a
/// controlled point in the loop.
pub fn refreshScreenGeometry(conn: Connection) bool {
    const st = getState();
    const cookie = xcb.xcb_get_geometry(conn, st.root);
    const geom = xcb.xcb_get_geometry_reply(conn, cookie, null) orelse return false;
    defer std.c.free(geom);

    const new_w: u16 = @intCast(geom.*.width);
    const new_h: u16 = @intCast(geom.*.height);
    if (new_w == st.screen.width_in_pixels and new_h == st.screen.height_in_pixels) return false;

    log.info(
        "Screen geometry changed: {d}x{d} -> {d}x{d}",
        .{ st.screen.width_in_pixels, st.screen.height_in_pixels, new_w, new_h },
    );
    st.screen.width_in_pixels = new_w;
    st.screen.height_in_pixels = new_h;
    return true;
}

/// Deinit and free the config box `State` owns, using the allocator `State`
/// was initialized with. `core.init` is the only producer, so this is the
/// only way the box is ever released.
pub fn deinitOwnedConfig() void {
    const cs = &state.?;
    cs.config.deinit(cs.alloc);
    cs.alloc.destroy(cs.config);
}

/// Swap in a freshly allocated config box and release the one being displaced.
/// Ownership moves with the pointer, which is what makes the two call sites
/// (shutdown and reload) able to share this one call: neither has to reason
/// about whether the box it is holding is still the live one.
pub fn replaceOwnedConfig(new_config: *composed.Config) void {
    deinitOwnedConfig();
    state.?.config = new_config;
    // Bumped AFTER the swap and after the old box is freed: every consumer
    // that compares against this value is deciding whether a pointer it holds
    // is still live, so the counter has to change after the freeing, never
    // before it.
    config_rev.bump();
}

/// Display DPI in use, as a fact on `State` rather than a bare global.
///
/// A bare global would let the value that scales every font metric the bar
/// probes live somewhere no initialization order constrains: `State`'s own
/// accessors panic when read before `init`, but a global quietly answers with
/// a default, so a module that reads it early gets `baseline_dpi` and a bar
/// sized for the wrong display, with no signal that the real value has not
/// arrived yet. As a field it is covered by the same "uninitialized access
/// panics cleanly" rule as everything else.
///
/// Two writers only: `init` seeds it (a config override beats detection), and
/// `setDpi` re-derives it on the RandR size-change path.
pub fn dpi() f32 {
    return getState().dpi_info;
}

pub fn setDpi(v: f32) void {
    getState().dpi_info = v;
}

/// Standard DPI for a 1x display. All scale factors are computed relative to
/// this value.
pub const baseline_dpi: f32 = 96.0;

// Clock reads
// Monotonic and wall-clock time, kept together so a caller picks the family
// deliberately: `monotonic*` is wall-independent and is what deadlines and
// frame deltas must use; `realtime*` is for displayed timestamps and expiry
// against the wall clock.

// clock_gettime with a best-effort fallback to the other clock id (a
// monotonic-realtime node or similar), then nanos.
fn clockNs(clock_id: std.os.linux.clockid_t) u64 {
    var ts: std.os.linux.timespec = undefined;
    if (std.os.linux.clock_gettime(clock_id, &ts) != 0) {
        const fallback_id: std.os.linux.clockid_t =
            if (clock_id == .MONOTONIC) .REALTIME else .MONOTONIC;
        if (std.os.linux.clock_gettime(fallback_id, &ts) != 0)
            ts = .{ .sec = 0, .nsec = 0 };
    }
    return @as(u64, @intCast(ts.sec)) * 1_000_000_000 + @as(u64, @intCast(ts.nsec));
}

pub inline fn monotonicNs() u64 {
    return clockNs(.MONOTONIC);
}

/// Monotonic milliseconds (wall-independent; for deltas and deadlines).
pub inline fn monotonicMs() i64 {
    return @intCast(monotonicNs() / std.time.ns_per_ms);
}

/// Wall-clock milliseconds (for timestamps/expiry, not deltas).
pub inline fn realtimeMs() i64 {
    return @intCast(realtimeNs() / std.time.ns_per_ms);
}

pub inline fn realtimeNs() u64 {
    return clockNs(.REALTIME);
}
