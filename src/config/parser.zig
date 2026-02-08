//! TOML file parser 
//!
//! Key improvements:
//! - Reduced allocations in hot paths
//! - Better error handling
//! - Cleaner code structure
//! - Compile-time optimizations
//! - Improved fast-path string parsing

const std = @import("std");
const debug = @import("debug");

/// Represents a value that can be either absolute or percentage-based
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
    name: []const u8,
    pairs: std.StringHashMap(Value),

    pub fn init(allocator: std.mem.Allocator, name: []const u8) Section {
        var map = std.StringHashMap(Value).init(allocator);
        // OPTIMIZATION: Pre-allocate reasonable capacity
        map.ensureTotalCapacity(16) catch {};
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

    pub inline fn getScalable(self: *const Section, key: []const u8) ?ScalableValue {
        return if (self.get(key)) |v| v.asScalable() else null;
    }
};

pub const Document = struct {
    allocator: std.mem.Allocator,
    sections: std.StringHashMap(Section),
    root: Section,

    pub fn init(allocator: std.mem.Allocator) Document {
        var sections = std.StringHashMap(Section).init(allocator);
        // OPTIMIZATION: Pre-allocate reasonable capacity
        sections.ensureTotalCapacity(8) catch {};
        return .{
            .allocator = allocator,
            .sections = sections,
            .root = Section.init(allocator, ""),
        };
    }

    pub fn deinit(self: *Document) void {
        // OPTIMIZATION: Extract cleanup helper to reduce duplication
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

    // OPTIMIZATION: Inline simple methods
    inline fn skipWhitespace(self: *Parser) void {
        while (self.pos < self.content.len) {
            switch (self.content[self.pos]) {
                ' ', '\t', '\r' => self.pos += 1,
                else => break,
            }
        }
    }

    inline fn skipWhitespaceAndNewlines(self: *Parser) void {
        while (self.pos < self.content.len) {
            switch (self.content[self.pos]) {
                ' ', '\t', '\r' => self.pos += 1,
                '\n' => { self.pos += 1; self.line += 1; },
                '#' => self.skipLine(),
                else => break,
            }
        }
    }

    inline fn skipLine(self: *Parser) void {
        while (self.pos < self.content.len and self.content[self.pos] != '\n') {
            self.pos += 1;
        }
        if (self.pos < self.content.len) {
            self.pos += 1;
            self.line += 1;
        }
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

    // OPTIMIZATION: Improved string parsing with better fast-path
    fn parseString(self: *Parser, allocator: std.mem.Allocator) ParseError![]const u8 {
        const quote = self.consume().?;
        const start = self.pos;

        // OPTIMIZATION: Scan ahead to check if we need escape processing
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

        // Fast path: no escapes - direct slice
        if (!has_escapes) {
            // Continue scanning to find end quote
            while (end_pos < self.content.len and self.content[end_pos] != quote) {
                if (self.content[end_pos] == '\n') return ParseError.InvalidValue;
                end_pos += 1;
            }
            
            if (end_pos >= self.content.len) return ParseError.InvalidValue;
            
            const result = try allocator.dupe(u8, self.content[start..end_pos]);
            self.pos = end_pos + 1; // Skip closing quote
            return result;
        }

        // Slow path: handle escapes
        // OPTIMIZATION: Pre-allocate based on scanned length for better capacity estimation
        var result = try std.ArrayList(u8).initCapacity(allocator, end_pos - start);
        errdefer result.deinit(allocator);

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

        _ = self.consume();
        return try result.toOwnedSlice(allocator);
    }

    // OPTIMIZATION: Inline color parsing
    inline fn parseColor(_: *Parser, value: []const u8) !u32 {
        if (value.len == 0) return error.InvalidColor;

        const offset: u8 = if (value[0] == '#') 1 
            else if (value.len > 2 and value[0] == '0' and (value[1] == 'x' or value[1] == 'X')) 2 
            else 0;
        const hex_part = value[offset..];

        if (hex_part.len == 0) return error.InvalidColor;

        const color = std.fmt.parseInt(u32, hex_part, 16) catch return error.InvalidColor;

        if (color > 0xFFFFFF) return error.InvalidColor;

        return color;
    }

    fn parseArray(self: *Parser, allocator: std.mem.Allocator) ParseError!std.ArrayList(Value) {
        _ = self.consume();

        // OPTIMIZATION: Pre-allocate reasonable initial capacity
        var array = try std.ArrayList(Value).initCapacity(allocator, 8);
        errdefer {
            for (array.items) |*item| item.deinit(allocator);
            array.deinit(allocator);
        }

        while (true) {
            self.skipWhitespaceAndNewlines();
            if (self.peek() == ']') {
                _ = self.consume();
                break;
            }

            try array.append(allocator, try self.parseValue(allocator));
            self.skipWhitespaceAndNewlines();
            if (self.peek() == ',') _ = self.consume();
        }

        return array;
    }

    // OPTIMIZATION: Use static string maps for keyword detection
    const BOOLEANS = std.StaticStringMap(bool).initComptime(.{
        .{ "true", true },
        .{ "false", false },
    });

    fn parseValue(self: *Parser, allocator: std.mem.Allocator) ParseError!Value {
        self.skipWhitespace();
        const c = self.peek() orelse return ParseError.InvalidValue;

        if (c == '[') return .{ .array = try self.parseArray(allocator) };
        if (c == '"' or c == '\'') return .{ .string = try self.parseString(allocator) };

        const start = self.pos;
        while (self.pos < self.content.len and self.content[self.pos] != '\n' and self.content[self.pos] != '#') {
            self.pos += 1;
        }

        const raw = std.mem.trim(u8, self.content[start..self.pos], " \t\r");
        if (raw.len == 0) return ParseError.InvalidValue;

        // OPTIMIZATION: Use static map for boolean lookup
        if (BOOLEANS.get(raw)) |boolean| return .{ .boolean = boolean };

        // Check for percentage suffix
        if (raw.len > 1 and raw[raw.len - 1] == '%') {
            const num_part = raw[0..raw.len - 1];
            if (std.fmt.parseFloat(f32, num_part)) |float_val| {
                return .{ .scalable = ScalableValue.percentage(float_val) };
            } else |_| {
                return ParseError.InvalidValue;
            }
        }

        // OPTIMIZATION: Early detection of color values
        const looks_like_color = raw[0] == '#' or 
            (raw.len > 2 and raw[0] == '0' and (raw[1] == 'x' or raw[1] == 'X')) or
            blk: {
                // Quick scan for hex letters
                for (raw) |ch| {
                    if ((ch >= 'a' and ch <= 'f') or (ch >= 'A' and ch <= 'F')) break :blk true;
                }
                break :blk false;
            };

        if (looks_like_color) {
            if (self.parseColor(raw)) |color| {
                return .{ .color = color };
            } else |_| {
                // Fallback: try as integer
                if (std.fmt.parseInt(i64, raw, 10)) |int_val| {
                    return .{ .integer = int_val };
                } else |_| {
                    debug.warn("Invalid color '{s}' at line {}", .{ raw, self.line });
                    return ParseError.InvalidColor;
                }
            }
        } else {
            return .{ .integer = std.fmt.parseInt(i64, raw, 10) catch return ParseError.InvalidValue };
        }
    }

    // OPTIMIZATION: Merge parseKeyValue and parseKeyValueOrBareWord to reduce duplication
    fn parseKeyValuePair(self: *Parser, allocator: std.mem.Allocator, allow_bare: bool) ParseError!struct { []const u8, Value } {
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
        } else if (allow_bare) {
            return .{ key, Value{ .boolean = true } };
        } else {
            self.allocator.free(key);
            return ParseError.InvalidSyntax;
        }
    }
};

/// Parse TOML configuration from string
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
            const section_name = parser.parseSection() catch |err| {
                debug.warn("Invalid section at line {}: {}", .{ parser.line, err });
                parser.skipLine();
                continue;
            };
            errdefer allocator.free(section_name);

            if (doc.sections.contains(section_name)) {
                allocator.free(section_name);
                debug.warn("Duplicate section at line {}", .{parser.line});
                parser.skipLine();
                continue;
            }

            try doc.sections.put(section_name, Section.init(allocator, section_name));
            current_section = doc.sections.getPtr(section_name).?;

            parser.skipWhitespace();
            if (parser.peek() == '\n') _ = parser.consume();
            continue;
        }

        // OPTIMIZATION: Use merged parseKeyValuePair function
        while (true) {
            var kv = parser.parseKeyValuePair(allocator, true) catch |err| {
                debug.warn("Invalid key-value at line {}: {}", .{ parser.line, err });
                parser.skipLine();
                break;
            };

            errdefer {
                allocator.free(kv[0]);
                kv[1].deinit(allocator);
            }

            if (current_section.pairs.contains(kv[0])) {
                debug.warn("Duplicate key '{s}' at line {}", .{ kv[0], parser.line });
                if (current_section.pairs.getPtr(kv[0])) |old_val| {
                    old_val.deinit(allocator);
                }
            }

            try current_section.pairs.put(kv[0], kv[1]);

            parser.skipWhitespace();

            const next = parser.peek();
            if (next == ';') {
                _ = parser.consume();
                parser.skipWhitespace();

                const after_semi = parser.peek();
                if (after_semi == '\n' or after_semi == '#' or after_semi == null) {
                    if (after_semi == '\n') _ = parser.consume();
                    if (after_semi == '#') parser.skipLine();
                    break;
                }
                continue;
            } else if (next == '\n' or next == '#' or next == null) {
                if (next == '\n') _ = parser.consume();
                if (next == '#') parser.skipLine();
                break;
            } else {
                debug.warn("Unexpected character at line {}", .{parser.line});
                parser.skipLine();
                break;
            }
        }
    }

    return doc;
}
