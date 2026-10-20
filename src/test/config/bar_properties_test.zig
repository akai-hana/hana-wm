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
const bar_config = @import("bar_config");
const types = @import("types");

fn load(a: std.mem.Allocator, cfg: *bar_config.Config, src: []const u8) !void {
    var doc = try parser.parse(a, src, "<bar-props-test>");
    color.collectPalette(&doc);
    try bar_config.applyBarProperties(testing.allocator, &doc, cfg);
}

test "gates: pre-seeded maps clear when [bar] or [bar.properties] is absent" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var cfg: bar_config.Config = .{};
    defer cfg.deinit(testing.allocator);
    // Map keys are owned by the Config and freed by cfg.deinit.
    try cfg.segment_fg.put(testing.allocator, try testing.allocator.dupe(u8, "x"), 0x111111);
    try cfg.segment_props.put(testing.allocator, try testing.allocator.dupe(u8, "y"), .{ .bold = true });
    try load(arena.allocator(), &cfg,
        \\[tiling]
    );
    try testing.expectEqual(@as(usize, 0), cfg.segment_fg.count());
    try testing.expectEqual(@as(usize, 0), cfg.segment_value_fg.count());
    try testing.expectEqual(@as(usize, 0), cfg.segment_props.count());

    // [bar] present, [bar.properties] absent: same clearing, same empty result.
    try cfg.segment_fg.put(testing.allocator, try testing.allocator.dupe(u8, "z"), 0x222222);
    try load(arena.allocator(), &cfg,
        \\[bar]
    );
    try testing.expectEqual(@as(usize, 0), cfg.segment_fg.count());
    try testing.expectEqual(@as(usize, 0), cfg.segment_value_fg.count());
    try testing.expectEqual(@as(usize, 0), cfg.segment_props.count());
}

test "knob keys are excluded; plain and _value segment keys split correctly" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var cfg: bar_config.Config = .{};
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
    try testing.expectEqual(@as(usize, 1), cfg.segment_fg.count());
    try testing.expect(cfg.segment_fg.get("title") == null);
    try testing.expectEqual(@as(u32, 0x00FF00), cfg.segment_fg.get("cpu").?);
    try testing.expectEqual(@as(usize, 1), cfg.segment_value_fg.count());
    try testing.expectEqual(@as(u32, 0x00AA00), cfg.segment_value_fg.get("cpu").?);
    try testing.expectEqual(@as(usize, 0), cfg.segment_props.count());
}

test "_value entries are color-only: style spellings fall back to bar fg" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var cfg: bar_config.Config = .{};
    defer cfg.deinit(testing.allocator);
    cfg.fg = 0x070809;
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
    try testing.expectEqual(@as(usize, 2), cfg.segment_value_fg.count());
    try testing.expectEqual(@as(u32, 0x070809), cfg.segment_value_fg.get("cpu").?);
    try testing.expectEqual(@as(u32, 0x070809), cfg.segment_value_fg.get("ram").?);
    try testing.expectEqual(@as(usize, 0), cfg.segment_props.count());
    try testing.expectEqual(@as(usize, 0), cfg.segment_fg.count());
}

test "style-only base entries store props but add no color map entry" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var cfg: bar_config.Config = .{};
    defer cfg.deinit(testing.allocator);
    cfg.fg = 0x070809;
    try load(arena.allocator(), &cfg,
        \\[bar]
        \\
        \\[bar.properties]
        \\clock = "underline"
    );

    // No color map entry means segmentFg's `orelse cfg.fg` fallback is
    // exactly what a segment without any entry would see.
    try testing.expectEqual(@as(usize, 0), cfg.segment_fg.count());
    try testing.expectEqual(@as(usize, 1), cfg.segment_props.count());
    try testing.expectEqual(bar_config.SegmentProps{ .underline = true }, cfg.segment_props.get("clock").?);
    try testing.expectEqual(@as(u32, 0x070809), cfg.segmentFg("clock"));
}

test "palette references resolve after collectPalette" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var cfg: bar_config.Config = .{};
    defer cfg.deinit(testing.allocator);
    try load(arena.allocator(), &cfg,
        \\[bar]
        \\primary_color = "#aa0000"
        \\
        \\[bar.properties]
        \\cpu = primary_color
    );

    try testing.expectEqual(@as(usize, 1), cfg.segment_fg.count());
    try testing.expectEqual(@as(u32, 0xAA0000), cfg.segment_fg.get("cpu").?);
}

test "P2-64: size=N pins a segment's absolute text size" {
    // Style-only single token: props with a size, and no color entry at all
    // (the same early return a bare `underline` takes).
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var cfg: bar_config.Config = .{};
    defer cfg.deinit(testing.allocator);
    try load(arena.allocator(), &cfg,
        \\[bar]
        \\
        \\[bar.properties]
        \\clock = size=14
    );
    try testing.expectEqual(bar_config.SegmentProps{ .size = 14 }, cfg.segment_props.get("clock").?);
    try testing.expectEqual(@as(usize, 0), cfg.segment_fg.count());

    // Composite form: color, flag and size land together.
    var arena2 = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena2.deinit();
    var cfg2: bar_config.Config = .{};
    defer cfg2.deinit(testing.allocator);
    try load(arena2.allocator(), &cfg2,
        \\[bar]
        \\
        \\[bar.properties]
        \\cpu = #ff0000 bold size=12
    );
    try testing.expectEqual(@as(usize, 1), cfg2.segment_fg.count());
    try testing.expectEqual(@as(u32, 0xff0000), cfg2.segmentFg("cpu"));
    try testing.expectEqual(bar_config.SegmentProps{ .bold = true, .size = 12 }, cfg2.segment_props.get("cpu").?);

    // Out of range (or non-integer) sizes are not recognized tokens: no
    // props entry, exactly as an unknown style flag.
    var arena3 = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena3.deinit();
    var cfg3: bar_config.Config = .{};
    defer cfg3.deinit(testing.allocator);
    try load(arena3.allocator(), &cfg3,
        \\[bar]
        \\
        \\[bar.properties]
        \\ram = size=0
    );
    try testing.expectEqual(bar_config.SegmentProps{}, cfg3.segment_props.get("ram") orelse bar_config.SegmentProps{});
    try testing.expectEqual(@as(usize, 0), cfg3.segment_props.count());
}
