//! Vim modal-editing engine tests (headless).
//!
//! The vim engine (`bar/modules/prompt/vim.zig`) is a pure state machine over
//! `prompt.EditorState`, so every handler can be driven directly without a
//! live connection or the bar runtime. Expected values are hand-traced from
//! the engine's formulas (word-scan classes, operator ranges, paste offsets).
//!
//! F-20 order independence: the engine keeps process-global state (`pending`,
//! `yank_buf`/`yank_len`), so each test resets the pending command via
//! `onDeactivate` and re-seeds its own yank register (yy) before any paste.

const std = @import("std");
const testing = std.testing;

const core = @import("core");
const xcb = core.xcb;
const prompt = @import("prompt");
const vim = @import("vim");

const Mode = prompt.Mode;
const Action = prompt.Action;

/// The vim engine owns a process-global yank register allocated by vim.init.
/// Tests run in ANY order (the runner is seeded), so each one lazily ensures
/// the register exists before touching delete/yank/paste paths. It lives for
/// the whole test process, so it's allocated from the untracked page allocator
/// -- the engine has no per-register free and a per-test tracking allocator
/// would report it as an order-dependent leak.
var yank_ready = false;
fn ensureYank() void {
    if (!yank_ready) {
        vim.init(std.heap.page_allocator, 64) catch {};
        yank_ready = true;
    }
}

/// Types the text in (insert mode), then escapes to normal mode.
fn typed(alloc: std.mem.Allocator, text: []const u8) !prompt.EditorState {
    ensureYank();
    var es = try prompt.EditorState.init(alloc, 64);
    for (text) |ch| _ = vim.handleInsert(&es, ch);
    _ = vim.handleInsert(&es, prompt.xk_escape);
    // A fresh editor never inherits a half-armed operator from an earlier test.
    vim.onDeactivate(&es);
    return es;
}

fn norm(es: *prompt.EditorState, sym: xcb.xcb_keysym_t) void {
    _ = vim.handleNormal(es, sym);
}

test "insert-mode typing and escape-to-normal with cursor clamp" {
    var es = try typed(testing.allocator, "hi there");
    defer es.deinit();
    try testing.expectEqual(Mode.normal, es.mode);
    try testing.expectEqual(@as(usize, 8), es.len);
    try testing.expectEqualStrings("hi there", es.buf[0..8]);
    // Clamped from past-the-end back onto the last character.
    try testing.expectEqual(@as(usize, 7), es.cursor);
}

test "normal-mode motion keys and count prefixes" {
    var es = try typed(testing.allocator, "one two three");
    defer es.deinit();
    try testing.expectEqual(@as(usize, 12), es.cursor);

    norm(&es, '0');
    try testing.expectEqual(@as(usize, 0), es.cursor);
    norm(&es, 'l');
    try testing.expectEqual(@as(usize, 1), es.cursor);
    norm(&es, '$');
    // '$' resolves to `len`; normal-mode clamp holds it on the last char.
    try testing.expectEqual(@as(usize, 12), es.cursor);
    norm(&es, 'h');
    try testing.expectEqual(@as(usize, 11), es.cursor);

    // w/b step as word-aligned tokens across the separators.
    norm(&es, '0');
    norm(&es, 'w');
    try testing.expectEqual(@as(usize, 4), es.cursor); // start of "two"
    norm(&es, 'w');
    try testing.expectEqual(@as(usize, 8), es.cursor); // start of "three"
    norm(&es, 'b');
    try testing.expectEqual(@as(usize, 4), es.cursor); // back to "two"

    // A count prefix multiplies a single motion.
    norm(&es, '0');
    norm(&es, '3');
    norm(&es, 'l');
    try testing.expectEqual(@as(usize, 3), es.cursor);
}

test "count prefixes clamp at the buffer edges" {
    var es = try typed(testing.allocator, "abc");
    defer es.deinit();

    norm(&es, '9');
    norm(&es, '9');
    norm(&es, 'l');
    // min(2 + 99, len - 1): normal mode holds on the last character, so the
    // run-off clamps to index 2, not past the end (consistent with the '$'
    // clamp above).
    try testing.expectEqual(@as(usize, 2), es.cursor);

    norm(&es, '9');
    norm(&es, 'h');
    try testing.expectEqual(@as(usize, 0), es.cursor); // saturating subtraction
}

