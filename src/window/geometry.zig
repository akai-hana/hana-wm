//! The geometry actions: tiling<->floating transitions,
//! the drag commands (registry dispatch loops), the
//! focus-step, and the viewport family (step, focus-snap
//! duty, the layout-metadata viewport context). Each
//! action is one model transition + one sync entry. The
//! shared transition tails (retile, the covering-mode
//! query) live in `actions.zig`, the hub this file
//! imports: the two files form the window layer's
//! intentional runtime-only import cycle (the same
//! hub-and-spoke shape check-layers.sh documents for
//! core<->window).

const std = @import("std");
const core = @import("core");
const model_mod = @import("model");
const pipeline = @import("pipeline");
const build_options = @import("build_options");
const contract = @import("contract");
const ledger = @import("ledger");
const usable_area = @import("usable_area");

const actions = @import("actions");
const gate = actions.gate;

/// Registry lookup for the hook `field` (see `contract.providerOf`), null when
/// no module binds it; canonical scan lives in window.providerOf.
const providerOf = actions.providerOf;

const dispatchAll = actions.dispatchAll;
const dispatchFirstTrue = actions.dispatchFirstTrue;
const isCoveringMode = actions.isCoveringMode;

// tiling ops / drag

/// Shared tiled->floating detach (toggleFloating/detachToFloating): seeds the
/// floating anchor from LastSent geometry and drops the home-list membership.
fn detachTiledToFloating(m: *model_mod.Model, e: *model_mod.Entry, win: model_mod.WindowId) bool {
    const r = ledger.lastRectFor(win) orelse return false;
    if (e.home_ws) |home| model_mod.removeValue(&m.ws[home.index].tiled_order, win);
    e.anchor = .{ .floating = r };
    e.home_ws = null; // no longer in tiled_order
    return true;
}

/// toggle_floating_window. Tiled->floating seeds the rect from the window's
/// current on-screen geometry (LastSent); floating->tiled re-enters the home
/// list at the primary-column head via the ordinary tiling order.
pub fn toggleFloating(win: model_mod.WindowId) void {
    const m = pipeline.mut(&gate);
    const e = m.store.getPtr(win) orelse return;
    // A window carrying a covering record keeps its anchor: the record owns
    // the screen while covering, and a ghost (parked) record must survive
    // the command so the later toggle-off restores the ORIGINAL anchor, not
    // a flipped one.
    if (isCoveringMode(m, win)) return;
    switch (e.anchor) {
        .tiled => {
            if (!detachTiledToFloating(m, e, win)) return;
        },
        .floating => |r| {
            e.anchor = .tiled;
            if (!repairStrandedHome(m, e, win)) {
                // The destination tiled list was full, so the window could not
                // be re-seated: keep it floating with its original rect rather
                // than leaving it anchored-tiled with no seat.
                e.anchor = .{ .floating = r };
                return;
            }
        },
    }
    actions.retile(.{ .mode = .restack }, null);
}

/// Defense in depth (the stranded-slot bug class): repair a tiled-anchored
/// window that has no home-list entry instead of leaving it a
/// tiling-invisible window this toggle could never fix again.
fn repairStrandedHome(m: *model_mod.Model, e: *model_mod.Entry, win: model_mod.WindowId) bool {
    if (model_mod.findHome(m, win) != null) return true;
    if (model_mod.lowestBit(e.mask)) |h| {
        // Append fails when the destination tiled list is full; only commit
        // home_ws when the seat actually got an entry, and report failure so
        // the caller can revert the anchor. Committing home_ws anyway would
        // leave the window anchored-tiled with no seat -- the exact stranded
        // state this function exists to prevent.
        if (!m.ws[h.index].tiled_order.append(win)) return false;
        e.home_ws = h;
    }
    return true;
}

/// Drag tick (no grab; E.6): targeted reconcile — sends ONLY the dragged
/// window's geometry (1 XCB call) instead of replaying all windows. Called
/// from the drag provider's updateDrag on every motion event.
pub fn dragRect(win: model_mod.WindowId, r: model_mod.Rect) void {
    const wm_prov = providerOf(.setFloatingRect) orelse return;
    const m = pipeline.mut(&gate);
    wm_prov.setFloatingRect.?(m, win, r);
    pipeline.dragTick(win);
}

