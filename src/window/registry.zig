//! The window layer's binding-layer dispatch surface: five thin wrappers
//! over the generated window-module registry (`window_modules`), plus two
//! named reads (covering occupant, parked predicate) that wrap one-line
//! provider lookups every consumer would otherwise restate.
//!
//! The five dispatch wrappers are thin ON PURPOSE: collapsing them would
//! spread providerOf + @call pairs across every dispatch call site, and
//! folding them back into contract would re-create comptime-generic helpers
//! the two-primitive dispatch family deliberately does not carry. They stay
//! five; do not collapse further.
//!
//! Within `src/window/**` callers import `registry` directly; outside the
//! layer `window.zig` re-exports them so `window.*` stays the stable facade
//! that events.zig, bar/state.zig, input and the tests import.

const std = @import("std");

const contract = @import("window_contract");
const dispatch = @import("contract_dispatch");
const model = @import("model");
const window_mods = @import("window_modules").modules;

/// Registry lookup for the hook `field` (see `dispatch.providerOf`), null
/// when no module binds it. Thin typed forward onto the canonical `contract`
/// dispatch family.
pub fn providerOf(
    comptime field: std.meta.FieldEnum(contract.WindowModule),
) ?*const contract.WindowModule {
    return dispatch.providerOf(contract.WindowModule, window_mods[0..], field);
}

/// First-match dispatch: invokes the first module that binds `field`,
/// nothing when none does (the "adopt by name" path for single-binder hooks,
/// see `single_binder_hooks`). providerOf + invoke stated here — this shape
/// had one consumer, so it lives at the binding layer rather than as a
/// comptime-generic helper in contract.
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
/// fires the hook exactly once", and it catches a re-added second fire site
/// even though every hook stays happy. The count lives at the dispatch
/// PRIMITIVE so it sees every path — the `window.*` facade re-export,
/// in-layer direct `registry.dispatchAll` calls, and module-to-module
/// re-dispatch. Increment is comptime-gated on this one field (every other
/// hook pays nothing); no production code reads it (test seam).
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
/// false when none binds it or none returns true. Stated here (one consumer
/// per owner layer — see the dispatch-primitives note in
/// contract_dispatch.zig).
pub fn dispatchFirstTrue(
    comptime field: std.meta.FieldEnum(contract.WindowModule),
    args: anytype,
) bool {
    for (window_mods) |m| {
        if (@field(m, @tagName(field))) |f| if (@call(.auto, f, args)) return true;
    }
    return false;
}

/// Per-family dispatch: the same five shapes as the top-level wrappers,
/// scoped to one `WindowModule` family struct
/// (`registry.hide.callHook(.hideWindow, ...)`). `get` projects the family
/// out of an element; `providerOf` returns the WHOLE element (pointer into
/// the static registry, same lifetime contract as the top-level lookup), so
/// a caller can still read other fields off it.
fn Family(comptime family_field: []const u8, comptime F: type) type {
    return struct {
        const Self = @This();

        fn get(m: *const contract.WindowModule) *const F {
            return &@field(m, family_field);
        }

        pub fn providerOf(comptime field: std.meta.FieldEnum(F)) ?*const contract.WindowModule {
            for (&window_mods) |*m| {
                if (@field(get(m), @tagName(field)) != null) return m;
            }
            return null;
        }

        pub fn callHook(comptime field: std.meta.FieldEnum(F), args: anytype) void {
            if (Self.providerOf(field)) |m| @call(.auto, @field(get(m), @tagName(field)).?, args);
        }

        pub fn callHookBool(comptime field: std.meta.FieldEnum(F), args: anytype) bool {
            if (Self.providerOf(field)) |m| return @call(.auto, @field(get(m), @tagName(field)).?, args);
            return false;
        }

        pub fn dispatchAll(comptime field: std.meta.FieldEnum(F), args: anytype) void {
            for (window_mods) |m| if (@field(get(&m), @tagName(field))) |f| @call(.auto, f, args);
        }

        pub fn dispatchFirstTrue(comptime field: std.meta.FieldEnum(F), args: anytype) bool {
            for (window_mods) |m| {
                if (@field(get(&m), @tagName(field))) |f| if (@call(.auto, f, args)) return true;
            }
            return false;
        }
    };
}

/// The seven single-binder families, one namespace each (see the family
/// structs in `window_contract.zig`). Dispatch is first-match, so each
/// family hook is bound by at most one module (asserted at comptime).
pub const hide = Family("hide", contract.HideHooks);
pub const covering = Family("covering", contract.CoveringHooks);
pub const workspaces = Family("workspaces", contract.WorkspacesHooks);
pub const floating = Family("floating", contract.FloatingHooks);
pub const drag = Family("drag", contract.DragHooks);
pub const command = Family("command", contract.CommandHooks);
pub const borders = Family("borders", contract.BordersHooks);

/// Convenience over the hide family's `callHookBool`: is this window parked
/// anywhere in the model? Asked by the restore path and by the tag-change
/// guard, both of which need the module-backed answer without naming
/// `minimize`.
pub fn isMinimizedOnAnyWs(m: *const model.Model, win: model.WindowId) bool {
    return hide.callHookBool(.isWindowHidden, .{ m, win });
}
