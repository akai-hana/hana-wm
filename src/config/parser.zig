//! Config file parser
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

pub const Value = union(enum) {
    integer: i64,
    boolean: bool,
    string: []const u8,
    array: std.ArrayList(Value),
    color: u32,
    scalable: ScalableValue,

    pub inline fn asInt(self: Value) ?i64 {
        return switch (self) {
            .integer => |i| i,
            else => null,
        };
    }
    pub inline fn asBool(self: Value) ?bool {
        return switch (self) {
            .boolean => |b| b,
            .integer => |i| i != 0,
            else => null,
        };
    }
    pub inline fn asString(self: Value) ?[]const u8 {
        return switch (self) {
            .string => |s| s,
            else => null,
        };
    }
    pub inline fn asColor(self: Value) ?u32 {
        return switch (self) {
            .color => |c| c,
            else => null,
        };
    }
    pub inline fn asArray(self: Value) ?[]const Value {
        return switch (self) {
            .array => |arr| arr.items,
            else => null,
        };
    }
    /// Both whole-number and decimal absolute values arrive here as `.scalable`
    /// (parseValue converts any bare numeric literal containing a `.` into a
    /// `.scalable` too, not just `%`-suffixed ones — see the decimal-literal
    /// branch there). `.integer` is retained purely for callers that need a
    /// true integer (workspace counts, master counts, etc.); it is widened
    /// losslessly here for the convenience of callers that only care about
    /// the scalable form.
    pub inline fn asScalable(self: Value) ?ScalableValue {
        return switch (self) {
            .scalable => |s| s,
            .integer => |i| ScalableValue.absolute(@floatFromInt(i)),
            else => null,
        };
    }

    pub fn deinit(self: *Value, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .string => |s| allocator.free(s),
            .array => |*arr| {
                for (arr.items) |*item| item.deinit(allocator);
                arr.deinit(allocator);
            },
            else => {},
        }
    }
};

pub const Section = struct {
    pairs: std.StringHashMap(Value),

    pub fn init(allocator: std.mem.Allocator) Section {
        var map = std.StringHashMap(Value).init(allocator);
        map.ensureTotalCapacity(16) catch {};
        return .{ .pairs = map };
    }

    pub fn deinit(self: *Section, allocator: std.mem.Allocator) void {
        cleanPairs(allocator, &self.pairs);
    }

    pub fn get(self: *const Section, key: []const u8) ?Value {
        return self.pairs.get(key);
    }

    /// Generic typed getter — dispatches to the matching `Value.asXxx()` accessor
    /// for the requested type.  All five typed getters below are thin wrappers
    /// around this single function so the dispatch logic lives in one place.
    pub fn getAs(self: *const Section, comptime T: type, key: []const u8) ?T {
        const v = self.get(key) orelse return null;
        return switch (T) {
            i64 => v.asInt(),
            bool => v.asBool(),
            []const u8 => v.asString(),
            []const Value => v.asArray(),
            ScalableValue => v.asScalable(),
            else => @compileError("Section.getAs: unsupported type " ++ @typeName(T)),
        };
    }

    pub fn getInt(self: *const Section, key: []const u8) ?i64 {
        return self.getAs(i64, key);
    }
    pub fn getBool(self: *const Section, key: []const u8) ?bool {
        return self.getAs(bool, key);
    }
    pub fn getString(self: *const Section, key: []const u8) ?[]const u8 {
        return self.getAs([]const u8, key);
    }
    pub fn getArray(self: *const Section, key: []const u8) ?[]const Value {
        return self.getAs([]const Value, key);
    }
    pub fn getScalable(self: *const Section, key: []const u8) ?ScalableValue {
        return self.getAs(ScalableValue, key);
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
        cleanPairs(self.allocator, &self.root.pairs);

        var section_iter = self.sections.iterator();
        while (section_iter.next()) |section_entry| {
            self.allocator.free(section_entry.key_ptr.*);
            cleanPairs(self.allocator, &section_entry.value_ptr.pairs);
        }
        self.sections.deinit();
    }

    pub fn getSection(self: *const Document, name: []const u8) ?*const Section {
        return self.sections.getPtr(name);
    }

    pub fn get(self: *const Document, key: []const u8) ?Value {
        return self.root.get(key);
    }
};

