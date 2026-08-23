//! Workspace state (WP6 residue).
//!
//! Switching, tagging, moving and all-view live in the model
//! (`actions.switchTo/tagToggle/moveWindowTo/allViewToggle` + sync); the
//! legacy engine this module once hosted is deleted. What remains is the
//! small state holder other modules read: the workspace list and which one
//! is current. `Workspace` keeps per-ws config override fields only because
//! workspaces.init() applies them once at boot; runtime layout truth is the
//! model's per-ws params.

const std = @import("std");

const core = @import("core");
const types = @import("types");
const constants = @import("constants");

const tracking = @import("tracking");
const build_options = @import("build_options");

pub const Workspace = struct {
    id: u8,
    /// Per-workspace layout-variant override from config; null = global default.
    variants: ?types.LayoutVariantOverride = null,
    /// Master-width override for master-stack layout; null = global default.
    master_width: ?f32 = null,
    /// Master-count override for master-stack layout; null = global default.
    master_count: ?u8 = null,
    /// Master-stack top/bottom balance override; null = even split (0).
    stack_balance: ?f32 = null,

    pub fn init(id: u8) Workspace {
        return .{ .id = id };
    }
};

pub const State = struct {
    workspaces: []Workspace,
    allocator: std.mem.Allocator,
};

var g_state: ?State = null;

pub inline fn getState() ?*State {
    return if (g_state) |*s| s else null;
}

/// Resolved layout + variant override for a single workspace, keyed by
/// workspace index in the flat lookup table built here.
const OverrideLookup = struct {
    variant: ?types.LayoutVariantOverride,
};

/// Applies per-workspace master-count/variant overrides from `cfg_tiling`.
///
/// `master_width` and `stack_balance` always reset to their global defaults
/// (null): neither has a config-file representation; they're pure runtime
/// state and genuinely should reset on reload.
pub fn applyWorkspaceOverrides(
    wss: []Workspace,
    cfg_tiling: *const types.TilingConfig,
) void {
    const max_ws = constants.max_workspaces;

    var master_count_lookup: [max_ws]?u8 = .{null} ** max_ws;
    for (cfg_tiling.workspace_master_count_overrides.items) |o| {
        if (o.workspace_idx < max_ws)
            master_count_lookup[o.workspace_idx] = o.count;
    }

    for (wss) |*ws| {
        const id = ws.id;
        ws.variants = if (id < max_ws)
            (if (lookupVariant(cfg_tiling, id)) |v| v else null)
        else
            null;
        ws.master_width = null;
        ws.stack_balance = null;
        ws.master_count = if (id < max_ws) master_count_lookup[id] else null;
    }
}

fn lookupVariant(cfg_tiling: *const types.TilingConfig, id: u8) ?types.LayoutVariantOverride {
    for (cfg_tiling.workspace_layout_overrides.items) |o| {
        if (o.workspace_idx == id) return o.variant;
    }
    return null;
}

/// Initializes global workspace state. Workspaces-disabled collapses to a
/// single implicit workspace; every switch/tag/move action already no-ops on
/// an out-of-range target, so nothing else needs to branch on this.
pub fn init() !void {
    const cs = core.getState();
    const count = if (cs.config.workspaces.enabled) cs.config.workspaces.count else 1;
    const wss = try cs.alloc.alloc(Workspace, count);

    for (wss, 0..) |*ws, i| {
        const id: u8 = @intCast(i);
        ws.* = Workspace.init(id);
    }
    applyWorkspaceOverrides(wss, &cs.config.tiling);

    tracking.setWorkspaceCount(count);

    g_state = .{
        .workspaces = wss,
        .allocator = cs.alloc,
    };
}

pub fn deinit() void {
    if (g_state) |*s| {
        s.allocator.free(s.workspaces);
    }
    g_state = null;
    tracking.setWorkspaceCount(0);
}

/// Clears per-workspace bookkeeping hooks for a window being unmanaged.
/// WP6: only the tracking/model removal remains meaningful.
pub fn removeWindow(win: u32) void {
    tracking.removeWindow(win);
}
