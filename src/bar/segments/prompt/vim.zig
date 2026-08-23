//! Vim modal editing engine for the prompt segment
//! Implements vim-style modal editing for the bar's inline command prompt.

const std = @import("std");
const core = @import("core");
const xcb = core.xcb;

pub const XK = core.XK;

// Switch arms need integer constants to match against raw xcb_keysym_t values.
const xk_back_space = @intFromEnum(XK.BackSpace);
const xk_return = @intFromEnum(XK.Return);
const xk_escape = @intFromEnum(XK.Escape);
const xk_delete = @intFromEnum(XK.Delete);
const xk_left = @intFromEnum(XK.Left);
const xk_right = @intFromEnum(XK.Right);
const xk_home = @intFromEnum(XK.Home);
const xk_end = @intFromEnum(XK.End);

pub const default_max_input: usize = 512;

pub const Action = enum { none, deactivate, spawn, spawn_keep };

/// The integer value is the index into the cached mode-width array in prompt.zig.
pub const Mode = enum(u2) {
    insert = 0,
    normal = 1,

    pub fn label(self: Mode) []const u8 {
        const labels = [_][]const u8{ "[INSERT]", "[NORMAL]" };
        return labels[@intFromEnum(self)];
    }
};

const MotionResult = struct {
    pos: usize,
    inclusive: bool = false,
    range_start_override: ?usize = null,
};

/// What the engine is waiting for between keystrokes.
const Awaiting = union(enum) {
    none,
    find_char: u8,
    g_prefix,
};

/// Accumulated state for the in-progress normal-mode command.
const PendingCmd = struct {
    count: u32 = 0,
    op: u8 = 0,
    op_count: u32 = 0,
    awaiting: Awaiting = .none,
};

const buf_fields = .{ "buf", "yank_buf" };

/// All state for the vim editing engine.
pub const VimState = struct {
    allocator: std.mem.Allocator = undefined,
    max_input: usize = 0,

    buf: []u8 = &.{},
    len: usize = 0,
    cursor: usize = 0,
    mode: Mode = .insert,

    pending: PendingCmd = .{},

    last_find_kind: u8 = 0,
    last_find_ch: u8 = 0,

    yank_buf: []u8 = &.{},
    yank_len: usize = 0,

    pub fn init(allocator: std.mem.Allocator, max_input: usize) !VimState {
        var vs = VimState{
            .allocator = allocator,
            .max_input = max_input,
        };
        inline for (buf_fields) |field| {
            @field(vs, field) = try allocator.alloc(u8, max_input);
        }
        return vs;
    }

    pub fn reset(vs: *VimState) void {
        var saved_bufs: [buf_fields.len][]u8 = undefined;
        inline for (buf_fields, 0..) |field, i| {
            saved_bufs[i] = @field(vs, field);
        }
        const saved_allocator = vs.allocator;
        const saved_max_input = vs.max_input;

        vs.* = .{};

        vs.allocator = saved_allocator;
        vs.max_input = saved_max_input;
        inline for (buf_fields, 0..) |field, i| {
            @field(vs, field) = saved_bufs[i];
        }
    }

    pub fn deinit(vs: *VimState) void {
        inline for (buf_fields) |field| {
            vs.allocator.free(@field(vs, field));
        }
        vs.* = .{};
    }
};

fn resetPendingCmd(vs: *VimState) void {
    vs.pending = .{};
}

inline fn pendingDone(vs: *VimState) Action {
    resetPendingCmd(vs);
    return .none;
}

pub fn onDeactivate(vs: *VimState) void {
    resetPendingCmd(vs);
}

fn enterInsert(vs: *VimState) void {
    vs.mode = .insert;
}

pub fn insertSlice(vs: *VimState, slice: []const u8) void {
    const n = @min(slice.len, vs.max_input - 1 - vs.len);
    if (n == 0) return;
    if (vs.cursor < vs.len) {
        std.mem.copyBackwards(u8, vs.buf[vs.cursor + n .. vs.len + n], vs.buf[vs.cursor..vs.len]);
    }
    @memcpy(vs.buf[vs.cursor .. vs.cursor + n], slice[0..n]);
    vs.len += n;
    vs.cursor += n;
}

pub inline fn isPrintableAscii(sym: xcb.xcb_keysym_t) bool {
    return sym >= 0x20 and sym <= 0x7e;
}

