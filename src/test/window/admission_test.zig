//! Headless admission-policy tests: the class-rule map merge and the
//! WM_CLASS match are pure (buildRulesMapFrom and matchRule take the map as
//! a parameter), so neither needs an X server nor live WM state -- the
//! "testable without a server" split admission.zig documents.

const std = @import("std");
const testing = std.testing;

const admission = @import("admission");
const types = @import("types");

test "admission rules: one map holds float and workspace rules; first rule wins" {
    var map: std.StringHashMapUnmanaged(?u8) = .{};
    defer map.deinit(testing.allocator);
    const rules = [_]types.Rule{
        .{ .class_name = "Navigator", .workspace = 2, .float = false },
        // Same name again, later: must NOT overwrite the workspace target.
        .{ .class_name = "Navigator", .workspace = 5, .float = true },
        .{ .class_name = "mpv", .workspace = 0, .float = true },
        // A float rule already won for this name: must NOT become tiled.
        .{ .class_name = "mpv", .workspace = 4, .float = false },
        .{ .class_name = "Alacritty", .workspace = 7, .float = false },
    };
    admission.buildRulesMapFrom(&map, testing.allocator, &rules);

    try testing.expectEqual(@as(?u8, 2), map.get("Navigator").?);
    try testing.expectEqual(@as(?u8, 7), map.get("Alacritty").?);
    // Float rules live in the same map as a null VALUE, not as absence:
    // get() must return an outer-present / inner-null pair.
    const mpv = map.get("mpv");
    try testing.expect(mpv != null);
    try testing.expectEqual(@as(?u8, null), mpv.?);
    try testing.expectEqual(@as(usize, 3), map.count());
    try testing.expect(map.get("no-such-class") == null);
}

test "admission matchRule: class before instance, per-key outcome, no match is null" {
    var map: std.StringHashMapUnmanaged(?u8) = .{};
    defer map.deinit(testing.allocator);
    const rules = [_]types.Rule{
        .{ .class_name = "Navigator", .workspace = 1, .float = false },
        .{ .class_name = "mpv", .workspace = 0, .float = true },
    };
    admission.buildRulesMapFrom(&map, testing.allocator, &rules);

    // Class hit wins outright, even when the instance would hit another key.
    const cls = admission.matchRule(&map, "mpv", "Navigator").?;
    try testing.expectEqual(@as(?u8, 1), cls.workspace);
    try testing.expect(!cls.float);

    // Class miss falls through to the instance key.
    const inst = admission.matchRule(&map, "Navigator", "missing-class").?;
    try testing.expectEqual(@as(?u8, 1), inst.workspace);
    try testing.expect(!inst.float);

    // Empty class goes straight to the instance; float outcome is explicit.
    const flt = admission.matchRule(&map, "mpv", "").?;
    try testing.expect(flt.float);
    try testing.expectEqual(@as(?u8, null), flt.workspace);

    // Unknown in both slots: no rule at all.
    try testing.expect(admission.matchRule(&map, "x", "y") == null);
}
