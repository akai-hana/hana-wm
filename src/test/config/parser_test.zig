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
const types = @import("types");

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
    try testing.expectEqual(@as(f32, 1.5), extra.asScalar(types.ScalableValue).?.value);
    try testing.expect(!extra.asScalar(types.ScalableValue).?.is_percentage);
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

test "colorFromValue: bare all-digit spellings are hex (6 or 8 digits), others invalid" {
    // A bare 6-digit number is #RRGGBB hex; 8 digits are #RRGGBBAA hex. Any
    // other bare integral value in a color context is rejected instead of
    // silently coerced to a decimal color.
    try testing.expectEqual(@as(u32, 0x112233), parser.colorFromValue(.{ .integer = 112233 }).?);
    try testing.expectEqual(@as(u32, 0x11223344), parser.colorFromValue(.{ .integer = 11223344 }).?);
    try testing.expectEqual(@as(u32, 0x99999999), parser.colorFromValue(.{ .integer = 99999999 }).?);
    try testing.expectEqual(@as(u32, 0x16777215), parser.colorFromValue(.{ .integer = 16777215 }).?);
    try testing.expect(parser.colorFromValue(.{ .integer = 300 }) == null);
    try testing.expect(parser.colorFromValue(.{ .integer = 1677721 }) == null); // 7 digits: neither RGB nor RGBA
    try testing.expect(parser.colorFromValue(.{ .integer = -1 }) == null);
    // The .color and string forms are unchanged.
    try testing.expectEqual(@as(u32, 0x61AFEF), parser.colorFromValue(.{ .color = 0x61AFEF }).?);
    try testing.expectEqual(@as(u32, 0x112233), parser.colorFromValue(.{ .string = "112233" }).?);
    try testing.expectEqual(@as(u32, 0x61AFEF), parser.colorFromValue(.{ .string = "#61AFEF" }).?);
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

test "array-of-tables and empty section headers are skipped with a flag" {
    // `[[..]]` is deliberately unsupported; `[]` is an empty name. Both must
    // be warn-and-skipped (not fatal) but flag the Document (C1) so a load
    // refuses to proceed on a partial config.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var doc = try parse(arena.allocator(),
        \\[[tiling.arr]]
        \\[bar]
        \\height = 24
        \\[]
        \\width = 10
    );

    try testing.expect(doc.had_errors);
    // The valid sections still parsed; the broken headers did not create keys.
    const bar = doc.sections.getPtr("bar").?;
    try testing.expectEqual(@as(i64, 24), bar.get("height").?.asScalar(i64).?);
    try testing.expect(doc.sections.getPtr("tiling.arr") == null);
    try testing.expect(doc.sections.getPtr("") == null);
    try testing.expect(doc.root.get("width") == null);
}

test "unterminated string and junk after a pair are skipped with a flag" {
    // A newline inside a double-quoted string and trailing garbage after a
    // completed pair are both recoverable skips; the surrounding lines parse.
    // (Space-separated bare values accumulate into an array instead of
    // tripping the junk path, so the junk case uses a second string.)
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var doc = try parse(arena.allocator(),
        \\a = "unterminated
        \\b = "ok" "junk"
        \\c = 3
    );

    try testing.expect(doc.had_errors);
    try testing.expectEqual(@as(i64, 3), doc.root.get("c").?.asScalar(i64).?);
    // `b`'s value was parsed, then the junk flagged the line: b survives.
    try testing.expectEqualStrings("ok", doc.root.get("b").?.asScalar([]const u8).?);
    try testing.expect(doc.root.get("a") == null);
}

test "empty key and bare-key flag semantics" {
    // `= value` has no key (InvalidSyntax skip); a bare `flag` parses as a
    // boolean true with no '=' (the TOML-subset's presence flag).
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var doc = try parse(arena.allocator(),
        \\= 5
        \\flag
        \\present = 1
    );

    try testing.expect(doc.had_errors);
    try testing.expect(doc.root.get("flag").?.asScalar(bool).?);
    try testing.expectEqual(@as(i64, 1), doc.root.get("present").?.asScalar(i64).?);
}

test "single-quoted and double-quoted strings both terminate correctly" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var doc = try parse(arena.allocator(), "s = 'hello'\n" ++ "d = \"hi\"\n");
    try testing.expect(!doc.had_errors);
    try testing.expectEqualStrings("hello", doc.root.get("s").?.asScalar([]const u8).?);
    try testing.expectEqualStrings("hi", doc.root.get("d").?.asScalar([]const u8).?);
}

test "mergeDocumentsInto propagates had_errors from an overlay" {
    // C1: a broken overlay flags the merged result even if the base is clean,
    // so a load composing documents can see any source's errors.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var base = try parser.parse(a, "theme = \"dark\"\n", "<test>");
    var broken = try parser.parse(a, "[oops\nstill = \"here\"\n", "<test>");

    try testing.expect(!base.had_errors);
    try testing.expect(broken.had_errors);
    try parser.mergeDocumentsInto(a, &base, &broken);
    try testing.expect(base.had_errors);
    // The valid line in the broken overlay still landed.
    try testing.expectEqualStrings("here", base.root.get("still").?.asScalar([]const u8).?);
}

