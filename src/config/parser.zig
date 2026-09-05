//! Configuration parser.
//! Parses hana's TOML-inspired configuration format into structured values.

const std = @import("std");
const debug = @import("debug");

/// A value that can be expressed as either an absolute pixel count or a
/// percentage of some reference dimension.
pub const ScalableValue = struct {
    value: f32,
    is_percentage: bool,

    pub inline fn absolute(val: f32) ScalableValue {
        return .{ .value = val, .is_percentage = false };
    }
    pub inline fn percentage(val: f32) ScalableValue {
        return .{ .value = val, .is_percentage = true };
    }
};

/// Frees every owned value in `arr` (its elements' strings/arrays) and then
/// the array's backing storage, in that order. Shared by Value.deinit and the
/// errdefer teardown of the partially built arrays in merging and parsing.
pub fn deinitValues(arr: *std.ArrayList(Value), allocator: std.mem.Allocator) void {
    for (arr.items) |*item| item.deinit(allocator);
    arr.deinit(allocator);
}

pub const Value = union(enum) {
    integer: i64,
    boolean: bool,
    string: []const u8,
    array: std.ArrayList(Value),
    color: u32,
    scalable: ScalableValue,

    // Duplicate keys accumulate into a flat array (see `accumulate`), so
    // scalar reads implement "later declaration wins": the latest value is
    // the LAST element. Array consumers see the full accumulation. Not
    // `inline` because recursion into an accumulated duplicate array is
    // rejected. Routes every scalar accessor through one shared
    // last-element descent.
    fn lastScalar(self: Value) ?Value {
        return switch (self) {
            .array => |arr| if (arr.items.len > 0)
                arr.items[arr.items.len - 1].lastScalar()
            else
                null,
            else => self,
        };
    }
    // Generic scalar accessor: dispatches to the matching variant tag via
    // comptime. Handles `asScalable`'s integer-widening as a comptime branch.
    pub fn asScalar(self: Value, comptime T: type) ?T {
        const scalar = self.lastScalar() orelse return null;
        return switch (T) {
            i64 => switch (scalar) {
                .integer => |i| i,
                else => null,
            },
            bool => switch (scalar) {
                .boolean => |b| b,
                else => null,
            },
            []const u8 => switch (scalar) {
                .string => |s| s,
                else => null,
            },
            u32 => switch (scalar) {
                .color => |c| c,
                else => null,
            },
            ScalableValue => switch (scalar) {
                .scalable => |s| s,
                .integer => |i| ScalableValue.absolute(@floatFromInt(i)),
                else => null,
            },
            else => @compileError("asScalar: unsupported type " ++ @typeName(T)),
        };
    }
    pub inline fn asArray(self: Value) ?[]const Value {
        return switch (self) {
            .array => |arr| arr.items,
            else => null,
        };
    }

    pub fn deinit(self: *Value, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .string => |s| allocator.free(s),
            .array => |*arr| deinitValues(arr, allocator),
            else => {},
        }
    }
};

