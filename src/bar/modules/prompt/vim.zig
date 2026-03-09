//! vim — modal editing engine for drun.
//!
//! Implements a vim-style modal editing layer over a single-line text buffer.
//! All state is contained in `VimState`.  The four mode handlers each return an
//! `Action` value so the caller can react without a circular dependency:
//!
//!   .none       — nothing special; caller should just redraw
//!   .deactivate — user pressed Escape / Ctrl+C to close
//!   .spawn      — user pressed Return; execute buf[0..len] and close
//!
//! Typical integration in a key-press handler:
//!
//!   const action = switch (vs.mode) {
//!       .insert  => vim.handleInsert(vs, sym),
//!       .normal  => vim.handleNormal(vs, sym),
//!       .visual  => vim.handleVisual(vs, sym),
//!       .replace => vim.handleReplace(vs, sym),
//!   };
//!   switch (action) {
//!       .none       => {},
//!       .deactivate => ...,
//!       .spawn      => { runCmd(vs.buf[0..vs.len]); ... },
//!   }
//!
//! Ctrl-modified keys should be pre-handled and routed to handleCtrl().

const std = @import("std");
const defs = @import("defs");
const xcb  = defs.xcb;

// ── X11 keysym constants ──────────────────────────────────────────────────────
// Re-exported from keysyms.zig for callers that write `vim.XK_*`.
// New code should import keysyms.zig directly.

const ks = @import("keysyms");
pub const XK_BackSpace = ks.XK_BackSpace;
pub const XK_Tab       = ks.XK_Tab;
pub const XK_Return    = ks.XK_Return;
pub const XK_Escape    = ks.XK_Escape;
pub const XK_Delete    = ks.XK_Delete;
pub const XK_Left      = ks.XK_Left;
pub const XK_Right     = ks.XK_Right;
pub const XK_Home      = ks.XK_Home;
pub const XK_End       = ks.XK_End;

// ── Shared constants ──────────────────────────────────────────────────────────

pub const MAX_INPUT  : usize = 512;
pub const UNDO_MAX   : usize = 32;
pub const MARK_COUNT : usize = 26; // marks a–z

// ── Types ─────────────────────────────────────────────────────────────────────

/// What the caller should do after handling a key.
pub const Action = enum { none, deactivate, spawn };

/// Editing modes, reflected live in the mode label.
/// The integer value is the index into the cached mode-width array.
pub const Mode = enum(u2) {
    insert  = 0,
    normal  = 1,
    visual  = 2,
    replace = 3,

    pub fn label(self: Mode) []const u8 {
        return switch (self) {
            .insert  => "[INSERT]",
            .normal  => "[NORMAL]",
            .visual  => "[VISUAL]",
            .replace => "[REPLACE]",
        };
    }
};

/// What the last change was — used by `.` to replay.
pub const DotKind = enum { none, direct, op_motion, op_line, insert_session };

/// Record of the last atomic change for `.` repeat.
pub const DotRecord = struct {
    kind:         DotKind              = .none,
    // op_motion / op_line:
    op:           u8                   = 0,
    op_count:     u32                  = 1,
    // op_motion only:
    motion_sym:   xcb.xcb_keysym_t    = 0,
    motion_count: u32                  = 1,
    g_prefix:     bool                 = false,  // ge / gE
    find_kind:    u8                   = 0,       // f/F/t/T motion
    find_ch:      u8                   = 0,
    tobj_kind:    u8                   = 0,       // 'i'/'a' for text objects
    tobj_delim:   u8                   = 0,
    // direct (x/X/D/C/~/r/p/P/s/S):
    direct_sym:   xcb.xcb_keysym_t    = 0,
    direct_count: u32                  = 1,
    direct_ch:    u8                   = 0,       // for r
    // insert text (for insert_session, c-op, s/S/C/cc):
    insert_buf:   [MAX_INPUT]u8        = undefined,
    insert_len:   usize                = 0,
};

/// Result returned by motion functions.
/// `pos`           — destination cursor position.
/// `inclusive`     — when true the char at `pos` is included in operator ranges.
/// `from_override` — when set (text objects), this is the range start instead of cursor.
pub const MotionResult = struct {
    pos:           usize,
    inclusive:     bool   = false,
    from_override: ?usize = null,
};

/// A single undo/redo snapshot.
pub const UndoEntry = struct {
    buf:    [MAX_INPUT]u8 = undefined,
    len:    usize         = 0,
    cursor: usize         = 0,
};

// ── VimState ──────────────────────────────────────────────────────────────────

/// All state for the vim editing engine.  Embed one of these in your application
/// state and pass a pointer to the handle* functions each key press.
pub const VimState = struct {
    buf:    [MAX_INPUT]u8 = undefined,
    len:    usize         = 0,
    cursor: usize         = 0,
    mode:   Mode          = .insert,

    // ── Normal-mode sub-state ─────────────────────────────────────────────────
    n_count:          u32  = 0,   // digit accumulator
    n_op:             u8   = 0,   // pending operator ('d'/'c'/'y')
    n_op_count:       u32  = 0,   // count when operator was armed
    n_find_kind:      u8   = 0,   // pending f/F/t/T
    n_pending_r:      bool = false,
    n_pending_g:      bool = false,
    n_text_obj_kind:  u8   = 0,   // pending 'i'/'a' for text object
    n_pending_m:      bool = false, // 'm' pressed, waiting for letter
    n_pending_apos:   bool = false, // "'" pressed, waiting for letter

    // Last f/F/t/T for ';' / ',' repeat.
    last_find_kind:   u8   = 0,
    last_find_ch:     u8   = 0,

    // ── Yank / delete register ────────────────────────────────────────────────
    yank_buf: [MAX_INPUT]u8 = undefined,
    yank_len: usize         = 0,

    // ── Visual mode ───────────────────────────────────────────────────────────
    vis_anchor: usize = 0,

    // ── Replace mode ──────────────────────────────────────────────────────────
    replace_orig_buf: [MAX_INPUT]u8 = undefined,
    replace_orig_len: usize         = 0,
    replace_orig_cur: usize         = 0, // cursor position when R was pressed

    // ── Marks a–z ─────────────────────────────────────────────────────────────
    marks: [MARK_COUNT]?usize = [_]?usize{null} ** MARK_COUNT,

    // ── Undo / redo ───────────────────────────────────────────────────────────
    undo_stack: [UNDO_MAX]UndoEntry = undefined,
    undo_top:   usize               = 0,
    redo_stack: [UNDO_MAX]UndoEntry = undefined,
    redo_top:   usize               = 0,

    // ── Dot repeat ────────────────────────────────────────────────────────────
    dot:              DotRecord     = .{},
    in_dot_replay:    bool          = false,
    recording_insert: bool          = false,
    insert_rec_buf:   [MAX_INPUT]u8 = undefined,
    insert_rec_len:   usize         = 0,
};

