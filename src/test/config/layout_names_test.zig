//! Layout-name grammar tests: master-stack alias canonicalization (case-
//! insensitive, slice-aliasing), the known-spelling set config and the tiling
//! tests both assert against, and the normalize/isLayoutName pair including
//! the oversize warn-and-skip boundary.

const std = @import("std");
const testing = std.testing;

const layout_names = @import("layout_names");
const types = @import("types");

test "master-stack aliases canonicalize to the registry spelling, any case" {
    const spellings = [_][]const u8{ "master-stack", "master_stack", "MASTER-STACK", "Master_Stack", "MASTER_stack" };
    for (spellings) |s|
        try testing.expectEqualStrings(types.canon_master_layout, layout_names.canonicalLayoutName(s));
}

test "canonicalLayoutName passes unrelated names through as the same slice" {
    const s: []const u8 = "Monocle";
    try testing.expect(layout_names.canonicalLayoutName(s).ptr == s.ptr);
    try testing.expectEqualStrings("Monocle", layout_names.canonicalLayoutName(s));
}

test "isLayoutName accepts every grammar spelling, any case, and rejects unknowns" {
    const known = [_][]const u8{ "master", "master-stack", "master_stack", "monocle", "grid", "fibonacci", "leaf", "scroll" };
    for (known) |name| try testing.expect(layout_names.isLayoutName(name));
    for ([_][]const u8{ "MASTER", "MonOcLe", "MASTER_STACK" }) |name|
        try testing.expect(layout_names.isLayoutName(name));

    try testing.expect(!layout_names.isLayoutName("bogus"));
    try testing.expect(!layout_names.isLayoutName(""));
    // A real word that is not a layout stays out of the grammar set.
    try testing.expect(!layout_names.isLayoutName("deck"));
}

test "layout_name_grammar holds exactly the known spellings" {
    try testing.expectEqual(@as(usize, 8), layout_names.layout_name_grammar.keys().len);
    const known = [_][]const u8{ "master", "master-stack", "master_stack", "monocle", "grid", "fibonacci", "leaf", "scroll" };
    for (known) |name| try testing.expect(layout_names.layout_name_grammar.has(name));
}

test "normalizeLayoutName: exact-fit passes, one byte over warns-and-skips" {
    var buf: [layout_names.max_layout_name]u8 = undefined;
    var exact: [layout_names.max_layout_name]u8 = undefined;
    @memset(&exact, 'x');
    const ok = layout_names.normalizeLayoutName(&buf, &exact);
    try testing.expect(ok != null);
    try testing.expectEqualStrings(&exact, ok.?);

    var over: [layout_names.max_layout_name + 1]u8 = undefined;
    @memset(&over, 'x');
    try testing.expect(layout_names.normalizeLayoutName(&buf, &over) == null);
    try testing.expect(!layout_names.isLayoutName(&over));
}
