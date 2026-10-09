//! `parseTilingStructures` unit tests: the layouts array (lowercasing,
//! case-insensitive dedup, trailing variants/workspace-list groups), the
//! flat and sub-table variant keys (with master-alias folding), the master
//! counts table (valid + every skip path), and the [tiling] gate. The
//! 256-entry cap is pinned by schema_test's "layouts array caps at 256
//! entries"; this file covers the rest at unit level. Owned strings land on
//! the Config with testing.allocator (leak-checked by cfg.deinit).

const std = @import("std");
const testing = std.testing;

const parser = @import("parser");
const tiling_sections = @import("tiling_sections");
const types = @import("types");

fn load(a: std.mem.Allocator, cfg: *types.Config, src: []const u8) !void {
    var doc = try parser.parse(a, src, "<tiling-sections-test>");
    try tiling_sections.parseTilingStructures(testing.allocator, &doc, cfg);
}

test "no layouts array: the layout string seeds the cycle, canonicalized" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var cfg: types.Config = .{};
    defer cfg.deinit(testing.allocator);

    try load(arena.allocator(), &cfg,
        \\[tiling]
        \\layout = "master-stack"
    );
    try testing.expectEqual(@as(usize, 1), cfg.tiling.layouts.items.len);
    try testing.expectEqualStrings("master", cfg.tiling.layouts.items[0]);

    // Neither key: the canonical master default.
    try load(arena.allocator(), &cfg,
        \\[tiling]
    );
    try testing.expectEqual(@as(usize, 1), cfg.tiling.layouts.items.len);
    try testing.expectEqualStrings("master", cfg.tiling.layouts.items[0]);
}

test "layouts array: lowercase storage, case-insensitive dedup, junk skipped" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var cfg: types.Config = .{};
    defer cfg.deinit(testing.allocator);
    try load(arena.allocator(), &cfg,
        \\[tiling]
        \\layouts = ["Master-Stack", "monocle", "MASTER", 42]
    );

    try testing.expectEqual(@as(usize, 2), cfg.tiling.layouts.items.len);
    try testing.expectEqualStrings("master", cfg.tiling.layouts.items[0]);
    try testing.expectEqualStrings("monocle", cfg.tiling.layouts.items[1]);
}

test "trailing variants word stores under the canonical layout name" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var cfg: types.Config = .{};
    defer cfg.deinit(testing.allocator);
    // "rtl" is not a layout name -> variants word; "monocle" is -> new group.
    try load(arena.allocator(), &cfg,
        \\[tiling]
        \\layouts = ["master-stack", "rtl", "monocle"]
    );

    try testing.expectEqual(@as(usize, 2), cfg.tiling.layouts.items.len);
    try testing.expectEqualStrings("master", cfg.tiling.layouts.items[0]);
    try testing.expectEqualStrings("monocle", cfg.tiling.layouts.items[1]);
    try testing.expectEqualStrings("rtl", cfg.tiling.variants.get("master").?);
    try testing.expectEqual(@as(usize, 0), cfg.tiling.workspace_layout_overrides.items.len);
}

test "trailing workspace list appends overrides in token order" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var cfg: types.Config = .{};
    defer cfg.deinit(testing.allocator);
    try load(arena.allocator(), &cfg,
        \\[tiling]
        \\layouts = ["grid", "1, 3"]
    );

    try testing.expectEqual(@as(usize, 1), cfg.tiling.layouts.items.len);
    try testing.expectEqualStrings("grid", cfg.tiling.layouts.items[0]);
    try testing.expectEqual(@as(usize, 2), cfg.tiling.workspace_layout_overrides.items.len);
    const o0 = cfg.tiling.workspace_layout_overrides.items[0];
    try testing.expectEqual(@as(u8, 0), o0.workspace_idx.index);
    try testing.expectEqual(@as(u8, 0), o0.layout_idx);
    try testing.expect(o0.variant == null);
    const o1 = cfg.tiling.workspace_layout_overrides.items[1];
    try testing.expectEqual(@as(u8, 2), o1.workspace_idx.index);
    try testing.expectEqual(@as(u8, 0), o1.layout_idx);
}

