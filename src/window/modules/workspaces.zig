//! Complete workspaces feature: tag membership transitions + the workspace
//! count for the tracking facade.
//! A self-contained plugin over the model: switching, tagging, and moving are
//! model transitions (tag mask + tiled_order moves), and the workspace count
//! (config-driven) is forwarded to tracking at init. The per-workspace
//! config-override store once held here was dead weight (never read in
//! production) and is gone; config overrides seed the model params directly
//! through actions.seedParamsFromConfig.

const core = @import("core");

const tracking = @import("tracking");
const model = @import("model");
const build_options = @import("build_options");

/// Initializes global workspace state. Workspaces-disabled collapses to a
/// single implicit workspace; every switch/tag/move action already no-ops on
/// an out-of-range target, so nothing else needs to branch on this.
pub fn init() !void {
    const cs = core.getState();
    const count = if (cs.config.workspaces.enabled) cs.config.workspaces.count else 1;
    tracking.setWorkspaceCount(count);
}

pub fn deinit() void {
    tracking.setWorkspaceCount(0);
}

/// Test-only; the production switch path is `actions.switchTo`.
pub fn switchTo(m: *model.Model, ws: model.WSId) void {
    m.current = ws;
}

pub fn moveWindowToWs(m: *model.Model, win: model.WindowId, ws: model.WSId) void {
    const e = m.store.getPtr(win) orelse return;
    if (ws >= m.ws.len) return; // bad target: indexing m.ws[ws] below would OOB (ReleaseFast)
    if (e.mask == model.ALL_MASK) return; // pinned stays everywhere-visible

    // Refuse-before-mutate: full destination list cancels the move.
    const h: ?model.WSId = e.home_ws;
    if (h) |old_h| if (old_h != ws and m.ws[ws].tiled_order.len >= model.max_tiled_per_ws) return;

    if (build_options.has_minimize and @import("minimize").isMinimized(m, win)) e.mask = model.bit(ws); // record follows the move
    transferFullscreenOnMove(m, win, ws);
    e.mask = model.bit(ws);
    if (h) |old_h| {
        if (old_h != ws) {
            model.removeValue(&m.ws[old_h].tiled_order, win);
            _ = m.ws[ws].tiled_order.append(win);
            e.home_ws = ws;
        }
    }
}

fn retargetOrDropFullscreen(m: *model.Model, win: model.WindowId, dest: model.WSId) void {
    const fmod = @import("fullscreen");
    if (fmod.fullscreenOccupied(m, win, dest)) {
        _ = fmod.toggleFullscreen(m, win);
    } else {
        fmod.moveFullscreenTo(m, win, dest);
    }
}

/// Fullscreen record follows the move; a destination owner drops the mover
/// into de-fullscreen rather than clobbering the resident. Ghost records
/// (minimized-from-fullscreen) move their ws too, following the parked mask.
fn transferFullscreenOnMove(m: *model.Model, win: model.WindowId, ws: model.WSId) void {
    if (!build_options.has_fullscreen) return;
    const fmod = @import("fullscreen");
    if (!fmod.isFullscreenMode(m, win)) return;
    const fws = fmod.fullscreenWsOf(m, win).?;
    if (fws == ws) return;
    retargetOrDropFullscreen(m, win, ws);
}

/// Remove tag `ws`; the last remaining tag is protected (returns false).
/// Fullscreen-on-removed-ws transfers to the lowest remaining bit, or drops
/// into de-fullscreen when that destination is occupied.
pub fn tagRemove(m: *model.Model, win: model.WindowId, ws: model.WSId) bool {
    const e = m.store.getPtr(win) orelse return false;
    if (@popCount(e.mask) <= 1) return false;
    e.mask &= ~model.bit(ws);
    if (build_options.has_fullscreen and @import("fullscreen").isFullscreenOnWs(m, win, ws)) {
        const dest = model.lowestBit(e.mask) orelse unreachable;
        retargetOrDropFullscreen(m, win, dest);
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
