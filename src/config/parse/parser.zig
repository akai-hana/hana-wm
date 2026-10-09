//! Configuration parser: the dialect reader.
//! Parses hana's TOML-inspired configuration format into structured values.
//!
//! The document model (`Value`, `Section`, `Document`, the duplicate-key
//! policy, `ParseError`) lives beside this file in `document.zig`, and the
//! cross-file merge in `merge.zig`; both re-export their names through this
//! file so existing `parser.*` call sites keep one import. What the model
//! owns (nothing -- one arena per load) is documented in `document.zig`.
//!
//! ACCEPTED SUBSET (everything outside this list is a parse error, by design --
//! this is a hand-written reader for one config dialect, not a TOML
//! implementation, and silently accepting a construct whose semantics we would
//! then have to approximate is worse than rejecting it):
//!
//!   `[table]` headers, one level, flat keys only;
//!   `key = value` pairs, plus the bare-key shorthand (`key` == `key = true`,
//!   which workspace rules rely on);
//!   values: decimal integers, `true`/`false`, single- or double-quoted
//!   strings, bracketed `[a, b, c]` arrays, bare multi-token lists, colors
//!   (`#RRGGBB`, `0xRRGGBB`), and scalable values with a unit suffix;
//!   `#` comments to end of line; duplicate keys accumulate into an array.
//!
//! REJECTED, with the error each produces:
//!
//!   inline tables (`{ a = 1 }`), dotted keys (`a.b = 1`), array-of-tables
//!   (`[[x]]`), date/time literals, floats, multi-line/basic strings,
//!   escapes beyond the supported set  -> InvalidValue
//!   a key or table name the reader cannot lex               -> InvalidSyntax
//!   a `[header]` that does not open a section the reader accepts -> InvalidSection
//!   a color token that is not a valid 24-bit hex              -> InvalidColor
//!   allocator exhaustion (distinct so callers can retry)     -> OutOfMemory
//!
//! The error set is `ParseError`, declared in `document.zig`.
const std = @import("std");
const log = @import("log");
const types = @import("types");

const document = @import("document");
const merge = @import("merge");

// Re-exports: the model moved beside this file (document.zig) and the
// cross-file merge to merge.zig; `parser.*` keeps naming both so callers
// (schema, sections, discover, tests) hold one import. The dialect itself
// -- tokenizer, weight/color token spellings, `parse` -- stays here.
pub const Value = document.Value;
pub const Section = document.Section;
pub const Document = document.Document;
pub const palette_var_names = document.palette_var_names;
pub const mergeDocumentsInto = merge.mergeDocumentsInto;
const ParseError = document.ParseError;

/// Core parser for a `(weight:DIGITS[%])` prefix at the head of `s`, where `s`
/// is the token with any leading `+` already stripped. Returns the weight and
/// the index just past the closing `)`; null when `s` does not open with a
/// well-formed weight marker. All three weight helpers (`isWeightToken`,
/// `weightFromToken`, `splitWeightPrefix`) are expressed on top of this so the
/// marker grammar is spelled exactly once.
fn parseWeightPrefix(s: []const u8) ?struct { weight: u32, end: usize } {
    const prefix = "(weight:";
    if (!std.mem.startsWith(u8, s, prefix)) return null;
    var i: usize = prefix.len;
    const digits_start = i;
    while (i < s.len and std.ascii.isDigit(s[i])) i += 1;
    if (i == digits_start) return null;
    const digits_end = i;
    if (i < s.len and s[i] == '%') i += 1;
    if (i >= s.len or s[i] != ')') return null;
    const weight = std.fmt.parseInt(u32, s[digits_start..digits_end], 10) catch return null;
    return .{ .weight = weight, .end = i + 1 };
}

