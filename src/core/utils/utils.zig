//! Core utilities
//! Provides shared geometry helpers, process lifecycle signals, and X11 property utilities for the WM core.

const std = @import("std");

const core = @import("core");
const xcb = core.xcb;
const constants = @import("constants");
const debug = @import("debug");
const bench = @import("bench");

const max_property_length = constants.PROPERTY_MAX_LENGTH;
/// Passed as the `delete` argument to xcb_get_property; 0 means do not consume the property.
const property_no_delete = constants.PROPERTY_NO_DELETE;

// Process lifecycle signals
//
// Module-level atomics, not WM struct fields — this is process control
// state, not window-manager state. Signal handlers and keybind actions
// write here; the main event loop reads here.

/// Set to false by SIGTERM/SIGINT to break the main event loop.
pub var running = std.atomic.Value(bool).init(true);

/// Set to true by SIGHUP or the `reload_config` keybinding.
/// Consumed by `consumeReload` in the main event loop.
var should_reload = std.atomic.Value(bool).init(false);

/// Write end of the signal self-pipe (owned by events.zig), registered via
/// `setSignalWriteFd`. The `reload_config` keybinding has no signal byte, so
/// `reload()` writes a SIGHUP wake byte here to poke the event loop out of
/// poll immediately instead of waiting for an unrelated signal.
var signal_write_fd: std.posix.fd_t = -1;

/// Registers the write end of the signal self-pipe so `reload()` can wake the
/// event loop. Pass -1 to unregister (teardown).
pub fn setSignalWriteFd(fd: std.posix.fd_t) void {
    signal_write_fd = fd;
}

/// Signals the main event loop to exit cleanly.
pub inline fn quit() void {
    running.store(false, .release);
}

/// Signals the main event loop to reload the user config.
///
/// Safe from any thread: the wake byte is a plain write, not a signal. If the
/// pipe is full (or not yet registered) the write is dropped — the event loop
/// also polls the flag itself every iteration, so a lost byte only delays the
/// reload by one poll timeout at worst.
pub inline fn reload() void {
    should_reload.store(true, .release);
    if (signal_write_fd >= 0)
        _ = std.os.linux.write(signal_write_fd, &[_]u8{@intFromEnum(std.posix.SIG.HUP)}, 1);
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
};

/// Gap and border widths applied around a tiled window.
pub const Margins = struct {
    gap: u16,
    border: u16,
};

/// Twice the border width (left+right / top+bottom inset).
pub inline fn doubledBorder(m: Margins) u16 {
    return 2 *| m.border;
}

/// Reinterprets a signed X11 coordinate (i16 on the wire) as the u32 value
/// XCB's configure_window value array expects.
pub inline fn toXcbCoord(v: i16) u32 {
    return @bitCast(@as(i32, v));
}

/// Moves and resizes `win` without touching border_width.
/// Use `window.configureWindowGeom` when border_width must change atomically.
pub inline fn configureWindow(conn: *xcb.xcb_connection_t, win: u32, rect: Rect) void {
    _ = xcb.xcb_configure_window(
        conn,
        win,
        xcb.XCB_CONFIG_WINDOW_X | xcb.XCB_CONFIG_WINDOW_Y |
            xcb.XCB_CONFIG_WINDOW_WIDTH | xcb.XCB_CONFIG_WINDOW_HEIGHT,
        &[_]u32{ toXcbCoord(rect.x), toXcbCoord(rect.y), rect.width, rect.height },
    );
}

/// Raises `win` to the top of the stacking order.
pub inline fn raiseWindow(conn: *xcb.xcb_connection_t, win: u32) void {
    _ = xcb.xcb_configure_window(conn, win, xcb.XCB_CONFIG_WINDOW_STACK_MODE, &[_]u32{xcb.XCB_STACK_MODE_ABOVE});
}

/// Strips lock-key and pointer-button bits from a raw event modifier state,
/// leaving only the modifier bits the WM uses for keybinding matching.
pub inline fn normalizeModifiers(state: u16) u16 {
    return state & constants.MOD_MASK_BINDING;
}

// Atom cache
//
// Field names match X11 atom strings exactly, so getAtomCached resolves
// them with a single @field call — no switch, no enum, no second place to
// add entries when a new atom is needed.
const AtomCache = struct {
    WM_PROTOCOLS: u32,
    WM_DELETE_WINDOW: u32,
    WM_TAKE_FOCUS: u32,
    _NET_WM_NAME: u32,
    UTF8_STRING: u32,
    WM_CLASS: u32,
    // Root window EWMH-conformance atoms — see advertiseEwmhSupport() below.
    _NET_SUPPORTED: u32,
    _NET_SUPPORTING_WM_CHECK: u32,
    // Bar window property atoms, batched here so setWindowProperties pays
    // zero X round-trips instead of 10 serial ones.
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
    // Root-window focus advertisement — read by focus.zig's setFocus path.
    _NET_ACTIVE_WINDOW: u32,
    // Legacy X resource-database atom — read by scale.zig for Xft.dpi.
    RESOURCE_MANAGER: u32,
};

