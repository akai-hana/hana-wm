//! The config color sub-language: color-literal decoding, palette
//! references, and `+` color-mix expressions with `(weight:N%)`
//! annotations -- plus the warn-and-default policy layered on top
//! (`getColorFromValue`) and the document-global palette collection
//! (`collectPalette`).
//!
//! The value-level color grammar, extracted from parser.zig: it is a
//! self-contained sub-language. The TOKEN-level
//! spellings stay in parser -- `parseColor` (a hex string to a
//! u32) and the weight markers (`parseWeightPrefix`/`isWeightToken`/
//! `weightFromToken`/`splitWeightPrefix`), which the bare-token
//! interpreter classifies with. This file sits between parser and
//! schema: it reads parser's `Value` and token grammar, and schema
//! (and bar_properties) read this file's decoders. The seam is
//! one-directional -- parser never imports color -- so it cannot
//! cycle, which is how bar_properties sits beside schema without
//! a schema<->bar_properties loop.

const std = @import("std");
const log = @import("log");
const parser = @import("parser");

const Value = parser.Value;

/// Single decoder for the color-literal / hex-integer / hex-string forms a
/// color knob accepts. A bare all-digit spelling is only a color when it has
/// exactly 6 (`RRGGBB`) or 8 (`RRGGBBAA`) digits, read as hex; any other bare
/// number is rejected rather than coerced to a decimal color.
/// `null` means "not a color"; callers layer their own palette-reference
/// lookup and warning policy on top (getColorFromValue below).
pub fn colorFromValue(val: Value) ?u32 {
    if (val.asScalar(u32)) |c| return c;
    if (val.asScalar(i64)) |i| {
        if (i < 0) return null;
        // Bare all-digit color spellings are HEX: 6 digits = #RRGGBB. Any
        // other bare integral value in a color context is INVALID (no silent
        // decimal coerce); spell a value-color via 0xRRGGBB instead. An
        // 8-digit spelling is deliberately rejected, matching parser.parseColor
        // (which caps at 24 bits): parsing it raw returned 0xRRGGBBAA, whose
        // alpha byte sits in the low byte and red shifted into the top byte --
        // i.e. an invalid packed Color flowing into XCB pixel fields.
        var buf: [20]u8 = undefined;
        const digits = std.fmt.bufPrint(&buf, "{d}", .{@as(u64, @intCast(i))}) catch return null;
        if (digits.len == 6) return std.fmt.parseInt(u32, digits, 16) catch null;
        return null;
    }
    if (val.asScalar([]const u8)) |s| {
        return parser.parseColor(s) catch null;
    }
    return null;
}

/// Maximum number of `+`-separated color operands in a single color-mix
/// expression. Config is locally authored, so this is a defensive backstop
/// against a pathological chain, not a response to observed input.
const max_mix_operands = 8;
/// The percentage budget a color-mix's explicit weights share; the head
/// (annotation-free) operand absorbs the remainder.
const mix_percent_total: u32 = 100;

/// One resolved operand of a color-mix expression: a literal color plus the
/// optional percentage weight annotated on the `+` before it (null = weight
/// derived from the remaining budget, or an equal share when nothing carries
/// a weight).
const MixOperand = struct {
    color: u32,
    weight: ?u32 = null,
};

/// Resolves a single mix operand (a hex string or a palette variable name)
/// against the collected palette.
fn resolveMixOperand(operand: []const u8, palette: *const std.StringHashMap(u32)) ?u32 {
    if (parser.parseColor(operand)) |c| return c else |_| {}
    return palette.get(operand);
}

