//! The tiling config fragment: `Config` (the [tiling] subtree), its knob table,
//! and the parse/validate entry points the generated `composed` dispatcher calls.
//! Deleting this file (with the rest of src/tiling/) removes the `tiling` field,
//! every [tiling] knob, and all tiling config vocabulary from the build.
//!
//! The non-scalar structures (layouts array, per-layout variants, master-stack
//! counts) are parsed by the sibling `tiling_sections` module; the scalar knobs
//! below are applied by the generic engine in `knob`.

const std = @import("std");
const model = @import("model");
const parser = @import("parser");
const scaling = @import("scaling");
const types = @import("types");
const knob = @import("knob");
const log = std.log.scoped(.tiling_config);
const tiling_sections = @import("tiling_sections");

/// Which side of the screen the master column occupies.
pub const MasterSide = enum {
    left,
    right,

    pub const string_map = std.StaticStringMap(MasterSide).initComptime(.{
        .{ "l", .left },
        .{ "left", .left },
        .{ "r", .right },
        .{ "right", .right },
    });
};

/// Per-workspace startup layout assignment, overriding the global default. variant
/// is null -> use the per-layout map default ([tiling].variants).
pub const WorkspaceLayoutOverride = struct {
    workspace_idx: model.WorkspaceId,
    layout_idx: u8, // index into Config.layouts
    variant: ?[]const u8, // null = use per-layout variants-map default
};

/// Per-workspace master count override, parsed from [tiling.layouts.master-stack.counts].
pub const WorkspaceMasterCountOverride = struct {
    workspace_idx: model.WorkspaceId,
    count: u8,
};

pub const Config = struct {
    layouts: std.ArrayList([]const u8) = .empty, // Available layouts in cycle order
    master_side: MasterSide = .left,
    master_width: types.ScalableValue = types.ScalableValue.percentage(50.0),
    master_count: u8 = 1,
    gap_width: types.ScalableValue = types.ScalableValue.absolute(10.0),
    border_width: types.ScalableValue = types.ScalableValue.absolute(2.0),
    border_focused: types.Color = types.default_focused_border,
    border_unfocused: types.Color = types.default_unfocused_border,
    /// Smallest on-screen width/height a tiled window (and floating drag resize) is
    /// allowed to reach, in pixels.
    min_window_dim: u16 = types.default_min_window_dim,

    // Per-layout variant preferences: placement policy as value-strings in a
    // canonical layout-name -> VALUE-STRING map (no closed per-layout enums; each
    // module interprets its strings via `variant_parse`). Both key and value are
    // heap-duped at parse so they outlive the document; deinit frees them.
    variants: std.StringHashMapUnmanaged([]const u8) = .empty,

    /// Per-workspace layout assignments parsed from the layouts array.
    workspace_layout_overrides: std.ArrayList(WorkspaceLayoutOverride) = .empty,

    /// Per-workspace master count overrides parsed from
    /// [tiling.layouts.master-stack.counts]. Only applied when global_layout = false.
    workspace_master_count_overrides: std.ArrayList(WorkspaceMasterCountOverride) = .empty,

    /// When true, layout changes apply globally across all workspaces instead of per
    /// workspace.
    global_layout: bool = false,

    /// Resolves the per-workspace master-count overrides into a fixed-size,
    /// workspace-indexed lookup with last-wins semantics (a duplicate entry
    /// overrides its predecessor). `null` means no override (use the global default).
    /// Consumed by seed.seedParamsFromConfig, so the last-wins rule lives in one
    /// place.
    pub fn masterCountLookup(self: *const Config) [model.max_workspaces]?u8 {
        var lookup: [model.max_workspaces]?u8 = .{null} ** model.max_workspaces;
        for (self.workspace_master_count_overrides.items) |o| {
            // One validity notion, not a second inline range test.
            if (o.workspace_idx.isValid())
                lookup[o.workspace_idx.index] = o.count;
        }
        return lookup;
    }

    /// The default layout name: the first entry of the layout cycle, or
    /// `canon_master_layout` when the cycle is empty. Derived, never stored.
    pub fn defaultLayout(self: *const Config) []const u8 {
        return if (self.layouts.items.len > 0) self.layouts.items[0] else types.canon_master_layout;
    }

    /// Resolves the per-workspace layout overrides into a fixed-size,
    /// workspace-indexed lookup of override indices with last-wins semantics (a
    /// duplicate entry overrides its predecessor). `null` means no override.
    /// Consumed by seed.seedParamsFromConfig, so the last-wins rule lives in one
    /// place.
    pub fn workspaceLayoutLookup(self: *const Config) [model.max_workspaces]?usize {
        var lookup: [model.max_workspaces]?usize = .{null} ** model.max_workspaces;
        for (self.workspace_layout_overrides.items, 0..) |o, oi| {
            if (o.workspace_idx.isValid())
                lookup[o.workspace_idx.index] = oi;
        }
        return lookup;
    }

    pub fn deinit(self: *Config, allocator: std.mem.Allocator) void {
        for (self.layouts.items) |layout| allocator.free(layout);
        self.layouts.deinit(allocator);
        types.freeStringMap(&self.variants, allocator, types.free_storage);
        for (self.workspace_layout_overrides.items) |o| {
            if (o.variant) |v| allocator.free(v);
        }
        self.workspace_layout_overrides.deinit(allocator);
        self.workspace_master_count_overrides.deinit(allocator);
    }
};

