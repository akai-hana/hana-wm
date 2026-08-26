//! Layout config mapping (stateless).
//!
//! The legacy retile engine and its per-window caches are gone: placement is
//! computed by src/layout/ over the model, sync owns the wire, and the shared
//! per-window cache lives in window/wincache.zig. What remains are live
//! mappings from static config (+ model overrides) to layout queries used by
//! the bar, input diagnostics, and actions -- all computed on demand, no
//! module state.

const std = @import("std");

const core = @import("core");
const types = @import("types");
const utils = @import("utils");
const build_options = @import("build_options");

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

// Live tiling state accessors.

pub inline fn isEnabled() bool {
    return core.getState().config.tiling.enabled;
}

pub inline fn getBorderWidth() u16 {
    const cs = core.getState();
    return utils.scaling.scaleBorderWidth(cs.config.tiling.border_width, cs.screen.height_in_pixels);
}

pub inline fn getCurrentLayout() Layout {
    // Keybinds mutate per-ws MODEL params now; reading static config here
    // left the bar icon stale after cycle_layout / step_variant / per-ws
    // overrides. Fall back to config pre-init only.
    if (build_options.has_tiling) {
        const pipeline = @import("pipeline");
        if (pipeline.initialized) {
            const mm = pipeline.model();
            const p = &mm.ws[mm.current].params;
            return @enumFromInt(@intFromEnum(p.kind));
        }
    }
    const cs = core.getState();
    // stringToEnum (not layoutFromString) so the scalar config key
    // `tiling.layout = "floating"` resolves: layoutFromString is scoped
    // to layout_table, which deliberately excludes .floating.
    return std.meta.stringToEnum(Layout, cs.config.tiling.layout) orelse defaultLayout();
}

pub inline fn getLayoutVariants() LayoutVariants {
    const cfg_tiling = core.getState().config.tiling;
    return .{
        .master = cfg_tiling.master_variant,
        .monocle = cfg_tiling.monocle_variant,
        .grid = cfg_tiling.grid_variant,
    };
}
