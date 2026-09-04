//! Process-wide XCB state and shared types.
//! Must call core.init() before any module accesses core.getState().

const std = @import("std");

const types = @import("types");
const constants = @import("constants");
const utils = @import("utils");

// Centralized here to avoid repeated @cImport translation across compilation units.
pub const xcb = @import("x11").xcb;

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
pub const Connection = *xcb.xcb_connection_t;
pub const Screen = *xcb.xcb_screen_t;

/// Equivalent to xcb_window_t (uint32_t).
pub const WindowId = u32;

/// Workspace index wrapper. The canonical type for workspace identifiers;
/// model code uses raw integers for internal indexing, converted at the
/// entry-point boundary. Prevents confusing indices with unrelated u8
/// values (counts, layout indices, etc.) at call sites.
pub const WorkspaceId = struct {
    index: u8,

    pub fn fromIndex(i: u8) WorkspaceId {
        return .{ .index = i };
    }

    pub fn eql(self: WorkspaceId, other: WorkspaceId) bool {
        return self.index == other.index;
    }
};

/// Why keyboard focus is temporarily withheld from a window.
pub const FocusSuppressReason = enum {
    none,
    window_spawn,
    tiling_operation,
};

// conn, screen, root, and alloc are written once during startup.
// config is a heap-allocated pointer swapped atomically on reload
// (see events.zig handleConfigReload). Bundled into one optional State,
// rather than five `undefined` globals, so any access before init()
// panics cleanly instead of reading undefined memory.
pub const State = struct {
    conn: Connection,
    screen: Screen,
    root: WindowId,
    alloc: std.mem.Allocator,
    config: *types.Config,
    /// Monotonic fact revisions. Bumped by the module that owns each fact
    /// (focus, window/workspace state, layout) whenever that fact changes.
    /// Consumers (e.g. the bar, over its draw poll) diff these revisions
    /// against their last-seen value to decide what to redraw, instead of
    /// being poked by name. Non-core modules never mutate core's facts;
    /// they bump the revision of the fact they changed.
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
};

/// Current focus fact revision.
pub inline fn focusRev() u32 {
    return getState().facts.focus_rev;
}
/// Bumps the focus fact revision. Called by the module that owns focus.
pub inline fn bumpFocus() void {
    getState().facts.focus_rev +%= 1;
}
/// Current window/workspace fact revision.
pub inline fn windowRev() u32 {
    return getState().facts.window_rev;
}
/// Bumps the window/workspace fact revision.
pub inline fn bumpWindow() void {
    getState().facts.window_rev +%= 1;
}
/// Current fullscreen-occupancy fact revision.
pub inline fn fullscreenRev() u32 {
    return getState().facts.fullscreen_rev;
}
/// Bumps the fullscreen-occupancy fact revision. Called by the module that
/// establishes or clears a fullscreen occupant on the current workspace.
pub inline fn bumpFullscreen() void {
    getState().facts.fullscreen_rev +%= 1;
}
/// Current layout fact revision.
pub inline fn layoutRev() u32 {
    return getState().facts.layout_rev;
}
/// Bumps the layout fact revision.
pub inline fn bumpLayout() void {
    getState().facts.layout_rev +%= 1;
}

// ---------------------------------------------------------------------------
// Config-derived windowing facts (owned by core).
// These are the only tiling facts other modules need; they read them here
// instead of importing `tiling`, so `tiling` stays a true plugin. They are
// thin config reads core can answer from its own config.

/// Whether the tiling windowing paradigm is enabled (config fact).
pub inline fn tilingEnabled() bool {
    return getState().config.tiling.enabled;
}

/// Scaled tiling border width in pixels (config fact).
pub inline fn borderWidth() u16 {
    const cs = getState();
    return utils.scaling.scaleBorderWidth(
        cs.config.tiling.border_width,
        cs.screen.height_in_pixels,
    );
}

var state: ?State = null;

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
    config: *types.Config,
) void {
    state = .{ .conn = conn, .screen = screen, .root = root, .alloc = alloc, .config = config };
}

/// Stays outside State: unlike State's fields it has a safe default
/// (96.0 DPI, no scaling), and is set once during scale detection, never
/// reassigned afterward.
pub var dpi_info: std.atomic.Value(f32) = std.atomic.Value(f32).init(constants.baseline_dpi);