// ── Public helpers ────────────────────────────────────────────────────────────

/// Reset all normal-mode sub-state (counts, pending operators, prefix flags).
pub fn resetNormalSub(vs: *VimState) void {
    vs.n_count         = 0;
    vs.n_op            = 0;
    vs.n_op_count      = 0;
    vs.n_find_kind     = 0;
    vs.n_pending_r     = false;
    vs.n_pending_g     = false;
    vs.n_text_obj_kind = 0;
    vs.n_pending_m     = false;
    vs.n_pending_apos  = false;
}

inline fn beginInsertRecording(vs: *VimState) void {
    vs.insert_rec_len   = 0;
    vs.recording_insert = true;
}

/// Enter INSERT mode from a standalone command (i/a/I/A).
/// Pushes an undo snapshot and begins recording for dot repeat.
pub fn enterInsert(vs: *VimState) void {
    if (!vs.in_dot_replay) { undoPush(vs); beginInsertRecording(vs); }
    vs.mode = .insert;
}

/// Switch to INSERT mode without an undo push (used by c-operators that
/// already called undoPush before the deletion).
pub fn startInsertMode(vs: *VimState) void {
    if (!vs.in_dot_replay) beginInsertRecording(vs);
    vs.mode = .insert;
}

/// Return [lo, hi) covering the visual selection (exclusive upper bound).
pub fn visualRange(vs: *VimState) [2]usize {
    const lo = @min(vs.vis_anchor, vs.cursor);
    const hi = @min(@max(vs.vis_anchor, vs.cursor) + 1, vs.len);
    return .{ lo, hi };
}

/// Clamp cursor to the last valid position for normal mode.
/// In normal mode the cursor must sit on a character, not past the end.
inline fn clampCursorForNormal(vs: *VimState) void {
    if (vs.len > 0 and vs.cursor == vs.len) vs.cursor = vs.len - 1;
}

// ── Key handlers ──────────────────────────────────────────────────────────────

/// Handle a Ctrl-modified key.  Call this before dispatching to mode handlers.
/// Returns `.deactivate` for Ctrl+C; `.none` for all others (mutations applied
/// in-place).
pub fn handleCtrl(vs: *VimState, sym: xcb.xcb_keysym_t) Action {
    switch (sym) {
        'c' => return .deactivate,
        'r' => if (vs.mode == .normal or vs.mode == .visual) undoRedo(vs),
        'w' => if (vs.mode == .insert) ctrlW(vs),
        'u' => if (vs.mode == .insert) ctrlU(vs),
        'a' => if (vs.mode == .normal) { ctrlAdjustNumber(vs, 1);  resetNormalSub(vs); },
        'x' => if (vs.mode == .normal) { ctrlAdjustNumber(vs, -1); resetNormalSub(vs); },
        else => {},
    }
    return .none;
}

// ── INSERT mode handler ───────────────────────────────────────────────────────

pub fn handleInsert(vs: *VimState, sym: xcb.xcb_keysym_t) Action {
    switch (sym) {
        XK_Escape => {
            // Finalise dot record insert text.
            if (vs.recording_insert) {
                vs.recording_insert = false;
                @memcpy(vs.dot.insert_buf[0..vs.insert_rec_len], vs.insert_rec_buf[0..vs.insert_rec_len]);
                vs.dot.insert_len = vs.insert_rec_len;
            }
            // Clamp cursor: in normal mode cursor must sit on a character.
            clampCursorForNormal(vs);
            vs.mode = .normal;
            resetNormalSub(vs);
        },

        XK_Return => return .spawn,

        XK_BackSpace => deleteBefore(vs),
        XK_Delete    => deleteAfter(vs),
        XK_Left      => { if (vs.cursor > 0) vs.cursor -= 1; },
        XK_Right     => { if (vs.cursor < vs.len) vs.cursor += 1; },
        XK_Home      => vs.cursor = 0,
        XK_End       => vs.cursor = vs.len,

        else => {
            if (sym >= 0x20 and sym <= 0x7e) {
                const ch: u8 = @truncate(sym);
                insertChar(vs, ch);
                // Record for dot repeat.
                if (vs.recording_insert and vs.insert_rec_len < MAX_INPUT - 1) {
                    vs.insert_rec_buf[vs.insert_rec_len] = ch;
                    vs.insert_rec_len += 1;
                }
            }
        },
    }
    return .none;
}

// ── NORMAL mode handler ───────────────────────────────────────────────────────

/// Digit accumulation shared by handleNormal and handleVisual.
/// Returns true and updates n_count if sym is a digit (1-9 always; 0 only if
/// count is already non-zero).  Returns false and does nothing otherwise.
fn tryAccumulateDigit(vs: *VimState, sym: xcb.xcb_keysym_t) bool {
    if (sym >= '1' and sym <= '9') {
        vs.n_count = vs.n_count *% 10 +% @as(u32, @truncate(sym - '0'));
        return true;
    }
    if (sym == '0' and vs.n_count > 0) {
        vs.n_count = vs.n_count *% 10;
        return true;
    }
    return false;
}

/// Arm f/F/t/T or g prefix, shared by handleNormal and handleVisual.
/// Returns true if the symbol was consumed as a prefix.
fn tryArmFindPrefix(vs: *VimState, sym: xcb.xcb_keysym_t) bool {
    if (sym == 'g') { vs.n_pending_g = true; return true; }
    if (sym == 'f' or sym == 'F' or sym == 't' or sym == 'T') {
        vs.n_find_kind = @truncate(sym);
        return true;
    }
    return false;
}

