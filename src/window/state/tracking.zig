//! Read-only query facade over the model singleton (the single source of truth
//! for windows and workspaces): is a window managed/tiled/on the current
//! workspace, is the all-view active, plus a caller-owned snapshot of the
//! registry for callers that sweep it and the comptime workspace label table
//! the bar renders.
//!
//! Writes are deliberately confined here: init/deinit latch the workspace
//! count from config (clamped to max_workspaces, 1 when workspaces are off)
//! and clear the per-workspace focus MRU, both through a file-private gate.
//! Every other model mutation belongs to its transition owner (actions/window/
//! focus); no shared writable token escapes this read facade. All model reads
//! go through core.isModelReady() (the one spelling), so boot order never
//! touches an undefined instance.

const std = @import("std");

const core = @import("core");
const constants = @import("constants");
const pipeline = @import("pipeline");
const model_mod = @import("model");

fn m() ?*const model_mod.Model {
    if (!core.isModelReady()) return null;
    return pipeline.model();
}

pub const Entry = struct {
    win: model_mod.WindowId,
    mask: model_mod.Mask,
    presence: model_mod.Presence = .present,
};

// Registry queries (facade)

/// The double-manage guard, in one place. A window can send multiple MapRequest
/// events (e.g. an unmap+remap race while the first is still processing);
/// without this check the model registration and property queries would fire
/// twice. Every admission path asks THIS, never a raw store lookup, so the
/// guard cannot drift out of parity between the direct and drain paths.
pub fn isManaged(win: u32) bool {
    const mm = m() orelse return false;
    return mm.store.has(win);
}

/// NOTE: rebuild-per-call is correct for correctness; a dirty flag
/// would need mutation hooks to track when the model store changes.
///
/// Read-only SNAPSHOT of the model registry into the CALLER's buffer,
/// returning the filled prefix. Do not retain across mutations.
///
/// The buffer is caller-owned on purpose: each caller passes its own State-
/// local array, so the aliasing is not expressible. Silently returning a
/// SHORT snapshot would read like "those are all the windows", which is the
/// bug this whole function is shaped to avoid, so an undersized buffer is an
/// assert rather than a clamp.
pub fn allWindowsInto(buf: []Entry) []const Entry {
    const mm = m() orelse return &.{};
    const n = mm.store.count();
    std.debug.assert(buf.len >= n);
    var i: usize = 0;
    var it = mm.store.iterator();
    while (it.next()) |row| : (i += 1) {
        buf[i] = .{ .win = row.key, .mask = row.val.mask, .presence = row.val.presence };
    }
    return buf[0..n];
}

// Per-workspace focus MRU (facade over model.ws[ws].focus_mru)
//
// Order convention: index 0 = most recent (matches model.setFocus's
// front-insert). Fallback selection reads the MRU through
// model.fallbackFocusCandidate.

fn clearFocusMru() void {
    if (!core.isModelReady()) return;
    const mm = pipeline.mut();
    for (&mm.ws) |*s| s.focus_mru.clear();
}

// Lifecycle / workspace count (latched from config at init)

var workspace_count: usize = 1;

/// Latch the workspace count directly from the live config, collapsing to a
/// single implicit workspace when the workspaces feature is disabled. The
/// u64 workspace bitmask caps the count; clamp (never crash) so a corrupt
/// config count can't overflow the mask in ReleaseFast. Callers before
/// core.init (headless test harnesses) keep the default.
fn latchWorkspaceCount() void {
    if (core.isReady()) {
        const cs = core.getState().config.workspaces;
        workspace_count = if (cs.enabled) @min(@as(usize, cs.count), constants.max_workspaces) else 1;
    }
}

pub fn init() void {
    latchWorkspaceCount();
    clearFocusMru();
}

/// Re-latch the workspace count after a config swap. The count is config-derived
/// and the `[workspaces] count`/`enabled` knobs are reloadable, but it used to
/// be read only at init: a hot reload kept the boot value for admission
/// clamping, the bar frame, and tag rendering until the next full restart.
pub fn reLatchWorkspaceCount() void {
    latchWorkspaceCount();
}

pub fn deinit() void {
    workspace_count = 1;
    clearFocusMru();
}

/// Read-through facade over `model.current`, the single source of truth:
/// every write path (actions.switchTo) mutates the model directly, so a
/// tracking query needs no separate storage. Null before pipeline.init
/// (callers default to workspace 0).
pub inline fn getCurrentWorkspace() ?u8 {
    // core.isModelReady() and nothing else: the model-live question has one
    // spelling, and the place that owns it documents why the gate exists.
    if (!core.isModelReady()) return null;
    return pipeline.model().current.index;
}

pub inline fn getWorkspaceCount() usize {
    return workspace_count;
}

/// True while the all_workspaces (Mod+5) all-view flag is active: every
/// workspace's windows are shown at once, and the bar collapses the tags into
/// a single cell. Reads the model, the single source of truth.
pub inline fn isAllViewActive() bool {
    const mm = m() orelse return false;
    return mm.all_view_active;
}

// Comptime workspace label table

/// Comptime number strings "1".."64" for workspace display labels.
pub const workspace_labels: [constants.max_workspaces][]const u8 = blk: {
    @setEvalBranchQuota(10_000);
    var labels: [constants.max_workspaces][]const u8 = undefined;
    for (&labels, 1..) |*label, i| label.* = std.fmt.comptimePrint("{d}", .{i});
    break :blk labels;
};

/// True when `win` has a tiled anchor (not floating, covering or
/// minimized); reads the model entry directly.
pub fn isTiledMode(win: u32) bool {
    const mm = m() orelse return false;
    const e = mm.store.get(win) orelse return false;
    return e.anchor == .tiled;
}

pub inline fn isOnCurrentWorkspace(win: u32) bool {
    if (getCurrentWorkspace()) |cur| {
        const mm = m() orelse return false;
        const e = mm.store.get(win) orelse return false;
        return model_mod.maskedOn(e.mask, core.WorkspaceId.fromIndex(cur));
    }
    return false;
}
