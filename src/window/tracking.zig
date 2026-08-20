//! Window tracking registry.
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
    /// workspaces combined). Not a tuneable: windows beyond the cap
    /// are silently dropped from tiling and workspace membership (error log).
    const capacity = constants.Limits.max_tiled_windows;

    // `len` is a u8, so capacity may not exceed 255. Enforced at compile time
    // so raising MAX_TILED_WINDOWS past 255 fails the build instead of
    // overflowing `len` at runtime; widen `len` alongside the cap.
    comptime {
        std.debug.assert(capacity <= std.math.maxInt(u8));
    }

    buf: [capacity]u32 = undefined,

    len: u8 = 0,

    pub fn contains(self: *const Tracking, win: u32) bool {
        return std.mem.indexOfScalar(u32, self.buf[0..self.len], win) != null;
    }

    /// Logs an error and returns false when the list is at capacity; the
    /// window is NOT tracked (invisible to tiling, membership queries, focus
    /// history). Capacity is reachable in production (many terminals,
    /// browsers); handled by log + graceful degradation so ReleaseFast stays safe.
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

    /// Append `win` to the back of the list. No-op if `win` is already
    /// present or the list is at capacity (see prepareAdd).
    pub fn add(self: *Tracking, win: u32) void {
        if (!self.prepareAdd(win)) return;
        self.buf[self.len] = win;
        self.len += 1;
    }

    /// Prepend `win` to the front of the list, shifting all existing
    /// entries right. No-op if `win` is already present or the list is at
    /// capacity (see prepareAdd).
    pub fn addFront(self: *Tracking, win: u32) void {
        if (!self.prepareAdd(win)) return;
        std.mem.copyBackwards(u32, self.buf[1 .. self.len + 1], self.buf[0..self.len]);
        self.buf[0] = win;
        self.len += 1;
    }

    /// Remove `win`, preserving the relative order of all other entries.
    /// Use this variant when window order is semantically meaningful, e.g.
    /// tiling layouts that derive master/slave assignment from positional index.
    /// O(n) due to the left-shift of the tail.
    pub fn remove(self: *Tracking, win: u32) bool {
        const i = std.mem.indexOfScalar(u32, self.buf[0..self.len], win) orelse return false;
        std.mem.copyForwards(u32, self.buf[i .. self.len - 1], self.buf[i + 1 .. self.len]);
        self.len -= 1;
        return true;
    }

    /// Remove `win` without preserving order: O(1) after the O(n) index
    /// scan. The last entry is moved into the removed slot. Use this variant
    /// when window order is not semantically meaningful (workspace membership
    /// bookkeeping, cleanup paths).
    pub fn removeUnordered(self: *Tracking, win: u32) bool {
        const i = std.mem.indexOfScalar(u32, self.buf[0..self.len], win) orelse return false;
        self.len -= 1;
        self.buf[i] = self.buf[self.len];
        return true;
    }

    /// Returns a slice of the live entries in insertion order.
    pub fn items(self: *const Tracking) []const u32 {
        return self.buf[0..self.len];
    }
};

pub const Entry = struct {
    win: u32,
    mask: u64,
};

// Per-workspace focus history (MRU).
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
const focus_mru_cap: usize = 12; // 8-16 entries is plenty for real usage; bounded like g_minimized.
var g_focus_mru: [constants.max_workspaces]utils.BoundedList(u32, focus_mru_cap) = @splat(.{});

/// Record `win` as the most-recently-defocused window on workspace `ws_idx`.
/// Moves `win` to the top if it was already present, so a window that gets
/// focused/defocused repeatedly doesn't accumulate duplicate, increasingly
/// stale entries. Evicts the oldest entry to make room when full: staying
/// bounded matters more here than remembering arbitrarily far back.
pub fn pushFocusMru(ws_idx: core.WorkspaceId, win: u32) void {
    if (ws_idx.index >= constants.max_workspaces) return;
    const list = &g_focus_mru[ws_idx.index];
    if (list.indexOfScalar(win)) |i| list.orderedRemove(i);
    if (!list.append(win)) {
        list.orderedRemove(0);
        _ = list.append(win);
    }
}

