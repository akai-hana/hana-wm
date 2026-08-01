//! Central hub for process-wide XCB state and shared types.
//! core.init() must be called from main before any other module calls
//! core.getState().

const std = @import("std");

const constants = @import("constants");
const types = @import("types");

// Centralized here to avoid repeated @cImport translation across compilation units.
pub const xcb = @cImport(@cInclude("xcb/xcb.h"));

/// X11 keysym constants, matching <X11/keysymdef.h>. Cast to xcb_keysym_t with @intFromEnum.
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

/// Equivalent to xcb_window_t (uint32_t).
pub const WindowId = u32;

/// Geometry snapshot used by fullscreen and minimize.
pub const WindowGeometry = struct {
    x: i16,
    y: i16,
    width: u16,
    height: u16,
    border_width: u16,
};

/// Focus suppression reason for context-aware behavior.
pub const FocusSuppressReason = enum {
    none,
    window_spawn,
    tiling_operation,
};

/// DPI and scale factor detected at startup.
pub const DpiInfo = struct {
    dpi: f32,

    pub fn scaleFactor(self: DpiInfo) f32 {
        return self.dpi / constants.BASELINE_DPI;
    }
};

// conn, screen, root, alloc, and config are written once during startup
// (config is later replaced wholesale on reload — see events.zig). Bundled
// into one optional State, rather than five `undefined` globals, so any
// access before init() panics cleanly instead of reading undefined memory.
// Mirrors the pattern tiling.zig uses for its own state.
pub const State = struct {
    conn: *xcb.xcb_connection_t,
    screen: *xcb.xcb_screen_t,
    root: WindowId,
    alloc: std.mem.Allocator,
    config: types.Config,
};

var state: ?State = null;

/// Pointer to the live core state. Panics if called before init().
pub inline fn getState() *State {
    if (state) |*s| return s;
    @panic("core: getState() called before init()");
}

/// Safe pre-init query, for code that may run before main() finishes startup
/// (e.g. a test that imports core without driving the normal boot path).
pub inline fn getStateOpt() ?*State {
    return if (state) |*s| s else null;
}

/// Establishes the process-wide core state. Must be called exactly once,
/// after the X connection is open and config is loaded, before any
/// other module calls getState().
pub fn init(conn: *xcb.xcb_connection_t, screen: *xcb.xcb_screen_t, root: WindowId, alloc: std.mem.Allocator, config: types.Config) void {
    state = .{ .conn = conn, .screen = screen, .root = root, .alloc = alloc, .config = config };
}

/// Stays outside State: unlike State's fields it has a safe default
/// (96.0 DPI, no scaling), and is set once during scale detection, never
/// reassigned afterward.
pub var dpi_info: DpiInfo = .{ .dpi = 96.0 };

/// True if the XCB connection is open and error-free.
pub fn isConnValid() bool {
    return xcb.xcb_connection_has_error(getState().conn) == 0;
}
