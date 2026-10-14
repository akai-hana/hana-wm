//! Cross-file document merging: an overlay document folds into a base with
//! the same duplicate-key semantics as within one file, through
//! `document.insertOrAccumulate`. Keys and values are SHARED (one arena per
//! load), never copied -- see the ownership model in `document.zig`.

const std = @import("std");
const document = @import("document");
const Section = document.Section;
const Document = document.Document;

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
        try document.insertOrAccumulate(allocator, dst, e.key, e.value, e.line);
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
