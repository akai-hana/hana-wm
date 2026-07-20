//! Core utilities
//! Provides shared geometry helpers, process lifecycle signals, and X11 property utilities for the WM core.

const std = @import("std");

const core = @import("core");
const xcb = core.xcb;
const constants = @import("constants");

const debug = @import("debug");

const max_property_length = constants.PROPERTY_MAX_LENGTH;
/// Passed as the `delete` argument to xcb_get_property; 0 means do not consume the property.
const property_no_delete = constants.PROPERTY_NO_DELETE;

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
pub inline fn quit() void {
    running.store(false, .release);
}

/// Signals the main event loop to reload the user config.
pub inline fn reload() void {
    should_reload.store(true, .release);
}

/// Atomically consumes the reload flag.
/// Returns true exactly once per request, whichever call path checks first wins.
pub inline fn consumeReload() bool {
    return should_reload.swap(false, .acq_rel);
}

// Geometry operations

/// Position and dimensions of a managed window, relative to the root window (the total display area).
pub const Rect = struct {
    x: i16,
    y: i16,
    width: u16,
    height: u16,

    /// Constructs a Rect from an XCB geometry reply.
    pub inline fn fromXcb(geom: *const xcb.xcb_get_geometry_reply_t) Rect {
        return .{ .x = geom.x, .y = geom.y, .width = geom.width, .height = geom.height };
    }

    /// Returns true when both dimensions meet the minimum window size requirement.
    pub inline fn isValid(self: Rect) bool {
        return self.width >= constants.MIN_WINDOW_DIM and self.height >= constants.MIN_WINDOW_DIM;
    }
};

/// Gap and border widths applied around a tiled window.
pub const Margins = struct {
    gap: u16,
    border: u16,
};

