//! Window tracking queries over the model (the single source of truth for
//! windows/workspaces): counts, per-window predicates, sweep snapshots and
//! the workspace labels. A few boot/config-driven lifecycle bits (workspace
//! count, the init flag) are kept locally here.
//!
//! PENDING (no simplification action): border sweeps call
//! model.coveringOccupantOnWs per window (an O(N) store scan each); measured
//! (~480 ns/call) and deliberately uncached (IMPROVEMENTS §II) -- an
//! optimization question, not a simplification.

const std = @import("std");

const core = @import("core");
const constants = @import("constants");
const pipeline = @import("pipeline");
const model_mod = @import("model");

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
    return pipeline.initialized();
}

fn m() ?*const model_mod.Model {
    if (!modelReady()) return null;
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
/// The buffer is caller-owned on purpose. This used to be one module-level
/// array, which was the last global mutable scratch in the window layer: it
/// was correct only because every walk is short and non-reentrant, and any
/// future call made from inside another's loop would have had its snapshot
/// overwritten mid-iteration. A caller now passes its own State-local array,
/// so the aliasing is not expressible. The old `@min(count, buf.len)` clamp is
/// an assert instead: silently returning a SHORT snapshot reads like "those
/// are all the windows", which is the bug this whole function is shaped to
/// avoid.
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
    if (!modelReady()) return;
    const mm = pipeline.mut(&gate);
    for (&mm.ws) |*s| s.focus_mru.clear();
}

// Lifecycle / workspace count (latched from config at init)

var workspace_count: usize = 1;

/// Latch the workspace count directly from the live config, collapsing to a
/// single implicit workspace when the workspaces feature is disabled. The
/// u64 workspace bitmask caps the count; clamp (never crash) so a corrupt
/// config count can't overflow the mask in ReleaseFast. Callers before
/// core.init (headless test harnesses) keep the default.
pub fn init() void {
    if (core.isReady()) {
        const cs = core.getState().config.workspaces;
        workspace_count = if (cs.enabled) @min(@as(usize, cs.count), constants.max_workspaces) else 1;
    }
    clearFocusMru();
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
    // Via modelReady() rather than pipeline.initialized() directly: (11.9)
    // this file had two spellings of one question -- modelReady() and a bare
    // pipeline.initialized() -- so "is the model live?" was answered by
    // reading whichever of the two the author happened to be near. One
    // spelling, defined by the one place that explains why the gate exists.
    if (!modelReady()) return null;
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

// Workspace bitmask helpers

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
