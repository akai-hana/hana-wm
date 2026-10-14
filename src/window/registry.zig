//! The window layer's binding-layer dispatch surface: five thin wrappers
//! over the generated window-module registry (`window_modules`).
//!
//! BINDING-LAYER SURFACE (KISS audit note): the five dispatch wrappers below
//! (providerOf/callHook/callHookBool/dispatchAll/dispatchFirstTrue) are thin
//! on purpose. Collapsing them would spread providerOf + @call pairs across
//! every dispatch call site, and folding them back into contract would
//! re-create the comptime-generic helpers the contract 6->2 dispatch
//! collapse deliberately removed. Further collapse: considered, rejected.
//!
//! Within `src/window/**` callers import `registry` directly (one hop to the
//! definition); outside the layer `window.zig` re-exports the same five so
//! `window.*` stays the stable external facade events.zig, bar/state.zig,
//! input and the tests import.

const std = @import("std");

const contract = @import("contract");
const window_mods = @import("window_modules").modules;

/// Registry lookup for the hook `field` (see `contract.providerOf`), null when
/// no module binds it; shared by the window layer (actions/borders alias this).
/// Thin typed forward onto the single canonical `contract` dispatch family
/// (two primitives: providerOf + callAll).
pub fn providerOf(
    comptime field: std.meta.FieldEnum(contract.WindowModule),
) ?*const contract.WindowModule {
    return contract.providerOf(contract.WindowModule, window_mods[0..], field);
}

/// First-match dispatch: invokes the first module that binds `field`, nothing
/// when none does (the "adopt by name" path for single-binder hooks, see
/// `single_binder_hooks`). providerOf + invoke stated here -- the shape had
/// this one consumer, so it lives at the binding layer rather than as a
/// comptime-generic helper in contract (the 6->2 collapse).
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

/// Runs a hook on EVERY module that binds it, not just the first (callHook
/// returns after the first provider). Dispatch loops shared by actions.
pub fn dispatchAll(
    comptime field: std.meta.FieldEnum(contract.WindowModule),
    args: anytype,
) void {
    contract.callAll(contract.WindowModule, window_mods[0..], field, args);
}

/// Like dispatchAll but returns true at the first provider whose hook does;
/// false when no provider binds the hook or none returns true. The any-true
/// scan is stated here (one consumer per owner layer -- see the dispatch-
/// primitives note in contract.zig); the fallible fan-out variant was inlined
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
