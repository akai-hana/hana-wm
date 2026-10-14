//! `parseBar` (bar_sections.zig) unit tests: the bar's non-scalar structures
//! the comptime schema walk does not cover -- fonts, the indicator mirror
//! pair, workspace icons (array/string/pad forms), and the per-anchor bar
//! layout columns with the default-layout fallbacks. All owned strings land
//! on the Config with testing.allocator (leak-checked by cfg.deinit); the
//! document lives in a per-test arena.

const std = @import("std");
const testing = std.testing;

const bar_sections = @import("bar_sections");
const parser = @import("parser");
const types = @import("types");

fn load(a: std.mem.Allocator, cfg: *types.Config, src: []const u8) !void {
    var doc = try parser.parse(a, src, "<bar-sections-test>");
    try bar_sections.parseBar(testing.allocator, &doc, cfg);
}

test "no per-anchor layout: defaults land, icons pad to the workspace count" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var cfg: types.Config = .{};
    defer cfg.deinit(testing.allocator);
    try load(arena.allocator(), &cfg,
        \\[bar]
    );

    // Default layout: left/workspaces, center/title, right/clock, in anchor order.
    try testing.expectEqual(@as(usize, 3), cfg.bar.layout.items.len);
    const expect_pos = [_]types.BarSegmentAnchor{ .left, .center, .right };
    const expect_seg = [_][]const u8{ "workspaces", "title", "clock" };
    for (cfg.bar.layout.items, 0..) |layout, i| {
        try testing.expectEqual(expect_pos[i], layout.position);
        try testing.expectEqual(@as(usize, 1), layout.segments.items.len);
        try testing.expectEqualStrings(expect_seg[i], layout.segments.items[0]);
    }

    // Absent icons still pad to workspaces.count (default 9): "1".."9".
    try testing.expectEqual(@as(usize, 9), cfg.bar.workspace_icons.items.len);
    for (cfg.bar.workspace_icons.items, 0..) |icon, i| {
        var buf: [4]u8 = undefined;
        const want = try std.fmt.bufPrint(&buf, "{}", .{i + 1});
        try testing.expectEqualStrings(want, icon);
    }
}

test "per-anchor layout sections replace defaults in fixed anchor order" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var cfg: types.Config = .{};
    defer cfg.deinit(testing.allocator);
    // right is declared first in the document, but anchor order is fixed:
    // left precedes right regardless of document order.
    try load(arena.allocator(), &cfg,
        \\[bar]
        \\
        \\[bar.layout.right]
        \\segments = ["clock", "cpu", true]
        \\
        \\[bar.layout.left]
        \\segments = ["workspaces", "tags"]
    );

    try testing.expectEqual(@as(usize, 2), cfg.bar.layout.items.len);
    try testing.expectEqual(types.BarSegmentAnchor.left, cfg.bar.layout.items[0].position);
    try testing.expectEqual(@as(usize, 2), cfg.bar.layout.items[0].segments.items.len);
    try testing.expectEqualStrings("workspaces", cfg.bar.layout.items[0].segments.items[0]);
    try testing.expectEqualStrings("tags", cfg.bar.layout.items[0].segments.items[1]);
    try testing.expectEqual(types.BarSegmentAnchor.right, cfg.bar.layout.items[1].position);
    // The non-string entry is skipped (and warned about), leaving two segments.
    try testing.expectEqual(@as(usize, 2), cfg.bar.layout.items[1].segments.items.len);
    try testing.expectEqualStrings("clock", cfg.bar.layout.items[1].segments.items[0]);
    try testing.expectEqualStrings("cpu", cfg.bar.layout.items[1].segments.items[1]);
}

test "empty layout sections and non-anchor names both fall back to defaults" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var cfg: types.Config = .{};
    defer cfg.deinit(testing.allocator);
    try load(arena.allocator(), &cfg,
        \\[bar]
        \\
        \\[bar.layout.center]
        \\segments = []
        \\
        \\[bar.layout.top]
        \\segments = ["mystery"]
    );

    // center produced no segments -> nothing appended; top is no anchor ->
    // ignored; zero entries -> the default three-column layout.
    try testing.expectEqual(@as(usize, 3), cfg.bar.layout.items.len);
    try testing.expectEqual(types.BarSegmentAnchor.left, cfg.bar.layout.items[0].position);
    try testing.expectEqual(types.BarSegmentAnchor.center, cfg.bar.layout.items[1].position);
    try testing.expectEqual(types.BarSegmentAnchor.right, cfg.bar.layout.items[2].position);
}

