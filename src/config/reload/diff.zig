//! Reload change detection: per-subsystem content comparison for
//! handleConfigReload (reload.zig), so it can skip teardown/rebuild work when a subsystem
//! didn't actually change (e.g. a bar color tweak should not regrab
//! keybindings). Pure struct comparison -- std containers are compared through
//! their logical items/entries, never their internal capacity/bookkeeping
//! bytes (which would make a reload comparison depend on append history) and
//! never by pointer identity.

const std = @import("std");
const types = @import("types");

/// Bar layouts are compared logically; the segments ArrayList's capacity is
/// bookkeeping that append history must never make read as different.
fn eqlBarLayouts(a: []const types.BarLayout, b: []const types.BarLayout) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (x.position != y.position) return false;
        if (!std.meta.eql(x.segments.items, y.segments.items)) return false;
    }
    return true;
}

/// Unordered string-keyed map comparison, shared by the variant map and the
/// segment-color maps: append history must never make two identical maps read
/// as different, and `std.meta.eql` on StringHashMapUnmanaged would trip on
/// internal bookkeeping. Values compare via `std.meta.eql` (slice or scalar).
fn eqlStringMap(comptime V: type, a: *const std.StringHashMapUnmanaged(V), b: *const std.StringHashMapUnmanaged(V)) bool {
    if (a.count() != b.count()) return false;
    var it = a.iterator();
    while (it.next()) |entry| {
        const v = b.get(entry.key_ptr.*) orelse return false;
        if (!std.meta.eql(entry.value_ptr.*, v)) return false;
    }
    return true;
}

pub const ConfigChanges = struct {
    bar: bool = false,
    tiling: bool = false,
    keys: bool = false,
};

/// The three detectors compare per-subsystem content summaries, not
/// derivations from `schema.knobs`: keysChanged is entirely bespoke
/// (bindings have no knob entries and compare pair-based), while
/// bar/tiling carry non-knob content (fonts, workspace icons, color
/// overrides, layout/rule tables) a knob scan could not see. bar and
/// tiling are DERIVED field walks (see `cmpFor`), so their coverage is
/// total by construction -- a field added to BarConfig, TilingConfig or
/// WorkspaceConfig cannot compile, parse and reload without tripping its
/// detector.
const BarCmp = union(enum) {
    direct,
    meta,
    string_map: type,
    layouts,
    lists,
};

/// Comptime `ArrayList(T)`/`ArrayListUnmanaged(T)` detection (the one
/// container family with `items` + `capacity` fields), so every list
/// field routes to the logical-items compare instead of the generic
/// struct rule, which would read capacity -- append-history bookkeeping
/// -- as a config change.
fn isArrayList(comptime t: type) bool {
    if (@typeInfo(t) != .@"struct") return false;
    var items = false;
    var capacity = false;
    inline for (@typeInfo(t).@"struct".fields) |f| {
        if (std.mem.eql(u8, f.name, "items")) items = @typeInfo(f.type) == .pointer;
        if (std.mem.eql(u8, f.name, "capacity")) capacity = true;
    }
    return items and capacity;
}

/// The comparison strategy for one `BarConfig` field, DERIVED from its type.
///
/// The table below is the hand-written version of this same function. It
/// existed because the original hand-written comparison was a silent-drift
/// hazard: every field happened to be covered so nothing failed, and a 44th
/// field added later compiled, parsed and reloaded -- and simply never rebuilt
/// the bar. Deriving removes the possibility instead of detecting it. The cost
/// is that a new field TYPE must be recognized here, so the fallthrough is a
/// @compileError rather than a default: an unrecognized type fails the build
/// rather than being compared by the wrong rule.
fn cmpFor(comptime t: type) BarCmp {
    // The container types whose contents need a deep compare of their own.
    // Named explicitly because each carries a different element rule.
    if (t == std.StringHashMapUnmanaged(types.Color)) return .{ .string_map = types.Color };
    if (t == std.StringHashMapUnmanaged(types.SegmentProps)) return .{ .string_map = types.SegmentProps };
    if (t == std.StringHashMapUnmanaged([]const u8)) return .{ .string_map = []const u8 };
    if (t == std.ArrayList(types.BarLayout)) return .layouts;
    // Any other ArrayList compares its items logically: the slice
    // compare sees elements, never the capacity bookkeeping.
    if (isArrayList(t)) return .lists;

    return switch (@typeInfo(t)) {
        // `==` resolves these exactly: scalars, enums, and Color (a u32).
        .bool, .int, .float, .@"enum" => .direct,
        // An optional compares as its payload, so `?Color` is `==` while
        // `?[]const u8` is not.
        .optional => |o| cmpFor(o.child),
        // `ScalableValue` (a union), `[]const u8`, and the ArrayList of
        // strings need meta.eql -- including the ArrayList's capacity, which is
        // what the table below compares and is kept deliberately.
        .pointer, .@"struct", .@"union", .array => .meta,
        else => @compileError("no config compare strategy for " ++ @typeName(t)),
    };
}