/// True when `raw` is a whole weight-marker token (`+(weight:50%)`,
/// `(weight:50%)`, or the `%`-less `(weight:50)`) rather than a value. Kept
/// syntax-only so the bare-token interpreter can classify a `%`-suffixed
/// weight token as a string before the generic percentage branch mistakes its
/// non-numeric prefix for an invalid ratio and errors the whole line.
pub fn isWeightToken(raw: []const u8) bool {
    return weightFromToken(raw) != null;
}

/// The weight (0-100) carried by a whole weight-marker token; null when `raw`
/// is not one. `+(weight:N%)` annotates the operand RIGHT after the `+`; the
/// operand at the head of the chain absorbs the remaining weight.
/// Test seam: pure parse core pinned by parser_test.
pub fn weightFromToken(raw: []const u8) ?u32 {
    const s = if (raw.len > 0 and raw[0] == '+') raw[1..] else raw;
    const p = parseWeightPrefix(s) orelse return null;
    if (p.end != s.len) return null;
    return p.weight;
}

/// Splits a `+`-separated chain part like `(weight:25%)secondary_color` into
/// its weight annotation and the operand it annotates. A part with no
/// annotation yields weight null and the part unchanged.
pub fn splitWeightPrefix(part: []const u8) struct { weight: ?u32, operand: []const u8 } {
    const p = parseWeightPrefix(part) orelse return .{ .weight = null, .operand = part };
    return .{ .weight = p.weight, .operand = part[p.end..] };
}

fn hexPrefixLen(value: []const u8) ?u2 {
    if (value.len == 0) return null;
    if (value[0] == '#') return 1;
    if (value.len > 2 and value[0] == '0' and (value[1] == 'x' or value[1] == 'X')) return 2;
    return null;
}

/// Parses a color token into a packed 0xRRGGBB value.
/// Test seam: pure parse core pinned by parser_test.
pub fn parseColor(value: []const u8) !u32 {
    if (value.len == 0) return error.InvalidColor;

    const offset: u8 = hexPrefixLen(value) orelse 0;
    const hex_part = value[offset..];

    if (hex_part.len == 0) return error.InvalidColor;

    const color = std.fmt.parseInt(u32, hex_part, 16) catch return error.InvalidColor;
    if (color > types.max_color) return error.InvalidColor;
    return color;
}

