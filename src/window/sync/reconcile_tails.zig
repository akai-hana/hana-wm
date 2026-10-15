//! The reconcile-ending transitions: the shared fact-bump + reconcile tail
//! (`retile`/`retileWithFallback`) every tiling action reconciles through,
//! plus the layout-parameter transitions that end in it.
//!
//! These live with the reconcile layer rather than under `src/tiling/`
//! because each is one MODEL transition plus one RECONCILE entry: the pure
//! tiling layer may not import `pipeline`/`core` (build.zig's
//! `assertPureLayerImports`), so a transition that reaches a server grab
//! cannot sit under it. The tiling ENGINE is still reached the same way —
//! through the build-generated `tiling_seam`, never by naming
//! `src/tiling/` — so a tree without the tiling subsystem keeps compiling
//! behind the `has_tiling` gates that already guard every one of these.

const std = @import("std");
const core = @import("core");
const log = @import("log");
const model_mod = @import("model");
const pipeline = @import("pipeline");
const focus = @import("focus");
const build_options = @import("build_options");
const contract = @import("tiling_contract");
const usable_area = @import("usable_area");
// Layout-name resolution for the state dump and the layout cycle, via the
// build-generated seam. The seam's top level also carries the has_tiling-gated
// op stubs (reorderTiled/stepTiled/...) so these transitions need no
// per-call guard of their own.
const tiling_seam = @import("tiling_seam");
const tiling = tiling_seam.tiling;

/// The four reconcile shapes a tiling action can ask for, as ONE axis.
///
/// A four-bool bag (`restack` / `full_redraw` / `with_focus` /
/// `bump_fullscreen`) resolved by a three-way if-chain would let a caller name
/// a combination that means nothing -- `with_focus` with no focus transition to
/// apply, or `restack` silently ignored on the plain path -- and would make the
/// dispatch unreadable without re-deriving the truth table. All four reachable
/// combinations are enumerated here instead, so the compiler rejects the
/// impossible ones and a reader sees the dispatch without reading the chain.
pub const RetileMode = enum {
    /// reconcileGrab: no focus, no restack.
    plain,
    /// reconcileGrab with force_restack: restack a window that is not taking focus.
    restack,
    /// reconcileGrabFocus: move focus, geometry only.
    focus,
    /// reconcileGrabFocus with force_restack: focus and restack together.
    focus_restack,
};

/// The two flags genuinely orthogonal to the reconcile shape: which geometry
/// fact to bump, and whether the fullscreen fact changes here.
pub const RetileOpts = struct {
    mode: RetileMode = .plain,
    full_redraw: bool = false,
    bump_fullscreen: bool = false,
};

/// The one fact-bump + reconcile entry for a tiling action.
///
/// Each mode names which facts IT bumps. The plain and restack modes
/// deliberately do NOT bump the window fact here: both reconcile through
/// `pipeline.reconcileGrab`, which owns that bump, so the actions
/// that route through them get the invariant without having to remember
/// it, and this one cannot double-bump on the way there. The focus variants
/// reconcile through `pipeline.reconcileGrabFocus`, which does not bump, so
/// those still bump the window fact here. That is the whole asymmetry, and
/// it is the one line of the function that looks surprising on purpose.
///
/// A fact bump is a counter increment with no X traffic, so doing it before
/// the reconcile is wire-identical to doing it after; actions with a pinned
/// side-effect ORDER keep their own tails instead of routing through here.
pub fn retile(opts: RetileOpts, ft: ?focus.FocusTransition) void {
    // `full_redraw` selects WHICH geometry fact to bump; without it only the
    // focus modes still bump the window fact themselves (their reconcile
    // entry does not), and plain/restack leave it entirely to reconcileGrab.
    if (opts.full_redraw) core.layout.bump() else if (opts.mode == .focus or opts.mode == .focus_restack) core.window.bump();
    if (opts.bump_fullscreen) core.fullscreen.bump();

    switch (opts.mode) {
        .plain => pipeline.reconcileGrab(.{}),
        .restack => pipeline.reconcileGrab(.{ .force_restack = true }),
        // Focus lands before geometry (focus-before). A null transition for a
        // focus mode is treated as the no-op transition instead of a panic, so
        // a caller that forgets the FocusTransition degrades to a plain
        // focus-mode retile rather than a crash.
        .focus => pipeline.reconcileGrabFocus(.{}, ft orelse .none, .before, null),
        .focus_restack => pipeline.reconcileGrabFocus(.{ .force_restack = true }, ft orelse .none, .before, null),
    }
}

/// Shared hide/close withdraw tail: when the withdrawn window was the
/// current workspace's covering occupant, bump the core fact so the bar (a
/// consumer) re-derives its screen claim before the reconcile reads the work
/// area; then hand focus to the fallback winner (or clear) and reconcile
/// focus + geometry under one grab.
pub fn retileWithFallback(m: *model_mod.Model, fs_current: bool, was_focused: bool) void {
    const ft: focus.FocusTransition = if (was_focused) focus.focusFallback(m, .tiling_operation) else .none;
    retile(.{ .mode = .focus_restack, .bump_fullscreen = fs_current }, ft);
}

/// Layout-parameter transitions: one model transition + one reconcile entry,
/// over the active workspace's `LayoutParams`.
/// Secondary-column balance swing cap for grow_stack adjustments (see
/// StackBoost.fromBalance).
const max_primary_swing: f32 = 6.0;

pub fn cycleLayoutKind(dir: i32) void {
    const m = pipeline.mut();
    cycleActiveLayout(m, dir);
    retile(.{ .full_redraw = true }, null);
}

