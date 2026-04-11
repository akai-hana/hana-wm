//! Core window tracking
//! Tracks windows' focus eligibility through workspaces.

const std   = @import("std");
const build = @import("build_options");

const minimize = if (build.has_minimize) @import("minimize") else struct {};


// Fixed-size ordered window list.
// Used by Workspace in workspaces.zig; kept here so it can be imported from
// the always-present tracking module rather than the optional workspaces module.

pub const Tracking = struct {
    /// Maximum windows tracked per workspace.
    ///
    /// This is a hard compile-time cap, not a tuneable.  Power users with many
    /// terminal instances or IDE popups can hit it; windows beyond the cap are
    /// silently dropped from tiling and workspace membership with an error log.
    ///
    /// If 64 is regularly too small for your workflow, increase this value and
    /// rebuild.  The struct is stack-allocated, so the cost is 4 × capacity bytes
    /// per Workspace instance — 256 bytes at capacity = 64, 512 bytes at 128.
    const capacity = 64;

    buf: [capacity]u32 = undefined,

    /// Number of live entries in buf[0..len].  Never exceeds `capacity`.
    /// The type u8 is wider than strictly necessary for a maximum of 64;
    /// the invariant is enforced by prepareAdd rather than the type alone.
    len: u8 = 0,

    /// Returns true if `win` is present in the list.
    pub fn contains(self: *const Tracking, win: u32) bool {
        return std.mem.indexOfScalar(u32, self.buf[0..self.len], win) != null;
    }

    /// Returns true if `win` may be safely appended or prepended.
    ///
    /// When the list is already at capacity, logs an error and returns false.
    /// The window is NOT tracked — it becomes invisible to tiling, workspace
    /// membership queries, and focus history with no further diagnostic output.
    ///
    /// NOTE: reaching capacity is a runtime condition that can happen in
    /// production (many terminal windows, browser instances, etc.).  It is
    /// handled with a log message and graceful degradation rather than an
    /// assertion, so ReleaseFast builds remain safe.
    fn prepareAdd(self: *Tracking, win: u32) bool {
        if (self.contains(win)) return false;
        if (self.len >= capacity) {
            std.log.err(
                "tracking: workspace capacity ({d}) reached; window 0x{x} will not be tracked",
                .{ capacity, win },
            );
            return false;
        }
        return true;
    }

    /// Append `win` to the back of the list.
    /// No-op if `win` is already present or the list is at capacity (see prepareAdd).
    pub fn add(self: *Tracking, win: u32) void {
        if (!self.prepareAdd(win)) return;
        self.buf[self.len] = win;
        self.len += 1;
    }

    /// Prepend `win` to the front of the list, shifting all existing entries right.
    /// No-op if `win` is already present or the list is at capacity (see prepareAdd).
    pub fn addFront(self: *Tracking, win: u32) void {
        if (!self.prepareAdd(win)) return;
        std.mem.copyBackwards(u32, self.buf[1 .. self.len + 1], self.buf[0..self.len]);
        self.buf[0] = win;
        self.len += 1;
    }

    /// Remove `win`, preserving the relative order of all other entries.
    ///
    /// Use this variant when window order is semantically meaningful — e.g.
    /// tiling layouts that derive master/slave assignment from positional index.
    /// O(n) due to the left-shift of the tail.
    ///
    /// Returns true if `win` was found and removed, false if it was not present.
    pub fn remove(self: *Tracking, win: u32) bool {
        const i = std.mem.indexOfScalar(u32, self.buf[0..self.len], win) orelse return false;
        std.mem.copyForwards(u32, self.buf[i .. self.len - 1], self.buf[i + 1 .. self.len]);
        self.len -= 1;
        return true;
    }

    /// Remove `win` by swapping it with the last entry.
    ///
    /// Use this variant only when window order is irrelevant — e.g. tag cleanup
    /// where the workspace is being emptied, or when the tiling layout will be
    /// fully recomputed immediately after.  Calling this when order matters will
    /// silently corrupt positional semantics.
    /// O(1) after the initial scan.
    ///
    /// Returns true if `win` was found and removed, false if it was not present.
    pub fn removeUnordered(self: *Tracking, win: u32) bool {
        const i = std.mem.indexOfScalar(u32, self.buf[0..self.len], win) orelse return false;
        self.buf[i] = self.buf[self.len - 1];
        self.len   -= 1;
        return true;
    }

    /// Replace the current window order with `new_order`.
    ///
    /// Asserts (in debug/releaseSafe builds) that `new_order` contains exactly
    /// the same set of windows as the current list — no additions, no removals,
    /// no duplicates.
    ///
    /// Validation is O(n²) in debug/releaseSafe builds: each entry in new_order
    /// requires an O(n) linear scan (indexOfScalar) to locate its slot in
    /// self.buf, and the resulting slot index is marked in a stack-allocated
    /// bitset to detect duplicates.  For capacity = 64 this is at most 4,096
    /// operations — acceptable for debug-only code.  The bitset operations
    /// themselves are O(1) per entry; the dominant cost is the linear scan.
    pub fn reorder(self: *Tracking, new_order: []const u32) void {
        std.debug.assert(new_order.len == self.len);

        var seen = std.StaticBitSet(capacity).initEmpty();
        for (new_order) |w| {
            const slot = std.mem.indexOfScalar(u32, self.buf[0..self.len], w);
            // Every entry in new_order must exist in the current list.
            std.debug.assert(slot != null);
            const idx = slot.?;
            // No duplicates in new_order.
            std.debug.assert(!seen.isSet(idx));
            seen.set(idx);
        }
        @memcpy(self.buf[0..self.len], new_order);
    }

    /// Returns a slice of the live entries in insertion order.
    pub fn items(self: *const Tracking) []const u32 {
        return self.buf[0..self.len];
    }
};