var atom_cache: ?AtomCache = null;

/// Interns all atoms in a single round-trip batch. Atom names come from
/// `AtomCache`'s field names at comptime, so adding a field is the only
/// change required — no parallel array, no index-order mismatch risk.
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

// EWMH root window advertisement

/// EWMH atoms hana declares support for via `_NET_SUPPORTED`. Every entry
/// here must correspond to a protocol hana genuinely honours — clients use
/// this list to decide what they can rely on.
///
/// Notably fixes GLFW's "Iconification of full screen windows requires a WM
/// that supports EWMH full screen" error (seen in Minecraft and other
/// LWJGL/GLFW games): GLFW only fullscreens via `_NET_WM_STATE_FULLSCREEN`
/// if that atom is listed here. Without it, GLFW falls back to a raw
/// override-redirect window, which bypasses the WM — and override-redirect
/// windows can't be iconified through the WM, so the next XIconifyWindow()
/// call throws that error instead of doing anything.
const supported_atoms = [_][]const u8{
    "_NET_SUPPORTED",
    "_NET_SUPPORTING_WM_CHECK",
    "_NET_WM_NAME",
    "_NET_WM_STATE",
    "_NET_WM_STATE_FULLSCREEN",
    "_NET_WM_STATE_ABOVE",
    "_NET_WM_STATE_STICKY",
    "_NET_WM_ALLOWED_ACTIONS",
    "_NET_WM_ACTION_CLOSE",
    "_NET_WM_ACTION_ABOVE",
    "_NET_WM_ACTION_STICK",
    "_NET_WM_PID",
    "_NET_WM_WINDOW_TYPE",
    "_NET_WM_WINDOW_TYPE_DOCK",
    "_NET_WM_STRUT_PARTIAL",
};

/// Publishes hana's EWMH conformance on the root window.
///
/// Per the EWMH spec, a conformant WM creates a small identity ("check")
/// window, tags it and the root with `_NET_SUPPORTING_WM_CHECK` pointing at
/// it, gives it a `_NET_WM_NAME`, and lists every hint it honours in
/// `_NET_SUPPORTED` on the root. Clients (GLFW, Qt, Chromium, ...) probe
/// this once at startup; without it they assume a bare ICCCM-only WM and
/// take more conservative — in GLFW's case, broken — code paths (see
/// `supported_atoms` above).
///
/// Must run once at startup, after initAtomCache() and before any client
/// can map a window.
pub fn advertiseEwmhSupport(conn: *xcb.xcb_connection_t, screen: *xcb.xcb_screen_t, root: u32) void {
    const supporting_wm_check = getAtomCached("_NET_SUPPORTING_WM_CHECK") catch return;
    const net_wm_name = getAtomCached("_NET_WM_NAME") catch return;
    const utf8_string = getAtomCached("UTF8_STRING") catch return;
    const net_supported = getAtomCached("_NET_SUPPORTED") catch return;

    // A small, invisible identity window. Override-redirect so hana's own
    // SubstructureRedirect handling never tries to manage it as a client.
    const check_win = xcb.xcb_generate_id(conn);
    const depth: u8 = xcb.XCB_COPY_FROM_PARENT;
    const value_mask = xcb.XCB_CW_OVERRIDE_REDIRECT;
    const value_list = [_]u32{1};
    _ = xcb.xcb_create_window(
        conn,
        depth,
        check_win,
        root,
        -1,
        -1,
        1,
        1,
        0,
        xcb.XCB_WINDOW_CLASS_INPUT_OUTPUT,
        screen.root_visual,
        @intCast(value_mask),
        &value_list,
    );

    // Identity dance required by the spec: the check window points at
    // itself, and the root points at the check window. Clients compare the
    // two `_NET_SUPPORTING_WM_CHECK` values to tell a live WM from a stale
    // property a crashed WM left behind.
    _ = xcb.xcb_change_property(conn, xcb.XCB_PROP_MODE_REPLACE, check_win, supporting_wm_check, xcb.XCB_ATOM_WINDOW, 32, 1, &check_win);
    _ = xcb.xcb_change_property(conn, xcb.XCB_PROP_MODE_REPLACE, root, supporting_wm_check, xcb.XCB_ATOM_WINDOW, 32, 1, &check_win);

    const wm_name = "hana";
    _ = xcb.xcb_change_property(conn, xcb.XCB_PROP_MODE_REPLACE, check_win, net_wm_name, utf8_string, 8, @intCast(wm_name.len), wm_name.ptr);

    var supported: [supported_atoms.len]xcb.xcb_atom_t = undefined;
    inline for (supported_atoms, 0..) |name, i|
        supported[i] = getAtomCached(name) catch xcb.XCB_ATOM_NONE;
    _ = xcb.xcb_change_property(conn, xcb.XCB_PROP_MODE_REPLACE, root, net_supported, xcb.XCB_ATOM_ATOM, 32, @intCast(supported.len), &supported);
}