/// `old` and `new` agree on one field of any config struct, compared by
/// the strategy `cmpFor` derives from the field's type.
fn fieldEql(
    comptime name: []const u8,
    old: anytype,
    new: anytype,
) bool {
    const a = @field(old, name);
    const b = @field(new, name);
    // comptime: `BarCmp.string_map` carries a `type`, which cannot exist at
    // runtime, so the strategy must be resolved here rather than stored.
    const by = comptime cmpFor(@TypeOf(a));
    return switch (by) {
        .direct => a == b,
        .meta => std.meta.eql(a, b),
        .string_map => |T| eqlStringMap(T, &a, &b),
        .layouts => eqlBarLayouts(a.items, b.items),
        .lists => std.meta.eql(a.items, b.items),
    };
}

/// Bar-subsystem content: every field of BarConfig, each compared by the
/// strategy its type implies (see `cmpFor`). Walking the fields themselves is
/// what makes the coverage total by construction -- there is no list that a
/// new field can be left out of.
fn barChanged(old: *const types.BarConfig, new: *const types.BarConfig) bool {
    inline for (std.meta.fields(types.BarConfig)) |f| {
        if (!fieldEql(f.name, old, new)) return true;
    }
    return false;
}

/// Tiling-subsystem content: every field of TilingConfig and
/// WorkspaceConfig, each compared by the strategy its type implies
/// (see `cmpFor`), plus the three top-level gates the reload handler
/// rebuilds together with tiling state. Walking the fields themselves
/// is what makes the coverage total by construction -- the same
/// cannot-fall-behind guarantee `barChanged` has. The hand-written
/// field list this replaces was the tiling half of the silent-drift
/// hazard: a field added to TilingConfig would compile, parse and
/// reload without ever tripping this detector, leaving stale tiling
/// state live.
fn tilingChanged(old: *const types.Config, new: *const types.Config) bool {
    inline for (std.meta.fields(types.TilingConfig)) |f| {
        if (!fieldEql(f.name, &old.tiling, &new.tiling)) return true;
    }
    inline for (std.meta.fields(types.WorkspaceConfig)) |f| {
        if (!fieldEql(f.name, &old.workspaces, &new.workspaces)) return true;
    }
    return old.fullscreen_enabled != new.fullscreen_enabled or
        old.drag_enabled != new.drag_enabled or
        !std.meta.eql(old.snap_distance, new.snap_distance);
}

/// Keys-subsystem content: the pair layout — (modifiers, keysym) per keyboard
/// binding and (modifiers, button) per mouse binding. Action is deliberately
/// excluded: two keybinds that differ only in their action (e.g. a changed
/// command string) still share a pair, so no regrab is needed.
fn keysChanged(old: *const types.Config, new: *const types.Config) bool {
    if (old.keybindings.items.len != new.keybindings.items.len) return true;
    for (old.keybindings.items, new.keybindings.items) |a, b| {
        if (a.modifiers != b.modifiers or a.keysym != b.keysym) return true;
    }
    if (old.mouse_bindings.items.len != new.mouse_bindings.items.len) return true;
    for (old.mouse_bindings.items, new.mouse_bindings.items) |a, b| {
        if (a.modifiers != b.modifiers or a.button != b.button) return true;
    }
    return false;
}

/// Compares old and new configs at a coarse per-subsystem level, returning
/// which subsystems changed. Gate each reload step on its flag so, e.g.,
/// a color tweak doesn't regrab keybindings.
pub fn detectChanges(old: *const types.Config, new: *const types.Config) ConfigChanges {
    return .{
        .bar = barChanged(&old.bar, &new.bar),
        .tiling = tilingChanged(old, new),
        .keys = keysChanged(old, new),
    };
}