/// Handle a Ctrl-modified key.  Returns `.deactivate` for Ctrl+C.
pub fn handleCtrl(vs: *VimState, sym: xcb.xcb_keysym_t) Action {
    switch (sym) {
        'c' => return .deactivate,
        'w' => if (vs.mode == .insert) ctrlW(vs),
        else => {},
    }
    return .none;
}

inline fn exitToNormal(vs: *VimState) void {
    clampCursorForNormal(vs);
    vs.mode = .normal;
}

pub fn handleInsert(vs: *VimState, sym: xcb.xcb_keysym_t) Action {
    switch (sym) {
        xk_escape => {
            exitToNormal(vs);
            resetPendingCmd(vs);
        },
        else => return insertKey(vs, sym),
    }
    return .none;
}

pub fn handleInsertBasic(vs: *VimState, sym: xcb.xcb_keysym_t) Action {
    switch (sym) {
        xk_escape => return .deactivate,
        else => return insertKey(vs, sym),
    }
}

fn insertKey(vs: *VimState, sym: xcb.xcb_keysym_t) Action {
    switch (sym) {
        xk_return => return .spawn,
        xk_back_space => deleteBefore(vs),
        xk_delete => deleteAfter(vs),
        xk_left => if (vs.cursor > 0) {
            vs.cursor -= 1;
        },
        xk_right => if (vs.cursor < vs.len) {
            vs.cursor += 1;
        },
        xk_home => vs.cursor = 0,
        xk_end => vs.cursor = vs.len,
        else => if (isPrintableAscii(sym)) {
            const ch: u8 = @truncate(sym);
            insertSlice(vs, &[1]u8{ch});
        },
    }
    return .none;
}

/// Arms an operator (d/c/y) on the first press, or; on a doubled press
/// (dd/cc/yy): applies it to the whole line.
fn handleOperatorArm(vs: *VimState, sym: xcb.xcb_keysym_t) Action {
    const op: u8 = @truncate(sym);
    if (vs.pending.op == 0) {
        vs.pending.op = op;
        vs.pending.op_count = vs.pending.count;
        vs.pending.count = 0;
        return .none;
    }
    if (vs.pending.op == op) {
        applyOperator(vs, op, .{ .pos = vs.len, .range_start_override = 0 });
    }
    resetPendingCmd(vs);
    return .none;
}

fn execNormalKey(vs: *VimState, sym: xcb.xcb_keysym_t, cnt: u32) Action {
    switch (sym) {
        xk_escape => {
            const act: Action = if (vs.pending.op == 0 and vs.pending.count == 0) .deactivate else .none;
            resetPendingCmd(vs);
            return act;
        },

        xk_return => {
            resetPendingCmd(vs);
            return .spawn;
        },

        'x', 'X', 'D', 'C', 's' => {
            _ = execDirectSym(vs, @truncate(sym), cnt);
        },

        'p', 'P' => if (vs.yank_len > 0) {
            var i: u32 = 0;
            if (sym == 'p') {
                while (i < cnt) : (i += 1) pasteAfter(vs);
            } else {
                while (i < cnt) : (i += 1) pasteBefore(vs);
            }
        },

        '~' => {
            var i: u32 = 0;
            while (i < cnt) : (i += 1) toggleCaseOnce(vs);
        },

        'S' => {
            clearAndYankAll(vs);
            enterInsert(vs);
        },

        'i', 'I', 'a', 'A' => {
            vs.cursor = switch (sym) {
                'I' => firstNonBlank(vs),
                'a' => @min(vs.cursor + 1, vs.len),
                'A' => vs.len,
                else => vs.cursor,
            };
            enterInsert(vs);
        },

        else => {},
    }

    resetPendingCmd(vs);
    return .none;
}

pub fn handleNormal(vs: *VimState, sym: xcb.xcb_keysym_t) Action {
    switch (vs.pending.awaiting) {
        .none, .find_char, .g_prefix => {},
    }

    if (resolveMotionKey(vs, sym)) |res| {
        if (res.mr) |mr| {
            if (res.op == 0) {
                setCursor(vs, mr);
                return .none;
            }
            applyOperator(vs, res.op, mr);
        }
        return .none;
    }

    if (sym == 'd' or sym == 'c' or sym == 'y') return handleOperatorArm(vs, sym);

    return execNormalKey(vs, sym, effectiveCount(vs));
}

/// Clamp cursor to the last valid position for normal mode.
inline fn clampCursorForNormal(vs: *VimState) void {
    if (vs.cursor >= vs.len) vs.cursor = vs.len -| 1;
}

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