// Property helpers

/// Canonical scaling formulas — pure functions of a ScalableValue, no DPI
/// lookup. scale.zig and config.zig both call into these, so there is exactly
/// one formula to maintain.
pub const scaling = struct {
    /// Resolves a ScalableValue to a ratio: `v%` becomes v/100, an absolute
    /// value stays as-is.
    pub inline fn asRatio(value: anytype) f32 {
        return if (value.is_percentage) value.value / 100.0 else value.value;
    }
    /// Resolves a ScalableValue against a reference dimension: `v%` becomes
    /// reference * v/100, an absolute value stays as-is (reference unused).
    pub inline fn scaleToPixels(value: anytype, reference: f32) f32 {
        return if (value.is_percentage) reference * (value.value / 100.0) else value.value;
    }
    pub fn scaleMasterWidth(value: anytype) f32 {
        return if (value.is_percentage) value.value / 100.0 else -value.value;
    }
    pub fn scaleBorderWidth(value: anytype, reference_dimension: u16) u16 {
        const v: f32 = if (value.is_percentage)
            (value.value / 100.0) * 0.5 * @as(f32, @floatFromInt(reference_dimension))
        else
            value.value;
        const clamped = std.math.clamp(@round(v), 0.0, @as(f32, std.math.maxInt(u16)));
        return @intFromFloat(clamped);
    }
};

/// Returns the raw timespec for the given clock id (REALTIME/MONOTONIC).
/// Uses the VDSO-accelerated clock_gettime on supported kernels.
inline fn clockTs(clock_id: std.os.linux.clockid_t) std.os.linux.timespec {
    var ts: std.os.linux.timespec = undefined;
    _ = std.os.linux.clock_gettime(clock_id, &ts);
    return ts;
}

/// Returns the current monotonic clock time in nanoseconds.
pub fn monotonicNs() u64 {
    const ts = clockTs(.MONOTONIC);
    return @as(u64, @intCast(ts.sec)) * 1_000_000_000 + @as(u64, @intCast(ts.nsec));
}

// XCB grab helpers

/// Moves `win` to the offscreen holding area (outside visible display bounds).
/// Uses only XCB_CONFIG_WINDOW_X.
pub inline fn pushWindowOffscreen(conn: *xcb.xcb_connection_t, win: u32) void {
    _ = xcb.xcb_configure_window(conn, win, xcb.XCB_CONFIG_WINDOW_X, &[_]u32{@bitCast(@as(i32, constants.OFFSCREEN_X_POSITION))});
}

/// Like `pushWindowOffscreen`, but also drops `win` to the bottom of the
/// global stacking order in the same request. Nothing in this codebase ever
/// lowers a window otherwise (only XCB_STACK_MODE_ABOVE is used, by raises),
/// so a window that got raised once — e.g. by a layout that isn't supposed
/// to raise during a background retile — would otherwise stay first in
/// stacking order forever, regardless of how far offscreen its X coordinate
/// is parked. Use this instead of `pushWindowOffscreen` for any window whose
/// hidden state must be defended even if something upstream raised it.
pub inline fn pushWindowOffscreenAndLower(conn: *xcb.xcb_connection_t, win: u32) void {
    _ = xcb.xcb_configure_window(
        conn,
        win,
        xcb.XCB_CONFIG_WINDOW_X | xcb.XCB_CONFIG_WINDOW_STACK_MODE,
        &[_]u32{
            @bitCast(@as(i32, constants.OFFSCREEN_X_POSITION)),
            xcb.XCB_STACK_MODE_BELOW,
        },
    );
}

// X server grab state
//
// The grab body runs on the main WM thread, but the shared xcb output buffer
// is flushed by ANY thread (the dedicated carousel/bar thread calls xcb_flush
// up to ~refresh-rate times per second). A carousel flush while the main
// thread holds xcb_grab_server would release the queued grab-batch requests to
// the server before xcb_ungrab_server, letting the compositor present an
// intermediate frame — exactly what the grab is meant to prevent.
//
// grab_active lets the bar thread detect that window and skip its flush.

