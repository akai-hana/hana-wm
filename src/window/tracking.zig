//! Window tracking FACADE over the model (REARCHITECTURE_PLAN.md P1: single
//! source of truth). The registry arrays this module once owned are gone:
//! every query reads `pipeline.model()`, so hover-focus resolution, manage
//! guards, counts, masks and iterators see exactly what actions/sync see.
//!
//! Kept locally (not model state): workspace_count (config lifecycle) and
//! `current` (also mirrored into the model by actions.switchTo; readers may
//! call this before pipeline.init during boot).

const std = @import("std");

const core = @import("core");
const constants = @import("constants");
const build_options = @import("build_options");
const wincache = @import("wincache");
const utils = @import("utils");
const pipeline = @import("pipeline");
const model_mod = @import("model");

/// True once pipeline.init ran; every model access is gated on this so boot
/// order never touches the undefined global instance.
fn modelReady() bool {
    return pipeline.initialized;
}

fn m() ?*model_mod.Model {
    if (!modelReady()) return null;
    return pipeline.model();
}

pub const Entry = struct {
    win: u32,
    mask: u64,
};

// ---------------------------------------------------------------------------
// Registry queries (facade)
// ---------------------------------------------------------------------------

pub fn isManaged(win: u32) bool {
    const mm = m() orelse return false;
    return mm.store.has(win);
}

/// Defensive registration path: legacy callers (workspaces.moveWindowTo when
/// present) may still call this. The map path registers via actions.mapRequest,
/// so this is a no-op for windows the model already knows.
pub fn registerWindow(win: u32, ws: core.WorkspaceId) !void {
    const mm = m() orelse return;
    std.debug.assert(ws.index < state.workspace_count);
    if (mm.store.has(win)) return;
    model_mod.register(mm, win, ws.index);
}

/// Idempotent with actions.unmanage (unregister early-returns when absent).
pub fn removeWindow(win: u32) void {
    const mm = m() orelse return;
    model_mod.unregister(mm, win);
}

pub fn setWindowMask(win: u32, mask: u64) void {
    const mm = m() orelse return;
    std.debug.assert(mask != 0);
    const e = mm.store.getPtr(win) orelse {
        std.log.err("tracking: setWindowMask called on unregistered window 0x{x}", .{win});
        return;
    };
    e.mask = mask;
}

pub inline fn getWindowWorkspaceMask(win: u32) ?u64 {
    const mm = m() orelse return null;
    const e = mm.store.get(win) orelse return null;
    return e.mask;
}

pub inline fn windowCount() usize {
    const mm = m() orelse return 0;
    return mm.store.count();
}

/// Read-only SNAPSHOT of the model registry, rebuilt per call (bounded by the
/// store capacity; call sites are redraw/focus-scan paths, not hot loops).
/// Do not retain across mutations.
var snapshot_buf: [model_mod.store_capacity]Entry = undefined;

pub fn allWindows() []const Entry {
    const mm = m() orelse return &.{};
    const n = @min(mm.store.count(), snapshot_buf.len);
    for (0..n) |i| {
        const it = mm.store.at(i);
        snapshot_buf[i] = .{ .win = it.key, .mask = it.val.mask };
    }
    return snapshot_buf[0..n];
}

// ---------------------------------------------------------------------------
// Iterators
// ---------------------------------------------------------------------------