// Document merging

/// Deep-copies a Value; string and array contents are newly allocated.
/// Integer, boolean, color, and scalable values are plain copies.
fn deepCopyValue(allocator: std.mem.Allocator, val: Value) std.mem.Allocator.Error!Value {
    return switch (val) {
        .string => |s| .{ .string = try allocator.dupe(u8, s) },
        .array => |arr| blk: {
            var new_arr = try std.ArrayList(Value).initCapacity(allocator, arr.items.len);
            errdefer {
                for (new_arr.items) |*item| item.deinit(allocator);
                new_arr.deinit(allocator);
            }
            for (arr.items) |item| new_arr.appendAssumeCapacity(try deepCopyValue(allocator, item));
            break :blk .{ .array = new_arr };
        },
        else => val, // integer / boolean / color / scalable are trivially copyable
    };
}

/// Wraps `old_val` in a fresh array if it isn't one already, so callers can
/// append into it. On error, `old_val` is left untouched.
fn ensureArray(allocator: std.mem.Allocator, old_val: *Value) !void {
    if (old_val.* == .array) return;
    var arr = try std.ArrayList(Value).initCapacity(allocator, 1);
    errdefer {
        for (arr.items) |*item| item.deinit(allocator);
        arr.deinit(allocator);
    }
    arr.appendAssumeCapacity(old_val.*);
    old_val.* = .{ .array = arr };
}

/// Accumulate `incoming` into the existing value at `old_val`.
///
/// Shared by the single-file duplicate-key path (`accumulateScalar`) and the
/// multi-file merge path (`mergeIntoArray`): both wrap a scalar in a fresh
/// array and flatten an array-valued `incoming` into one flat array, so the
/// same logical situation — a key declared twice — produces the same shape
/// whether it happened within one file or was split across two included files.
///
/// With `move` set, `incoming` is uniquely owned (freshly parsed within a
/// single file) and its array elements are transferred into `old_val.array` by
/// ownership — no copy pass. With `move` clear, elements are deep-copied so
/// `incoming` stays independently owned (it is a copy taken from a distinct
/// source document). Takes ownership of `incoming`; `old_val` is updated
/// in place.
fn accumulate(comptime move: bool, allocator: std.mem.Allocator, old_val: *Value, incoming: Value) !void {
    try ensureArray(allocator, old_val);
    if (incoming == .array) {
        var inc = incoming;
        const start = old_val.array.items.len;
        for (inc.array.items) |item| {
            const elt = if (comptime move) item else try deepCopyValue(allocator, item);
            old_val.array.append(allocator, elt) catch |err| {
                if (comptime move) {
                    // Un-append the already-moved elements so the caller's
                    // errdefer (which deinits `incoming`) frees each one exactly
                    // once — without this, the moved elements would be freed
                    // both here and again when `old_val` is later deinited.
                    old_val.array.shrinkRetainingCapacity(start);
                }
                return err;
            };
        }
        if (comptime move) {
            inc.array.deinit(allocator); // items transferred by ownership; free only the backing array
        } else {
            // Items were deep-copied into `old_val`; free the source copies
            // and their backing array so nothing from `incoming` leaks.
            for (inc.array.items) |*item| item.deinit(allocator);
            inc.array.deinit(allocator);
        }
    } else {
        try old_val.array.append(allocator, incoming);
    }
}

/// Single-file duplicate-key accumulation: `incoming` is freshly parsed and
/// uniquely owned, so elements are moved rather than copied.
fn accumulateScalar(allocator: std.mem.Allocator, old_val: *Value, incoming: Value) !void {
    return accumulate(true, allocator, old_val, incoming);
}

/// Multi-file merge accumulation: `incoming` is a copy taken from a distinct
/// source document, so elements are deep-copied before being stored.
fn mergeIntoArray(allocator: std.mem.Allocator, old_val: *Value, incoming: Value) !void {
    return accumulate(false, allocator, old_val, incoming);
}