/// True while the main WM thread holds the X server grab.
pub var grab_active = std.atomic.Value(bool).init(false);

/// Returns true while the main WM thread holds the X server grab.
pub inline fn isGrabActive() bool {
    return grab_active.load(.monotonic);
}

/// Takes the X server grab. Always pair with ungrabServer()/ungrabAndFlush().
pub inline fn grabServer(conn: *xcb.xcb_connection_t) void {
    grab_active.store(true, .release);
    _ = xcb.xcb_grab_server(conn);
}

/// Releases the X server grab without flushing pending requests.
pub inline fn ungrabServer(conn: *xcb.xcb_connection_t) void {
    _ = xcb.xcb_ungrab_server(conn);
    grab_active.store(false, .release);
}

/// Ungrabs the X server and flushes pending requests.
/// Always called as a pair; defined here so every module can share one copy.
pub inline fn ungrabAndFlush(conn: *xcb.xcb_connection_t) void {
    ungrabServer(conn);
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

    // pthread_condattr_t is not exposed by std.c on this Zig version, so it's
    // pulled in from the system header directly. Using the real type (rather
    // than a hand-sized opaque buffer) keeps the stack allocation exactly as
    // large as libc's definition — no silent corruption if a libc ever
    // grows the type.
    const pthread = @cImport(@cInclude("pthread.h"));

    /// Re-initialises this condition variable to use CLOCK_MONOTONIC as its
    /// clock, so that a subsequent `timedWait` can use a monotonic deadline
    /// (immune to wall-clock adjustments). Must be called once before any
    /// `timedWait` call; safe to call on a freshly zero-initialised instance,
    /// and safe to call again later (e.g. on every config reload) as long as
    /// no thread is currently blocked in `wait`/`timedWait` on it.
    pub fn initMonotonic(cv: *Condition) void {
        var attr: pthread.pthread_condattr_t = undefined;
        if (pthread.pthread_condattr_init(&attr) != 0) return;
        defer _ = pthread.pthread_condattr_destroy(&attr);
        _ = pthread.pthread_condattr_setclock(&attr, @intFromEnum(std.os.linux.CLOCK.MONOTONIC));
        _ = pthread.pthread_cond_init(@ptrCast(&cv.inner), &attr);
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
};

// Bounded collections
//
// Shared shape used by window.zig's caches, minimize.zig's minimized-window
// record, and input.zig's pending-spawn table: a fixed-capacity array plus
// a length, with linear-scan find, append, and remove-and-compact.

/// Generic fixed-capacity, allocation-free collection backed by a plain
/// array. Linear scan is the right tool at the counts these call sites deal
/// with (tens to low hundreds of entries): cache-local, branch-predictor-
/// friendly, no allocator, no OOM error surface.
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
/// Returns a slice into `buffer.items`, or null if the property is absent,
/// empty, or not 8-bit encoded, or the reply's type doesn't match the
/// requested `atom_type`. The buffer is cleared before each use, so the
/// caller can allocate it once and pass it across repeated calls.
pub fn fetchPropertyToBuffer(
    conn: *xcb.xcb_connection_t,
    window: u32,
    atom: u32,
    atom_type: u32,
    buffer: *std.ArrayListUnmanaged(u8),
    allocator: std.mem.Allocator,
) !?[]const u8 {
    const reply = pollPropertyReply(
        conn,
        xcb.xcb_get_property(conn, property_no_delete, window, atom, atom_type, 0, max_property_length),
    ) orelse return null;
    defer std.c.free(reply);
    const r = reply.*;
    if (r.format != 8 or r.value_len == 0 or r.type != atom_type) return null;
    if (r.value_len == max_property_length)
        debug.warn("Property atom {x} on window {x} exceeds the {}-byte fetch cap; value truncated", .{ atom, window, max_property_length });

    buffer.clearRetainingCapacity();
    const value_ptr: [*]const u8 = @ptrCast(xcb.xcb_get_property_value(reply));
    try buffer.appendSlice(allocator, value_ptr[0..@intCast(r.value_len)]);
    return buffer.items;
}

/// Collect the reply for a fired `xcb_get_property` request without a blocking
/// wait when the reply is already buffered (see `bench.pollReply`). In a
/// non-bench build this reduces to a single blocking reply call.
fn pollPropertyReply(
    conn: *xcb.xcb_connection_t,
    cookie: xcb.xcb_get_property_cookie_t,
) ?*xcb.xcb_get_property_reply_t {
    if (bench.pollReply(conn, cookie.sequence)) |rep|
        return @ptrCast(@alignCast(rep));
    return xcb.xcb_get_property_reply(conn, cookie, null);
}
