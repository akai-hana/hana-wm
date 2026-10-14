//! `parseRules` unit tests: the three directions of the [workspace.rules] /
//! [rules] families plus the warn-and-skip edges the schema-level end-to-end
//! test (schema_test) does not reach -- digit-run discrimination, oversized
//! workspace keys, bound checks, and the numbered-section suffix rules.
//! Class names are duped onto the Config with testing.allocator (leak-
//! checked); the document lives in a per-test arena.

const std = @import("std");
const testing = std.testing;

const parser = @import("parser");
const rules = @import("rules");
const types = @import("types");

fn load(a: std.mem.Allocator, cfg: *types.Config, src: []const u8) !void {
    var doc = try parser.parse(a, src, "<rules-test>");
    try rules.parseRules(testing.allocator, &doc, cfg);
}

fn findRule(cfg: *types.Config, class: []const u8) ?types.Rule {
    for (cfg.workspaces.rules.items) |r|
        if (std.mem.eql(u8, r.class_name, class)) return r;
    return null;
}

fn expectRule(
    cfg: *types.Config,
    class: []const u8,
    workspace_0based: u8,
    is_float: bool,
) !void {
    const r = findRule(cfg, class) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(workspace_0based, r.workspace);
    try testing.expectEqual(is_float, r.float);
}

test "[rules]: int and float rules land; bad values skip" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var cfg: types.Config = .{};
    defer cfg.deinit(testing.allocator);
    // Default WorkspaceConfig.count is 9, so 10 is out of range; 0 is below
    // the 1-based minimum; the non-float string is unsupported.
    try load(arena.allocator(), &cfg,
        \\[rules]
        \\Firefox = 2
        \\foot = "float"
        \\wechat = "pinned"
        \\spotify = 0
        \\discord = 10
    );

    try testing.expectEqual(@as(usize, 2), cfg.workspaces.rules.items.len);
    // Append order follows document order.
    try testing.expectEqualStrings("Firefox", cfg.workspaces.rules.items[0].class_name);
    try testing.expectEqual(@as(u8, 1), cfg.workspaces.rules.items[0].workspace);
    try testing.expectEqualStrings("foot", cfg.workspaces.rules.items[1].class_name);
    try testing.expect(cfg.workspaces.rules.items[1].float);
}

test "[workspace.rules]: array direction and class direction interleave in order" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var cfg: types.Config = .{};
    defer cfg.deinit(testing.allocator);
    try load(arena.allocator(), &cfg,
        \\[workspace.rules]
        \\1 = ["Firefox", "Slack"]
        \\Alacritty = 3
    );

    try testing.expectEqual(@as(usize, 3), cfg.workspaces.rules.items.len);
    try testing.expectEqualStrings("Firefox", cfg.workspaces.rules.items[0].class_name);
    try testing.expectEqual(@as(u8, 0), cfg.workspaces.rules.items[0].workspace);
    try testing.expectEqualStrings("Slack", cfg.workspaces.rules.items[1].class_name);
    try testing.expectEqual(@as(u8, 0), cfg.workspaces.rules.items[1].workspace);
    try testing.expectEqualStrings("Alacritty", cfg.workspaces.rules.items[2].class_name);
    try testing.expectEqual(@as(u8, 2), cfg.workspaces.rules.items[2].workspace);
}

test "digit-prefixed class keys stay class rules, never coerce" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var cfg: types.Config = .{};
    defer cfg.deinit(testing.allocator);
    // "12x" starts with digits but is not all-digits: a class rule (the
    // leading-digit warning path), with the value read as an integer.
    try load(arena.allocator(), &cfg,
        \\[workspace.rules]
        \\12x = 4
    );

    try testing.expectEqual(@as(usize, 1), cfg.workspaces.rules.items.len);
    try expectRule(&cfg, "12x", 3, false);
}

test "oversized digit keys, non-array values, and out-of-range workspaces all skip" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var cfg: types.Config = .{};
    defer cfg.deinit(testing.allocator);
    try load(arena.allocator(), &cfg,
        \\[workspace.rules]
        \\9999999999999999999999 = ["X"]
        \\2 = "notarray"
        \\0 = ["Y"]
    );

    try testing.expectEqual(@as(usize, 0), cfg.workspaces.rules.items.len);
}

test "numbered sections: suffix is the workspace, member values are ignored" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var cfg: types.Config = .{};
    defer cfg.deinit(testing.allocator);
    try load(arena.allocator(), &cfg,
        \\[rules.2]
        \\Foo = 1
        \\Bar = 999
        \\
        \\[rules.foo]
        \\Q = 1
        \\
        \\[rules.10]
        \\Z = 1
        \\
        \\[rules.0]
        \\W = 1
    );

    // Only [rules.2] parses (suffix 2, in range 1..9): its member VALUES
    // never matter -- the section name carries the workspace. Non-numeric,
    // zero, and over-count suffixes warn and skip.
    try testing.expectEqual(@as(usize, 2), cfg.workspaces.rules.items.len);
    try expectRule(&cfg, "Foo", 1, false);
    try expectRule(&cfg, "Bar", 1, false);
}

test "the workspace.rules numbered prefix behaves identically" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var cfg: types.Config = .{};
    defer cfg.deinit(testing.allocator);
    try load(arena.allocator(), &cfg,
        \\[workspace.rules.3]
        \\One = "ignored"
    );

    try testing.expectEqual(@as(usize, 1), cfg.workspaces.rules.items.len);
    try expectRule(&cfg, "One", 2, false);
}

test "a class name equal to a workspace number in [rules] still binds" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var cfg: types.Config = .{};
    defer cfg.deinit(testing.allocator);
    // [rules] is always class-keyed: the key is never workspace-disambiguated,
    // so class "1" with value 2 is a class rule (unlike [workspace.rules]).
    try load(arena.allocator(), &cfg,
        \\[rules]
        \\1 = 2
    );

    try testing.expectEqual(@as(usize, 1), cfg.workspaces.rules.items.len);
    try expectRule(&cfg, "1", 1, false);
}