pub const Section = struct {
    pairs: std.StringHashMap(Value),
    // Keys examined via get()/getAs()/markConsumed() during config
    // interpretation. Populated (best-effort, alloc failures are swallowed)
    // so config.zig can warn about keys no parse function recognises.
    consumed: std.StringHashMap(void),
    // Document-order key list (insertion order); `pairs` is a hashmap, so
    // direct iteration is nondeterministic (per-process random seed).
    // `orderedIterator` gives deterministic, first-in-file-wins resolution
    // for `[binds]`, `[workspace.rules]`, etc. Holds `pairs`' allocations.
    keys_in_order: std.ArrayListUnmanaged([]const u8) = .empty,

    pub fn init(allocator: std.mem.Allocator) Section {
        var map = std.StringHashMap(Value).init(allocator);
        map.ensureTotalCapacity(4) catch {};
        var consumed = std.StringHashMap(void).init(allocator);
        consumed.ensureTotalCapacity(4) catch {};
        return .{ .pairs = map, .consumed = consumed };
    }

    pub fn deinit(self: *Section, allocator: std.mem.Allocator) void {
        self.keys_in_order.deinit(allocator);
        var iter = self.pairs.iterator();
        while (iter.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            var val = entry.value_ptr.*;
            val.deinit(allocator);
        }
        self.pairs.deinit();
        self.consumed.deinit();
    }

    // Records `key` as the newest document-order key. Best-effort: an OOM
    // here just loses deterministic ordering for this section, never data.
    fn recordKey(self: *Section, allocator: std.mem.Allocator, key: []const u8) void {
        self.keys_in_order.append(allocator, key) catch {};
    }

    // Iterates pairs in document (insertion) order; deterministic, unlike
    // `pairs.iterator()`. Values are the live (possibly accumulated) values.
    pub fn orderedIterator(self: *const Section) OrderedIterator {
        return .{ .section = self, .idx = 0 };
    }

    // Records `key` as recognised so it won't be reported by warnUnconsumed.
    // Needed for keys read via direct `pairs` iteration (e.g. `[binds]`,
    // `[workspace.rules]`, `[tiling.layouts.master-stack.counts]`) rather
    // than the typed getters.
    pub fn markConsumed(self: *Section, key: []const u8) void {
        self.consumed.put(key, {}) catch {};
    }

    // Warns about every key in the section that was never examined via
    // get()/getAs()/markConsumed(); typically a typo in the key name, since
    // the parser otherwise accepts it silently.
    pub fn warnUnconsumed(self: *const Section, section_name: []const u8) void {
        var iter = self.pairs.iterator();
        while (iter.next()) |entry| {
            if (!self.consumed.contains(entry.key_ptr.*)) {
                debug.warn(
                    "Unrecognized key '{s}' in section [{s}]; ignoring",
                    .{ entry.key_ptr.*, section_name },
                );
            }
        }
    }

    pub fn get(self: *Section, key: []const u8) ?Value {
        self.markConsumed(key);
        return self.pairs.get(key);
    }

    // Generic typed getter: dispatches to the matching `Value.asScalar`
    // accessor for the requested type.
    pub fn getAs(self: *Section, comptime T: type, key: []const u8) ?T {
        const v = self.get(key) orelse return null;
        return switch (T) {
            i64 => v.asScalar(i64),
            bool => v.asScalar(bool),
            []const u8 => v.asScalar([]const u8),
            []const Value => v.asArray(),
            ScalableValue => v.asScalar(ScalableValue),
            else => @compileError("Section.getAs: unsupported type " ++ @typeName(T)),
        };
    }
};

// Iterates a section's pairs in document (insertion) order. Values are
// looked up live from `pairs` so accumulated duplicates are seen in full.
pub const OrderedIterator = struct {
    section: *const Section,
    idx: usize,

    pub fn next(self: *OrderedIterator) ?struct { key: []const u8, value: Value } {
        if (self.idx >= self.section.keys_in_order.items.len) return null;
        const key = self.section.keys_in_order.items[self.idx];
        self.idx += 1;
        return .{ .key = key, .value = self.section.pairs.get(key).? };
    }
};

pub const Document = struct {
    allocator: std.mem.Allocator,
    sections: std.StringHashMap(Section),
    root: Section,

    pub fn init(allocator: std.mem.Allocator) Document {
        var sections = std.StringHashMap(Section).init(allocator);
        sections.ensureTotalCapacity(8) catch {};
        return .{ .allocator = allocator, .sections = sections, .root = Section.init(allocator) };
    }

    pub fn deinit(self: *Document) void {
        self.root.deinit(self.allocator);

        var section_iter = self.sections.iterator();
        while (section_iter.next()) |section_entry| {
            self.allocator.free(section_entry.key_ptr.*);
            section_entry.value_ptr.deinit(self.allocator);
        }
        self.sections.deinit();
    }

    pub fn getSection(self: *Document, name: []const u8) ?*Section {
        return self.sections.getPtr(name);
    }

    pub fn get(self: *Document, key: []const u8) ?Value {
        return self.root.get(key);
    }
};

// Document merging

