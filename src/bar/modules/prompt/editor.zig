//! The prompt's line editor: the bounded buffer, its edit
//! primitives, and the basic (non-modal) key handlers. The vim
//! extensor (`vim.zig`) layers its own handlers on top through the
//! `Handlers` contract below; both drive the same `EditorState`, and the
//! package core (`prompt.zig`) re-exports every name the extensor
//! binds to, so the extensor imports the package, never this file.

const std = @import("std");

const core = @import("core");
const xcb = core.xcb;
const drawing = @import("drawing");

pub const XK = core.XK;
const xk_back_space = @intFromEnum(XK.BackSpace);
pub const xk_return = @intFromEnum(XK.Return);
pub const xk_escape = @intFromEnum(XK.Escape);
const xk_delete = @intFromEnum(XK.Delete);
pub const xk_left = @intFromEnum(XK.Left);
pub const xk_right = @intFromEnum(XK.Right);
pub const xk_home = @intFromEnum(XK.Home);
pub const xk_end = @intFromEnum(XK.End);

/// 256 input chars fits a full `.desktop` file path plus arguments, the
/// longest payload a run-segment entry can produce.
pub const default_max_input: usize = 256;

pub const Action = enum { none, deactivate, spawn };

pub const Mode = enum(u2) {
    insert = 0,
    normal = 1,

    /// Hint text for this mode, or "" when the active provider has none.
    /// Provided by the mode's owner, not chosen by the host.
    pub fn label(self: Mode) []const u8 {
        return handlers.mode_label(self);
    }

    /// Pixel width of this mode's hint, measured once and cached in `cache`.
    /// 0 means "no hint", which is what suppresses the pill entirely.
    ///
    /// The pill is the extensor's UI, so the WIDTH POLICY belongs to the
    /// mode rather than to the bar: the host used to measure the provider's
    /// label and decide on its own what a mode with no label means. Asking the
    /// mode for its hint width moves the "no label => no pill" rule next to the
    /// label that produces it, so the two cannot drift.
    ///
    /// The cache cell is passed in rather than kept here on purpose: it has to
    /// be invalidated when the font changes on reload (see onDeactivate), which
    /// is a host lifecycle fact the mode has no way to observe.
    pub fn hintWidth(self: Mode, dc: *drawing.DrawContext, cache: *?u16) u16 {
        const text = self.label();
        if (text.len == 0) {
            // Do not memoise the empty case: a provider that starts with no
            // hint and installs one later must be measured when it appears.
            cache.* = null;
            return 0;
        }
        return measureCached(cache, dc, text);
    }
};

pub const EditorState = struct {
    allocator: std.mem.Allocator = undefined,
    max_input: usize = 0,
    buf: []u8 = &.{},
    len: usize = 0,
    cursor: usize = 0,
    mode: Mode = .insert,

    pub fn init(allocator: std.mem.Allocator, max_input: usize) !EditorState {
        return .{
            .allocator = allocator,
            .max_input = max_input,
            .buf = try allocator.alloc(u8, max_input),
        };
    }
    pub fn reset(es: *EditorState) void {
        es.* = .{
            .allocator = es.allocator,
            .max_input = es.max_input,
            .buf = es.buf,
        };
    }
    pub fn deinit(es: *EditorState) void {
        es.allocator.free(es.buf);
        es.* = .{};
    }
};

fn onDeactivate(_: *EditorState) void {}
pub fn insertSlice(es: *EditorState, slice: []const u8) void {
    if (es.max_input == 0 or es.len + 1 >= es.max_input) return;
    const n = @min(slice.len, es.max_input - 1 - es.len);
    if (n == 0) return;
    if (es.cursor < es.len) {
        std.mem.copyBackwards(
            u8,
            es.buf[es.cursor + n .. es.len + n],
            es.buf[es.cursor..es.len],
        );
    }
    @memcpy(es.buf[es.cursor .. es.cursor + n], slice[0..n]);
    es.len += n;
    es.cursor += n;
}

/// Removes [from, to) from the buffer and places the cursor at `from`.
///
/// The mode-aware clamp lives here rather than in the caller: in NORMAL mode a
/// cursor may sit ON the last character (it addresses it, so the next motion
/// has something to act on), and a delete that emptied the tail would
/// otherwise leave normal mode addressing `len`, one past the end. Five
/// divergent memmove+clamp copies existed between this module and the vim
/// extensor; this is the one that owns the rule, and both now call it.
pub fn deleteRange(es: *EditorState, from: usize, to: usize) void {
    if (from >= to or to > es.len) return;
    const n = to - from;
    std.mem.copyForwards(u8, es.buf[from .. es.len - n], es.buf[to..es.len]);
    es.len -= n;
    es.cursor = from;
    if (es.mode == .normal and es.len > 0 and es.cursor >= es.len)
        es.cursor = es.len - 1;
}

/// Overwrites in place at `pos` with `bytes`, up to the end of the current
/// content. The length CANNOT change: this is a replacement primitive for
/// edits that keep the buffer's extent (a case toggle, an in-place rewrite of
/// a run), not an insert. Overflow past the end of the content is dropped
/// rather than appending, so a caller cannot silently grow the buffer by using
/// the overwrite to mean an insert.
pub fn overwriteAt(es: *EditorState, pos: usize, bytes: []const u8) void {
    if (pos >= es.len) return;
    const n = @min(bytes.len, es.len - pos);
    if (n == 0) return;
    @memcpy(es.buf[pos..][0..n], bytes[0..n]);
}

