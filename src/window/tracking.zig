//! Core window tracking
//! Maintains the registry of all managed windows and their workspace assignments.

const std = @import("std");

const constants = @import("constants");
const minimize = @import("minimize");

// Fixed-size ordered window list.
// Embedded once as tiling.State.windows (a single global instance, not one
// per workspace); kept here so tiling.zig can import it from the always-present
// tracking module.

pub const Tracking = struct {
    /// Hard compile-time cap on windows tracked across the whole WM (all
    /// workspaces combined) — `tiling.State.windows`, a single global
    /// instance, not one per workspace. Not a tuneable: windows beyond the cap
    /// are silently dropped from tiling and workspace membership (error log).
    /// Raise constants.Limits.MAX_TILED_WINDOWS and rebuild if too small; the
    /// struct is stack-allocated, 4 bytes per slot.
    const capacity = constants.Limits.MAX_TILED_WINDOWS;

    // `len` is a u8, so capacity may not exceed 255. Enforced at compile time
    // so raising MAX_TILED_WINDOWS past 255 fails the build instead of
    // overflowing `len` at runtime; widen `len` alongside the cap.
    comptime {
        std.debug.assert(capacity <= std.math.maxInt(u8));
    }

    buf: [capacity]u32 = undefined,

    /// Number of live entries in buf[0..len].  Never exceeds `capacity`.
    len: u8 = 0,

    /// Returns true if `win` is present in the list.
    pub fn contains(self: *const Tracking, win: u32) bool {
        return std.mem.indexOfScalar(u32, self.buf[0..self.len], win) != null;
    }

    /// Returns true if `win` may be safely appended or prepended. Logs an
    /// error and returns false when the list is at capacity; the window is
    /// NOT tracked (invisible to tiling, membership queries, focus history).
    ///
    /// NOTE: capacity is reachable in production (many terminals, browsers);
    /// handled by log + graceful degradation so ReleaseFast stays safe.
    fn prepareAdd(self: *Tracking, win: u32) bool {
        if (self.contains(win)) return false;
        if (self.len >= capacity) {
            std.log.err(
                "tracking: window list capacity ({d}) reached; window 0x{x} will not be tracked",
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

    /// Returns a slice of the live entries in insertion order.
    pub fn items(self: *const Tracking) []const u32 {
        return self.buf[0..self.len];
    }
};

// Global tracking state

pub const Entry = struct {
    win: u32,
    mask: u64,
};

var g_windows: std.ArrayListUnmanaged(Entry) = .empty;
/// win -> index into g_windows.items, giving the ID-lookup functions below
/// (getWindowWorkspaceMask, isManaged, setWindowMask, removeWindow) O(1)
/// average instead of an O(n) scan. Unlike the bounded per-workspace tiling
/// list (Tracking above), g_windows is genuinely unbounded — it holds every
/// managed window, tiled and floating — so its scan cost grows with real
/// usage. Same window-ID index pattern as layouts.CacheMap.
var g_index: std.AutoHashMapUnmanaged(u32, usize) = .empty;
var g_alloc: std.mem.Allocator = undefined;
var g_initialized: bool = false;
var g_current: u8 = 0;
var g_workspace_count: usize = 1;

/// Initialises the global window-tracking list. Must be called once at startup before any windows are managed.
pub fn init(allocator: std.mem.Allocator) void {
    g_alloc = allocator;
    g_initialized = true;
    g_windows.ensureTotalCapacity(allocator, 32) catch |err| {
        std.log.warn("tracking: initial pre-allocation failed ({s}); list will grow on demand", .{@errorName(err)});
    };
    g_index.ensureTotalCapacity(allocator, 32) catch |err| {
        std.log.warn("tracking: initial index pre-allocation failed ({s}); map will grow on demand", .{@errorName(err)});
    };
}

/// Frees the global window-tracking list and resets all state.
pub fn deinit() void {
    if (g_initialized) {
        g_windows.deinit(g_alloc);
        g_index.deinit(g_alloc);
    }
    g_windows = .empty;
    g_index = .empty;
    g_initialized = false;
    g_current = 0;
    g_workspace_count = 1;
}

/// Called by workspaces.init — tells tracking how many workspaces exist.
/// count must not exceed 64; the workspace bitmask (u64) cannot represent more.
pub fn setWorkspaceCount(count: usize) void {
    std.debug.assert(count <= 64);
    g_workspace_count = count;
}

/// Called by workspaces.switchTo so getCurrentWorkspace() stays correct even
/// when code queries tracking directly. Asserts `ws` is in [0, g_workspace_count):
/// an out-of-range value (e.g. a config reload reducing the workspace count)
/// would make every window appear off-workspace and silently break focus.
pub fn setCurrentWorkspace(ws: u8) void {
    // ws < g_workspace_count is sufficient: setWorkspaceCount already asserts
    // g_workspace_count <= 64, so ws < 64 is implied.
    std.debug.assert(ws < g_workspace_count);
    g_current = ws;
}

// Window registration

/// Register `win` on workspace `ws`. No-op if already tracked.
/// Called directly when workspaces.zig is absent; workspaces.moveWindowTo
/// handles the full registration path (screen effects etc.) when present.
pub fn registerWindow(win: u32, ws: u8) !void {
    if (!g_initialized) return;
    // Same validation strength as setCurrentWorkspace: ws < g_workspace_count
    // implies ws < 64, so there's no separate looser check here either.
    std.debug.assert(ws < g_workspace_count);
    if (isManaged(win)) return;
    const idx = g_windows.items.len;
    try g_windows.append(g_alloc, .{ .win = win, .mask = workspaceBit(ws) });
    g_index.put(g_alloc, win, idx) catch |err| {
        // Roll back the just-appended entry so g_windows and g_index stay in
        // sync — otherwise the window would be present in g_windows but
        // invisible to isManaged/getWindowWorkspaceMask, which only consult
        // g_index.
        _ = g_windows.pop();
        return err;
    };
}

/// Remove `win` from the tracking list. Swap-remove: O(1) after an O(1)
/// g_index lookup; order doesn't matter for WM ops. When workspaces.zig is
/// present it calls this after cleaning up workspace last_focused; when
/// absent, window.zig calls this directly.
pub fn removeWindow(win: u32) void {
    if (!g_initialized) return;
    const i = g_index.get(win) orelse return;
    _ = g_windows.swapRemove(i);
    _ = g_index.remove(win);
    // swapRemove moved the previously-last entry into slot i (unless i was
    // last) — repoint that window's index if so.
    if (i < g_windows.items.len) {
        const moved_win = g_windows.items[i].win;
        g_index.put(g_alloc, moved_win, i) catch {
            // The map just shrank by one (g_index.remove above), so this put
            // should not need new bucket capacity; handled defensively anyway.
            std.log.err(
                "tracking: failed to reindex window 0x{x} after swap-remove; " ++
                    "it may be unreachable by ID lookup until removed and re-registered",
                .{moved_win},
            );
        };
    }
}

/// Update the workspace bitmask for `win` (tag and move operations).
/// Logs an error and returns (rather than asserting) when `win` is untracked:
/// a runtime condition in production (e.g. a removeWindow/mask-update race),
/// not a compile-time-checkable invariant.
pub fn setWindowMask(win: u32, mask: u64) void {
    if (!g_initialized) return;
    std.debug.assert(mask != 0);
    const idx = g_index.get(win) orelse {
        std.log.err(
            "tracking: setWindowMask called on unregistered window 0x{x}",
            .{win},
        );
        return;
    };
    g_windows.items[idx].mask = mask;
}

// Query predicates

/// Returns the workspace bitmask for `win`, or null if not tracked.
pub inline fn getWindowWorkspaceMask(win: u32) ?u64 {
    const idx = g_index.get(win) orelse return null;
    return g_windows.items[idx].mask;
}

pub fn isManaged(win: u32) bool {
    return getWindowWorkspaceMask(win) != null;
}

pub inline fn windowCount() usize {
    return g_windows.items.len;
}

pub inline fn getCurrentWorkspace() ?u8 {
    return if (g_initialized) g_current else null;
}

pub inline fn getWorkspaceCount() usize {
    return g_workspace_count;
}

/// Returns a read-only slice of all tracked (win, mask) pairs.
/// Callers filter by mask bit as needed; do not retain the slice across
/// any call that may add or remove windows.
pub fn allWindows() []const Entry {
    return g_windows.items;
}

/// True when at least one window has ws_idx set in its mask.
pub fn hasWindowsOnWorkspace(ws_idx: u8) bool {
    const bit = workspaceBit(ws_idx);
    for (g_windows.items) |e| {
        if (e.mask & bit != 0) return true;
    }
    return false;
}

/// Count of windows that have ws_idx set in their mask.
pub fn countWindowsOnWorkspace(ws_idx: u8) usize {
    const bit = workspaceBit(ws_idx);
    var n: usize = 0;
    for (g_windows.items) |e| {
        if (e.mask & bit != 0) n += 1;
    }
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

/// Comptime number strings "1".."64" for workspace display labels. Sized to
/// the bitmask capacity so any valid index is in-bounds; never heap-allocated.
pub const WORKSPACE_LABELS: [64][]const u8 = blk: {
    @setEvalBranchQuota(10_000);
    var labels: [64][]const u8 = undefined;
    for (&labels, 1..) |*label, i| label.* = std.fmt.comptimePrint("{d}", .{i});
    break :blk labels;
};

/// Lowest-indexed workspace this window belongs to, or null if untracked.
/// Definitive for single-workspace windows (the common case); for tag-based
/// multi-workspace windows the mask may have several bits set and this returns
/// the lowest, which need not be the *current* workspace — use
/// isOnCurrentWorkspace(win) for that.
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
    return !minimize.isMinimized(win);
}
