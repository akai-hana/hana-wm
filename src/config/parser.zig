//! Configuration parser.
//! Parses hana's TOML-inspired configuration format into structured values.
//!
//! Ownership model: every document produced by one load borrows from a single
//! load-scoped arena (the caller's `allocator`). String values are slices into
//! the source `content` where possible, and cross-document merging SHARES
//! keys and values rather than deep-copying them, because all documents in a
//! load share one allocator. This is only sound when every `parse`/`merge` in
//! a load is called with the same arena-backed allocator; the arena reset at
//! the end of the load reclaims everything, so Document/Section/Value own
//! nothing and have no deinit.

const std = @import("std");
const debug = @import("debug");
const types = @import("types");

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
    // Per-key source line, kept in parallel with `keys_in_order` for the
    // unrecognized-key / duplicate-key diagnostics (C5/C6/C14). Best-effort.
    lines_in_order: std.ArrayListUnmanaged(usize) = .empty,
    // Keys that were declared more than once in this section (across the
    // duplicate / cross-file merge paths). Distinct from a single literal
    // array value like `layouts = [...]`: only genuine duplicate declarations
    // accumulate, and only those warn when read as a scalar (C14).
    duplicated_keys: std.StringHashMap(void),
    // Keys already warned about for scalar-duplicate reads (C14), so each
    // section+key pair warns at most once.
    scalar_dup_warned: std.StringHashMap(void),
    // The section header this Section belongs to ("" for the root pairs that
    // have no header). Filled by parse() when a section is created; merged
    // sections carry their source name through the shared-value merge.
    name: []const u8 = "",

    pub fn init(allocator: std.mem.Allocator) Section {
        var map = std.StringHashMap(Value).init(allocator);
        map.ensureTotalCapacity(4) catch |err| debug.warnOnErr(err, "section pair map reserve");
        var consumed = std.StringHashMap(void).init(allocator);
        consumed.ensureTotalCapacity(4) catch |err| debug.warnOnErr(err, "section consumed-set reserve");
        var duplicated = std.StringHashMap(void).init(allocator);
        duplicated.ensureTotalCapacity(4) catch |err| debug.warnOnErr(err, "section duplicate tracking reserve");
        var dup_warned = std.StringHashMap(void).init(allocator);
        dup_warned.ensureTotalCapacity(4) catch |err| debug.warnOnErr(err, "section duplicate-diagnostic reserve");
        return .{ .pairs = map, .consumed = consumed, .duplicated_keys = duplicated, .scalar_dup_warned = dup_warned };
    }

    // Records `key` as the newest document-order key. Best-effort: an OOM
    // here just loses deterministic ordering for this section, never data.
    fn recordKey(self: *Section, allocator: std.mem.Allocator, key: []const u8) void {
        self.keys_in_order.append(allocator, key) catch {};
    }

    // Records `key` as the newest document-order key together with the source
    // line it was declared on. Best-effort on both halves (C5/C6 diagnostics).
    fn recordLine(self: *Section, allocator: std.mem.Allocator, key: []const u8, line: usize) void {
        self.recordKey(allocator, key);
        self.lines_in_order.append(allocator, line) catch {};
    }

    // Returns the source line `key` was first declared on in this section.
    pub fn lineOfKey(self: *const Section, key: []const u8) ?usize {
        for (self.keys_in_order.items, 0..) |k, i| {
            if (std.mem.eql(u8, k, key)) {
                if (i < self.lines_in_order.items.len) return self.lines_in_order.items[i];
                return null;
            }
        }
        return null;
    }

    // Records `key` as declared more than once (calling `accumulate` path);
    // these are the only keys that can trigger C14's scalar-duplicate warn.
    fn markDuplicated(self: *Section, key: []const u8) void {
        self.duplicated_keys.put(key, {}) catch {};
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
        self.consumed.put(key, {}) catch |err| debug.warnOnErr(err, "marking key consumed");
    }

    // Warns about every key in the section that was never examined via
    // get()/getAs()/markConsumed(); typically a typo in the key name, since
    // the parser otherwise accepts it silently. Names the source line so a
    // large config's typos are findable (C6).
    pub fn warnUnconsumed(self: *const Section, section_name: []const u8) void {
        var iter = self.pairs.iterator();
        while (iter.next()) |entry| {
            if (!self.consumed.contains(entry.key_ptr.*)) {
                debug.warn(
                    "Unrecognized key '{s}' in section [{s}] (line {d}); ignoring",
                    .{ entry.key_ptr.*, section_name, self.lineOfKey(entry.key_ptr.*) orelse 0 },
                );
            }
        }
    }

    pub fn get(self: *Section, key: []const u8) ?Value {
        self.markConsumed(key);
        const val = self.pairs.get(key);
        if (val) |v| self.warnScalarDuplicate(key, v);
        return val;
    }

    // C14: a key that accumulated duplicate declarations reads as an array,
    // but a scalar request resolves to the last declaration. Warn once (per
    // section+key) so silent last-wins isn't a surprise -- except in the
    // sections where accumulated arrays ARE the point: [binds], rule tables
    // ([workspace.rules]/[rules]), the root `include` key, and the [tiling]
    // `layouts` list.
    fn warnScalarDuplicate(self: *Section, key: []const u8, val: Value) void {
        if (val != .array) return;
        if (!self.duplicated_keys.contains(key)) return;
        if (self.scalar_dup_warned.contains(key)) return;
        const exempt = std.mem.eql(u8, self.name, "binds") or
            std.mem.eql(u8, self.name, "workspace.rules") or
            std.mem.eql(u8, self.name, "rules") or
            (self.name.len == 0 and std.mem.eql(u8, key, "include")) or
            (std.mem.eql(u8, self.name, "tiling") and std.mem.eql(u8, key, "layouts"));
        if (exempt) return;
        self.scalar_dup_warned.put(key, {}) catch {};
        const decls: usize = val.array.items.len;
        if (self.name.len == 0)
            debug.warn(
                "Duplicate key '{s}' accumulates into an array ({d} declarations); scalar reads use the last value",
                .{ key, decls },
            )
        else
            debug.warn(
                "Duplicate key '{s}' in section [{s}] accumulates into an array ({d} declarations); scalar reads use the last value",
                .{ key, self.name, decls },
            );
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

    // C4: `getAs` that also diagnoses a present-but-wrong-typed value, so a
    // knob silently keeping its default is never a surprise. Fires once per
    // read (schema.applyAll reads each knob's key exactly once). The
    // accumulated-duplicate case is already covered by get's
    // warnScalarDuplicate; a single literal array at a scalar knob warns
    // here as a wrong type.
    pub fn getAsOrWarn(self: *Section, comptime T: type, key: []const u8) ?T {
        const out = self.getAs(T, key);
        if (out == null) {
            if (self.pairs.get(key)) |v| {
                debug.warn(
                    "Key '{s}' in section [{s}] expects {s}, got {s}; ignoring (keeping default)",
                    .{ key, self.name, typeLabel(T), valueTypeLabel(v) },
                );
            }
        }
        return out;
    }
};

