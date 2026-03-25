//! Core window tracking — always present, no optionality.
//!
//! Owns the window→workspace bitmask map and the current-workspace cursor.
//! Every other module queries window membership and focus eligibility through
//! this module, which means those predicates work correctly even when the full
//! workspace-switching subsystem (workspaces.zig) is not compiled in.
//!
//! workspaces.zig calls setCurrentWorkspace() and setWorkspaceCount() on every
//! switch and init respectively, keeping the state here in sync with the
//! multi-workspace feature when it is present.  When workspaces.zig is absent
//! the WM operates as a single-workspace session: all windows land on
//! workspace 0 and getCurrentWorkspace() always returns 0.

const std           = @import("std");
const build_options = @import("build_options");
const minimize      = if (build_options.has_minimize) @import("minimize") else struct {};

// Fixed-size ordered window list.
// Used by Workspace in workspaces.zig; kept here so it can be imported from
// the always-present tracking module rather than the optional workspaces module.

pub const Tracking = struct {
    const capacity = 64;

    buf: [capacity]u32 = undefined,

    /// Number of live entries in buf[0..len].  Never exceeds `capacity`.
    /// The type u8 is wider than strictly necessary for a maximum of 64;
    /// the invariant is enforced by prepareAdd rather than the type alone.
    len: u8 = 0,

    pub fn contains(self: *const Tracking, win: u32) bool {
        return std.mem.indexOfScalar(u32, self.buf[0..self.len], win) != null;
    }

    /// Returns true if `win` may be safely appended or prepended.
    /// Emits a warning and triggers a debug assertion if the list is already
    /// at capacity, making overflow visible rather than silently dropping the
    /// window (which would cause it to become invisible to tiling, workspace
    /// membership queries, and focus history with no diagnostic output).
    fn prepareAdd(self: *Tracking, win: u32) bool {
        if (self.contains(win)) return false;
        if (self.len >= capacity) {
            std.log.warn(
                "tracking: workspace capacity ({d}) reached; window 0x{x} will not be tracked",
                .{ capacity, win },
            );
            std.debug.assert(false); // catch in debug/releaseSafe builds
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
    /// Validation is O(n) via a stack-allocated bitset: one pass builds a
    /// presence bitmap over current buf indices, then verifies that new_order
    /// hits every slot exactly once.
    pub fn reorder(self: *Tracking, new_order: []const u32) void {
        std.debug.assert(new_order.len == self.len);

        // Build a presence bitmap over the *current* buf indices in one O(n)
        // pass, then verify new_order hits every slot exactly once.
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
        // Every current window must appear in new_order.
        std.debug.assert(seen.count() == self.len);

        @memcpy(self.buf[0..self.len], new_order);
    }

    pub fn items(self: *const Tracking) []const u32 {
        return self.buf[0..self.len];
    }
};

// Global tracking state

var g_map:             ?std.AutoHashMap(u32, u64) = null;
var g_current:         u8                         = 0;
var g_workspace_count: usize                      = 1;

pub fn init(allocator: std.mem.Allocator) void {
    var map = std.AutoHashMap(u32, u64).init(allocator);
    map.ensureTotalCapacity(32) catch {};
    g_map = map;
}

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
pub fn setCurrentWorkspace(ws: u8) void { g_current = ws; }

// Window registration

/// Register `win` on workspace `ws`. No-op if already tracked.
/// Called directly when workspaces.zig is absent; workspaces.moveWindowTo
/// handles the full registration path (screen effects etc.) when present.
pub fn registerWindow(win: u32, ws: u8) !void {
    var map = &(g_map orelse return);
    if (map.contains(win)) return;
    try map.ensureUnusedCapacity(1);
    map.putAssumeCapacity(win, @as(u64, 1) << @intCast(ws));
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
/// Panics in debug/releaseSafe builds if `win` is not already in the map —
/// registerWindow must be called before any mask update.
pub fn setWindowMask(win: u32, mask: u64) void {
    std.debug.assert(mask != 0);
    if (g_map) |*m| {
        if (m.getPtr(win)) |p| {
            p.* = mask;
        } else {
            // setWindowMask called on an unregistered (or already-removed) window.
            // This is always a caller bug: registerWindow must precede any mask update.
            std.debug.assert(false);
        }
    }
}

// Query predicates

pub inline fn getWindowWorkspaceMask(win: u32) ?u64 {
    const m = g_map orelse return null;
    return m.get(win);
}

pub fn isManaged(win: u32) bool {
    return getWindowWorkspaceMask(win) != null;
}

pub inline fn windowCount() usize {
    return if (g_map) |m| m.count() else 0;
}

pub inline fn getCurrentWorkspace() ?u8 {
    if (g_map == null) return null;
    return g_current;
}

pub inline fn getWorkspaceCount() usize {
    return g_workspace_count;
}

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
    return if (comptime build_options.has_minimize) !minimize.isMinimized(win) else true;
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
        const is_min = if (comptime build_options.has_minimize) minimize.isMinimized(win) else false;
        if (!is_min) return win;
    }
    return null;
}