test "fonts replace the previous list and silently drop non-string entries" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var cfg: types.Config = .{};
    defer cfg.deinit(testing.allocator);
    try cfg.bar.fonts.append(testing.allocator, try testing.allocator.dupe(u8, "OLD"));

    try load(arena.allocator(), &cfg,
        \\[bar]
        \\fonts = ["JetBrains Mono 10", 42, "Noto Sans 12"]
    );

    try testing.expectEqual(@as(usize, 2), cfg.bar.fonts.items.len);
    try testing.expectEqualStrings("JetBrains Mono 10", cfg.bar.fonts.items[0]);
    try testing.expectEqualStrings("Noto Sans 12", cfg.bar.fonts.items[1]);
}

test "indicator pair: one key mirrors the other, both keys stay independent" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var cfg: types.Config = .{};
    defer cfg.deinit(testing.allocator);

    try load(arena.allocator(), &cfg,
        \\[bar]
        \\indicator_focused = "●"
    );
    try testing.expectEqualStrings("●", cfg.bar.indicator_focused.?);
    try testing.expectEqualStrings("●", cfg.bar.indicator_unfocused.?);

    try load(arena.allocator(), &cfg,
        \\[bar]
        \\indicator_unfocused = "○"
    );
    try testing.expectEqualStrings("○", cfg.bar.indicator_focused.?);
    try testing.expectEqualStrings("○", cfg.bar.indicator_unfocused.?);

    try load(arena.allocator(), &cfg,
        \\[bar]
        \\indicator_focused = "F"
        \\indicator_unfocused = "U"
    );
    try testing.expectEqualStrings("F", cfg.bar.indicator_focused.?);
    try testing.expectEqualStrings("U", cfg.bar.indicator_unfocused.?);
}

test "workspace icons: mixed array keeps ints as number strings, then pads" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var cfg: types.Config = .{};
    defer cfg.deinit(testing.allocator);
    try load(arena.allocator(), &cfg,
        \\[bar]
        \\icons = ["一", "二", 3, "四"]
    );

    try testing.expectEqual(@as(usize, 9), cfg.bar.workspace_icons.items.len);
    const prefix = [_][]const u8{ "一", "二", "3", "四" };
    for (prefix, 0..) |want, i| try testing.expectEqualStrings(want, cfg.bar.workspace_icons.items[i]);
    // Padding continues with the numbers AFTER the four supplied entries.
    try testing.expectEqualStrings("5", cfg.bar.workspace_icons.items[4]);
    try testing.expectEqualStrings("9", cfg.bar.workspace_icons.items[8]);
}

test "workspace icons: the string form splits into single characters" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var cfg: types.Config = .{};
    defer cfg.deinit(testing.allocator);
    try load(arena.allocator(), &cfg,
        \\[bar]
        \\icons = "ab"
    );

    try testing.expectEqual(@as(usize, 9), cfg.bar.workspace_icons.items.len);
    try testing.expectEqualStrings("a", cfg.bar.workspace_icons.items[0]);
    try testing.expectEqualStrings("b", cfg.bar.workspace_icons.items[1]);
    try testing.expectEqualStrings("3", cfg.bar.workspace_icons.items[2]);
    try testing.expectEqualStrings("9", cfg.bar.workspace_icons.items[8]);
}

test "padWorkspaceIcons tops a pre-seeded list up to the workspace count" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var cfg: types.Config = .{};
    defer cfg.deinit(testing.allocator);
    try cfg.bar.workspace_icons.append(testing.allocator, try testing.allocator.dupe(u8, "X"));

    try bar_sections.padWorkspaceIcons(testing.allocator, &cfg);

    try testing.expectEqual(@as(usize, 9), cfg.bar.workspace_icons.items.len);
    try testing.expectEqualStrings("X", cfg.bar.workspace_icons.items[0]);
    try testing.expectEqualStrings("2", cfg.bar.workspace_icons.items[1]);
    try testing.expectEqualStrings("9", cfg.bar.workspace_icons.items[8]);
}

test "everything is gated on the [bar] parent section" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var cfg: types.Config = .{};
    defer cfg.deinit(testing.allocator);
    // bar.layout.left alone must NOT seed anything: no [bar], no parse.
    try load(arena.allocator(), &cfg,
        \\[bar.layout.left]
        \\segments = ["workspaces"]
    );

    try testing.expectEqual(@as(usize, 0), cfg.bar.layout.items.len);
    try testing.expectEqual(@as(usize, 0), cfg.bar.workspace_icons.items.len);
}
