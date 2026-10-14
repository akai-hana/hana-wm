//! Layout-name canonicalization and grammar. Every config-sourced layout name
//! passes through here -- the master-stack aliases fold onto the registry
//! module's canonical spelling -- so downstream resolution (engine.layoutByName,
//! which is exact-on-canonical) needs no alias handling of its own. The
//! known-spelling set lives here too, as the one grammar both config and the
//! tiling tests can see: the two sides cannot import each other (config is
//! below tiling), so neither can check the registry agreement alone, and a
//! drift between them would be silent.

const std = @import("std");
const types = @import("types");

/// Canonicalizes the layout-name aliases accepted from config: "master-stack"
/// and "master_stack" (any case) fold onto the registry module's canonical
/// name "master". Every config-sourced layout name passes through here so
/// downstream resolution (engine.layoutByName,
/// which is exact-on-canonical) needs no alias handling. Returns `name`
/// unchanged otherwise; never allocates, and the returned slice aliases the
/// input whenever it is not the canonical literal.
pub fn canonicalLayoutName(name: []const u8) []const u8 {
    if (std.ascii.eqlIgnoreCase(name, "master-stack") or
        std.ascii.eqlIgnoreCase(name, "master_stack"))
        return types.canon_master_layout;
    return name;
}

/// Known layout-name spellings, used ONLY to disambiguate the `layouts`
/// array grammar at parse time: a following token that names a layout starts
/// a new group rather than being consumed as a variants word. This is
/// grammar, not an authoritative registry — layout names resolve to
/// `tiling_modules` registry indices at seed time (engine.layoutByName), and
/// unknown names pass through so third-party addon layouts keep working.
/// Public so the tiling test can assert this list and the layout registry
/// agree in BOTH directions -- the two sides cannot import each other (config
/// is below tiling), so neither can check itself, and a drift between them is
/// silent: a name here that the registry dropped is skipped at parse, a layout
/// in the registry missing here is unselectable.
pub const layout_name_grammar = std.StaticStringMap(void).initComptime(.{
    .{ "master", {} },  .{ "master-stack", {} }, .{ "master_stack", {} },
    .{ "monocle", {} }, .{ "grid", {} },         .{ "fibonacci", {} },
    .{ "leaf", {} },    .{ "scroll", {} },
});

/// Maximum bytes a config layout name may occupy after normalization. Longer
/// names are warned-and-skipped by the layouts-array and variants-word parses
/// below.
pub const max_layout_name = types.max_config_name;

/// Layout-name normalization shared by isLayoutName, parseLayoutVariant and
/// parseLayoutsArray: lowercases `name` into `buf`, returning null when it
/// exceeds `max_layout_name` bytes so the caller can warn-and-skip (mirroring
/// types.lowerSlice's caller-buffer semantics). Canonicalization of the
/// master-stack aliases stays with the storage sites, which need it.
pub fn normalizeLayoutName(buf: *[max_layout_name]u8, name: []const u8) ?[]const u8 {
    return types.lowerSlice(max_layout_name, buf, name);
}

/// Whether `name` is one of the known layout-name spellings (grammar test).
/// Public for the same reason as `layout_name_grammar`: the tiling test uses
/// this to check the registry can be spelled, without config importing tiling.
pub fn isLayoutName(name: []const u8) bool {
    var buf: [max_layout_name]u8 = undefined;
    const lowered = normalizeLayoutName(&buf, name) orelse return false;
    return layout_name_grammar.has(lowered);
}