/// Step the active layout within the config layout-name list (config order
/// is the cycle order), wrapping around while resetting the variant index.
/// Defaults/overrides always come from config names, so the active kind is
/// always resolvable.
fn cycleActiveLayout(m: *model_mod.Model, dir: i32) void {
    if (!build_options.has_tiling) return;
    const cfg = &core.getState().config.tiling;
    const p = &m.ws[m.current.index].params;
    p.kind = tiling.cycleKind(p.kind, dir, cfg.layouts.items);
    p.variant_idx = 0;
}

pub fn stepVariantDir(dir: i32) void {
    if (!build_options.has_tiling) return;
    const m = pipeline.mut();
    const p = &m.ws[m.current.index].params;
    const n = tiling.variantCount(p.kind);
    p.variant_idx = @intCast(model_mod.wrapIndex(p.variant_idx, dir, n));
    retile(.{ .full_redraw = true }, null);
}

pub fn adjustPrimaryWidthAction(delta: f32) void {
    const m = pipeline.mut();
    tiling_seam.adjustPrimaryWidth(m, delta);
    pipeline.reconcileGrab(.{});
}

pub fn adjustPrimaryCount(delta: i32) void {
    const m = pipeline.mut();
    const p = &m.ws[m.current.index].params;
    const next = std.math.clamp(@as(i32, p.primary_count) + delta, 1, model_mod.max_primary_count);
    p.primary_count = @intCast(next);
    pipeline.reconcileGrab(.{});
}

pub fn adjustSecondaryBalance(delta: f32) void {
    const m = pipeline.mut();
    const p = &m.ws[m.current.index].params;
    p.secondary_balance = std.math.clamp(p.secondary_balance + delta, -max_primary_swing, max_primary_swing);
    pipeline.reconcileGrab(.{});
}

/// swap_master: exchanges the focused window's tiled slot with the previously
/// focused window's (focus MRU), not the list head -- a slot in the middle of
/// a 3+ window workspace still swaps the pair the user expects. focus_swap
/// variant moves focus to the previously focused window BEFORE the reconcile
/// so the swapped-in window is focused on the first reconcile.
pub fn swapPrimaryAction(focus_swap: bool) void {
    const m = pipeline.mut();
    const focused = m.focused orelse return;
    const mru = m.ws[m.current.index].focus_mru.constSlice();
    if (mru.len < 2 or mru[1] == focused) return;
    const displaced = mru[1];
    tiling_seam.swapFocusedWithPrevious(m);
    var ft: focus.FocusTransition = .none;
    if (focus_swap) {
        // A no_input displaced window must not take model focus.
        ft = focus.prepareAndSetFocus(m, displaced, .tiling_operation);
    }
    pipeline.reconcileGrabFocus(.{}, ft, .before, null);
}

/// move_window_next/prev: rotate the focused window through the home list's
/// tiled order.
pub fn moveFocused(delta: i32) void {
    const m = pipeline.mut();
    const win = m.focused orelse return;
    // Modulo wrap (dwm stack rotate): stepping past either edge of the home
    // list's tiled order cycles back around, matching the focus-step parity.
    tiling_seam.stepTiled(m, win, delta);
    pipeline.reconcileGrab(.{});
}

/// Viewport transitions (scrollable-tile viewport over the layout params).
/// The viewport is resolved through the layout METADATA (slotWidth/maxOffset
/// hooks), so it rides the same `tiling_seam` reach as the cycles above.
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
    pipeline.reconcileGrab(.{});
}

/// Focus-change viewport snap: shift the viewport minimally so the focused
/// window's slot is fully on-usable area. Pure model/param mutation (no grab, no
/// reconcile). When the focused window is already fully on-screen (the common
/// case during focus cycling) nothing changes. The focus-cycle path runs this
/// as a duty INSIDE the focus transition's grab, so a Mod+k/Mod+j that scrolls
/// the viewport still lands focus + geometry in one grab+reconcile rather than
/// two.
fn snapViewportParamsToFocused() void {
    const vp = activeViewport() orelse return;
    const m = vp.m;
    const p = vp.p;
    const sc = vp.sc;
    const win = m.focused orelse return;

    var idx: ?usize = null;
    var n: usize = 0;
    for (m.ws[m.current.index].tiled_order.constSlice()) |w| {
        const e = m.store.get(w) orelse continue;
        if (!model_mod.taggedOn(e, m.current)) continue;
        if (w == win) idx = n;
        n += 1;
    }
    const i = idx orelse return;

    const wa = usable_area.workArea(core.getState().screen);
    const i64_slot_w: i64 = sc.slot_w;
    const slot_left = @as(i64, @intCast(i)) * i64_slot_w - p.viewport_offset;
    const slot_right = slot_left + i64_slot_w;
    const snapped = if (slot_left < 0)
        @as(i64, @intCast(i)) * i64_slot_w
    else if (slot_right > wa.width)
        @as(i64, @intCast(i)) * i64_slot_w + i64_slot_w - @as(i64, wa.width)
    else
        p.viewport_offset;
    commitViewport(p, sc, snapped, n);
}

/// Focus-cycle duty (see focus.grabFocusWithDuty): recompute the viewport for
/// the freshly focused window and let the enclosing reconcile pick it up.
pub fn snapViewportFocusedDuty() void {
    snapViewportParamsToFocused();
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
    const m = pipeline.mut();
    const p = &m.ws[m.current.index].params;
    const sc = viewportContext(m);
    if (!sc.active) return null;
    return .{ .m = m, .p = p, .sc = sc };
}