pub fn handleNormal(vs: *VimState, sym: xcb.xcb_keysym_t) Action {
    // ── 1. Pending r{c} ───────────────────────────────────────────────────────
    if (vs.n_pending_r) {
        if (sym >= 0x20 and sym <= 0x7e and vs.cursor < vs.len) {
            const ch: u8   = @truncate(sym);
            const cnt: u32 = effCount(vs);
            vs.dot = .{ .kind = .direct, .direct_sym = 'r', .direct_count = cnt, .direct_ch = ch };
            undoPush(vs);
            var i: usize = 0;
            while (i < cnt and vs.cursor + i < vs.len) : (i += 1) vs.buf[vs.cursor + i] = ch;
            vs.cursor = @min(vs.cursor + cnt - 1, vs.len -| 1);
        }
        resetNormalSub(vs);
        return .none;
    }

    // ── 2. Pending f/F/t/T char ───────────────────────────────────────────────
    if (vs.n_find_kind != 0) {
        if (sym >= 0x20 and sym <= 0x7e) {
            const ch: u8   = @truncate(sym);
            const cnt: u32 = effCount(vs);
            const kind     = vs.n_find_kind;
            const mr       = motionFind(vs, kind, ch, cnt);
            vs.last_find_kind = kind;
            vs.last_find_ch   = ch;
            if (vs.n_op != 0) {
                vs.dot = DotRecord{
                    .kind = .op_motion, .op = vs.n_op, .op_count = vs.n_op_count,
                    .motion_count = vs.n_count, .find_kind = kind, .find_ch = ch,
                };
                doOp(vs, vs.n_op, mr);
            } else {
                setCursor(vs, mr);
            }
        }
        resetNormalSub(vs);
        return .none;
    }

    // ── 3. Pending g-prefix ───────────────────────────────────────────────────
    if (vs.n_pending_g) {
        const cnt = effCount(vs);
        const mr_opt: ?MotionResult = switch (sym) {
            'e'     => MotionResult{ .pos = motionWordEndBack(vs, false, cnt), .inclusive = true },
            'E'     => MotionResult{ .pos = motionWordEndBack(vs, true,  cnt), .inclusive = true },
            'g', '0', XK_Home => MotionResult{ .pos = 0 },
            '$', XK_End       => MotionResult{ .pos = vs.len },
            else    => null,
        };
        if (mr_opt) |mr| {
            if (vs.n_op != 0) {
                vs.dot = DotRecord{
                    .kind = .op_motion, .op = vs.n_op, .op_count = vs.n_op_count,
                    .motion_count = vs.n_count, .motion_sym = sym,
                    .g_prefix = true,
                };
                doOp(vs, vs.n_op, mr);
            } else {
                setCursor(vs, mr);
            }
        }
        resetNormalSub(vs);
        return .none;
    }

    // ── 4. Pending text-object delimiter ─────────────────────────────────────
    if (vs.n_text_obj_kind != 0) {
        if (sym >= 0x20 and sym <= 0x7e) {
            const ch: u8 = @truncate(sym);
            if (resolveTextObject(vs, vs.n_text_obj_kind, ch)) |mr| {
                vs.dot = DotRecord{
                    .kind = .op_motion, .op = vs.n_op, .op_count = vs.n_op_count,
                    .motion_count = vs.n_count,
                    .tobj_kind = vs.n_text_obj_kind, .tobj_delim = ch,
                };
                doOp(vs, vs.n_op, mr);
            }
        }
        resetNormalSub(vs);
        return .none;
    }

    // ── 5. Pending mark set (m{a-z}) ─────────────────────────────────────────
    if (vs.n_pending_m) {
        if (sym >= 'a' and sym <= 'z')
            vs.marks[@as(usize, @intCast(sym - 'a'))] = vs.cursor;
        resetNormalSub(vs);
        return .none;
    }

    // ── 6. Pending mark jump ('{a-z}) ────────────────────────────────────────
    if (vs.n_pending_apos) {
        if (sym >= 'a' and sym <= 'z') {
            if (vs.marks[@as(usize, @intCast(sym - 'a'))]) |pos| {
                const mr = MotionResult{ .pos = pos };
                if (vs.n_op != 0) doOp(vs, vs.n_op, mr) else setCursor(vs, mr);
            }
        }
        resetNormalSub(vs);
        return .none;
    }

    // ── 7. Digit accumulation ─────────────────────────────────────────────────
    if (tryAccumulateDigit(vs, sym)) return .none;

    // ── 8. ; / , (repeat last find) ──────────────────────────────────────────
    if (sym == ';' or sym == ',') {
        if (vs.last_find_kind != 0) {
            const cnt  = effCount(vs);
            const kind = if (sym == ',') reverseFindKind(vs.last_find_kind) else vs.last_find_kind;
            const mr   = motionFind(vs, kind, vs.last_find_ch, cnt);
            if (vs.n_op != 0) doOp(vs, vs.n_op, mr) else setCursor(vs, mr);
        }
        resetNormalSub(vs);
        return .none;
    }

    // ── 9. Simple motions ─────────────────────────────────────────────────────
    if (resolveSimpleMotion(vs, sym, effCount(vs))) |mr| {
        if (vs.n_op != 0) {
            vs.dot = DotRecord{
                .kind = .op_motion, .op = vs.n_op, .op_count = vs.n_op_count,
                .motion_count = vs.n_count, .motion_sym = sym,
            };
            doOp(vs, vs.n_op, mr);
        } else {
            setCursor(vs, mr);
        }
        resetNormalSub(vs);
        return .none;
    }

    // ── 10. Operator arming / text-object detection ───────────────────────────
    if ((sym == 'i' or sym == 'a') and vs.n_op != 0) {
        vs.n_text_obj_kind = @truncate(sym);
        return .none;
    }
    if (sym == 'd' or sym == 'c' or sym == 'y') {
        const op: u8 = @truncate(sym);
        if (vs.n_op == 0) {
            vs.n_op       = op;
            vs.n_op_count = vs.n_count;
            vs.n_count    = 0;
            return .none;
        }
        if (vs.n_op == op) {
            vs.dot = DotRecord{ .kind = .op_line, .op = op, .op_count = vs.n_op_count, .motion_count = vs.n_count };
            doOp(vs, op, .{ .pos = vs.len, .from_override = 0 });
        }
        resetNormalSub(vs);
        return .none;
    }

    // ── 11. Prefix arming ────────────────────────────────────────────────────
    if (tryArmFindPrefix(vs, sym)) return .none;
    if (sym == 'r' and vs.n_op == 0) { vs.n_pending_r    = true; return .none; }
    if (sym == 'm' and vs.n_op == 0) { vs.n_pending_m    = true; return .none; }
    if (sym == 0x27)                 { vs.n_pending_apos = true; return .none; } // apostrophe

    // ── 12. Single-key commands ───────────────────────────────────────────────
    const cnt = effCount(vs);

    switch (sym) {

        XK_Escape => {
            if (vs.n_op == 0 and vs.n_count == 0) {
                resetNormalSub(vs);
                return .deactivate;
            }
            resetNormalSub(vs);
            return .none;
        },

        XK_Return => {
            resetNormalSub(vs);
            return .spawn;
        },

        // delete/change to a computed position: x X D C s
        'x', 'X', 'D', 'C', 's' => {
            const op: u8     = if (sym == 'x' or sym == 'X' or sym == 'D') 'd' else 'c';
            const pos: usize = switch (sym) {
                'X'      => charLeft(vs, cnt),
                'D', 'C' => vs.len,
                else     => charRight(vs, cnt), // x, s
            };
            vs.dot = .{ .kind = .direct, .direct_sym = @truncate(sym), .direct_count = cnt };
            doOp(vs, op, .{ .pos = pos });
        },

        'p', 'P' => {
            if (vs.yank_len > 0) {
                vs.dot = .{ .kind = .direct, .direct_sym = @truncate(sym), .direct_count = cnt };
                undoPush(vs);
                var i: u32 = 0;
                while (i < cnt) : (i += 1) { if (sym == 'p') pasteAfter(vs) else pasteBefore(vs); }
            }
        },

        '~' => {
            vs.dot = .{ .kind = .direct, .direct_sym = '~', .direct_count = cnt };
            undoPush(vs);
            var i: u32 = 0;
            while (i < cnt) : (i += 1) toggleCaseOnce(vs);
        },

        'S' => {
            vs.dot = .{ .kind = .direct, .direct_sym = 'S', .direct_count = cnt };
            undoPush(vs);
            yankRange(vs, 0, vs.len);
            vs.len    = 0;
            vs.cursor = 0;
            startInsertMode(vs);
        },

        'i', 'I', 'a', 'A' => {
            vs.cursor = switch (sym) {
                'I'  => firstNonBlank(vs),
                'a'  => @min(vs.cursor + 1, vs.len),
                'A'  => vs.len,
                else => vs.cursor,
            };
            vs.dot = .{ .kind = .insert_session };
            enterInsert(vs);
        },

        'v' => {
            vs.vis_anchor = vs.cursor;
            vs.mode = .visual;
            resetNormalSub(vs);
            return .none;
        },

        'R' => {
            undoPush(vs);
            @memcpy(vs.replace_orig_buf[0..vs.len], vs.buf[0..vs.len]);
            vs.replace_orig_len = vs.len;
            vs.replace_orig_cur = vs.cursor;
            vs.mode = .replace;
            resetNormalSub(vs);
            return .none;
        },

        '%' => {
            const pos = motionMatchBracket(vs);
            if (vs.n_op != 0) {
                vs.dot = DotRecord{
                    .kind = .op_motion, .op = vs.n_op, .op_count = vs.n_op_count,
                    .motion_count = vs.n_count, .motion_sym = '%',
                };
                doOp(vs, vs.n_op, MotionResult{ .pos = pos, .inclusive = true });
            } else {
                setCursor(vs, MotionResult{ .pos = pos });
            }
        },

        'u' => undoUndo(vs),
        '.' => { dotReplay(vs); resetNormalSub(vs); return .none; },

        else => {},
    }

    resetNormalSub(vs);
    return .none;
}

