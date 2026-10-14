//! The layout-parameter actions (cycle/variant/primary/swap).
//! Each action is one model transition + one reconcile entry. The
//! shared transition tails (retile, prepareAndSetFocus) live
//! in `actions.zig`, the hub this file imports: the two files
//! form the window layer's intentional runtime-only import
//! cycle (the same hub-and-spoke shape check-layers.sh
//! documents for core<->window). Config → model seeding lives
//! in `core/loop/seed.zig`.

const std = @import("std");
const core = @import("core");
const constants = @import("constants");
const model_mod = @import("model");
const pipeline = @import("pipeline");
const focus = @import("focus");
const build_options = @import("build_options");
const tiling = @import("tiling_seam").tiling;

const actions = @import("actions");

pub fn cycleLayoutKind(dir: i32) void {
    const m = pipeline.mut();
    cycleActiveLayout(m, dir);
    actions.retile(.{ .full_redraw = true }, null);
}

/// Step the active layout within the config layout-name list (config order
/// is the cycle order), reproducing the old model.cycleLayout
/// wrap-around while resetting the variant index. Defaults/overrides always
/// come from config names, so the active kind is always resolvable.
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
    actions.retile(.{ .full_redraw = true }, null);
}

pub fn adjustPrimaryWidthAction(delta: f32) void {
    const m = pipeline.mut();
    model_mod.adjustPrimaryWidth(m, delta);
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
    p.secondary_balance = std.math.clamp(p.secondary_balance + delta, -constants.max_primary_swing, constants.max_primary_swing);
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
    model_mod.swapFocusedWithPrevious(m);
    var ft: focus.FocusTransition = .none;
    if (focus_swap) {
        // A no_input displaced window must not take model focus.
        ft = actions.prepareAndSetFocus(m, displaced, .tiling_operation);
    }
    pipeline.reconcileGrabFocus(.{}, ft, .before, null);
}
