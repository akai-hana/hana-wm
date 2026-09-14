//! TOML-subset parser tests: the deterministic in-memory Document layer that
//! config.zig/schema.zig consume. These exercise the raw parser (parse,
//! mergeDocumentsInto, parseColor) without touching config loading, keeping
//! them hermetic and fast. Every parse lives in a per-test arena, matching
//! the load-scoped arena the real config pipeline uses.

const std = @import("std");
const testing = std.testing;

// The tests deliberately feed the parser invalid input, which emits
// warn-level diagnostics; src/core/utils/debug.zig silences all std.log
// diagnostics in test binaries, so this stays quiet on success.
const parser = @import("parser");

/// Parses into the caller's arena (like the load-scoped arena the real config
/// pipeline uses); the caller owns the arena and frees it after use. Named
/// "<test>" so diagnostics identify the source.
fn parse(a: std.mem.Allocator, src: []const u8) !parser.Document {
    return parser.parse(a, src, "<test>");
}

test "parses root + named sections into a flat Document" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var doc = try parse(arena.allocator(),
        \\str_key = "hello"
        \\num = 42
        \\flag = true
        \\[general]
        \\width = 800
        \\name = "hana"
        \\[general]
        \\extra = 1.5
    );

    // Root-level keys land on the root section.
    try testing.expectEqualStrings("hello", doc.root.get("str_key").?.asScalar([]const u8).?);
    try testing.expectEqual(@as(i64, 42), doc.root.get("num").?.asScalar(i64).?);
    try testing.expectEqual(true, doc.root.get("flag").?.asScalar(bool).?);

    // Named sections, including duplicate headers collapsing into one.
    const general = doc.sections.getPtr("general").?;
    try testing.expectEqual(@as(i64, 800), general.get("width").?.asScalar(i64).?);
    try testing.expectEqualStrings("hana", general.get("name").?.asScalar([]const u8).?);
    // Bare decimals parse as absolute ScalableValues, not strings.
    const extra = general.get("extra").?;
    try testing.expectEqual(@as(f32, 1.5), extra.asScalar(parser.ScalableValue).?.value);
    try testing.expect(!extra.asScalar(parser.ScalableValue).?.is_percentage);
}

test "double-quoted strings resolve escapes; single-quoted pass through" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var doc = try parse(arena.allocator(), "a = \"line1\\nline2\\ttab\"\n" ++ "b = 'raw\\nnot-an-escape'\n");

    try testing.expectEqualStrings("line1\nline2\ttab", doc.root.get("a").?.asScalar([]const u8).?);
    // TOML literal strings keep backslashes verbatim.
    try testing.expectEqualStrings("raw\\nnot-an-escape", doc.root.get("b").?.asScalar([]const u8).?);
}

test "missing key / missing section yield absent, not panic" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var doc = try parse(arena.allocator(), "present = 1\n");
    try testing.expect(doc.root.get("absent") == null);
    try testing.expect(doc.sections.getPtr("nope") == null);
}

test "parseColor accepts forms and rejects out-of-range" {
    try testing.expectEqual(@as(u32, 0xFFFFFF), try parser.parseColor("0xFFFFFF"));
    try testing.expectEqual(@as(u32, 0x61AFEF), try parser.parseColor("#61AFEF"));
    try testing.expectEqual(@as(u32, 0xFF), try parser.parseColor("#0000ff"));
    try testing.expectEqual(@as(u32, 0x123456), try parser.parseColor("123456"));
    // 8 hex digits (ARGB / >24-bit) are out of range for this schema.
    try testing.expectError(error.InvalidColor, parser.parseColor("0xFFFFFFFF"));
    try testing.expectError(error.InvalidColor, parser.parseColor(""));
    try testing.expectError(error.InvalidColor, parser.parseColor("zzz"));
}

test "mergeDocumentsInto: later document wins for scalars" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var base = try parser.parse(a, "theme = \"dark\"\n[bar]\nheight = 24\n", "<test>");
    var overlay = try parser.parse(a, "theme = \"light\"\n[bar]\nheight = 32\n", "<test>");

    try parser.mergeDocumentsInto(a, &base, &overlay);

    try testing.expectEqualStrings("light", base.root.get("theme").?.asScalar([]const u8).?);
    const bar = base.sections.getPtr("bar").?;
    try testing.expectEqual(@as(i64, 32), bar.get("height").?.asScalar(i64).?);
}

test "malformed lines are skipped without aborting the parse" {
    // A bad section header and a bad value don't poison the documents; the
    // parser recovers by skipping to the next line.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var doc = try parse(arena.allocator(),
        \\[broken header
        \\good = "value"
        \\[sane]
        \\kept = 7
    );

    try testing.expectEqualStrings("value", doc.root.get("good").?.asScalar([]const u8).?);
    const sane = doc.sections.getPtr("sane").?;
    try testing.expectEqual(@as(i64, 7), sane.get("kept").?.asScalar(i64).?);
    // C1: skipped lines flag the Document so the load can fail on broken configs.
    try testing.expect(doc.had_errors);
}

test "duplicate key accumulates and flags scalar-duplicate reads" {
    // C14: a genuine repeated declaration reads as an array; a scalar read
    // resolves to the last declaration and calls it out (warn-level).
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var doc = try parse(a,
        \\[demo]
        \\count = 3
        \\count = 5
    );

    const sec = doc.sections.getPtr("demo").?;
    const val = sec.get("count").?;
    try testing.expectEqual(@as(usize, 2), val.asArray().?.len);
    try testing.expectEqual(@as(i64, 5), sec.getAs(i64, "count").?);
}

test "wrong-case section header is a parse error through extends etc" {
    // Placeholder for C1 integration (buildConfigFromDoc-level tests live in
    // config_test.zig); parser-level just verifies source_path plumbing.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const doc = try parser.parse(arena.allocator(), "[bar]\nheight = 24\n", "cfg/extra.toml");
    try testing.expectEqualStrings("cfg/extra.toml", doc.source_path);
}
