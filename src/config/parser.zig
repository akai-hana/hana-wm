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

pub const Value = union(enum) {
    integer: i64,
    boolean: bool,
    string: []const u8,
    array: std.ArrayList(Value),
    color: u32,
    scalable: types.ScalableValue,

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
        map.ensureTotalCapacity(section_keys_reserve) catch |err| debug.warnOnErr(err, label);
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
        self.consumed.put(key, {}) catch |err| debug.warnOnErr(err, "marking key consumed");
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
                debug.warn(
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
        const decls: usize = val.array.items.len;
        debug.warn(
            "Duplicate key '{s}' in section [{s}] accumulates into an array ({d} declarations); scalar reads use the last value",
            .{ key, if (self.name.len == 0) "root" else self.name, decls },
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
            types.ScalableValue => v.asScalar(types.ScalableValue),
            else => @compileError("Section.getAs: unsupported type " ++ @typeName(T)),
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
        sections.ensureTotalCapacity(document_sections_reserve) catch |err| debug.warnOnErr(err, "document section map reserve");
        var palette = std.StringHashMap(u32).init(allocator);
        palette.ensureTotalCapacity(palette_var_names.len) catch |err| debug.warnOnErr(err, "document palette reserve");
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
/// theme's `[bar.properties]` entries.
const palette_var_names = [_][]const u8{
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

/// Single decoder for the color-literal / hex-integer / hex-string forms a
/// color knob accepts. A bare all-digit spelling is only a color when it has
/// exactly 6 (`RRGGBB`) or 8 (`RRGGBBAA`) digits, read as hex; any other bare
/// number is rejected rather than coerced to a decimal color.
/// `null` means "not a color"; callers layer their own palette-reference
/// lookup and warning policy on top (schema's getColorFromValue).
pub fn colorFromValue(val: Value) ?u32 {
    if (val.asScalar(u32)) |c| return c;
    if (val.asScalar(i64)) |i| {
        if (i < 0) return null;
        // Bare all-digit color spellings are HEX: 6 digits = #RRGGBB, 8
        // digits = #RRGGBBAA (e.g. `112233` -> 0x112233). Any other bare
        // integral value in a color context is INVALID (no silent decimal
        // coerce); spell a value-color via 0xRRGGBB instead.
        var buf: [20]u8 = undefined;
        const digits = std.fmt.bufPrint(&buf, "{d}", .{@as(u64, @intCast(i))}) catch return null;
        if (digits.len == 6 or digits.len == 8) return std.fmt.parseInt(u32, digits, 16) catch null;
        return null;
    }
    if (val.asScalar([]const u8)) |s| {
        return parseColor(s) catch null;
    }
    return null;
}

/// Maximum number of `+`-separated color operands in a single color-mix
/// expression. Config is locally authored, so this is a defensive backstop
/// against a pathological chain, not a response to observed input.
const max_mix_operands = 8;

/// One resolved operand of a color-mix expression: a literal color plus the
/// optional percentage weight annotated on the `+` before it (null = weight
/// derived from the remaining budget, or an equal share when nothing carries
/// a weight).
const MixOperand = struct {
    color: u32,
    weight: ?u32 = null,
};

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
    const s = if (raw.len > 0 and raw[0] == '+') raw[1..] else raw;
    const p = parseWeightPrefix(s) orelse return false;
    return p.end == s.len;
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
fn splitWeightPrefix(part: []const u8) struct { weight: ?u32, operand: []const u8 } {
    const p = parseWeightPrefix(part) orelse return .{ .weight = null, .operand = part };
    return .{ .weight = p.weight, .operand = part[p.end..] };
}

/// Resolves a single mix operand (a hex string or a palette variable name)
/// against the collected palette.
fn resolveMixOperand(operand: []const u8, palette: *const std.StringHashMap(u32)) ?u32 {
    if (parseColor(operand)) |c| return c else |_| {}
    return palette.get(operand);
}

/// Resolves a single mix operand carried by a Value (a `.color`/integer
/// literal, or a string palette reference); null when it isn't a color.
fn resolveMixOperandValue(val: Value, palette: *const std.StringHashMap(u32)) ?u32 {
    if (colorFromValue(val)) |c| return c;
    if (val.asScalar([]const u8)) |s| return resolveMixOperand(s, palette);
    return null;
}

/// Cap-checked store of one resolved mix operand. Returns false when `count`
/// is already at the operand cap, so every mix branch shares one spill guard.
fn pushMixOperand(out: *[max_mix_operands]MixOperand, count: *usize, color: u32, weight: ?u32) bool {
    if (count.* == max_mix_operands) return false;
    out[count.*] = .{ .color = color, .weight = weight };
    count.* += 1;
    return true;
}

/// Parses `val` (the one-token spelling `a+(weight:20%)b`, the spaced array
/// spelling `[a, "+", (weight:20%), b]`, or a bare operand list `[a, b, c]`
/// with no operator or weights) as a color-mix expression, resolving every
/// operand against `palette`, storing them into `out`. A bare list mixes its
/// operands equally (the same no-weight rule as the unspaced spelling). null
/// when `val` is not a valid mix: no `+` in a scalar, malformed structure
/// (stray/trailing `+`, a weight before the head operand), more than
/// max_mix_operands operands, or an operand that isn't a color. Returns the
/// valid operand count.
fn extractMixOperands(
    val: Value,
    palette: *const std.StringHashMap(u32),
    out: *[max_mix_operands]MixOperand,
) ?usize {
    var count: usize = 0;

    // Match on the variant directly: asScalar would descend into an array's
    // last element, misreading the spaced spelling as the unspaced one.
    switch (val) {
        // Unspaced spelling: one bare token, "a+b+(weight:20%)c".
        .string => |s| {
            if (std.mem.indexOfScalar(u8, s, '+') == null) return null;
            var it = std.mem.splitScalar(u8, s, '+');
            while (it.next()) |part| {
                const tagged = splitWeightPrefix(part);
                const color = resolveMixOperand(tagged.operand, palette) orelse return null;
                if (!pushMixOperand(out, &count, color, tagged.weight)) return null;
            }
            return count;
        },
        .array => |arr| {
            if (arr.items.len < 2) return null;
            // Bare operand list: no `+` and no weight tokens, every element a
            // color operand. These mix equally (all weights null -> equal
            // share in mixColors), e.g. `[red, green]` = 50/50.
            var has_marker = false;
            for (arr.items) |elem| {
                if (elem == .string) {
                    const s = elem.string;
                    if (std.mem.eql(u8, s, "+") or isWeightToken(s)) {
                        has_marker = true;
                        break;
                    }
                }
            }
            if (!has_marker) {
                for (arr.items) |elem| {
                    const color = resolveMixOperandValue(elem, palette) orelse return null;
                    if (!pushMixOperand(out, &count, color, null)) return null;
                }
                return count;
            }
            // Spaced spelling: an array alternating operand and "+"([weight]) tokens.
            if (arr.items.len < 3) return null;
            var last_was_operand = false;
            var pending_weight: ?u32 = null;
            var expecting_operand_after_plus = false;
            for (arr.items) |elem| {
                if (elem == .string) {
                    const s = elem.string;
                    if (std.mem.eql(u8, s, "+")) {
                        if (!last_was_operand) return null;
                        last_was_operand = false;
                        expecting_operand_after_plus = true;
                        pending_weight = null;
                        continue;
                    }
                    if (isWeightToken(s)) {
                        if (std.mem.startsWith(u8, s, "+")) {
                            // Combined "+(weight:N%)": operator + weight in one token.
                            if (!last_was_operand) return null;
                            last_was_operand = false;
                            expecting_operand_after_plus = true;
                            pending_weight = weightFromToken(s);
                            continue;
                        }
                        // Bare "(weight:N%)": continues a pending '+'.
                        if (!expecting_operand_after_plus) return null;
                        pending_weight = weightFromToken(s);
                        continue;
                    }
                }
                if (last_was_operand) return null;
                const color = resolveMixOperandValue(elem, palette) orelse return null;
                if (!pushMixOperand(out, &count, color, if (expecting_operand_after_plus) pending_weight else null)) return null;
                last_was_operand = true;
                expecting_operand_after_plus = false;
                pending_weight = null;
            }
            if (!last_was_operand) return null;
            return count;
        },
        else => return null,
    }
}

/// Single weight scan over mix operands: whether any carries an explicit
/// weight and what those total. Shared by mixColors (head-remainder math)
/// and resolveColorExpr (bounds validation before mixing).
fn scanWeights(parts: []const MixOperand) struct { any_explicit: bool, sum: u64 } {
    var any_explicit = false;
    var explicit_sum: u64 = 0;
    for (parts) |p| if (p.weight) |w| {
        any_explicit = true;
        explicit_sum += w;
    };
    return .{ .any_explicit = any_explicit, .sum = explicit_sum };
}

/// Weighted channel average of `parts`: the head operand absorbs the weight
/// remainder (`100 - explicit sum`) when any weight is given, later operands
/// take their annotation; with no weights at all every operand shares
/// equally. Weights must be validated (each 0-100, explicit sum <= 100) by
/// resolveColorExpr before this is reached.
fn mixColors(parts: []const MixOperand) u32 {
    const n = parts.len;
    if (n == 0) return 0;
    if (n == 1) return parts[0].color;

    const stats = scanWeights(parts[1..]);
    var weights: [max_mix_operands]u64 = undefined;
    if (stats.any_explicit) {
        weights[0] = 100 - stats.sum;
        for (parts[1..], 0..) |p, i| weights[i + 1] = p.weight orelse 0;
    } else {
        for (parts, 0..) |_, i| weights[i] = 1;
    }

    var acc_r: u64 = 0;
    var acc_g: u64 = 0;
    var acc_b: u64 = 0;
    var wsum: u64 = 0;
    for (parts, 0..) |p, i| {
        const w = weights[i];
        acc_r += ((p.color >> 16) & 0xFF) * w;
        acc_g += ((p.color >> 8) & 0xFF) * w;
        acc_b += (p.color & 0xFF) * w;
        wsum += w;
    }
    if (wsum == 0) return 0;
    // Round-half-up keeps the midpoint of black/white at 128 where the bare
    // division would truncate 127.5 down to 127.
    const r = (acc_r + wsum / 2) / wsum;
    const g = (acc_g + wsum / 2) / wsum;
    const b = (acc_b + wsum / 2) / wsum;
    return (@as(u32, @intCast(r)) << 16) |
        (@as(u32, @intCast(g)) << 8) |
        @as(u32, @intCast(b));
}

/// Resolves a `+` color-mix expression into a single mixed color, null when
/// `val` is not a valid mix (callers layer their own warn-and-default
/// policy). Every operand resolves through the collected palette; weights
/// must each sit in 0-100 and their explicit sum must not exceed 100, so a
/// `+(weight:N%)` chain always produces a valid, fully-determined mix.
pub fn resolveColorExpr(val: Value, palette: *const std.StringHashMap(u32)) ?u32 {
    var operands: [max_mix_operands]MixOperand = undefined;
    const count = extractMixOperands(val, palette, &operands) orelse return null;
    const parts = operands[0..count];
    if (parts.len == 0) return null;
    if (parts[0].weight != null) return null;
    const stats = scanWeights(parts);
    if (stats.any_explicit and stats.sum > 100) return null;
    for (parts) |p| if (p.weight) |w| if (w > 100) return null;
    return mixColors(parts);
}

/// Resolves a palette-variable declaration to a color. Literals decode
/// directly; a `+`-bearing value is a color mix; a single name is an alias of
/// another collected palette variable. An accumulated `.array` first tries
/// the whole-value mix (the spaced spelling accumulates element-wise), then
/// falls through to the last-declaration scalar (later declaration wins) for
/// plain duplicates. Used by collectPalette's fixpoint.
fn resolvePaletteDecl(val: Value, palette: *const std.StringHashMap(u32)) ?u32 {
    if (colorFromValue(val)) |c| return c;
    if (val == .array) {
        if (resolveColorExpr(val, palette)) |c| return c;
        if (val.asScalar([]const u8)) |s| return palette.get(s);
        return null;
    }
    if (val.asScalar([]const u8)) |s| {
        if (std.mem.indexOfScalar(u8, s, '+') != null) return resolveColorExpr(val, palette);
        return palette.get(s);
    }
    return null;
}

/// Scans every section (and the root) for palette-variable declarations,
/// resolving each to its color value and storing the last declaration into
/// `doc.palette` ("later declaration wins" like every other knob). One pass
/// resolves literal declarations; a bounded fixpoint then resolves aliases
/// and `+` mixes that reference other palette variables, so
/// `primary_color = secondary_color + text_color` works. Also marks the keys
/// consumed so they never appear as unrecognized. A variable left unresolved
/// after the fixpoint is cyclic or references an unknown operand: warned and
/// skipped (referencing knobs fall back to their own defaults). Call once per
/// merged Document, before knobs are applied.
pub fn collectPalette(self: *Document) void {
    // Last declaration per palette variable, in reserved-name order.
    var last: [palette_var_names.len]?Value = undefined;
    for (palette_var_names, 0..) |name, i| {
        var best: ?Value = null;
        var iter = self.sections.iterator();
        while (iter.next()) |entry| {
            if (entry.value_ptr.get(name)) |val| best = val;
        }
        if (self.root.get(name)) |val| best = val;
        // Keep the full accumulated declaration: an array-spelling `+` mix
        // (`primary_color + secondary_color`) must survive to the resolver,
        // which reads it as a unit (resolvePaletteDecl). Its own resolution
        // keeps later-declaration-wins for plain scalar duplicates.
        last[i] = best;
    }

    // Fixpoint: each round resolves whatever became resolvable this pass; a
    // progress-free round means everything left is cyclic or unresolvable.
    var progress = true;
    var rounds: usize = 0;
    while (progress and rounds <= palette_var_names.len) {
        progress = false;
        rounds += 1;
        for (last, 0..) |may, i| {
            if (may == null) continue;
            const name = palette_var_names[i];
            if (resolvePaletteDecl(may.?, &self.palette)) |c| {
                self.palette.put(name, c) catch {};
                last[i] = null;
                progress = true;
            }
        }
    }

    for (last, 0..) |may, i| {
        if (may != null) {
            debug.warn(
                "Palette variable '{s}' is a cyclic or unresolvable color expression; ignoring (referencing colors fall back to defaults)",
                .{palette_var_names[i]},
            );
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
            const value = try self.parseValue(false);
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
        self.skipBadLine("unexpected character after pair (key '{s}')", .{self.last_key});
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
                p.skipBadLine("invalid section: {}", .{err});
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