fn tryArmFindPrefix(vs: *VimState, sym: xcb.xcb_keysym_t) bool {
    if (sym == 'g') {
        vs.pending.awaiting = .g_prefix;
        return true;
    }
    if (sym == 'f' or sym == 'F' or sym == 't' or sym == 'T') {
        vs.pending.awaiting = .{ .find_char = @truncate(sym) };
        return true;
    }
    return false;
}

/// Position resolver for g-prefix motions (ge, gE, gg, g0, g$).
fn resolveGPrefixPos(vs: *VimState, sym: xcb.xcb_keysym_t, cnt: u32) ?usize {
    return switch (sym) {
        'e' => motionWordEndBackward(vs, false, cnt),
        'E' => motionWordEndBackward(vs, true, cnt),
        'g', '0', xk_home => @as(usize, 0),
        '$', xk_end => vs.len,
        else => null,
    };
}

const MotionKeyResult = struct {
    mr: ?MotionResult = null,
    op: u8 = 0,
};

inline fn commitMotion(vs: *VimState, mr: MotionResult) MotionKeyResult {
    const op = vs.pending.op;
    resetPendingCmd(vs);
    return .{ .mr = mr, .op = op };
}

fn resolveMotionKey(vs: *VimState, sym: xcb.xcb_keysym_t) ?MotionKeyResult {
    if (vs.pending.awaiting == .find_char) return resolvePendingFindChar(vs, sym);
    if (vs.pending.awaiting == .g_prefix) return resolvePendingGPrefix(vs, sym);

    if (tryAccumulateDigit(vs, sym)) return .{};

    const cnt = effectiveCount(vs);

    // ;/, repeat last find.
    if (sym == ';' or sym == ',') {
        if (vs.last_find_kind != 0) {
            const kind = if (sym == ',') reverseFindKind(vs.last_find_kind) else vs.last_find_kind;
            const mr = motionFind(vs, kind, vs.last_find_ch, cnt);
            return commitMotion(vs, mr);
        }
        resetPendingCmd(vs);
        return .{};
    }

    if (resolveSimpleMotion(vs, sym, cnt)) |mr| {
        return commitMotion(vs, mr);
    }

    if (tryArmFindPrefix(vs, sym)) return .{};

    return null;
}

fn resolvePendingFindChar(vs: *VimState, sym: xcb.xcb_keysym_t) ?MotionKeyResult {
    if (!isPrintableAscii(sym)) {
        resetPendingCmd(vs);
        return .{};
    }
    const ch: u8 = @truncate(sym);
    const kind = vs.pending.awaiting.find_char;
    vs.last_find_kind = kind;
    vs.last_find_ch = ch;
    const mr = motionFind(vs, kind, ch, effectiveCount(vs));
    return commitMotion(vs, mr);
}

fn resolvePendingGPrefix(vs: *VimState, sym: xcb.xcb_keysym_t) ?MotionKeyResult {
    const pos = resolveGPrefixPos(vs, sym, effectiveCount(vs)) orelse {
        resetPendingCmd(vs);
        return .{};
    };
    const mr = MotionResult{ .pos = pos, .inclusive = (sym == 'e' or sym == 'E') };
    return commitMotion(vs, mr);
}

fn resolveSimpleMotion(vs: *VimState, sym: xcb.xcb_keysym_t, cnt: u32) ?MotionResult {
    return switch (sym) {
        'h', xk_left => MotionResult{ .pos = vs.cursor -| @as(usize, cnt) },
        'l', xk_right => MotionResult{ .pos = @min(vs.cursor + @as(usize, cnt), vs.len) },
        'w' => MotionResult{ .pos = motionWordNext(vs, false, cnt) },
        'W' => MotionResult{ .pos = motionWordNext(vs, true, cnt) },
        'b' => MotionResult{ .pos = motionWordPrev(vs, false, cnt) },
        'B' => MotionResult{ .pos = motionWordPrev(vs, true, cnt) },
        'e' => MotionResult{ .pos = motionWordEnd(vs, false, cnt), .inclusive = true },
        'E' => MotionResult{ .pos = motionWordEnd(vs, true, cnt), .inclusive = true },
        '0', xk_home => MotionResult{ .pos = 0 },
        '^' => MotionResult{ .pos = firstNonBlank(vs) },
        '$', xk_end => MotionResult{ .pos = vs.len },
        else => null,
    };
}

