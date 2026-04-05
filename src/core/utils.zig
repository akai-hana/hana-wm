//! hana core utilities
//! Includes X11 geometry helpers, atom caching, ICCCM input model caching, and process lifecycle signals.

const std = @import("std");

const core      = @import("core");
    const xcb   = core.xcb;
const constants = @import("constants");

const debug = @import("debug");


const MAX_PROPERTY_LENGTH: u32 = 256;
/// Minimum window dimension; windows thinner or shorter than this are considered invalid.
const MIN_WINDOW_DIM = constants.MIN_WINDOW_DIM;
/// Maximum depth when walking the X11 window tree in findManagedWindow.
const MAX_WINDOW_TREE_DEPTH = constants.MAX_WINDOW_TREE_DEPTH;
/// Passed as the `delete` argument to xcb_get_property; 0 means do not consume the property.
const PROPERTY_NO_DELETE: u8 = 0;
const WM_HINTS_INPUT_FLAG:   u32   = 1 << 0;
const WM_HINTS_FLAGS_FIELD:  usize = 0;
const WM_HINTS_INPUT_FIELD:  usize = 1;
const WM_HINTS_LONG_LENGTH:  u32   = 9; // flags + 8 fields

// Process lifecycle signals
//
// Module-level atomics rather than WM struct fields, because they are process control state, not window-manager state.
// Signal handlers and keybind actions write here; the main event loop reads here.

/// Set to false by SIGTERM/SIGINT to break the main event loop.
pub var running = std.atomic.Value(bool).init(true);

/// Set to true by SIGHUP or the `reload_config` keybinding.
/// Consumed by `maybeReload` in the main event loop.
pub var should_reload = std.atomic.Value(bool).init(false);

/// Signals the main event loop to exit cleanly.
pub inline fn quit() void { running.store(false, .release); }

/// Signals the main event loop to reload the user config.
pub inline fn reload() void { should_reload.store(true, .release); }

/// Atomically consumes the reload flag.
/// Returns true exactly once per request, whichever call path checks first wins.
pub inline fn consumeReload() bool {
    return should_reload.swap(false, .acq_rel);
}

// Geometry operations


/// Position and dimensions of a managed window, relative to the root window (the total display area).
pub const Rect = struct {
    x:      i16,
    y:      i16,
    width:  u16,
    height: u16,

    pub inline fn fromXcb(geom: *const xcb.xcb_get_geometry_reply_t) Rect {
        return .{ .x = geom.x, .y = geom.y, .width = geom.width, .height = geom.height };
    }

    pub inline fn isValid(self: Rect) bool {
        return self.width >= MIN_WINDOW_DIM and self.height >= MIN_WINDOW_DIM;
    }
};

/// Gap and border widths applied around a tiled window.
pub const Margins = struct {
    gap:    u16,
    border: u16,

    /// Returns the total space consumed on one axis (gap + border on each side).
    pub inline fn total(self: Margins) u16 { return self.gap + 2 * self.border; }
};

/// Moves and resizes `win` without touching border_width.
/// Use `window.configureWindowGeom` when border_width must change atomically.
pub inline fn configureWindow(conn: *xcb.xcb_connection_t, win: u32, rect: Rect) void {
    _ = xcb.xcb_configure_window(
        conn, win,
        xcb.XCB_CONFIG_WINDOW_X | xcb.XCB_CONFIG_WINDOW_Y |
            xcb.XCB_CONFIG_WINDOW_WIDTH | xcb.XCB_CONFIG_WINDOW_HEIGHT,
        &[_]u32{
            @bitCast(@as(i32, rect.x)),
            @bitCast(@as(i32, rect.y)),
            rect.width,
            rect.height,
        },
    );
}

/// Strips lock-key and pointer-button bits from a raw event modifier state,
/// leaving only the modifier bits the WM uses for keybinding matching.
pub inline fn normalizeModifiers(state: u16) u16 {
    return state & constants.MOD_MASK_BINDING;
}