fn typeLabel(comptime T: type) []const u8 {
    return switch (T) {
        i64 => "a number",
        bool => "a boolean",
        []const u8 => "a string",
        u32 => "a color",
        ScalableValue => "a size or percentage",
        else => "a different type",
    };
}

fn valueTypeLabel(val: Value) []const u8 {
    return switch (val) {
        .integer => "a number",
        .boolean => "a boolean",
        .string => "a string",
        .array => "an array",
        .color => "a color",
        .scalable => "a size or percentage",
    };
}

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
    /// Document-global color palette: the reserved palette variable names
    /// (see `palette_var_names`) declared anywhere in the load, parsed as
    /// literal colors. Any color-valued knob may reference them by their
    /// full knob name (e.g. `border_focused = primary_color`) from any
    /// section. Populated by `collectPalette` once all includes are merged,
    /// so "later declaration wins" matches every other knob.
    palette: std.StringHashMap(u32),
    /// Set when any line in this document was warn-and-skipped, or when a
    /// whole file it represents was skipped during the load's merge.
    /// config.zig turns a had_errors merged document into
    /// error.ConfigParseFailed so a broken config can't silently partial-load
    /// (C1); keeps its existing per-line/file warns either way.
    had_errors: bool = false,
    /// Path of the TOML file this document was parsed from ("" for in-memory
    /// / embedded inputs). Named in every per-line diagnostic (C5).
    source_path: []const u8 = "",

    pub fn init(allocator: std.mem.Allocator) Document {
        var sections = std.StringHashMap(Section).init(allocator);
        sections.ensureTotalCapacity(8) catch |err| debug.warnOnErr(err, "document section map reserve");
        var palette = std.StringHashMap(u32).init(allocator);
        palette.ensureTotalCapacity(palette_var_names.len) catch |err| debug.warnOnErr(err, "document palette reserve");
        return .{ .allocator = allocator, .sections = sections, .root = Section.init(allocator), .palette = palette };
    }

    pub fn getSection(self: *Document, name: []const u8) ?*Section {
        return self.sections.getPtr(name);
    }

    pub fn get(self: *Document, key: []const u8) ?Value {
        return self.root.get(key);
    }
};

