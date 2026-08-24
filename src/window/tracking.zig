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
// Per-workspace focus MRU (facade over model.ws[ws].focus_mru)
//
// Order convention: index 0 = most recent (matches model.setFocus's
// front-insert). Fallback selection reads the MRU through actions.pickFallback.
// ---------------------------------------------------------------------------

fn clearFocusMru() void {
    const mm = m() orelse return;
    for (&mm.ws) |*s| s.focus_mru.clear();
}

// ---------------------------------------------------------------------------
// Lifecycle / workspace count (kept local; config-driven)
// ---------------------------------------------------------------------------

var state = struct {
    initialized: bool = false,
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
/// Single source of truth is `model.current` (A4): read-through facade,
/// null before pipeline.init (callers default to workspace 0).
pub inline fn getCurrentWorkspace() ?u8 {
    if (pipeline.initialized) return @intCast(pipeline.model().current);
    return null;
}

pub inline fn getWorkspaceCount() usize {
    return state.workspace_count;
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
