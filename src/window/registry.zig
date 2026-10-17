//! The window layer's binding-layer dispatch surface: five thin wrappers
//! over the generated window-module registry (`window_modules`), plus two
//! named reads (covering occupant, parked predicate) that wrap one-line
//! provider lookups every consumer would otherwise restate.
//!
//! BINDING-LAYER SURFACE: the five dispatch wrappers below
//! (providerOf/callHook/callHookBool/dispatchAll/dispatchFirstTrue) are thin
//! on purpose. Collapsing them would spread providerOf + @call pairs across
//! every dispatch call site, and folding them back into contract would
//! re-create comptime-generic helpers that the two-primitive dispatch family
//! deliberately does not carry. They stay five: do not collapse further.
//!
//! Within `src/window/**` callers import `registry` directly (one hop to the
//! definition); outside the layer `window.zig` re-exports them so
//! `window.*` stays the stable external facade events.zig, bar/state.zig,
//! input and the tests import.

const std = @import("std");

const contract = @import("window_contract");
const dispatch = @import("contract_dispatch");
const model = @import("model");
const window_mods = @import("window_modules").modules;

/// Registry lookup for the hook `field` (see `dispatch.providerOf`), null when
/// no module binds it; shared by the whole window layer.
/// Thin typed forward onto the single canonical `contract` dispatch family
/// (two primitives: providerOf + callAll).
pub fn providerOf(
    comptime field: std.meta.FieldEnum(contract.WindowModule),
) ?*const contract.WindowModule {
    return dispatch.providerOf(contract.WindowModule, window_mods[0..], field);
}

/// First-match dispatch: invokes the first module that binds `field`, nothing
/// when none does (the "adopt by name" path for single-binder hooks, see
/// `single_binder_hooks`). providerOf + invoke stated here -- the shape had
/// this one consumer, so it lives at the binding layer rather than as a
/// comptime-generic helper in contract).
pub fn callHook(
    comptime field: std.meta.FieldEnum(contract.WindowModule),
    args: anytype,
) void {
    if (providerOf(field)) |m| @call(.auto, @field(m, @tagName(field)).?, args);
}

/// Like callHook but returns the first provider's hook result; false when no
/// module binds the hook.
pub fn callHookBool(
    comptime field: std.meta.FieldEnum(contract.WindowModule),
    args: anytype,
) bool {
    if (providerOf(field)) |m| return @call(.auto, @field(m, @tagName(field)).?, args);
    return false;
}

/// Fan-out FIRE COUNT for the `onWindowGone` lifecycle audit: every hook
/// binding that name is idempotent (find-then-clear), so MODULE STATE cannot
/// distinguish one fire from two — only a count can pin "a managed destroy
/// fires the hook exactly once" (P1-19's X-gated test, which is what makes
/// P1-40's removal of the events.zig pre-fire checkable: a re-added second
/// fire site regresses this counter even though every hook stays happy). The
/// count lives at the dispatch PRIMITIVE so it sees every path — the
/// `window.*` facade re-export, in-layer direct `registry.dispatchAll`
/// calls, and module-to-module re-dispatch — however the next call site is
/// written. Increment is comptime-gated on this one field (every other hook
/// pays nothing), and no production code reads the counter (test seam).
pub var onWindowGone_fires: usize = 0;

/// Runs a hook on EVERY module that binds it, not just the first (callHook
/// returns after the first provider).
pub fn dispatchAll(
    comptime field: std.meta.FieldEnum(contract.WindowModule),
    args: anytype,
) void {
    if (comptime field == .onWindowGone) onWindowGone_fires += 1;
    dispatch.callAll(contract.WindowModule, window_mods[0..], field, args);
}

/// Like dispatchAll but returns true at the first provider whose hook does;
/// false when no provider binds the hook or none returns true. The any-true
/// scan is stated here (one consumer per owner layer -- see the dispatch-
/// primitives note in contract_dispatch.zig); the fallible fan-out variant was inlined
/// at its single lifecycle-init call site.
pub fn dispatchFirstTrue(
    comptime field: std.meta.FieldEnum(contract.WindowModule),
    args: anytype,
) bool {
    for (window_mods) |m| {
        if (@field(m, @tagName(field))) |f| if (@call(.auto, f, args)) return true;
    }
    return false;
}

/// Convenience over `providerOf`: the current workspace's covering occupant
/// via the module AND hook (anchored AND visible), null without a fullscreen
/// module. Contrast the model's OR scan `model.coveringOccupantOnWs`.
///
/// Here rather than in each consumer because two owner modules ask the same
/// question and neither may name the other: `fullscreen` owns the covering
/// record, `minimize` must know whether parking freed the screen.
pub fn currentCoveringOccupant(m: *const model.Model) ?model.WindowId {
    return if (providerOf(.visibleCoveringOnWs)) |prov|
        prov.visibleCoveringOnWs.?(m, m.current)
    else
        null;
}

/// Convenience over `callHookBool`: is this window parked anywhere in the
/// model? Asked by the restore path and by the tag-change guard, both of
/// which need the module-backed answer without naming `minimize`.
pub fn isMinimizedOnAnyWs(m: *const model.Model, win: model.WindowId) bool {
    return callHookBool(.isWindowHidden, .{ m, win });
}