// ── VISUAL mode handler ───────────────────────────────────────────────────────

inline fn exitVisual(vs: *VimState) void { vs.mode = .normal; resetNormalSub(vs); }

pub fn handleVisual(vs: *VimState, sym: xcb.xcb_keysym_t) Action {
    // Resolve pending find.
    if (vs.n_find_kind != 0) {
        if (sym >= 0x20 and sym <= 0x7e) {
            const ch: u8  = @truncate(sym);
            const cnt     = effCount(vs);
            const kind    = vs.n_find_kind;
            const mr      = motionFind(vs, kind, ch, cnt);
            vs.last_find_kind = kind;
            vs.last_find_ch   = ch;
            setCursor(vs, mr);
        }
        resetNormalSub(vs);
        return .none;
    }

    // Resolve pending g-prefix.
    if (vs.n_pending_g) {
        const cnt = effCount(vs);
        const pos: ?usize = switch (sym) {
            'e'     => motionWordEndBack(vs, false, cnt),
            'E'     => motionWordEndBack(vs, true,  cnt),
            'g', '0', XK_Home => @as(usize, 0),
            '$', XK_End       => vs.len,
            else    => null,
        };
        if (pos) |p| setCursor(vs, MotionResult{ .pos = p });
        resetNormalSub(vs);
        return .none;
    }

    // Digit accumulation.
    if (tryAccumulateDigit(vs, sym)) return .none;

    // ; / , repeat find.
    if (sym == ';' or sym == ',') {
        if (vs.last_find_kind != 0) {
            const cnt  = effCount(vs);
            const kind = if (sym == ',') reverseFindKind(vs.last_find_kind) else vs.last_find_kind;
            setCursor(vs, motionFind(vs, kind, vs.last_find_ch, cnt));
        }
        resetNormalSub(vs);
        return .none;
    }

    // Simple motions extend selection.
    if (resolveSimpleMotion(vs, sym, effCount(vs))) |mr| {
        setCursor(vs, mr);
        resetNormalSub(vs);
        return .none;
    }

    // Prefix arming.
    if (tryArmFindPrefix(vs, sym)) return .none;

    // Operator and other keys.
    switch (sym) {

        XK_Escape, 'v' => exitVisual(vs),

        XK_Return => {
            resetNormalSub(vs);
            return .spawn;
        },

        'd', 'x', 'c' => {
            const sel = visualRange(vs);
            vs.dot = .{ .kind = .op_line, .op = if (sym == 'c') @as(u8, 'c') else @as(u8, 'd') };
            undoPush(vs);
            yankRange(vs, sel[0], sel[1]);
            deleteRange(vs, sel[0], sel[1]);
            exitVisual(vs);
            if (sym == 'c') startInsertMode(vs);
        },

        'y' => {
            const sel = visualRange(vs);
            yankRange(vs, sel[0], sel[1]);
            vs.cursor = sel[0];
            exitVisual(vs);
        },

        '~' => {
            const sel = visualRange(vs);
            undoPush(vs);
            var i = sel[0];
            while (i < sel[1]) : (i += 1) {
                const ch = vs.buf[i];
                vs.buf[i] = if (std.ascii.isLower(ch)) std.ascii.toUpper(ch)
                            else if (std.ascii.isUpper(ch)) std.ascii.toLower(ch)
                            else ch;
            }
            vs.cursor = sel[0];
            exitVisual(vs);
        },

        else => resetNormalSub(vs),
    }
    return .none;
}