/// Master-stack trio: dedicated-section short spelling wins over the flat [tiling]
/// spelling (section presence, not key presence, picks the spelling). Targets are
/// relative to THIS Config.
fn masterStack(dedicated_key: []const u8, flat_key: []const u8, kind: knob.Kind) knob.Knob {
    return .{
        .places = &.{ knob.place(types.section_tiling_layouts_master_stack, dedicated_key), knob.place(types.section_tiling, flat_key) },
        .target = flat_key,
        .kind = kind,
        .requires = types.section_tiling,
    };
}

/// Every tiling scalar knob, exactly once. ORDER MATTERS only for `needs` (none today),
/// which `validateTable` enforces.
pub const knobs = [_]knob.Knob{
    // [tiling]: functional knobs gated on the section itself -- a lone [tiling]
    // carrying only the aesthetics quartet (a theme file's shape) never fed these
    // knobs. (The quartet below is UNGATED: it's visual.)
    knob.knobGated(&.{knob.place(types.section_tiling, "global_layout")}, "global_layout", .b, types.section_tiling),
    knob.knobGated(&.{knob.place(types.section_tiling, "min_window_dim")}, "min_window_dim", .{ .int = .{ .T = u16, .min = 1 } }, types.section_tiling),

    // Aesthetics quartet: flat [tiling] spellings. UNGATED -- it's visual, so a
    // theme file may ship only these in a lone [tiling] with no functional key.
    knob.knob(&.{knob.place(types.section_tiling, "gap_width")}, "gap_width", .{ .scalable = 0.0 }),
    knob.knob(&.{knob.place(types.section_tiling, "border_width")}, "border_width", .{ .scalable = 0.0 }),
    // The two color knobs are read ONLY by the optional borders module; when that
    // module is deleted the settings are legitimately unread, so they carry the
    // ownership declaration (P2-47). border_width stays core-owned: core.borderWidth()
    // and the reconcile geometry read it regardless.
    knob.readerOf(&.{knob.place(types.section_tiling, "border_focused")}, "border_focused", .color, "borders"),
    knob.readerOf(&.{knob.place(types.section_tiling, "border_unfocused")}, "border_unfocused", .color, "borders"),

    // Master-stack trio: the dedicated section's shorter spellings win; flat
    // [tiling] keeps the flat spellings.
    masterStack("count", "master_count", .{ .int = .{ .T = u8, .min = 1 } }),
    masterStack("side", "master_side", .{ .enum_read = .{ .T = MasterSide, .ci = true } }),
    // No local bound: validate() owns master_width's ratio/negative policy.
    masterStack("width", "master_width", .scalable_free),
};

