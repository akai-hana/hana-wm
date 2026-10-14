//! The config document model: `Value`, `Section`, `Document`, and the
//! duplicate-key policy shared by every parse path.
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
const log = @import("log");
const types = @import("types");

/// Error set shared by the dialect reader, the duplicate-key policy, and
/// the cross-file merge. Error VALUES (`error.InvalidValue` etc.) are
/// global in Zig and need no import at their use sites; only code that
/// names the set as a type (the reader's fns) imports this module.
pub const ParseError = error{
    InvalidSyntax,
    InvalidSection,
    InvalidValue,
    InvalidColor,
    OutOfMemory,
};

/// A parsed value.
///
/// Deliberately carries NO source span: the section already records
/// the source line of every key it inserted (`Entry.line`),
/// and that is the line a user needs -- a knob error is reported against a KEY
/// PATH inside a section, and every diagnostic in this file reaches the section
/// that owns the key. Putting a line/column on each of the six union variants
/// instead would mean 30 construction sites carrying it, plus every method that
/// synthesizes or returns a `Value` (lastScalar/asScalar/accumulate), all to
/// report a number already available one level up.
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
    /// One entry per declared key, in document order. This array IS the
    /// section: one place per key, so there is no second copy to keep in
    /// step. A section holds tens of keys and is read only during a config
    /// load, so the linear scan below costs a comparison or two, and
    /// iteration is document order for free.
    /// Nothing to allocate up front: the array grows as keys are inserted,
    /// and a section is never read before parsing has finished.
    entries: std.ArrayListUnmanaged(Entry) = .empty,
    // The section header this Section belongs to ("" for the root pairs that
    // have no header). Filled by parse() when a section is created; merged
    // sections carry their source name through the shared-value merge.
    name: []const u8 = "",

    /// What the parser knows about one declared key.
    pub const Entry = struct {
        key: []const u8,
        /// The live value: duplicate declarations accumulate INTO this field
        /// (see insertOrAccumulate), so it is the one place a key's value
        /// lives -- there is no second copy in a map to keep in step.
        value: Value,
        /// Source line of the FIRST declaration; feeds the unrecognized-key
        /// and duplicate-key diagnostics (best-effort).
        line: usize = 0,
        /// Read by get()/getAs()/markConsumed, or visited by
        /// orderedIterator(). A key no reader examined is reported by
        /// warnUnconsumed (almost always a typo in the key name).
        consumed: bool = false,
        /// Declared more than once across the duplicate / cross-file merge
        /// paths. Distinct from a single literal array value like
        /// `layouts = [...]`: only genuine duplicate declarations accumulate,
        /// and only those warn when read as a scalar.
        duplicated: bool = false,
        /// Already warned about for a scalar-duplicate read, so each
        /// section+key pair warns at most once.
        scalar_dup_warned: bool = false,
    };

    /// Index of `key`'s entry, or null. The one lookup every method below is
    /// built on.
    fn indexOf(self: *const Section, key: []const u8) ?usize {
        for (self.entries.items, 0..) |e, i| {
            if (std.mem.eql(u8, e.key, key)) return i;
        }
        return null;
    }

    // Iterates pairs in document (insertion) order; deterministic.
    // Values are the live (possibly accumulated) values.
    // Every key the walk visits is marked consumed, so a section read this way
    // needs no separate markConsumed prologue: the walk itself is the read.
    pub fn orderedIterator(self: *Section) OrderedIterator {
        return .{ .section = self, .idx = 0 };
    }

    // Records `key` as recognised so it won't be reported by warnUnconsumed.
    // Called by `get()`/`getAs()` (typed readers) and by OrderedIterator.next()
    // (the document-order readers); nothing else needs to call it.
    pub fn markConsumed(self: *Section, key: []const u8) void {
        const i = self.indexOf(key) orelse return;
        self.entries.items[i].consumed = true;
    }

    // Warns about every key in the section that was never examined via
    // get()/getAs()/markConsumed(); typically a typo in the key name, since
    // the parser otherwise accepts it silently. Names the source line so a
    // large config's typos are findable. Iterates `entries`, which IS
    // document order, so warnings are deterministic and O(n).
    pub fn warnUnconsumed(self: *const Section, section_name: []const u8) void {
        for (self.entries.items) |e| {
            if (e.consumed) continue;
            log.warn(
                "Unrecognized key '{s}' in section [{s}] (line {d}); ignoring",
                .{ e.key, section_name, e.line },
            );
        }
    }

    pub fn get(self: *Section, key: []const u8) ?Value {
        const i = self.indexOf(key) orelse return null;
        self.entries.items[i].consumed = true;
        self.warnScalarDuplicate(i);
        return self.entries.items[i].value;
    }

    // A key that accumulated duplicate declarations reads as an array,
    // but a scalar request resolves to the last declaration. Warn once (per
    // section+key) so silent last-wins isn't a surprise -- except in the
    // sections where accumulated arrays ARE the point: [binds], rule tables
    // ([workspace.rules]/[rules]), the root `include` key, and the [tiling]
    // `layouts` list.
    /// Takes the entry's index rather than its key: the caller has just
    /// located it, and a second scan for the same key would be pure waste.
    fn warnScalarDuplicate(self: *Section, i: usize) void {
        const e = &self.entries.items[i];
        if (e.value != .array) return;
        if (!e.duplicated or e.scalar_dup_warned) return;
        const exempt = std.mem.eql(u8, self.name, types.section_binds) or
            std.mem.eql(u8, self.name, types.section_workspace_rules) or
            std.mem.eql(u8, self.name, types.section_rules) or
            (self.name.len == 0 and std.mem.eql(u8, e.key, "include")) or
            (std.mem.eql(u8, self.name, types.section_tiling) and std.mem.eql(u8, e.key, "layouts"));
        if (exempt) return;
        e.scalar_dup_warned = true;
        // Root pairs (no section header) warn under a "[root]" label so one
        // format serves both cases.
        log.warn(
            "Duplicate key '{s}' in section [{s}] accumulates into an array ({d} declarations, first at line {d}); scalar reads use the last value",
            .{ e.key, if (self.name.len == 0) "root" else self.name, e.value.array.list.items.len, e.line },
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
            if (self.indexOf(key)) |i| {
                const e = self.entries.items[i];
                log.warn(
                    "Key '{s}' in section [{s}] expects {s}, got {s} (line {d}); ignoring (keeping default)",
                    .{ key, self.name, typeLabel(T), valueTypeLabel(e.value), e.line },
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
pub fn expectedForm(err: ParseError) []const u8 {
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
        f32 => "a number",
        bool => "a boolean",
        []const u8 => "a string",
        []const Value => "an array",
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
// read from the live entry, so accumulated duplicates are seen in full.
// Marks each key consumed as it hands it over (see orderedIterator).
pub const OrderedIterator = struct {
    section: *Section,
    idx: usize,

    pub fn next(self: *OrderedIterator) ?struct { key: []const u8, value: Value } {
        if (self.idx >= self.section.entries.items.len) return null;
        const e = &self.section.entries.items[self.idx];
        self.idx += 1;
        e.consumed = true;
        return .{ .key = e.key, .value = e.value };
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
        return .{ .sections = sections, .root = .{}, .palette = palette };
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

/// Pre-reserve the document's section map so a typical document (theme + 7
/// core sections) builds without rehashing.
const document_sections_reserve: usize = 8;

// Duplicate-key accumulation policy: shared by the dialect reader's
// pair parser (within one file) and the cross-file merge below
// (`mergeDocumentsInto`), so both paths apply the identical later-wins semantics.

// Wraps `old_val` in a fresh accumulated array if it isn't one already, so
// callers can append into it. This array represents duplicate-key
// accumulation (later declaration wins), unlike parse-time literal arrays.
pub fn ensureArray(allocator: std.mem.Allocator, old_val: *Value) !void {
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
// full accumulation so keybindings, `include`, `layouts`, etc. chain. The result
// is always an ACCUMULATED array (genuinely duplicated keys), marking it so
// literal arrays (bracket lists / bare multi-token spellings) stay distinct:
// scalar later-wins applies to accumulated arrays only.
pub fn accumulate(
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
pub fn insertOrAccumulate(
    allocator: std.mem.Allocator,
    section: *Section,
    key: []const u8,
    value: Value,
    line: usize,
) !void {
    if (section.indexOf(key)) |i| {
        // The entry's value is where a duplicate accumulates, so the array a
        // scalar read later resolves to is built in place -- there is no
        // second map to update alongside it.
        const e = &section.entries.items[i];
        try accumulate(allocator, &e.value, value);
        e.duplicated = true;
    } else {
        try section.entries.append(allocator, .{ .key = key, .value = value, .line = line });
    }
}

// Cross-file document merging: an overlay document folds into a base with
// the same duplicate-key semantics as within one file, through
// `insertOrAccumulate`. Keys and values are SHARED (one arena per load),
// never copied -- see the ownership model above.

// Merges `src`'s pairs into `dst`; duplicate keys accumulate into arrays,
// exactly as within one file: a keybinding in two files runs both actions.
// Scalar reads resolve to the last declaration (later file wins); array
// reads see the full accumulation; `src` is unmodified. Keys and values are
// shared (arena), so nothing is copied or freed.
fn mergeSectionsInto(allocator: std.mem.Allocator, dst: *Section, src: *const Section) !void {
    // Raw entry iteration on purpose, NOT orderedIterator(): walking with the
    // iterator marks keys consumed on `src`, and a section dst does not have
    // yet is copied over WITH its entries and their flags -- which would
    // silence warnUnconsumed for every key an include file contributes.
    for (src.entries.items) |e| {
        try insertOrAccumulate(allocator, dst, e.key, e.value, e.line);
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