/// Pop the most recently defocused window on workspace `ws_idx` that
/// satisfies `visible`. Entries popped along the way that do NOT satisfy
/// `visible` are discarded rather than left in place. They are stale
/// (minimized, destroyed, or moved off this workspace) and, having already
/// failed the check once, would only fail it again later. Returns null once
/// the stack is exhausted with nothing eligible.
pub fn popFocusMru(ws_idx: core.WorkspaceId, visible: *const fn (u32) bool) ?u32 {
    if (ws_idx.index >= constants.max_workspaces) return null;
    const list = &g_focus_mru[ws_idx.index];
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
/// from a stale entry. X11 recycles window IDs, and an unpurged entry could
/// otherwise be mistaken for a live, unrelated window that later reuses the
/// same ID.
fn removeFromFocusMruAll(win: u32) void {
    for (g_focus_mru[0..state.?.workspace_count]) |*list| {
        if (list.indexOfScalar(win)) |i| list.orderedRemove(i);
    }
}

fn clearFocusMru() void {
    for (&g_focus_mru) |*list| list.clear();
}

const State = struct {
    windows: std.ArrayListUnmanaged(Entry) = .empty,
    index: std.AutoHashMapUnmanaged(u32, usize) = .empty,
    alloc: std.mem.Allocator = undefined,
    initialized: bool = false,
    current: u8 = 0,
    workspace_count: usize = 1,
};

var state: ?State = null;

pub inline fn getState() *State {
    if (state) |*s| return s;
    @panic("tracking: getState() called before init()");
}

pub inline fn getStateOpt() ?*State {
    return if (state) |*s| s else null;
}

/// Initializes the global window-tracking list. Must be called once at
/// startup before any windows are managed.
pub fn init(allocator: std.mem.Allocator) void {
    state = .{};
    state.?.alloc = allocator;
    state.?.initialized = true;
    state.?.windows.ensureTotalCapacity(allocator, 32) catch |err| {
        std.log.warn("tracking: initial pre-allocation failed ({s}); list will grow on demand", .{@errorName(err)});
    };
    state.?.index.ensureTotalCapacity(allocator, 32) catch |err| {
        std.log.warn("tracking: initial index pre-allocation failed ({s}); map will grow on demand", .{@errorName(err)});
    };
    clearFocusMru();
}

/// Frees the global window-tracking list and resets all state.
pub fn deinit() void {
    if (state) |*s| {
        if (s.initialized) {
            s.windows.deinit(s.alloc);
            s.index.deinit(s.alloc);
        }
    }
    state = null;
    clearFocusMru();
}

/// Called by workspaces.init: tells tracking how many workspaces exist.
/// Count must not exceed 64; the workspace bitmask (u64) cannot represent more.
pub fn setWorkspaceCount(count: usize) void {
    std.debug.assert(count <= 64);
    state.?.workspace_count = count;
}

/// Called by workspaces.switchTo so getCurrentWorkspace() stays correct even
/// when code queries tracking directly. Asserts `ws` is in [0, state.?.workspace_count):
/// an out-of-range value (e.g. a config reload reducing the workspace count)
/// would make every window appear off-workspace and silently break focus.
pub fn setCurrentWorkspace(ws: core.WorkspaceId) void {
    // ws.index < state.?.workspace_count is sufficient: setWorkspaceCount already asserts
    // state.?.workspace_count <= 64, so ws.index < 64 is implied.
    std.debug.assert(ws.index < state.?.workspace_count);
    state.?.current = ws.index;
}

// Window registration

/// Register `win` on workspace `ws`. No-op if already tracked.
/// Called directly when workspaces.zig is absent; workspaces.moveWindowTo
/// handles the full registration path (screen effects etc.) when present.
pub fn registerWindow(win: u32, ws: core.WorkspaceId) !void {
    if (!state.?.initialized) return;
    // Same validation strength as setCurrentWorkspace: ws.index < state.?.workspace_count
    // implies ws.index < 64, so there's no separate looser check here either.
    std.debug.assert(ws.index < state.?.workspace_count);
    if (isManaged(win)) return;
    const idx = state.?.windows.items.len;
    try state.?.windows.append(state.?.alloc, .{ .win = win, .mask = workspaceBit(ws.index) });
    state.?.index.put(state.?.alloc, win, idx) catch |err| {
        // Roll back the just-appended entry so state.?.windows and state.?.index stay in
        // sync, otherwise the window would be present in state.?.windows but
        // invisible to isManaged/getWindowWorkspaceMask, which only consult
        // state.?.index.
        _ = state.?.windows.pop();
        return err;
    };
}

/// Remove `win` from the tracking list. Swap-remove: O(1) after an O(1)
/// state.?.index lookup; order doesn't matter for WM ops. When workspaces.zig is
/// present it calls this after cleaning up workspace last_focused; when
/// absent, window.zig calls this directly.
pub fn removeWindow(win: u32) void {
    if (!state.?.initialized) return;
    const i = state.?.index.get(win) orelse return;
    removeFromFocusMruAll(win);
    _ = state.?.windows.swapRemove(i);
    // swapRemove moved the previously-last entry into slot i (unless i was
    // last), repoint that window's index in place to avoid a put+alloc.
    if (i < state.?.windows.items.len) {
        const moved_win = state.?.windows.items[i].win;
        if (state.?.index.getPtr(moved_win)) |ptr| {
            ptr.* = i;
        }
    }
    _ = state.?.index.remove(win);
}

/// Update the workspace bitmask for `win` (tag and move operations).
/// Logs an error and returns (rather than asserting) when `win` is untracked:
/// a runtime condition in production (e.g. a removeWindow/mask-update race),
/// not a compile-time-checkable invariant.
pub fn setWindowMask(win: u32, mask: u64) void {
    if (!state.?.initialized) return;
    std.debug.assert(mask != 0);
    const idx = state.?.index.get(win) orelse {
        std.log.err(
            "tracking: setWindowMask called on unregistered window 0x{x}",
            .{win},
        );
        return;
    };
    state.?.windows.items[idx].mask = mask;
}

// Query predicates

pub inline fn getWindowWorkspaceMask(win: u32) ?u64 {
    const idx = state.?.index.get(win) orelse return null;
    return state.?.windows.items[idx].mask;
}

pub fn isManaged(win: u32) bool {
    return getWindowWorkspaceMask(win) != null;
}

pub inline fn windowCount() usize {
    return state.?.windows.items.len;
}

pub inline fn getCurrentWorkspace() ?u8 {
    return if (state.?.initialized) state.?.current else null;
}

pub inline fn getWorkspaceCount() usize {
    return state.?.workspace_count;
}

/// Returns a read-only slice of all tracked (win, mask) pairs.
/// Callers filter by mask bit as needed; do not retain the slice across
/// any call that may add or remove windows.
pub fn allWindows() []const Entry {
    return state.?.windows.items;
}

/// Iterates tracked entries, yielding only those whose workspace mask contains
/// `bit`, and optionally skipping a single window id (`skip` = 0 = none).
/// When the caller wants no mask filter it passes an all-ones `bit`.
pub const WorkspaceIter = struct {
    idx: usize = 0,
    bit: u64,
    skip: u32,

    pub fn next(self: *WorkspaceIter) ?Entry {
        const entries = allWindows();
        while (self.idx < entries.len) {
            const e = entries[self.idx];
            self.idx += 1;
            if (e.mask & self.bit == 0 or e.win == self.skip) continue;
            return e;
        }
        return null;
    }
};

pub fn onWorkspace(bit: u64, skip: u32) WorkspaceIter {
    return .{ .bit = bit, .skip = skip };
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

pub fn windowsOnCurrentWorkspace(skip: u32) WorkspaceIter {
    const bit = currentWorkspaceIterBit() orelse
        return .{ .skip = skip, .bit = ~@as(u64, 0) };
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

    // Phase 1: fire ALL geometry requests, collecting cookies in a bounded
    // stack buffer. This pipelines the round trips: the server processes
    // each request while we fire the next, converting N serial round trips
    // into ~1.
    var wins: [Tracking.capacity]u32 = undefined;
    var cookies: [Tracking.capacity]core.xcb.xcb_get_geometry_cookie_t = undefined;
    var count: usize = 0;

    {
        var it = onWorkspace(ws_bit, skip_win);
        while (it.next()) |entry| {
            const win = entry.win;
            if (skip_ws < 64 and isWindowOnWorkspace(win, core.WorkspaceId.fromIndex(skip_ws))) continue;
            if (!predicate(win)) continue;
            if ((if (build_options.has_tiling) tiling.getWindowGeom(win) else null) != null) continue;
            if (count >= Tracking.capacity) break;
            wins[count] = win;
            // xcb_get_geometry returns an xcb_get_geometry_cookie_t.
            cookies[count] = core.xcb.xcb_get_geometry(conn, win);
            count += 1;
        }
    }

    // Phase 2: drain all replies. By the time we get here the server has
    // had time to process all pipelined requests, so most replies are
    // already in the XCB receive buffer.
    for (0..count) |i| {
        const reply = core.xcb.xcb_get_geometry_reply(conn, cookies[i], null) orelse continue;
        defer std.c.free(reply);
        if (utils.isOffscreenGeomReply(reply)) continue;
        window.saveWindowGeom(wins[i], utils.Rect.fromXcb(reply));
    }
}

pub fn prefetchAndSaveGeometryOnCurrentWorkspace(
    predicate: *const fn (u32) bool,
    skip_win: u32,
) void {
    const bit = currentWorkspaceIterBit() orelse return;
    prefetchAndSaveGeometry(bit, predicate, skip_win, 255);
}

pub fn countWindowsOnWorkspace(ws_idx: core.WorkspaceId) usize {
    const bit = workspaceBit(ws_idx.index);
    var n: usize = 0;
    for (state.?.windows.items) |e| {
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
pub const workspace_labels: [64][]const u8 = blk: {
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

pub inline fn isWindowOnWorkspace(win: u32, ws_idx: core.WorkspaceId) bool {
    const mask = getWindowWorkspaceMask(win) orelse return false;
    return mask & workspaceBit(ws_idx.index) != 0;
}

pub inline fn isOnCurrentWorkspace(win: u32) bool {
    return isWindowOnWorkspace(win, core.WorkspaceId.fromIndex(state.?.current));
}

/// Combined predicate for focus recovery: on current workspace and not minimized.
/// Declared as a plain fn (not inline) so it can be passed as a *const fn(u32)bool.
pub fn isOnCurrentWorkspaceAndVisible(win: u32) bool {
    if (!isOnCurrentWorkspace(win)) return false;
    return !minimize.isMinimized(win);
}