/// First motion of a drag on a tiled window detaches it to floating at its
/// current geometry (pending-float detach + remove + retile).
pub fn detachToFloating(win: model_mod.WindowId) bool {
    const m = pipeline.mut(&gate);
    const e = m.store.getPtr(win) orelse return false;
    if (isCoveringMode(m, win)) return false;
    if (e.anchor != .tiled) return false;
    if (!detachTiledToFloating(m, e, win)) return false;
    pipeline.reconcileGrab();
    return true;
}

// floating drag commands (registry loops)
//
// Uniform dispatch loops over the compiled-in sub-system set: a module that
// provides the hook runs it, and a tree without the module simply has no
// provider, so the loop no-ops; dropping a module file (and its entire
// subtree) leaves zero residue here.

/// Pointer-press drag begin.
pub fn startDrag(win: model_mod.WindowId, button: u8, x: i16, y: i16) void {
    dispatchAll(.startDrag, .{ win, button, x, y });
}

/// Drag end: commits any in-flight detach/rect.
pub fn stopDrag() void {
    dispatchAll(.stopDrag, .{});
}

/// Motion tick during an active drag.
pub fn updateDrag(x: i16, y: i16) void {
    dispatchAll(.updateDrag, .{ x, y });
}

/// Whether a floating drag/resize is currently in flight. In practice only
/// one module provides this hook, so the loop's first true wins.
pub fn isDragging() bool {
    return dispatchFirstTrue(.isDragging, .{});
}

/// Whether `win` is the current resize target (drag guard).
pub fn isResizingWindow(win: model_mod.WindowId) bool {
    return dispatchFirstTrue(.isResizingWindow, .{win});
}

/// Last committed drag rect, for resize-path geometry replay. Zero rect
/// fallback when no module provides the hook, matching the old no-floating
/// default.
pub fn getDragLastRect() model_mod.Rect {
    const zero = model_mod.Rect{ .x = 0, .y = 0, .width = 0, .height = 0 };
    const wm_prov = providerOf(.getDragLastRect) orelse return zero;
    return wm_prov.getDragLastRect.?();
}

/// Cancels any active drag targeting `win` (unmanage path).
pub fn cancelDragForWindow(win: model_mod.WindowId) void {
    dispatchAll(.cancelDragForWindow, .{win});
}

pub fn moveFocused(delta: i32) void {
    const m = pipeline.mut(&gate);
    const win = m.focused orelse return;
    // Modulo wrap (dwm stack rotate): stepping past either edge of the home
    // list's tiled order cycles back around, matching the focus-step parity.
    model_mod.stepTiled(m, win, delta);
    pipeline.reconcileGrab();
}

/// Clamp an updated viewport offset to the layout's content span and stamp
/// the tiled-count snapshot the prefetch expects after a step.
fn commitViewport(p: *model_mod.LayoutParams, sc: ViewportContext, offset: i64, count: usize) void {
    // maxOffset can legitimately return negative (content narrower than the
    // workarea math still leaves a negative scroll bound), and clamp asserts
    // lower<=upper in safe builds. Floor the upper bound at 0 so an unusable
    // negative range collapses to the single offset 0 instead of panicking.
    p.viewport_offset = @intCast(std.math.clamp(offset, 0, @max(0, sc.max_off)));
    p.viewport_prev_count = @intCast(count);
}

/// scroll_view_left/right: one slot per step, clamped to content. The spawn
/// snap-right duty lives in preReconcileDuties (pipeline choke point).
pub fn viewportStep(dir: i32) void {
    const vp = activeViewport() orelse return;
    const p = vp.p;
    const sc = vp.sc;
    commitViewport(p, sc, p.viewport_offset + dir * sc.slot_w, sc.tiled_count);
    pipeline.reconcileGrab();
}

