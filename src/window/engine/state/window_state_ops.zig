//! Window-state admission mutations over the model: `register` (adopt a new
//! window into the store + a tiled slot), `unregister` (drop it everywhere),
//! and `applyParamsDelta` (apply a layout module's pre-reconcile params
//! delta). The model keeps the struct and pure queries; these mutations
//! live with the window state that owns admission.

const std = @import("std");
const model = @import("model");

/// Adopts `win` into the model store and a tiled slot on `hint_ws` (or the
/// current workspace). Capacity refusal with rollback, BEFORE any observable
/// state change.
pub fn register(m: *model.Model, win: model.WindowId, hint_ws: ?model.WSId) error{CapacityFull}!void {
    if (m.store.has(win)) return;
    const target: model.WSId = hint_ws orelse m.current;
    // Bounds-checked: `ws` is a FIXED [max_workspaces] array, so an
    // out-of-range target (reachable from a lenient `WorkspaceId.fromIndex`
    // on a config path) would index out of the model. Fail at the boundary
    // that created the id, not silently on the array read below.
    std.debug.assert(target.isValid());
    _ = m.store.put(win, .{ .mask = model.bit(target), .anchor = .tiled }) catch |e| return e;
    if (!m.ws[target.index].tiled_order.append(win)) {
        _ = m.store.remove(win);
        return error.CapacityFull;
    }
}

/// Drops `win` from the store and every workspace list.
pub fn unregister(m: *model.Model, win: model.WindowId) void {
    if (!m.store.remove(win)) return;
    // Scrub EVERY workspace's lists: a stale id left in any tiled_order would
    // make a later layout pass move or draw a window the store no longer has,
    // and there is no way to detect that from the entry once it is gone.
    // Whole-model scan, provably idempotent.
    for (&m.ws) |*s| {
        model.removeValue(&s.tiled_order, win);
        model.removeValue(&s.focus_mru, win);
    }
    if (m.focused == win) m.focused = null;
}

/// Applies a layout module's pre-reconcile delta to `ws`'s params, IN
/// PLACE, through the model.
///
/// The hook is value-in/value-out (`old -> new`): a raw `*LayoutParams`
/// taken from the model would be an un-gated mutation channel into it --
/// anything holding it could rewrite a field the model owns (or reach
/// another workspace) with no check. Routing the write through here means
/// the model decides whether `ws` is addressable, and the pipeline holds no
/// pointer into model state at all.
pub fn applyParamsDelta(m: *model.Model, ws: model.WSId, delta: model.LayoutParams) void {
    std.debug.assert(ws.isValid());
    m.ws[ws.index].params = delta;
}
