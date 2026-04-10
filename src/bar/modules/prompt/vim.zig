//! vim — modal editing engine for the prompt segment.
//!
//! Implements a vim-style modal editing layer over a single-line text buffer.
//! All state is contained in `VimState`.  Buffers are heap-allocated; create
//! and destroy instances with `VimState.init` / `VimState.deinit`:
//!
//!   var vs = try VimState.init(allocator, 512, 32);
//!   defer vs.deinit();
//!
//! The four mode handlers each return an `Action` value so the caller can
//! react without a circular dependency:
//!
//!   .none       — nothing special; caller should just redraw
//!   .deactivate — user pressed Escape / Ctrl+C to close
//!   .spawn      — user pressed Return; execute buf[0..len] and close
//!
//! Typical integration in a key-press handler:
//!
//!   const action = switch (vs.mode) {
//!       .insert  => vim.handleInsert(&vs, sym),
//!       .normal  => vim.handleNormal(&vs, sym),
//!       .visual  => vim.handleVisual(&vs, sym),
//!       .replace => vim.handleReplace(&vs, sym),
//!   };
//!   switch (action) {
//!       .none       => {},
//!       .deactivate => ...,
//!       .spawn      => { runCmd(vs.buf[0..vs.len]); ... },
//!   }
//!
//! Ctrl-modified keys should be pre-handled and routed to `handleCtrl()`.

const std  = @import("std");
const core = @import("core");
const xcb  = core.xcb;

// Re-exported keysyms (convenience for callers)

pub const XK_BackSpace = core.XK_BackSpace;
pub const XK_Tab       = core.XK_Tab;
pub const XK_Return    = core.XK_Return;
pub const XK_Escape    = core.XK_Escape;
pub const XK_Delete    = core.XK_Delete;
pub const XK_Left      = core.XK_Left;
pub const XK_Right     = core.XK_Right;
pub const XK_Home      = core.XK_Home;
pub const XK_End       = core.XK_End;

// Public constants

pub const default_max_input: usize = 512;
pub const default_undo_max:  usize = 32;
/// Number of named marks supported (a–z).
pub const mark_count: usize = 26;

// Public enums and types

/// What the caller should do after handling a key.
///
///   .none        — nothing special; caller should just redraw
///   .deactivate  — close the prompt without executing (`:q`, Escape, Ctrl+C)
///   .spawn       — execute buf[0..len] and close the prompt (Return, `:wq`, `:x`)
///   .spawn_keep  — execute buf[0..len] but keep the prompt open (`:w`)
pub const Action = enum { none, deactivate, spawn, spawn_keep };

/// Editing modes, reflected live in the mode label.
/// The integer value is the index into the cached mode-width array in prompt.zig.
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

/// What the last committed change was — used by `.` to replay it.
pub const DotKind = enum { none, direct, op_motion, op_line, insert_session };

/// Record of the last atomic change for `.` repeat.
///
/// `dot_insert_buf` / `dot_insert_len` live directly on `VimState` (see
/// below) so that the allocation is not lost when `vs.dot` is overwritten
/// with a union literal.
pub const DotRecord = union(DotKind) {
    none: void,
    direct: struct {
        sym:          xcb.xcb_keysym_t = 0,
        count:        u32              = 1,
        replace_char: u8               = 0,   // used by 'r'
    },
    op_motion: struct {
        op:           u8               = 0,
        op_count:     u32              = 1,
        motion_sym:   xcb.xcb_keysym_t = 0,
        motion_count: u32              = 1,
        has_g_prefix: bool             = false, // ge / gE
        find_kind:    u8               = 0,     // f/F/t/T motion (0 = none)
        find_ch:      u8               = 0,
        tobj_kind:    u8               = 0,
        tobj_delim:   u8               = 0,
    },
    op_line: struct {
        op:           u8  = 0,
        op_count:     u32 = 1,
        motion_count: u32 = 1,
    },
    insert_session: void,
};

/// Result returned by motion functions.
///
/// `pos`                — destination cursor position.
/// `inclusive`          — when true the char at `pos` is included in operator ranges.
/// `range_start_override` — when set (text objects), this is the range start
///                          instead of the cursor.
pub const MotionResult = struct {
    pos:                  usize,
    inclusive:            bool   = false,
    range_start_override: ?usize = null,
};

/// A single undo/redo snapshot.
pub const UndoEntry = struct {
    buf:    []u8  = &.{},
    len:    usize = 0,
    cursor: usize = 0,
};

/// A fixed-capacity ring-buffer stack of `UndoEntry` snapshots.
///
/// `entries` is a heap-allocated slice (length = capacity).
/// `top`     is the number of valid entries currently stored.
/// `base`    is the index of the oldest entry (advances when the ring is full).
pub const RingStack = struct {
    entries: []UndoEntry = &.{},
    top:     usize       = 0,
    base:    usize       = 0,
};

// Internal types