/// The named color-palette slots a theme declares once and any color-valued
/// knob may reference by full name (`border_focused = primary_color`,
/// `title = secondary_color`, ...). `primary_color` doubles as the bar's
/// default accent knob (the former `accent_color`); the other three are pure
/// palette declarations currently consumed by the fallback chain and the
/// theme's `[bar.colors]` entries.
const palette_var_names = [_][]const u8{
    "primary_color",
    "secondary_color",
    "alternative_color",
    "text_color",
};

/// Resolves a palette-declaration Value to a color: `.color` literals, hex
/// strings (quoted `"#RRGGBB"`), and in-range integers. Anything else is
/// ignored so a duplicated/non-color declaration can't poison the palette.
fn paletteColorOf(val: Value) ?u32 {
    return colorFromValue(val);
}

/// Single decoder for the color-literal / in-range-integer / hex-string forms
/// a color knob accepts. `null` means "not a color"; callers layer their own
/// palette-reference lookup and warning policy on top (schema's
/// getColorFromValue).
pub fn colorFromValue(val: Value) ?u32 {
    if (val.asScalar(u32)) |c| return c;
    if (val.asScalar(i64)) |i| {
        if (i >= 0 and i <= types.max_color) return @intCast(i);
    }
    if (val.asScalar([]const u8)) |s| {
        return parseColor(s) catch null;
    }
    return null;
}

/// Scans every section (and the root) for palette-variable declarations,
/// resolving each to its color value and storing the last declaration into
/// `doc.palette`. Also marks the keys consumed so they never appear as
/// unrecognized. Call once per merged Document, before knobs are applied.
pub fn collectPalette(self: *Document) void {
    for (palette_var_names) |name| {
        var best: ?u32 = null;
        var iter = self.sections.iterator();
        while (iter.next()) |entry| {
            if (entry.value_ptr.get(name)) |val| {
                if (paletteColorOf(val)) |c| best = c;
            }
        }
        if (self.root.get(name)) |val| {
            if (paletteColorOf(val)) |c| best = c;
        }
        if (best) |c| {
            self.palette.put(name, c) catch {};
        }
    }
}

// Document merging