test "color-mix weight markers: isWeightToken / weightFromToken" {
    try testing.expect(parser.isWeightToken("+(weight:50%)"));
    try testing.expect(parser.isWeightToken("(weight:50%)"));
    try testing.expect(parser.isWeightToken("(weight:50)"));
    try testing.expect(!parser.isWeightToken("+"));
    try testing.expect(!parser.isWeightToken("(weight:)"));
    try testing.expect(!parser.isWeightToken("(weight:abc%)"));
    try testing.expect(!parser.isWeightToken("50%"));
    try testing.expect(!parser.isWeightToken("primary_color"));

    try testing.expectEqual(@as(?u32, 50), parser.weightFromToken("+(weight:50%)"));
    try testing.expectEqual(@as(?u32, 25), parser.weightFromToken("(weight:25)"));
    try testing.expectEqual(@as(?u32, null), parser.weightFromToken("+"));
    try testing.expectEqual(@as(?u32, null), parser.weightFromToken("50%"));
}

test "color-mix: a weight token survives the tokenizer instead of erroring" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var doc = try parse(arena.allocator(),
        \\[bar]
        \\border_focused = primary_color +(weight:50%) secondary_color
    );
    try testing.expect(!doc.had_errors);
    const bar = doc.sections.getPtr("bar").?;
    const vals = bar.get("border_focused").?.asArray().?;
    // "+(weight:50%)" is one bare token (no space after '+'), so three
    // elements, not four.
    try testing.expectEqual(@as(usize, 3), vals.len);
    try testing.expectEqualStrings("primary_color", vals[0].asScalar([]const u8).?);
    try testing.expectEqualStrings("+(weight:50%)", vals[1].asScalar([]const u8).?);
    try testing.expectEqualStrings("secondary_color", vals[2].asScalar([]const u8).?);
}

test "color-mix: resolveColorExpr averages channels across spellings and weights" {
    // pa = (160, 0, 0), pb = (128, 32, 0); every assertion below is exact.
    // (Names deliberately avoid [0-9a-f] so they can't be misread as hex
    // literals by colorFromValue before the palette lookup.)
    var palette = std.StringHashMap(u32).init(testing.allocator);
    defer palette.deinit();
    try palette.put("pa", 0xA00000);
    try palette.put("pb", 0x802000);

    // Plain midpoint (unspaced string spelling).
    try testing.expectEqual(@as(u32, 0x901000), parser.resolveColorExpr(.{ .string = "pa+pb" }, &palette).?);
    // Spaced array spelling with a weight on the second operand: b = 25%.
    var spaced = try std.ArrayList(parser.Value).initCapacity(testing.allocator, 4);
    defer spaced.deinit(testing.allocator);
    try spaced.append(testing.allocator, .{ .string = "pa" });
    try spaced.append(testing.allocator, .{ .string = "+" });
    try spaced.append(testing.allocator, .{ .string = "(weight:25%)" });
    try spaced.append(testing.allocator, .{ .string = "pb" });
    try testing.expectEqual(@as(u32, 0x980800), parser.resolveColorExpr(.{ .array = .{ .list = spaced } }, &palette).?);

    // Combined "+(weight:N%)" token (no space after the plus) is equivalent.
    var compact = try std.ArrayList(parser.Value).initCapacity(testing.allocator, 3);
    defer compact.deinit(testing.allocator);
    try compact.append(testing.allocator, .{ .string = "pa" });
    try compact.append(testing.allocator, .{ .string = "+(weight:25%)" });
    try compact.append(testing.allocator, .{ .string = "pb" });
    try testing.expectEqual(@as(u32, 0x980800), parser.resolveColorExpr(.{ .array = .{ .list = compact } }, &palette).?);
    // Reversed weight: b = 75%.
    try testing.expectEqual(@as(u32, 0x881800), parser.resolveColorExpr(.{ .string = "pa+(weight:75%)pb" }, &palette).?);

    // A chain: a stays the head, later operands take their annotation
    // (a=50%, b=25%, a=25%).
    try testing.expectEqual(@as(u32, 0x980800), parser.resolveColorExpr(.{ .string = "pa+(weight:25%)pb+(weight:25%)pa" }, &palette).?);

    // Equal weights beyond two operands share evenly (a=160/0/0,
    // b=128/32/0: r=(160+128+128)/3=139, g=(32+32)/3=21).
    try testing.expectEqual(@as(u32, 0x8B1500), parser.resolveColorExpr(.{ .string = "pa+pb+pb" }, &palette).?);
}

