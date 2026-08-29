//! Layout config mapping (stateless).
//! Resolves layout names and serves live tiling config to consumers.

const std = @import("std");

const core = @import("core");
const types = @import("types");
const utils = @import("utils");

/// Defined in types.zig (see its doc comment for why) so config.zig and
/// workspaces.zig can resolve layout names without a circular import;
/// re-exported here so every existing `tiling.Layout` call site is unaffected.
pub const Layout = types.Layout;

pub const LayoutVariants = types.LayoutVariants;

/// Resolves a config-file layout name (canonical or alias) to its `Layout` tag.
pub inline fn layoutFromString(name: []const u8) ?Layout {
    for (types.layout_table) |entry| {
        if (std.mem.eql(u8, name, entry.name)) return entry.tag;
        for (entry.aliases) |alias| {
            if (std.mem.eql(u8, name, alias)) return entry.tag;
        }
    }
    return null;
}

/// First canonical layout; fallback for unknown/missing config names.
pub inline fn defaultLayout() Layout {
    return types.layout_table[0].tag;
}

// NOTE: live tiling state accessors (isEnabled/getBorderWidth/getLayoutVariants)
// were removed as dead symbols (2026-08, D3): callers read the config directly
// (borders.zig) and no module used the layout-variant bundle.
