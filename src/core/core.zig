//! Process-wide XCB state and shared types.
//! Must call core.init() before any module accesses core.getState().

const std = @import("std");

const types = @import("types");
const constants = @import("constants");

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

/// Workspace index wrapper. Prevents confusing workspace indices with
/// unrelated u8 values (counts, layout indices, etc.) at call sites.
pub const WorkspaceId = struct {
    index: u8,

    pub fn fromIndex(i: u8) WorkspaceId {
        return .{ .index = i };
    }

    pub fn toIndex(self: WorkspaceId) u8 {
        return self.index;
    }

    pub fn eql(self: WorkspaceId, other: WorkspaceId) bool {
        return self.index == other.index;
    }

    pub fn order(self: WorkspaceId, other: WorkspaceId) std.math.Order {
        return std.math.order(u8, self.index, other.index);
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
};

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
pub fn init(conn: Connection, screen: Screen, root: WindowId, alloc: std.mem.Allocator, config: *types.Config) void {
    state = .{ .conn = conn, .screen = screen, .root = root, .alloc = alloc, .config = config };
}

/// Stays outside State: unlike State's fields it has a safe default
/// (96.0 DPI, no scaling), and is set once during scale detection, never
/// reassigned afterward.
pub var dpi_info: std.atomic.Value(f32) = std.atomic.Value(f32).init(constants.baseline_dpi);
