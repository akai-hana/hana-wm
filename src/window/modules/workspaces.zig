//! Workspace state transitions over the window model: tag membership, moves,
//! pin and all-view toggles. Pure model edits, no state of its own -- a
//! window's membership IS its tag mask plus its workspace's `tiled_order`,
//! so a move is one mask write plus two list edits. The only cross-module
//! rule is covering intent: a move or a removed tag retargets a covering
//! window to the new workspace, or drops it to de-fullscreen when that
//! destination already has an owner (dispatched through the registry, so
//! `fullscreen` is never named here). Workspace count and per-workspace
//! config overrides are owned elsewhere (tracking latches the count;
//! actions.seedParamsFromConfig seeds the params).

const model = @import("model");
const window = @import("window");
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
