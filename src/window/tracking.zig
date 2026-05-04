//! Core window tracking
//! Maintains the registry of all managed windows and their workspace assignments.

const std   = @import("std");
const build = @import("build_options");

const minimize = if (build.has_minimize) @import("minimize");


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
    /// rebuild.  The struct is stack-allocated, so the cost is 4 x capacity bytes
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

    /// Replace the current window order with `new_order`.
    ///
    /// Validates that `new_order` contains exactly the same set of windows as
    /// the current list — no additions, no removals, no duplicates.  In all
    /// build modes an error is logged and the function returns early on bad
    /// input (no corruption).  In debug/releaseSafe builds the assert also
    /// fires to surface programmer errors loudly.
    ///
    /// Validation is O(n²): each entry requires an O(n) linear scan to locate
    /// its slot, and the result is marked in a stack-allocated bitset to detect
    /// duplicates.  For capacity = 64 this is at most 4,096 operations.
    pub fn reorder(self: *Tracking, new_order: []const u32) void {
        if (new_order.len != self.len) {
            std.log.err(
                "tracking: reorder length mismatch: got {d}, expected {d}",
                .{ new_order.len, self.len },
            );
            std.debug.assert(new_order.len == self.len);
            return;
        }

        var seen = std.StaticBitSet(capacity).initEmpty();
        for (new_order) |w| {
            const idx = std.mem.indexOfScalar(u32, self.buf[0..self.len], w) orelse {
                std.log.err(
                    "tracking: reorder: window 0x{x} not in current list",
                    .{w},
                );
                std.debug.assert(false);
                return;
            };
            if (seen.isSet(idx)) {
                std.log.err(
                    "tracking: reorder: duplicate window 0x{x} in new_order",
                    .{w},
                );
                std.debug.assert(false);
                return;
            }
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

pub const Entry = struct {
    win:  u32,
    mask: u64,
};

var g_windows:         std.ArrayListUnmanaged(Entry) = .empty;
var g_alloc:           std.mem.Allocator             = undefined;
var g_initialized:     bool                          = false;
var g_current:         u8                            = 0;
var g_workspace_count: usize                         = 1;

/// Initialises the global window-tracking list. Must be called once at startup before any windows are managed.
pub fn init(allocator: std.mem.Allocator) void {
    g_alloc       = allocator;
    g_initialized = true;
    g_windows.ensureTotalCapacity(allocator, 32) catch |err| {
        std.log.warn("tracking: initial pre-allocation failed ({s}); list will grow on demand", .{@errorName(err)});
    };
}

/// Frees the global window-tracking list and resets all state.
pub fn deinit() void {
    if (g_initialized) g_windows.deinit(g_alloc);
    g_windows         = .empty;
    g_initialized     = false;
    g_current         = 0;
    g_workspace_count = 1;
}

/// Called by workspaces.init — tells tracking how many workspaces exist.
/// count must not exceed 64; the workspace bitmask (u64) cannot represent more.
pub fn setWorkspaceCount(count: usize) void {
    std.debug.assert(count <= 64);
    g_workspace_count = count;
}

/// Called by workspaces.switchTo so getCurrentWorkspace() stays correct
/// even when code queries tracking directly.
///
/// Asserts that `ws` is within the valid range [0, g_workspace_count).
/// An out-of-range value (e.g. from a config reload that reduces the workspace
/// count) would cause isOnCurrentWorkspace to return false for all windows,
/// making every window appear off-workspace and silently breaking focus.
pub fn setCurrentWorkspace(ws: u8) void {
    std.debug.assert(ws < 64);
    std.debug.assert(ws < g_workspace_count);
    g_current = ws;
}

// Window registration

/// Register `win` on workspace `ws`. No-op if already tracked.
/// Called directly when workspaces.zig is absent; workspaces.moveWindowTo
/// handles the full registration path (screen effects etc.) when present.
pub fn registerWindow(win: u32, ws: u8) !void {
    if (!g_initialized) return;
    std.debug.assert(ws < 64);
    if (isManaged(win)) return;
    try g_windows.append(g_alloc, .{ .win = win, .mask = workspaceBit(ws) });
}

/// Remove `win` from the tracking list.
/// Swap-remove: O(1) after the linear find; order doesn't matter for WM ops.
/// When workspaces.zig is present it calls this after cleaning up workspace
/// last_focused; when absent, window.zig calls this directly.
pub fn removeWindow(win: u32) void {
    if (!g_initialized) return;
    for (g_windows.items, 0..) |e, i| {
        if (e.win == win) { _ = g_windows.swapRemove(i); return; }
    }
}

/// Update the workspace bitmask for `win`.
///
/// Called by workspaces.zig for tag and move operations.
///
/// Logs an error and returns (rather than asserting) if `win` is not in the list,
/// because this is a runtime condition that can occur in production (e.g. a
/// race between removeWindow and a delayed mask update), not a programmer
/// invariant that can be checked at compile time.
pub fn setWindowMask(win: u32, mask: u64) void {
    if (!g_initialized) return;
    std.debug.assert(mask != 0);
    for (g_windows.items) |*e| {
        if (e.win == win) { e.mask = mask; return; }
    }
    std.log.err(
        "tracking: setWindowMask called on unregistered window 0x{x}",
        .{win},
    );
}

// Query predicates

/// Returns the workspace bitmask for `win`, or null if not tracked.
pub inline fn getWindowWorkspaceMask(win: u32) ?u64 {
    for (g_windows.items) |e| { if (e.win == win) return e.mask; }
    return null;
}

pub fn isManaged(win: u32) bool {
    return getWindowWorkspaceMask(win) != null;
}

pub inline fn windowCount() usize { return g_windows.items.len; }

pub inline fn getCurrentWorkspace() ?u8 {
    return if (g_initialized) g_current else null;
}

pub inline fn getWorkspaceCount() usize { return g_workspace_count; }

/// Returns a read-only slice of all tracked (win, mask) pairs.
/// Callers filter by mask bit as needed; do not retain the slice across
/// any call that may add or remove windows.
pub fn allWindows() []const Entry { return g_windows.items; }

/// True when at least one window has ws_idx set in its mask.
pub fn hasWindowsOnWorkspace(ws_idx: u8) bool {
    const bit = workspaceBit(ws_idx);
    for (g_windows.items) |e| { if (e.mask & bit != 0) return true; }
    return false;
}

/// Count of windows that have ws_idx set in their mask.
pub fn countWindowsOnWorkspace(ws_idx: u8) usize {
    const bit = workspaceBit(ws_idx);
    var n: usize = 0;
    for (g_windows.items) |e| { if (e.mask & bit != 0) n += 1; }
    return n;
}

// Workspace bitmask helpers

/// Returns a u64 bitmask with only the bit for `ws_idx` set.
/// `ws_idx` may be any integer type; must be in [0, 63].
pub inline fn workspaceBit(ws_idx: anytype) u64 {
    std.debug.assert(ws_idx < 64);
    return @as(u64, 1) << @intCast(ws_idx);
}

/// Returns a bitmask with bits set for every workspace in [0, count).
/// Returns all-ones for count ≥ 64 (saturating at the u64 width).
pub inline fn allWorkspacesMask(count: usize) u64 {
    if (count >= 64) return ~@as(u64, 0);
    return (@as(u64, 1) << @intCast(count)) - 1;
}

// Comptime workspace label table

/// Comptime-generated number strings "1".."64" for workspace display labels.
/// Sized to match the bitmask capacity so any valid workspace index can be
/// looked up without risk of out-of-bounds access.
/// Never heap-allocated; slices remain valid for the lifetime of the program.
pub const WORKSPACE_LABELS: [64][]const u8 = blk: {
    @setEvalBranchQuota(10_000);
    var labels: [64][]const u8 = undefined;
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

pub inline fn isWindowOnWorkspace(win: u32, ws_idx: u8) bool {
    const mask = getWindowWorkspaceMask(win) orelse return false;
    return mask & workspaceBit(ws_idx) != 0;
}

pub inline fn isOnCurrentWorkspace(win: u32) bool {
    return isWindowOnWorkspace(win, g_current);
}

/// Combined predicate for focus recovery: on current workspace and not minimized.
/// Declared as a plain fn (not inline) so it can be passed as a *const fn(u32)bool.
pub fn isOnCurrentWorkspaceAndVisible(win: u32) bool {
    if (!isOnCurrentWorkspace(win)) return false;
    return if (build.has_minimize) !minimize.isMinimized(win) else true;
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
    if (comptime !build.has_minimize) return if (windows.len > 0) windows[0] else null;
    for (windows) |win| {
        if (!minimize.isMinimized(win)) return win;
    }
    return null;
}