// ── REPLACE mode handler ──────────────────────────────────────────────────────

pub fn handleReplace(vs: *VimState, sym: xcb.xcb_keysym_t) Action {
    switch (sym) {
        XK_Escape => {
            clampCursorForNormal(vs);
            vs.mode = .normal;
        },

        XK_Return => return .spawn,

        XK_BackSpace => {
            if (vs.cursor > vs.replace_orig_cur) {
                vs.cursor -= 1;
                if (vs.cursor < vs.replace_orig_len) {
                    vs.buf[vs.cursor] = vs.replace_orig_buf[vs.cursor];
                } else {
                    if (vs.cursor < vs.len - 1) {
                        std.mem.copyForwards(u8, vs.buf[vs.cursor .. vs.len - 1], vs.buf[vs.cursor + 1 .. vs.len]);
                    }
                    vs.len -= 1;
                }
            }
        },

        else => {
            if (sym >= 0x20 and sym <= 0x7e) {
                const ch: u8 = @truncate(sym);
                if (vs.cursor < vs.len) {
                    vs.buf[vs.cursor] = ch;
                    vs.cursor += 1;
                } else if (vs.len < MAX_INPUT - 1) {
                    vs.buf[vs.len] = ch;
                    vs.len    += 1;
                    vs.cursor += 1;
                }
            }
        },
    }
    return .none;
}

// ── Motion resolvers ──────────────────────────────────────────────────────────

fn resolveSimpleMotion(vs: *VimState, sym: xcb.xcb_keysym_t, cnt: u32) ?MotionResult {
    return switch (sym) {
        'h', XK_Left  => MotionResult{ .pos = charLeft(vs, cnt)              },
        'l', XK_Right => MotionResult{ .pos = charRight(vs, cnt)             },
        'w'           => MotionResult{ .pos = motionWordNext(vs, false, cnt)  },
        'W'           => MotionResult{ .pos = motionWordNext(vs, true,  cnt)  },
        'b'           => MotionResult{ .pos = motionWordPrev(vs, false, cnt)  },
        'B'           => MotionResult{ .pos = motionWordPrev(vs, true,  cnt)  },
        'e'           => MotionResult{ .pos = motionWordEnd(vs, false, cnt),   .inclusive = true },
        'E'           => MotionResult{ .pos = motionWordEnd(vs, true,  cnt),   .inclusive = true },
        '0', XK_Home  => MotionResult{ .pos = 0                               },
        '^'           => MotionResult{ .pos = firstNonBlank(vs)               },
        '$', XK_End   => MotionResult{ .pos = vs.len                          },
        else          => null,
    };
}

// ── Primitive motion functions ────────────────────────────────────────────────

inline fn isWordChar(ch: u8) bool {
    return std.ascii.isAlphanumeric(ch) or ch == '_';
}

/// Character class for word motions.  big=true collapses to space/non-space.
/// 0 = space, 1 = word char (or any non-space when big), 2 = punctuation.
inline fn charClass(big: bool, ch: u8) u2 {
    if (ch == ' ') return 0;
    if (big or isWordChar(ch)) return 1;
    return 2;
}

fn charLeft(vs: *VimState, cnt: u32) usize {
    return vs.cursor -| @as(usize, cnt);
}

fn charRight(vs: *VimState, cnt: u32) usize {
    return @min(vs.cursor + @as(usize, cnt), vs.len);
}

fn motionWordNext(vs: *VimState, big: bool, cnt: u32) usize {
    var p = vs.cursor;
    var i: u32 = 0;
    while (i < cnt) : (i += 1) {
        if (p >= vs.len) break;
        const cls = charClass(big, vs.buf[p]);
        while (p < vs.len and charClass(big, vs.buf[p]) == cls) p += 1;
        while (p < vs.len and vs.buf[p] == ' ') p += 1;
    }
    return p;
}

fn motionWordPrev(vs: *VimState, big: bool, cnt: u32) usize {
    var p = vs.cursor;
    var i: u32 = 0;
    while (i < cnt) : (i += 1) {
        if (p == 0) break;
        while (p > 0 and vs.buf[p - 1] == ' ') p -= 1;
        if (p == 0) break;
        const cls = charClass(big, vs.buf[p - 1]);
        while (p > 0 and charClass(big, vs.buf[p - 1]) == cls) p -= 1;
    }
    return p;
}

fn motionWordEnd(vs: *VimState, big: bool, cnt: u32) usize {
    var p = vs.cursor;
    var i: u32 = 0;
    while (i < cnt) : (i += 1) {
        if (p >= vs.len) break;
        p += 1;
        while (p < vs.len and vs.buf[p] == ' ') p += 1;
        if (p >= vs.len) { p = vs.len; break; }
        const cls = charClass(big, vs.buf[p]);
        while (p + 1 < vs.len and charClass(big, vs.buf[p + 1]) == cls) p += 1;
    }
    return @min(p, vs.len -| 1);
}

fn motionWordEndBack(vs: *VimState, big: bool, cnt: u32) usize {
    var p = vs.cursor;
    var i: u32 = 0;
    while (i < cnt) : (i += 1) {
        if (p == 0) break;
        const cls0 = charClass(big, vs.buf[p]);
        if (cls0 != 0) {
            while (p > 0 and charClass(big, vs.buf[p - 1]) == cls0) p -= 1;
        }
        if (p == 0) break;
        p -= 1;
        while (p > 0 and vs.buf[p] == ' ') p -= 1;
    }
    return p;
}