test "variants word followed by a workspace list: each override owns a copy" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var cfg: types.Config = .{};
    defer cfg.deinit(testing.allocator);
    try load(arena.allocator(), &cfg,
        \\[tiling]
        \\layouts = ["master-stack", "rtl", "2,4"]
    );

    try testing.expectEqual(@as(usize, 2), cfg.tiling.workspace_layout_overrides.items.len);
    const o0 = cfg.tiling.workspace_layout_overrides.items[0];
    try testing.expectEqual(@as(u8, 1), o0.workspace_idx.index);
    try testing.expectEqual(@as(u8, 0), o0.layout_idx);
    try testing.expectEqualStrings("rtl", o0.variant.?);
    const o1 = cfg.tiling.workspace_layout_overrides.items[1];
    try testing.expectEqual(@as(u8, 3), o1.workspace_idx.index);
    try testing.expectEqual(@as(u8, 0), o1.layout_idx);
    try testing.expectEqualStrings("rtl", o1.variant.?);
    try testing.expect(o0.variant.?.ptr != o1.variant.?.ptr);
}

test "flat [tiling] variant keys map onto canonical layout names" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var cfg: types.Config = .{};
    defer cfg.deinit(testing.allocator);
    try load(arena.allocator(), &cfg,
        \\[tiling]
        \\master_variant = "mz"
        \\monocle_variant = "cz"
        \\grid_variant = "gz"
    );

    try testing.expectEqual(@as(usize, 3), cfg.tiling.variants.count());
    try testing.expectEqualStrings("mz", cfg.tiling.variants.get("master").?);
    try testing.expectEqualStrings("cz", cfg.tiling.variants.get("monocle").?);
    try testing.expectEqualStrings("gz", cfg.tiling.variants.get("grid").?);
}

test "sub-table variants fold a master alias spelling onto the same key" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var cfg: types.Config = .{};
    defer cfg.deinit(testing.allocator);
    try load(arena.allocator(), &cfg,
        \\[tiling]
        \\
        \\[tiling.layouts.master_stack]
        \\variants = "x"
    );

    try testing.expectEqual(@as(usize, 1), cfg.tiling.variants.count());
    try testing.expectEqualStrings("x", cfg.tiling.variants.get("master").?);
}

test "master counts: valid rows land, every invalid row skips" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var cfg: types.Config = .{};
    defer cfg.deinit(testing.allocator);
    // constants.max_workspaces is 64 -> workspace 65 is out of range;
    // counts are capped at 10; "abc" is not a number; 4's value is a string.
    try load(arena.allocator(), &cfg,
        \\[tiling]
        \\
        \\[tiling.layouts.master-stack.counts]
        \\1 = 3
        \\5 = 0
        \\65 = 2
        \\abc = 1
        \\2 = -1
        \\3 = 99
        \\4 = "x"
    );

    try testing.expectEqual(@as(usize, 2), cfg.tiling.workspace_master_count_overrides.items.len);
    const m0 = cfg.tiling.workspace_master_count_overrides.items[0];
    try testing.expectEqual(@as(u8, 0), m0.workspace_idx.index);
    try testing.expectEqual(@as(u8, 3), m0.count);
    const m1 = cfg.tiling.workspace_master_count_overrides.items[1];
    try testing.expectEqual(@as(u8, 4), m1.workspace_idx.index);
    try testing.expectEqual(@as(u8, 0), m1.count);
}

test "counts tables of non-master layouts are ignored entirely" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var cfg: types.Config = .{};
    defer cfg.deinit(testing.allocator);
    try load(arena.allocator(), &cfg,
        \\[tiling]
        \\
        \\[tiling.layouts.monocle.counts]
        \\1 = 3
    );

    try testing.expectEqual(@as(usize, 0), cfg.tiling.workspace_master_count_overrides.items.len);
    try testing.expectEqual(@as(usize, 0), cfg.tiling.variants.count());
}

test "overlong layout names warn-and-skip, the rest still land" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var cfg: types.Config = .{};
    defer cfg.deinit(testing.allocator);
    // max_layout_name is types.max_config_name (32): a 33-byte name is over.
    var long: [33]u8 = undefined;
    @memset(&long, 'x');
    var src_buf: [128]u8 = undefined;
    const src = try std.fmt.bufPrint(&src_buf, "[tiling]\nlayouts = [\"{s}\", \"master\"]\n", .{&long});
    try load(arena.allocator(), &cfg, src);

    try testing.expectEqual(@as(usize, 1), cfg.tiling.layouts.items.len);
    try testing.expectEqualStrings("master", cfg.tiling.layouts.items[0]);
}

test "everything is gated on the [tiling] parent section" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var cfg: types.Config = .{};
    defer cfg.deinit(testing.allocator);
    try load(arena.allocator(), &cfg,
        \\[tiling.layouts.master-stack]
        \\variants = "x"
    );

    try testing.expectEqual(@as(usize, 0), cfg.tiling.layouts.items.len);
    try testing.expectEqual(@as(usize, 0), cfg.tiling.variants.count());
}
