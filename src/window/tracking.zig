//! Core window tracking
//! Maintains the registry of all managed windows and their workspace assignments.

const std = @import("std");

const core = @import("core");
const constants = @import("constants");
const build_options = @import("build_options");
const tiling = if (build_options.has_tiling) @import("tiling") else null;
const utils = @import("utils");
const minimize = @import("minimize");

// Fixed-size ordered window list.
// Embedded once as tiling.State.windows (a single global instance, not one
// per workspace); kept here so tiling.zig can import it from the always-present
// tracking module.

pub const Tracking = struct {
    /// Hard compile-time cap on windows tracked across the whole WM (all
    /// workspaces combined), `tiling.State.windows`, a single global
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
    /// Use this variant when window order is semantically meaningful, e.g.
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

// Per-workspace focus history (MRU)
//
// Records, per workspace, the order windows lost focus on it, so a caller
// resolving "what should regain focus now" (minimize fallback, in particular)
// answers "whichever window was actually focused right before this one", not
// "the first candidate a registration-order scan turns up". Scoped
// per-workspace (rather than one global stack) so the answer is never a window
// on a workspace the user isn't looking at.
//
// Pushed from tiling.updateWindowFocus on every focus transition (it already
// runs unconditionally from focus.commitFocusTransition); popped by minimize.zig
// when resolving its post-minimize restore target. Pushes are keyed by the
// departing window's OWN workspace (getWorkspaceForWindow), not the "current"
// workspace: across a workspace switch the current pointer has already moved to
// the destination by the time the switch's focus transition runs, so keying off
// "current" would misfile the departing window.
const FOCUS_MRU_CAP: usize = 12; // 8-16 entries is plenty for real usage; bounded like g_minimized.
var g_focus_mru: [constants.MAX_WORKSPACES]utils.BoundedList(u32, FOCUS_MRU_CAP) = @splat(.{});

/// Record `win` as the most-recently-defocused window on workspace `ws_idx`.
/// Moves `win` to the top if it was already present, so a window that gets
/// focused/defocused repeatedly doesn't accumulate duplicate, increasingly
/// stale entries. Evicts the oldest entry to make room when full: staying
/// bounded matters more here than remembering arbitrarily far back.
pub fn pushFocusMru(ws_idx: u8, win: u32) void {
    if (ws_idx >= constants.MAX_WORKSPACES) return;
    const list = &g_focus_mru[ws_idx];
    if (list.indexOfScalar(win)) |i| list.orderedRemove(i);
    if (!list.append(win)) {
        list.orderedRemove(0);
        _ = list.append(win);
    }
}

/// Pop the most recently defocused window on workspace `ws_idx` that
/// satisfies `visible`. Entries popped along the way that do NOT satisfy
/// `visible` are discarded rather than left in place, they're stale
/// (minimized, destroyed, or moved off this workspace) and, having already
/// failed the check once, would only fail it again later. Returns null once
/// the stack is exhausted with nothing eligible.
pub fn popFocusMru(ws_idx: u8, visible: *const fn (u32) bool) ?u32 {
    if (ws_idx >= constants.MAX_WORKSPACES) return null;
    const list = &g_focus_mru[ws_idx];
    while (list.len > 0) {
        const i = list.len - 1;
        const win = list.items[i];
        list.orderedRemove(i);
        if (visible(win)) return win;
    }
    return null;
}

/// Purge `win` from every workspace's focus history. Called on final
/// untracking (removeWindow) so a destroyed window's ID can never surface
/// from a stale entry, X11 recycles window IDs, and an unpurged entry could
/// otherwise be mistaken for a live, unrelated window that later reuses the
/// same ID.
fn removeFromFocusMruAll(win: u32) void {
    for (&g_focus_mru) |*list| {
        if (list.indexOfScalar(win)) |i| list.orderedRemove(i);
    }
}

fn clearFocusMru() void {
    for (&g_focus_mru) |*list| list.clear();
}

var g_windows: std.ArrayListUnmanaged(Entry) = .empty;
/// win -> index into g_windows.items, giving the ID-lookup functions below
/// (getWindowWorkspaceMask, isManaged, setWindowMask, removeWindow) O(1)
/// average instead of an O(n) scan. Unlike the bounded per-workspace tiling
/// list (Tracking above), g_windows is genuinely unbounded, it holds every
/// managed window, tiled and floating, so its scan cost grows with real
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
    clearFocusMru();
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
    clearFocusMru();
}