fn motionFind(vs: *VimState, kind: u8, ch: u8, cnt: u32) MotionResult {
    var p: usize = vs.cursor;
    var i: u32 = 0;
    while (i < cnt) : (i += 1) {
        switch (kind) {
            'f', 't' => {
                var q = p + 1;
                while (q < vs.len and vs.buf[q] != ch) q += 1;
                if (q < vs.len) p = if (kind == 't') q - 1 else q else break;
            },
            'F', 'T' => {
                if (p == 0) break;
                var q = p - 1;
                while (vs.buf[q] != ch) {
                    if (q == 0) { q = vs.len; break; }
                    q -= 1;
                }
                if (q < vs.len) p = if (kind == 'T') q + 1 else q else break;
            },
            else => {},
        }
    }
    return .{ .pos = p, .inclusive = (kind == 'f' or kind == 'F') };
}

fn reverseFindKind(kind: u8) u8 {
    return switch (kind) {
        'f' => 'F', 'F' => 'f',
        't' => 'T', 'T' => 't',
        else => kind,
    };
}

fn firstNonBlank(vs: *VimState) usize {
    var p: usize = 0;
    while (p < vs.len and vs.buf[p] == ' ') p += 1;
    return p;
}

/// Jump to the bracket that matches the one under the cursor.
fn motionMatchBracket(vs: *VimState) usize {
    if (vs.cursor >= vs.len) return vs.cursor;
    const ch = vs.buf[vs.cursor];

    const Pair = struct { open: u8, close: u8, forward: bool };
    const pair: Pair = switch (ch) {
        '(' => .{ .open = '(', .close = ')', .forward = true  },
        '[' => .{ .open = '[', .close = ']', .forward = true  },
        '{' => .{ .open = '{', .close = '}', .forward = true  },
        ')' => .{ .open = '(', .close = ')', .forward = false },
        ']' => .{ .open = '[', .close = ']', .forward = false },
        '}' => .{ .open = '{', .close = '}', .forward = false },
        else => return vs.cursor,
    };

    var depth: i32 = 0;

    if (pair.forward) {
        var p = vs.cursor;
        while (p < vs.len) : (p += 1) {
            if      (vs.buf[p] == pair.open)  { depth += 1; }
            else if (vs.buf[p] == pair.close) { depth -= 1; if (depth == 0) return p; }
        }
    } else {
        var p = vs.cursor;
        while (true) {
            if      (vs.buf[p] == pair.close) { depth += 1; }
            else if (vs.buf[p] == pair.open)  { depth -= 1; if (depth == 0) return p; }
            if (p == 0) break;
            p -= 1;
        }
    }
    return vs.cursor;
}

// ── Text object resolver ──────────────────────────────────────────────────────

fn resolveTextObject(vs: *VimState, kind: u8, delim: u8) ?MotionResult {
    const inner = (kind == 'i');
    return switch (delim) {
        'w'           => textObjWord(vs, false, inner),
        'W'           => textObjWord(vs, true,  inner),
        '"', '\'', '`' => textObjQuote(vs, delim, inner),
        '(', ')', 'b' => textObjBracket(vs, '(', ')', inner),
        '[', ']'       => textObjBracket(vs, '[', ']', inner),
        '{', '}', 'B'  => textObjBracket(vs, '{', '}', inner),
        '<', '>'       => textObjBracket(vs, '<', '>', inner),
        else           => null,
    };
}

fn textObjWord(vs: *VimState, big: bool, inner: bool) ?MotionResult {
    if (vs.len == 0) return null;
    var lo = vs.cursor;
    var hi = vs.cursor;

    const cls = charClass(big, vs.buf[vs.cursor]);
    if (cls != 0) {
        while (lo > 0 and charClass(big, vs.buf[lo - 1]) == cls) lo -= 1;
        while (hi < vs.len and charClass(big, vs.buf[hi]) == cls) hi += 1;
        if (!inner) {
            if (hi < vs.len and vs.buf[hi] == ' ') {
                while (hi < vs.len and vs.buf[hi] == ' ') hi += 1;
            } else {
                while (lo > 0 and vs.buf[lo - 1] == ' ') lo -= 1;
            }
        }
    } else {
        while (lo > 0 and vs.buf[lo - 1] == ' ') lo -= 1;
        while (hi < vs.len and vs.buf[hi]     == ' ') hi += 1;
    }

    if (lo >= hi) return null;
    return MotionResult{ .pos = hi, .inclusive = false, .from_override = lo };
}

fn textObjQuote(vs: *VimState, q: u8, inner: bool) ?MotionResult {
    var i: usize = 0;
    while (i < vs.len) {
        if (vs.buf[i] == q) {
            const start = i;
            i += 1;
            while (i < vs.len and vs.buf[i] != q) i += 1;
            if (i >= vs.len) break;
            const stop = i;
            i += 1;
            if (vs.cursor >= start and vs.cursor <= stop) {
                const lo: usize = if (inner) start + 1 else start;
                const hi: usize = if (inner) stop       else stop + 1;
                if (lo >= hi) return null;
                return MotionResult{ .pos = hi, .inclusive = false, .from_override = lo };
            }
        } else {
            i += 1;
        }
    }
    return null;
}

fn textObjBracket(vs: *VimState, open: u8, close: u8, inner: bool) ?MotionResult {
    var lo: ?usize = null;
    var depth: i32 = 0;
    var p = vs.cursor;
    while (true) {
        if      (vs.buf[p] == close) { depth += 1; }
        else if (vs.buf[p] == open)  {
            if (depth == 0) { lo = p; break; }
            depth -= 1;
        }
        if (p == 0) break;
        p -= 1;
    }
    const lv = lo orelse return null;

    var hi: ?usize = null;
    depth = 0;
    p = lv + 1;
    while (p < vs.len) : (p += 1) {
        if      (vs.buf[p] == open)  { depth += 1; }
        else if (vs.buf[p] == close) {
            if (depth == 0) { hi = p; break; }
            depth -= 1;
        }
    }
    const hv = hi orelse return null;

    if (inner) {
        if (lv + 1 >= hv) return null;
        return MotionResult{ .pos = hv,     .inclusive = false, .from_override = lv + 1 };
    } else {
        return MotionResult{ .pos = hv + 1, .inclusive = false, .from_override = lv };
    }
}

// ── Operator application ──────────────────────────────────────────────────────

