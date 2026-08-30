//! Complete workspaces feature: tag membership transitions + per-workspace
//! config-override types.
//! A self-contained plugin over the model: switching, tagging, and moving are
//! model transitions (tag mask + tiled_order moves), and the workspace list
//! with its per-ws config overrides applied once at boot is held here.

const std = @import("std");

const core = @import("core");
const types = @import("types");
const constants = @import("constants");

const tracking = @import("tracking");
const model = @import("model");
const build_options = @import("build_options");

pub const Workspace = struct {
    id: u8,
    /// Per-workspace layout-variant value-string override from config;
    /// null = global default. Borrows the owning config override's dupe.
    variants: ?[]const u8 = null,
    /// Master-count override for master-stack layout; null = global default.
    master_count: ?u8 = null,

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

/// Applies per-workspace master-count/variant overrides from `cfg_tiling`.
///
/// `primary_width` and `secondary_balance` have no config-file representation;
/// they are pure runtime state living only in the model's per-ws params, so
/// nothing here touches them.
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
        ws.master_count = if (id < max_ws) master_count_lookup[id] else null;
    }
}

/// Last matching override wins: duplicate entries for one workspace now
/// resolve identically across ALL per-ws fields; this lookup, the
/// master-count loop below, and actions.seedParamsFromConfig's layout lookup
/// all use loop-overwrite (last-wins).
fn lookupVariant(cfg_tiling: *const types.TilingConfig, id: u8) ?[]const u8 {
    var found: ?[]const u8 = null;
    for (cfg_tiling.workspace_layout_overrides.items) |o| {
        if (o.workspace_idx == id) found = o.variant;
    }
    return found;
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
/// Facade kept for module boundary; inlined would be equivalent.
pub fn removeWindow(win: u32) void {
    tracking.removeWindow(win);
}

pub fn switchTo(m: *model.Model, ws: model.WSId) void {
    m.current = ws;
}

pub fn moveWindowToWs(m: *model.Model, win: model.WindowId, ws: model.WSId) void {
    const e = m.store.getPtr(win) orelse return;
    if (e.mask == model.ALL_MASK) return; // pinned stays everywhere-visible
    if (build_options.has_minimize) {
        if (@import("minimize").isMinimized(m, win)) {
            e.mask = model.bit(ws); // record follows the move
            return;
        }
    }
    // Fullscreen record follows the move; a destination owner drops this one
    // into de-fullscreen (toggle OFF) rather than clobbering the resident.
    // Ghost records (minimized-from-fullscreen) move their ws too, following
    // the parked window's mask.
    if (build_options.has_fullscreen) {
        const fmod = @import("fullscreen");
        if (fmod.isFullscreenMode(m, win)) {
            const fws = fmod.fullscreenWsOf(m, win).?;
            if (fws != ws) {
                if (fmod.fullscreenOccupied(m, win, ws)) {
                    _ = fmod.toggleFullscreen(m, win);
                } else {
                    fmod.moveFullscreenTo(m, win, ws);
                }
            }
        }
    }
    e.mask = model.bit(ws);
    const h: ?model.WSId = e.home_ws;
    if (h) |old_h| {
        if (old_h != ws) {
            // Refuse-before-mutate: a full destination list cancels the
            // move instead of stranding the window home-less.
            if (m.ws[ws].tiled_order.len >= model.max_tiled_per_ws) {
                e.mask = model.bit(old_h);
                return;
            }
            model.removeValue(&m.ws[old_h].tiled_order, win);
            _ = m.ws[ws].tiled_order.append(win);
            e.home_ws = ws;
        }
    }
}

/// Remove tag `ws`; the last remaining tag is protected (returns false).
/// Fullscreen-on-removed-ws transfers to the lowest remaining bit, or drops
/// into de-fullscreen when that destination is occupied.
pub fn tagRemove(m: *model.Model, win: model.WindowId, ws: model.WSId) bool {
    const e = m.store.getPtr(win) orelse return false;
    if (@popCount(e.mask) <= 1) return false;
    e.mask &= ~model.bit(ws);
    if (build_options.has_fullscreen) {
        const fmod = @import("fullscreen");
        if (fmod.isFullscreenOnWs(m, win, ws)) {
            const dest = model.lowestBit(e.mask);
            if (fmod.fullscreenOccupied(m, win, dest)) {
                _ = fmod.toggleFullscreen(m, win);
            } else {
                fmod.moveFullscreenTo(m, win, dest);
            }
        }
    }
    return true;
}

pub fn tagAdd(m: *model.Model, win: model.WindowId, ws: model.WSId, protect_current: bool) void {
    const e = m.store.getPtr(win) orelse return;
    e.mask |= model.bit(ws);
    if (protect_current) e.mask |= model.bit(m.current);
}

pub fn pinToggle(m: *model.Model, win: model.WindowId) void {
    const e = m.store.getPtr(win) orelse return;
    e.mask = if (e.mask == model.ALL_MASK) model.bit(m.current) else model.ALL_MASK;
}

pub fn allViewToggle(m: *model.Model) bool {
    m.all_view_active = !m.all_view_active;
    return m.all_view_active;
}

/// This module's window sub-system contribution: lifecycle only, since
/// workspace state lives in the model.
pub const module: @import("plugin").WindowModule = .{
    .init = init,
    .deinit = deinit,
    .sendToWs = moveWindowToWs,
    .addToWs = tagAdd,
    .removeFromWs = tagRemove,
    .togglePin = pinToggle,
    .toggleAllView = allViewToggle,
};
