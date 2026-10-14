//! Read-only accessors over the model singleton (the single source of truth
//! for windows and workspaces): is a window managed/tiled/on the current
//! workspace, is the all-view active, plus a caller-owned snapshot of the
//! registry for callers that sweep it and the comptime workspace label table
//! the bar renders.
//!
//! This file holds NO state and NO lifecycle: the workspace count is derived
//! from the live config on read, and the focus-MRU clear belongs to the model
//! owner (pipeline.clearFocusMru, invoked by the window layer's reset
//! discipline). Every model mutation belongs to its transition owner
//! (actions/window/focus); all model reads go through core.isModelReady()
//! (the one spelling), so boot order never touches an undefined instance.
//! It exists as a LIGHT read surface: core/loop, core/proc, input and bar
//! readers must not import window.zig (drags focus/admission/actions) or
//! pipeline's reconcile chain for a predicate.

const std = @import("std");

const core = @import("core");
const constants = @import("constants");
const pipeline = @import("pipeline");
const model_mod = @import("model");
const usable_area = @import("usable_area");

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

/// True for the null window, the root, or one of this layer's own X surfaces
/// (bar/output -- usable_area.isSurfaceWindow); never a valid focus or
/// manage target. The complement of isValidManagedWindow below.
pub inline fn isInvalidWindow(win: u32) bool {
    return win == 0 or win == core.getState().root or usable_area.isSurfaceWindow(win);
}

/// True when `win` is a real manage target we are tracking. The single
/// predicate for "is this window ours" (events.zig, reconcile paths);
/// window.zig re-exports this so `window.*` stays the stable facade for
/// callers outside the layer.
pub inline fn isValidManagedWindow(win: u32) bool {
    return !isInvalidWindow(win) and isManaged(win);
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

// Lifecycle / workspace count: derived on read from the live config (no
// latch, no re-latch on reload — see getWorkspaceCount).

/// Read-through facade over `model.current`, the single source of truth:
/// every write path (actions.switchTo) mutates the model directly, so a
/// read-only query needs no separate storage. Null before pipeline.init
/// (callers default to workspace 0).
pub inline fn getCurrentWorkspace() ?u8 {
    // core.isModelReady() and nothing else: the model-live question has one
    // spelling, and the place that owns it documents why the gate exists.
    if (!core.isModelReady()) return null;
    return pipeline.model().current.index;
}

/// The workspace count from the live config, derived on read: collapses to a
/// single implicit workspace when the workspaces feature is disabled. The
/// u64 workspace bitmask caps the count; clamp (never crash) so a corrupt
/// config count can't overflow the mask in ReleaseFast. Callers before
/// core.init (headless test harnesses) get the default of 1. A hot reload
/// that edits `[workspaces] count`/`enabled` is picked up by the next read —
/// no latch to re-arm.
pub inline fn getWorkspaceCount() usize {
    if (!core.isReady()) return 1;
    const cs = core.getState().config.workspaces;
    return if (cs.enabled) @min(@as(usize, cs.count), constants.max_workspaces) else 1;
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
