// Minimal TOML parser - optimized for speed and low memory usage
// Supports: [sections], key=value, integers, hex colors, strings, arrays, comments, escape sequences

const std = @import("std");
const builtin = @import("builtin");

/// Parsed value type - union is 16 bytes (pointer-sized)
pub const Value = union(enum) {
    integer: i64,
    string: []const u8,
    array: std.ArrayList(Value),
    color: u32,

    /// Fast accessor with no overhead
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
                for (arr.items) |*item| {
                    item.deinit(allocator);
                }
                arr.deinit(allocator);
            },
            else => {},
        }
    }
};

/// TOML section - pre-allocated capacity for typical config sizes
pub const Section = struct {
    name: []const u8,
    pairs: std.StringHashMap(Value),

    pub fn init(allocator: std.mem.Allocator, name: []const u8) Section {
        // Pre-allocate for typical section size (reduces rehashing)
        var map = std.StringHashMap(Value).init(allocator);
        map.ensureTotalCapacity(8) catch {}; // Typical config has ~8 keys per section
        
        return .{
            .name = name,
            .pairs = map,
        };
    }

    pub fn deinit(self: *Section) void {
        self.pairs.deinit();
    }

    /// Hot path: inline to avoid function call overhead
    pub inline fn get(self: *const Section, key: []const u8) ?Value {
        return self.pairs.get(key);
    }

    pub inline fn getInt(self: *const Section, key: []const u8) ?i64 {
        const val = self.get(key) orelse return null;
        return val.asInt();
    }

    pub inline fn getString(self: *const Section, key: []const u8) ?[]const u8 {
        const val = self.get(key) orelse return null;
        return val.asString();
    }

    pub inline fn getColor(self: *const Section, key: []const u8) ?u32 {
        const val = self.get(key) orelse return null;
        return val.asColor();
    }
};

/// Parsed TOML document
pub const Document = struct {
    allocator: std.mem.Allocator,
    sections: std.StringHashMap(Section),
    root: Section,

    pub fn init(allocator: std.mem.Allocator) Document {
        // Pre-allocate for typical config (reduces rehashing during parsing)
        var sections = std.StringHashMap(Section).init(allocator);
        sections.ensureTotalCapacity(4) catch {}; // Typical config has ~4 sections
        
        return .{
            .allocator = allocator,
            .sections = sections,
            .root = Section.init(allocator, ""),
        };
    }

    pub fn deinit(self: *Document) void {
        // Clean up root section
        {
            var iter = self.root.pairs.iterator();
            while (iter.next()) |entry| {
                // Free the key
                self.allocator.free(entry.key_ptr.*);
                // Free the value
                var mutable_val = entry.value_ptr.*;
                mutable_val.deinit(self.allocator);
            }
            self.root.pairs.deinit();
        }
        
        // Clean up all sections
        var section_iter = self.sections.iterator();
        while (section_iter.next()) |section_entry| {
            // Free the section name
            self.allocator.free(section_entry.key_ptr.*);
            
            // Free all key-value pairs in this section
            var pair_iter = section_entry.value_ptr.pairs.iterator();
            while (pair_iter.next()) |entry| {
                // Free the key
                self.allocator.free(entry.key_ptr.*);
                // Free the value
                var mutable_val = entry.value_ptr.*;
                mutable_val.deinit(self.allocator);
            }
            
            section_entry.value_ptr.pairs.deinit();
        }
        
        self.sections.deinit();
    }

    /// Hot path: inline for zero overhead
    pub inline fn getSection(self: *const Document, name: []const u8) ?*const Section {
        return self.sections.getPtr(name);
    }

    pub inline fn get(self: *const Document, key: []const u8) ?Value {
        return self.root.get(key);
    }
};

/// Parse errors
pub const ParseError = error{
    InvalidSyntax,
    InvalidSection,
    InvalidValue,
    InvalidColor,
    DuplicateKey,
    OutOfMemory,
};