/// Accumulated state for the in-progress normal-mode command.
/// Reset atomically between commands via `resetPendingCmd`.
const PendingCmd = struct {
    count:                 u32  = 0,   // digit accumulator
    op:                    u8   = 0,   // pending operator ('d'/'c'/'y')
    op_count:              u32  = 0,   // count when operator was armed
    find_kind:             u8   = 0,   // pending f/F/t/T target (0 = none)
    /// True after 'r' is pressed; the next printable char replaces `count` chars.
    is_awaiting_replace_char: bool = false,
    /// True after 'g' is pressed; the next key completes a g-prefix motion.
    is_g_prefix_active:       bool = false,
    /// The 'i' or 'a' pressed before a text-object delimiter (0 = none).
    text_obj_prefix:          u8   = 0,
    /// True after 'm' is pressed; the next letter names the mark to set.
    is_awaiting_mark_set:     bool = false,
    /// True after `'` is pressed; the next letter names the mark to jump to.
    is_awaiting_mark_jump:    bool = false,
    /// True after ':' is pressed; subsequent keys build the ex command.
    /// Recognised commands: w (spawn_keep), q (deactivate), wq (spawn), x (spawn).
    is_colon_cmd: bool  = false,
    colon_buf:    [4]u8 = .{ 0, 0, 0, 0 },
    colon_len:    u8    = 0,
};

// Public state type

/// All state for the vim editing engine.
/// Create with `VimState.init` and release with `VimState.deinit`.
pub const VimState = struct {
    allocator: std.mem.Allocator = undefined,
    max_input: usize             = 0,
    undo_max:  usize             = 0,

    buf:    []u8  = &.{},
    len:    usize = 0,
    cursor: usize = 0,
    mode:   Mode  = .insert,

    pending: PendingCmd = .{},

    last_find_kind: u8 = 0,
    last_find_ch:   u8 = 0,

    yank_buf: []u8  = &.{},
    yank_len: usize = 0,

    visual_anchor: usize = 0,

    replace_origin_buf: []u8  = &.{},
    replace_origin_len: usize = 0,
    /// Cursor position at the moment 'R' was pressed; used by BackSpace to
    /// prevent retreating before the entry point.
    replace_origin_cursor: usize = 0,

    marks: [mark_count]?usize = [_]?usize{null} ** mark_count,

    undo: RingStack = .{},
    redo: RingStack = .{},

    dot:              DotRecord = .none,
    /// Survives `vs.dot = .none` assignments so the allocation is never leaked
    /// when the dot record is overwritten with a new union literal.
    dot_insert_buf:   []u8  = &.{},
    dot_insert_len:   usize = 0,
    is_replaying_dot: bool  = false,
    is_recording_insert: bool = false,
    insert_rec_buf:   []u8  = &.{},
    insert_rec_len:   usize = 0,

    /// Allocate all buffers.  `max_input` is the maximum text length (bytes);
    /// `undo_max` is the depth of each undo and redo ring stack.
    pub fn init(
        allocator: std.mem.Allocator,
        max_input: usize,
        undo_max:  usize,
    ) !VimState {
        var vs = VimState{
            .allocator = allocator,
            .max_input = max_input,
            .undo_max  = undo_max,
        };
        vs.buf                = try allocator.alloc(u8, max_input);
        vs.yank_buf           = try allocator.alloc(u8, max_input);
        vs.replace_origin_buf = try allocator.alloc(u8, max_input);
        vs.insert_rec_buf     = try allocator.alloc(u8, max_input);
        vs.dot_insert_buf     = try allocator.alloc(u8, max_input);
        vs.undo.entries       = try allocator.alloc(UndoEntry, undo_max);
        vs.redo.entries       = try allocator.alloc(UndoEntry, undo_max);
        for (vs.undo.entries) |*e| e.buf = try allocator.alloc(u8, max_input);
        for (vs.redo.entries) |*e| e.buf = try allocator.alloc(u8, max_input);
        return vs;
    }

    /// Free all heap buffers.  The `VimState` must not be used after this call.
    pub fn deinit(vs: *VimState) void {
        for (vs.undo.entries) |*e| vs.allocator.free(e.buf);
        vs.allocator.free(vs.undo.entries);
        for (vs.redo.entries) |*e| vs.allocator.free(e.buf);
        vs.allocator.free(vs.redo.entries);
        vs.allocator.free(vs.dot_insert_buf);
        vs.allocator.free(vs.insert_rec_buf);
        vs.allocator.free(vs.replace_origin_buf);
        vs.allocator.free(vs.yank_buf);
        vs.allocator.free(vs.buf);
        vs.* = .{}; // poison all fields
    }
};

// Public helpers

/// Reset all in-progress command state (counts, pending operators, prefix flags).
pub fn resetPendingCmd(vs: *VimState) void { vs.pending = .{}; }

/// Enter INSERT mode.  `push_undo` = true for standalone commands (i/a/I/A/S);
/// false for c-operators that already pushed an undo snapshot before deleting.
pub fn enterInsert(vs: *VimState, push_undo: bool) void {
    if (!vs.is_replaying_dot) {
        if (push_undo) undoPush(vs);
        vs.insert_rec_len    = 0;
        vs.is_recording_insert = true;
    }
    vs.mode = .insert;
}

/// Return `[lo, hi)` covering the visual selection (exclusive upper bound).
pub fn visualRange(vs: *VimState) [2]usize {
    const lo = @min(vs.visual_anchor, vs.cursor);
    const hi = @min(@max(vs.visual_anchor, vs.cursor) + 1, vs.len);
    return .{ lo, hi };
}

/// Returns the ex-command characters typed so far after `:` in normal mode,
/// or null when the prompt is not in colon-command mode.
/// The returned slice aliases internal `PendingCmd` storage and is valid only
/// until the next call that mutates `VimState`.
pub fn colonInput(vs: *const VimState) ?[]const u8 {
    if (!vs.pending.is_colon_cmd) return null;
    return vs.pending.colon_buf[0..vs.pending.colon_len];
}