fn setCursor(vs: *VimState, mr: MotionResult) void {
    vs.cursor = @min(mr.pos, vs.len -| 1);
}

fn deleteBefore(vs: *VimState) void {
    if (vs.cursor == 0) return;
    vs.cursor -= 1;
    deleteAfter(vs);
}

fn deleteAfter(vs: *VimState) void {
    deleteRange(vs, vs.cursor, vs.cursor + 1);
}

fn deleteRange(vs: *VimState, from: usize, to: usize) void {
    if (from >= to or to > vs.len) return;
    const n = to - from;
    std.mem.copyForwards(u8, vs.buf[from .. vs.len - n], vs.buf[to..vs.len]);
    vs.len -= n;
    vs.cursor = from;
    if (vs.mode == .normal and vs.len > 0 and vs.cursor >= vs.len)
        vs.cursor = vs.len - 1;
}

fn yankRange(vs: *VimState, from: usize, to: usize) void {
    if (from >= to or to > vs.len) return;
    const n = to - from;
    @memcpy(vs.yank_buf[0..n], vs.buf[from..to]);
    vs.yank_len = n;
}

fn deleteAndYank(vs: *VimState, from: usize, to: usize) void {
    yankRange(vs, from, to);
    deleteRange(vs, from, to);
}

fn clearAndYankAll(vs: *VimState) void {
    yankRange(vs, 0, vs.len);
    vs.len = 0;
    vs.cursor = 0;
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

inline fn toggleCaseChar(ch: u8) u8 {
    if (std.ascii.isLower(ch)) return std.ascii.toUpper(ch);
    if (std.ascii.isUpper(ch)) return std.ascii.toLower(ch);
    return ch;
}

fn toggleCaseOnce(vs: *VimState) void {
    if (vs.cursor >= vs.len) return;
    vs.buf[vs.cursor] = toggleCaseChar(vs.buf[vs.cursor]);
    if (vs.cursor + 1 < vs.len) vs.cursor += 1;
}

fn ctrlW(vs: *VimState) void {
    if (vs.cursor == 0) return;
    deleteRange(vs, motionWordPrev(vs, false, 1), vs.cursor);
}

fn applyOperator(vs: *VimState, op: u8, mr: MotionResult) void {
    const from: usize, const to: usize = blk: {
        if (mr.range_start_override) |rso|
            break :blk .{ rso, @min(mr.pos, vs.len) };
        const inc: usize = @intFromBool(mr.inclusive);
        if (mr.pos >= vs.cursor)
            break :blk .{ vs.cursor, @min(mr.pos + inc, vs.len) };
        break :blk .{ mr.pos, @min(vs.cursor + inc, vs.len) };
    };

    if (from >= to) return;

    switch (op) {
        'd', 'c' => {
            deleteAndYank(vs, from, to);
            if (op == 'c') enterInsert(vs);
        },
        'y' => {
            yankRange(vs, from, to);
            vs.cursor = from;
        },
        else => {},
    }
}

fn execDirectSym(vs: *VimState, sym: u8, cnt: u32) u8 {
    const op: u8 = if (sym == 'x' or sym == 'X' or sym == 'D') 'd' else 'c';
    const pos: usize = switch (sym) {
        'X' => vs.cursor -| @as(usize, cnt),
        'D', 'C' => vs.len,
        else => @min(vs.cursor + @as(usize, cnt), vs.len),
    };
    applyOperator(vs, op, .{ .pos = pos });
    return op;
}

/// Treat a count of 0 as 1 (vim convention: no count = repeat once).
inline fn resolveCount(n: u32) u32 {
    return if (n == 0) 1 else n;
}

fn effectiveCount(vs: *VimState) u32 {
    return resolveCount(vs.pending.count) * resolveCount(vs.pending.op_count);
}

inline fn isWordChar(ch: u8) bool {
    return std.ascii.isAlphanumeric(ch) or ch == '_';
}

/// Character class for word motions.  `big=true` collapses to space/non-space.
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
        if (p >= vs.len) {
            p = vs.len;
            break;
        }
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
                while (q > 0 and vs.buf[q] != ch) q -= 1;
                if (vs.buf[q] != ch) break;
                p = if (kind == 'T') q + 1 else q;
            },
            else => {},
        }
    }
    return .{ .pos = p, .inclusive = (kind == 'f' or kind == 'F') };
}

fn reverseFindKind(kind: u8) u8 {
    return switch (kind) {
        'f', 'F', 't', 'T' => kind ^ 0x20,
        else => kind,
    };
}
