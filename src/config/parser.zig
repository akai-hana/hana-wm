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
//! The error set is `ParseError`, declared at the bottom of this file.

const std = @import("std");
const log = @import("log");
const types = @import("types");

/// A parsed value.
///
/// Deliberately carries NO source span (16.1/16.3): the section already records
/// the source line of every key it inserted (`lines_in_order` / `lineOfKey`),
/// and that is the line a user needs -- a knob error is reported against a KEY
/// PATH inside a section, and every diagnostic in this file reaches the section
/// that owns the key. Putting a line/column on each of the six union variants
/// instead would mean 30 construction sites carrying it, plus every method that
/// synthesizes or returns a `Value` (lastScalar/asScalar/accumulate), all to
/// report a number already available one level up. See the 16.1 note in the
/// ledger for the full argument.
pub const Value = union(enum) {
    integer: i64,
    boolean: bool,
    string: []const u8,
    // A list of values. `accumulated` is true only for arrays formed by
    // duplicate-key accumulation (`accumulate`): scalar reads then implement
    // "later declaration wins" (the latest value is the LAST element) while
    // array consumers see the full accumulation. A *literal* array (a `[...]`
    // bracket list or a bare multi-token spelling, both created once at parse
    // time) is `accumulated == false`: it is never a scalar -- `resolveColorExpr`
    // owns it as a color-mix (bare lists mix equally) and array consumers read
    // it as-is. Keeps "genuinely duplicated keys" distinct from "one author
    // wrote a list".
    array: struct { list: std.ArrayList(Value), accumulated: bool = false },
    color: u32,
    scalable: types.ScalableValue,

    // Scalar reads resolve through the last element ONLY for accumulated
    // duplicate arrays (later declaration wins). A literal array is not a
    // scalar, so it yields null here and callers fall back to their own
    // array handling (resolveColorExpr for colors). Not `inline` because
    // recursion into an accumulated duplicate array is rejected.
    fn lastScalar(self: Value) ?Value {
        return switch (self) {
            .array => |arr| if (arr.accumulated and arr.list.items.len > 0)
                arr.list.items[arr.list.items.len - 1].lastScalar()
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
            // A bare number in TOML arrives as `integer` (`dpi = 144`) or,
            // when written with a fraction, as `scalable` (`dpi = 144.0`).
            // Both mean the same knob, so both widen.
            f32 => switch (scalar) {
                .integer => |i| @floatFromInt(i),
                .scalable => |sc| sc.value,
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
            types.ScalableValue => switch (scalar) {
                .scalable => |s| s,
                .integer => |i| types.ScalableValue.absolute(@floatFromInt(i)),
                else => null,
            },
            else => @compileError("asScalar: unsupported type " ++ @typeName(T)),
        };
    }
    pub inline fn asArray(self: Value) ?[]const Value {
        return switch (self) {
            .array => |arr| arr.list.items,
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
    // unrecognized-key / duplicate-key diagnostics. Best-effort.
    lines_in_order: std.ArrayListUnmanaged(usize) = .empty,
    // Keys that were declared more than once in this section (across the
    // duplicate / cross-file merge paths). Distinct from a single literal
    // array value like `layouts = [...]`: only genuine duplicate declarations
    // accumulate, and only those warn when read as a scalar.
    duplicated_keys: std.StringHashMap(void),
    // Keys already warned about for scalar-duplicate reads, so each
    // section+key pair warns at most once.
    scalar_dup_warned: std.StringHashMap(void),
    // The section header this Section belongs to ("" for the root pairs that
    // have no header). Filled by parse() when a section is created; merged
    // sections carry their source name through the shared-value merge.
    name: []const u8 = "",

    /// Reserves 4 slots in a string map, warning with `label` on OOM
    /// (best-effort: losing the reserve just means an extra rehash).
    fn reserve(allocator: std.mem.Allocator, comptime V: type, comptime label: []const u8) std.StringHashMap(V) {
        var map = std.StringHashMap(V).init(allocator);
        map.ensureTotalCapacity(section_keys_reserve) catch |err| log.warnOnErr(err, label);
        return map;
    }

    pub fn init(allocator: std.mem.Allocator) Section {
        return .{
            .pairs = reserve(allocator, Value, "section pair map reserve"),
            .consumed = reserve(allocator, void, "section consumed-set reserve"),
            .duplicated_keys = reserve(allocator, void, "section duplicate tracking reserve"),
            .scalar_dup_warned = reserve(allocator, void, "section duplicate-diagnostic reserve"),
        };
    }

    // Records `key` as the newest document-order key together with the source
    // line it was declared on. Best-effort on both halves: an OOM just loses
    // deterministic ordering for this section, never data.
    fn recordLine(self: *Section, allocator: std.mem.Allocator, key: []const u8, line: usize) void {
        self.keys_in_order.append(allocator, key) catch {};
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
    // these are the only keys that can trigger the scalar-duplicate warn.
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
        self.consumed.put(key, {}) catch |err| log.warnOnErr(err, "marking key consumed");
    }

    // Warns about every key in the section that was never examined via
    // get()/getAs()/markConsumed(); typically a typo in the key name, since
    // the parser otherwise accepts it silently. Names the source line so a
    // large config's typos are findable. Iterates in document order
    // (keys_in_order, filled together with lines_in_order by
    // insertOrAccumulate) so warnings are deterministic and O(n).
    pub fn warnUnconsumed(self: *const Section, section_name: []const u8) void {
        for (self.keys_in_order.items, 0..) |key, i| {
            if (!self.consumed.contains(key)) {
                log.warn(
                    "Unrecognized key '{s}' in section [{s}] (line {d}); ignoring",
                    .{ key, section_name, if (i < self.lines_in_order.items.len) self.lines_in_order.items[i] else 0 },
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

    // A key that accumulated duplicate declarations reads as an array,
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
            std.mem.eql(u8, self.name, types.section_workspace_rules) or
            std.mem.eql(u8, self.name, types.section_rules) or
            (self.name.len == 0 and std.mem.eql(u8, key, "include")) or
            (std.mem.eql(u8, self.name, types.section_tiling) and std.mem.eql(u8, key, "layouts"));
        if (exempt) return;
        self.scalar_dup_warned.put(key, {}) catch {};
        // Root pairs (no section header) warn under a "[root]" label so one
        // format serves both cases.
        const decls: usize = val.array.list.items.len;
        log.warn(
            "Duplicate key '{s}' in section [{s}] accumulates into an array ({d} declarations, first at line {d}); scalar reads use the last value",
            .{ key, if (self.name.len == 0) "root" else self.name, decls, self.lineOfKey(key) orelse 0 },
        );
    }

    // Generic typed getter: dispatches to `Value.asScalar` (which owns the
    // last-declaration descent), plus the array view for sequence reads.
    pub fn getAs(self: *Section, comptime T: type, key: []const u8) ?T {
        const v = self.get(key) orelse return null;
        return switch (T) {
            []const Value => v.asArray(),
            else => v.asScalar(T),
        };
    }

    // `getAs` that also diagnoses a present-but-wrong-typed value, so a
    // knob silently keeping its default is never a surprise. Fires once per
    // read (schema.applyAll reads each knob's key exactly once). The
    // accumulated-duplicate case is already covered by get's
    // warnScalarDuplicate; a single literal array at a scalar knob warns
    // here as a wrong type.
    pub fn getAsOrWarn(self: *Section, comptime T: type, key: []const u8) ?T {
        const out = self.getAs(T, key);
        if (out == null) {
            if (self.pairs.get(key)) |v| {
                log.warn(
                    "Key '{s}' in section [{s}] expects {s}, got {s} (line {d}); ignoring (keeping default)",
                    .{ key, self.name, typeLabel(T), valueTypeLabel(v), self.lineOfKey(key) orelse 0 },
                );
            }
        }
        return out;
    }
};

/// What the reader was looking for when it gave up, in the reader's own terms.
///
/// The error NAMES alone ("InvalidValue") tell a user which bucket to blame and
/// nothing about what to write instead, and this dialect is hand-written, so
/// the accepted forms are a deliberate list (see the file header) that a user
/// cannot infer from the error. Each variant states the form it was parsing.
/// OutOfMemory is absent on purpose: it is not a syntax complaint, it is a
/// retryable allocator failure, and no amount of "expected" text helps.
fn expectedForm(err: ParseError) []const u8 {
    return switch (err) {
        error.InvalidSyntax => "a bare key (letters, digits, '_', '-', '+', '/', '.'), optionally quoted",
        error.InvalidSection => "a section header of the form [name] (one level, no quotes needed)",
        error.InvalidValue => "a value: a number, true/false, a quoted string, a [list], " ++
            "a color (#RRGGBB / 0xRRGGBB), or a size with a unit (10, 10%, 10px)",
        error.InvalidColor => "a 24-bit color: #RRGGBB, 0xRRGGBB, or a 6/8-digit hex number",
        error.OutOfMemory => "enough memory to continue parsing",
    };
}

fn typeLabel(comptime T: type) []const u8 {
    return switch (T) {
        i64 => "a number",
        bool => "a boolean",
        []const u8 => "a string",
        types.ScalableValue => "a size or percentage",
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
    /// (the existing per-line/file warns surface anyway).
    had_errors: bool = false,

    pub fn init(allocator: std.mem.Allocator) Document {
        var sections = std.StringHashMap(Section).init(allocator);
        sections.ensureTotalCapacity(document_sections_reserve) catch |err| log.warnOnErr(err, "document section map reserve");
        var palette = std.StringHashMap(u32).init(allocator);
        palette.ensureTotalCapacity(palette_var_names.len) catch |err| log.warnOnErr(err, "document palette reserve");
        return .{ .sections = sections, .root = Section.init(allocator), .palette = palette };
    }

    pub fn getSection(self: *Document, name: []const u8) ?*Section {
        return self.sections.getPtr(name);
    }
};

/// The named color-palette slots a theme declares once and any color-valued
/// knob may reference by full name (`border_focused = primary_color`,
/// `title = secondary_color`, ...). `primary_color` doubles as the bar's
/// default accent knob (the former `accent_color`); the other three are pure
/// palette declarations currently consumed by the fallback chain and the
/// theme's `[bar.properties]` entries. `pub` because the palette
/// collection lives in color.zig (the color sub-language's home).
pub const palette_var_names = [_][]const u8{
    types.palette_primary_color,
    types.palette_secondary_color,
    types.palette_alternative_color,
    types.palette_text_color,
};

/// Pre-reserve capacities for the two string-keyed maps so a typical
/// document builds without rehashing: 8 sections in the document map
/// (theme + 7 core sections), 4 keys per section.
const document_sections_reserve: usize = 8;
const section_keys_reserve: usize = 4;

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

// Document merging

// Wraps `old_val` in a fresh accumulated array if it isn't one already, so
// callers can append into it. This array represents duplicate-key
// accumulation (later declaration wins), unlike parse-time literal arrays.
fn ensureArray(allocator: std.mem.Allocator, old_val: *Value) !void {
    if (old_val.* == .array) {
        old_val.array.accumulated = true;
        return;
    }
    var arr = try std.ArrayList(Value).initCapacity(allocator, 1);
    arr.appendAssumeCapacity(old_val.*);
    old_val.* = .{ .array = .{ .list = arr, .accumulated = true } };
}

// Accumulates `incoming` into `old_val`. An array-valued `incoming` is
// flattened. Values are SHARED, never copied: all documents in a load share
// one arena, so pointers stay valid until the load's arena reset. Scalar
// getters resolve to the LAST element (later files win); asArray sees the
// full accumulation so keybinds, `include`, `layouts`, etc. chain. The result
// is always an ACCUMULATED array (genuinely duplicated keys), marking it so
// literal arrays (bracket lists / bare multi-token spellings) stay distinct:
// scalar later-wins applies to accumulated arrays only.
fn accumulate(
    allocator: std.mem.Allocator,
    old_val: *Value,
    incoming: Value,
) !void {
    try ensureArray(allocator, old_val);
    if (incoming == .array) {
        try old_val.array.list.appendSlice(allocator, incoming.array.list.items);
    } else {
        try old_val.array.list.append(allocator, incoming);
    }
}

// Inserts `value` under `key`, or -- for a duplicate key -- accumulates both
// values into an array rather than overwriting. Shared by the within-file
// pair parser (parsePairs) and the cross-file section merge
// (mergeSectionsInto), so both paths apply the identical duplicate policy:
// scalar reads later resolve to the LAST declaration (later file wins), array
// reads see the full accumulation, and the key is recorded as duplicated for
// the scalar-read warning. `line` is the source line involved when the
// key is FIRST inserted; it only feeds the best-effort diagnostic, and
// duplicate declarations keep the original line.
fn insertOrAccumulate(
    allocator: std.mem.Allocator,
    section: *Section,
    key: []const u8,
    value: Value,
    line: ?usize,
) !void {
    if (section.pairs.getPtr(key)) |old| {
        try accumulate(allocator, old, value);
        section.markDuplicated(key);
    } else {
        try section.pairs.put(key, value);
        section.recordLine(allocator, key, line orelse 0);
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
        try insertOrAccumulate(allocator, dst, entry.key, entry.value, src.lineOfKey(entry.key));
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
    /// Last key parsed by parseKeyValuePair, named in line-level diagnostics
    // when a pair fails mid-parse.
    last_key: []const u8 = "",
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

    // Parses one `key = value` pair, or a bare `key` (treated as `key = true`).
    // Workspace rule entries like `Navigator` rely on the bare-key shorthand.
    fn parseKeyValuePair(self: *Parser) ParseError!struct { []const u8, Value } {
        self.last_key = "";
        const key = try self.parseKey();
        self.last_key = key;
        self.skipWhitespace();

        if (self.peek() == '=') {
            _ = self.consume();
            const value = try self.parseValue(false);
            return .{ key, value };
        }
        return .{ key, Value{ .boolean = true } };
    }

    // Parses `key = value` pairs (and bare `key` flags) until a blank line,
    // comment, `;` terminator, or end of content. Duplicate keys accumulate
    // into arrays so a repeated keybind or include runs all declarations.
    // Parses one `key = value` pair (or bare `key` flag), inserts it, and
    // consumes the trailing syntax. The document loop in `parse` re-invokes
    // this for each further pair on the following line; a malformed pair is
    // warned-and-skipped to the next line so recovery returns to that loop.
    fn parsePairs(self: *Parser, section: *Section) ParseError!void {
        const kv = self.parseKeyValuePair() catch |err| {
            self.had_errors.* = true;
            if (self.last_key.len > 0)
                self.warnLine("invalid value for key '{s}': {s} (got {s})", .{ self.last_key, expectedForm(err), @errorName(err) })
            else
                self.warnLine("invalid value: {s} (got {s})", .{ expectedForm(err), @errorName(err) });
            self.skipToNewline();
            return;
        };

        // Duplicate key: accumulate both values into an array rather
        // than overwriting, so a keybind can bind multiple actions:
        //
        //   Mod+Shift+1 = "move_to_workspace_1"
        //   Mod+Shift+1 = "toggle_tag_1"
        //
        // parseKeybindings treats array values as sequences; scalar
        // reads of a repeated key resolve to the last declaration.
        try insertOrAccumulate(self.allocator, section, kv[0], kv[1], self.line);

        self.skipWhitespace();
        self.advanceAfterPair();
    }

    // Advances past the end of one pair: an optional ';' terminator, trailing
    // whitespace, and any line-end comment or newline.
    fn advanceAfterPair(self: *Parser) void {
        const next = self.peek();
        if (next == ';') _ = self.consume();
        self.skipWhitespace();
        const trail = self.peek();
        if (trail != '\n' and trail != '#' and trail != null) {
            self.skipBadLine("unexpected character after pair (key '{s}')", .{self.last_key});
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
                p.skipBadLine("invalid section header: {s} (got {s})", .{ expectedForm(err), @errorName(err) });
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