// Wraps `old_val` in a fresh array if it isn't one already, so callers can
// append into it.
fn ensureArray(allocator: std.mem.Allocator, old_val: *Value) !void {
    if (old_val.* == .array) return;
    var arr = try std.ArrayList(Value).initCapacity(allocator, 1);
    arr.appendAssumeCapacity(old_val.*);
    old_val.* = .{ .array = arr };
}

// Accumulates `incoming` into `old_val`. An array-valued `incoming` is
// flattened. Values are SHARED, never copied: all documents in a load share
// one arena, so pointers stay valid until the load's arena reset. Scalar
// getters resolve to the LAST element (later files win); asArray sees the
// full accumulation so keybinds, `include`, `layouts`, etc. chain.
fn accumulate(
    allocator: std.mem.Allocator,
    old_val: *Value,
    incoming: Value,
) !void {
    try ensureArray(allocator, old_val);
    if (incoming == .array) {
        const inc = incoming;
        try old_val.array.appendSlice(allocator, inc.array.items);
    } else {
        try old_val.array.append(allocator, incoming);
    }
}

// Merges `src`'s pairs into `dst`; duplicate keys accumulate into arrays,
// exactly as within one file: a keybind in two files runs both actions.
// Scalar reads resolve to the last declaration (later file wins); array
// reads see the full accumulation; `src` is unmodified. Keys and values are
// shared (arena), so nothing is copied or freed.
fn mergeSectionsInto(allocator: std.mem.Allocator, dst: *Section, src: *const Section) !void {
    var iter = src.orderedIterator();
    while (iter.next()) |entry| {
        const src_key = entry.key;
        const src_val = entry.value;
        if (dst.pairs.getPtr(src_key)) |old_val| {
            // Duplicate key: accumulate into an array, flattening an
            // array-valued `incoming` so two files declaring an array produce
            // one flat array rather than an array-of-arrays.
            try accumulate(allocator, old_val, src_val);
            dst.markDuplicated(src_key);
        } else {
            try dst.pairs.put(src_key, src_val);
            dst.recordLine(allocator, src_key, src.lineOfKey(src_key) orelse 0);
        }
    }
}