/// Module-owned knob readers (see `knob.readerOf` / `Knob.reader`): the two border
/// color knobs are read only by the optional borders module, so the build's
/// knob-reader scan excuses them on a tree that module has been deleted from (P2-47).
pub const knob_reader_modules = [_][2][]const u8{
    .{ "border_focused", "borders" },
    .{ "border_unfocused", "borders" },
};

comptime {
    knob.validateTable(Config, &knobs, &.{});
    knob.validateOwnership(&knobs, &knob_reader_modules, "tiling");
}

/// The section names the tiling subsystem owns (D13/P2-50): the composed facade unions
/// every fragment's list into the mis-case lint's inventory. The two master-stack
/// spellings are the shipped dedicated tables; other layout names arrive through the
/// `section_prefixes` family below, not as exact entries.
pub const sections = &[_][]const u8{
    types.section_tiling,
    types.section_tiling_layouts_master_stack,
    types.section_prefix_tiling_layouts ++ "master_stack",
};

/// Mis-case family: `[tiling.layouts.*]` is an open set (any registry layout name), so
/// a case-variant of the family gets the family warn rather than needing exact entries.
pub const section_prefixes = &[_][]const u8{types.section_prefix_tiling_layouts};

/// Inert family (D13/P2-50): `[tiling.*]` sub-tables are read only when bare
/// `[tiling]` is present; a present family with the parent missing leaves those knobs
/// inert, which the load warns about.
pub const inert_families = &[_]types.InertFamily{.{
    .parent = types.section_tiling,
    .child_prefix = types.section_prefix_tiling,
}};

/// `[tiling] layouts` accumulates the layout-name list by design (same list-reading
/// policy the layout cycle has always had); a scalar read takes the last declaration
/// without a "later wins" warn.
pub const accumulate_exempt = &[_]types.SectionKey{.{
    .section = types.section_tiling,
    .key = "layouts",
}};

/// The section HEADS whose presence in the embedded fallback TOML is gated on this
/// fragment's owner module (P2-50).
pub const fallback_sections = &[_][]const u8{"tiling"};

/// The fragment parse entry: self-seed the owned defaults (so an empty document still
/// yields a usable single-layout cycle), apply the scalar knobs, then parse the
/// non-scalar structures.
pub fn parse(allocator: std.mem.Allocator, doc: *parser.Document) !Config {
    var cfg: Config = .{};
    errdefer cfg.deinit(allocator);
    try tiling_sections.seedDefaultLayout(allocator, &cfg, types.canon_master_layout);
    try knob.applyAll(Config, doc, allocator, &cfg, &knobs);
    try tiling_sections.parseTilingStructures(allocator, doc, &cfg);
    return cfg;
}

/// Range checks the knob engine does not own: master_width's ratio band (percentages
/// validate as a [min_master_width, max_master_width] ratio; pixels only as >= 0,
/// since the screen width for a ratio isn't available here and the runtime clamps).
/// Called by composed.parse.
pub fn validate(cfg: *const Config) !void {
    const mw = cfg.master_width;
    if (mw.is_percentage) {
        const mw_ratio: f32 = scaling.asRatio(mw);
        if (mw_ratio < model.min_master_width or mw_ratio > model.max_master_width) {
            log.err("Invalid config: master_width {d:.0}% out of [{d:.0}%, {d:.0}%]", .{
                mw_ratio * 100.0,
                model.min_master_width * 100.0,
                model.max_master_width * 100.0,
            });
            return error.InvalidConfig;
        }
    } else if (mw.value < 0.0) {
        log.err("Invalid config: master_width {d}px must be >= 0", .{mw.value});
        return error.InvalidConfig;
    }
}
