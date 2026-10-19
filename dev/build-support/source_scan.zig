//! Shared build-time source scanners (P2-49): one comment/string-aware
//! stripper and one `@import("<name>")` name iterator, consumed by
//! build.zig's fragment/knob/edge scans AND by the Rule-3 xcb sweep
//! (dev/build-support/rule3.zig), so comment semantics cannot drift between
//! the configure-time checks and the layer guard. Pure text processing:
//! no std.Build dependency, importable from both a build script and a
//! `zig run` tool.

const std = @import("std");

/// Copies `src` into `out` with comments removed, newline-preserving: every
/// physical line of the input is one physical line of the output, so a
/// consumer can report hits at their true file:line. Line comments (`//`)
/// and block comments (`/* */`, incl. multi-line) are dropped; string and
/// char literals are tracked so a `//` or `/*` INSIDE a literal neither
/// starts a comment (the old over-cut that could only cause false failures)
/// nor hides following code from a token sweep (the old false-green hole,
/// where `"...//...xcb"` lost its tail to the strip). Escapes inside
/// literals are consumed in pairs. A `\\`-continued multi-line string
/// terminates at its newline like any other literal: the state machine
/// stays line-oriented at that edge, which can only expose text to a
/// consumer (loud), never hide it.
pub fn stripCommentsInto(out: *std.ArrayList(u8), alloc: std.mem.Allocator, src: []const u8) !void {
    var i: usize = 0;
    while (i < src.len) {
        const c = src[i];
        if (c == '\n') {
            try out.append(alloc, '\n');
            i += 1;
            continue;
        }
        if (c == '/' and i + 1 < src.len and src[i + 1] == '/') {
            while (i < src.len and src[i] != '\n') i += 1;
            continue;
        }
        if (c == '/' and i + 1 < src.len and src[i + 1] == '*') {
            i += 2;
            while (i < src.len) : (i += 1) {
                if (src[i] == '\n') try out.append(alloc, '\n');
                if (src[i] == '*' and i + 1 < src.len and src[i + 1] == '/') {
                    i += 2;
                    break;
                }
            }
            continue;
        }
        if (c == '"' or c == '\'') {
            try out.append(alloc, c);
            i += 1;
            while (i < src.len and src[i] != c and src[i] != '\n') {
                if (src[i] == '\\' and i + 1 < src.len) {
                    try out.appendSlice(alloc, src[i .. i + 2]);
                    i += 2;
                    continue;
                }
                try out.append(alloc, src[i]);
                i += 1;
            }
            if (i < src.len and src[i] == c) {
                try out.append(alloc, c);
                i += 1;
            }
            continue;
        }
        try out.append(alloc, c);
        i += 1;
    }
}

/// True for a line whose first non-blank byte is `/`: a `//` comment, a
/// `/*` opener, or (already, for the `[0] == '/'` spelling) a stray `*/`
/// never matches. The one comment-line predicate every line-oriented
/// build-time scan shares, so the skip cannot drift between helpers.
pub fn isCommentOnlyLine(trimmed: []const u8) bool {
    return trimmed.len > 0 and trimmed[0] == '/';
}

/// Lazy iterator over the `@import("<name>")` literals in a raw source
/// string. Callers that must not count prose pass comment-stripped text;
/// `importEdgesOf` intentionally scans raw source (a comment-shaped mention
/// can only add a harmless extra edge, and the wired set is intersected
/// with the discovered modules anyway).
pub const ImportIterator = struct {
    rest: []const u8,

    pub const Match = struct {
        /// The module name between the quotes (may be empty on malformed
        /// input, which callers treat as a non-match).
        name: []const u8,
        /// Bytes AFTER the closing quote: `parseSubsConsumers` inspects
        /// this tail for the `).field` shape without recomputing offsets.
        tail: []const u8,
    };

    pub fn next(self: *ImportIterator) ?Match {
        const needle = "@import(\"";
        while (true) {
            const start = std.mem.indexOf(u8, self.rest, needle) orelse return null;
            const rel = self.rest[start + needle.len ..];
            const quote = std.mem.indexOfScalar(u8, rel, '"') orelse {
                // No closing quote on the rest of the string: the name
                // region cannot contain another needle that the original
                // single-pass scans would have seen either, so end.
                self.rest = rel[rel.len..];
                return null;
            };
            self.rest = rel[quote + 1 ..];
            return .{ .name = rel[0..quote], .tail = self.rest };
        }
    }
};