pub inline fn isPrintableAscii(sym: xcb.xcb_keysym_t) bool {
    return sym >= 0x20 and sym <= 0x7e;
}

/// Deletes the word immediately before the cursor (readline Ctrl-W
/// semantics): the run of non-space chars plus the space run separating it
/// from the previous word. No-op at the buffer head.
fn deleteWordBack(es: *EditorState) void {
    if (es.cursor == 0) return;
    var start = es.cursor;
    while (start > 0 and es.buf[start - 1] == ' ') start -= 1;
    while (start > 0 and es.buf[start - 1] != ' ') start -= 1;
    // Eat the inter-word space run that separated this word from the previous
    // one, so deleting "two" out of "one two" leaves "one", not "one ".
    while (start > 0 and es.buf[start - 1] == ' ') start -= 1;
    if (start == es.cursor) return;
    std.mem.copyForwards(
        u8,
        es.buf[start .. es.len - (es.cursor - start)],
        es.buf[es.cursor..es.len],
    );
    es.len -= es.cursor - start;
    es.cursor = start;
}

/// Deletes the text from `from` to the end of the buffer (Ctrl-K): the tail
/// is discarded and the cursor clamps into range.
fn clearToEnd(es: *EditorState, from: usize) void {
    es.len = from;
    es.cursor = @min(es.cursor, es.len);
}

fn backspace(es: *EditorState) void {
    if (es.cursor == 0) return;
    std.mem.copyForwards(
        u8,
        es.buf[es.cursor - 1 .. es.len - 1],
        es.buf[es.cursor..es.len],
    );
    es.cursor -= 1;
    es.len -= 1;
}

/// Base Ctrl-key handler (used whenever the vim overlay is absent): the
/// readline editing set plus Ctrl-C, so a Ctrl-modified key in a bare prompt
/// never disappears without an effect. The vim overlay layers its own keys on
/// top of this one.
pub fn handleCtrl(es: *EditorState, sym: xcb.xcb_keysym_t) Action {
    switch (sym) {
        'c' => return .deactivate,
        'a' => es.cursor = 0,
        'e' => es.cursor = es.len,
        'u' => deleteRange(es, 0, es.cursor),
        'k' => clearToEnd(es, es.cursor),
        'w' => deleteWordBack(es),
        'h' => backspace(es),
        else => {},
    }
    return .none;
}

pub fn handleInsertBasic(es: *EditorState, sym: xcb.xcb_keysym_t) Action {
    return if (sym == xk_escape) .deactivate else insertChar(es, sym);
}

/// Shared insert-mode editing for a printable/control key: text insertion and
/// cursor navigation, returning .none. Escape is invisible here: callers add
/// the escape exit themselves (handleInsertBasic deactivates, the vim overlay
/// calls exitToNormal).
pub fn insertChar(es: *EditorState, sym: xcb.xcb_keysym_t) Action {
    switch (sym) {
        xk_return => return .spawn,
        xk_back_space => backspace(es),
        xk_delete => if (es.cursor < es.len) {
            std.mem.copyForwards(
                u8,
                es.buf[es.cursor .. es.len - 1],
                es.buf[es.cursor + 1 .. es.len],
            );
            es.len -= 1;
        },
        xk_left => {
            if (es.cursor > 0) es.cursor -= 1;
        },
        xk_right => {
            if (es.cursor < es.len) es.cursor += 1;
        },
        xk_home => es.cursor = 0,
        xk_end => es.cursor = es.len,
        else => if (isPrintableAscii(sym)) {
            const ch: u8 = @truncate(sym);
            insertSlice(es, &[1]u8{ch});
        },
    }
    return .none;
}

/// True once a handler set has been registered.
///
/// Sticky: nothing unregisters handlers, and a build with no extensor never
/// calls registerHandlers at all, which is what leaves insert mode basic.
pub var addon_active: bool = false;

pub const Handlers = struct {
    handle_insert: *const fn (*EditorState, xcb.xcb_keysym_t) Action = handleInsertBasic,
    handle_normal: *const fn (*EditorState, xcb.xcb_keysym_t) Action = struct {
        fn f(_: *EditorState, _: xcb.xcb_keysym_t) Action {
            return .none;
        }
    }.f,
    handle_ctrl: *const fn (*EditorState, xcb.xcb_keysym_t) Action = handleCtrl,
    on_deactivate: *const fn (*EditorState) void = onDeactivate,
    mode_label: *const fn (Mode) []const u8 = struct {
        fn f(_: Mode) []const u8 {
            return "";
        }
    }.f,
};

pub var handlers: Handlers = .{};

pub fn registerHandlers(h: Handlers) void {
    handlers = h;
    // Registering a handler set is what MAKES this a modal prompt, and
    // the two places that used to ask `config.bar.vim_mode` were really asking
    // that question through a config key -- so a compiled-in extensor that
    // implements the modal engine was silently bypassed in insert mode and had
    // its mode pill suppressed, purely because the user had not set
    // `vim_mode`. The flag is the honest answer to "is a handler installed",
    // and it leaves `vim_mode` a policy input a handler may consult instead of
    // a second dispatch mode the host switches on.
    addon_active = true;
}

/// Pixel width of `text`, measured once and cached (font and text are
/// constant between reloads). Shared by the mode hint (Mode.hintWidth) and
/// the prompt's own prefix measurement.
pub fn measureCached(cache: *?u16, dc: *drawing.DrawContext, text: []const u8) u16 {
    return cache.* orelse blk: {
        const w = dc.measureTextWidth(text);
        cache.* = w;
        break :blk w;
    };
}