/// Moves and resizes `win` without touching border_width.
/// Use `window.configureWindowGeom` when border_width must change atomically.
pub inline fn configureWindow(conn: *xcb.xcb_connection_t, win: u32, rect: Rect) void {
    const coord = struct {
        inline fn u(v: i16) u32 {
            return @bitCast(@as(i32, v));
        }
    }.u;
    _ = xcb.xcb_configure_window(
        conn,
        win,
        xcb.XCB_CONFIG_WINDOW_X | xcb.XCB_CONFIG_WINDOW_Y |
            xcb.XCB_CONFIG_WINDOW_WIDTH | xcb.XCB_CONFIG_WINDOW_HEIGHT,
        &[_]u32{ coord(rect.x), coord(rect.y), rect.width, rect.height },
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
    WM_PROTOCOLS: u32,
    WM_DELETE_WINDOW: u32,
    WM_TAKE_FOCUS: u32,
    _NET_WM_NAME: u32,
    UTF8_STRING: u32,
    WM_CLASS: u32,
    // Bar window property atoms
    // Batched here so setWindowProperties pays zero X round-trips rather than 10 serial ones.
    _NET_WM_STRUT_PARTIAL: u32,
    _NET_WM_WINDOW_TYPE: u32,
    _NET_WM_WINDOW_TYPE_DOCK: u32,
    _NET_WM_STATE: u32,
    _NET_WM_STATE_FULLSCREEN: u32,
    _NET_WM_STATE_ABOVE: u32,
    _NET_WM_STATE_STICKY: u32,
    _NET_WM_ALLOWED_ACTIONS: u32,
    _NET_WM_ACTION_CLOSE: u32,
    _NET_WM_ACTION_ABOVE: u32,
    _NET_WM_ACTION_STICK: u32,
    _NET_WM_PID: u32,
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

/// Looks up a cached atom by name.
/// Unknown names produce a compile error rather than a silent runtime failure.
pub inline fn getAtomCached(comptime name: []const u8) error{AtomCacheNotInitialized}!u32 {
    comptime if (!@hasField(AtomCache, name)) @compileError("atom not in cache: " ++ name);
    const cache = atom_cache orelse return error.AtomCacheNotInitialized;
    return @field(cache, name);
}

// Property helpers

/// Canonical implementations of the no-DPI-info scaling formulas.
/// scale.zig delegates scaleBorderWidth/scaleMasterWidth to these directly
/// (they need no DPI lookup), so there is exactly one formula to maintain.
pub const scale_fallback = struct {
    pub fn scaleMasterWidth(value: anytype) f32 {
        return if (value.is_percentage) value.value / 100.0 else -value.value;
    }
    pub fn scaleBorderWidth(value: anytype, reference_dimension: u16) u16 {
        const v: f32 = if (value.is_percentage)
            (value.value / 100.0) * 0.5 * @as(f32, @floatFromInt(reference_dimension))
        else
            value.value;
        return @intFromFloat(@max(0.0, @round(v)));
    }
};

/// Returns the raw CLOCK_MONOTONIC timespec.
/// Uses the VDSO-accelerated clock_gettime on supported kernels.
inline fn monotonicTs() std.os.linux.timespec {
    var ts: std.os.linux.timespec = undefined;
    _ = std.os.linux.clock_gettime(.MONOTONIC, &ts);
    return ts;
}

/// Returns the current monotonic clock time in milliseconds.
pub fn monotonicMs() i64 {
    const ts = monotonicTs();
    return ts.sec * 1000 + @divTrunc(ts.nsec, 1_000_000);
}

/// Returns the current monotonic clock time in nanoseconds.
pub fn monotonicNs() u64 {
    const ts = monotonicTs();
    return @as(u64, @intCast(ts.sec)) * 1_000_000_000 + @as(u64, @intCast(ts.nsec));
}

// XCB grab helpers

/// Moves `win` to the offscreen holding area (outside visible display bounds).
/// Uses only XCB_CONFIG_WINDOW_X.
pub inline fn pushWindowOffscreen(conn: *xcb.xcb_connection_t, win: u32) void {
    _ = xcb.xcb_configure_window(conn, win, xcb.XCB_CONFIG_WINDOW_X, &[_]u32{@bitCast(@as(i32, constants.OFFSCREEN_X_POSITION))});
}

/// Ungrabs the X server and flushes pending requests.
/// Always called as a pair; defined here so every module can share one copy.
pub inline fn ungrabAndFlush(conn: *xcb.xcb_connection_t) void {
    _ = xcb.xcb_ungrab_server(conn);
    _ = xcb.xcb_flush(conn);
}

/// Creates a pipe with O_NONBLOCK | O_CLOEXEC on both ends via pipe2(2).
///
/// Shared by input.zig (double-fork spawn plumbing) and events.zig (signal
/// self-pipe), avoiding byte-equivalent copies of this in each.
pub fn makePipe() ![2]std.posix.fd_t {
    var fds: [2]std.posix.fd_t = undefined;
    const flags = std.os.linux.O{ .CLOEXEC = true, .NONBLOCK = true };
    switch (std.posix.errno(std.os.linux.pipe2(&fds, flags))) {
        .SUCCESS => {},
        .MFILE => return error.ProcessFdQuotaExceeded,
        .NFILE => return error.SystemFdQuotaExceeded,
        else => |err| return std.posix.unexpectedErrno(err),
    }
    return fds;
}

/// Blocking mutex backed by pthread_mutex_t; `.{}` is safe (= PTHREAD_MUTEX_INITIALIZER).
///
/// Zig 0.16 removed std.Thread.Mutex/Condition (replaced by std.Io.Mutex,
/// which requires threading an std.Io handle through every lock/unlock call
/// site — too invasive for the small, self-contained locking bar.zig and
/// carousel.zig need). This is a minimal handle-free substitute, shared
/// between both instead of each defining its own copy.
pub const Mutex = struct {
    inner: std.c.pthread_mutex_t = .{},
    pub fn lock(m: *Mutex) void {
        _ = std.c.pthread_mutex_lock(&m.inner);
    }
    pub fn unlock(m: *Mutex) void {
        _ = std.c.pthread_mutex_unlock(&m.inner);
    }
};

/// Condition variable backed by pthread_cond_t; `.{}` is safe (= PTHREAD_COND_INITIALIZER).
/// Call `initMonotonic()` on any instance that will use `timedWait`.
pub const Condition = struct {
    inner: std.c.pthread_cond_t = .{},

    // pthread_condattr_t and related functions are not exposed by std.c on
    // this Zig version, so they're declared directly against libc here.
    const pthread_condattr_t = opaque {};
    extern "c" fn pthread_condattr_init(attr: *pthread_condattr_t) c_int;
    extern "c" fn pthread_condattr_setclock(attr: *pthread_condattr_t, clock_id: c_int) c_int;
    extern "c" fn pthread_condattr_destroy(attr: *pthread_condattr_t) c_int;
    extern "c" fn pthread_cond_init(cond: *std.c.pthread_cond_t, attr: *const pthread_condattr_t) c_int;

    /// Re-initialises this condition variable to use CLOCK_MONOTONIC as its
    /// clock, so that a subsequent `timedWait` can use a monotonic deadline
    /// (immune to wall-clock adjustments). Must be called once before any
    /// `timedWait` call; safe to call on a freshly zero-initialised instance,
    /// and safe to call again later (e.g. on every config reload) as long as
    /// no thread is currently blocked in `wait`/`timedWait` on it.
    pub fn initMonotonic(c: *Condition) void {
        var attr_buf: [64]u8 align(8) = @splat(0);
        const attr: *pthread_condattr_t = @ptrCast(&attr_buf);
        _ = pthread_condattr_init(attr);
        _ = pthread_condattr_setclock(attr, @intFromEnum(std.os.linux.CLOCK.MONOTONIC));
        _ = pthread_cond_init(&c.inner, attr);
        _ = pthread_condattr_destroy(attr);
    }

    pub fn wait(c: *Condition, m: *Mutex) void {
        _ = std.c.pthread_cond_wait(&c.inner, &m.inner);
    }

    /// Waits up to `timeout_ns` nanoseconds; returns error.Timeout on expiry.
    /// Uses a CLOCK_MONOTONIC absolute deadline — requires that `initMonotonic()`
    /// was called on this instance at startup.
    pub fn timedWait(c: *Condition, m: *Mutex, timeout_ns: u64) error{Timeout}!void {
        var ts: std.os.linux.timespec = undefined;
        _ = std.os.linux.clock_gettime(.MONOTONIC, &ts);
        // Saturating add prevents overflow when timeout_ns is near u64 max.
        const new_nsec = @as(u64, @intCast(ts.nsec)) +| timeout_ns;
        ts.sec += @intCast(new_nsec / std.time.ns_per_s);
        ts.nsec = @intCast(new_nsec % std.time.ns_per_s);
        const rc = std.c.pthread_cond_timedwait(&c.inner, &m.inner, @ptrCast(&ts));
        if (rc == std.posix.E.TIMEDOUT) return error.Timeout;
    }

    pub fn signal(c: *Condition) void {
        _ = std.c.pthread_cond_signal(&c.inner);
    }
    pub fn broadcast(c: *Condition) void {
        _ = std.c.pthread_cond_broadcast(&c.inner);
    }
};

// Bounded collections
//
// Four call sites across the codebase (window.zig's focus-property cache and
// child-window cache, minimize.zig's minimized-window record, input.zig's
// pending-spawn table) each independently hand-rolled the same shape: a
// fixed-capacity array plus a length, with linear-scan find, append, and
// remove-and-compact. BoundedList consolidates that into one generic type so
// a future fix to e.g. swap-remove semantics only needs to happen once.

/// Generic fixed-capacity, allocation-free collection backed by a plain
/// array. At the small counts these call sites deal with (tens to low
/// hundreds of entries), a linear scan beats a hash table: cache-local,
/// branch-predictor-friendly, and with no allocator or OOM error surface.
pub fn BoundedList(comptime T: type, comptime capacity: usize) type {
    return struct {
        items: [capacity]T = undefined,
        len: usize = 0,

        const Self = @This();

        /// Mutable view over the live portion of the backing array.
        pub fn slice(self: *Self) []T {
            return self.items[0..self.len];
        }

        /// Read-only view over the live portion of the backing array.
        pub fn constSlice(self: *const Self) []const T {
            return self.items[0..self.len];
        }

        /// Returns the index of the first item for which `match(context, item)`
        /// is true, or null if none matches. `context` is typically the search
        /// key (e.g. a window ID) and `match` a plain (non-closure) function —
        /// the same context+comptime-predicate shape `std.sort.pdq` uses.
        pub fn indexOf(self: *const Self, context: anytype, comptime match: fn (@TypeOf(context), T) bool) ?usize {
            for (self.items[0..self.len], 0..) |item, i| {
                if (match(context, item)) return i;
            }
            return null;
        }

        /// Appends `item` if there's room. Returns false and leaves the
        /// collection untouched if full — callers decide whether a full
        /// collection is worth a warning or a silent fallback.
        pub fn append(self: *Self, item: T) bool {
            if (self.len >= capacity) return false;
            self.items[self.len] = item;
            self.len += 1;
            return true;
        }

        /// O(1) removal that does *not* preserve the relative order of the
        /// remaining elements — the slot at `i` is filled with the current
        /// last element. Use when ordering carries no meaning (caches, sets).
        pub fn swapRemove(self: *Self, i: usize) void {
            self.len -= 1;
            self.items[i] = self.items[self.len];
        }

        /// O(n) removal that preserves the relative order of the remaining
        /// elements. Use when insertion order is meaningful, e.g. LIFO/FIFO
        /// replay.
        pub fn orderedRemove(self: *Self, i: usize) void {
            self.len -= 1;
            std.mem.copyForwards(T, self.items[i..self.len], self.items[i + 1 .. self.len + 1]);
        }

        /// Resets to empty without touching capacity or contents of unused slots.
        pub fn clear(self: *Self) void {
            self.len = 0;
        }
    };
}

/// Fetches an 8-bit X11 window property into a caller-supplied reuse buffer.
/// Returns a slice into `buffer.items` on success, or null if the property is absent, empty, or not 8-bit encoded.
/// The buffer is cleared before each use, so the caller can allocate it once and pass it across repeated calls.
pub fn fetchPropertyToBuffer(
    conn: *xcb.xcb_connection_t,
    window: u32,
    atom: u32,
    atom_type: u32,
    buffer: *std.ArrayListUnmanaged(u8),
    allocator: std.mem.Allocator,
) !?[]const u8 {
    const reply = xcb.xcb_get_property_reply(
        conn,
        xcb.xcb_get_property(conn, property_no_delete, window, atom, atom_type, 0, max_property_length),
        null,
    ) orelse return null;
    defer std.c.free(reply);
    const r = reply.*;
    if (r.format != 8 or r.value_len == 0) return null;

    buffer.clearRetainingCapacity();
    const value_ptr: [*]const u8 = @ptrCast(xcb.xcb_get_property_value(reply));
    try buffer.appendSlice(allocator, value_ptr[0..@intCast(r.value_len)]);
    return buffer.items;
}