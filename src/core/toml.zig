// Minimal TOML parser - optimized for speed and low memory usage

const std = @import("std");
const builtin = @import("builtin");

pub const Value = union(enum) {
    integer: i64,
    string: []const u8,
    array: std.ArrayList(Value),
    color: u32,

    pub inline fn asInt(self: Value) ?i64 {
        return switch (self) {
            .integer => |i| i,
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
    name: []const u8,
    pairs: std.StringHashMap(Value),

    pub fn init(allocator: std.mem.Allocator, name: []const u8) Section {
        var map = std.StringHashMap(Value).init(allocator);
        map.ensureTotalCapacity(8) catch {};
        return .{ .name = name, .pairs = map };
    }

    pub fn deinit(self: *Section) void {
        self.pairs.deinit();
    }

    pub inline fn get(self: *const Section, key: []const u8) ?Value {
        return self.pairs.get(key);
    }

    pub inline fn getInt(self: *const Section, key: []const u8) ?i64 {
        return if (self.get(key)) |v| v.asInt() else null;
    }

    pub inline fn getString(self: *const Section, key: []const u8) ?[]const u8 {
        return if (self.get(key)) |v| v.asString() else null;
    }

    pub inline fn getColor(self: *const Section, key: []const u8) ?u32 {
        return if (self.get(key)) |v| v.asColor() else null;
    }
};

pub const Document = struct {
    allocator: std.mem.Allocator,
    sections: std.StringHashMap(Section),
    root: Section,

    pub fn init(allocator: std.mem.Allocator) Document {
        var sections = std.StringHashMap(Section).init(allocator);
        sections.ensureTotalCapacity(4) catch {};
        return .{
            .allocator = allocator,
            .sections = sections,
            .root = Section.init(allocator, ""),
        };
    }

    pub fn deinit(self: *Document) void {
        // Helper to clean up a section's pairs
        const cleanPairs = struct {
            fn clean(alloc: std.mem.Allocator, pairs: *std.StringHashMap(Value)) void {
                var iter = pairs.iterator();
                while (iter.next()) |entry| {
                    alloc.free(entry.key_ptr.*);
                    var val = entry.value_ptr.*;
                    val.deinit(alloc);
                }
                pairs.deinit();
            }
        }.clean;

        cleanPairs(self.allocator, &self.root.pairs);

        var section_iter = self.sections.iterator();
        while (section_iter.next()) |section_entry| {
            self.allocator.free(section_entry.key_ptr.*);
            cleanPairs(self.allocator, &section_entry.value_ptr.pairs);
        }
        self.sections.deinit();
    }

    pub inline fn getSection(self: *const Document, name: []const u8) ?*const Section {
        return self.sections.getPtr(name);
    }

    pub inline fn get(self: *const Document, key: []const u8) ?Value {
        return self.root.get(key);
    }
};

pub const ParseError = error{
    InvalidSyntax,
    InvalidSection,
    InvalidValue,
    InvalidColor,
    DuplicateKey,
    OutOfMemory,
};

const Parser = struct {
    allocator: std.mem.Allocator,
    content: []const u8,
    pos: usize,
    line: usize,

    fn init(allocator: std.mem.Allocator, content: []const u8) Parser {
        return .{ .allocator = allocator, .content = content, .pos = 0, .line = 1 };
    }

    fn skipWhitespace(self: *Parser) void {
        while (self.pos < self.content.len) {
            switch (self.content[self.pos]) {
                ' ', '\t', '\r' => self.pos += 1,
                else => break,
            }
        }
    }

    fn skipLine(self: *Parser) void {
        while (self.pos < self.content.len and self.content[self.pos] != '\n') {
            self.pos += 1;
        }
        if (self.pos < self.content.len) {
            self.pos += 1;
            self.line += 1;
        }
    }

    fn peek(self: *const Parser) ?u8 {
        return if (self.pos < self.content.len) self.content[self.pos] else null;
    }

    fn consume(self: *Parser) ?u8 {
        const c = self.peek() orelse return null;
        self.pos += 1;
        if (c == '\n') self.line += 1;
        return c;
    }

    fn parseSection(self: *Parser) ParseError![]const u8 {
        _ = self.consume(); // consume '['
        self.skipWhitespace();

        const start = self.pos;
        while (self.peek()) |c| {
            if (c == ']') break;
            if (c == '\n') return ParseError.InvalidSection;
            _ = self.consume();
        }

        if (self.peek() != ']') return ParseError.InvalidSection;
        _ = self.consume(); // consume ']'

        const name = std.mem.trim(u8, self.content[start..self.pos - 1], " \t");
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

        // Fast path: scan for escapes or end quote
        var end_pos = start;
        var has_escapes = false;
        while (end_pos < self.content.len) : (end_pos += 1) {
            const c = self.content[end_pos];
            if (c == quote) {
                if (!has_escapes) {
                    self.pos = end_pos + 1;
                    return try allocator.dupe(u8, self.content[start..end_pos]);
                }
                break;
            }
            if (c == '\\') has_escapes = true;
            if (c == '\n') return ParseError.InvalidValue;
        }

        // Slow path: handle escapes
        var result = std.ArrayList(u8){};
        try result.ensureTotalCapacity(allocator, end_pos - start);

        while (self.peek()) |c| {
            if (c == quote) break;
            if (c == '\n') return ParseError.InvalidValue;

            if (c == '\\') {
                _ = self.consume();
                const next = self.consume() orelse return ParseError.InvalidValue;
                try result.append(allocator, switch (next) {
                    'n' => '\n',
                    't' => '\t',
                    'r' => '\r',
                    '\\' => '\\',
                    '"', '\'' => next,
                    else => return ParseError.InvalidValue,
                });
            } else {
                try result.append(allocator, c);
                _ = self.consume();
            }
        }

        _ = self.consume(); // consume closing quote
        return try result.toOwnedSlice(allocator);
    }

    fn parseColor(_: *Parser, value: []const u8) ParseError!u32 {
        const offset: usize = if (value[0] == '#') 1 else if (value.len > 2 and value[0] == '0' and value[1] == 'x') 2 else 0;
        return std.fmt.parseInt(u32, value[offset..], 16) catch ParseError.InvalidColor;
    }

    fn parseArray(self: *Parser, allocator: std.mem.Allocator) ParseError!std.ArrayList(Value) {
        _ = self.consume(); // consume '['

        var array = std.ArrayList(Value){};
        try array.ensureTotalCapacity(allocator, 4);

        while (true) {
            self.skipWhitespace();
            if (self.peek() == ']') {
                _ = self.consume();
                break;
            }

            try array.append(allocator, try self.parseValue(allocator));
            self.skipWhitespace();
            if (self.peek() == ',') _ = self.consume();
        }

        return array;
    }

    fn parseValue(self: *Parser, allocator: std.mem.Allocator) ParseError!Value {
        self.skipWhitespace();
        const c = self.peek() orelse return ParseError.InvalidValue;

        if (c == '[') return .{ .array = try self.parseArray(allocator) };
        if (c == '"' or c == '\'') return .{ .string = try self.parseString(allocator) };

        // Parse integer or color
        const start = self.pos;
        while (self.pos < self.content.len and self.content[self.pos] != '\n' and self.content[self.pos] != '#') {
            self.pos += 1;
        }

        const raw = std.mem.trim(u8, self.content[start..self.pos], " \t\r");
        if (raw.len == 0) return ParseError.InvalidValue;

        // Detect color: has # prefix, 0x prefix, or hex letters a-f/A-F
        const is_color = raw[0] == '#' or (raw.len > 2 and raw[0] == '0' and raw[1] == 'x') or
            for (raw) |ch| { if (ch >= 'a' and ch <= 'f' or ch >= 'A' and ch <= 'F') break true; } else false;

        return if (is_color)
            .{ .color = try self.parseColor(raw) }
        else
            .{ .integer = std.fmt.parseInt(i64, raw, 10) catch return ParseError.InvalidValue };
    }

    fn parseKeyValue(self: *Parser, allocator: std.mem.Allocator) ParseError!struct { []const u8, Value } {
        const key = try self.parseKey();
        self.skipWhitespace();
        if (self.consume() != '=') return ParseError.InvalidSyntax;
        return .{ key, try self.parseValue(allocator) };
    }
};

pub fn parse(allocator: std.mem.Allocator, content: []const u8) !Document {
    var doc = Document.init(allocator);
    errdefer doc.deinit();

    var parser = Parser.init(allocator, content);
    var current_section: *Section = &doc.root;

    while (parser.pos < parser.content.len) {
        parser.skipWhitespace();
        const c = parser.peek() orelse break;

        if (c == '\n') {
            _ = parser.consume();
            continue;
        }

        if (c == '#') {
            parser.skipLine();
            continue;
        }

        if (c == '[') {
            const section_name = try parser.parseSection();
            if (doc.sections.contains(section_name)) return ParseError.DuplicateKey;

            try doc.sections.put(section_name, Section.init(allocator, section_name));
            current_section = doc.sections.getPtr(section_name).?;

            parser.skipWhitespace();
            if (parser.peek() == '\n') _ = parser.consume();
            continue;
        }

        const kv = try parser.parseKeyValue(allocator);
        if (current_section.pairs.contains(kv[0])) return ParseError.DuplicateKey;
        try current_section.pairs.put(kv[0], kv[1]);

        parser.skipWhitespace();
        if (parser.peek() == '\n') _ = parser.consume();
    }

    return doc;
}
