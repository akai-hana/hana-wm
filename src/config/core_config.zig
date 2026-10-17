//! The always-present core config fragment: keybindings, mouse bindings, and
//! the DPI override. Unlike the subsystem fragments this file is NOT
//! discovered by its stem (`core_config` is on discovery's skip list); the
//! generated `composed` module calls it unconditionally to fill its `core`
//! field, so it survives every optional-module deletion.

const std = @import("std");
const parser = @import("parser");
const types = @import("types");
const knob = @import("knob");
const binds = @import("binds");

pub const knobs = [_]knob.Knob{
    // [display]
    knob.knob(&.{knob.place(types.section_display, "dpi")}, "dpi", .{ .opt_float = .{ .min = 20.0, .max = 1000.0 } }),
    // [core]
    knob.knob(&.{knob.place(types.section_core, "key_repeat")}, "key_repeat", .b),
};

comptime {
    knob.validateTable(types.CoreConfig, &knobs, &.{});
}

/// The core parse entry: key/mouse bindings first (so a `[binds]` action can
/// never depend on the dpi knob), then the scalar knobs.
pub fn parse(allocator: std.mem.Allocator, doc: *parser.Document) !types.CoreConfig {
    var core: types.CoreConfig = .{};
    errdefer core.deinit(allocator);
    try binds.parseKeybindings(allocator, doc, &core);
    try knob.applyAll(types.CoreConfig, doc, allocator, &core, &knobs);
    return core;
}

/// No domain invariants beyond the knob bounds (the dpi range is enforced by
/// the opt_float reader); present so the generated composed facade can call
/// `validate` uniformly on every fragment.
pub fn validate(_: *const types.CoreConfig) !void {}
