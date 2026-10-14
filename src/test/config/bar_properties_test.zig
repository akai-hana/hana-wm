//! `applyBarProperties` unit tests: the gate contract (pre-seeded maps clear
//! when [bar] or [bar.properties] is absent), knob-key exclusion from the
//! segment pass, the `_value` color-only rule, style-only entries storing
//! props WITHOUT a color map entry, and palette references after
//! collectPalette. The full-pipeline spellings (composite arrays, mixes,
//! every `=`/bare/0-1 flag form) are pinned by schema_test; these are the
//! unit-level contracts underneath them. `schema.applyBarProperties` is the
//! same decoder applyAll calls; collectPalette runs exactly as applyAll does
//! before the entries read.

const std = @import("std");
const testing = std.testing;

const color = @import("color");
const parser = @import("parser");
const schema = @import("schema");
const types = @import("types");

fn load(a: std.mem.Allocator, cfg: *types.Config, src: []const u8) !void {
    var doc = try parser.parse(a, src, "<bar-props-test>");
    color.collectPalette(&doc);
    try schema.applyBarProperties(testing.allocator, &doc, cfg);
}

test "gates: pre-seeded maps clear when [bar] or [bar.properties] is absent" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var cfg: types.Config = .{};
    defer cfg.deinit(testing.allocator);
    // Map keys are owned by the Config and freed by cfg.deinit.
    try cfg.bar.segment_fg.put(testing.allocator, try testing.allocator.dupe(u8, "x"), 0x111111);
    try cfg.bar.segment_props.put(testing.allocator, try testing.allocator.dupe(u8, "y"), .{ .bold = true });
    try load(arena.allocator(), &cfg,
        \\[tiling]
    );
    try testing.expectEqual(@as(usize, 0), cfg.bar.segment_fg.count());
    try testing.expectEqual(@as(usize, 0), cfg.bar.segment_value_fg.count());
    try testing.expectEqual(@as(usize, 0), cfg.bar.segment_props.count());

    // [bar] present, [bar.properties] absent: same clearing, same empty result.
    try cfg.bar.segment_fg.put(testing.allocator, try testing.allocator.dupe(u8, "z"), 0x222222);
    try load(arena.allocator(), &cfg,
        \\[bar]
    );
    try testing.expectEqual(@as(usize, 0), cfg.bar.segment_fg.count());
    try testing.expectEqual(@as(usize, 0), cfg.bar.segment_value_fg.count());
    try testing.expectEqual(@as(usize, 0), cfg.bar.segment_props.count());
}

test "knob keys are excluded; plain and _value segment keys split correctly" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var cfg: types.Config = .{};
    defer cfg.deinit(testing.allocator);
    try load(arena.allocator(), &cfg,
        \\[bar]
        \\primary_color = "#aa0000"
        \\
        \\[bar.properties]
        \\title = primary_color
        \\cpu = "#00ff00"
        \\cpu_value = "#00aa00"
    );

    // "title" is a scalar knob (bar.title_accent_color), not a segment: the
    // segment pass skips it, leaving only cpu on the plain map and the
    // suffix-stripped "cpu" key on the value map.
    try testing.expectEqual(@as(usize, 1), cfg.bar.segment_fg.count());
    try testing.expect(cfg.bar.segment_fg.get("title") == null);
    try testing.expectEqual(@as(u32, 0x00FF00), cfg.bar.segment_fg.get("cpu").?);
    try testing.expectEqual(@as(usize, 1), cfg.bar.segment_value_fg.count());
    try testing.expectEqual(@as(u32, 0x00AA00), cfg.bar.segment_value_fg.get("cpu").?);
    try testing.expectEqual(@as(usize, 0), cfg.bar.segment_props.count());
}

test "_value entries are color-only: style spellings fall back to bar fg" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var cfg: types.Config = .{};
    defer cfg.deinit(testing.allocator);
    cfg.bar.fg = 0x070809;
    try load(arena.allocator(), &cfg,
        \\[bar]
        \\
        \\[bar.properties]
        \\cpu_value = "underline"
        \\ram_value = ["bold"]
    );

    // A style token on a _value key is not a color: the entry still lands on
    // the VALUE map (color-only contract) with the bar-fg fallback, and no
    // style flag is ever recorded for a _value key.
    try testing.expectEqual(@as(usize, 2), cfg.bar.segment_value_fg.count());
    try testing.expectEqual(@as(u32, 0x070809), cfg.bar.segment_value_fg.get("cpu").?);
    try testing.expectEqual(@as(u32, 0x070809), cfg.bar.segment_value_fg.get("ram").?);
    try testing.expectEqual(@as(usize, 0), cfg.bar.segment_props.count());
    try testing.expectEqual(@as(usize, 0), cfg.bar.segment_fg.count());
}

test "style-only base entries store props but add no color map entry" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var cfg: types.Config = .{};
    defer cfg.deinit(testing.allocator);
    cfg.bar.fg = 0x070809;
    try load(arena.allocator(), &cfg,
        \\[bar]
        \\
        \\[bar.properties]
        \\clock = "underline"
    );

    // No color map entry means segmentFg's `orelse cfg.bar.fg` fallback is
    // exactly what a segment without any entry would see.
    try testing.expectEqual(@as(usize, 0), cfg.bar.segment_fg.count());
    try testing.expectEqual(@as(usize, 1), cfg.bar.segment_props.count());
    try testing.expectEqual(types.SegmentProps{ .underline = true }, cfg.bar.segment_props.get("clock").?);
    try testing.expectEqual(@as(u32, 0x070809), cfg.bar.segmentFg("clock"));
}

test "palette references resolve after collectPalette" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var cfg: types.Config = .{};
    defer cfg.deinit(testing.allocator);
    try load(arena.allocator(), &cfg,
        \\[bar]
        \\primary_color = "#aa0000"
        \\
        \\[bar.properties]
        \\cpu = primary_color
    );

    try testing.expectEqual(@as(usize, 1), cfg.bar.segment_fg.count());
    try testing.expectEqual(@as(u32, 0xAA0000), cfg.bar.segment_fg.get("cpu").?);
}