/// Focus-change viewport snap: shift the viewport minimally so the focused
/// window's slot is fully on-usable area. Pure model/param mutation (no grab, no
/// reconcile); returns whether the offset or tiled count actually changed.
/// When the focused window is already fully on-screen (the common case during
/// focus cycling) both are unchanged and the caller can skip all geometry
/// work. The focus-cycle path runs this as a duty INSIDE the focus transition's
/// grab, so a Mod+k/Mod+j that scrolls the viewport still lands focus + geometry
/// in one grab+reconcile rather than two.
fn snapViewportParamsToFocused() bool {
    const vp = activeViewport() orelse return false;
    const m = vp.m;
    const p = vp.p;
    const sc = vp.sc;
    const win = m.focused orelse return false;

    var idx: ?usize = null;
    var n: usize = 0;
    for (m.ws[m.current.index].tiled_order.constSlice()) |w| {
        const e = m.store.get(w) orelse continue;
        if (!model_mod.taggedOn(e, m.current)) continue;
        if (w == win) idx = n;
        n += 1;
    }
    const i = idx orelse return false;

    const wa = usable_area.workArea(core.getState().screen);
    const i64_slot_w: i64 = sc.slot_w;
    const slot_left = @as(i64, @intCast(i)) * i64_slot_w - p.viewport_offset;
    const slot_right = slot_left + i64_slot_w;
    const old_offset = p.viewport_offset;
    const snapped = if (slot_left < 0)
        @as(i64, @intCast(i)) * i64_slot_w
    else if (slot_right > wa.width)
        @as(i64, @intCast(i)) * i64_slot_w + i64_slot_w - @as(i64, wa.width)
    else
        p.viewport_offset;
    const old_count = p.viewport_prev_count;
    commitViewport(p, sc, snapped, n);
    return p.viewport_offset != old_offset or p.viewport_prev_count != old_count;
}

/// Focus-cycle duty (see focus.grabFocusWithDuty): recompute the viewport for
/// the freshly focused window and let the enclosing reconcile pick it up.
/// Signature is void to match the pipeline duty pointer; the change signal is
/// not needed because the transition's reconcile always runs.
pub fn snapViewportFocusedDuty() void {
    _ = snapViewportParamsToFocused();
}

const ViewportContext = struct {
    active: bool,
    tiled_count: usize,
    slot_w: i32,
    max_off: i32,
};

const viewport_inactive: ViewportContext =
    .{ .active = false, .tiled_count = 0, .slot_w = 0, .max_off = 0 };

/// Viewport context for the active layout, resolved through the layout
/// metadata: a layout "has a viewport" iff it registers the slotWidth/
/// maxOffset hooks. Returns inactive for layouts without a viewport or an
/// out-of-range kind.
fn viewportContext(m: *const model_mod.Model) ViewportContext {
    if (!build_options.has_tiling) return viewport_inactive;
    const p = &m.ws[m.current.index].params;
    const md = contract.moduleOf(p.kind) orelse return viewport_inactive;
    if (md.slotWidth == null or md.maxOffset == null) return viewport_inactive;
    const n = model_mod.tiledCountOnWs(m, m.current);
    const wa = usable_area.workArea(core.getState().screen);
    const slot_w = md.slotWidth.?(wa.width);
    const max_off = md.maxOffset.?(n, slot_w, wa.width);
    return .{ .active = true, .tiled_count = n, .slot_w = slot_w, .max_off = max_off };
}

fn activeViewport() ?struct {
    m: *model_mod.Model,
    p: *model_mod.LayoutParams,
    sc: ViewportContext,
} {
    if (!build_options.has_tiling) return null;
    // No `has_bar` gate: the viewport clamps to `usable_area.workArea`,
    // which is the full screen without a bar, so a scroll layout works
    // headless too -- the clamp target is bar-independent.
    const m = pipeline.mut(&gate);
    const p = &m.ws[m.current.index].params;
    const sc = viewportContext(m);
    if (!sc.active) return null;
    return .{ .m = m, .p = p, .sc = sc };
}