/// Iterates tracked entries, yielding only those whose workspace mask contains
/// `bit`, and optionally skipping a single window id (`skip` = 0 = none).
/// When the caller wants no mask filter it passes an all-ones `bit`.
pub const WorkspaceIter = struct {
    idx: usize = 0,
    bit: u64,
    skip: u32,

    pub fn next(self: *WorkspaceIter) ?Entry {
        const mm = m() orelse return null;
        const count = mm.store.count();
        while (self.idx < count) {
            const it = mm.store.at(self.idx);
            self.idx += 1;
            if (it.val.mask & self.bit == 0 or it.key == self.skip) continue;
            return .{ .win = it.key, .mask = it.val.mask };
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

// ---------------------------------------------------------------------------
// Per-workspace focus MRU (facade over model.ws[ws].focus_mru)
//
// Order convention: index 0 = most recent (matches model.setFocus's
// front-insert). popFocusMru consumes from the FRONT and discards invisible
// entries along the way (legacy consume semantics preserved).
// ---------------------------------------------------------------------------

const focus_mru_cap = model_mod.mru_capacity;

/// Record `win` as the most-recently-defocused window on workspace `ws_idx`.
pub fn pushFocusMru(ws_idx: core.WorkspaceId, win: u32) void {
    const mm = m() orelse return;
    if (ws_idx.index >= constants.max_workspaces) return;
    const list = &mm.ws[ws_idx.index].focus_mru;
    if (model_mod.findInOrder(list, win)) |i| _ = list.orderedRemove(i);
    list.insert(mm.gpa, 0, win) catch return;
    if (list.items.len > focus_mru_cap) list.shrinkRetainingCapacity(focus_mru_cap);
}

/// Pop the most recently defocused window on workspace `ws_idx` that
/// satisfies `visible`. Entries skipped along the way are discarded (stale:
/// minimized, destroyed, or moved off this workspace). Returns null once the
/// history is exhausted with nothing eligible.
pub fn popFocusMru(ws_idx: core.WorkspaceId, visible: *const fn (u32) bool) ?u32 {
    const mm = m() orelse return null;
    if (ws_idx.index >= constants.max_workspaces) return null;
    const list = &mm.ws[ws_idx.index].focus_mru;
    while (list.items.len > 0) {
        const win = list.items[0];
        _ = list.orderedRemove(0);
        if (visible(win)) return win;
    }
    return null;
}

/// Purge `win` from every workspace's focus history so a destroyed window's
/// ID can never surface from a stale entry (X11 recycles window IDs).
fn removeFromFocusMruAll(win: u32) void {
    const mm = m() orelse return;
    for (&mm.ws) |*s| model_mod.removeValuePub(s.focus_mru, win);
}

fn clearFocusMru() void {
    const mm = m() orelse return;
    for (&mm.ws) |*s| s.focus_mru.clearRetainingCapacity();
}

// ---------------------------------------------------------------------------
// Lifecycle / workspace count (kept local; config-driven)
// ---------------------------------------------------------------------------

var state = struct {
    initialized: bool = false,
    current: u8 = 0,
    workspace_count: usize = 1,
}{};

pub fn init(allocator: std.mem.Allocator) void {
    _ = allocator;
    state.initialized = true;
    clearFocusMru();
}

pub fn deinit() void {
    state = .{};
    clearFocusMru();
}

/// Called by workspaces.init: tells tracking how many workspaces exist.
/// Count must not exceed 64; the workspace bitmask (u64) cannot represent more.
pub fn setWorkspaceCount(count: usize) void {
    std.debug.assert(count <= 64);
    state.workspace_count = count;
}

/// Called by workspaces.switchTo so getCurrentWorkspace() stays correct even
/// when code queries tracking directly. Also mirrored into the model by
/// actions.switchTo (dual-write until tracking's storage is fully deleted).
pub fn setCurrentWorkspace(ws: core.WorkspaceId) void {
    std.debug.assert(ws.index < state.workspace_count);
    state.current = ws.index;
    if (m()) |mm| mm.current = ws.index;
}

pub inline fn getStateOpt() ?*@TypeOf(state) {
    return if (state.initialized) &state else null;
}

pub inline fn getCurrentWorkspace() ?u8 {
    if (!state.initialized) return null;
    return state.current;
}

pub inline fn getWorkspaceCount() usize {
    return state.workspace_count;
}

// ---------------------------------------------------------------------------
// Geometry prefetch (data source now model-driven)
// ---------------------------------------------------------------------------

/// Shared geometry prefetch + save: iterates windows matching `ws_bit`,
/// applies `predicate`, skips windows on `skip_ws` (255 = none), skips cache
/// hits, issues pipelined `xcb_get_geometry` requests, saves results. Skips
/// offscreen-parked replies. Must run BEFORE `xcb_grab_server`.
/// `skip_win` is excluded from iteration (0 = none).
pub fn prefetchAndSaveGeometry(
    ws_bit: u64,
    predicate: *const fn (u32) bool,
    skip_win: u32,
    skip_ws: u8,
) void {
    const window = @import("window");
    const conn = core.getState().conn;

    const capacity = constants.Limits.max_tiled_windows;
    var wins: [capacity]u32 = undefined;
    var cookies: [capacity]core.xcb.xcb_get_geometry_cookie_t = undefined;
    var count: usize = 0;

    {
        var it = onWorkspace(ws_bit, skip_win);
        while (it.next()) |entry| {
            const win = entry.win;
            if (skip_ws < 64 and isWindowOnWorkspace(win, core.WorkspaceId.fromIndex(skip_ws))) continue;
            if (!predicate(win)) continue;
            if (wincache.getWindowGeom(win) != null) continue;
            if (count >= capacity) break;
            wins[count] = win;
            cookies[count] = core.xcb.xcb_get_geometry(conn, win);
            count += 1;
        }
    }

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
    for (allWindows()) |e| {
        if (e.mask & bit != 0) n += 1;
    }
    return n;
}

/// Windows currently in base-tiled mode on the active workspace (model
/// truth). dump_state used to read the legacy tiling pool, which is no
/// longer fed on the model spawn path.
pub fn tiledCountOnCurrent() usize {
    const mm = pipeline.model();
    const cur_bit = workspaceBit(mm.current);
    var n: usize = 0;
    var seq: usize = 0;
    while (seq < mm.store.count()) : (seq += 1) {
        const item = mm.store.at(seq);
        if (item.val.mask & cur_bit == 0) continue;
        if (item.val.mode == .base and item.val.mode.base == .tiled) n += 1;
    }
    return n;
}

// ---------------------------------------------------------------------------
// Workspace bitmask helpers
// ---------------------------------------------------------------------------

/// Returns a u64 bitmask with only the bit for `ws_idx` set.
pub inline fn workspaceBit(ws_idx: anytype) u64 {
    std.debug.assert(ws_idx < 64);
    return @as(u64, 1) << @intCast(ws_idx);
}

/// Returns a bitmask with bits set for every workspace in [0, count).
pub inline fn allWorkspacesMask(count: usize) u64 {
    if (count >= 64) return ~@as(u64, 0);
    return (@as(u64, 1) << @intCast(count)) - 1;
}

// Comptime workspace label table

/// Comptime number strings "1".."64" for workspace display labels.
pub const workspace_labels: [64][]const u8 = blk: {
    @setEvalBranchQuota(10_000);
    var labels: [64][]const u8 = undefined;
    for (&labels, 1..) |*label, i| label.* = std.fmt.comptimePrint("{d}", .{i});
    break :blk labels;
};

/// Lowest-indexed workspace this window belongs to, or null if untracked.
pub inline fn getWorkspaceForWindow(win: u32) ?u8 {
    const mask = getWindowWorkspaceMask(win) orelse return null;
    return @intCast(@ctz(mask));
}

pub inline fn isWindowOnWorkspace(win: u32, ws_idx: core.WorkspaceId) bool {
    const mask = getWindowWorkspaceMask(win) orelse return false;
    return mask & workspaceBit(ws_idx.index) != 0;
}

/// True when `win` sits in the model's base-tiled mode (not floating,
/// fullscreen or minimized). Replaces the legacy tiling pool's
/// isWindowTiled/isWindowActiveTiled, which read a list nothing feeds.
pub fn isTiledMode(win: u32) bool {
    const mm = m() orelse return false;
    const e = mm.store.get(win) orelse return false;
    return e.mode == .base and e.mode.base == .tiled;
}

pub inline fn isOnCurrentWorkspace(win: u32) bool {
    const cur = getCurrentWorkspace() orelse return false;
    return isWindowOnWorkspace(win, core.WorkspaceId.fromIndex(cur));
}

/// Combined predicate for focus recovery: on current workspace and not
/// minimized (MODEL mode check — the legacy minimize-record read is gone).
pub fn isOnCurrentWorkspaceAndVisible(win: u32) bool {
    if (!isOnCurrentWorkspace(win)) return false;
    const mm = m() orelse return false;
    const e = mm.store.get(win) orelse return false;
    return e.mode != .minimized;
}
