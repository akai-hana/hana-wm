//! Vim modal editing engine for the prompt segment.
//! Imports prompt.zig for basic input types and registers enhanced handlers.

const std = @import("std");
const core = @import("core");
const xcb = core.xcb;
const prompt = @import("prompt");

const XK = prompt.XK;
const Action = prompt.Action;
const Mode = prompt.Mode;
const EditorState = prompt.EditorState;

// Keysym payloads are owned by prompt (the one place they're derived from
// core.XK); vim re-aliases them so it never re-derives the same constants.
const xk_back_space = prompt.xk_back_space;
const xk_return = prompt.xk_return;
const xk_escape = prompt.xk_escape;
const xk_delete = prompt.xk_delete;
const xk_left = prompt.xk_left;
const xk_right = prompt.xk_right;
const xk_home = prompt.xk_home;
const xk_end = prompt.xk_end;

const Awaiting = union(enum) {
    none,
    find_char: u8,
    g_prefix,
};

const PendingCmd = struct {
    count: u32 = 0,
    op: u8 = 0,
    op_count: u32 = 0,
    awaiting: Awaiting = .none,
};

var pending = PendingCmd{};
var last_find_kind: u8 = 0;
var last_find_ch: u8 = 0;
var yank_buf: []u8 = &.{};
var yank_len: usize = 0;

const MotionResult = struct {
    pos: usize,
    inclusive: bool = false,
    range_start_override: ?usize = null,
};

fn resetPendingCmd(_: *EditorState) void {
    pending = .{};
}

pub fn onDeactivate(vs: *EditorState) void {
    resetPendingCmd(vs);
}

fn enterInsert(vs: *EditorState) void {
    vs.mode = .insert;
}

/// Handle a Ctrl-modified key.  Returns `.deactivate` for Ctrl+C.
pub fn handleCtrl(vs: *EditorState, sym: xcb.xcb_keysym_t) Action {
    switch (sym) {
        'c' => return .deactivate,
        'w' => if (vs.mode == .insert) ctrlW(vs),
        else => {},
    }
    return .none;
}

inline fn exitToNormal(vs: *EditorState) void {
    clampCursorForNormal(vs);
    vs.mode = .normal;
}

pub fn handleInsert(vs: *EditorState, sym: xcb.xcb_keysym_t) Action {
    switch (sym) {
        xk_escape => {
            exitToNormal(vs);
            resetPendingCmd(vs);
        },
        else => return insertKey(vs, sym),
    }
    return .none;
}

fn insertKey(vs: *EditorState, sym: xcb.xcb_keysym_t) Action {
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
        else => if (prompt.isPrintableAscii(sym)) {
            const ch: u8 = @truncate(sym);
            prompt.insertSlice(vs, &[1]u8{ch});
        },
    }
    return .none;
}

/// Arms an operator (d/c/y) on the first press, or; on a doubled press
/// (dd/cc/yy): applies it to the whole line.
fn handleOperatorArm(vs: *EditorState, sym: xcb.xcb_keysym_t) Action {
    const op: u8 = @truncate(sym);
    if (pending.op == 0) {
        pending.op = op;
        pending.op_count = pending.count;
        pending.count = 0;
        return .none;
    }
    if (pending.op == op) {
        applyOperator(vs, op, .{ .pos = vs.len, .range_start_override = 0 });
    }
    resetPendingCmd(vs);
    return .none;
}

