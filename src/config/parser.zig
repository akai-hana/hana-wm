//! Minimal TOML-inspired parser for hana WM configuration files.
//!
//! The format extends TOML with WM-specific conveniences: bare keys (treated
//! as `key = true`), percentage literals (e.g. `50%`), unquoted hex colors
//! (`#ac3232`), comma-as-decimal separator, and duplicate-key merging into
//! arrays (used to bind multiple actions to one key).

const std   = @import("std");
const debug = @import("debug");

/// A value that can be expressed as either an absolute pixel count or a
/// percentage of some reference dimension.
pub const ScalableValue = struct {
    value:        f32,
    is_percentage: bool,

    pub inline fn absolute(val: f32) ScalableValue   { return .{ .value = val, .is_percentage = false }; }
    pub inline fn percentage(val: f32) ScalableValue { return .{ .value = val, .is_percentage = true  }; }
};

pub const Value = union(enum) {
    integer:  i64,
    boolean:  bool,
    string:   []const u8,
    array:    std.ArrayList(Value),
    color:    u32,
    scalable: ScalableValue,

    pub inline fn asInt(self: Value) ?i64           { return switch (self) { .integer  => |i| i, else => null }; }
    pub inline fn asBool(self: Value) ?bool         { return switch (self) { .boolean  => |b| b, .integer => |i| i != 0, else => null }; }
    pub inline fn asString(self: Value) ?[]const u8 { return switch (self) { .string   => |s| s, else => null }; }
    pub inline fn asColor(self: Value) ?u32         { return switch (self) { .color    => |c| c, else => null }; }
    pub inline fn asArray(self: Value) ?[]const Value {
        return switch (self) { .array => |arr| arr.items, else => null };
    }
    pub inline fn asScalable(self: Value) ?ScalableValue {
        return switch (self) {
            .scalable => |s| s,
            .integer  => |i| ScalableValue.absolute(@floatFromInt(i)),
            else      => null,
        };
    }

    pub fn deinit(self: *Value, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .string => |s|    allocator.free(s),
            .array  => |*arr| {
                for (arr.items) |*item| item.deinit(allocator);
                arr.deinit(allocator);
            },
            else => {},
        }
    }
};

pub const Section = struct {
    name:  []const u8,
    pairs: std.StringHashMap(Value),

    pub fn init(allocator: std.mem.Allocator, name: []const u8) Section {
        var map = std.StringHashMap(Value).init(allocator);
        map.ensureTotalCapacity(16) catch {};
        return .{ .name = name, .pairs = map };
    }

    pub fn deinit(self: *Section) void { self.pairs.deinit(); }

    pub fn get(self: *const Section, key: []const u8) ?Value { return self.pairs.get(key); }

    pub fn getInt     (self: *const Section, key: []const u8) ?i64          { return if (self.get(key)) |v| v.asInt()      else null; }
    pub fn getBool    (self: *const Section, key: []const u8) ?bool         { return if (self.get(key)) |v| v.asBool()     else null; }
    pub fn getString  (self: *const Section, key: []const u8) ?[]const u8   { return if (self.get(key)) |v| v.asString()   else null; }
    pub fn getColor   (self: *const Section, key: []const u8) ?u32          { return if (self.get(key)) |v| v.asColor()    else null; }
    pub fn getScalable(self: *const Section, key: []const u8) ?ScalableValue { return if (self.get(key)) |v| v.asScalable() else null; }
};

