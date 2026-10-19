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

/// The section names this always-present fragment owns (D13/P2-50): the
/// composed facade unions every fragment's list into the mis-case lint's
/// inventory, so a new section is added here, not in the core. `fullscreen`
/// is reserved vocabulary with no consumer yet; it stays recognized so a
/// case-variant header still gets the mis-case warn.
pub const sections = &[_][]const u8{
    types.section_binds,      types.section_binds_alt,
    types.section_display,    types.section_core,
    types.section_fullscreen,
};

/// [binds] accumulates duplicate declarations by design (repeated bind
/// names read as arrays; scalar reads take the last without a "later wins"
/// warn). The [Keybindings] alias deliberately is NOT exempt -- it carries
/// the same keys, but the policy was written for [binds] and stays there.
pub const accumulate_exempt = &[_]types.SectionKey{
    .{ .section = types.section_binds },
};

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