// Global tracking state

var g_map:             ?std.AutoHashMap(u32, u64) = null;
var g_current:         u8                         = 0;
var g_workspace_count: usize                      = 1;

/// Initialises the global window-tracking map. Must be called once at startup before any windows are managed.
pub fn init(allocator: std.mem.Allocator) void {
    var map = std.AutoHashMap(u32, u64).init(allocator);
    // Pre-allocate to avoid early growth under normal workloads.  Failure is
    // non-fatal: the map still works correctly, just with more incremental
    // allocations as windows are added.
    map.ensureTotalCapacity(32) catch |err| {
        std.log.warn("tracking: initial map pre-allocation failed ({s}); map will grow on demand", .{@errorName(err)});
    };
    g_map = map;
}

/// Frees the global window-tracking map and resets all state.
pub fn deinit() void {
    if (g_map) |*m| m.deinit();
    g_map             = null;
    g_current         = 0;
    g_workspace_count = 1;
}

/// Called by workspaces.init — tells tracking how many workspaces exist.
pub fn setWorkspaceCount(count: usize) void { g_workspace_count = count; }

/// Called by workspaces.switchTo so getCurrentWorkspace() stays correct
/// even when code queries tracking directly.
///
/// Asserts that `ws` is within the valid range [0, g_workspace_count).
/// An out-of-range value (e.g. from a config reload that reduces the workspace
/// count) would cause isOnCurrentWorkspace to return false for all windows,
/// making every window appear off-workspace and silently breaking focus.
pub fn setCurrentWorkspace(ws: u8) void {
    std.debug.assert(ws < g_workspace_count);
    g_current = ws;
}

// Window registration

/// Register `win` on workspace `ws`. No-op if already tracked.
/// Called directly when workspaces.zig is absent; workspaces.moveWindowTo
/// handles the full registration path (screen effects etc.) when present.
pub fn registerWindow(win: u32, ws: u8) !void {
    const map = &(g_map orelse return);
    const gop = try map.getOrPut(win);
    if (!gop.found_existing) {
        gop.value_ptr.* = @as(u64, 1) << @intCast(ws);
    }
}

/// Remove `win` from the tracking map.
/// When workspaces.zig is present it calls this after cleaning up workspace
/// Tracking arrays; when absent, window.zig calls this directly.
pub fn removeWindow(win: u32) void {
    if (g_map) |*m| _ = m.remove(win);
}

/// Update the workspace bitmask for `win`.
///
/// Called by workspaces.zig for tag and move operations; keeps the hashmap in
/// sync with workspace arrays.
///
/// Logs an error and returns (rather than asserting) if `win` is not in the map,
/// because this is a runtime condition that can occur in production (e.g. a
/// race between removeWindow and a delayed mask update), not a programmer
/// invariant that can be checked at compile time.
pub fn setWindowMask(win: u32, mask: u64) void {
    std.debug.assert(mask != 0);
    const m = &(g_map orelse return);
    const p = m.getPtr(win) orelse {
        std.log.err(
            "tracking: setWindowMask called on unregistered window 0x{x}; registerWindow must precede any mask update",
            .{win},
        );
        return;
    };
    p.* = mask;
}

