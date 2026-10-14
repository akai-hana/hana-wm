//! The window-manager lifecycle actions: the map-request tail,
//! the post-geometry focus handoff, and the unmanage
//! tail. Each action is one model transition + one
//! sync entry. The fullscreen/covering orchestration
//! lives beside this file in covering.zig; the shared
//! transition tails (retile,
//! focusFallback, prepareAndSetFocus, the
//! covering-occupant queries) live in `actions.zig`,
//! the hub this file imports: the two files form the
//! window layer's intentional runtime-only import
//! cycle (the same hub-and-spoke shape check-layers.sh
//! documents for core<->window).

const core = @import("core");
const model_mod = @import("model");
const pipeline = @import("pipeline");
const focus = @import("focus");
const window = @import("window");
const query = @import("query");
const wincache = @import("wincache");
const contract = @import("contract");
const ledger = @import("ledger");
const log = @import("log");

const actions = @import("actions");

// spawn/map lifecycle

/// MapRequest tail. The caller's front-end (event masks, property queries)
/// has already run; this registers the window in
/// the model and lets ONE reconcile do map+pixel+bw+geom(+ABOVE winner) for
/// on-current spawns. Off-current spawns park by construction; sync sends
/// their border width at first show instead of immediately (invisible either
/// way; one less request).
///
/// `float_rect` admits the window already floating: the entry is registered
/// tiled (core membership is tiled-only) and then immediately detached to the
/// given rect with no home-list membership, mirroring detachTiledToFloating's
/// anchor/home_ws state. The reconcile tail then sizes it floating in one
/// reconcile, so a float-rule spawn never flashes a tiled slot.
///
/// `size_hints` is the admission drain's parsed WM_NORMAL_HINTS, threaded
/// through as a parameter because no model entry exists when the reply
/// drains. The model entry is the single store for size hints.
pub fn mapRequest(
    win: model_mod.WindowId,
    target_ws: u8,
    on_current: bool,
    float_rect: ?model_mod.Rect,
    size_hints: ?model_mod.SizeHints,
) void {
    const m = pipeline.mut();
    if (query.isManaged(win)) return; // double-manage guard, see query.isManaged

    // A defined refusal (store or home-list full) leaves the window
    // unmanaged.
    model_mod.register(m, win, if (on_current) null else model_mod.WSId.fromIndex(target_ws)) catch {
        log.warn("mapRequest: capacity full; window 0x{x} left unmanaged", .{win});
        // Evict, or a refused window's XID lingers in the cache forever: XIDs
        // are recycled, so the next client to be handed this id would inherit
        // a stale title/child entry and read the wrong window.
        wincache.removeWindow(win);
        return;
    };
    // Install the admission drain's WM_NORMAL_HINTS on the fresh entry (no
    // entry existed when the reply drains, hence the parameter above).
    const e = m.store.getPtr(win);
    if (e) |ep| {
        if (size_hints) |h| ep.size_hints = h;
    }

    // Float-rule admission: detach the entry from its tiled slot before the
    // fifo placement runs (which assumes a home slot, nonsensical for a
    // floating window). The anchor/home_ws state mirrors toggleFloating's
    // detach, and the reconcile tail applies the rect in the same reconcile.
    if (float_rect) |rect| {
        if (e) |ep| {
            if (ep.home_ws) |home| model_mod.removeValue(&m.ws[home.index].tiled_order, win);
            ep.anchor = .{ .floating = rect };
            ep.home_ws = null;
        }
    } else {
        // Primary-fifo variant spawn placement (moved out of model.register;
        // it is SPAWN policy, not membership policy): a new window takes the
        // primary-column head slot, and the previous head window drops one
        // slot.
        {
            // Clamp the requested home workspace so a misconfigured target
            // can't index past the `ws` array in ReleaseFast (defense in depth;
            // the MapRequest front-end already resolves/clamps the target).
            const home: model_mod.WSId = if (on_current)
                m.current
            else
                window.clampToValidWorkspace(target_ws, model_mod.WSId.fromIndex(m.current.index));
            const p = &m.ws[home.index].params;
            // Same policy restated at the spawn site: driven by the active
            // module's fifo_variant metadata (the head slot binds variant
            // index 1).
            if (contract.moduleOf(p.kind)) |mv| {
                if (mv.fifo_variant) |v| {
                    if (p.variant_idx == v and m.ws[home.index].tiled_order.len > 1)
                        model_mod.reorderTiled(m, win, 0);
                }
            }
        }
    }
    focus.initWindowGrabs(win); // protocol-side keygrabs, both paths did this
    core.window.bump(); // a window was admitted

    if (!on_current) return;

    // Focus prep before the model write (same rule as focusFallback): a
    // spawned no_input window must never take model focus -- its focus
    // protocol can't land, so marking it focused would leave borders and
    // stacking claiming a focus X will never deliver. X input focus lands
    // AFTER the reconcile, inside the same grab: the window must be mapped
    // before xcb_set_input_focus, so both map+focus land under one grab.
    const ft = actions.prepareAndSetFocus(m, win, .window_spawn);
    pipeline.reconcileGrabFocus(.{}, ft, .after, null);
}

/// The tail shared with session adoption: put X input focus on whatever the
/// model says is focused, inside one grab AFTER geometry, or -- when nothing is
/// focused -- reconcile under the grab with no focus handoff.
///
/// Adopted windows are already mapped, so the mapRequest path's ordering
/// ("map, then focus, in the same grab") is satisfied here for the same
/// reason. Both callers need this to be identical: a session that adopts 40
/// windows and then focuses differently from a session that spawned them is a
/// bug that only shows up after a re-exec.
pub fn focusAfterGeometry() void {
    if (pipeline.model().focused) |focused| {
        const ft = actions.prepareAndSetFocus(pipeline.mut(), focused, .window_spawn);
        pipeline.reconcileGrabFocus(.{}, ft, .after, null);
    } else {
        pipeline.reconcileGrab(.{});
    }
}

/// Unmanage tail: close/destroy/unmap of a managed window. Local
/// bookkeeping (covering record, caches, sub-system removes) has already
/// run; this drops the model entry and re-focuses. Inactive-workspace
/// geometry repairs ride the same global LastSent diff.
pub fn unmanage(win: model_mod.WindowId) void {
    const m = pipeline.mut();
    // Covering and focus truth must be read BEFORE the unregister below
    // drops the model entry (after which no store query could recover it):
    // an onWindowGone binder mutating model focus or the covering record
    // would make them unreadable. The hooks that fire on this path touch
    // module-local stores only.
    const was_fs_current = if (model_mod.coveringWsOf(m, win)) |ws_id| ws_id.eql(m.current) else false;
    const was_focused = m.focused == win;

    model_mod.unregister(m, win);
    ledger.forget(win); // X ids recycle; stale LastSent must not survive

    // Closing the current workspace's covering occupant releases the area;
    // retileWithFallback bumps the core fact so the bar reacts.
    actions.retileWithFallback(m, was_fs_current, was_focused);
}
