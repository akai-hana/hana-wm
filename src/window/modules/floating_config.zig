//! The floating config fragment: `Config` (the [drag] subtree), its knob
//! table, and the parse entry point the generated `composed` dispatcher
//! calls. Deleting this file (with the rest of the optional floating module)
//! removes the `floating` field and the snap_distance knob from the build
//! with no trace elsewhere.

const std = @import("std");
const parser = @import("parser");
const types = @import("types");
const knob = @import("knob");

pub const Config = struct {
    /// How close (in px or %) a window edge must be to a monitor/bar boundary
    /// before it snaps. Set to 0 to disable. Percentage is relative to screen
    /// width.
    snap_distance: types.ScalableValue = types.ScalableValue.absolute(8.0),

    pub fn deinit(_: *Config, _: std.mem.Allocator) void {}
};

pub const knobs = [_]knob.Knob{
    // [drag]
    knob.knob(&.{knob.place(types.section_drag, "snap_distance")}, "snap_distance", .{ .scalable = 0.0 }),
};

comptime {
    knob.validateTable(Config, &knobs, &.{});
}

/// The section name this fragment owns (D13/P2-50), plus the fallback-TOML
/// head gating (drag sections are stripped from the embedded fallback when
/// the floating module is absent from the tree).
pub const sections = &[_][]const u8{types.section_drag};
pub const fallback_sections = &[_][]const u8{"drag"};

pub fn parse(allocator: std.mem.Allocator, doc: *parser.Document) !Config {
    var cfg: Config = .{};
    errdefer cfg.deinit(allocator);
    try knob.applyAll(Config, doc, allocator, &cfg, &knobs);
    return cfg;
}

/// No domain invariants beyond the snap knob's bounds; present so the
/// generated composed facade can call `validate` uniformly on every fragment.
pub fn validate(_: *const Config) !void {}