pub fn insertSlice(vs: *VimState, slice: []const u8) void {
    const n = @min(slice.len, vs.max_input - 1 - vs.len);
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

// Public mode handlers

/// Handle a Ctrl-modified key.  Call this before dispatching to mode handlers.
/// Returns `.deactivate` for Ctrl+C; `.none` for all others (mutations applied
/// in-place).
pub fn handleCtrl(vs: *VimState, sym: xcb.xcb_keysym_t) Action {
    switch (sym) {
        'c' => return .deactivate,
        'r' => if (vs.mode == .normal or vs.mode == .visual)
            applyHistoryStep(vs, &vs.redo, &vs.undo),
        'w' => if (vs.mode == .insert) ctrlW(vs),
        'u' => if (vs.mode == .insert) ctrlU(vs),
        'a' => if (vs.mode == .normal) { ctrlAdjustNumber(vs, 1);  resetPendingCmd(vs); },
        'x' => if (vs.mode == .normal) { ctrlAdjustNumber(vs, -1); resetPendingCmd(vs); },
        else => {},
    }
    return .none;
}

/// Handles a key press in insert mode. Returns the Action the caller should take.
pub fn handleInsert(vs: *VimState, sym: xcb.xcb_keysym_t) Action {
    switch (sym) {
        XK_Escape => {
            // Finalise dot record insert text.
            if (vs.is_recording_insert) {
                vs.is_recording_insert = false;
                @memcpy(vs.dot_insert_buf[0..vs.insert_rec_len], vs.insert_rec_buf[0..vs.insert_rec_len]);
                vs.dot_insert_len = vs.insert_rec_len;
            }
            clampCursorForNormal(vs);
            vs.mode = .normal;
            resetPendingCmd(vs);
        },

        XK_Return => return .spawn,

        XK_BackSpace => deleteBefore(vs),
        XK_Delete    => deleteAfter(vs),
        XK_Left      => { if (vs.cursor > 0)       vs.cursor -= 1; },
        XK_Right     => { if (vs.cursor < vs.len)  vs.cursor += 1; },
        XK_Home      => vs.cursor = 0,
        XK_End       => vs.cursor = vs.len,

        else => {
            if (sym >= 0x20 and sym <= 0x7e) {
                const ch: u8 = @truncate(sym);
                insertSlice(vs, &[1]u8{ch});
                // Record for dot repeat.
                if (vs.is_recording_insert and vs.insert_rec_len < vs.max_input - 1) {
                    vs.insert_rec_buf[vs.insert_rec_len] = ch;
                    vs.insert_rec_len += 1;
                }
            }
        },
    }
    return .none;
}

/// Handles a key press in normal mode. Returns the Action the caller should take.
pub fn handleNormal(vs: *VimState, sym: xcb.xcb_keysym_t) Action {
    // Pending r{c}: replace `count` chars with a single character.
    if (vs.pending.is_awaiting_replace_char) {
        if (sym >= 0x20 and sym <= 0x7e and vs.cursor < vs.len) {
            const ch: u8   = @truncate(sym);
            const cnt: u32 = effectiveCount(vs);
            vs.dot = .{ .direct = .{ .sym = 'r', .count = cnt, .replace_char = ch } };
            undoPush(vs);
            var i: usize = 0;
            while (i < cnt and vs.cursor + i < vs.len) : (i += 1) vs.buf[vs.cursor + i] = ch;
            vs.cursor = @min(vs.cursor + cnt - 1, vs.len -| 1);
        }
        resetPendingCmd(vs);
        return .none;
    }

    // Colon ex-command mode: :w  -> spawn_keep (execute, keep open)
    //                         :q  -> deactivate (cancel)
    //                         :wq -> spawn      (execute, close)
    //                         :x  -> spawn      (execute, close)
    // Escape cancels; any unrecognised command is silently discarded.
    if (vs.pending.is_colon_cmd) {
        switch (sym) {
            XK_Escape => {
                resetPendingCmd(vs);
                return .none;
            },
            XK_BackSpace => {
                if (vs.pending.colon_len > 0) {
                    vs.pending.colon_len -= 1;
                } else {
                    resetPendingCmd(vs); // nothing typed -> cancel back to normal
                }
                return .none;
            },
            XK_Return => {
                // Copy command bytes locally before resetPendingCmd zeroes colon_buf.
                var cmd_buf: [4]u8 = vs.pending.colon_buf;
                const cmd_len: u8  = vs.pending.colon_len;
                const cmd = cmd_buf[0..cmd_len];
                resetPendingCmd(vs);
                if (std.mem.eql(u8, cmd, "q"))  return .deactivate;
                if (std.mem.eql(u8, cmd, "w"))  return .spawn_keep;
                if (std.mem.eql(u8, cmd, "wq")) return .spawn;
                if (std.mem.eql(u8, cmd, "x"))  return .spawn;
                return .none;
            },
            else => {
                if (sym >= 0x20 and sym <= 0x7e and vs.pending.colon_len < vs.pending.colon_buf.len) {
                    vs.pending.colon_buf[vs.pending.colon_len] = @truncate(sym);
                    vs.pending.colon_len += 1;
                }
                return .none;
            },
        }
    }

    // ':' with no pending operator arms colon command mode.
    if (sym == ':' and vs.pending.op == 0) {
        vs.pending.is_colon_cmd = true;
        vs.pending.colon_len    = 0;
        return .none;
    }


    if (resolveMotionKey(vs, sym)) |mkr| {
        switch (mkr) {
            .consumed => return .none,
            .motion   => |m| {
                if (m.op == 0) { setCursor(vs, m.mr); return .none; }
                if (m.dot_eligible) vs.dot = .{ .op_motion = .{
                    .op           = m.op,
                    .op_count     = m.op_count,
                    .motion_count = m.motion_count,
                    .motion_sym   = if (m.find_kind != 0) 0 else @truncate(sym),
                    .find_kind    = m.find_kind,
                    .find_ch      = m.find_ch,
                    .has_g_prefix = m.has_g_prefix,
                }};
                applyOperator(vs, m.op, m.mr);
                return .none;
            },
        }
    }

    // Normal-mode-specific pending states (only reachable when resolveMotionKey
    // bailed out because one of these flags was set).
    if (vs.pending.text_obj_prefix != 0) {
        if (sym >= 0x20 and sym <= 0x7e) {
            const ch: u8 = @truncate(sym);
            if (resolveTextObject(vs, vs.pending.text_obj_prefix, ch)) |mr| {
                vs.dot = buildOpMotionRecord(vs, 0);
                vs.dot.op_motion.tobj_kind  = vs.pending.text_obj_prefix;
                vs.dot.op_motion.tobj_delim = ch;
                applyOperator(vs, vs.pending.op, mr);
            }
        }
        resetPendingCmd(vs);
        return .none;
    }
    if (vs.pending.is_awaiting_mark_set) {
        if (sym >= 'a' and sym <= 'z')
            vs.marks[@as(usize, @intCast(sym - 'a'))] = vs.cursor;
        resetPendingCmd(vs);
        return .none;
    }
    if (vs.pending.is_awaiting_mark_jump) {
        if (sym >= 'a' and sym <= 'z') {
            if (vs.marks[@as(usize, @intCast(sym - 'a'))]) |pos| {
                const mr = MotionResult{ .pos = pos };
                if (vs.pending.op != 0) applyOperator(vs, vs.pending.op, mr) else setCursor(vs, mr);
            }
        }
        resetPendingCmd(vs);
        return .none;
    }

    const cnt = effectiveCount(vs);

    // Operator arming (d/c/y) and doubled-operator line commands (dd/cc/yy).
    if (sym == 'd' or sym == 'c' or sym == 'y') {
        const op: u8 = @truncate(sym);
        if (vs.pending.op == 0) {
            vs.pending.op       = op;
            vs.pending.op_count = vs.pending.count;
            vs.pending.count    = 0;
            return .none;
        }
        if (vs.pending.op == op) {
            vs.dot = .{ .op_line = .{ .op = op, .op_count = vs.pending.op_count, .motion_count = vs.pending.count } };
            applyOperator(vs, op, .{ .pos = vs.len, .range_start_override = 0 });
        }
        resetPendingCmd(vs);
        return .none;
    }

    // i/a after an operator arms the text-object resolver.
    if ((sym == 'i' or sym == 'a') and vs.pending.op != 0) {
        vs.pending.text_obj_prefix = @truncate(sym);
        return .none;
    }

    // r/m/' prefix arming (single-char targets; not consumed by resolveMotionKey).
    if (sym == 'r'    and vs.pending.op == 0) { vs.pending.is_awaiting_replace_char = true; return .none; }
    if (sym == 'm'    and vs.pending.op == 0) { vs.pending.is_awaiting_mark_set     = true; return .none; }
    if (sym == 0x27)                          { vs.pending.is_awaiting_mark_jump    = true; return .none; } // '

    switch (sym) {

        XK_Escape => {
            const act: Action = if (vs.pending.op == 0 and vs.pending.count == 0) .deactivate else .none;
            resetPendingCmd(vs);
            return act;
        },

        XK_Return => {
            resetPendingCmd(vs);
            return .spawn;
        },

        'x', 'X', 'D', 'C', 's' => {
            vs.dot = .{ .direct = .{ .sym = @truncate(sym), .count = cnt } };
            _ = execDirectSym(vs, @truncate(sym), cnt);
        },

        'p', 'P' => {
            if (vs.yank_len > 0) {
                vs.dot = .{ .direct = .{ .sym = @truncate(sym), .count = cnt } };
                undoPush(vs);
                var i: u32 = 0;
                while (i < cnt) : (i += 1) { if (sym == 'p') pasteAfter(vs) else pasteBefore(vs); }
            }
        },

        '~' => {
            vs.dot = .{ .direct = .{ .sym = '~', .count = cnt } };
            undoPush(vs);
            var i: u32 = 0;
            while (i < cnt) : (i += 1) toggleCaseOnce(vs);
        },

        'S' => {
            vs.dot = .{ .direct = .{ .sym = 'S', .count = cnt } };
            undoPush(vs);
            yankRange(vs, 0, vs.len);
            vs.len    = 0;
            vs.cursor = 0;
            enterInsert(vs, false);
        },

        'i', 'I', 'a', 'A' => {
            vs.cursor = switch (sym) {
                'I'  => firstNonBlank(vs),
                'a'  => @min(vs.cursor + 1, vs.len),
                'A'  => vs.len,
                else => vs.cursor,
            };
            vs.dot = .insert_session;
            enterInsert(vs, true);
        },

        'v' => {
            vs.visual_anchor = vs.cursor;
            vs.mode = .visual;
            resetPendingCmd(vs);
            return .none;
        },

        'R' => {
            undoPush(vs);
            @memcpy(vs.replace_origin_buf[0..vs.len], vs.buf[0..vs.len]);
            vs.replace_origin_len    = vs.len;
            vs.replace_origin_cursor = vs.cursor;
            vs.mode = .replace;
            resetPendingCmd(vs);
            return .none;
        },

        '%' => {
            const pos = motionMatchBracket(vs);
            if (vs.pending.op != 0) {
                vs.dot = buildOpMotionRecord(vs, '%');
                applyOperator(vs, vs.pending.op, MotionResult{ .pos = pos, .inclusive = true });
            } else {
                setCursor(vs, MotionResult{ .pos = pos });
            }
        },

        'u' => applyHistoryStep(vs, &vs.undo, &vs.redo),
        '.' => { replayDot(vs); resetPendingCmd(vs); return .none; },

        else => {},
    }

    resetPendingCmd(vs);
    return .none;
}

/// Handles a key press in visual mode. Returns the Action the caller should take.
pub fn handleVisual(vs: *VimState, sym: xcb.xcb_keysym_t) Action {
    // Shared: pending find/g, digits, ;/,, simple motions, prefix arming.
    if (resolveMotionKey(vs, sym)) |mkr| {
        switch (mkr) {
            .consumed => return .none,
            .motion   => |m| { setCursor(vs, m.mr); return .none; },
        }
    }

    switch (sym) {

        XK_Escape, 'v' => exitVisual(vs),

        XK_Return => {
            resetPendingCmd(vs);
            return .spawn;
        },

        'd', 'x', 'c' => {
            const sel = visualRange(vs);
            vs.dot = .{ .op_line = .{ .op = if (sym == 'c') @as(u8, 'c') else @as(u8, 'd') } };
            undoPush(vs);
            yankRange(vs, sel[0], sel[1]);
            deleteRange(vs, sel[0], sel[1]);
            exitVisual(vs);
            if (sym == 'c') enterInsert(vs, false);
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

        else => resetPendingCmd(vs),
    }
    return .none;
}

/// Handles a key press in replace mode. Returns the Action the caller should take.
pub fn handleReplace(vs: *VimState, sym: xcb.xcb_keysym_t) Action {
    switch (sym) {
        XK_Escape => {
            clampCursorForNormal(vs);
            vs.mode = .normal;
        },

        XK_Return => return .spawn,

        XK_BackSpace => blk: {
            if (vs.cursor <= vs.replace_origin_cursor) break :blk;
            vs.cursor -= 1;
            if (vs.cursor < vs.replace_origin_len) {
                vs.buf[vs.cursor] = vs.replace_origin_buf[vs.cursor];
            } else {
                if (vs.cursor < vs.len - 1) {
                    std.mem.copyForwards(u8, vs.buf[vs.cursor .. vs.len - 1], vs.buf[vs.cursor + 1 .. vs.len]);
                }
                vs.len -= 1;
            }
        },

        else => blk: {
            if (sym < 0x20 or sym > 0x7e) break :blk;
            const ch: u8 = @truncate(sym);
            if (vs.cursor < vs.len) {
                vs.buf[vs.cursor] = ch;
                vs.cursor += 1;
            } else if (vs.len < vs.max_input - 1) {
                vs.buf[vs.len] = ch;
                vs.len    += 1;
                vs.cursor += 1;
            }
        },
    }
    return .none;
}

// Private — normal-mode motion resolution

/// Clamp cursor to the last valid position for normal mode.
/// In normal mode the cursor must sit on a character, not past the end.
inline fn clampCursorForNormal(vs: *VimState) void {
    if (vs.len > 0 and vs.cursor == vs.len) vs.cursor = vs.len - 1;
}

inline fn exitVisual(vs: *VimState) void { vs.mode = .normal; resetPendingCmd(vs); }

/// Digit accumulation helper: returns true and updates `pending.count` if
/// `sym` is a digit (1–9 always; 0 only when count is already non-zero).
/// Counts are clamped at 1_000_000 — the vim convention — so an accidental
/// run of digits never wraps silently to a small, unexpected repeat count.
fn tryAccumulateDigit(vs: *VimState, sym: xcb.xcb_keysym_t) bool {
    if (sym >= '1' and sym <= '9') {
        const next = vs.pending.count *% 10 +% @as(u32, @truncate(sym - '0'));
        vs.pending.count = @min(next, 1_000_000);
        return true;
    }
    if (sym == '0' and vs.pending.count > 0) {
        vs.pending.count = @min(vs.pending.count *% 10, 1_000_000);
        return true;
    }
    return false;
}

/// Arms f/F/t/T or the g prefix; returns true if `sym` was consumed.
fn tryArmFindPrefix(vs: *VimState, sym: xcb.xcb_keysym_t) bool {
    if (sym == 'g') { vs.pending.is_g_prefix_active = true; return true; }
    if (sym == 'f' or sym == 'F' or sym == 't' or sym == 'T') {
        vs.pending.find_kind = @truncate(sym);
        return true;
    }
    return false;
}

/// Position resolver for g-prefix motions (ge, gE, gg, g0, g$).
/// Returns the destination position, or null for unrecognised symbols.
fn resolveGPrefixPos(vs: *VimState, sym: xcb.xcb_keysym_t, cnt: u32) ?usize {
    return switch (sym) {
        'e'                => motionWordEndBackward(vs, false, cnt),
        'E'                => motionWordEndBackward(vs, true,  cnt),
        'g', '0', XK_Home => @as(usize, 0),
        '$', XK_End        => vs.len,
        else               => null,
    };
}

/// Result returned by `resolveMotionKey`.
const MotionKeyResult = union(enum) {
    /// Digit accumulated or prefix flag set; `pending` not reset; caller returns `.none`.
    consumed: void,
    /// A motion was produced; `pending` has already been reset.
    /// The captured op fields enable dot-record construction without reading `pending`.
    /// `dot_eligible` is false for `;`/`,` repeats, which do not update the dot record.
    motion: struct {
        mr:           MotionResult,
        op:           u8   = 0,
        op_count:     u32  = 0,
        motion_count: u32  = 0,
        find_kind:    u8   = 0,
        find_ch:      u8   = 0,
        has_g_prefix: bool = false,
        dot_eligible: bool = true,
    },
};

/// Shared motion-key resolution for normal and visual mode.
/// Handles: pending find, pending g, digit accumulation, ;/,, simple motions,
/// and prefix arming (f/F/t/T/g).
///
/// Returns `.motion` if a motion was resolved (`pending` already reset; caller
/// applies the result then returns `.none`), `.consumed` if the key was
/// absorbed without producing a motion (digit or prefix arm; `pending` not
/// reset), or null if the key was not handled (normal-mode-specific pending
/// state active, or unrecognised).
fn resolveMotionKey(vs: *VimState, sym: xcb.xcb_keysym_t) ?MotionKeyResult {
    // Pending find char.
    if (vs.pending.find_kind != 0) {
        if (sym >= 0x20 and sym <= 0x7e) {
            const ch: u8 = @truncate(sym);
            const cnt    = effectiveCount(vs);
            const kind   = vs.pending.find_kind;
            vs.last_find_kind = kind;
            vs.last_find_ch   = ch;
            const mr = motionFind(vs, kind, ch, cnt);
            const op = vs.pending.op; const opc = vs.pending.op_count; const mc = vs.pending.count;
            resetPendingCmd(vs);
            return .{ .motion = .{ .mr = mr, .op = op, .op_count = opc, .motion_count = mc,
                .find_kind = kind, .find_ch = ch } };
        }
        resetPendingCmd(vs);
        return .consumed;
    }

    // Pending g-prefix.
    if (vs.pending.is_g_prefix_active) {
        const cnt = effectiveCount(vs);
        if (resolveGPrefixPos(vs, sym, cnt)) |pos| {
            const mr = MotionResult{ .pos = pos, .inclusive = (sym == 'e' or sym == 'E') };
            const op = vs.pending.op; const opc = vs.pending.op_count; const mc = vs.pending.count;
            resetPendingCmd(vs);
            return .{ .motion = .{ .mr = mr, .op = op, .op_count = opc, .motion_count = mc,
                .has_g_prefix = true } };
        }
        resetPendingCmd(vs);
        return .consumed;
    }

    // Bail out so handleNormal can service its own pending states (text-object,
    // mark set/jump) before we consume digits or simple motions.
    if (vs.pending.text_obj_prefix != 0 or
        vs.pending.is_awaiting_mark_set  or
        vs.pending.is_awaiting_mark_jump) return null;

    // Digit accumulation.
    if (tryAccumulateDigit(vs, sym)) return .consumed;

    const cnt = effectiveCount(vs);

    // ;/, — repeat last find.  Does not update the dot record.
    if (sym == ';' or sym == ',') {
        if (vs.last_find_kind != 0) {
            const kind = if (sym == ',') reverseFindKind(vs.last_find_kind) else vs.last_find_kind;
            const mr   = motionFind(vs, kind, vs.last_find_ch, cnt);
            const op = vs.pending.op; const opc = vs.pending.op_count; const mc = vs.pending.count;
            resetPendingCmd(vs);
            return .{ .motion = .{ .mr = mr, .op = op, .op_count = opc, .motion_count = mc,
                .dot_eligible = false } };
        }
        resetPendingCmd(vs);
        return .consumed;
    }

    // Simple motions (h/l/w/b/e/0/^/$/arrows …).
    if (resolveSimpleMotion(vs, sym, cnt)) |mr| {
        const op = vs.pending.op; const opc = vs.pending.op_count; const mc = vs.pending.count;
        resetPendingCmd(vs);
        return .{ .motion = .{ .mr = mr, .op = op, .op_count = opc, .motion_count = mc } };
    }

    // Prefix arming (f/F/t/T/g).
    if (tryArmFindPrefix(vs, sym)) return .consumed;

    return null;
}

fn resolveSimpleMotion(vs: *VimState, sym: xcb.xcb_keysym_t, cnt: u32) ?MotionResult {
    return switch (sym) {
        'h', XK_Left  => MotionResult{ .pos = vs.cursor -| @as(usize, cnt)                },
        'l', XK_Right => MotionResult{ .pos = @min(vs.cursor + @as(usize, cnt), vs.len)   },
        'w'           => MotionResult{ .pos = motionWordNext(vs, false, cnt)  },
        'W'           => MotionResult{ .pos = motionWordNext(vs, true,  cnt)  },
        'b'           => MotionResult{ .pos = motionWordPrev(vs, false, cnt)  },
        'B'           => MotionResult{ .pos = motionWordPrev(vs, true,  cnt)  },
        'e'           => MotionResult{ .pos = motionWordEnd(vs, false, cnt),     .inclusive = true },
        'E'           => MotionResult{ .pos = motionWordEnd(vs, true,  cnt),     .inclusive = true },
        '0', XK_Home  => MotionResult{ .pos = 0                               },
        '^'           => MotionResult{ .pos = firstNonBlank(vs)               },
        '$', XK_End   => MotionResult{ .pos = vs.len                          },
        else          => null,
    };
}

// Private — text operations

/// Move cursor (normal mode: clamp to last valid position).
fn setCursor(vs: *VimState, mr: MotionResult) void {
    const max_pos: usize = if (vs.len > 0) vs.len - 1 else 0;
    vs.cursor = @min(mr.pos, max_pos);
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

/// Ctrl+A / Ctrl+X: find the nearest number at/after cursor and increment by `delta`.
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
    const cnt_val: i64 = @intCast(effectiveCount(vs));
    const new_val = old_val + delta * cnt_val;

    var new_str_buf: [32]u8 = undefined;
    const new_str = std.fmt.bufPrint(&new_str_buf, "{}", .{new_val}) catch return;

    undoPush(vs);

    const old_len = num_end - num_start;
    const new_len = new_str.len;

    if (new_len > old_len) {
        const expand = new_len - old_len;
        if (vs.len + expand >= vs.max_input) return;
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

/// Apply an operator to the range described by `mr`.
fn applyOperator(vs: *VimState, op: u8, mr: MotionResult) void {
    var from: usize = undefined;
    var to:   usize = undefined;

    if (mr.range_start_override) |rso| {
        from = rso;
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
        'd', 'c' => { undoPush(vs); yankRange(vs, from, to); deleteRange(vs, from, to); if (op == 'c') enterInsert(vs, false); },
        'y'      => { yankRange(vs, from, to); vs.cursor = from; },
        else     => {},
    }
}

/// Shared implementation for x/X/D/C/s commands.  Returns the operator used
/// ('d' or 'c') so callers can decide whether to replay insert text.
fn execDirectSym(vs: *VimState, sym: u8, cnt: u32) u8 {
    const op: u8     = if (sym == 'x' or sym == 'X' or sym == 'D') 'd' else 'c';
    const pos: usize = switch (sym) {
        'X'      => vs.cursor -| @as(usize, cnt),
        'D', 'C' => vs.len,
        else     => @min(vs.cursor + @as(usize, cnt), vs.len), // x, s
    };
    applyOperator(vs, op, .{ .pos = pos });
    return op;
}

// Private — undo / redo ring stacks

/// Push the current editor state onto `ring`.  When the ring is full, the
/// oldest slot is overwritten rather than silently dropping the save.
inline fn ringPush(ring: *RingStack, vs: *const VimState) void {
    const idx = (ring.base + ring.top) % ring.entries.len;
    if (ring.top < ring.entries.len) {
        ring.top += 1;
    } else {
        ring.base = (ring.base + 1) % ring.entries.len;
    }
    const e = &ring.entries[idx];
    @memcpy(e.buf[0..vs.len], vs.buf[0..vs.len]);
    e.len = vs.len; e.cursor = vs.cursor;
}

/// Pop from `from` into `vs`, simultaneously saving the current state to `to`.
/// Used for both undo (from=undo, to=redo) and redo (from=redo, to=undo).
fn applyHistoryStep(vs: *VimState, from: *RingStack, to: *RingStack) void {
    if (from.top == 0) return;
    ringPush(to, vs);
    from.top -= 1;
    const idx = (from.base + from.top) % from.entries.len;
    const e = &from.entries[idx];
    @memcpy(vs.buf[0..e.len], e.buf[0..e.len]);
    vs.len = e.len; vs.cursor = e.cursor;
}

fn undoPush(vs: *VimState) void {
    if (vs.is_replaying_dot) return;
    ringPush(&vs.undo, vs);
    // A new edit invalidates the redo history.
    vs.redo = .{ .entries = vs.redo.entries };
}

// Private — dot repeat

fn replayDot(vs: *VimState) void {
    if (vs.dot == .none) return;

    ringPush(&vs.undo, vs);
    vs.redo.top = 0;

    vs.is_replaying_dot = true;
    defer vs.is_replaying_dot = false;

    switch (vs.dot) {
        .none => unreachable,

        .direct => |d| {
            const cnt = d.count;
            switch (d.sym) {
                'x', 'X', 'D', 'C', 's' => {
                    const op = execDirectSym(vs, @truncate(d.sym), cnt);
                    if (op == 'c') insertSlice(vs, vs.dot_insert_buf[0..vs.dot_insert_len]);
                },
                'p', 'P' => for (0..cnt) |_| { if (d.sym == 'p') pasteAfter(vs) else pasteBefore(vs); },
                '~' => for (0..cnt) |_| toggleCaseOnce(vs),
                'S' => {
                    yankRange(vs, 0, vs.len);
                    vs.len = 0; vs.cursor = 0;
                    insertSlice(vs, vs.dot_insert_buf[0..vs.dot_insert_len]);
                },
                'r' => {
                    var i: usize = 0;
                    while (i < cnt and vs.cursor + i < vs.len) : (i += 1)
                        vs.buf[vs.cursor + i] = d.replace_char;
                    vs.cursor = @min(vs.cursor + cnt - 1, vs.len -| 1);
                },
                else => {},
            }
        },

        .op_motion => |om| {
            const cnt: u32 = resolveCount(om.op_count) * resolveCount(om.motion_count);
            const mr_opt: ?MotionResult =
                if (om.find_kind != 0)
                    motionFind(vs, om.find_kind, om.find_ch, cnt)
                else if (om.tobj_kind != 0)
                    resolveTextObject(vs, om.tobj_kind, om.tobj_delim)
                else if (om.has_g_prefix) blk: {
                    break :blk switch (om.motion_sym) {
                        'e'  => MotionResult{ .pos = motionWordEndBackward(vs, false, cnt), .inclusive = true },
                        'E'  => MotionResult{ .pos = motionWordEndBackward(vs, true,  cnt), .inclusive = true },
                        else => null,
                    };
                } else resolveSimpleMotion(vs, om.motion_sym, cnt);
            if (mr_opt) |mr| {
                applyOperator(vs, om.op, mr);
                if (om.op == 'c') insertSlice(vs, vs.dot_insert_buf[0..vs.dot_insert_len]);
            }
        },

        .op_line => |ol| {
            applyOperator(vs, ol.op, .{ .pos = vs.len, .range_start_override = 0 });
            if (ol.op == 'c') insertSlice(vs, vs.dot_insert_buf[0..vs.dot_insert_len]);
        },

        .insert_session => {
            insertSlice(vs, vs.dot_insert_buf[0..vs.dot_insert_len]);
        },
    }
}

// Private — count helpers and dot record building

/// Treat a count of 0 as 1 (vim convention: no count = repeat once).
inline fn resolveCount(n: u32) u32 { return if (n == 0) 1 else n; }

/// Compute the combined effective count: `op_count × motion_count` (both
/// defaulting to 1 when zero).
fn effectiveCount(vs: *VimState) u32 {
    return resolveCount(vs.pending.count) * resolveCount(vs.pending.op_count);
}

/// Build a base `op_motion` `DotRecord` from the current `pending` state.
/// Callers fill in any extra fields (`has_g_prefix`, `find_kind`, `tobj_kind`)
/// afterwards.
inline fn buildOpMotionRecord(vs: *VimState, sym: xcb.xcb_keysym_t) DotRecord {
    return .{ .op_motion = .{
        .op           = vs.pending.op,
        .op_count     = vs.pending.op_count,
        .motion_count = vs.pending.count,
        .motion_sym   = @truncate(sym),
    }};
}

// Private — word and find motions

inline fn isWordChar(ch: u8) bool {
    return std.ascii.isAlphanumeric(ch) or ch == '_';
}

/// Character class for word motions.  `big=true` collapses to space/non-space.
/// 0 = space, 1 = word char (or any non-space when big), 2 = punctuation.
inline fn charClass(big: bool, ch: u8) u2 {
    if (ch == ' ') return 0;
    if (big or isWordChar(ch)) return 1;
    return 2;
}

fn firstNonBlank(vs: *VimState) usize {
    var p: usize = 0;
    while (p < vs.len and vs.buf[p] == ' ') p += 1;
    return p;
}

fn motionWordNext(vs: *VimState, big: bool, cnt: u32) usize {
    var p = vs.cursor;
    for (0..cnt) |_| {
        if (p >= vs.len) break;
        const cls = charClass(big, vs.buf[p]);
        while (p < vs.len and charClass(big, vs.buf[p]) == cls) p += 1;
        while (p < vs.len and vs.buf[p] == ' ') p += 1;
    }
    return p;
}

fn motionWordPrev(vs: *VimState, big: bool, cnt: u32) usize {
    var p = vs.cursor;
    for (0..cnt) |_| {
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
    for (0..cnt) |_| {
        if (p >= vs.len) break;
        p += 1;
        while (p < vs.len and vs.buf[p] == ' ') p += 1;
        if (p >= vs.len) { p = vs.len; break; }
        const cls = charClass(big, vs.buf[p]);
        while (p + 1 < vs.len and charClass(big, vs.buf[p + 1]) == cls) p += 1;
    }
    return @min(p, vs.len -| 1);
}

fn motionWordEndBackward(vs: *VimState, big: bool, cnt: u32) usize {
    var p = vs.cursor;
    for (0..cnt) |_| {
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
    for (0..cnt) |_| {
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

/// f↔F and t↔T differ only in bit 5 (0x20 = lowercase flag).
fn reverseFindKind(kind: u8) u8 {
    return switch (kind) {
        'f', 'F', 't', 'T' => kind ^ 0x20,
        else => kind,
    };
}

// Private — bracket matching and text objects

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

fn resolveTextObject(vs: *VimState, kind: u8, delim: u8) ?MotionResult {
    const inner = (kind == 'i');
    return switch (delim) {
        'w'            => textObjWord(vs, false, inner),
        'W'            => textObjWord(vs, true,  inner),
        '"', '\'', '`' => textObjQuote(vs, delim, inner),
        '(', ')', 'b'  => textObjBracket(vs, '(', ')', inner),
        '[', ']'        => textObjBracket(vs, '[', ']', inner),
        '{', '}', 'B'   => textObjBracket(vs, '{', '}', inner),
        // '<' and '>' are treated symmetrically (same open/close pair) so that
        // `i<` and `a<` select tag-like content.  Note that in a single-line
        // prompt buffer these are rare; the behaviour matches vim's `it`/`at`
        // in spirit without full XML awareness.
        '<', '>'        => textObjBracket(vs, '<', '>', inner),
        else            => null,
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
    return MotionResult{ .pos = hi, .inclusive = false, .range_start_override = lo };
}

fn textObjQuote(vs: *VimState, q: u8, inner: bool) ?MotionResult {
    var i: usize = 0;
    while (i < vs.len) {
        if (vs.buf[i] != q) { i += 1; continue; }
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
            return MotionResult{ .pos = hi, .inclusive = false, .range_start_override = lo };
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
        return MotionResult{ .pos = hv,     .inclusive = false, .range_start_override = lv + 1 };
    } else {
        return MotionResult{ .pos = hv + 1, .inclusive = false, .range_start_override = lv };
    }
}