/// Called by workspaces.init: tells tracking how many workspaces exist.
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
        // sync, otherwise the window would be present in g_windows but
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
    removeFromFocusMruAll(win);
    _ = g_windows.swapRemove(i);
    _ = g_index.remove(win);
    // swapRemove moved the previously-last entry into slot i (unless i was
    // last), repoint that window's index if so.
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

/// Iterates tracked entries, yielding only those whose workspace mask contains
/// `bit`, and optionally skipping a single window id (`skip` = 0 = none).
/// When the caller wants no mask filter it passes an all-ones `bit`.
pub const WorkspaceIter = struct {
    entries: []const Entry,
    idx: usize = 0,
    bit: u64,
    skip: u32,

    pub fn next(self: *WorkspaceIter) ?Entry {
        while (self.idx < self.entries.len) {
            const e = self.entries[self.idx];
            self.idx += 1;
            if (e.mask & self.bit == 0) continue;
            if (e.win == self.skip) continue;
            return e;
        }
        return null;
    }
};

/// Iterate entries on workspace `bit` (via `WorkspaceIter`), skipping `skip`.
pub fn onWorkspace(bit: u64, skip: u32) WorkspaceIter {
    return .{ .entries = allWindows(), .bit = bit, .skip = skip };
}

/// Bitmask selecting "windows on the current workspace" for iteration
/// helpers: the current workspace's bit when workspaces are enabled, or
/// all-ones (no filter) when they're disabled. Null when workspaces are
/// enabled but no current workspace is set yet (not initialized), callers
/// treat that as "nothing to iterate".
fn currentWorkspaceIterBit() ?u64 {
    if (core.getState().config.workspaces.enabled) {
        const cur = getCurrentWorkspace() orelse return null;
        return workspaceBit(cur);
    }
    return ~@as(u64, 0);
}

/// Iterate windows on the current workspace, skipping `skip`. Uses the
/// shared `WorkspaceIter` with a workspace-mask filter when workspaces
/// are enabled, otherwise the global window list (all-ones bit = no filter).
pub fn windowsOnCurrentWorkspace(skip: u32) WorkspaceIter {
    const bit = currentWorkspaceIterBit() orelse
        return .{ .entries = &.{}, .skip = skip, .bit = ~@as(u64, 0) };
    return onWorkspace(bit, skip);
}

/// Shared geometry prefetch + save: iterates windows matching `ws_bit`
/// (use `~@as(u64, 0)` for all windows), applies `predicate`, skips
/// windows that are on `skip_ws` (use 255 to skip none), skips
/// windows with a cache hit, issues a live `xcb_get_geometry`, and saves
/// the result. Skips replies that report the window parked at the
/// off-screen sentinel, that position isn't a real, restorable geometry.
/// Must run BEFORE `xcb_grab_server` (a round-trip can't happen inside a
/// grab). `skip_win` is excluded from iteration (0 = none).
pub fn prefetchAndSaveGeometry(
    ws_bit: u64,
    predicate: *const fn (u32) bool,
    skip_win: u32,
    skip_ws: u8,
) void {
    const window = @import("window");
    const conn = core.getState().conn;
    var it = onWorkspace(ws_bit, skip_win);
    while (it.next()) |entry| {
        const win = entry.win;
        if (skip_ws < 64 and isWindowOnWorkspace(win, skip_ws)) continue;
        if (!predicate(win)) continue;
        if ((if (build_options.has_tiling) tiling.getWindowGeom(win) else null) != null) continue;
        const reply = core.xcb.xcb_get_geometry_reply(conn, core.xcb.xcb_get_geometry(conn, win), null) orelse continue;
        defer std.c.free(reply);
        if (utils.isOffscreenGeomReply(reply)) continue;
        window.saveWindowGeom(win, utils.Rect.fromXcb(reply));
    }
}

/// Like `prefetchAndSaveGeometry`, but scoped to "the current workspace"
/// using the same enabled/disabled semantics as `windowsOnCurrentWorkspace`
/// (falls back to every window when workspaces are disabled). No-op when no
/// current workspace is set yet. Shared by callers that only ever care about
/// the visible workspace, so they don't need to pass a `skip_ws`.
pub fn prefetchAndSaveGeometryOnCurrentWorkspace(
    predicate: *const fn (u32) bool,
    skip_win: u32,
) void {
    const bit = currentWorkspaceIterBit() orelse return;
    prefetchAndSaveGeometry(bit, predicate, skip_win, 255);
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
/// Returns all-ones for count >= 64 (saturating at the u64 width).
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
/// the lowest, which need not be the *current* workspace, use
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