fn doOp(vs: *VimState, op: u8, mr: MotionResult) void {
    var from: usize = undefined;
    var to:   usize = undefined;

    if (mr.from_override) |fo| {
        from = fo;
        to   = @min(mr.pos, vs.len);
    } else if (mr.pos >= vs.cursor) {
        from = vs.cursor;
        to   = @min(mr.pos + @as(usize, @intFromBool(mr.inclusive)), vs.len);
    } else {
        from = mr.pos;
        // For inclusive backward motions (e.g. dF, dB) the cursor character
        // is part of the range; add 1 and clamp to len.
        to   = @min(vs.cursor + @as(usize, @intFromBool(mr.inclusive)), vs.len);
    }

    if (from >= to) return;

    switch (op) {
        'd', 'c' => { undoPush(vs); yankRange(vs, from, to); deleteRange(vs, from, to); if (op == 'c') startInsertMode(vs); },
        'y' => { yankRange(vs, from, to); vs.cursor = from; },
        else => {},
    }
}

// ── Edit helpers ──────────────────────────────────────────────────────────────

/// Move cursor (normal mode: clamp to last valid position).
fn setCursor(vs: *VimState, mr: MotionResult) void {
    const max_pos: usize = if (vs.len > 0) vs.len - 1 else 0;
    vs.cursor = @min(mr.pos, max_pos);
}

fn insertChar(vs: *VimState, ch: u8) void { insertSlice(vs, &[1]u8{ch}); }

pub fn insertSlice(vs: *VimState, slice: []const u8) void {
    const n = @min(slice.len, MAX_INPUT - 1 - vs.len);
    if (n == 0) return;
    if (vs.cursor < vs.len) {
        std.mem.copyBackwards(u8,
            vs.buf[vs.cursor + n .. vs.len + n],
            vs.buf[vs.cursor     .. vs.len]);
    }
    @memcpy(vs.buf[vs.cursor .. vs.cursor + n], slice[0..n]);
    vs.len    += n;
    vs.cursor += n;
}

fn deleteBefore(vs: *VimState) void {
    if (vs.cursor == 0) return;
    vs.cursor -= 1;
    deleteAfter(vs);
}

fn deleteAfter(vs: *VimState) void {
    if (vs.cursor >= vs.len) return;
    std.mem.copyForwards(u8, vs.buf[vs.cursor .. vs.len - 1], vs.buf[vs.cursor + 1 .. vs.len]);
    vs.len -= 1;
}

fn deleteRange(vs: *VimState, from: usize, to: usize) void {
    if (from >= to or to > vs.len) return;
    const n = to - from;
    std.mem.copyForwards(u8, vs.buf[from .. vs.len - n], vs.buf[to .. vs.len]);
    vs.len    -= n;
    vs.cursor  = from;
    if (vs.mode == .normal and vs.len > 0 and vs.cursor >= vs.len)
        vs.cursor = vs.len - 1;
}

fn yankRange(vs: *VimState, from: usize, to: usize) void {
    if (from >= to or to > vs.len) return;
    const n = to - from;
    @memcpy(vs.yank_buf[0..n], vs.buf[from..to]);
    vs.yank_len = n;
}

fn pasteAfter(vs: *VimState) void {
    if (vs.yank_len == 0) return;
    if (vs.cursor < vs.len) vs.cursor += 1;
    insertSlice(vs, vs.yank_buf[0..vs.yank_len]);
}

fn pasteBefore(vs: *VimState) void {
    if (vs.yank_len == 0) return;
    insertSlice(vs, vs.yank_buf[0..vs.yank_len]);
}

fn toggleCaseOnce(vs: *VimState) void {
    if (vs.cursor >= vs.len) return;
    const ch = vs.buf[vs.cursor];
    vs.buf[vs.cursor] =
        if      (std.ascii.isLower(ch)) std.ascii.toUpper(ch)
        else if (std.ascii.isUpper(ch)) std.ascii.toLower(ch)
        else ch;
    if (vs.cursor + 1 < vs.len) vs.cursor += 1;
}

fn ctrlW(vs: *VimState) void {
    if (vs.cursor == 0) return;
    undoPush(vs);
    deleteRange(vs, motionWordPrev(vs, false, 1), vs.cursor);
}

fn ctrlU(vs: *VimState) void {
    if (vs.cursor == 0) return;
    undoPush(vs);
    yankRange(vs, 0, vs.cursor);
    deleteRange(vs, 0, vs.cursor);
}

/// Ctrl+A / Ctrl+X: find the nearest number at/after cursor and increment by delta.
fn ctrlAdjustNumber(vs: *VimState, delta: i64) void {
    if (vs.len == 0) return;

    var digit_pos = vs.cursor;
    while (digit_pos < vs.len and !std.ascii.isDigit(vs.buf[digit_pos])) digit_pos += 1;
    if (digit_pos >= vs.len) return;

    var num_start = digit_pos;
    if (num_start > 0 and vs.buf[num_start - 1] == '-') num_start -= 1;

    var num_end = digit_pos;
    while (num_end < vs.len and std.ascii.isDigit(vs.buf[num_end])) num_end += 1;

    const old_str = vs.buf[num_start..num_end];
    const old_val = std.fmt.parseInt(i64, old_str, 10) catch return;
    const cnt_val: i64 = @intCast(effCount(vs));
    const new_val = old_val + delta * cnt_val;

    var new_str_buf: [32]u8 = undefined;
    const new_str = std.fmt.bufPrint(&new_str_buf, "{}", .{new_val}) catch return;

    undoPush(vs);

    const old_len = num_end - num_start;
    const new_len = new_str.len;

    if (new_len > old_len) {
        const expand = new_len - old_len;
        if (vs.len + expand >= MAX_INPUT) return;
        std.mem.copyBackwards(u8, vs.buf[num_end + expand .. vs.len + expand], vs.buf[num_end .. vs.len]);
        vs.len += expand;
    } else if (new_len < old_len) {
        const shrink = old_len - new_len;
        std.mem.copyForwards(u8, vs.buf[num_start + new_len .. vs.len - shrink], vs.buf[num_end .. vs.len]);
        vs.len -= shrink;
    }

    @memcpy(vs.buf[num_start .. num_start + new_len], new_str);
    // num_start >= 0 and new_len >= 1 (any integer formats as at least "0"),
    // so num_start + new_len - 1 is always a valid non-negative index.
    vs.cursor = num_start + new_len - 1;
}