// Deep-copies a Value; string and array contents are newly allocated.
// Integer, boolean, color, and scalable values are plain copies.
fn deepCopyValue(allocator: std.mem.Allocator, val: Value) std.mem.Allocator.Error!Value {
    return switch (val) {
        .string => |s| .{ .string = try allocator.dupe(u8, s) },
        .array => |arr| blk: {
            var new_arr = try std.ArrayList(Value).initCapacity(allocator, arr.items.len);
            errdefer deinitValues(&new_arr, allocator);
            for (arr.items) |item| new_arr.appendAssumeCapacity(try deepCopyValue(allocator, item));
            break :blk .{ .array = new_arr };
        },
        else => val,
    };
}

// Wraps `old_val` in a fresh array if it isn't one already, so callers can
// append into it. On error, `old_val` is left untouched.
fn ensureArray(allocator: std.mem.Allocator, old_val: *Value) !void {
    if (old_val.* == .array) return;
    var arr = try std.ArrayList(Value).initCapacity(allocator, 1);
    errdefer deinitValues(&arr, allocator);
    arr.appendAssumeCapacity(old_val.*);
    old_val.* = .{ .array = arr };
}

// Accumulates `incoming` into `old_val`. When `do_copy` is true elements are
// deep-copied (for cross-document merging); when false they transfer by
// ownership (for within-file duplicate keys). An array-valued `incoming` is
// flattened. Scalar getters resolve to the LAST element (later files win);
// asArray sees the full accumulation so keybinds, `include`, `layouts`, etc.
// chain.
fn accumulate(
    allocator: std.mem.Allocator,
    old_val: *Value,
    incoming: Value,
    comptime do_copy: bool,
) !void {
    try ensureArray(allocator, old_val);
    if (incoming == .array) {
        var inc = incoming;
        const start = old_val.array.items.len;
        for (inc.array.items) |item| {
            const v = if (do_copy) try deepCopyValue(allocator, item) else item;
            old_val.array.append(allocator, v) catch |err| {
                // OOM mid-merge: release everything this call acquired so a
                // failed accumulate leaks nothing on either path. `tail` is
                // the deep copies already appended (do_copy only; captured as
                // a slice header BEFORE the shrink, since the shrink resets
                // items.len and would make re-indexing stale), and `inc` owns
                // all its elements in both modes (transferred values on
                // do_copy=false, source values on do_copy=true).
                const tail = old_val.array.items[start..];
                for (tail) |*owned| if (do_copy) owned.deinit(allocator);
                old_val.array.shrinkRetainingCapacity(start);
                for (inc.array.items) |*owned| owned.deinit(allocator);
                inc.array.deinit(allocator);
                return err;
            };
        }
        if (do_copy) {
            for (inc.array.items) |*item| item.deinit(allocator);
        }
        inc.array.deinit(allocator);
    } else {
        // do_copy=true: `incoming` is already a fresh deep copy owned by the
        // caller (freed by its errdefer on error), so take it by ownership
        // rather than copying again -- re-copying leaked the original for the
        // scalar duplicate-key path. do_copy=false transfers the parser's own
        // value the same way.
        try old_val.array.append(allocator, incoming);
    }
}

// Merges `src`'s pairs into `dst`; duplicate keys accumulate into arrays,
// exactly as within one file: a keybind in two files runs both actions.
// Scalar reads resolve to the last declaration (later file wins); array
// reads see the full accumulation; `src` is unmodified.
fn mergeSectionsInto(allocator: std.mem.Allocator, dst: *Section, src: *const Section) !void {
    var iter = src.orderedIterator();
    while (iter.next()) |entry| {
        const src_key = entry.key;
        const src_val = entry.value;
        if (dst.pairs.getPtr(src_key)) |old_val| {
            // Duplicate key: accumulate into an array, flattening an
            // array-valued `incoming` so two files declaring an array produce
            // one flat array rather than an array-of-arrays.
            const incoming = try deepCopyValue(allocator, src_val);
            errdefer {
                var v = incoming;
                v.deinit(allocator);
            }
            try accumulate(allocator, old_val, incoming, true);
        } else {
            const key_copy = try allocator.dupe(u8, src_key);
            errdefer allocator.free(key_copy);
            try dst.pairs.put(key_copy, try deepCopyValue(allocator, src_val));
            dst.recordKey(allocator, key_copy);
        }
    }
}