test "operator d over motion ranges (dw, dd)" {
    var es = try typed(testing.allocator, "one two three");
    defer es.deinit();

    // dw deletes through the start of the next word, yanking the range.
    norm(&es, '0');
    norm(&es, 'd');
    norm(&es, 'w');
    try testing.expectEqualStrings("two three", es.buf[0..9]);
    try testing.expectEqual(@as(usize, 9), es.len);
    try testing.expectEqual(@as(usize, 0), es.cursor);

    // dd is the double-tap full-line form.
    norm(&es, 'd');
    norm(&es, 'd');
    try testing.expectEqual(@as(usize, 0), es.len);
}

test "yank/paste register round-trip" {
    var es = try typed(testing.allocator, "ab");
    defer es.deinit();

    // yy yanks the whole line, parking the cursor at the range start.
    norm(&es, 'y');
    norm(&es, 'y');
    try testing.expectEqual(@as(usize, 0), es.cursor);

    // p pastes after the cursor character (documented offset semantics).
    norm(&es, 'p');
    try testing.expectEqualStrings("aabb", es.buf[0..4]);
    try testing.expectEqual(@as(usize, 4), es.len);
}

test "cw range-replaces into insert mode" {
    var es = try typed(testing.allocator, "one two");
    defer es.deinit();

    norm(&es, '0');
    norm(&es, 'c');
    norm(&es, 'w');
    // "one " was consumed and we are in insert mode at its start.
    try testing.expectEqual(Mode.insert, es.mode);
    try testing.expectEqualStrings("two", es.buf[0..3]);

    _ = vim.handleInsert(&es, 'h');
    _ = vim.handleInsert(&es, 'i');
    try testing.expectEqualStrings("hitwo", es.buf[0..5]);
}

test "direct operators x, D and case toggle ~" {
    var es = try typed(testing.allocator, "aBc");
    defer es.deinit();

    norm(&es, '0');
    norm(&es, 'x');
    try testing.expectEqualStrings("Bc", es.buf[0..2]);

    // ~ toggles the char under the cursor and advances one.
    norm(&es, '0');
    norm(&es, '~');
    try testing.expectEqualStrings("bc", es.buf[0..2]);
    norm(&es, '~');
    try testing.expectEqualStrings("bC", es.buf[0..2]);
}

test "find motions f/t and repeats ; ," {
    var es = try typed(testing.allocator, "cab cad cae");
    defer es.deinit();

    norm(&es, '0');
    norm(&es, 'f');
    norm(&es, 'a');
    try testing.expectEqual(@as(usize, 1), es.cursor);

    norm(&es, ';'); // repeat forward
    try testing.expectEqual(@as(usize, 5), es.cursor);

    norm(&es, 't');
    norm(&es, 'a');
    try testing.expectEqual(@as(usize, 8), es.cursor); // stops just before 'a'

    norm(&es, 'F');
    norm(&es, 'c');
    try testing.expectEqual(@as(usize, 4), es.cursor);

    norm(&es, ','); // repeat the last find in the opposite direction (F -> f): next 'c' forward
    try testing.expectEqual(@as(usize, 8), es.cursor);
}

test "g-prefix motions gg and g$" {
    var es = try typed(testing.allocator, "one two");
    defer es.deinit();

    norm(&es, 'g');
    norm(&es, 'g');
    try testing.expectEqual(@as(usize, 0), es.cursor);

    norm(&es, 'g');
    norm(&es, '$');
    try testing.expectEqual(@as(usize, 6), es.cursor); // len - 1 of len 7
}

test "ctrl-w deletes the previous word in insert; ctrl-c deactivates" {
    ensureYank();
    var es = try prompt.EditorState.init(testing.allocator, 64);
    defer es.deinit();
    for ("one two") |ch| _ = vim.handleInsert(&es, ch);
    try testing.expectEqual(Mode.insert, es.mode);

    // Removes "two" but keeps the separator space (the word scan stops at it).
    _ = vim.handleCtrl(&es, 'w');
    try testing.expectEqualStrings("one ", es.buf[0..4]);
    try testing.expectEqual(@as(usize, 4), es.len);
    try testing.expectEqual(@as(usize, 4), es.cursor);

    try testing.expectEqual(Action.deactivate, vim.handleCtrl(&es, 'c'));

    // Ctrl+C deactivates from normal mode too.
    _ = vim.handleInsert(&es, prompt.xk_escape);
    try testing.expectEqual(Action.deactivate, vim.handleCtrl(&es, 'c'));
}

