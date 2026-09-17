//! Window tracking facade over the model, the single source of truth.
//! Every query reads pipeline.model(), so window predicates match actions/sync.

const std = @import("std");

const core = @import("core");
const constants = @import("constants");
const build_options = @import("build_options");
const wincache = @import("wincache");
const utils = @import("utils");
const pipeline = @import("pipeline");
const model_mod = @import("model");
const debug = @import("debug");

// Transition-layer gate for THIS facade's own model writes only. The single
// entry-drop transition (removeWindow) and the focus-MRU clear in
// init/deinit go through it. It is deliberately NOT pub: external model
// mutation is the job of the transition owners (actions/window/focus), and
// each of those declares its OWN private gate instead of aliasing this one,
// so no shared writable token leaks through the read facade.
const gate: pipeline.Gate = .{};

/// True once pipeline.init ran; every model access is gated on this so boot
/// order never touches the undefined global instance.
fn modelReady() bool {
    return pipeline.initialized;
}

fn m() ?*const model_mod.Model {
    if (!modelReady()) return null;
    return pipeline.model();
}

pub const Entry = struct {
    win: u32,
    mask: u64,
    presence: model_mod.Presence = .present,
};

// ---------------------------------------------------------------------------
// Registry queries (facade)
// ---------------------------------------------------------------------------

pub fn isManaged(win: u32) bool {
    const mm = m() orelse return false;
    return mm.store.has(win);
}

/// Idempotent with actions.unmanage (unregister early-returns when absent).
/// The one entry-drop transition in this facade: unregisters the model entry
/// (requires the transition-layer gate; all other tracking queries are reads).
pub fn removeWindow(win: u32) void {
    if (!modelReady()) return;
    model_mod.unregister(pipeline.mut(&gate), win);
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

/// NOTE: rebuild-per-call is correct for correctness; a dirty flag
/// would need mutation hooks to track when the model store changes.
///
/// Read-only SNAPSHOT of the model registry, rebuilt per call (bounded by the
/// store capacity; call sites are redraw/focus-scan paths, not hot loops).
/// Do not retain across mutations.
var snapshot_buf: [model_mod.store_capacity]Entry = undefined;

pub fn allWindows() []const Entry {
    const mm = m() orelse return &.{};
    const n = @min(mm.store.count(), snapshot_buf.len);
    for (0..n) |i| {
        const it = mm.store.at(i);
        snapshot_buf[i] = .{ .win = it.key, .mask = it.val.mask, .presence = it.val.presence };
    }
    return snapshot_buf[0..n];
}

// ---------------------------------------------------------------------------
// Per-workspace focus MRU (facade over model.ws[ws].focus_mru)
//
// Order convention: index 0 = most recent (matches model.setFocus's
// front-insert). Fallback selection reads the MRU through
// model.fallbackFocusCandidate.
// ---------------------------------------------------------------------------

fn clearFocusMru() void {
    if (!modelReady()) return;
    const mm = pipeline.mut(&gate);
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
/// The workspace bitmask is a u64, so more than 64 workspaces cannot be
/// represented; clamp (never crash) so a corrupt boot count can't overflow the
/// mask in ReleaseFast.
pub fn setWorkspaceCount(count: usize) void {
    if (count > 64) debug.warn("setWorkspaceCount: {d} workspaces requested; clamping to 64", .{count});
    state.workspace_count = @min(count, 64);
}

/// Read-through facade over `model.current`, the single source of truth:
/// every write path (actions.switchTo) mutates the model directly, so a
/// tracking query needs no separate storage. Null before pipeline.init
/// (callers default to workspace 0).
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

// ---------------------------------------------------------------------------
// Workspace bitmask helpers
// ---------------------------------------------------------------------------

/// Returns a u64 bitmask with only the bit for `ws_idx` set.
pub inline fn workspaceBit(ws_idx: anytype) u64 {
    if (ws_idx >= 64) return 0; // out-of-range → no windows in that mask
    return model_mod.bit(@intCast(ws_idx));
}

// Comptime workspace label table

/// Comptime number strings "1".."64" for workspace display labels.
pub const workspace_labels: [64][]const u8 = blk: {
    @setEvalBranchQuota(10_000);
    var labels: [64][]const u8 = undefined;
    for (&labels, 1..) |*label, i| label.* = std.fmt.comptimePrint("{d}", .{i});
    break :blk labels;
};

pub inline fn isWindowOnWorkspace(win: u32, ws_idx: core.WorkspaceId) bool {
    const mask = getWindowWorkspaceMask(win) orelse return false;
    return mask & workspaceBit(ws_idx.index) != 0;
}

/// True when `win` has a tiled anchor (not floating, covering or
/// minimized); reads the model entry directly.
pub fn isTiledMode(win: u32) bool {
    const mm = m() orelse return false;
    const e = mm.store.get(win) orelse return false;
    return e.anchor == .tiled;
}

pub inline fn isOnCurrentWorkspace(win: u32) bool {
    const cur = getCurrentWorkspace() orelse return false;
    return isWindowOnWorkspace(win, core.WorkspaceId.fromIndex(cur));
}

/// Combined predicate for focus recovery: on current workspace and not
/// parked (presence check; extensions hide windows via `.parked`).
pub fn isOnCurrentWorkspaceAndVisible(win: u32) bool {
    if (!isOnCurrentWorkspace(win)) return false;
    const mm = m() orelse return false;
    const e = mm.store.get(win) orelse return false;
    return e.presence != .parked;
}