// Merges `src` into `dst`; duplicate keys accumulate into arrays rather than
// overwriting, equivalent to writing all pairs in one file. Scalar reads
// resolve to the last element (later files win); array reads see every
// declaration.
pub fn mergeDocumentsInto(
    allocator: std.mem.Allocator,
    dst: *Document,
    src: *const Document,
) !void {
    try mergeSectionsInto(allocator, &dst.root, &src.root);

    var iter = src.sections.iterator();
    while (iter.next()) |entry| {
        const name = entry.key_ptr.*;
        if (dst.sections.getPtr(name)) |dst_sec| {
            try mergeSectionsInto(allocator, dst_sec, entry.value_ptr);
        } else {
            var new_sec = Section.init(allocator);
            errdefer new_sec.deinit(allocator);
            try mergeSectionsInto(allocator, &new_sec, entry.value_ptr);
            const name_copy = try allocator.dupe(u8, name);
            errdefer allocator.free(name_copy);
            try dst.sections.put(name_copy, new_sec);
        }
    }
}

pub const ParseError = error{
    InvalidSyntax,
    InvalidSection,
    InvalidValue,
    InvalidColor,
    OutOfMemory,
};

fn hexPrefixLen(value: []const u8) ?u2 {
    if (value.len == 0) return null;
    if (value[0] == '#') return 1;
    if (value.len > 2 and value[0] == '0' and (value[1] == 'x' or value[1] == 'X')) return 2;
    return null;
}

pub fn parseColor(value: []const u8) !u32 {
    if (value.len == 0) return error.InvalidColor;

    const offset: u8 = hexPrefixLen(value) orelse 0;
    const hex_part = value[offset..];

    if (hex_part.len == 0) return error.InvalidColor;

    const color = std.fmt.parseInt(u32, hex_part, 16) catch return error.InvalidColor;
    if (color > 0xFFFFFF) return error.InvalidColor;
    return color;
}