fn execNormalKey(vs: *EditorState, sym: xcb.xcb_keysym_t, cnt: u32) Action {
    switch (sym) {
        xk_escape => {
            const act: Action = if (pending.op == 0 and pending.count == 0) .deactivate else .none;
            resetPendingCmd(vs);
            return act;
        },

        xk_return => {
            resetPendingCmd(vs);
            return .spawn;
        },

        'x', 'X', 'D', 'C', 's' => {
            execDirectSym(vs, @truncate(sym), cnt);
        },

        'p', 'P' => if (yank_len > 0) {
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

pub fn handleNormal(vs: *EditorState, sym: xcb.xcb_keysym_t) Action {
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

    return execNormalKey(vs, sym, effectiveCount());
}

/// Clamp cursor to the last valid position for normal mode.
inline fn clampCursorForNormal(vs: *EditorState) void {
    if (vs.cursor >= vs.len) vs.cursor = vs.len -| 1;
}

fn tryAccumulateDigit(sym: xcb.xcb_keysym_t) bool {
    if (sym >= '1' and sym <= '9') {
        const next = pending.count *% 10 +% @as(u32, @truncate(sym - '0'));
        pending.count = @min(next, 1_000_000);
        return true;
    }
    if (sym == '0' and pending.count > 0) {
        pending.count = @min(pending.count *% 10, 1_000_000);
        return true;
    }
    return false;
}

fn tryArmFindPrefix(sym: xcb.xcb_keysym_t) bool {
    if (sym == 'g') {
        pending.awaiting = .g_prefix;
        return true;
    }
    if (sym == 'f' or sym == 'F' or sym == 't' or sym == 'T') {
        pending.awaiting = .{ .find_char = @truncate(sym) };
        return true;
    }
    return false;
}

/// Position resolver for g-prefix motions (ge, gE, gg, g0, g$).
fn resolveGPrefixPos(vs: *EditorState, sym: xcb.xcb_keysym_t, cnt: u32) ?usize {
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

inline fn commitMotion(vs: *EditorState, mr: MotionResult) MotionKeyResult {
    const op = pending.op;
    resetPendingCmd(vs);
    return .{ .mr = mr, .op = op };
}

fn resolveMotionKey(vs: *EditorState, sym: xcb.xcb_keysym_t) ?MotionKeyResult {
    if (pending.awaiting == .find_char) return resolvePendingFindChar(vs, sym);
    if (pending.awaiting == .g_prefix) return resolvePendingGPrefix(vs, sym);

    if (tryAccumulateDigit(sym)) return .{};

    const cnt = effectiveCount();

    // ;/, repeat last find.
    if (sym == ';' or sym == ',') {
        if (last_find_kind != 0) {
            const kind = if (sym == ',') reverseFindKind(last_find_kind) else last_find_kind;
            const mr = motionFind(vs, kind, last_find_ch, cnt);
            return commitMotion(vs, mr);
        }
        resetPendingCmd(vs);
        return .{};
    }

    if (resolveSimpleMotion(vs, sym, cnt)) |mr| {
        return commitMotion(vs, mr);
    }

    if (tryArmFindPrefix(sym)) return .{};

    return null;
}

fn resolvePendingFindChar(vs: *EditorState, sym: xcb.xcb_keysym_t) ?MotionKeyResult {
    if (!prompt.isPrintableAscii(sym)) {
        resetPendingCmd(vs);
        return .{};
    }
    const ch: u8 = @truncate(sym);
    const kind = pending.awaiting.find_char;
    last_find_kind = kind;
    last_find_ch = ch;
    const mr = motionFind(vs, kind, ch, effectiveCount());
    return commitMotion(vs, mr);
}

fn resolvePendingGPrefix(vs: *EditorState, sym: xcb.xcb_keysym_t) ?MotionKeyResult {
    const pos = resolveGPrefixPos(vs, sym, effectiveCount()) orelse {
        resetPendingCmd(vs);
        return .{};
    };
    const mr = MotionResult{ .pos = pos, .inclusive = (sym == 'e' or sym == 'E') };
    return commitMotion(vs, mr);
}

fn resolveSimpleMotion(vs: *EditorState, sym: xcb.xcb_keysym_t, cnt: u32) ?MotionResult {
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

fn setCursor(vs: *EditorState, mr: MotionResult) void {
    vs.cursor = @min(mr.pos, vs.len -| 1);
}

fn deleteBefore(vs: *EditorState) void {
    if (vs.cursor == 0) return;
    vs.cursor -= 1;
    deleteAfter(vs);
}

fn deleteAfter(vs: *EditorState) void {
    deleteRange(vs, vs.cursor, vs.cursor + 1);
}

fn deleteRange(vs: *EditorState, from: usize, to: usize) void {
    if (from >= to or to > vs.len) return;
    const n = to - from;
    std.mem.copyForwards(u8, vs.buf[from .. vs.len - n], vs.buf[to..vs.len]);
    vs.len -= n;
    vs.cursor = from;
    if (vs.mode == .normal and vs.len > 0 and vs.cursor >= vs.len)
        vs.cursor = vs.len - 1;
}

fn yankRange(vs: *EditorState, from: usize, to: usize) void {
    if (from >= to or to > vs.len) return;
    const n = to - from;
    @memcpy(yank_buf[0..n], vs.buf[from..to]);
    yank_len = n;
}

fn deleteAndYank(vs: *EditorState, from: usize, to: usize) void {
    yankRange(vs, from, to);
    deleteRange(vs, from, to);
}

fn clearAndYankAll(vs: *EditorState) void {
    yankRange(vs, 0, vs.len);
    vs.len = 0;
    vs.cursor = 0;
}

fn pasteAfter(vs: *EditorState) void {
    if (yank_len == 0) return;
    if (vs.cursor < vs.len) vs.cursor += 1;
    prompt.insertSlice(vs, yank_buf[0..yank_len]);
}

fn pasteBefore(vs: *EditorState) void {
    if (yank_len == 0) return;
    prompt.insertSlice(vs, yank_buf[0..yank_len]);
}

inline fn toggleCaseChar(ch: u8) u8 {
    if (std.ascii.isLower(ch)) return std.ascii.toUpper(ch);
    if (std.ascii.isUpper(ch)) return std.ascii.toLower(ch);
    return ch;
}

fn toggleCaseOnce(vs: *EditorState) void {
    if (vs.cursor >= vs.len) return;
    vs.buf[vs.cursor] = toggleCaseChar(vs.buf[vs.cursor]);
    if (vs.cursor + 1 < vs.len) vs.cursor += 1;
}

fn ctrlW(vs: *EditorState) void {
    if (vs.cursor == 0) return;
    deleteRange(vs, motionWordPrev(vs, false, 1), vs.cursor);
}

fn applyOperator(vs: *EditorState, op: u8, mr: MotionResult) void {
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

fn execDirectSym(vs: *EditorState, sym: u8, cnt: u32) void {
    const op: u8 = if (sym == 'x' or sym == 'X' or sym == 'D') 'd' else 'c';
    const pos: usize = switch (sym) {
        'X' => vs.cursor -| @as(usize, cnt),
        'D', 'C' => vs.len,
        else => @min(vs.cursor + @as(usize, cnt), vs.len),
    };
    applyOperator(vs, op, .{ .pos = pos });
}

/// Treat a count of 0 as 1 (vim convention: no count = repeat once).
inline fn resolveCount(n: u32) u32 {
    return if (n == 0) 1 else n;
}

fn effectiveCount() u32 {
    // Saturating multiply: chained count prefixes can push the product past
    // u32 max (1e6 x 1e6); consumers clamp against buffer bounds anyway, so
    // saturate instead of overflowing.
    return resolveCount(pending.count) *| resolveCount(pending.op_count);
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

fn firstNonBlank(vs: *EditorState) usize {
    var p: usize = 0;
    while (p < vs.len and vs.buf[p] == ' ') p += 1;
    return p;
}

fn motionWordNext(vs: *EditorState, big: bool, cnt: u32) usize {
    var p = vs.cursor;
    for (0..cnt) |_| {
        if (p >= vs.len) break;
        const cls = charClass(big, vs.buf[p]);
        while (p < vs.len and charClass(big, vs.buf[p]) == cls) p += 1;
        while (p < vs.len and vs.buf[p] == ' ') p += 1;
    }
    return p;
}

fn motionWordPrev(vs: *EditorState, big: bool, cnt: u32) usize {
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

fn motionWordEnd(vs: *EditorState, big: bool, cnt: u32) usize {
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

fn motionWordEndBackward(vs: *EditorState, big: bool, cnt: u32) usize {
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

fn motionFind(vs: *EditorState, kind: u8, ch: u8, cnt: u32) MotionResult {
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

fn modeLabel(m: Mode) []const u8 {
    const labels = [_][]const u8{ "[INSERT]", "[NORMAL]" };
    return labels[@intFromEnum(m)];
}

pub fn init(allocator: std.mem.Allocator, max_input: usize) !void {
    yank_buf = try allocator.alloc(u8, max_input);
}

pub fn deinit(allocator: std.mem.Allocator) void {
    if (yank_buf.len > 0) {
        allocator.free(yank_buf);
        yank_buf = &.{};
    }
}

pub fn register() void {
    prompt.registerHandlers(.{
        .handle_insert = handleInsert,
        .handle_normal = handleNormal,
        .handle_ctrl = handleCtrl,
        .on_deactivate = onDeactivate,
        .mode_label = modeLabel,
    });
}