pub const Document = struct {
    allocator: std.mem.Allocator,
    sections:  std.StringHashMap(Section),
    root:      Section,

    pub fn init(allocator: std.mem.Allocator) Document {
        var sections = std.StringHashMap(Section).init(allocator);
        sections.ensureTotalCapacity(8) catch {};
        return .{ .allocator = allocator, .sections = sections, .root = Section.init(allocator, "") };
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

// ---------------------------------------------------------------------------
// Document merging
// ---------------------------------------------------------------------------

/// Deep-copies a Value; string and array contents are newly allocated.
/// Integer, boolean, color, and scalable values are plain copies.
fn deepCopyValue(allocator: std.mem.Allocator, val: Value) std.mem.Allocator.Error!Value {
    return switch (val) {
        .string => |s| .{ .string = try allocator.dupe(u8, s) },
        .array  => |arr| blk: {
            var new_arr = try std.ArrayList(Value).initCapacity(allocator, arr.items.len);
            errdefer {
                for (new_arr.items) |*item| item.deinit(allocator);
                new_arr.deinit(allocator);
            }
            for (arr.items) |item| try new_arr.append(allocator, try deepCopyValue(allocator, item));
            break :blk .{ .array = new_arr };
        },
        else => val, // integer / boolean / color / scalable are trivially copyable
    };
}

/// Merges the key-value pairs of `src` into `dst`.
/// Keys present in both are overwritten with `src`'s value (last-file-wins).
/// `src` is not modified; all new data is freshly allocated.
fn mergeSectionsInto(allocator: std.mem.Allocator, dst: *Section, src: *const Section) !void {
    var iter = src.pairs.iterator();
    while (iter.next()) |entry| {
        const src_key = entry.key_ptr.*;
        const src_val = entry.value_ptr.*;
        if (dst.pairs.getPtr(src_key)) |old_val| {
            // Overwrite: free the old value, deep-copy the incoming one.
            var old = old_val.*;
            old.deinit(allocator);
            old_val.* = try deepCopyValue(allocator, src_val);
        } else {
            const key_copy = try allocator.dupe(u8, src_key);
            errdefer allocator.free(key_copy);
            try dst.pairs.put(key_copy, try deepCopyValue(allocator, src_val));
        }
    }
}

/// Merges `src` into `dst`; `src` takes precedence for any conflicting scalar
/// keys (last-file-wins), but both documents remain valid after the call.
///
/// Intended use: parse each config file into its own Document, then fold them
/// all into a single Document with successive `mergeDocumentsInto` calls.
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
            var new_sec = Section.init(allocator, name);
            errdefer new_sec.deinit();
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
    DuplicateKey,
    OutOfMemory,
};

/// Parses an RGB hex color string (`#RRGGBB`, `0xRRGGBB`, or bare `RRGGBB`).
pub fn parseColor(value: []const u8) !u32 {
    if (value.len == 0) return error.InvalidColor;

    const offset: u8 =
        if (value[0] == '#') 1
        else if (value.len > 2 and value[0] == '0' and (value[1] == 'x' or value[1] == 'X')) 2
        else 0;
    const hex_part = value[offset..];

    if (hex_part.len == 0) return error.InvalidColor;

    const color = std.fmt.parseInt(u32, hex_part, 16) catch return error.InvalidColor;
    if (color > 0xFFFFFF) return error.InvalidColor;
    return color;
}

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
    content:   []const u8,
    pos:       usize,
    line:      usize,

    fn init(allocator: std.mem.Allocator, content: []const u8) Parser {
        return .{ .allocator = allocator, .content = content, .pos = 0, .line = 1 };
    }

    fn skip(self: *Parser, comptime include_newlines: bool, comptime include_comments: bool) void {
        while (self.pos < self.content.len) {
            switch (self.content[self.pos]) {
                ' ', '\t', '\r' => self.pos += 1,
                '\n' => if (include_newlines) { self.pos += 1; self.line += 1; } else break,
                '#'  => if (include_comments) self.skipToNewline() else break,
                else => break,
            }
        }
    }

    fn skipToNewline(self: *Parser) void {
        while (self.pos < self.content.len and self.content[self.pos] != '\n') self.pos += 1;
        if (self.pos < self.content.len) { self.pos += 1; self.line += 1; }
    }

    inline fn skipWhitespace(self: *Parser) void            { self.skip(false, false); }
    inline fn skipWhitespaceAndNewlines(self: *Parser) void { self.skip(true, true); }

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

    fn parseString(self: *Parser, allocator: std.mem.Allocator) ParseError![]const u8 {
        const quote = self.consume().?;
        const start = self.pos;

        // Scan ahead to determine whether escape processing is needed.
        var has_escapes = false;
        var end_pos = start;
        while (end_pos < self.content.len) {
            const c = self.content[end_pos];
            if (c == quote)  break;
            if (c == '\\')  { has_escapes = true; break; }
            if (c == '\n')  return ParseError.InvalidValue;
            end_pos += 1;
        }

        if (!has_escapes) {
            if (end_pos >= self.content.len) return ParseError.InvalidValue;
            const result = try allocator.dupe(u8, self.content[start..end_pos]);
            self.pos = end_pos + 1;
            return result;
        }

        var result = try std.ArrayList(u8).initCapacity(allocator, end_pos - start);
        errdefer result.deinit(allocator);

        while (self.peek()) |c| {
            if (c == quote) break;
            if (c == '\n') return ParseError.InvalidValue;

            if (c == '\\') {
                _ = self.consume();
                const next = self.consume() orelse return ParseError.InvalidValue;
                try result.append(allocator, switch (next) {
                    'n'        => '\n',
                    't'        => '\t',
                    'r'        => '\r',
                    '\\'       => '\\',
                    '"', '\'' => next,
                    else       => return ParseError.InvalidValue,
                });
            } else {
                try result.append(allocator, c);
                _ = self.consume();
            }
        }

        _ = self.consume();
        return try result.toOwnedSlice(allocator);
    }

    fn parseArray(self: *Parser, allocator: std.mem.Allocator) ParseError!std.ArrayList(Value) {
        _ = self.consume();
        var array = try std.ArrayList(Value).initCapacity(allocator, 8);
        errdefer {
            for (array.items) |*item| item.deinit(allocator);
            array.deinit(allocator);
        }

        while (true) {
            self.skipWhitespaceAndNewlines();
            if (self.peek() == ']') { _ = self.consume(); break; }
            try array.append(allocator, try self.parseValue(allocator));
            self.skipWhitespaceAndNewlines();
            if (self.peek() == ',') _ = self.consume();
        }

        return array;
    }

    const BOOLEANS = std.StaticStringMap(bool).initComptime(.{
        .{ "true", true }, .{ "false", false },
    });

    fn parseValue(self: *Parser, allocator: std.mem.Allocator) ParseError!Value {
        self.skipWhitespace();
        const c = self.peek() orelse return ParseError.InvalidValue;

        if (c == '[')              return .{ .array  = try self.parseArray(allocator) };
        if (c == '"' or c == '\'') return .{ .string = try self.parseString(allocator) };

        const start = self.pos;
        while (self.pos < self.content.len and
               self.content[self.pos] != '\n' and
               self.content[self.pos] != '#') {
            self.pos += 1;
        }

        const raw = std.mem.trim(u8, self.content[start..self.pos], " \t\r");
        if (raw.len == 0) return ParseError.InvalidValue;

        if (BOOLEANS.get(raw)) |b| return .{ .boolean = b };

        if (raw.len > 1 and raw[raw.len - 1] == '%') {
            const f = std.fmt.parseFloat(f32, raw[0..raw.len - 1]) catch return ParseError.InvalidValue;
            return .{ .scalable = ScalableValue.percentage(f) };
        }

        // Hex digits overlap with base-10, so check for a color-like token before
        // trying integer parsing; otherwise "ac3232" would fail integer parsing
        // rather than being recognised as a color.
        const looks_like_color = raw[0] == '#' or
            (raw.len > 2 and raw[0] == '0' and (raw[1] == 'x' or raw[1] == 'X')) or
            std.mem.indexOfAny(u8, raw, "abcdefABCDEF") != null;

        if (looks_like_color) {
            if (parseColor(raw)) |color| return .{ .color = color } else |_| {
                if (std.fmt.parseInt(i64, raw, 10)) |int_val| return .{ .integer = int_val } else |_| {
                    debug.warn("Invalid color '{s}' at line {}", .{ raw, self.line });
                    return ParseError.InvalidColor;
                }
            }
        }

        return .{ .integer = std.fmt.parseInt(i64, raw, 10) catch return ParseError.InvalidValue };
    }

    // Bare keys (no `=`) are treated as `key = true`, which is the only call
    // site's expectation. Workspace rule entries like `Navigator` use this.
    fn parseKeyValuePair(self: *Parser, allocator: std.mem.Allocator) ParseError!struct { []const u8, Value } {
        const key = try self.parseKey();
        errdefer self.allocator.free(key);
        self.skipWhitespace();

        if (self.peek() == '=') {
            _ = self.consume();
            const value = self.parseValue(allocator) catch |err| {
                self.allocator.free(key);
                return err;
            };
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

        if (c == '\n') { _ = p.consume(); continue; }
        if (c == '#')  { p.skipToNewline();    continue; }

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

            try doc.sections.put(section_name, Section.init(allocator, section_name));
            current_section = doc.sections.getPtr(section_name).?;

            p.skipWhitespace();
            if (p.peek() == '\n') _ = p.consume();
            continue;
        }

        while (true) {
            var kv = p.parseKeyValuePair(allocator) catch |err| {
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
                //   Mod+Shift+1 = "tag_toggle_1"
                //
                // parseKeybindings already handles array values as sequences,
                // so no further changes are needed there.
                if (old.* == .array) {
                    try old.array.append(allocator, kv[1]);
                } else {
                    // First duplicate: wrap the original scalar and new value
                    // in a 2-element array. initCapacity(2) guarantees both
                    // appendAssumeCapacity calls cannot fail.
                    var arr = try std.ArrayList(Value).initCapacity(allocator, 2);
                    arr.appendAssumeCapacity(old.*);
                    arr.appendAssumeCapacity(kv[1]);
                    old.* = .{ .array = arr };
                }
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
                    if (after == '\n') _ = p.consume();
                    if (after == '#') p.skipToNewline();
                    break;
                }
                continue;
            }

            if (next == '\n' or next == '#' or next == null) {
                if (next == '\n') _ = p.consume();
                if (next == '#') p.skipToNewline();
                break;
            }

            debug.warn("Unexpected character at line {}", .{p.line});
            p.skipToNewline();
            break;
        }
    }

    return doc;
}