const Parser = struct {
    allocator: std.mem.Allocator,
    content: []const u8,
    pos: usize,
    line: usize,
    /// Position of the first byte of the current line, so diagnostics can
    // report a column (`pos - line_start`). Reset whenever a newline is
    // consumed by any scanner.
    line_start: usize = 0,
    /// Owning Document's had_errors flag; set whenever a line is warn-and-
    // skipped so the load can fail on broken configs.
    had_errors: *bool,
    /// File path named in every per-line diagnostic; "" = in-memory input.
    source_path: []const u8 = "",
    // Current nested-array depth, checked against max_array_depth so a
    // pathologically deep literal (`[[[[[...]]]]]`) can't exhaust the stack.
    // Config is locally authored and trusted, so this is a defensive
    // backstop, not a response to observed input.
    array_depth: usize = 0,

    fn init(allocator: std.mem.Allocator, content: []const u8, had_errors: *bool) Parser {
        return .{ .allocator = allocator, .content = content, .pos = 0, .line = 1, .had_errors = had_errors };
    }

    // Zero-based column of the current scan position within its line.
    inline fn column(self: *const Parser) usize {
        return self.pos - self.line_start;
    }

    // "<input>" when no source file is named (in-memory/embedded inputs).
    fn sourceLabel(self: *const Parser) []const u8 {
        return if (self.source_path.len == 0) "<input>" else self.source_path;
    }

    // Per-line diagnostic prefixed with file:line:column.
    fn warnLine(self: *const Parser, comptime fmt: []const u8, args: anytype) void {
        log.warn("{s}:{d}:{d}: " ++ fmt, .{ self.sourceLabel(), self.line, self.column() } ++ args);
    }

    // Advances one byte. A newline also bumps the line counter and resets
    // `line_start` (see the field docs); every scanner consumes characters
    // through here so the bookkeeping never drifts.
    inline fn advanceChar(self: *Parser) void {
        self.pos += 1;
        if (self.content[self.pos - 1] == '\n') {
            self.line += 1;
            self.line_start = self.pos;
        }
    }

    // Skips whitespace up to the next payload char; `comptime full` selects the
    // narrower scan (inline whitespace only) or the full inter-token run (also
    // newlines and comments). Two comptime-flagged arms of one skipper.
    inline fn skipInline(self: *Parser, comptime full: bool) void {
        while (self.pos < self.content.len) {
            switch (self.content[self.pos]) {
                ' ', '\t', '\r' => self.advanceChar(),
                '\n' => if (full) self.advanceChar() else break,
                '#' => if (full) self.skipToNewline() else break,
                else => break,
            }
        }
    }

    // Skips inline whitespace (' ', '\t', '\r') only; a newline or comment
    // stops the scan.
    inline fn skipWhitespace(self: *Parser) void {
        self.skipInline(false);
    }

    // Skips whitespace, newlines, and comments (the full inter-token run
    // consumed inside arrays and at line starts).
    inline fn skipWhitespaceAndNewlines(self: *Parser) void {
        self.skipInline(true);
    }

    fn skipToNewline(self: *Parser) void {
        while (self.pos < self.content.len and self.content[self.pos] != '\n') self.pos += 1;
        if (self.pos < self.content.len) self.advanceChar();
    }

    // Flags the document as errored, warns about the offending line, and
    // discards to the next newline: the shared recoverable-error recovery.
    fn skipBadLine(self: *Parser, comptime fmt: []const u8, args: anytype) void {
        self.had_errors.* = true;
        self.warnLine(fmt, args);
        self.skipToNewline();
    }

    inline fn peek(self: *const Parser) ?u8 {
        return if (self.pos < self.content.len) self.content[self.pos] else null;
    }

    inline fn consume(self: *Parser) ?u8 {
        const c = self.peek() orelse return null;
        self.advanceChar();
        return c;
    }

    fn parseSection(self: *Parser) ParseError![]const u8 {
        _ = self.consume();
        self.skipWhitespace();

        const start = self.pos;
        while (self.peek()) |c| {
            if (c == ']') break;
            if (c == '\n') return ParseError.InvalidSection;
            _ = self.consume();
        }

        if (self.peek() != ']') return ParseError.InvalidSection;
        _ = self.consume();

        const name = std.mem.trim(u8, self.content[start .. self.pos - 1], " \t\r");
        return if (name.len > 0) name else ParseError.InvalidSection;
    }

    fn parseKey(self: *Parser) ParseError![]const u8 {
        self.skipWhitespace();
        const start = self.pos;
        while (self.pos < self.content.len) {
            switch (self.content[self.pos]) {
                // '\r' joins the break set so a bare key on a CRLF file (e.g.
                // a `[workspace.rules]` class name) can't soak up the
                // carriage return and silently mismatch rule targets.
                '=', ' ', '\t', '\n', '\r' => break,
                else => self.pos += 1,
            }
        }
        // A slice into `content` (arena-backed by the caller), like every
        // parsed string: nothing is duped or freed.
        const key = self.content[start..self.pos];
        return if (key.len > 0) key else ParseError.InvalidSyntax;
    }

    fn parseString(self: *Parser) ParseError![]const u8 {
        const quote = self.consume().?;
        var result = std.ArrayList(u8).initCapacity(
            self.allocator,
            32,
        ) catch return ParseError.OutOfMemory;
        while (self.peek()) |c| {
            if (c == quote) {
                _ = self.consume();
                return try result.toOwnedSlice(self.allocator);
            }
            if (c == '\n') return ParseError.InvalidValue;
            if (c == '\\' and quote == '"') {
                _ = self.consume();
                const next = self.consume() orelse return ParseError.InvalidValue;
                try result.append(self.allocator, switch (next) {
                    'n' => '\n',
                    't' => '\t',
                    'r' => '\r',
                    '\\' => '\\',
                    '"', '\'' => next,
                    else => return ParseError.InvalidValue,
                });
            } else {
                try result.append(self.allocator, c);
                _ = self.consume();
            }
        }
        return ParseError.InvalidValue;
    }

    // Maximum nested-array depth accepted by parseArray (see array_depth doc comment).
    const max_array_depth = 16;

    fn parseArray(self: *Parser) ParseError!std.ArrayList(Value) {
        self.array_depth += 1;
        defer self.array_depth -= 1;
        if (self.array_depth > max_array_depth) {
            self.warnLine("Array nesting too deep (> {d}), treating as invalid", .{max_array_depth});
            return ParseError.InvalidValue;
        }

        _ = self.consume();
        var array = try std.ArrayList(Value).initCapacity(self.allocator, 8);

        while (true) {
            self.skipWhitespaceAndNewlines();
            if (self.peek() == ']') {
                _ = self.consume();
                break;
            }
            try array.append(self.allocator, try self.parseValue(true));
            self.skipWhitespaceAndNewlines();
            if (self.peek() == ',') _ = self.consume();
        }

        return array;
    }

    // True when `raw` is an optionally-signed bare decimal literal: digits,
    // exactly one '.', at least one digit (e.g. "2.5", "-0.3"). Whole numbers
    // and malformed tokens return false, falling through to the existing
    // color/integer/string handling in `parseValue`.
    fn looksLikeDecimal(raw: []const u8) bool {
        var start: usize = 0;
        if (raw.len > 0 and raw[0] == '-') start = 1;
        if (start >= raw.len) return false;
        var dot_count: usize = 0;
        var digit_count: usize = 0;
        for (raw[start..]) |c| {
            if (c == '.') {
                dot_count += 1;
            } else if (std.ascii.isDigit(c)) {
                digit_count += 1;
            } else {
                return false;
            }
        }
        return dot_count == 1 and digit_count > 0;
    }

    // Scans a single bare (unquoted) token. Stops at whitespace, newline,
    // ',', ';', ']', and any '#' that is not the first character (a comment
    // start). A leading '#' is allowed so unquoted `#RRGGBB` colors parse as
    // colors rather than being mistaken for a comment.
    fn parseBareToken(self: *Parser) ?[]const u8 {
        const start = self.pos;
        while (self.pos < self.content.len) {
            const ch = self.content[self.pos];
            switch (ch) {
                ' ', '\t', '\r', '\n', ',', ';', ']' => break,
                '#' => {
                    if (self.pos == start) {
                        self.pos += 1;
                    } else break;
                },
                else => self.pos += 1,
            }
        }
        const token = self.content[start..self.pos];
        return if (token.len > 0) token else null;
    }

    // Interprets a single bare token as a Value. Every scalar form a bare
    // token can take is handled here: boolean, percentage, decimal, color,
    // integer, with the unrecognised-token string fallback last.
    fn parseBareTokenValue(raw: []const u8) ParseError!Value {
        if (std.mem.eql(u8, raw, "true")) return .{ .boolean = true };
        if (std.mem.eql(u8, raw, "false")) return .{ .boolean = false };

        // A weight-marker token (`+(weight:50%)`) must survive the tokenizer
        // as a string for the color-mix resolver: the trailing '%' would
        // otherwise fall into the percentage branch below and, having a
        // non-numeric prefix, error the whole line.
        if (isWeightToken(raw)) return .{ .string = raw };

        if (raw.len > 1 and raw[raw.len - 1] == '%') {
            const f = std.fmt.parseFloat(
                f32,
                raw[0 .. raw.len - 1],
            ) catch return ParseError.InvalidValue;
            if (!std.math.isFinite(f)) return ParseError.InvalidValue;
            return .{ .scalable = types.ScalableValue.percentage(f) };
        }

        // Bare decimal (no '%' suffix), e.g. `border_width = 2.5`: parsed as
        // an absolute ScalableValue so such fields don't keep their struct
        // default for lacking a '%'. Whole numbers stay integers so
        // asInt()/asBool() consumers are unaffected.
        if (looksLikeDecimal(raw)) {
            const f = std.fmt.parseFloat(f32, raw) catch return ParseError.InvalidValue;
            if (std.math.isFinite(f)) return .{ .scalable = types.ScalableValue.absolute(f) };
        }

        // Colors require '#' or '0x' prefix: bare all-hex identifiers
        // (e.g. "dead", "cafe") must parse as strings, not colors.
        if (hexPrefixLen(raw) != null) {
            if (parseColor(raw)) |color| return .{ .color = color } else |_| {}
            if (raw[0] == '#') return ParseError.InvalidValue;
        }

        if (std.fmt.parseInt(i64, raw, 10)) |int_val| return .{ .integer = int_val } else |_| {
            // Not a color/integer/boolean/percentage: an unquoted bare string,
            // so layout or action names without quotes parse without error.
            // `raw` is a slice into `content`; nothing is duped.
            return .{ .string = raw };
        }
    }

    // Parses a bare (unquoted) value: one token is a scalar; two or more
    // (whitespace/commas) form an array, e.g. `segments = workspaces layout
    // clock` -> ["workspaces","layout","clock"] or `icons = #ac3232, #52263e`
    // -> [0xac3232, 0x52263e]. Inside `[...]` one token is consumed (commas
    // belong to parseArray); semicolons are likewise left to the pair parser.
    fn parseBareValues(self: *Parser, in_array: bool) ParseError!Value {
        var items: std.ArrayList(Value) = .empty;

        while (true) {
            self.skipWhitespace();
            const nxt = self.peek() orelse break;
            if (nxt == '\n' or nxt == ';') break;
            // A '#' following a token is a comment; a leading '#' (no token
            // collected yet) starts a color literal instead.
            if (nxt == '#' and items.items.len > 0) break;
            const token = self.parseBareToken() orelse break;
            try items.append(self.allocator, try parseBareTokenValue(token));
            if (in_array) break;
            self.skipWhitespace();
            if (self.peek() == ',') _ = self.consume();
        }

        if (items.items.len == 0) return ParseError.InvalidValue;
        if (items.items.len == 1) {
            return items.swapRemove(0);
        }
        // Literal array (one declaration): `accumulated` stays false so a
        // scalar read never descends into it and color reads treat it as a
        // mix unit.
        return .{ .array = .{ .list = items } };
    }

    fn parseValue(self: *Parser, in_array: bool) ParseError!Value {
        self.skipWhitespace();
        const c = self.peek() orelse return ParseError.InvalidValue;

        if (c == '[') return .{ .array = .{ .list = try self.parseArray() } };
        if (c == '"' or c == '\'') return .{ .string = try self.parseString() };

        return self.parseBareValues(in_array);
    }

    // Advances past a trailing newline or comment character at line end.
    fn skipLineEnd(self: *Parser, c: ?u8) void {
        switch (c orelse return) {
            '\n' => _ = self.consume(),
            '#' => self.skipToNewline(),
            else => {},
        }
    }

    // Reports one malformed pair: warn against `key` when it parsed (so a
    // user sees WHICH key has the bad value), warn generically when even the
    // key failed, then skip to the next line so the document loop continues.
    fn pairFailed(self: *Parser, err: ParseError, key: []const u8) void {
        self.had_errors.* = true;
        if (key.len > 0)
            self.warnLine("invalid value for key '{s}': {s} (got {s})", .{ key, document.expectedForm(err), @errorName(err) })
        else
            self.warnLine("invalid value: {s} (got {s})", .{ document.expectedForm(err), @errorName(err) });
        self.skipToNewline();
    }

    // Parses one `key = value` pair (or bare `key` flag), inserts it, and
    // consumes the trailing syntax. The document loop in `parse` re-invokes
    // this for each further pair on the following line; a malformed pair is
    // warned-and-skipped to the next line so recovery returns to that loop.
    fn parsePairs(self: *Parser, section: *Section) ParseError!void {
        const key = self.parseKey() catch |err| {
            self.pairFailed(err, "");
            return;
        };
        self.skipWhitespace();
        var value: Value = .{ .boolean = true }; // bare `key` shorthand: `key = true`
        if (self.peek() == '=') {
            _ = self.consume();
            value = self.parseValue(false) catch |err| {
                self.pairFailed(err, key);
                return;
            };
        }

        // Duplicate key: accumulate both values into an array rather
        // than overwriting, so a keybinding can bind multiple actions:
        //
        //   Mod+Shift+1 = "move_to_workspace_1"
        //   Mod+Shift+1 = "toggle_tag_1"
        //
        // parseKeybindings treats array values as sequences; scalar
        // reads of a repeated key resolve to the last declaration.
        try document.insertOrAccumulate(self.allocator, section, key, value, self.line);

        self.skipWhitespace();
        self.advanceAfterPair(key);
    }

    // Advances past the end of one pair: an optional ';' terminator, trailing
    // whitespace, and any line-end comment or newline. `key` names the pair
    // for the unexpected-character diagnostic.
    fn advanceAfterPair(self: *Parser, key: []const u8) void {
        const next = self.peek();
        if (next == ';') _ = self.consume();
        self.skipWhitespace();
        const trail = self.peek();
        if (trail != '\n' and trail != '#' and trail != null) {
            self.skipBadLine("unexpected character after pair (key '{s}')", .{key});
            return;
        }
        self.skipLineEnd(trail);
    }
};

