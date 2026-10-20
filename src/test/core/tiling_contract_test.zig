//! Acceptance for P2-55: the registry helpers are parameterizable, so a test
//! can inject a fake layout registry instead of depending on the build
//! generated `tiling_mods` singleton. Non-gated on purpose -- the helpers live
//! in the always compiled `tiling_contract`, and this is what proves the
//! `moduleOfRegistry` / `activeLayoutMetaFrom` shapes carry their own registry
//! rather than reaching for the singleton.

const std = @import("std");
const testing = std.testing;
const contract = @import("tiling_contract");

fn fakeCompute(_: *const contract.View, out: *contract.List) void {
    _ = out;
}

test "moduleOfRegistry injects a one-layout registry; out-of-range is null" {
    const fake: [1]contract.Layout = .{
        .{ .name = "only", .compute = fakeCompute, .variant_count = 1 },
    };
    // The single injected layout resolves by index 0...
    const got = contract.moduleOfRegistry(&fake, 0);
    try testing.expect(got != null);
    try testing.expectEqualStrings("only", got.?.name);
    // ...and anything past the injected registry length is null, exactly like
    // the singleton path, so the guard is carried by the parameterized form.
    try testing.expect(contract.moduleOfRegistry(&fake, 1) == null);
    try testing.expect(contract.moduleOfRegistry(&fake, 255) == null);
    // An empty injected registry degrades the same way the absent-tiling one
    // does: every lookup is null.
    try testing.expect(contract.moduleOfRegistry(&[_]contract.Layout{}, 0) == null);
}

fn fakeIcon(l: contract.Layout) ?[]const u8 {
    return l.icon;
}

test "activeLayoutMetaFrom picks over the injected registry and falls back" {
    const fake: [1]contract.Layout = .{
        .{ .name = "only", .icon = "[]", .variant_count = 1 },
    };
    // Enabled + registered: the injected icon comes back.
    try testing.expectEqualStrings("[]", contract.activeLayoutMetaFrom(&fake, 0, true, fakeIcon, "none"));
    // Tiling disabled: the gate short-circuits to the fallback.
    try testing.expectEqualStrings("none", contract.activeLayoutMetaFrom(&fake, 0, false, fakeIcon, "none"));
    // Registered index that the injected set does not cover: fallback, not crash.
    try testing.expectEqualStrings("none", contract.activeLayoutMetaFrom(&fake, 7, true, fakeIcon, "none"));
    // A layout with no icon for this dimension: null pick propagates to fallback.
    const noIcon: [1]contract.Layout = .{.{ .name = "bare", .variant_count = 1 }};
    try testing.expectEqualStrings("none", contract.activeLayoutMetaFrom(&noIcon, 0, true, fakeIcon, "none"));
    // Empty injected registry: fallback before any lookup.
    try testing.expectEqualStrings("none", contract.activeLayoutMetaFrom(&[_]contract.Layout{}, 0, true, fakeIcon, "none"));
}