// Query predicates

/// Returns the workspace bitmask for `win`, or null if not tracked.
///
/// Uses a pointer capture (`|*m|`) to avoid copying the AutoHashMap header
/// on every call, which would be unnecessary given that .get() only reads.
pub inline fn getWindowWorkspaceMask(win: u32) ?u64 {
    if (g_map) |*m| return m.get(win);
    return null;
}

pub fn isManaged(win: u32) bool {
    return getWindowWorkspaceMask(win) != null;
}

pub inline fn windowCount() usize {
    return if (g_map) |m| m.count() else 0;
}

pub inline fn getCurrentWorkspace() ?u8 {
    return if (g_map != null) g_current else null;
}

pub inline fn getWorkspaceCount() usize {
    return g_workspace_count;
}

// Workspace bitmask helpers

/// Returns a u64 bitmask with only the bit for `ws_idx` set.
/// `ws_idx` may be any integer type; the cast is checked in debug builds.
pub inline fn workspaceBit(ws_idx: anytype) u64 {
    return @as(u64, 1) << @intCast(ws_idx);
}

/// Returns a bitmask with bits set for every workspace in [0, count).
/// Returns all-ones for count ≥ 64 (saturating at the u64 width).
pub inline fn allWorkspacesMask(count: usize) u64 {
    if (count >= 64) return ~@as(u64, 0);
    return (@as(u64, 1) << @intCast(count)) - 1;
}

// Comptime workspace label table

/// Comptime-generated number strings "1".."20" for workspace display labels.
/// Never heap-allocated; slices remain valid for the lifetime of the program.
pub const WORKSPACE_LABELS: [20][]const u8 = blk: {
    var labels: [20][]const u8 = undefined;
    for (&labels, 1..) |*label, i| label.* = std.fmt.comptimePrint("{d}", .{i});
    break :blk labels;
};

/// Returns the lowest-indexed workspace this window belongs to, or null if
/// the window is not tracked.
///
/// For windows on exactly one workspace (the common case) this is the
/// definitive workspace index.  For tag-based multi-workspace windows the
/// bitmask may have several bits set; this function returns the lowest set bit,
/// which is not necessarily the *current* workspace.  Callers that need
/// "is this window on the current workspace?" should use
/// isOnCurrentWorkspace(win) instead.
pub inline fn getWorkspaceForWindow(win: u32) ?u8 {
    const mask = getWindowWorkspaceMask(win) orelse return null;
    return @intCast(@ctz(mask));
}

/// Returns a key iterator over every tracked window ID, or null if uninitialised.
/// The map must not be modified while the iterator is live.
pub fn allWindowsIterator() ?std.AutoHashMap(u32, u64).KeyIterator {
    if (g_map) |*m| return m.keyIterator();
    return null;
}

pub inline fn isWindowOnWorkspace(win: u32, ws_idx: u8) bool {
    const mask = getWindowWorkspaceMask(win) orelse return false;
    return (mask >> @intCast(ws_idx)) & 1 != 0;
}

pub inline fn isOnCurrentWorkspace(win: u32) bool {
    return isWindowOnWorkspace(win, g_current);
}

/// Combined predicate for focus recovery: on current workspace and not minimized.
/// Declared as a plain fn (not inline) so it can be passed as a *const fn(u32)bool.
pub fn isOnCurrentWorkspaceAndVisible(win: u32) bool {
    if (!isOnCurrentWorkspace(win)) return false;
    return if (comptime build.has_minimize) !minimize.isMinimized(win) else true;
}

/// Returns the first non-minimized window in `windows`, or null if all are minimized.
///
/// This function lives in tracking.zig rather than minimize.zig because
/// tracking.zig is always compiled in, making it safely importable by modules
/// such as focus.zig that need to store a *const fn pointer without a comptime
/// gate at every storage site.  minimize.zig is optional and cannot be
/// unconditionally imported.
///
/// Declared as a plain fn so minimize.zig can store it as a function pointer.
pub fn firstNonMinimized(windows: []const u32) ?u32 {
    for (windows) |win| {
        const is_min = if (comptime build.has_minimize) minimize.isMinimized(win) else false;
        if (!is_min) return win;
    }
    return null;
}