/// Parser state - compact for cache efficiency
const Parser = struct {
    allocator: std.mem.Allocator,
    content: []const u8,
    pos: usize,
    line: usize,

    inline fn init(allocator: std.mem.Allocator, content: []const u8) Parser {
        return .{
            .allocator = allocator,
            .content = content,
            .pos = 0,
            .line = 1,
        };
    }

    /// Hot path: inline and use pointer arithmetic
    inline fn skipWhitespace(self: *Parser) void {
        const len = self.content.len;
        while (self.pos < len) {
            const c = self.content[self.pos];
            if (c == ' ' or c == '\t' or c == '\r') {
                @branchHint(.likely); // Usually whitespace
                self.pos += 1;
            } else {
                @branchHint(.unlikely);
                break;
            }
        }
    }

    inline fn skipLine(self: *Parser) void {
        const len = self.content.len;
        while (self.pos < len and self.content[self.pos] != '\n') {
            self.pos += 1;
        }
        if (self.pos < len) {
            self.pos += 1;
            self.line += 1;
        }
    }

    inline fn isEof(self: *const Parser) bool {
        return self.pos >= self.content.len;
    }

    inline fn peek(self: *const Parser) ?u8 {
        if (self.isEof()) return null;
        return self.content[self.pos];
    }

    inline fn consume(self: *Parser) ?u8 {
        const c = self.peek() orelse return null;
        self.pos += 1;
        if (c == '\n') self.line += 1;
        return c;
    }

    /// Parse section header
    fn parseSection(self: *Parser) ParseError![]const u8 {
        _ = self.consume(); // consume '['
        self.skipWhitespace();

        const start = self.pos;
        while (self.peek()) |c| {
            if (c == ']') break;
            if (c == '\n') {
                if (builtin.mode == .Debug) {
                    std.debug.print("Error (line {}): Section header not closed\n", .{self.line});
                }
                return ParseError.InvalidSection;
            }
            _ = self.consume();
        }

        if (self.peek() != ']') {
            if (builtin.mode == .Debug) {
                std.debug.print("Error (line {}): Expected ']' to close section\n", .{self.line});
            }
            return ParseError.InvalidSection;
        }

        const name = std.mem.trim(u8, self.content[start..self.pos], " \t");
        _ = self.consume(); // consume ']'

        if (name.len == 0) {
            if (builtin.mode == .Debug) {
                std.debug.print("Error (line {}): Empty section name\n", .{self.line});
            }
            return ParseError.InvalidSection;
        }

        return try self.allocator.dupe(u8, name);
    }

    /// Parse key - optimized to avoid trim by skipping whitespace first
    inline fn parseKey(self: *Parser) ParseError![]const u8 {
        // Skip leading whitespace first
        self.skipWhitespace();
        
        const start = self.pos;
        const len = self.content.len;
        
        // Fast loop using unchecked access (bounds already guaranteed)
        while (self.pos < len) {
            const c = self.content[self.pos];
            if (c == '=' or c == ' ' or c == '\t' or c == '\n') break;
            self.pos += 1;
        }

        const key = self.content[start..self.pos];
        if (key.len == 0) {
            if (builtin.mode == .Debug) {
                std.debug.print("Error (line {}): Empty key\n", .{self.line});
            }
            return ParseError.InvalidSyntax;
        }

        return try self.allocator.dupe(u8, key);
    }

    /// Parse string - optimized with fast path for no escapes
    fn parseString(self: *Parser, allocator: std.mem.Allocator) ParseError![]const u8 {
        const quote = self.consume().?;
        const start = self.pos;
        const len = self.content.len;

        // Fast scan for escapes or end quote
        var end_pos = start;
        var has_escapes = false;
        
        while (end_pos < len) : (end_pos += 1) {
            const c = self.content[end_pos];
            if (c == quote) {
                // Fast path: no escapes, direct slice
                if (!has_escapes) {
                    const value = self.content[start..end_pos];
                    self.pos = end_pos + 1;
                    return try allocator.dupe(u8, value);
                }
                break;
            }
            if (c == '\\') {
                has_escapes = true;
            }
            if (c == '\n') {
                if (builtin.mode == .Debug) {
                    std.debug.print("Error (line {}): Unterminated string\n", .{self.line});
                }
                return ParseError.InvalidValue;
            }
        }

        // Slow path: handle escape sequences
        var result = std.ArrayList(u8){};
        errdefer result.deinit(allocator);
        
        // Pre-allocate approximate size
        try result.ensureTotalCapacity(allocator, end_pos - start);

        while (self.peek()) |c| {
            if (c == quote) break;
            if (c == '\n') {
                if (builtin.mode == .Debug) {
                    std.debug.print("Error (line {}): Unterminated string\n", .{self.line});
                }
                return ParseError.InvalidValue;
            }

            if (c == '\\') {
                _ = self.consume();
                const next = self.consume() orelse {
                    if (builtin.mode == .Debug) {
                        std.debug.print("Error (line {}): Escape at end of string\n", .{self.line});
                    }
                    return ParseError.InvalidValue;
                };

                const escaped: u8 = switch (next) {
                    'n' => '\n',
                    't' => '\t',
                    'r' => '\r',
                    '\\' => '\\',
                    '"' => '"',
                    '\'' => '\'',
                    else => {
                        if (builtin.mode == .Debug) {
                            std.debug.print("Error (line {}): Unknown escape '\\{c}'\n", .{ self.line, next });
                        }
                        return ParseError.InvalidValue;
                    },
                };
                try result.append(allocator, escaped);
            } else {
                try result.append(allocator, c);
                _ = self.consume();
            }
        }

        _ = self.consume(); // consume closing quote
        return try result.toOwnedSlice(allocator);
    }

    /// Parse color - inline for speed
    inline fn parseColor(self: *Parser, value: []const u8) ParseError!u32 {
        // Fast path: determine offset without allocation
        const hex_start: usize = if (value.len == 0)
            0
        else if (value[0] == '#')
            1
        else if (value.len > 1 and value[0] == '0' and value[1] == 'x')
            2
        else
            0;

        const hex_value = value[hex_start..];

        const color = std.fmt.parseInt(u32, hex_value, 16) catch {
            if (builtin.mode == .Debug) {
                std.debug.print("Error (line {}): Invalid color '{s}'\n", .{ self.line, value });
            }
            return ParseError.InvalidColor;
        };

        return color;
    }

    /// Parse array
    fn parseArray(self: *Parser, allocator: std.mem.Allocator) ParseError!std.ArrayList(Value) {
        _ = self.consume(); // consume '['

        var array = std.ArrayList(Value){};
        errdefer {
            for (array.items) |*item| {
                item.deinit(allocator);
            }
            array.deinit(allocator);
        }

        // Pre-allocate for typical small arrays
        try array.ensureTotalCapacity(allocator, 4);

        while (true) {
            self.skipWhitespace();
            if (self.peek() == ']') {
                _ = self.consume();
                break;
            }

            const value = try self.parseValue(allocator);
            try array.append(allocator, value);

            self.skipWhitespace();
            if (self.peek() == ',') {
                _ = self.consume();
            }
        }

        return array;
    }

    /// Parse value - hot path for config loading
    fn parseValue(self: *Parser, allocator: std.mem.Allocator) ParseError!Value {
        self.skipWhitespace();

        const c = self.peek() orelse {
            if (builtin.mode == .Debug) {
                std.debug.print("Error (line {}): Expected value\n", .{self.line});
            }
            return ParseError.InvalidValue;
        };

        // Array (rare)
        if (c == '[') {
            const arr = try self.parseArray(allocator);
            return Value{ .array = arr };
        }

        // String (common for commands)
        if (c == '"' or c == '\'') {
            const str = try self.parseString(allocator);
            return Value{ .string = str };
        }

        // Integer or color (common for config values)
        const start = self.pos;
        const len = self.content.len;
        
        // Fast scan to end of value
        while (self.pos < len) {
            const ch = self.content[self.pos];
            if (ch == '\n' or ch == '#') break;
            self.pos += 1;
        }

        const raw = std.mem.trim(u8, self.content[start..self.pos], " \t\r");
        if (raw.len == 0) {
            if (builtin.mode == .Debug) {
                std.debug.print("Error (line {}): Empty value\n", .{self.line});
            }
            return ParseError.InvalidValue;
        }

        // Detect color vs integer using fast checks
        const is_color = blk: {
            if (raw[0] == '#') break :blk true;
            if (raw.len > 2 and raw[0] == '0' and raw[1] == 'x') break :blk true;
            
            // Check for hex letters (a-f, A-F indicate color)
            for (raw) |ch| {
                if ((ch >= 'a' and ch <= 'f') or (ch >= 'A' and ch <= 'F')) {
                    break :blk true;
                }
            }
            break :blk false;
        };

        if (is_color) {
            const color = try self.parseColor(raw);
            return Value{ .color = color };
        }

        // Parse integer
        const int = std.fmt.parseInt(i64, raw, 10) catch {
            if (builtin.mode == .Debug) {
                std.debug.print("Error (line {}): Invalid value '{s}'\n", .{ self.line, raw });
            }
            return ParseError.InvalidValue;
        };

        return Value{ .integer = int };
    }

    /// Parse key-value pair
    inline fn parseKeyValue(self: *Parser, allocator: std.mem.Allocator) ParseError!struct { []const u8, Value } {
        const key = try self.parseKey();
        self.skipWhitespace();

        if (self.consume() != '=') {
            if (builtin.mode == .Debug) {
                std.debug.print("Error (line {}): Expected '=' after key '{s}'\n", .{ self.line, key });
            }
            return ParseError.InvalidSyntax;
        }

        const value = try self.parseValue(allocator);
        return .{ key, value };
    }
};