// Atom cache
//
// Field names match X11 atom strings exactly so getAtomCached can resolve them with a single @field call:
// No switch, no redundant enum, no second place to add entries when a new atom is needed.
const AtomCache = struct {
    @"WM_PROTOCOLS":             u32,
    @"WM_DELETE_WINDOW":         u32,
    @"WM_TAKE_FOCUS":            u32,
    @"_NET_WM_NAME":             u32,
    @"UTF8_STRING":              u32,
    @"WM_CLASS":                 u32,
    // Bar window property atoms
    // Batched here so setWindowProperties pays zero X round-trips rather than 10 serial ones.
    @"_NET_WM_STRUT_PARTIAL":    u32,
    @"_NET_WM_WINDOW_TYPE":      u32,
    @"_NET_WM_WINDOW_TYPE_DOCK": u32,
    @"_NET_WM_STATE":            u32,
    @"_NET_WM_STATE_FULLSCREEN": u32,
    @"_NET_WM_STATE_ABOVE":      u32,
    @"_NET_WM_STATE_STICKY":     u32,
    @"_NET_WM_ALLOWED_ACTIONS":  u32,
    @"_NET_WM_ACTION_CLOSE":     u32,
    @"_NET_WM_ACTION_ABOVE":     u32,
    @"_NET_WM_ACTION_STICK":     u32,
    @"_NET_WM_PID":              u32,
};

var atom_cache: ?AtomCache = null;

/// Interns all atoms in a single round-trip batch.
/// Atom names are derived from `AtomCache` field names at comptime, so adding a field is the only change required:
/// No parallel array to maintain, and no index-order mismatch risk.
pub fn initAtomCache(conn: *xcb.xcb_connection_t) !void {
    const fields = std.meta.fields(AtomCache);
    var cookies: [fields.len]xcb.xcb_intern_atom_cookie_t = undefined;

    inline for (fields, 0..) |f, i|
        cookies[i] = xcb.xcb_intern_atom(conn, 0, @intCast(f.name.len), f.name.ptr);

    var cache: AtomCache = undefined;
    inline for (fields, 0..) |f, i| {
        const reply = xcb.xcb_intern_atom_reply(conn, cookies[i], null) orelse {
            for (i + 1..fields.len) |j| xcb.xcb_discard_reply(conn, cookies[j].sequence);
            return error.AtomFailed;
        };
        defer std.c.free(reply);
        @field(cache, f.name) = reply.*.atom;
    }
    atom_cache = cache;
}

/// Interns a single atom by name, always making a server round-trip.
/// Prefer `getAtomCached` for atoms known at compile time.
pub fn getAtom(conn: *xcb.xcb_connection_t, name: []const u8) !u32 {
    const reply = xcb.xcb_intern_atom_reply(
        conn,
        xcb.xcb_intern_atom(conn, 0, @intCast(name.len), name.ptr),
        null,
    ) orelse {
        debug.err("Failed to intern atom: {s}", .{name});
        return error.AtomFailed;
    };
    defer std.c.free(reply);
    return reply.*.atom;
}

/// Looks up a cached atom by name.
/// Unknown names produce a compile error rather than a silent runtime failure.
pub inline fn getAtomCached(comptime name: []const u8) error{AtomCacheNotInitialized}!u32 {
    comptime if (!@hasField(AtomCache, name)) @compileError("atom not in cache: " ++ name);
    const cache = atom_cache orelse return error.AtomCacheNotInitialized;
    return @field(cache, name);
}

// Property helpers

/// Fetches an 8-bit X11 window property into a caller-supplied reuse buffer.
/// Returns a slice into `buffer.items` on success, or null if the property is absent, empty, or not 8-bit encoded.
/// The buffer is cleared before each use, so the caller can allocate it once and pass it across repeated calls.
pub fn fetchPropertyToBuffer(
    conn:      *xcb.xcb_connection_t,
    window:    u32,
    atom:      u32,
    atom_type: u32,
    buffer:    *std.ArrayListUnmanaged(u8),
    allocator: std.mem.Allocator,
) !?[]const u8 {
    const reply = xcb.xcb_get_property_reply(conn,
        xcb.xcb_get_property(conn, PROPERTY_NO_DELETE, window, atom, atom_type, 0, MAX_PROPERTY_LENGTH),
        null,
    ) orelse return null;
    defer std.c.free(reply);
    if (reply.*.format != 8 or reply.*.value_len == 0) return null;

    buffer.clearRetainingCapacity();
    const value_ptr: [*]const u8 = @ptrCast(xcb.xcb_get_property_value(reply));
    try buffer.appendSlice(allocator, value_ptr[0..@intCast(reply.*.value_len)]);
    return buffer.items;
}