const Parser = struct {
    allocator: std.mem.Allocator,
    content: []const u8,
    pos: usize,
    line: usize,
    // Current nested-array depth, checked against max_array_depth so a
    // pathologically deep literal (`[[[[[...]]]]]`) can't exhaust the stack.
    // Config is locally authored and trusted, so this is a defensive
    // backstop, not a response to observed input.
    array_depth: usize = 0,
    // Set while parsing array elements so parseBareValues parses only a
    // single bare token per call, the `,`/`]` separators belong to
    // parseArray, and without this an element list like `[a, b]` would be
    // gathered greedily into one nested array.
    in_array: bool = false,

    fn init(allocator: std.mem.Allocator, content: []const u8) Parser {
        return .{ .allocator = allocator, .content = content, .pos = 0, .line = 1 };
    }

    fn skip(self: *Parser, comptime include_newlines: bool, comptime include_comments: bool) void {
        while (self.pos < self.content.len) {
            switch (self.content[self.pos]) {
                ' ', '\t', '\r' => self.pos += 1,
                '\n' => if (include_newlines) {
                    self.pos += 1;
                    self.line += 1;
                } else break,
                '#' => if (include_comments) self.skipToNewline() else break,
                else => break,
            }
        }
    }

    fn skipToNewline(self: *Parser) void {
        while (self.pos < self.content.len and self.content[self.pos] != '\n') self.pos += 1;
        if (self.pos < self.content.len) {
            self.pos += 1;
            self.line += 1;
        }
    }

    inline fn skipWhitespace(self: *Parser) void {
        self.skip(false, false);
    }
    inline fn skipWhitespaceAndNewlines(self: *Parser) void {
        self.skip(true, true);
    }

    inline fn peek(self: *const Parser) ?u8 {
        return if (self.pos < self.content.len) self.content[self.pos] else null;
    }

    inline fn consume(self: *Parser) ?u8 {
        const c = self.peek() orelse return null;
        self.pos += 1;
        if (c == '\n') self.line += 1;
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

        const name = std.mem.trim(u8, self.content[start .. self.pos - 1], " \t");
        return if (name.len > 0) try self.allocator.dupe(u8, name) else ParseError.InvalidSection;
    }

    fn parseKey(self: *Parser) ParseError![]const u8 {
        self.skipWhitespace();
        const start = self.pos;
        while (self.pos < self.content.len) {
            switch (self.content[self.pos]) {
                '=', ' ', '\t', '\n' => break,
                else => self.pos += 1,
            }
        }
        const key = self.content[start..self.pos];
        return if (key.len > 0) try self.allocator.dupe(u8, key) else ParseError.InvalidSyntax;
    }

    fn parseString(self: *Parser) ParseError![]const u8 {
        const quote = self.consume().?;
        var result = std.ArrayList(u8).initCapacity(
            self.allocator,
            32,
        ) catch return ParseError.OutOfMemory;
        errdefer result.deinit(self.allocator);
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
            debug.warn(
                "Array nesting too deep (> {}) at line {}, treating as invalid",
                .{ max_array_depth, self.line },
            );
            return ParseError.InvalidValue;
        }

        self.in_array = true;
        defer self.in_array = false;

        _ = self.consume();
        var array = try std.ArrayList(Value).initCapacity(self.allocator, 8);
        errdefer deinitValues(&array, self.allocator);

        while (true) {
            self.skipWhitespaceAndNewlines();
            if (self.peek() == ']') {
                _ = self.consume();
                break;
            }
            try array.append(self.allocator, try self.parseValue());
            self.skipWhitespaceAndNewlines();
            if (self.peek() == ',') _ = self.consume();
        }

        return array;
    }

    const boolean_keywords = std.StaticStringMap(bool).initComptime(.{
        .{ "true", true }, .{ "false", false },
    });

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
    fn parseBareTokenValue(self: *Parser, raw: []const u8) ParseError!Value {
        if (boolean_keywords.get(raw)) |b| return .{ .boolean = b };

        if (raw.len > 1 and raw[raw.len - 1] == '%') {
            const f = std.fmt.parseFloat(
                f32,
                raw[0 .. raw.len - 1],
            ) catch return ParseError.InvalidValue;
            if (!std.math.isFinite(f)) return ParseError.InvalidValue;
            return .{ .scalable = ScalableValue.percentage(f) };
        }

        // Bare decimal (no '%' suffix), e.g. `border_width = 2.5`: parsed as
        // an absolute ScalableValue so such fields don't keep their struct
        // default for lacking a '%'. Whole numbers stay integers so
        // asInt()/asBool() consumers are unaffected.
        if (looksLikeDecimal(raw)) {
            const f = std.fmt.parseFloat(f32, raw) catch return ParseError.InvalidValue;
            if (std.math.isFinite(f)) return .{ .scalable = ScalableValue.absolute(f) };
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
            return .{ .string = try self.allocator.dupe(u8, raw) };
        }
    }

    // Parses a bare (unquoted) value: one token is a scalar; two or more
    // (whitespace/commas) form an array, e.g. `segments = workspaces layout
    // clock` -> ["workspaces","layout","clock"] or `icons = #ac3232, #52263e`
    // -> [0xac3232, 0x52263e]. Inside `[...]` one token is consumed (commas
    // belong to parseArray); semicolons are likewise left to the pair parser.
    fn parseBareValues(self: *Parser) ParseError!Value {
        var items: std.ArrayList(Value) = .empty;
        errdefer deinitValues(&items, self.allocator);

        while (true) {
            self.skipWhitespace();
            const nxt = self.peek() orelse break;
            if (nxt == '\n' or nxt == ';') break;
            // A '#' following a token is a comment; a leading '#' (no token
            // collected yet) starts a color literal instead.
            if (nxt == '#' and items.items.len > 0) break;
            const token = self.parseBareToken() orelse break;
            try items.append(self.allocator, try self.parseBareTokenValue(token));
            if (self.in_array) break;
            self.skipWhitespace();
            if (self.peek() == ',') _ = self.consume();
        }

        if (items.items.len == 0) return ParseError.InvalidValue;
        if (items.items.len == 1) {
            const single = items.swapRemove(0);
            items.deinit(self.allocator);
            return single;
        }
        return .{ .array = items };
    }

    fn parseValue(self: *Parser) ParseError!Value {
        self.skipWhitespace();
        const c = self.peek() orelse return ParseError.InvalidValue;

        if (c == '[') return .{ .array = try self.parseArray() };
        if (c == '"' or c == '\'') return .{ .string = try self.parseString() };

        return self.parseBareValues();
    }

    // Advances past a trailing newline or comment character at line end.
    fn skipLineEnd(self: *Parser, c: ?u8) void {
        switch (c orelse return) {
            '\n' => _ = self.consume(),
            '#' => self.skipToNewline(),
            else => {},
        }
    }

    // Parses one `key = value` pair, or a bare `key` (treated as `key = true`).
    // Workspace rule entries like `Navigator` rely on the bare-key shorthand.
    fn parseKeyValuePair(self: *Parser) ParseError!struct { []const u8, Value } {
        const key = try self.parseKey();
        errdefer self.allocator.free(key);
        self.skipWhitespace();

        if (self.peek() == '=') {
            _ = self.consume();
            const value = try self.parseValue();
            return .{ key, value };
        }
        return .{ key, Value{ .boolean = true } };
    }

    // Parses `key = value` pairs (and bare `key` flags) until a blank line,
    // comment, `;` terminator, or end of content. Duplicate keys accumulate
    // into arrays so a repeated keybind or include runs all declarations.
    fn parsePairs(self: *Parser, section: *Section) ParseError!void {
        while (true) {
            var kv = self.parseKeyValuePair() catch |err| {
                debug.warn("Invalid key-value at line {}: {}", .{ self.line, err });
                self.skipToNewline();
                continue;
            };

            errdefer {
                self.allocator.free(kv[0]);
                kv[1].deinit(self.allocator);
            }

            if (section.pairs.getPtr(kv[0])) |old| {
                // Duplicate key: accumulate both values into an array rather
                // than overwriting, so a keybind can bind multiple actions:
                //
                //   Mod+Shift+1 = "move_to_workspace_1"
                //   Mod+Shift+1 = "toggle_tag_1"
                //
                // parseKeybindings treats array values as sequences; scalar
                // reads of a repeated key resolve to the last declaration.
                try accumulate(self.allocator, old, kv[1], false);
                self.allocator.free(kv[0]);
            } else {
                try section.pairs.put(kv[0], kv[1]);
                section.recordKey(self.allocator, kv[0]);
            }

            self.skipWhitespace();
            if (!self.advanceAfterPair()) break;
        }
    }

    // Advances past the end of one pair: an optional ';' terminator, trailing
    // whitespace, and any line-end comment or newline. Returns false (stop
    // the pair loop) on a terminator or an unexpected trailing character.
    fn advanceAfterPair(self: *Parser) bool {
        const next = self.peek();
        if (next == ';') _ = self.consume();
        self.skipWhitespace();
        const trail = self.peek();
        if (trail == '\n' or trail == '#' or trail == null) {
            self.skipLineEnd(trail);
            return false;
        }
        debug.warn("Unexpected character at line {}", .{self.line});
        self.skipToNewline();
        return false;
    }
};

pub fn parse(allocator: std.mem.Allocator, content: []const u8) !Document {
    var doc = Document.init(allocator);
    errdefer doc.deinit();

    var p = Parser.init(allocator, content);
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
                debug.warn("Array-of-tables header '[[...]]' unsupported at line {}", .{p.line});
                p.skipToNewline();
                continue;
            }
            const section_name = p.parseSection() catch |err| {
                debug.warn("Invalid section at line {}: {}", .{ p.line, err });
                p.skipToNewline();
                continue;
            };
            errdefer allocator.free(section_name);

            if (doc.sections.getPtr(section_name)) |existing| {
                // Duplicate section header: keep filling the existing section
                // so duplicate keys accumulate as if the blocks were one
                // section, consistent with the cross-file merge path.
                allocator.free(section_name);
                current_section = existing;
            } else {
                try doc.sections.put(section_name, Section.init(allocator));
                current_section = doc.sections.getPtr(section_name).?;
            }

            continue;
        }

        try p.parsePairs(current_section);
    }

    return doc;
}
