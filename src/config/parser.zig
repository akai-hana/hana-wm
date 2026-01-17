// Minimal custom TOML parser with improved error resilience

const std = @import("std");
const builtin = @import("builtin");

pub const Value = union(enum) {
    integer: i64,
    boolean: bool,
    string: []const u8,
    array: std.ArrayList(Value),
    color: u32,

    pub inline fn asInt(self: Value) ?i64 {
        return switch (self) {
            .integer => |i| i,
            else => null,
        };
    }

    pub inline fn asBool(self: Value) ?bool {
        return switch (self) {
            .boolean => |b| b,
            .integer => |i| i != 0,  // Also accept integers as booleans
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

    pub inline fn getBool(self: *const Section, key: []const u8) ?bool {
        return if (self.get(key)) |v| v.asBool() else null;
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
        var result: std.ArrayList(u8) = std.ArrayList(u8){ .items = null, .len = 0, .allocator = allocator };

        errdefer result.deinit();
        try result.ensureTotalCapacity(end_pos - start);

        while (self.peek()) |c| {
            if (c == quote) break;
            if (c == '\n') return ParseError.InvalidValue;

            if (c == '\\') {
                _ = self.consume();
                const next = self.consume() orelse return ParseError.InvalidValue;
                try result.append(switch (next) {
                    'n' => '\n',
                    't' => '\t',
                    'r' => '\r',
                    '\\' => '\\',
                    '"', '\'' => next,
                    else => return ParseError.InvalidValue,
                });
            } else {
                try result.append(c);
                _ = self.consume();
            }
        }

        _ = self.consume(); // consume closing quote
        return try result.toOwnedSlice();
    }

    fn parseColor(_: *Parser, value: []const u8) !u32 {
        if (value.len == 0) return error.InvalidColor;

        const offset: usize = if (value[0] == '#') 1 else if (value.len > 2 and value[0] == '0' and value[1] == 'x') 2 else 0;
        const hex_part = value[offset..];

        if (hex_part.len == 0) return error.InvalidColor;

        // Try to parse as hex
        const color = std.fmt.parseInt(u32, hex_part, 16) catch return error.InvalidColor;

        // Validate it's within RGB range (0x000000 - 0xFFFFFF)
        if (color > 0xFFFFFF) return error.InvalidColor;

        return color;
    }

    fn parseArray(self: *Parser, allocator: std.mem.Allocator) ParseError!std.ArrayList(Value) {
        _ = self.consume(); // consume '['

        var array = std.ArrayList(Value).init(allocator);
        errdefer {
            for (array.items) |*item| item.deinit(allocator);
            array.deinit();
        }
        try array.ensureTotalCapacity(4);

        while (true) {
            self.skipWhitespace();
            if (self.peek() == ']') {
                _ = self.consume();
                break;
            }

            try array.append(try self.parseValue(allocator));
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

        // Parse boolean, integer, or color
        const start = self.pos;
        while (self.pos < self.content.len and self.content[self.pos] != '\n' and self.content[self.pos] != '#') {
            self.pos += 1;
        }

        const raw = std.mem.trim(u8, self.content[start..self.pos], " \t\r");
        if (raw.len == 0) return ParseError.InvalidValue;

        // Check for boolean
        if (std.mem.eql(u8, raw, "true")) return .{ .boolean = true };
        if (std.mem.eql(u8, raw, "false")) return .{ .boolean = false };

        // Detect color: has # prefix, 0x prefix, or hex letters a-f/A-F
        const is_color = raw[0] == '#' or (raw.len > 2 and raw[0] == '0' and raw[1] == 'x') or
            for (raw) |ch| { if (ch >= 'a' and ch <= 'f' or ch >= 'A' and ch <= 'F') break true; } else false;

        if (is_color) {
            // Try to parse as color, but if it fails, try integer fallback
            if (self.parseColor(raw)) |color| {
                return .{ .color = color };
            } else |_| {
                // Color parsing failed, try integer
                if (std.fmt.parseInt(i64, raw, 10)) |int_val| {
                    return .{ .integer = int_val };
                } else |_| {
                    // Both failed - this is truly invalid
                    std.log.warn("[parser] Invalid color value '{s}' at line {}", .{raw, self.line});
                    return ParseError.InvalidColor;
                }
            }
        } else {
            // Parse as integer
            return .{ .integer = std.fmt.parseInt(i64, raw, 10) catch return ParseError.InvalidValue };
        }
    }

    fn parseKeyValue(self: *Parser, allocator: std.mem.Allocator) ParseError!struct { []const u8, Value } {
        const key = try self.parseKey();
        errdefer self.allocator.free(key);  // Free key if error occurs after allocation
        self.skipWhitespace();
        if (self.consume() != '=') return ParseError.InvalidSyntax;
        
        const value = self.parseValue(allocator) catch |err| {
            self.allocator.free(key);
            return err;
        };
        
        return .{ key, value };
    }

    fn parseKeyValueOrBareWord(self: *Parser, allocator: std.mem.Allocator) ParseError!struct { []const u8, Value } {
        const key = try self.parseKey();
        errdefer self.allocator.free(key);
        self.skipWhitespace();

        // Check if there's an equals sign
        if (self.peek() == '=') {
            _ = self.consume(); // consume '='
            
            const value = self.parseValue(allocator) catch |err| {
                self.allocator.free(key);
                return err;
            };
            
            return .{ key, value };
        } else {
            // No equals sign - treat as bare word with implicit true value
            return .{ key, Value{ .boolean = true } };
        }
    }
};

pub fn parse(allocator: std.mem.Allocator, content: []const u8) !Document {
    var doc = Document.init(allocator);
    errdefer {
        // CRITICAL: Ensure full cleanup on any error
        doc.deinit();
    }

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
            const section_name = parser.parseSection() catch |err| {
                std.log.warn("[parser] Skipping invalid section at line {}: {}", .{parser.line, err});
                parser.skipLine();
                continue;
            };
            errdefer allocator.free(section_name);

            if (doc.sections.contains(section_name)) {
                allocator.free(section_name); // Free duplicate section name
                std.log.warn("[parser] Duplicate section at line {}, ignoring", .{parser.line});
                parser.skipLine();
                continue;
            }

            try doc.sections.put(section_name, Section.init(allocator, section_name));
            current_section = doc.sections.getPtr(section_name).?;

            parser.skipWhitespace();
            if (parser.peek() == '\n') _ = parser.consume();
            continue;
        }

        // Parse key-value pairs (potentially multiple on one line separated by semicolons)
        while (true) {
            // Try to parse as key-value, or fall back to bare word
            var kv = parser.parseKeyValueOrBareWord(allocator) catch |err| {
                // Skip this line and continue parsing
                std.log.warn("[parser] Skipping invalid key-value at line {}: {any}", .{parser.line, err});
                parser.skipLine();
                break;
            };

            errdefer {
                allocator.free(kv[0]);  // Free the duplicated key
                kv[1].deinit(allocator);  // Deinit the value (handles strings, arrays, etc.)
            }

            if (current_section.pairs.contains(kv[0])) {
                std.log.warn("[parser] Duplicate key '{s}' at line {}, using last value", .{kv[0], parser.line});
                // Free the old value before replacing
                if (current_section.pairs.getPtr(kv[0])) |old_val| {
                    old_val.deinit(allocator);
                }
            }

            try current_section.pairs.put(kv[0], kv[1]);

            parser.skipWhitespace();

            // Check what comes next
            const next = parser.peek();
            if (next == ';') {
                // Semicolon - consume it and parse another key-value pair on this line
                _ = parser.consume();
                parser.skipWhitespace();

                // If we hit a newline or comment after the semicolon, stop
                const after_semi = parser.peek();
                if (after_semi == '\n' or after_semi == '#' or after_semi == null) {
                    if (after_semi == '\n') _ = parser.consume();
                    if (after_semi == '#') parser.skipLine();
                    break;
                }
                // Otherwise continue to parse next key-value pair
                continue;
            } else if (next == '\n' or next == '#' or next == null) {
                // End of line or comment - stop parsing this line
                if (next == '\n') _ = parser.consume();
                if (next == '#') parser.skipLine();
                break;
            } else {
                // Unexpected character - skip rest of line
                std.log.warn("[parser] Unexpected character after value at line {}, skipping line", .{parser.line});
                parser.skipLine();
                break;
            }
        }
    }

    return doc;
}