/// Parses `content` into a Document. The caller must back `allocator` with a
/// load-scoped arena: string values alias `content` (and the arena for
/// escaped strings/arrays), merging shares values across documents, and a
/// parse/merge error abandons the partial document to the arena reset. The
/// Document owns nothing; `content` must stay alive (arena-backed) until the
/// arena reset. `source_path` is the file this content came from, named in
/// every per-line diagnostic ("" for in-memory/embedded inputs).
pub fn parse(allocator: std.mem.Allocator, content: []const u8, source_path: []const u8) !Document {
    var doc = Document.init(allocator);

    var p = Parser.init(allocator, content, &doc.had_errors);
    p.source_path = source_path;
    var current_section: *Section = &doc.root;

    while (p.pos < p.content.len) {
        p.skipWhitespace();
        const c = p.peek() orelse break;

        if (c == '\n' or c == '#') {
            p.skipLineEnd(c);
            continue;
        }

        if (c == '[') {
            // TOML array-of-tables headers ([[name]]) are unsupported. Reject
            // them with a clear warning instead of silently treating them as a
            // plain [name] section and then misparsing the trailing ']' as a
            // key (parseSection consumes just one '[').
            if (p.pos + 1 < p.content.len and p.content[p.pos + 1] == '[') {
                p.skipBadLine("array-of-tables header '[[...]]' unsupported", .{});
                continue;
            }
            const section_name = p.parseSection() catch |err| {
                p.skipBadLine("invalid section header: {s} (got {s})", .{ document.expectedForm(err), @errorName(err) });
                continue;
            };

            if (doc.sections.getPtr(section_name)) |existing| {
                // Duplicate section header: keep filling the existing section
                // so duplicate keys accumulate as if the blocks were one
                // section, consistent with the cross-file merge path.
                current_section = existing;
            } else {
                try doc.sections.put(section_name, .{});
                current_section = doc.sections.getPtr(section_name).?;
                current_section.name = section_name;
            }

            continue;
        }

        try p.parsePairs(current_section);
    }

    return doc;
}
