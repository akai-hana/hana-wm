//! The generic layout port's inert and adapter behavior: the absent-provider
//! defaults every mandatory caller relies on, plus the request/registry
//! vocabulary a layout subsystem adapter speaks. Pure, so no X server.

const std = @import("std");
const testing = std.testing;

const port = @import("layout_port");
const model = @import("model");

fn fakeStatus(kind: u8) port.Status {
    if (kind != 1) return .{};
    return .{
        .active = true,
        .name = "grid",
        .icon = "[]",
        .variant_count = 2,
        .variant_indicators = &.{ "a", "b" },
    };
}

fn fakeIndex(name: []const u8) ?u8 {
    return if (std.mem.eql(u8, name, "grid")) 1 else null;
}

fn fakeName(kind: u8) []const u8 {
    return if (kind == 1) "grid" else "";
}

fn fakeVariantCount(kind: u8) u8 {
    return if (kind == 1) 2 else 1;
}

fn fakeHasVariantParse(kind: u8) bool {
    return kind == 1;
}

fn fakeVariantParse(kind: u8, value: []const u8) ?u8 {
    if (kind != 1) return null;
    if (std.mem.eql(u8, value, "a")) return 0;
    if (std.mem.eql(u8, value, "b")) return 1;
    return null;
}

fn fakeCycle(kind: u8, dir: i32, names: []const []const u8) u8 {
    _ = kind;
    _ = dir;
    _ = names;
    return 1;
}

fn fakeProvider() port.Provider {
    return .{
        .count = 2,
        .status = fakeStatus,
        .indexByName = fakeIndex,
        .nameFor = fakeName,
        .variantCount = fakeVariantCount,
        .hasVariantParse = fakeHasVariantParse,
        .variantParse = fakeVariantParse,
        .cycleKind = fakeCycle,
    };
}

test "null provider: every hook is inert" {
    const p = port.null_provider;
    try testing.expectEqual(@as(usize, 0), p.count);
    try testing.expect(!p.status(0).active);
    try testing.expectEqualStrings("", p.status(0).name);
    try testing.expect(p.status(0).icon == null);
    try testing.expectEqual(@as(u8, 1), p.status(0).variant_count);
    try testing.expect(p.status(0).variant_indicators == null);
    try testing.expect(p.indexByName("master") == null);
    try testing.expectEqualStrings("", p.nameFor(0));
    try testing.expectEqual(@as(u8, 1), p.variantCount(0));
    try testing.expect(!p.hasVariantParse(0));
    try testing.expect(p.variantParse(0, "fifo") == null);
    try testing.expectEqual(@as(u8, 7), p.cycleKind(7, 1, &.{}));
    try testing.expect(p.preReconcile(0, .{}, 0, 0) == null);
    try testing.expect(p.viewport(0, 0, 0) == null);
    try testing.expect(p.spawnHeadSlot(&.{}, .fromIndex(0)) == null);
    try testing.expect(p.splitPlan(
        &.{},
        1,
        .left,
        .{ .x = 0, .y = 0, .width = 0, .height = 0 },
        .{ .x = 0, .y = 0, .width = 0, .height = 0 },
        false,
        0,
    ) == null);

    // The transitions are no-ops, not crashes, on the inert adapter.
    var m: model.Model = .{};
    p.reorderTiled(&m, 1, 0);
    p.stepTiled(&m, 1, 1);
    p.swapFocusedWithPrevious(&m);
    p.adjustPrimaryWidth(&m, 0.1);
}

test "provider status and registry lookups flow through the adapter" {
    const p = fakeProvider();
    const active = p.status(1);
    try testing.expect(active.active);
    try testing.expectEqualStrings("grid", active.name);
    try testing.expectEqualStrings("[]", active.icon.?);
    try testing.expectEqual(@as(u8, 2), active.variant_count);
    try testing.expectEqualStrings("b", active.variant_indicators.?[1]);

    try testing.expectEqual(@as(?u8, 1), p.indexByName("grid"));
    try testing.expect(p.indexByName("nope") == null);
    try testing.expectEqualStrings("grid", p.nameFor(1));
    try testing.expectEqual(@as(u8, 2), p.variantCount(1));
    try testing.expect(p.hasVariantParse(1));
    try testing.expectEqual(@as(?u8, 1), p.variantParse(1, "b"));
    try testing.expect(p.variantParse(1, "nope") == null);
}

test "kindFallingBack resolves names and warns down to the fallback" {
    const p = fakeProvider();
    try testing.expectEqual(@as(u8, 1), port.kindFallingBack(&p, "grid", port.default_kind));
    // The test runner captures the warn; the returned fallback is the pin.
    try testing.expectEqual(port.default_kind, port.kindFallingBack(&p, "missing", port.default_kind));
}

test "Request.hintsFor resolves aligned hints and defaults absent windows" {
    const order = [_]model.WindowId{ 10, 11 };
    var hints = [_]model.SizeHints{
        .{ .min_width = 100 },
        .{ .min_width = 200 },
    };
    var params: model.LayoutParams = .{};
    const req: port.Request = .{
        .order = &order,
        .params = &params,
        .workarea = .{ .x = 0, .y = 0, .width = 800, .height = 600 },
        .hints = &hints,
        .focused = 11,
    };
    try testing.expectEqual(@as(u16, 100), req.hintsFor(10).min_width);
    try testing.expectEqual(@as(u16, 200), req.hintsFor(11).min_width);
    try testing.expectEqual(@as(u16, 0), req.hintsFor(12).min_width);
}