/// Merges the key-value pairs of `src` into `dst`.
/// Duplicate keys are accumulated into arrays, exactly like the parser does for
/// duplicate keys within a single file — so a keybind defined in two different
/// config files will have both actions executed, not one overwriting the other.
/// `src` is not modified; all new data is freshly allocated.
fn mergeSectionsInto(allocator: std.mem.Allocator, dst: *Section, src: *const Section) !void {
    var iter = src.pairs.iterator();
    while (iter.next()) |entry| {
        const src_key = entry.key_ptr.*;
        const src_val = entry.value_ptr.*;
        if (dst.pairs.getPtr(src_key)) |old_val| {
            // Duplicate key: accumulate into an array, same as the single-file
            // parser does at parse time.  The merge path flattens incoming arrays
            // so that two files each declaring an array value produce a single
            // flat array rather than an array-of-arrays.
            const incoming = try deepCopyValue(allocator, src_val);
            errdefer {
                var v = incoming;
                v.deinit(allocator);
            }
            try mergeIntoArray(allocator, old_val, incoming);
        } else {
            const key_copy = try allocator.dupe(u8, src_key);
            errdefer allocator.free(key_copy);
            try dst.pairs.put(key_copy, try deepCopyValue(allocator, src_val));
        }
    }
}

/// Merges `src` into `dst`. Duplicate keys are accumulated into arrays rather
/// than overwritten, so the result is equivalent to having written all the
/// key-value pairs in a single file — consistent with how the parser itself
/// handles duplicate keys within one file.
pub fn mergeDocumentsInto(allocator: std.mem.Allocator, dst: *Document, src: *const Document) !void {
    // Merge root-level keys.
    try mergeSectionsInto(allocator, &dst.root, &src.root);

    // Merge named sections.
    var iter = src.sections.iterator();
    while (iter.next()) |entry| {
        const name = entry.key_ptr.*;
        if (dst.sections.getPtr(name)) |dst_sec| {
            // Section already exists — merge pairs.
            try mergeSectionsInto(allocator, dst_sec, entry.value_ptr);
        } else {
            // New section — deep-copy it wholesale.
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

/// Parses an RGB hex color string (`#RRGGBB`, `0xRRGGBB`, or bare `RRGGBB`).
pub fn parseColor(value: []const u8) !u32 {
    if (value.len == 0) return error.InvalidColor;

    const offset: u8 =
        if (value[0] == '#') 1 else if (value.len > 2 and value[0] == '0' and (value[1] == 'x' or value[1] == 'X')) 2 else 0;
    const hex_part = value[offset..];

    if (hex_part.len == 0) return error.InvalidColor;

    const color = std.fmt.parseInt(u32, hex_part, 16) catch return error.InvalidColor;
    if (color > 0xFFFFFF) return error.InvalidColor;
    return color;
}

/// Frees all key strings and recursively deinits all values in `pairs`, then deinits the map.
fn cleanPairs(alloc: std.mem.Allocator, pairs: *std.StringHashMap(Value)) void {
    var iter = pairs.iterator();
    while (iter.next()) |entry| {
        alloc.free(entry.key_ptr.*);
        var val = entry.value_ptr.*;
        val.deinit(alloc);
    }
    pairs.deinit();
}

const Parser = struct {
    allocator: std.mem.Allocator,
    content: []const u8,
    pos: usize,
    line: usize,
    /// Current nested-array depth; incremented on entry to parseArray and
    /// checked against MAX_ARRAY_DEPTH to guard against a pathologically
    /// deeply nested literal (`[[[[[...]]]]]`) exhausting the stack. Config
    /// files are locally authored and trusted, not adversarial input, so this
    /// is a defensive backstop rather than a response to an observed problem —
    /// consistent with the existing MAX_FILE_BYTES / fc-list-output caps
    /// elsewhere in the config subsystem.
    array_depth: usize = 0,

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
        const start = self.pos;

        // Scan ahead to determine whether escape processing is needed.
        var has_escapes = false;
        var end_pos = start;
        while (end_pos < self.content.len) {
            const c = self.content[end_pos];
            if (c == quote) break;
            if (c == '\\') {
                has_escapes = true;
                break;
            }
            if (c == '\n') return ParseError.InvalidValue;
            end_pos += 1;
        }

        if (!has_escapes) {
            if (end_pos >= self.content.len) return ParseError.InvalidValue;
            const result = try self.allocator.dupe(u8, self.content[start..end_pos]);
            self.pos = end_pos + 1;
            return result;
        }

        var result = try std.ArrayList(u8).initCapacity(self.allocator, end_pos - start);
        errdefer result.deinit(self.allocator);

        var closed = false;
        while (self.peek()) |c| {
            if (c == quote) {
                closed = true;
                break;
            }
            if (c == '\n') return ParseError.InvalidValue;

            if (c == '\\') {
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

        if (!closed) return ParseError.InvalidValue;
        _ = self.consume();
        return try result.toOwnedSlice(self.allocator);
    }

    /// Maximum nested-array depth accepted by parseArray (see array_depth doc comment).
    const MAX_ARRAY_DEPTH = 16;

    fn parseArray(self: *Parser) ParseError!std.ArrayList(Value) {
        self.array_depth += 1;
        defer self.array_depth -= 1;
        if (self.array_depth > MAX_ARRAY_DEPTH) {
            debug.warn("Array nesting too deep (> {}) at line {}, treating as invalid", .{ MAX_ARRAY_DEPTH, self.line });
            return ParseError.InvalidValue;
        }

        _ = self.consume();
        var array = try std.ArrayList(Value).initCapacity(self.allocator, 8);
        errdefer {
            for (array.items) |*item| item.deinit(self.allocator);
            array.deinit(self.allocator);
        }

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

    const BOOLEAN_KEYWORDS = std.StaticStringMap(bool).initComptime(.{
        .{ "true", true }, .{ "false", false },
    });

    /// Returns true when `raw` is an optionally-signed bare decimal literal:
    /// digits, exactly one '.', and at least one digit overall (e.g. "2.5",
    /// "-0.3", "0.15"). Whole numbers (no '.') and malformed tokens (multiple
    /// dots, stray letters) return false and fall through to the existing
    /// color/integer/string handling in `parseValue`.
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

    fn parseValue(self: *Parser) ParseError!Value {
        self.skipWhitespace();
        const c = self.peek() orelse return ParseError.InvalidValue;

        if (c == '[') return .{ .array = try self.parseArray() };
        if (c == '"' or c == '\'') return .{ .string = try self.parseString() };

        const start = self.pos;
        while (self.pos < self.content.len and
            self.content[self.pos] != '\n' and
            self.content[self.pos] != '#')
        {
            self.pos += 1;
        }

        const raw = std.mem.trim(u8, self.content[start..self.pos], " \t\r");
        if (raw.len == 0) return ParseError.InvalidValue;

        if (BOOLEAN_KEYWORDS.get(raw)) |b| return .{ .boolean = b };

        if (raw.len > 1 and raw[raw.len - 1] == '%') {
            const f = std.fmt.parseFloat(f32, raw[0 .. raw.len - 1]) catch return ParseError.InvalidValue;
            return .{ .scalable = ScalableValue.percentage(f) };
        }

        // Bare decimal literal (no '%' suffix): e.g. `border_width = 2.5` or
        // `indicator_padding = 0.15`. Parsed as an absolute ScalableValue so
        // ScalableValue-typed config fields no longer silently keep their
        // struct default just because the value lacked a '%' suffix — see
        // `looksLikeDecimal` below. Whole numbers (no '.') are intentionally
        // left to the integer branch further down so asInt()/asBool()
        // consumers are unaffected.
        if (looksLikeDecimal(raw)) {
            if (std.fmt.parseFloat(f32, raw)) |f| return .{ .scalable = ScalableValue.absolute(f) } else |_| {}
        }

        // Bare color literals require an explicit '#' or '0x' prefix. Sniffing
        // for hex-only letters (the old heuristic) meant any short, all-lowercase
        // identifier composed entirely of a-f characters — e.g. "dead", "cafe",
        // "face" — would parse as `.color` instead of `.string`, silently
        // breaking any asString()/ACTION_MAP.get() lookup downstream the moment
        // such a word appeared as a layout/variant/segment/action name. Bare hex
        // digits with no prefix (e.g. "ac3232") now simply fall through to the
        // integer-parse attempt below and then to `.string`, the same fallback
        // path already used for every other unrecognized bare token.
        const looks_like_color = raw[0] == '#' or
            (raw.len > 2 and raw[0] == '0' and (raw[1] == 'x' or raw[1] == 'X'));

        if (looks_like_color) {
            if (parseColor(raw)) |color| return .{ .color = color } else |_| {}
        }

        if (std.fmt.parseInt(i64, raw, 10)) |int_val| return .{ .integer = int_val } else |_| {
            // Not a color, not an integer, not a boolean or percentage: treat
            // as an unquoted bare string so the caller sees a Value rather than
            // an error.  This avoids ParseError.InvalidValue for tokens like
            // layout or action names that appear without quotes.
            return .{ .string = try self.allocator.dupe(u8, raw) };
        }
    }

    /// Advances past a trailing newline or comment character at line end.
    fn skipLineEnd(self: *Parser, c: ?u8) void {
        if (c == '\n') _ = self.consume();
        if (c == '#') self.skipToNewline();
    }

    /// Parses one `key = value` pair, or a bare `key` (treated as `key = true`).
    /// Workspace rule entries like `Navigator` rely on the bare-key shorthand.
    fn parseKeyValuePair(self: *Parser) ParseError!struct { []const u8, Value } {
        const key = try self.parseKey();
        errdefer self.allocator.free(key);
        self.skipWhitespace();

        if (self.peek() == '=') {
            _ = self.consume();
            const value = self.parseValue() catch |err| return err;
            return .{ key, value };
        }
        return .{ key, Value{ .boolean = true } };
    }
};

/// Parses a configuration string into a `Document`.
pub fn parse(allocator: std.mem.Allocator, content: []const u8) !Document {
    var doc = Document.init(allocator);
    errdefer doc.deinit();

    var p = Parser.init(allocator, content);
    var current_section: *Section = &doc.root;

    while (p.pos < p.content.len) {
        p.skipWhitespace();
        const c = p.peek() orelse break;

        if (c == '\n') {
            _ = p.consume();
            continue;
        }
        if (c == '#') {
            p.skipToNewline();
            continue;
        }

        if (c == '[') {
            const section_name = p.parseSection() catch |err| {
                debug.warn("Invalid section at line {}: {}", .{ p.line, err });
                p.skipToNewline();
                continue;
            };
            errdefer allocator.free(section_name);

            if (doc.sections.contains(section_name)) {
                allocator.free(section_name);
                debug.warn("Duplicate section at line {}", .{p.line});
                p.skipToNewline();
                continue;
            }

            try doc.sections.put(section_name, Section.init(allocator));
            current_section = doc.sections.getPtr(section_name).?;

            p.skipWhitespace();
            if (p.peek() == '\n') _ = p.consume();
            continue;
        }

        while (true) {
            var kv = p.parseKeyValuePair() catch |err| {
                debug.warn("Invalid key-value at line {}: {}", .{ p.line, err });
                p.skipToNewline();
                break;
            };

            errdefer {
                allocator.free(kv[0]);
                kv[1].deinit(allocator);
            }

            if (current_section.pairs.getPtr(kv[0])) |old| {
                // Duplicate key: merge both values into an array rather than
                // overwriting. This lets the user assign multiple actions to
                // one keybind by repeating the key:
                //
                //   Mod+Shift+1 = "move_to_workspace_1"
                //   Mod+Shift+1 = "toggle_tag_1"
                //
                // parseKeybindings already handles array values as sequences,
                // so no further changes are needed there.
                try accumulateScalar(allocator, old, kv[1]);
                allocator.free(kv[0]);
            } else {
                try current_section.pairs.put(kv[0], kv[1]);
            }

            p.skipWhitespace();
            const next = p.peek();

            if (next == ';') {
                _ = p.consume();
                p.skipWhitespace();
                const after = p.peek();
                if (after == '\n' or after == '#' or after == null) {
                    p.skipLineEnd(after);
                    break;
                }
                continue;
            }

            if (next == '\n' or next == '#' or next == null) {
                p.skipLineEnd(next);
                break;
            }

            debug.warn("Unexpected character at line {}", .{p.line});
            p.skipToNewline();
            break;
        }
    }

    return doc;
}
