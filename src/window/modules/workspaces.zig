//! Complete workspaces feature: tag membership transitions.
//! A self-contained plugin over the model: switching, tagging, and moving are
//! model transitions (tag mask + tiled_order moves). The workspace count is
//! no longer forwarded here: the tracking facade latches it directly from
//! config at init. The per-workspace config-override store once held here was
//! dead weight (never read in production) and is gone; config overrides seed
//! the model params directly through actions.seedParamsFromConfig.

const model = @import("model");
const window = @import("window");
// Peers reach each other's hooks through the generated window registry,
// never by naming a sibling module: deleting a sibling only shortens the
// registry, and capabilities stay provider-agnostic.
const providerOf = window.providerOf;

/// Test-only; the production switch path is `actions.switchTo`.
pub fn switchTo(m: *model.Model, ws: model.WSId) void {
    m.current = ws;
}

pub fn moveWindowToWs(m: *model.Model, win: model.WindowId, ws: model.WSId) void {
    const e = m.store.getPtr(win) orelse return;
    if (ws.index >= m.ws.len) return; // bad target: indexing m.ws[ws] below would OOB (ReleaseFast)
    if (model.isPinned(e.*)) return; // pinned stays everywhere-visible

    // Refuse-before-mutate: full destination list cancels the move.
    const to_new_ws = if (e.home_ws) |hw| !hw.eql(ws) else true;
    if (e.home_ws != null and to_new_ws and m.ws[ws.index].tiled_order.len >= model.max_tiled_per_ws) return;

    transferFullscreenOnMove(m, win, ws);
    e.mask = model.bit(ws);
    if (e.home_ws) |old_h| {
        if (to_new_ws) {
            model.removeValue(&m.ws[old_h.index].tiled_order, win);
            _ = m.ws[ws.index].tiled_order.append(win);
            e.home_ws = ws;
        }
    }
}

/// Move `win`'s covering intent to `dest`, or drop it when a resident occupant
/// there swallows the transfer.
///
/// 12.8: the demote direction is EXPLICIT. This used to demote by calling
/// `toggleCovering`, whose correctness depended entirely on a guard the caller
/// had already proved -- `win` really was covering. Toggle is a two-edged verb:
/// if that proof were ever lost (a reordered check, a new caller, a provider
/// that reports covering differently) the "demote" silently became a fullscreen
/// ENTRY, and the failure is a window jumping to screen-covering, not a no-op.
/// `releaseCovering` only goes one way, so the wrong-direction mistake is
/// unrepresentable.
fn retargetOrDropFullscreen(m: *model.Model, win: model.WindowId, dest: model.WSId) void {
    const occupant = if (providerOf(.visibleCoveringOnWs)) |wm|
        wm.visibleCoveringOnWs.?(m, dest)
    else
        null;
    if (occupant != null and occupant != win) {
        if (providerOf(.releaseCovering)) |wm| {
            wm.releaseCovering.?(m, win);
        }
        return; // a resident owner swallows the transfer
    }
    if (providerOf(.moveCoveringTo)) |wm| {
        wm.moveCoveringTo.?(m, win, dest);
    }
}

/// Fullscreen record follows the move; a destination owner drops the mover
/// into de-fullscreen rather than clobbering the resident. Ghost records
/// (minimized-from-fullscreen) move their ws too, following the parked mask.
fn transferFullscreenOnMove(m: *model.Model, win: model.WindowId, ws: model.WSId) void {
    // 12.4: model query, not a peer-module dispatch. The dispatch returned
    // null when no covering module is bound, which made "is this window
    // covering" answer false in such a build -- while the model still held the
    // intent, and persisted.zig restores it across a session restart.
    const fws = model.coveringWsOf(m, win) orelse return;
    if (fws.eql(ws)) return;
    retargetOrDropFullscreen(m, win, ws);
}

/// Remove tag `ws`; the last remaining tag is protected (returns false).
/// Fullscreen-on-removed-ws transfers to the lowest remaining bit, or drops
/// into de-fullscreen when that destination is occupied.
pub fn tagRemove(m: *model.Model, win: model.WindowId, ws: model.WSId) bool {
    const e = m.store.getPtr(win) orelse return false;
    if (@popCount(e.mask) <= 1) return false;
    e.mask &= ~model.bit(ws);
    // 12.4: model query (see transferFullscreenOnMove).
    if (model.isCoveringOn(m, win, ws)) {
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
    e.mask = if (model.isPinned(e.*)) model.bit(m.current) else model.ALL_MASK;
}

pub fn allViewToggle(m: *model.Model) bool {
    m.all_view_active = !m.all_view_active;
    return m.all_view_active;
}

/// This module's window sub-system contribution: pure model transitions;
/// lifecycle is handled by the tracking facade's init (count latch) and
/// model state lives in the model.
pub const module: @import("contract").WindowModule = .{
    .name = "workspaces",
    .sendToWs = moveWindowToWs,
    .addToWs = tagAdd,
    .removeFromWs = tagRemove,
    .togglePin = pinToggle,
    .toggleAllView = allViewToggle,
};