/// Resolves a single mix operand carried by a Value (a `.color`/integer
/// literal, or a string palette reference); null when it isn't a color.
fn resolveMixOperandValue(val: Value, palette: *const std.StringHashMap(u32)) ?u32 {
    if (colorFromValue(val)) |c| return c;
    if (val.asScalar([]const u8)) |s| return palette.get(s);
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
                const tagged = parser.splitWeightPrefix(part);
                const color = resolveMixOperand(tagged.operand, palette) orelse return null;
                if (!pushMixOperand(out, &count, color, tagged.weight)) return null;
            }
            return count;
        },
        .array => |arr| {
            // Only a LITERAL array (one declaration) is a mix expression. An
            // accumulated duplicate array is "later declaration wins": the
            // caller falls through to the last-scalar descent instead of
            // averaging the duplicates.
            if (arr.accumulated) return null;
            const items = arr.list.items;
            if (items.len < 2) return null;
            // Bare operand list: no `+` and no weight tokens, every element a
            // color operand. These mix equally (all weights null -> equal
            // share in mixColors), e.g. `[red, green]` = 50/50.
            var has_marker = false;
            for (items) |elem| {
                if (elem == .string) {
                    const s = elem.string;
                    if (std.mem.eql(u8, s, "+") or parser.isWeightToken(s)) {
                        has_marker = true;
                        break;
                    }
                }
            }
            if (!has_marker) {
                for (items) |elem| {
                    const color = resolveMixOperandValue(elem, palette) orelse return null;
                    if (!pushMixOperand(out, &count, color, null)) return null;
                }
                return count;
            }
            // Spaced spelling: an array alternating operand and "+"([weight]) tokens.
            if (items.len < 3) return null;
            var last_was_operand = false;
            var pending_weight: ?u32 = null;
            var expecting_operand_after_plus = false;
            for (items) |elem| {
                if (elem == .string) {
                    const s = elem.string;
                    if (std.mem.eql(u8, s, "+")) {
                        if (!last_was_operand) return null;
                        last_was_operand = false;
                        expecting_operand_after_plus = true;
                        pending_weight = null;
                        continue;
                    }
                    if (parser.isWeightToken(s)) {
                        if (std.mem.startsWith(u8, s, "+")) {
                            // Combined "+(weight:N%)": operator + weight in one token.
                            if (!last_was_operand) return null;
                            last_was_operand = false;
                            expecting_operand_after_plus = true;
                            pending_weight = parser.weightFromToken(s);
                            continue;
                        }
                        // Bare "(weight:N%)": continues a pending '+'.
                        if (!expecting_operand_after_plus) return null;
                        pending_weight = parser.weightFromToken(s);
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
    // Callers guarantee at least one operand (extractMixOperands returns null
    // on an empty chain); a single element is that element's color.
    const n = parts.len;
    if (n == 1) return parts[0].color;

    const stats = scanWeights(parts[1..]);
    var weights: [max_mix_operands]u64 = undefined;
    if (stats.any_explicit) {
        weights[0] = mix_percent_total - stats.sum;
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
    // A single weight > mix_percent_total forces the sum over and is caught
    // here, so no per-weight bound is needed.
    if (stats.any_explicit and stats.sum > mix_percent_total) return null;
    return mixColors(parts);
}

/// Resolves a palette-variable declaration to a color. Literals decode
/// directly; a `+`-bearing value is a color mix; a single name is an alias of
/// another collected palette variable. A LITERAL array is owned by
/// resolveColorExpr (bare lists and spaced spellings mix); an accumulated
/// `.array` (duplicate declarations) is NOT a mix -- it falls through to the
/// last-declaration scalar so "later declaration wins" like every other knob.
/// Used by collectPalette's fixpoint.
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
/// `doc.palette` ("later declaration wins" like every other knob). The initial scan
/// resolves literal declarations; a bounded fixpoint then resolves aliases
/// and `+` mixes that reference other palette variables, so
/// `primary_color = secondary_color + text_color` works. Also marks the keys
/// consumed so they never appear as unrecognized. A variable left unresolved
/// after the fixpoint is cyclic or references an unknown operand: warned and
/// skipped (referencing knobs fall back to their own defaults). Call once per
/// merged Document, before knobs are applied.
pub fn collectPalette(doc: *parser.Document) void {
    // Last declaration per palette variable, in reserved-name order.
    var last: [parser.palette_var_names.len]?Value = undefined;
    // Deterministic precedence: StringHashMap iteration order is unrelated to
    // the merge order, so a palette variable declared in two sections must be
    // picked by NAME, not walk order: keep the strictly-greatest declaring
    // section (a var in two sections takes the alphabetically later one),
    // then let the root override (root applied last, so a var in both a
    // section and the root takes the root's value). The common case -- a var
    // declared exactly once -- yields that same value under any scan order.
    // One pass per var; no name array, no sort, no alloc.
    for (parser.palette_var_names, 0..) |name, i| {
        var best: ?Value = null;
        var best_name: []const u8 = "";
        var iter = doc.sections.iterator();
        while (iter.next()) |entry| {
            const val = entry.value_ptr.get(name) orelse continue;
            if (std.mem.lessThan(u8, best_name, entry.key_ptr.*)) {
                best_name = entry.key_ptr.*;
                best = val;
            }
        }
        if (doc.root.get(name)) |val| best = val;
        // Keep the full accumulated declaration: an array-spelling `+` mix
        // (`primary_color + secondary_color`) must survive to the resolver,
        // which reads it as a unit (resolvePaletteDecl). Its own resolution
        // keeps later-declaration-wins for plain scalar duplicates.
        last[i] = best;
    }

    // Fixpoint: each round resolves whatever became resolvable this round; a
    // progress-free round means everything left is cyclic or unresolvable.
    var progress = true;
    var rounds: usize = 0;
    while (progress and rounds <= parser.palette_var_names.len) {
        progress = false;
        rounds += 1;
        for (last, 0..) |may, i| {
            if (may == null) continue;
            const name = parser.palette_var_names[i];
            if (resolvePaletteDecl(may.?, &doc.palette)) |c| {
                doc.palette.put(name, c) catch {};
                last[i] = null;
                progress = true;
            }
        }
    }

    for (last, 0..) |may, i| {
        if (may != null) {
            log.warn(
                "Palette variable '{s}' is a cyclic or unresolvable color expression; ignoring (referencing colors fall back to defaults)",
                .{parser.palette_var_names[i]},
            );
        }
    }
}

/// True when `val` looks like a color-mix attempt that FAILED the bounds
/// check (a `+` in some element, or a weight marker anywhere): the
/// last-scalar fallback must not swallow it (descending to its
/// final operand silently resolves the bad mix instead of reverting).
fn isMixAttempt(val: parser.Value) bool {
    if (val != .array) return false;
    for (val.asArray().?) |item| {
        if (item.asScalar([]const u8)) |s| {
            if (std.mem.indexOfScalar(u8, s, '+') != null) return true;
        }
        if (parser.isWeightToken(item.asScalar([]const u8) orelse "")) return true;
    }
    return false;
}

/// Resolves a color from a pre-fetched Value, accepting `#RRGGBB`,
/// `0xRRGGBB`, an integer, a full-name reference to a collected palette
/// variable (e.g. `border_focused = primary_color`), or a `+` color-mix
/// expression of any of those (e.g. `primary_color + (weight:75%)
/// secondary_color`). The value-decoding forms share colorFromValue
/// (the single decoder); this layer adds the palette-reference lookup and the
/// warn-and-default policy on top.
pub fn getColorFromValue(
    key: []const u8,
    val: parser.Value,
    default: u32,
    palette: *const std.StringHashMap(u32),
) u32 {
    if (colorFromValue(val)) |c| return c;
    if (resolveColorExpr(val, palette)) |c| return c;
    if (isMixAttempt(val)) {
        log.warn("Invalid color mix for '{s}': coalesced + weights may not exceed 100 and the head operand cannot carry a weight (using default)", .{key});
        return default;
    }
    if (val.asScalar([]const u8)) |s| {
        if (palette.get(s)) |c| return c;
        log.warn("Invalid color for {s}: '{s}' (not a hex code, palette reference, or + mix)", .{ key, s });
        return default;
    }
    // Unresolvable value (boolean, size, bare float, out-of-range int, ...)
    // would otherwise silently use the default without a trace.
    log.warn("Value for '{s}' is not a color (expected '#RRGGBB', '0xRRGGBB', a bare 6/8-digit hex number, a palette reference, or a + mix), using default", .{key});
    return default;
}