test "onDeactivate resets a half-armed operator" {
    var es = try typed(testing.allocator, "abc");
    defer es.deinit();

    norm(&es, 'd'); // half-armed, awaiting a motion
    vim.onDeactivate(&es); // a prompt exit must not leave the op armed
    norm(&es, 'd'); // now arms a FRESH op instead of double-tapping dd
    try testing.expectEqual(@as(usize, 3), es.len); // whole line intact
}

test "empty buffer: every op is a no-op, no traps" {
    var es = try typed(testing.allocator, "");
    defer es.deinit();
    try testing.expectEqual(Mode.normal, es.mode);

    // Motions and ops on an empty buffer must all no-op. (Paste is excluded:
    // it would act on whatever a prior test left in the process-global yank.)
    for ([_]xcb.xcb_keysym_t{ '0', '$', 'l', 'h', 'w', 'b', 'g', '~', 'x' }) |sym| {
        norm(&es, sym);
    }
    norm(&es, 'd');
    norm(&es, 'd');
    norm(&es, 'f');
    norm(&es, 'a');
    try testing.expectEqual(@as(usize, 0), es.len);
    try testing.expectEqual(@as(usize, 0), es.cursor);
}

test "bare-prompt Ctrl keys are readline editing, never swallowed" {
    // The base handler (vim absent) routes Ctrl-U/A/E/K/W/H to editing.
    var es = try prompt.EditorState.init(testing.allocator, 64);
    defer es.deinit();

    _ = prompt.handleInsertBasic(&es, 'o');
    _ = prompt.handleInsertBasic(&es, 'n');
    _ = prompt.handleInsertBasic(&es, 'e');
    _ = prompt.handleInsertBasic(&es, ' ');
    _ = prompt.handleInsertBasic(&es, 't');
    _ = prompt.handleInsertBasic(&es, 'w');
    _ = prompt.handleInsertBasic(&es, 'o');
    try testing.expectEqual(@as(usize, 7), es.len);

    // Ctrl-A / Ctrl-E jump to the ends.
    _ = prompt.handleCtrl(&es, 'a');
    try testing.expectEqual(@as(usize, 0), es.cursor);
    _ = prompt.handleCtrl(&es, 'e');
    try testing.expectEqual(@as(usize, 7), es.cursor);

    // Ctrl-W deletes the word before the cursor ("two", mid-buffer cursor).
    _ = prompt.handleCtrl(&es, 'w');
    try testing.expectEqualStrings("one", es.buf[0..3]);
    try testing.expectEqual(@as(usize, 3), es.len);
    try testing.expectEqual(@as(usize, 3), es.cursor);

    // Type a fresh tail, then Ctrl-U clears head-to-cursor.
    _ = prompt.handleInsertBasic(&es, ',');
    _ = prompt.handleInsertBasic(&es, 'x');
    _ = prompt.handleCtrl(&es, 'u');
    try testing.expectEqual(@as(usize, 0), es.len);

    // Ctrl-K clears cursor-to-end.
    _ = prompt.handleInsertBasic(&es, 'x');
    _ = prompt.handleInsertBasic(&es, 'y');
    _ = prompt.handleInsertBasic(&es, 'z');
    _ = prompt.handleCtrl(&es, 'a');
    _ = prompt.handleInsertBasic(&es, 'Q');
    try testing.expectEqual(@as(usize, 1), es.cursor);
    _ = prompt.handleCtrl(&es, 'k');
    try testing.expectEqualStrings("Q", es.buf[0..1]);
    try testing.expectEqual(@as(usize, 1), es.len);

    // Ctrl-H is backspace before the cursor.
    _ = prompt.handleInsertBasic(&es, 'r');
    try testing.expectEqual(@as(usize, 2), es.cursor);
    _ = prompt.handleCtrl(&es, 'h');
    try testing.expectEqualStrings("Q", es.buf[0..1]);
    try testing.expectEqual(@as(usize, 1), es.len);

    // Ctrl-C still dismisses.
    try testing.expectEqual(Action.deactivate, prompt.handleCtrl(&es, 'c'));
}

test "vim insert keeps the readline Ctrl set (single word delete)" {
    var es = try prompt.EditorState.init(testing.allocator, 64);
    defer es.deinit();

    // Straight insert-mode typing (no escape): the shared tail.
    for ("aa bb") |ch| _ = vim.handleInsert(&es, ch);
    try testing.expectEqual(Mode.insert, es.mode);
    try testing.expectEqual(@as(usize, 5), es.len);

    // Ctrl-U in vim insert falls through to the base handler once, not twice.
    _ = vim.handleCtrl(&es, 'u');
    try testing.expectEqual(@as(usize, 0), es.len);
}