/// Parse TOML content - main entry point
pub fn parse(allocator: std.mem.Allocator, content: []const u8) !Document {
    @setEvalBranchQuota(100000); // Allow more compile-time evaluation

    var doc = Document.init(allocator);
    errdefer doc.deinit();

    var parser = Parser.init(allocator, content);
    var current_section: *Section = &doc.root;

    // Main parsing loop - optimized for typical config files
    while (!parser.isEof()) {
        parser.skipWhitespace();

        const c = parser.peek() orelse break;

        // Fast path: skip empty lines
        if (c == '\n') {
            _ = parser.consume();
            continue;
        }

        // Fast path: skip comments
        if (c == '#') {
            parser.skipLine();
            continue;
        }

        // Section header (infrequent)
        if (c == '[') {
            const section_name = try parser.parseSection();

            if (doc.sections.contains(section_name)) {
                if (builtin.mode == .Debug) {
                    std.debug.print("Error (line {}): Duplicate section '{s}'\n", .{ parser.line, section_name });
                }
                return ParseError.DuplicateKey;
            }

            const section = Section.init(allocator, section_name);
            try doc.sections.put(section_name, section);
            current_section = doc.sections.getPtr(section_name).?;

            parser.skipWhitespace();
            if (parser.peek() == '\n') _ = parser.consume();
            continue;
        }

        // Key-value pair (common)
        const kv = try parser.parseKeyValue(allocator);
        const key = kv[0];
        const value = kv[1];

        if (current_section.pairs.contains(key)) {
            if (builtin.mode == .Debug) {
                std.debug.print("Error (line {}): Duplicate key '{s}'\n", .{ parser.line, key });
            }
            return ParseError.DuplicateKey;
        }

        try current_section.pairs.put(key, value);

        parser.skipWhitespace();
        if (parser.peek() == '\n') _ = parser.consume();
    }

    return doc;
}
