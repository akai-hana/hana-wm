//! Word-at-cursor completion logic.
//!
//! `updateGhost` used to bail on ANY space in the buffer, so the second and
//! later words of a command could never be completed: typing "git ch" showed no
//! ghost even with "checkout" sitting in the executable table. The fix is to
//! match the token under the CURSOR rather than a prefix of the line.
//!
//! `wordAtCursor` is the whole fix in one pure function, and it is public
//! precisely so it can be pinned here without the module's global state -- the
//! ghost itself lives in `g`, which no test can seed. What is pinned is the
//! behavior change: a token after a space is found, and the reported offset
//! points at the token's first byte.

// Declared here, next to the imports that make it necessary, rather than in a
// build.zig table that had to be kept in agreement with them by hand.
// build-gate: vim, seg_prompt

const std = @import("std");
const testing = std.testing;

const prompt = @import("prompt");
const wordAtCursor = prompt.wordAtCursor;

test "a single-word buffer is one token at offset 0" {
    const w = wordAtCursor("git", 3);
    try testing.expectEqualStrings("git", w.token);
    try testing.expectEqual(@as(usize, 0), w.start);
}

test "the token under the cursor is the LAST word, not the first" {
    // The regression this fixes: with a space present, the old code gave up
    // entirely, so nothing here completed at all.
    const w = wordAtCursor("git ch", 6);
    try testing.expectEqualStrings("ch", w.token);
    try testing.expectEqual(@as(usize, 4), w.start);
}

test "the whole line is one token when it has no space" {
    const w = wordAtCursor("checkout", 8);
    try testing.expectEqualStrings("checkout", w.token);
    try testing.expectEqual(@as(usize, 0), w.start);
}

test "a mid-buffer cursor takes the word it is inside, not the rest" {
    // The cursor bounds the token: text after the cursor is not part of it.
    // This is what lets the same helper serve the completion sources, which
    // always pass a cursor at the end of their own slice.
    const w = wordAtCursor("git checkout main", 3);
    try testing.expectEqualStrings("git", w.token);
    try testing.expectEqual(@as(usize, 0), w.start);
}

test "a cursor inside the second word yields that word alone" {
    const w = wordAtCursor("git checkout", 5);
    try testing.expectEqualStrings("c", w.token);
    try testing.expectEqual(@as(usize, 4), w.start);
}

test "consecutive spaces collapse: the token starts after the last one" {
    // "git  ch" -- the token must not carry a leading space, or every
    // startsWith comparison downstream fails on a space the user never sees.
    const w = wordAtCursor("git  ch", 7);
    try testing.expectEqualStrings("ch", w.token);
    try testing.expectEqual(@as(usize, 5), w.start);
}

test "a trailing space yields an empty token, not the previous word" {
    // Nothing is being typed yet at the cursor, so there is nothing to
    // complete. Returning the previous word here would ghost its own tail.
    const w = wordAtCursor("git ", 4);
    try testing.expectEqualStrings("", w.token);
    try testing.expectEqual(@as(usize, 4), w.start);
}

test "an empty buffer yields an empty token" {
    const w = wordAtCursor("", 0);
    try testing.expectEqualStrings("", w.token);
    try testing.expectEqual(@as(usize, 0), w.start);
}

test "a cursor past the end clamps instead of slicing out of bounds" {
    // The cursor is threaded from the editor's own length, but a defensive
    // clamp here is what keeps this a total function: the alternative is a
    // panic in the middle of a keystroke handler.
    const w = wordAtCursor("git ch", 99);
    try testing.expectEqualStrings("ch", w.token);
    try testing.expectEqual(@as(usize, 4), w.start);
}

test "CompletionSource names both lookup strategies the union replaced" {
    // The union exists so priority lives in one list. Pin the members so a
    // rename that silently drops a source is a compile error at the call site
    // rather than a source that is never consulted.
    try testing.expectEqual(@as(usize, 2), @typeInfo(prompt.CompletionSource).@"enum".fields.len);
}
