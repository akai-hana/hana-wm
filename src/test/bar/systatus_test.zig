//! Registry-agnostic unit tests for the systatus readout resolution.
//! The `subs` registry is build-generated from file presence
//! (build.zig's buildSubsRegistryModule), so no concrete readout name
//! ("cpu", "batt", ...) is ever hardcoded here: pinning one would make the
//! suite fail the moment a readout file is added or removed -- precisely the
//! open-module churn this surface is designed to absorb.

const std = @import("std");
const types = @import("types");
const systatus = @import("systatus");

test "resolveSubs default and config ordering" {
    var out: [systatus.subs.len]usize = undefined;

    // Explicit empty list = none.
    var none_cfg = types.BarConfig{};
    none_cfg.systatus_items = std.ArrayList([]const u8).empty;
    defer none_cfg.systatus_items.?.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), systatus.resolveSubs(none_cfg, &out));

    // Explicit list honored verbatim: unknown names and duplicates skipped.
    // Built from the registry itself so no concrete readout name is hardcoded
    // here -- the registry is generated and may shrink/grow freely.
    const first = systatus.subs[0].name;
    const second = if (systatus.subs.len > 1) systatus.subs[1].name else first;
    var cfg = types.BarConfig{};
    cfg.systatus_items = std.ArrayList([]const u8).empty;
    defer cfg.systatus_items.?.deinit(std.testing.allocator);
    try cfg.systatus_items.?.append(std.testing.allocator, first);
    try cfg.systatus_items.?.append(std.testing.allocator, second);
    try cfg.systatus_items.?.append(std.testing.allocator, "no-such-readout");
    try cfg.systatus_items.?.append(std.testing.allocator, first);
    const len = systatus.resolveSubs(cfg, &out);
    try std.testing.expectEqual(@as(usize, 2), len);
    try std.testing.expectEqualStrings(first, systatus.subs[out[0]].name);
    try std.testing.expectEqualStrings(second, systatus.subs[out[1]].name);

    // Absent = default: every present-capable readout, exactly in the
    // registry's (deterministic) order.
    const default_len = systatus.resolveSubs(.{}, &out);
    var present_count: usize = 0;
    for (systatus.subs) |sub| {
        const present = if (sub.present) |p| p() else true;
        if (present) present_count += 1;
    }
    try std.testing.expectEqual(present_count, default_len);
    var i: usize = 0;
    for (systatus.subs) |sub| {
        const present = if (sub.present) |p| p() else true;
        if (present) {
            try std.testing.expectEqualStrings(sub.name, systatus.subs[out[i]].name);
            i += 1;
        }
    }
}