// ── Undo / redo ───────────────────────────────────────────────────────────────

/// Push the current buffer state onto the undo stack unconditionally.
/// If the stack is full, the oldest entry is dropped to make room.
/// Does NOT check in_dot_replay — callers are responsible for that guard.
fn undoPushRaw(vs: *VimState) void {
    if (vs.undo_top < UNDO_MAX) {
        const e = &vs.undo_stack[vs.undo_top];
        @memcpy(e.buf[0..vs.len], vs.buf[0..vs.len]);
        e.len = vs.len; e.cursor = vs.cursor;
        vs.undo_top += 1;
    } else {
        std.mem.copyForwards(UndoEntry, vs.undo_stack[0 .. UNDO_MAX - 1], vs.undo_stack[1..UNDO_MAX]);
        const e = &vs.undo_stack[UNDO_MAX - 1];
        @memcpy(e.buf[0..vs.len], vs.buf[0..vs.len]);
        e.len = vs.len; e.cursor = vs.cursor;
    }
}

fn undoPush(vs: *VimState) void {
    if (vs.in_dot_replay) return;
    undoPushRaw(vs);
    vs.redo_top = 0;
}

/// Save current state onto `stack[top.*]` and advance top (no overflow guard —
/// caller ensures there is room or uses the raw path).
inline fn stackSave(stack: []UndoEntry, top: *usize, vs: *VimState) void {
    if (top.* < UNDO_MAX) {
        const e = &stack[top.*];
        @memcpy(e.buf[0..vs.len], vs.buf[0..vs.len]);
        e.len = vs.len; e.cursor = vs.cursor;
        top.* += 1;
    }
}

fn undoUndo(vs: *VimState) void {
    if (vs.undo_top == 0) return;
    stackSave(&vs.redo_stack, &vs.redo_top, vs);
    vs.undo_top -= 1;
    const e = &vs.undo_stack[vs.undo_top];
    @memcpy(vs.buf[0..e.len], e.buf[0..e.len]);
    vs.len = e.len; vs.cursor = e.cursor;
}

fn undoRedo(vs: *VimState) void {
    if (vs.redo_top == 0) return;
    stackSave(&vs.undo_stack, &vs.undo_top, vs);
    vs.redo_top -= 1;
    const e = &vs.redo_stack[vs.redo_top];
    @memcpy(vs.buf[0..e.len], e.buf[0..e.len]);
    vs.len = e.len; vs.cursor = e.cursor;
}

// ── Dot repeat ────────────────────────────────────────────────────────────────

fn dotReplay(vs: *VimState) void {
    if (vs.dot.kind == .none) return;

    undoPushRaw(vs);
    vs.redo_top = 0;

    vs.in_dot_replay = true;
    defer vs.in_dot_replay = false;

    switch (vs.dot.kind) {
        .none => unreachable,

        .direct => {
            const cnt = vs.dot.direct_count;
            switch (vs.dot.direct_sym) {
                'x', 'X', 'D', 'C', 's' => {
                    const d = vs.dot.direct_sym;
                    const op: u8     = if (d == 'x' or d == 'X' or d == 'D') 'd' else 'c';
                    const pos: usize = switch (d) {
                        'X'      => charLeft(vs, cnt),
                        'D', 'C' => vs.len,
                        else     => charRight(vs, cnt), // x, s
                    };
                    doOp(vs, op, .{ .pos = pos });
                    if (op == 'c') insertSlice(vs, vs.dot.insert_buf[0..vs.dot.insert_len]);
                },
                'p', 'P' => { var i: u32 = 0; while (i < cnt) : (i += 1) { if (vs.dot.direct_sym == 'p') pasteAfter(vs) else pasteBefore(vs); } },
                '~' => { var i: u32 = 0; while (i < cnt) : (i += 1) toggleCaseOnce(vs); },
                'S' => {
                    yankRange(vs, 0, vs.len);
                    vs.len = 0; vs.cursor = 0;
                    insertSlice(vs, vs.dot.insert_buf[0..vs.dot.insert_len]);
                },
                'r' => {
                    const ch = vs.dot.direct_ch;
                    var i: usize = 0;
                    while (i < cnt and vs.cursor + i < vs.len) : (i += 1) vs.buf[vs.cursor + i] = ch;
                    vs.cursor = @min(vs.cursor + cnt - 1, vs.len -| 1);
                },
                else => {},
            }
        },

        .op_motion => {
            const cnt: u32 = resolveCount(vs.dot.op_count) * resolveCount(vs.dot.motion_count);

            const mr_opt: ?MotionResult =
                if (vs.dot.find_kind != 0)
                    motionFind(vs, vs.dot.find_kind, vs.dot.find_ch, cnt)
                else if (vs.dot.tobj_kind != 0)
                    resolveTextObject(vs, vs.dot.tobj_kind, vs.dot.tobj_delim)
                else if (vs.dot.g_prefix) blk: {
                    break :blk switch (vs.dot.motion_sym) {
                        'e'  => MotionResult{ .pos = motionWordEndBack(vs, false, cnt), .inclusive = true },
                        'E'  => MotionResult{ .pos = motionWordEndBack(vs, true,  cnt), .inclusive = true },
                        else => null,
                    };
                } else resolveSimpleMotion(vs, vs.dot.motion_sym, cnt);

            if (mr_opt) |mr| {
                doOp(vs, vs.dot.op, mr);
                if (vs.dot.op == 'c')
                    insertSlice(vs, vs.dot.insert_buf[0..vs.dot.insert_len]);
            }
        },

        .op_line => {
            doOp(vs, vs.dot.op, .{ .pos = vs.len, .from_override = 0 });
            if (vs.dot.op == 'c')
                insertSlice(vs, vs.dot.insert_buf[0..vs.dot.insert_len]);
        },

        .insert_session => {
            insertSlice(vs, vs.dot.insert_buf[0..vs.dot.insert_len]);
        },
    }
}

// ── Normal-mode sub-state helpers ─────────────────────────────────────────────

/// Treat a count of 0 as 1 (vim convention: no count = repeat once).
inline fn resolveCount(n: u32) u32 { return if (n == 0) 1 else n; }

fn effCount(vs: *VimState) u32 {
    return resolveCount(vs.n_count) * resolveCount(vs.n_op_count);
}
