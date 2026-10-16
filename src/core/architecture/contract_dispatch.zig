//! Dispatch primitives shared by every pluggable contract: exactly TWO --
//! `providerOf` (first-match lookup) and `callAll` (fan-out) -- plus the
//! comptime binder-list helpers the engine contracts validate their hook
//! lists with. Pure vocabulary, no X11, no feature imports; lives in
//! `core/architecture/` because both engine contracts (window, bar) and the
//! core dispatch sites reach it.

const std = @import("std");

/// Dispatch primitives for every generated registry element type
/// (`WindowModule`, `Segment`, ...): exactly TWO -- `providerOf` (first-match
/// lookup) and `callAll` (fan-out). Every other shape the family offers is a
/// one-line providerOf application or a 3-line `for` that its owner states
/// where it binds, against the registry it owns: the first-match-with-bool
/// shape lives in the window layer's callHook/callHookBool (one consumer
/// each), and the fallible fan-out / any-true shapes live with their single
/// consumer layer. Nothing here is a comptime-generic helper whose doc cost
/// exceeds its body. All scans honor the registry's deterministic scan order.
/// (The per-contract classification asserts live with each
/// engine contract — window_contract, bar_contract.)
///
/// The single canonical registry-lookup entry: the first module in `registry`
/// that binds the hook `field`, in the registry's deterministic scan order.
/// Returns null when no compiled-in module provides
/// the hook (the "no owner" fallback). Core callers use this to reach a
/// window/bar subsystem through the build-generated registry, never by naming a
/// module. The registry is passed in (not captured) so dispatch sites never
/// depend on the generated-registry layer.
/// Returns a POINTER into `registry`, not a copy of the element: a
/// `WindowModule` is 36 function-pointer fields, and returning it by value made
/// every single-binder dispatch copy the whole struct to reach one of them.
/// The registry is build-generated static data (`&[_]WindowModule{...}`), so
/// the pointer is as long-lived as the program; a caller that outlives the
/// registry slice it passed would have been broken before this too, since the
/// by-value return hid the aliasing rather than preventing it.
pub fn providerOf(
    comptime T: type,
    registry: []const T,
    comptime field: std.meta.FieldEnum(T),
) ?*const T {
    var i: usize = 0;
    while (i < registry.len) : (i += 1) {
        if (@field(registry[i], @tagName(field)) != null) return &registry[i];
    }
    return null;
}

/// Fan-out dispatch: calls EVERY module in `registry` that binds `field`, in
/// registry order. Used for lifecycle and multi-binder-capable hooks.
pub fn callAll(
    comptime T: type,
    registry: []const T,
    comptime field: std.meta.FieldEnum(T),
    args: anytype,
) void {
    for (registry) |m| if (@field(m, @tagName(field))) |f| @call(.auto, f, args);
}

/// True when `name` appears in `list`; called at comptime by the partition
/// check below.
pub fn isListed(list: []const []const u8, name: []const u8) bool {
    for (list) |hook| if (std.mem.eql(u8, hook, name)) return true;
    return false;
}

/// Every name in a contract's binder list must be a real field of that
/// contract, and must appear once. A renamed hook left behind in a list would
/// otherwise turn into an `@hasField` that quietly skips -- the exact "unlisted
/// new hook silently escaped" failure the lists exist to prevent, just pointing
/// the other way. A WITHIN-list duplicate is rejected too: it is always a
/// copy-paste bug, and on the generated registry's at-most-one pass it would
/// double-count nothing (the count is per-hook, computed once) while making
/// the list lie about its own size.
pub fn assertListedFields(comptime T: type, comptime list_name: []const u8, list: []const []const u8) void {
    for (list, 0..) |hook, i| {
        if (!@hasField(T, hook)) @compileError(
            "T." ++ list_name ++ " lists '" ++ hook ++ "', which is not a " ++ @typeName(T) ++ " field",
        );
        for (list[i + 1 ..]) |later| {
            if (std.mem.eql(u8, hook, later)) @compileError(
                "T." ++ list_name ++ " lists '" ++ hook ++ "' twice; a binder list is a set, not a bag",
            );
        }
    }
}
