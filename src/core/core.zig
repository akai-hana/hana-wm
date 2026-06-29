//! Central hub for process-wide XCB state and shared types.
//! `core.init()` must be called from main before any other module calls
//! `core.getState()` — see `State` below for why and how this is enforced.

const std = @import("std");

const constants = @import("constants");
const types = @import("types");

// Centralised to avoid repeated @cImport translation across compilation units.
pub const xcb = @cImport(@cInclude("xcb/xcb.h"));

/// X11 keysym constants. Values match <X11/keysymdef.h> (stable since X11R1).
/// Cast to xcb_keysym_t with `@intFromEnum`.
pub const XK = enum(u32) {
    BackSpace = 0xff08,
    Tab = 0xff09,
    Return = 0xff0d,
    Escape = 0xff1b,
    Home = 0xff50,
    Left = 0xff51,
    Up = 0xff52,
    Right = 0xff53,
    Down = 0xff54,
    End = 0xff57,
    Delete = 0xffff,
};

/// Equivalent to xcb.xcb_window_t (uint32_t); named for readability.
pub const WindowId = u32;

/// Geometry snapshot used by both fullscreen and minimize.
pub const WindowGeometry = struct {
    x: i16,
    y: i16,
    width: u16,
    height: u16,
    border_width: u16,
};

/// Focus suppression reason for context-aware behavior.
pub const FocusSuppressReason = enum {
    /// No suppression (default)
    none,
    /// Window just spawned
    window_spawn,
    /// Tiling in progress
    tiling_operation,
};

/// DPI and scale factor detected at startup.
/// Defined here so modules can reference the type without importing scale
pub const DpiInfo = struct {
    dpi: f32,

    /// Computes scale factor relative to BASELINE_DPI on demand.
    pub fn scaleFactor(self: DpiInfo) f32 {
        return self.dpi / constants.BASELINE_DPI;
    }
};

// Process-wide singletons.
//
// `conn`, `screen`, `root`, `alloc`, and `config` are all written exactly
// once during main()'s startup sequence (config is later *replaced*
// wholesale on a config reload — see events.zig — but the act of replacing
// it is itself just a normal field write, not a teardown).  Before that
// first write they have no sensible value, so they're bundled into one
// `?State` rather than left as five separate `undefined` globals: any
// access before init() is a clear, safe @panic in every build mode, never
// silent undefined behaviour in ReleaseFast.
//
// This mirrors the pattern `tiling.zig` already uses for its own state
// (see `tiling.getState()` / `tiling.getStateOpt()`); core now follows the
// same convention instead of being the one place that didn't.
pub const State = struct {
    conn: *xcb.xcb_connection_t,
    screen: *xcb.xcb_screen_t,
    root: WindowId,
    alloc: std.mem.Allocator,
    config: types.Config,
};

// Null before init(), non-null for the rest of the process lifetime.
// Using ?State rather than five undefined fields makes pre-init access a
// safe runtime @panic in all build modes, not UB in ReleaseFast.
var state: ?State = null;

/// Returns a pointer to the live core state.
/// Panics in all build modes when called before init() — never silent UB.
pub inline fn getState() *State {
    if (state) |*s| return s;
    @panic("core: getState() called before init()");
}

/// Safe pre-init query for code that may run before main() finishes startup
/// (e.g. a test that imports `core` without driving the normal boot path).
pub inline fn getStateOpt() ?*State {
    return if (state) |*s| s else null;
}

/// Establishes the process-wide core state. Must be called exactly once,
/// after the X connection is open and the initial config has been loaded,
/// and before any other module calls `getState()`.
pub fn init(conn: *xcb.xcb_connection_t, screen: *xcb.xcb_screen_t, root: WindowId, alloc: std.mem.Allocator, config: types.Config) void {
    state = .{ .conn = conn, .screen = screen, .root = root, .alloc = alloc, .config = config };
}

// `dpi_info` deliberately stays outside `State`: unlike the fields above it
// already carries a safe, sensible default (96.0 DPI, i.e. "assume no
// scaling") instead of `undefined`, so it never had the uninitialised-access
// hazard `State` exists to fix. It's set once during scale detection at
// startup and never reassigned afterward.
pub var dpi_info: DpiInfo = .{ .dpi = 96.0 };

/// Returns true if the XCB connection is open and error-free.
pub fn isConnValid() bool {
    return xcb.xcb_connection_has_error(getState().conn) == 0;
}
