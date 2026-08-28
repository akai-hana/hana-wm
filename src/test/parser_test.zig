//! TOML-subset parser tests: the deterministic in-memory Document layer that
//! config.zig/schema.zig consume. These exercise the raw parser (parse,
//! mergeDocumentsInto, parseColor) without touching config loading, keeping
//! them hermetic and fast.

const std = @import("std");
const testing = std.testing;

const parser = @import("parser");

test "P1 parses root + named sections into a flat Document" {
    const alloc = testing.allocator;
    const src =
        \\str_key = "hello"
        \\num = 42
        \\flag = true
        \\[general]
        \\width = 800
        \\name = "hana"
        \\[general]
        \\extra = 1.5
    ;
    var doc = try parser.parse(alloc, src);
    defer doc.deinit();

    // Root-level keys land on the root section.
    try testing.expectEqualStrings("hello", doc.root.get("str_key").?.asString().?);
    try testing.expectEqual(@as(i64, 42), doc.root.get("num").?.asInt().?);
    try testing.expectEqual(true, doc.root.get("flag").?.asBool().?);

    // Named sections, including duplicate headers collapsing into one.
    const general = doc.sections.getPtr("general").?;
    try testing.expectEqual(@as(i64, 800), general.get("width").?.asInt().?);
    try testing.expectEqualStrings("hana", general.get("name").?.asString().?);
    // Bare decimals parse as absolute ScalableValues, not strings.
    const extra = general.get("extra").?;
    try testing.expectEqual(@as(f32, 1.5), extra.asScalable().?.value);
    try testing.expect(!extra.asScalable().?.is_percentage);
}

test "P2 double-quoted strings resolve escapes; single-quoted pass through" {
    const alloc = testing.allocator;
    const src = "a = \"line1\\nline2\\ttab\"\n" ++ "b = 'raw\\nnot-an-escape'\n";
    var doc = try parser.parse(alloc, src);
    defer doc.deinit();

    try testing.expectEqualStrings("line1\nline2\ttab", doc.root.get("a").?.asString().?);
    // TOML literal strings keep backslashes verbatim.
    try testing.expectEqualStrings("raw\\nnot-an-escape", doc.root.get("b").?.asString().?);
}

test "P3 missing key / missing section yield absent, not panic" {
    const alloc = testing.allocator;
    var doc = try parser.parse(alloc, "present = 1\n");
    defer doc.deinit();
    try testing.expect(doc.root.get("absent") == null);
    try testing.expect(doc.sections.getPtr("nope") == null);
}

test "P4 parseColor accepts forms and rejects out-of-range" {
    try testing.expectEqual(@as(u32, 0xFFFFFF), try parser.parseColor("0xFFFFFF"));
    try testing.expectEqual(@as(u32, 0x61AFEF), try parser.parseColor("#61AFEF"));
    try testing.expectEqual(@as(u32, 0xFF), try parser.parseColor("#0000ff"));
    try testing.expectEqual(@as(u32, 0x123456), try parser.parseColor("123456"));
    // 8 hex digits (ARGB / >24-bit) are out of range for this schema.
    try testing.expectError(error.InvalidColor, parser.parseColor("0xFFFFFFFF"));
    try testing.expectError(error.InvalidColor, parser.parseColor(""));
    try testing.expectError(error.InvalidColor, parser.parseColor("zzz"));
}

test "P5 mergeDocumentsInto: later document wins for scalars" {
    const alloc = testing.allocator;
    var base = try parser.parse(alloc, "theme = \"dark\"\n[bar]\nheight = 24\n");
    defer base.deinit();
    var overlay = try parser.parse(alloc, "theme = \"light\"\n[bar]\nheight = 32\n");
    defer overlay.deinit();

    try parser.mergeDocumentsInto(alloc, &base, &overlay);

    try testing.expectEqualStrings("light", base.root.get("theme").?.asString().?);
    const bar = base.sections.getPtr("bar").?;
    try testing.expectEqual(@as(i64, 32), bar.get("height").?.asInt().?);
}

test "P6 malformed lines are skipped without aborting the parse" {
    const alloc = testing.allocator;
    // A bad section header and a bad value don't poison the documents; the
    // parser recovers by skipping to the next line.
    const src =
        \\[broken header
        \\good = "value"
        \\[sane]
        \\kept = 7
    ;
    var doc = try parser.parse(alloc, src);
    defer doc.deinit();

    try testing.expectEqualStrings("value", doc.root.get("good").?.asString().?);
    const sane = doc.sections.getPtr("sane").?;
    try testing.expectEqual(@as(i64, 7), sane.get("kept").?.asInt().?);
}