// Merges `src` into `dst`; duplicate keys accumulate into arrays rather than
// overwriting, equivalent to writing all pairs in one file. Scalar reads
// resolve to the last element (later files win); array reads see every
// declaration. Parse-error state propagates so a merged document reports a
// failure (error.ConfigParseFailed) when ANY contributing file had errors.
pub fn mergeDocumentsInto(
    allocator: std.mem.Allocator,
    dst: *Document,
    src: *const Document,
) !void {
    try mergeSectionsInto(allocator, &dst.root, &src.root);
    dst.had_errors = dst.had_errors or src.had_errors;

    var iter = src.sections.iterator();
    while (iter.next()) |entry| {
        const name = entry.key_ptr.*;
        if (dst.sections.getPtr(name)) |dst_sec| {
            try mergeSectionsInto(allocator, dst_sec, entry.value_ptr);
        } else {
            // Share the section (and its name) as-is: both documents live in
            // the same arena, and nothing is freed until the load's reset.
            try dst.sections.put(name, entry.value_ptr.*);
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
    /// Last key parsed by parseKeyValuePair, named in line-level diagnostics
    // when a pair fails mid-parse.
    last_key: []const u8 = "",
    /// Owning Document's had_errors flag; set whenever a line is warn-and-
    // skipped so the load can fail on broken configs (C1).
    had_errors: *bool,
    /// File path named in every per-line diagnostic (C5); "" = in-memory input.
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

    // Per-line diagnostic prefixed with file:line:column (C5).
    fn warnLine(self: *const Parser, comptime fmt: []const u8, args: anytype) void {
        debug.warn("{s}:{d}:{d}: " ++ fmt, .{ self.sourceLabel(), self.line, self.column() } ++ args);
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

    // Skips inline whitespace (' ', '\t', '\r') only; a newline or comment
    // stops the scan.
    inline fn skipWhitespace(self: *Parser) void {
        while (self.pos < self.content.len) {
            switch (self.content[self.pos]) {
                ' ', '\t', '\r' => self.advanceChar(),
                else => break,
            }
        }
    }

    // Skips whitespace, newlines, and comments (the full inter-token run
    // consumed inside arrays and at line starts).
    inline fn skipWhitespaceAndNewlines(self: *Parser) void {
        while (self.pos < self.content.len) {
            switch (self.content[self.pos]) {
                ' ', '\t', '\r', '\n' => self.advanceChar(),
                '#' => self.skipToNewline(),
                else => break,
            }
        }
    }

    fn skipToNewline(self: *Parser) void {
        while (self.pos < self.content.len and self.content[self.pos] != '\n') self.pos += 1;
        if (self.pos < self.content.len) self.advanceChar();
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
            debug.warn(
                "Array nesting too deep (> {}) at line {}, treating as invalid",
                .{ max_array_depth, self.line },
            );
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
    fn parseBareTokenValue(_: *Parser, raw: []const u8) ParseError!Value {
        if (std.mem.eql(u8, raw, "true")) return .{ .boolean = true };
        if (std.mem.eql(u8, raw, "false")) return .{ .boolean = false };

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
        return .{ .array = items };
    }

    fn parseValue(self: *Parser, in_array: bool) ParseError!Value {
        self.skipWhitespace();
        const c = self.peek() orelse return ParseError.InvalidValue;

        if (c == '[') return .{ .array = try self.parseArray() };
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

    // Parses one `key = value` pair, or a bare `key` (treated as `key = true`).
    // Workspace rule entries like `Navigator` rely on the bare-key shorthand.
    fn parseKeyValuePair(self: *Parser) ParseError!struct { []const u8, Value } {
        self.last_key = "";
        const key = try self.parseKey();
        self.last_key = key;
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
            const kv = self.parseKeyValuePair() catch |err| {
                self.had_errors.* = true;
                if (self.last_key.len > 0)
                    self.warnLine("invalid key-value (key '{s}'): {}", .{ self.last_key, err })
                else
                    self.warnLine("invalid key-value: {}", .{err});
                self.skipToNewline();
                continue;
            };

            if (section.pairs.getPtr(kv[0])) |old| {
                // Duplicate key: accumulate both values into an array rather
                // than overwriting, so a keybind can bind multiple actions:
                //
                //   Mod+Shift+1 = "move_to_workspace_1"
                //   Mod+Shift+1 = "toggle_tag_1"
                //
                // parseKeybindings treats array values as sequences; scalar
                // reads of a repeated key resolve to the last declaration.
                try accumulate(self.allocator, old, kv[1]);
                section.markDuplicated(kv[0]);
            } else {
                try section.pairs.put(kv[0], kv[1]);
                section.recordLine(self.allocator, kv[0], self.line);
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
        self.had_errors.* = true;
        self.warnLine("unexpected character after pair (key '{s}')", .{self.last_key});
        self.skipToNewline();
        return false;
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
    doc.source_path = source_path;

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
                p.had_errors.* = true;
                p.warnLine("array-of-tables header '[[...]]' unsupported", .{});
                p.skipToNewline();
                continue;
            }
            const section_name = p.parseSection() catch |err| {
                p.had_errors.* = true;
                p.warnLine("invalid section: {}", .{err});
                p.skipToNewline();
                continue;
            };

            if (doc.sections.getPtr(section_name)) |existing| {
                // Duplicate section header: keep filling the existing section
                // so duplicate keys accumulate as if the blocks were one
                // section, consistent with the cross-file merge path.
                current_section = existing;
            } else {
                try doc.sections.put(section_name, Section.init(allocator));
                current_section = doc.sections.getPtr(section_name).?;
                current_section.name = section_name;
            }

            continue;
        }

        try p.parsePairs(current_section);
    }

    return doc;
}