test "color-mix: malformed expressions resolve to null, not garbage" {
    var palette = std.StringHashMap(u32).init(testing.allocator);
    defer palette.deinit();
    try palette.put("a", 0xA00000);
    try palette.put("b", 0x802000);

    // No '+': not a mix (plain aliases live in getColorFromValue).
    try testing.expect(parser.resolveColorExpr(.{ .string = "pa" }, &palette) == null);
    // A weight above 100 is invalid.
    try testing.expect(parser.resolveColorExpr(.{ .string = "pa+(weight:150%)pb" }, &palette) == null);
    // An unknown operand is invalid.
    try testing.expect(parser.resolveColorExpr(.{ .string = "pa+nope" }, &palette) == null);
    // Stray structure in the array spelling.
    const cases = [_][]const parser.Value{ &.{ .{ .string = "+" }, .{ .string = "pa" }, .{ .string = "pb" } }, &.{ .{ .string = "pa" }, .{ .string = "+" } }, &.{ .{ .string = "pa" }, .{ .string = "+" }, .{ .string = "pb" }, .{ .string = "c" } } };
    for (cases) |cs| {
        var arr = try std.ArrayList(parser.Value).initCapacity(testing.allocator, cs.len);
        defer arr.deinit(testing.allocator);
        try arr.appendSlice(testing.allocator, cs);
        try testing.expect(parser.resolveColorExpr(.{ .array = .{ .list = arr } }, &palette) == null);
    }
    // The head operand may never carry a weight.
    try testing.expect(parser.resolveColorExpr(.{ .string = "(weight:50%)pa+pb" }, &palette) == null);
}

test "color-mix: a bare operand list mixes equally" {
    var palette = std.StringHashMap(u32).init(testing.allocator);
    defer palette.deinit();
    try palette.put("pa", 0xA00000);
    try palette.put("pb", 0x802000);

    // `[pa, pb]` with no operator or weights is a 50/50 equal-weight mix.
    var arr = try std.ArrayList(parser.Value).initCapacity(testing.allocator, 2);
    defer arr.deinit(testing.allocator);
    try arr.appendSlice(testing.allocator, &.{ .{ .string = "pa" }, .{ .string = "pb" } });
    const mixed = parser.resolveColorExpr(.{ .array = .{ .list = arr } }, &palette) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(u32, 0x901000), mixed);
    // A single-element list is not a mix; the alias fallback handles it.
    var one = try std.ArrayList(parser.Value).initCapacity(testing.allocator, 1);
    defer one.deinit(testing.allocator);
    try one.append(testing.allocator, .{ .string = "pa" });
    try testing.expect(parser.resolveColorExpr(.{ .array = .{ .list = one } }, &palette) == null);
}

test "collectPalette: aliases and + mixes resolve through a fixpoint" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var doc = try parse(arena.allocator(),
        \\[bar]
        \\secondary_color   = text_color        # alias of another palette var
        \\primary_color     = secondary_color + text_color
        \\alternative_color = "#000000"
        \\text_color        = "#ffffff"
    );
    parser.collectPalette(&doc);
    try testing.expectEqual(@as(u32, 0xFFFFFF), doc.palette.get("primary_color").?);
    try testing.expectEqual(@as(u32, 0xFFFFFF), doc.palette.get("secondary_color").?);
    try testing.expectEqual(@as(u32, 0x000000), doc.palette.get("alternative_color").?);
    try testing.expectEqual(@as(u32, 0xFFFFFF), doc.palette.get("text_color").?);
}

test "collectPalette: a cyclic mix is skipped, not infinite-looped" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var doc = try parse(arena.allocator(),
        \\[bar]
        \\primary_color   = secondary_color    # mutual alias (cycle)
        \\secondary_color = primary_color
        \\text_color      = "#ffffff"
    );
    parser.collectPalette(&doc);
    try testing.expect(doc.palette.contains("text_color"));
    try testing.expect(!doc.palette.contains("primary_color"));
    try testing.expect(!doc.palette.contains("secondary_color"));
}

test "color-mix: literal arrays parse with accumulated=false, mixing stays intact" {
    // C-16: parsing is orthogonal to the mix half. A genuine single-declaration
    // literal array from any working spelling (bracket or bare, `0x` colors)
    // must keep `accumulated` false so `colorFromValue`/`resolveColorExpr`
    // treat it as a mix unit and never descend as a scalar.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const doc0 = try parse(arena.allocator(),
        \\[tiling.aesthetics]
        \\x = [1, 2]
    );
    const x = doc0.sections.getPtr("tiling.aesthetics").?.get("x").?;
    try testing.expect(x == .array);
    try testing.expect(!x.array.accumulated);
    try testing.expectEqual(@as(usize, 2), x.array.list.items.len);
    var doc5 = try parse(arena.allocator(),
        \\icons = 0xac3232, 0x52263e
    );
    const icons = doc5.root.get("icons").?;
    try testing.expect(icons == .array);
    try testing.expect(!icons.array.accumulated);
    try testing.expectEqual(@as(usize, 2), icons.array.list.items.len);
    var doc6 = try parse(arena.allocator(),
        \\x = [0xac3232, 0x52263e]
    );
    const x6 = doc6.root.get("x").?;
    try testing.expect(x6 == .array);
    try testing.expect(!x6.array.accumulated);
}
