//! Inline command prompt for the bar.
//! Embeds an interactive command runner into the bar's title segment.

const std = @import("std");

const core = @import("core");
const xcb = core.xcb;
const debug = @import("debug");

const types = @import("types");

const drawing = @import("drawing");
const masks = @import("masks");
const paths = @import("paths");
const segmod = @import("segment");
// The vim modal-editing engine is a prompt addon: its lifecycle (and mode
// UI) rides the generated `prompt_subs` registry, so this module never names
// it. Dropping vim.zig just shortens the `addons` array and leaves the basic
// editor handlers in force -- no dead stub, no core edit.
pub const Addon = struct {
    register: *const fn () void,
    init: *const fn (std.mem.Allocator, usize) anyerror!void,
    deinit: *const fn (std.mem.Allocator) void,
};
pub const addons = @import("prompt_subs").addons;
pub const XK = core.XK;
pub const xk_back_space = @intFromEnum(XK.BackSpace);
pub const xk_return = @intFromEnum(XK.Return);
pub const xk_escape = @intFromEnum(XK.Escape);
pub const xk_delete = @intFromEnum(XK.Delete);
pub const xk_left = @intFromEnum(XK.Left);
pub const xk_right = @intFromEnum(XK.Right);
pub const xk_home = @intFromEnum(XK.Home);
pub const xk_end = @intFromEnum(XK.End);

pub const default_max_input: usize = 256;
pub const Action = enum { none, deactivate, spawn };

pub const Mode = enum(u2) {
    insert = 0,
    normal = 1,
    pub fn label(self: Mode) []const u8 {
        return handlers.mode_label(self);
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

pub fn onDeactivate(_: *EditorState) void {}
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

/// Deletes the text from the head of the buffer to the cursor (Ctrl-U),
/// shifting the remainder left.
fn clearToStart(es: *EditorState) void {
    if (es.cursor == 0) return;
    std.mem.copyForwards(
        u8,
        es.buf[0 .. es.len - es.cursor],
        es.buf[es.cursor..es.len],
    );
    es.len -= es.cursor;
    es.cursor = 0;
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
        'u' => clearToStart(es),
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
        xk_back_space => if (es.cursor > 0) {
            std.mem.copyForwards(
                u8,
                es.buf[es.cursor - 1 .. es.len - 1],
                es.buf[es.cursor..es.len],
            );
            es.cursor -= 1;
            es.len -= 1;
        },
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

var handlers: Handlers = .{};

pub fn registerHandlers(h: Handlers) void {
    handlers = h;
}

const c = @cImport({
    @cInclude("unistd.h");
    @cInclude("stdlib.h");
    @cInclude("stdio.h");
    @cInclude("fcntl.h");
    @cInclude("dirent.h");
    @cInclude("sys/stat.h");
    @cInclude("sys/wait.h");
});

// XCB keysyms bindings (link with -lxcb-keysyms).

const xcb_key_symbols_t = opaque {};

extern fn xcb_key_symbols_alloc(conn: *xcb.xcb_connection_t) ?*xcb_key_symbols_t;
extern fn xcb_key_symbols_free(syms: *xcb_key_symbols_t) void;
extern fn xcb_key_symbols_get_keysym(
    syms: *xcb_key_symbols_t,
    code: xcb.xcb_keycode_t,
    col: c_int,
) xcb.xcb_keysym_t;

// Minimum pixel width of the block cursor; ensures it is visible even on
// the narrowest glyphs (e.g. '.', '!').
const min_cursor_px: u16 = 8;
// Cursor blink half-period: cursor is visible for this many ms, then
// invisible for the same duration.
const cursor_blink_ms: u64 = 300;
// Number of editing modes (derived from vim.Mode at comptime).
const num_modes = @typeInfo(Mode).@"enum".fields.len;

const cursor_width: u16 = 1;
const cursor_v_pad: u16 = 2;
const max_completions: usize = 1024;
const max_completion_len: usize = 64;
const max_history: usize = 128;
const max_history_line: usize = default_max_input;
// History-file path scratch size (HOME + suffix); shared by the append and
// load paths so the two buffers can't drift apart.
const history_path_buf_len = 512;

const PromptState = struct {
    is_active: bool = false,
    vim_state: EditorState = .{},

    allocator: std.mem.Allocator = undefined,

    /// Bar-provided service handles (present/dismiss/isBarWindow), set at init;
    /// prompt never imports the bar orchestrator.
    handlers: ?*const segmod.BarHandlers = null,

    key_syms: ?*xcb_key_symbols_t = null,
    cached_prompt_w: ?u16 = null,
    // Cached pixel width of each mode label, indexed by `vim.Mode` integer value.
    cached_mode_w: [num_modes]?u16 = .{null} ** num_modes,

    comp_names: []u8 = &.{},
    comp_count: usize = 0,

    // Ghost text: the completion suffix shown dimmed after the cursor.
    ghost_buf: []u8 = &.{},
    ghost_len: usize = 0,
    // True when the current buffer contains at least one space.  Maintained
    // incrementally so `updateGhost` can skip a full buffer scan on every call.
    has_space: bool = false,

    is_blink_visible: bool = true,

    // Caret geometry cached after the first insert-mode draw.  Font metrics
    // and bar height are constant between reloads, so these never need clearing.
    cached_caret_top: ?u16 = null,
    cached_caret_h: ?u16 = null,

    hist_entries: []u8 = &.{},
    hist_count: usize = 0,
    hist_head: usize = 0,
    is_hist_loaded: bool = false,
    // Tracks whether the $PATH scan has run at all, separate from comp_count:
    // a legitimately empty result (or an ensureAlloc failure) leaves
    // comp_count at 0, and gating on that would re-scan $PATH on every
    // activation.
    is_completions_loaded: bool = false,

    // Set by key handlers, `activate`, and `deactivate` to notify the bar
    // that the prompt area needs to be redrawn.  Consumed (read + cleared)
    // by `consumeRedrawRequest` to avoid a circular import between prompt <-> bar.
    redraw_pending: bool = false,

    // Caret-blink scoped repaint: set by `blinkTick`, cleared in `draw`.
    // Unlike `redraw_pending` (which forces a full-bar redraw because it
    // accompanies layout-affecting changes), this only asks the host title
    // slot to repaint, so a caret toggle costs one title-region blit rather
    // than a whole-bar repaint.
    blink_repaint: bool = false,

    // Layout cache: pixel width of the pre-caret text, the block-caret width,
    // and the scroll offset keeping the caret visible.  Recomputed in
    // `drawActive` only when `layout_dirty` is set (keypress, activate,
    // or bar-height change): the caret-blink redraws an identical
    // frame each blink, so ticks reuse these instead of ~20 Pango shape passes.
    cached_pre_w: u16 = 0,
    cached_caret_w: u16 = 0,
    cached_scroll_x: u16 = 0,
    cached_height: u16 = 0,
    layout_dirty: bool = true,
};

var g: PromptState = .{};

/// Invalidates every cache derived from config/font metrics or bar height.
/// Called from bar.applyReload: these module globals are built against the
/// OLD config's fonts and bar height, and a reload can change both. Without
/// this the prompt renders with stale widths/geometry until its next full
/// cycle (the old "constant between reloads" assumption was wrong).
pub fn invalidateReloadCaches() void {
    g.cached_prompt_w = null;
    g.cached_mode_w = .{null} ** num_modes;
    g.cached_caret_top = null;
    g.cached_caret_h = null;
    g.layout_dirty = true;
}

fn vimModeEnabled() bool {
    return core.getState().config.bar.vim_mode;
}

fn copyToZ(dest: []u8, src: []const u8) ?[*:0]u8 {
    if (src.len >= dest.len) return null;
    @memcpy(dest[0..src.len], src);
    dest[src.len] = 0;
    return @ptrCast(dest.ptr);
}

/// Returns true when the prompt is currently active and accepting key input.
pub fn isActive() bool {
    return g.is_active;
}

/// Milliseconds until the next blink toggle, or -1 when the blink animation
/// isn't running.  Pass this (with the clock timeout) to poll() so the loop
/// wakes exactly when a redraw is needed.  Non-negative only while the
/// prompt is active in insert mode.
pub fn blinkPollTimeoutMs() i32 {
    if (!g.is_active or g.vim_state.mode != .insert) return -1;
    return cursor_blink_ms;
}

/// Toggle cursor blink visibility; called by the bar's blink timer.  Flags a
/// scoped repaint as well: while the prompt covers the title slot, the title's
/// needsRepaint hook forwards the overlay's query, and an inactive overlay
/// reports inactive, so the toggled caret reaches the screen without forcing a
/// whole-bar redraw.
///
/// The bar runs every onPollWakeup hook on any timer wakeup (the clock tick,
/// not just the blink), so this guard (matching blinkPollTimeoutMs) keeps a
/// non-blinking prompt from toggling invisible state and queuing repaints off
/// the clock's cadence.
pub fn blinkTick() void {
    if (!g.is_active or g.vim_state.mode != .insert) return;
    g.is_blink_visible = !g.is_blink_visible;
    g.blink_repaint = true;
}

/// Overlay repaint query (plugin.BarOverlay.needsRepaint): true while a caret
/// toggle is waiting to be drawn. Cleared inside `draw`.
pub fn overlayNeedsRepaint() bool {
    return g.blink_repaint;
}

/// Returns true and clears the flag if a prompt-driven redraw is outstanding.
/// Call once per event-loop iteration from `bar.updateIfDirty`.
pub fn consumeRedrawRequest() bool {
    const pending = g.redraw_pending;
    g.redraw_pending = false;
    return pending;
}

/// Initialises prompt state that is needed regardless of whether the prompt
/// is ever opened: the bar service handles, vim engine, and key-symbol table.
/// Completion / history buffers are deferred to `ensureAlloc` (~97 KiB total:
/// 66,560 B completions + 64 B ghost + 32,896 B history)
/// and allocated lazily on the first activation.
pub fn init(
    allocator: std.mem.Allocator,
    conn: core.Connection,
    bar_handlers: ?*const anyopaque,
) !void {
    if (g.vim_state.buf.len != 0) return; // already initialised
    g.handlers = @ptrCast(@alignCast(bar_handlers));
    g.allocator = allocator;
    g.vim_state = try EditorState.init(allocator, default_max_input);
    g.key_syms = xcb_key_symbols_alloc(conn);
    if (g.key_syms == null)
        debug.warn("prompt: xcb_key_symbols_alloc failed: key input will not work", .{});
    // The addon lifecycle lives here: each registered engine binds its
    // handlers into this module's state on init and tears down on deinit.
    inline for (addons) |a| {
        a.register();
        try a.init(allocator, default_max_input);
    }
}

/// Lazily allocate the completion, ghost-text and history buffers on first
/// activation.  Each sub-allocation is independently guarded so a partial
/// OOM on a previous attempt is retried.  ~97 KiB total.
fn ensureAlloc() void {
    if (g.comp_names.len == 0)
        g.comp_names = g.allocator.alloc(
            u8,
            (max_completion_len + 1) * max_completions,
        ) catch return;
    if (g.ghost_buf.len == 0)
        g.ghost_buf = g.allocator.alloc(u8, max_completion_len) catch return;
    if (g.hist_entries.len == 0)
        g.hist_entries = g.allocator.alloc(u8, (max_history_line + 1) * max_history) catch return;
}

/// Releases all prompt resources including the keyboard grab, vim state,
/// completion and history buffers.
pub fn deinit(allocator: std.mem.Allocator) void {
    inline for (addons) |a| a.deinit(allocator);
    if (g.key_syms) |ks| {
        xcb_key_symbols_free(ks);
        g.key_syms = null;
    }
    if (g.vim_state.buf.len != 0) g.vim_state.deinit();
    for ([_]*[]u8{ &g.hist_entries, &g.ghost_buf, &g.comp_names }) |p|
        if (p.*.len != 0) g.allocator.free(p.*);
    g = .{};
}

/// Open the prompt if closed, or close it if open.
pub fn toggle() void {
    if (g.is_active) deactivate() else activate();
}

/// Query the X pointer and decide what close_window should do while the prompt
/// is active: cursor over the bar -> kill the prompt; over a program -> let the
/// WM close it (false); over nothing -> swallow the key silently.
fn closeWindowOrPromptUnderCursor() bool {
    const cs = core.getState();
    const ptr_cookie = xcb.xcb_query_pointer(cs.conn, cs.root);
    const ptr_reply = xcb.xcb_query_pointer_reply(cs.conn, ptr_cookie, null);
    defer if (ptr_reply) |r| std.c.free(r);

    const child: u32 = if (ptr_reply) |r| r.*.child else 0;

    if (g.handlers) |h| if (h.isBarWindow(child)) {
        deactivate();
        return true;
    };
    return child == 0 or child == cs.root;
}

/// Complete key-event routing entry point called by `input.zig`.
///
/// Keeps all prompt-specific routing out of `input.zig`: returns false
/// immediately when inactive (normal keybind dispatch), routes `close_window`
/// by cursor position (bar -> kill prompt, window -> WM close, desktop ->
/// swallow), and otherwise delegates to `handleKeyPress`.
///
/// `bound_action` is whatever the keybind map resolved for this key; pass
/// `state.map.get(key)` directly; null is fine when there's no binding.
pub fn handlePromptKeypress(
    event: *const xcb.xcb_key_press_event_t,
    bound_action: ?*const types.Action,
) bool {
    if (!g.is_active) return false;

    // When the mod key (Super) is held and a WM action is bound to this key,
    // let the normal dispatcher run so WM operations don't cancel the prompt;
    // close_window is still routed here to dismiss the prompt, but only when
    // the cursor is over the bar itself.
    if (bound_action) |action| {
        if (action.* == .close_window) return closeWindowOrPromptUnderCursor();
        if (event.state & xcb.XCB_MOD_MASK_4 != 0)
            return false; // let WM dispatch execute the bind; prompt stays open
    }
    return handleKeyPress(event);
}

/// Low-level key-press handler.  Called by `handlePromptKeypress` after all
/// prompt-level routing decisions have been made.
fn handleKeyPress(event: *const xcb.xcb_key_press_event_t) bool {
    // Only process XCB_KEY_PRESS events: press and release events share the
    // same struct layout, so the loop sometimes casts a release and dispatches
    // it here.  Without this guard the Escape release is a trap: handleInsert
    // switches to .normal on press, then handleNormal sees xk_escape with a
    // clean pending and deactivates; and the prompt is gone before the next
    // editing key arrives.
    //
    // Returning true (not false) keeps the release from falling through to WM
    // keybind dispatch.
    if (event.response_type & 0x7F != xcb.XCB_KEY_PRESS) return true;

    const syms = g.key_syms orelse return false;

    const shift_held = event.state & xcb.XCB_MOD_MASK_SHIFT != 0;
    const ctrl_held = event.state & xcb.XCB_MOD_MASK_CONTROL != 0;
    const col: c_int = if (shift_held) 1 else 0;
    const sym = xcb_key_symbols_get_keysym(syms, event.detail, col);
    const vim_mode = vimModeEnabled();

    // Drop bare modifier key events (Shift, Ctrl, Alt, Super, Meta, Hyper ...).
    //
    // XCB delivers a key event for every key including modifiers, so Shift
    // before '$'/'^' fires XK_Shift_L/R first.  Reaching handleNormal, that
    // falls through to resetPendingCmd(), clearing any pending operator/count:
    // why d$, d^, c$, y^, visual 3W, etc. silently become bare cursor moves.
    //
    // Modifier keysyms occupy 0xFFE1-0xFFEE; the check widens that band by
    // one key on each side, none of which are valid editing keys.
    if (sym >= masks.modifier_keysym_lo and sym <= masks.modifier_keysym_hi) return true;

    // Ctrl-modified keys. Route EVERY Ctrl key through the mode handler,
    // not just in vim mode: otherwise Ctrl-C (and Ctrl-W with vim on) is
    // swallowed by the `.none` fallback and can't cancel the prompt.
    if (ctrl_held) {
        const action = handlers.handle_ctrl(&g.vim_state, sym);
        // handleCtrl may have deleted text (Ctrl-W / Ctrl-U), so the ghost is
        // recomputed in the shared tail.  The blink phase is left untouched.
        return finishKeyPress(action, false);
    }

    // Tab: accept ghost completion
    if (sym == @intFromEnum(XK.Tab) and g.vim_state.mode == .insert) {
        return acceptGhost();
    }

    const action = if (!vim_mode and g.vim_state.mode == .insert)
        handleInsertBasic(&g.vim_state, sym)
    else switch (g.vim_state.mode) {
        .insert => handlers.handle_insert(&g.vim_state, sym),
        .normal => handlers.handle_normal(&g.vim_state, sym),
    };
    return finishKeyPress(action, true);
}

/// Shared tail for every key that edited the buffer: run the action, recompute
/// the ghost suggestion (a mode handler may have deleted or inserted text),
/// and schedule a redraw.  Returns true (event consumed).
fn finishKeyPress(action: Action, refresh_blink: bool) bool {
    const prev_len = g.vim_state.len;
    handleAction(action);
    if (g.vim_state.len != prev_len)
        g.has_space = std.mem.indexOfScalar(u8, g.vim_state.buf[0..g.vim_state.len], ' ') != null;
    updateGhost();
    if (refresh_blink) g.is_blink_visible = true;
    g.layout_dirty = true;
    g.redraw_pending = true;
    return true;
}

/// Inserts as much of the ghost completion as fits (clamped to the input
/// limit), then finishes the key press, which recomputes the ghost for the
/// new buffer. Returns true (event consumed).
fn acceptGhost() bool {
    const n_ghost: usize = if (g.ghost_len > 0 and g.vim_state.cursor == g.vim_state.len)
        @min(g.ghost_len, g.vim_state.max_input - 1 - g.vim_state.len)
    else
        0;
    if (n_ghost > 0) insertSlice(&g.vim_state, g.ghost_buf[0..n_ghost]);
    return finishKeyPress(.none, true);
}

/// Draw the title segment's content when the prompt is active, covering the
/// whole title slot. Returns the right edge (start_x + width). Only invoked by
/// the title segment's draw delegation while the prompt is open.
pub fn draw(ctx: *segmod.DrawCtx, x: u16) !u16 {
    // Clearing before the draw (not after) means a draw error still consumes
    // the request, so a persistently failing overlay can't re-request forever.
    g.blink_repaint = false;
    // While covered, title's pollTimeoutMsHook contributes no marquee wakeup
    // (title owns that decision), so no explicit carousel pause is needed here.
    return drawActive(ctx.dc, ctx.config, ctx.height, x, ctx.width);
}

/// Dispatches a vim.Action returned by a mode handler: executes/closes on spawn,
/// deactivates on deactivate, no-ops on none.
fn handleAction(action: Action) void {
    switch (action) {
        .none => {},
        .deactivate => deactivate(),
        .spawn => {
            runPromptCommand();
            deactivate();
        },
    }
}

fn runPromptCommand() void {
    const cmd = g.vim_state.buf[0..g.vim_state.len];
    if (cmd.len > 0) spawnCommand(cmd);
}

fn resetPromptEditing() void {
    g.vim_state.reset();
    g.ghost_len = 0;
    g.has_space = false;
    g.layout_dirty = true;
}

/// Acquires the keyboard grab and marks the prompt active.  Completion and
/// history buffers are allocated on first activation via `ensureAlloc`.
fn activate() void {
    ensureAlloc();
    resetPromptEditing();
    // Load completions and history on first activation.
    if (!g.is_completions_loaded and g.comp_names.len > 0) loadCompletions();
    if (!g.is_hist_loaded and g.hist_entries.len > 0) loadHistory();
    g.is_blink_visible = true;

    const cs = core.getState();
    const cookie = xcb.xcb_grab_keyboard(
        cs.conn,
        0,
        cs.root,
        xcb.XCB_CURRENT_TIME,
        xcb.XCB_GRAB_MODE_ASYNC,
        xcb.XCB_GRAB_MODE_ASYNC,
    );
    const grab_reply = xcb.xcb_grab_keyboard_reply(cs.conn, cookie, null);
    if (grab_reply == null) {
        debug.warn("prompt: xcb_grab_keyboard_reply returned null: aborting activation", .{});
        return;
    }
    defer std.c.free(grab_reply);
    if (grab_reply.*.status != xcb.XCB_GRAB_STATUS_SUCCESS) {
        debug.warn(
            "prompt: keyboard grab failed (status {}): aborting activation",
            .{grab_reply.*.status},
        );
        return;
    }
    g.is_active = true;
    g.layout_dirty = true;
    g.redraw_pending = true;
    // Force the bar to the absolute top for the prompt's duration so it's
    // always visible/reachable; reversed in deactivate() via dismissAfterPrompt().
    if (g.handlers) |h| h.presentForPrompt();
    // No xcb_flush: xcb_grab_keyboard_reply already drained the output buffer
    // and presentForPrompt() flushes its own requests; nothing is pending
    // here.  Contrast with deactivate(), where xcb_ungrab_keyboard must arrive
    // promptly.
}

fn deactivate() void {
    g.is_active = false;
    if (vimModeEnabled()) handlers.on_deactivate(&g.vim_state);
    const conn = core.getState().conn;
    _ = xcb.xcb_ungrab_keyboard(conn, xcb.XCB_CURRENT_TIME);
    _ = xcb.xcb_flush(conn);
    g.redraw_pending = true;
    // Return the bar to whatever state it was actually in before the prompt
    // forced it to the top (e.g. re-hide it if a fullscreen window is still
    // active): see the comment on presentForPrompt() in activate().
    if (g.handlers) |h| h.dismissAfterPrompt();
}

/// Scan every directory in $PATH and collect executable names into the static
/// completion table.  Called once on first activation.
fn loadCompletions() void {
    g.comp_count = 0;
    if (g.comp_names.len == 0) return; // ensureAlloc failed
    // Mark attempted up front: a missing $PATH or an empty result must not
    // re-trigger the scan on the next activation.
    g.is_completions_loaded = true;
    const path_env_ptr = c.getenv("PATH") orelse return;
    const path_env = std.mem.span(path_env_ptr);

    var dir_buf: [std.fs.max_path_bytes:0]u8 = undefined;

    var dir_it = paths.dirIterator(path_env);
    outer: while (dir_it.next()) |dir_path| {
        _ = copyToZ(&dir_buf, dir_path) orelse continue;

        const dirp = c.opendir(&dir_buf) orelse continue;
        defer _ = c.closedir(dirp);

        while (c.readdir(dirp)) |entry| {
            const name = std.mem.span(@as([*:0]const u8, @ptrCast(&entry.*.d_name)));
            // d_type 0 (DT_UNKNOWN on filesystems with no type) counts as a
            // candidate: it rules out only "obviously not a plain file"; the
            // X_OK probe inside isRunnableFile is the real test.
            const dt = entry.*.d_type;
            if (dt != 0 and dt != c.DT_REG and dt != c.DT_LNK) continue;
            if (!isRunnableFile(dir_path, name)) continue;
            if (offerCompletion(name)) break :outer;
        }
    }

    // Sort for O(log n) binary search in updateGhost.
    const slot_stride = max_completion_len + 1;
    const entries = @as([*][slot_stride]u8, @ptrCast(g.comp_names.ptr))[0..g.comp_count];
    std.sort.pdq([slot_stride]u8, entries, {}, struct {
        fn lt(_: void, a: [slot_stride]u8, b: [slot_stride]u8) bool {
            return std.mem.order(u8, std.mem.sliceTo(&a, 0), std.mem.sliceTo(&b, 0)) == .lt;
        }
    }.lt);
}

/// True when `name` under `dir_path` is executable, so it can be offered as a
/// command completion.  Filters empty/oversized/dot-prefixed names and probes
/// the executable bit on the joined path.
fn isRunnableFile(dir_path: []const u8, name: []const u8) bool {
    if (name.len == 0 or name.len > max_completion_len) return false;
    if (name[0] == '.') return false;

    var full_path_buf: [std.fs.max_path_bytes:0]u8 = undefined;
    _ = std.fmt.bufPrintZ(&full_path_buf, "{s}/{s}", .{ dir_path, name }) catch return false;
    return c.access(&full_path_buf, c.X_OK) == 0;
}

/// Stores `name` into the next completion slot.  Returns true when the table is
/// full and the $PATH scan should stop.
fn offerCompletion(name: []const u8) bool {
    const slot = g.comp_count * (max_completion_len + 1);
    @memcpy(g.comp_names[slot .. slot + name.len], name);
    g.comp_names[slot + name.len] = 0;
    g.comp_count += 1;
    return g.comp_count >= max_completions;
}

/// Binary searches the sorted completion table for the first entry >= `prefix`.
/// Returns the insertion index (0..comp_count); existence is an eql() at the
/// returned index, inlined at the call site.
fn compLowerBound(prefix: []const u8) usize {
    var lo: usize = 0;
    var hi: usize = g.comp_count;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (std.mem.order(u8, compName(mid), prefix) == .lt) lo = mid + 1 else hi = mid;
    }
    return lo;
}

fn compName(i: usize) []const u8 {
    const slot = i * (max_completion_len + 1);
    return std.mem.sliceTo(g.comp_names[slot .. slot + max_completion_len + 1], 0);
}

fn histEntry(i: usize) []const u8 {
    const slot = ((g.hist_head + i) % max_history) * (max_history_line + 1);
    return std.mem.sliceTo(g.hist_entries[slot .. slot + max_history_line + 1], 0);
}

/// Clamps `suffix` into g.ghost_buf/g.ghost_len.  Shared by both updateGhost
/// branches, which only differ in how they find the match.
inline fn setGhost(suffix: []const u8) void {
    // B1: ghost_buf is empty when its one-time allocation failed (partial OOM
    // in ensureAlloc). Slicing it for a non-empty suffix is then an OOB write.
    if (g.ghost_buf.len == 0) {
        g.ghost_len = 0;
        return;
    }
    const n = @min(suffix.len, max_completion_len);
    @memcpy(g.ghost_buf[0..n], suffix[0..n]);
    g.ghost_len = n;
}

/// Recompute the ghost-text suggestion based on the current buffer.
/// Priority: history (newest first) -> any executable match.
/// Only operates in INSERT mode with cursor at end and no spaces typed.
fn updateGhost() void {
    g.ghost_len = 0;

    if (g.vim_state.mode != .insert or g.vim_state.len == 0 or
        g.vim_state.cursor != g.vim_state.len or g.has_space) return;

    const prefix = g.vim_state.buf[0..g.vim_state.len];

    // 1. History-based suggestion (newest first)
    var hi: usize = 0;
    while (hi < g.hist_count) : (hi += 1) {
        const entry = histEntry(hi);
        if (entry.len == 0) continue;
        if (entry[0] != prefix[0]) continue;

        const cmd_end = std.mem.indexOfScalar(u8, entry, ' ') orelse entry.len;
        const cmd_tok = entry[0..cmd_end];

        if (cmd_tok.len <= prefix.len or !std.mem.startsWith(u8, cmd_tok, prefix)) continue;
        const idx = compLowerBound(cmd_tok);
        if (idx < g.comp_count and std.mem.eql(u8, compName(idx), cmd_tok))
            return setGhost(cmd_tok[prefix.len..]);
    }

    // 2. Fallback: shortest executable that starts with prefix.
    //    comp_names is sorted, so the first entry past the lower bound that
    //    starts with prefix and is longer than prefix IS the shortest match.
    var i: usize = compLowerBound(prefix);
    while (i < g.comp_count) : (i += 1) {
        const name = compName(i);
        if (!std.mem.startsWith(u8, name, prefix)) return; // past all prefix matches
        if (name.len <= prefix.len) continue; // exact match, not a completion
        return setGhost(name[prefix.len..]);
    }
}

/// Prepend `cmd` to the in-memory history ring (newest at index 0), shifting
/// entries right by one slot.
/// Silently no-ops when cmd is empty or exceeds max_history_line.
fn histPrepend(cmd: []const u8) void {
    if (cmd.len == 0 or cmd.len > max_history_line) return;
    // B1: hist_entries is empty when its one-time allocation failed (partial
    // OOM in ensureAlloc); don't index into it (OOB write at slot + cmd.len).
    if (g.hist_entries.len == 0) return;
    // Skip consecutive duplicates (shell convention): when the newest entry
    // already equals this command, re-running it must not stack the ring.
    if (g.hist_count > 0 and std.mem.eql(u8, histEntry(0), cmd)) return;

    g.hist_head = if (g.hist_head == 0) max_history - 1 else g.hist_head - 1;
    const slot = g.hist_head * (max_history_line + 1);
    @memcpy(g.hist_entries[slot .. slot + cmd.len], cmd);
    g.hist_entries[slot + cmd.len] = 0;
    if (g.hist_count < max_history) g.hist_count += 1;
}

fn histAppendToFile(cmd: []const u8) void {
    if (cmd.len == 0) return;
    const home = std.mem.span(c.getenv("HOME") orelse return);

    var path_buf: [history_path_buf_len:0]u8 = undefined;
    const file_path = std.fmt.bufPrintZ(
        &path_buf,
        "{s}/.local/share/drun/history",
        .{home},
    ) catch return;

    const last_sep = std.mem.lastIndexOfScalar(u8, file_path, '/') orelse return;
    path_buf[last_sep] = 0;
    _ = c.mkdir(@ptrCast(&path_buf), 0o700);
    path_buf[last_sep] = '/';

    const fd = c.open(@ptrCast(&path_buf), c.O_WRONLY | c.O_CREAT | c.O_APPEND, @as(c_int, 0o600));
    if (fd < 0) return;
    defer _ = c.close(fd);
    _ = c.write(fd, cmd.ptr, cmd.len);
    _ = c.write(fd, "\n", 1);
}

/// Parse one line from a shell history file into `out`, returning its length
/// (0 to skip).  Understands fish `"- cmd: ..."`, zsh `": <ts>:<elapsed>;..."` or
/// bare lines, and bash/drun bare lines (`#` timestamp markers skipped).
fn histParseLine(line: []const u8, out: []u8) usize {
    if (line.len == 0) return 0;

    var cmd = line;

    if (std.mem.startsWith(u8, cmd, "- cmd: ")) {
        cmd = cmd["- cmd: ".len..];
    } else if (cmd.len > 2 and cmd[0] == ':' and cmd[1] == ' ') {
        if (std.mem.indexOfScalar(u8, cmd, ';')) |semi| {
            cmd = cmd[semi + 1 ..];
        }
    } else if (cmd[0] == '#') {
        return 0;
    }

    cmd = std.mem.trim(u8, cmd, " \t\r");

    if (cmd.len == 0 or cmd.len > max_history_line) return 0;
    @memcpy(out[0..cmd.len], cmd);
    return cmd.len;
}

/// Fixed byte window read from a history file's tail: an overgrown
/// file must not push its newest entries out of reach of one bounded read.
const hist_read_window: usize = 256 * 1024 - 1;

/// Load history from `path` into the in-memory ring, processing lines in
/// reverse so the newest entry ends up at index 0.
fn histLoadFile(path: []const u8) void {
    const io = std.Options.debug_io;
    const file = std.Io.Dir.cwd().openFile(io, path, .{}) catch return;
    defer file.close(io);

    // History semantics want the NEWEST entries, which live at the file's
    // tail. Position the read window at EOF - window so an overgrown file
    // can't push recent entries out of the fixed read; a partial
    // line at the window head is dropped below.
    const fsize: u64 = if (file.stat(io) catch null) |st| st.size else 0;
    const read_off: u64 = if (fsize > hist_read_window) fsize - hist_read_window else 0;

    const file_buf = g.allocator.alloc(u8, hist_read_window) catch return;
    defer g.allocator.free(file_buf);
    const n_read = file.readPositionalAll(io, file_buf, read_off) catch return;
    if (n_read == 0) return;
    var text = file_buf[0..n_read];
    if (read_off > 0) {
        // Drop the cut-mid-line fragment at the window start; its real
        // content lives in the unread region before the window.
        const nl = std.mem.indexOfScalar(u8, text, '\n') orelse return;
        text = text[nl + 1 ..];
    }

    // Only the trailing max_lines lines are eligible: history consumers walk
    // them back-to-front for newest-first priority, so dropping the head of
    // an overgrown file keeps the freshest entries visible once it outgrows
    // the window. The ranges live in a ring indexed modulo max_lines, so the
    // scan only ever remembers the LAST max_lines lines.
    const max_lines = max_history * 2;
    var line_starts: [max_lines]usize = undefined;
    var line_ends: [max_lines]usize = undefined;
    var total: usize = 0;

    var pos: usize = 0;
    while (pos < text.len) {
        const end = std.mem.indexOfScalarPos(u8, text, pos, '\n') orelse text.len;
        line_starts[total % max_lines] = pos;
        line_ends[total % max_lines] = end;
        total += 1;
        pos = end + 1;
    }

    var out_line: [max_history_line]u8 = undefined;

    // Build a hash set of already-loaded entries so duplicate detection is O(1)
    // instead of O(n^2).  Pre-populate with any entries that were prepended by
    // earlier histLoadFile calls in the same session.
    var seen = std.AutoHashMapUnmanaged(u64, void){};
    defer seen.deinit(g.allocator);
    for (0..g.hist_count) |di| {
        seen.put(g.allocator, std.hash.Wyhash.hash(0, histEntry(di)), {}) catch {};
    }

    // Walk the kept lines back-to-front so the newest entry ends up at index 0.
    var li: usize = 0;
    while (li < @min(total, max_lines)) : (li += 1) {
        if (g.hist_count >= max_history) break;
        const ri = (total - 1 - li) % max_lines;
        const line = text[line_starts[ri]..line_ends[ri]];
        const len = histParseLine(line, &out_line);
        if (len == 0) continue;
        const h = std.hash.Wyhash.hash(0, out_line[0..len]);
        if (seen.contains(h)) continue;
        histPrepend(out_line[0..len]);
        seen.put(g.allocator, h, {}) catch {};
    }
}

/// Load history from drun -> bash -> zsh -> fish (load order).
/// Because `histPrepend()` inserts at index 0, fish ends up with the highest
/// suggestion priority in `updateGhost`.
fn loadHistory() void {
    g.is_hist_loaded = true;
    if (g.hist_entries.len == 0) return; // ensureAlloc failed

    var path_buf: [history_path_buf_len]u8 = undefined;
    const home = std.mem.span(c.getenv("HOME") orelse return);

    const history_suffixes = [_][]const u8{
        ".local/share/drun/history",
        ".bash_history",
        ".zsh_history",
        ".local/share/fish/fish_history",
    };
    for (history_suffixes) |suffix| {
        const path = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ home, suffix }) catch continue;
        histLoadFile(path);
    }
}

fn spawnCommand(cmd: []const u8) void {
    histPrepend(cmd);
    histAppendToFile(cmd);

    // cmd.len <= default_max_input - 1 (enforced by the vim buffer
    // insert clamp), so buf always has room for the null terminator.
    var buf: [default_max_input]u8 = undefined;
    @memcpy(buf[0..cmd.len], cmd);
    buf[cmd.len] = 0;
    const cmd_z: [*:0]const u8 = buf[0..cmd.len :0];

    const pid = c.fork();
    if (pid == 0) {
        // Double-fork detaches the grandchild from this process so the bar
        // does not wait on it when it exits.
        const pid2 = c.fork();
        if (pid2 == 0) {
            _ = c.setsid();
            const argv = [_:null]?[*:0]const u8{ "/bin/sh", "-c", cmd_z, null };
            _ = c.execvp("/bin/sh", @ptrCast(&argv));
            std.process.exit(1);
        }
        std.process.exit(0);
    } else if (pid > 0) {
        var status: c_int = 0;
        _ = c.waitpid(pid, &status, 0);
    }
}

const WidthRel = enum { ge, gt };

/// Binary search: first byte offset where `measureTextWidth(text[0..offset])`
/// is `>= t` (ge) or `> t` (gt). Returns `text.len` when no index satisfies
/// it. Mapped a pixel scroll offset to a character boundary (ge) or finds the
/// first index overflowing a width cap (gt); moved here from drawing.zig
/// (prompt is its only consumer).
fn measureBound(dc: *drawing.DrawContext, text: []const u8, t: u16, comptime rel: WidthRel) usize {
    var lo: usize = 0;
    var hi: usize = text.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        const w = dc.measureTextWidth(text[0..mid]);
        const past = if (rel == .ge) w >= t else w > t;
        if (!past) lo = mid + 1 else hi = mid;
    }
    return lo;
}

/// Draw `text` from the virtual pen `px` clipped to `[text_left_x, scroll_end_x)`.
/// Non-post (`post=false`) is the pre-cursor span: hard-clips both edges without
/// ellipsis and always advances `px.*` by the full text width, using the caller's
/// measured `text_w` (null to measure here). Post (`post=true`) ellipsizes on
/// overflow to the right edge and never advances the pen.
inline fn drawScrollSpan(
    comptime post: bool,
    dc: *drawing.DrawContext,
    px: *i32,
    text_left_x: u16,
    scroll_end_x: u16,
    baseline: u16,
    text: []const u8,
    text_w: ?u16,
    color: u32,
) !void {
    if (post) {
        if (text.len == 0 or px.* >= @as(i32, scroll_end_x)) return;
        const draw_x: u16 = @intCast(@max(px.*, @as(i32, text_left_x)));
        const remaining: u16 = scroll_end_x -| draw_x;
        if (remaining > 0)
            try dc.drawTextEllipsis(draw_x, baseline, text, remaining, color);
        return;
    }
    const w = text_w orelse dc.measureTextWidth(text);
    defer px.* += @intCast(w);
    if (w == 0) return;

    const tl: i32 = text_left_x;
    const se: i32 = scroll_end_x;

    // Fully off-screen to the left or right: nothing to draw.
    if (px.* + @as(i32, w) <= tl or px.* >= se) return;

    // Skip the prefix that lies off-screen to the left.
    const start: usize = if (px.* < tl) measureBound(dc, text, @intCast(tl - px.*), .ge) else 0;

    const draw_x: u16 = @intCast(@max(px.*, tl));
    const available: u16 = @intCast(se - @as(i32, draw_x));

    // Clip the visible suffix to the available width on the right.  When no
    // left clip occurred and the full text fits, `w` (already measured) skips
    // the binary-search pass entirely.
    const suffix = text[start..];
    const visible = if (start == 0 and w <= available)
        text
    else blk: {
        const sb = measureBound(dc, suffix, available, .gt);
        break :blk if (sb < suffix.len) suffix[0 .. sb - 1] else suffix;
    };
    if (visible.len > 0)
        try dc.drawText(draw_x, baseline, visible, color);
}

const CursorStyle = struct {
    text_left_x: u16,
    scroll_end_x: u16,
    baseline: u16,
    height: u16,
    accent: u32,
    bg: u32,
};

/// Draw a filled block cursor over `buf[lo..hi]` and advance `px.*` past it.
///
/// Shared by visual selection highlighting and the normal/replace character
/// cursor: "highlight a byte range with an accent block and inverse text".
/// `lo == hi` draws an empty space-sized block (end-of-line).
inline fn drawBlockCursor(
    dc: *drawing.DrawContext,
    px: *i32,
    style: CursorStyle,
    buf: []const u8,
    lo: usize,
    hi: usize,
    text_w: ?u16,
) !void {
    const block_text = if (hi > lo) buf[lo..hi] else " ";
    const block_w = @max(text_w orelse dc.measureTextWidth(block_text), min_cursor_px);

    if (px.* + @as(i32, block_w) > @as(i32, style.text_left_x) and px.* < @as(i32, style.scroll_end_x)) {
        const draw_x: u16 = @intCast(@max(px.*, @as(i32, style.text_left_x)));
        const vis_w: u16 = @intCast(@min(@as(i32, block_w), @as(i32, style.scroll_end_x) - px.*));
        if (vis_w > 0) {
            dc.fillRect(
                draw_x,
                cursor_v_pad,
                vis_w,
                style.height -| cursor_v_pad * 2,
                style.accent,
            );
            if (hi > lo)
                try dc.drawText(draw_x, style.baseline, block_text, style.bg);
        }
    }
    px.* += @intCast(block_w);
}

/// Lazily cache the caret geometry: font metrics and bar height are constant
/// between reloads, so this runs at most once.  Hoisted before the pill and
/// mode branches so the lazy-init runs exactly once regardless of which
/// branch executes first.
fn ensureCaretGeom(dc: *drawing.DrawContext, height: u16) void {
    if (g.cached_caret_top == null) {
        const asc, const desc = dc.font.getMetrics();
        const font_h: u16 = @intCast(@max(0, @as(i32, asc) + @as(i32, desc)));
        // The caret's top is the baseline less the ascent: vertical-centering
        // math identical to drawing.baselineY's (top_pad + asc), so derive it
        // from there instead of re-rolling the (height -| font_h) / 2 formula.
        // Clamp a possibly-negative ascent before the u16 cast.
        const asc_u: u16 = @intCast(@max(0, @as(i32, asc)));
        g.cached_caret_top = dc.baselineY(height) -| asc_u;
        g.cached_caret_h = @min(font_h, height);
    }
}

/// Pixel width of `text`, measured once and cached (font and text are
/// constant between reloads). Shared by promptWidth and the mode pill.
fn measureCached(cache: *?u16, dc: *drawing.DrawContext, text: []const u8) u16 {
    return cache.* orelse blk: {
        const w = dc.measureTextWidth(text);
        cache.* = w;
        break :blk w;
    };
}

/// Pixel width of the prompt text, measured once and cached (font and prompt
/// are constant between reloads).
fn promptWidth(dc: *drawing.DrawContext, prompt: []const u8) u16 {
    return measureCached(&g.cached_prompt_w, dc, prompt);
}

/// Recompute the cached caret widths and scroll offset, but only when
/// `layout_dirty` or a bar-height change demands it.  The caret-blink redraws
/// an identical frame every blink, so blink ticks reuse these instead of ~20
/// Pango shape passes per tick; the cache needs invalidating only when
/// buffer, cursor, mode, or height changes.
fn refreshLayoutCache(
    dc: *drawing.DrawContext,
    height: u16,
    prompt: []const u8,
    prompt_w: u16,
    pre_cur_text: []const u8,
    max_scroll_px: u16,
) void {
    if (!g.layout_dirty and height == g.cached_height) return;

    if (g.layout_dirty) g.cached_pre_w = dc.measureTextWidth(pre_cur_text);
    // When !layout_dirty: only height changed; text and cursor are unchanged,
    // so cached_pre_w remains valid.
    g.cached_caret_w = if (g.vim_state.mode == .insert)
        cursor_width
    else
        @max(
            dc.measureTextWidth(if (g.vim_state.cursor < g.vim_state.len)
                g.vim_state.buf[g.vim_state.cursor .. g.vim_state.cursor + 1]
            else
                " "),
            min_cursor_px,
        );

    var scroll_x: u16 = 0;
    const cursor_right = prompt_w + g.cached_pre_w + g.cached_caret_w;
    if (cursor_right > max_scroll_px) {
        const min_scroll: u16 = cursor_right -| max_scroll_px;
        // Snap scroll_x to the nearest character boundary at/past min_scroll:
        // without it, drawSpan renders text[start..] at text_left_x while the
        // character begins past it in virtual space: a phantom gap next to the
        // caret.
        if (min_scroll <= prompt_w) {
            const idx = measureBound(dc, prompt, min_scroll, .ge);
            scroll_x = dc.measureTextWidth(prompt[0..idx]);
        } else {
            const min_in_pre: u16 = min_scroll - prompt_w;
            const idx = measureBound(dc, pre_cur_text, min_in_pre, .ge);
            scroll_x = prompt_w + dc.measureTextWidth(pre_cur_text[0..idx]);
        }
    }
    g.cached_scroll_x = scroll_x;
    g.cached_height = height;
    g.layout_dirty = false;
}

/// Right-pinned mode widget: a filled pill (accent bg, white text) with
/// `pill_h_pad` on both sides so the text never touches the pill edge and
/// there's a gap to the scrollable region. The label is the active vim mode's
/// label (empty in the null-vim build, which skips the pill entirely).
///
/// Returns the scrollable region's right edge (the pill's left edge), or null
/// when no room remains for text; callers return immediately.
fn drawPill(
    dc: *drawing.DrawContext,
    height: u16,
    baseline: u16,
    text_left_x: u16,
    text_end_x: u16,
    accent: u32,
) ?u16 {
    const pill_h_pad: u16 = 6;
    const white: u32 = 0xFFFFFFFF;

    const vim_mode = vimModeEnabled();
    const mode_label = if (vim_mode) g.vim_state.mode.label() else "";
    const mode_idx: usize = @intFromEnum(g.vim_state.mode);
    const mode_w: u16 = measureCached(&g.cached_mode_w[mode_idx], dc, mode_label);

    // The pill only exists when there is a mode label (vim mode enabled);
    // basic mode gets the full width for the scrollable text region.
    const show_pill = mode_w > 0;
    const pill_w: u16 = mode_w + pill_h_pad * 2;
    const pill_fits = text_end_x >= pill_w;

    // Reserve the pill width on the right; the scrollable region ends here.
    // When the label cannot fit we drop the pill but still give the text the
    // whole region: blanking the prompt because the mode pill didn't fit hid
    // the user's typing (B2).
    const scroll_end_x: u16 = if (show_pill and pill_fits)
        text_end_x - pill_w
    else
        text_end_x;
    if (text_left_x >= scroll_end_x) return null;

    if (show_pill and pill_fits) {
        const pill_x: u16 = text_end_x - pill_w;
        dc.fillRect(
            pill_x,
            cursor_v_pad,
            pill_w,
            height -| cursor_v_pad * 2,
            accent,
        );
        try dc.drawText(pill_x + pill_h_pad, baseline, mode_label, white);
    }

    return scroll_end_x;
}

/// Insert mode: blinking thin caret; the caret position does not consume its
/// character, and ghost text appears dimmed after the cursor when at end.
/// Post-cursor text is drawn by the shared tail in drawActive.
fn drawInsertMode(
    dc: *drawing.DrawContext,
    baseline: u16,
    text_left_x: u16,
    scroll_end_x: u16,
    px: *i32,
    accent: u32,
) !void {
    // Caret geometry was pre-computed in ensureCaretGeom.
    const caret_top = g.cached_caret_top.?;
    const caret_h = g.cached_caret_h.?;
    if (g.is_blink_visible and px.* >= @as(i32, text_left_x) and px.* < @as(i32, scroll_end_x)) {
        dc.fillRect(@intCast(px.*), caret_top, cursor_width, caret_h, accent);
    }

    // Ghost text (only when cursor is at end).
    if (g.ghost_len > 0 and g.vim_state.cursor == g.vim_state.len)
        try drawScrollSpan(true, dc, px, text_left_x, scroll_end_x, baseline, g.ghost_buf[0..g.ghost_len], null, accent);
}

/// NORMAL: full-character block cursor. Post-cursor text is drawn by the
/// shared tail in drawActive.
fn drawNormalMode(
    dc: *drawing.DrawContext,
    height: u16,
    baseline: u16,
    text_left_x: u16,
    scroll_end_x: u16,
    px: *i32,
    accent: u32,
    bg: u32,
) !void {
    const cur_hi = @min(g.vim_state.cursor + @intFromBool(g.vim_state.mode != .insert), g.vim_state.len);

    const style: CursorStyle = .{ .text_left_x = text_left_x, .scroll_end_x = scroll_end_x, .baseline = baseline, .height = height, .accent = accent, .bg = bg };
    try drawBlockCursor(
        dc,
        px,
        style,
        g.vim_state.buf,
        g.vim_state.cursor,
        cur_hi,
        g.cached_caret_w,
    );
}

/// Render the active input UI.
///
/// Layout: [ pad | scrollable: PROMPT | pre | CURSOR/SELECTION | post |
/// MODE_LABEL | pad ].  The mode label is pinned right (never scrolls); the
/// scrollable region keeps the cursor in view.
fn drawActive(
    dc: *drawing.DrawContext,
    config: types.BarConfig,
    height: u16,
    start_x: u16,
    width: u16,
) !u16 {
    const end_x = start_x + width;
    const pad = config.scaledSegmentPadding(height);
    const accent = config.drunPromptColor();
    const bg = config.drunBg();
    const fg = config.drunFg();
    const prompt = config.drun_prompt orelse types.default_drun_prompt;

    dc.fillRect(start_x, 0, width, height, bg);

    const baseline = dc.baselineY(height);
    const text_left_x = start_x + pad;
    const text_end_x = end_x -| pad;
    if (text_left_x >= text_end_x) return end_x;

    ensureCaretGeom(dc, height);

    // Mode widget, pinned right; does not scroll.  Its left edge bounds the
    // scrollable text region.
    const scroll_end_x = drawPill(dc, height, baseline, text_left_x, text_end_x, accent) orelse
        return end_x;
    // Clip post-cursor text 2 px before the pill so ink never bleeds into it.
    const post_clip_end_x = scroll_end_x -| 2;

    const max_scroll_px: u16 = scroll_end_x - text_left_x;
    const prompt_w = promptWidth(dc, prompt);

    // In INSERT mode the caret doesn't consume its character; post_text
    // starts at cursor and caret_w is `cursor_width`; all other modes use a
    // full-character block.
    const pre_cur_text = g.vim_state.buf[0..g.vim_state.cursor];
    refreshLayoutCache(dc, height, prompt, prompt_w, pre_cur_text, max_scroll_px);

    // Draw prompt.
    var px: i32 = @as(i32, text_left_x) - @as(i32, g.cached_scroll_x);
    try drawScrollSpan(false, dc, &px, text_left_x, scroll_end_x, baseline, prompt, prompt_w, accent);

    // Pre-cursor span: rendered identically as the first step of BOTH modes,
    // so it's hoisted here and the branch bodies carry only what differs.
    if (pre_cur_text.len > 0)
        try drawScrollSpan(false, dc, &px, text_left_x, scroll_end_x, baseline, pre_cur_text, g.cached_pre_w, fg);

    // Mode-specific caret/ghost rendering; post-cursor text is common to both
    // (the block cursor advances px past its own character in NORMAL, the
    // caret consumes none in INSERT), so it is drawn once below.
    switch (g.vim_state.mode) {
        .insert => try drawInsertMode(dc, baseline, text_left_x, scroll_end_x, &px, accent),
        else => try drawNormalMode(dc, height, baseline, text_left_x, scroll_end_x, &px, accent, bg),
    }

    const post_start = @min(g.vim_state.cursor + @intFromBool(g.vim_state.mode != .insert), g.vim_state.len);
    try drawScrollSpan(true, dc, &px, text_left_x, post_clip_end_x, baseline, g.vim_state.buf[post_start..g.vim_state.len], null, fg);

    // No blitRegion here: the prompt draws as a segment inside performDraw,
    // whose end-of-batch queueBlit copies the whole frame (and the caller
    // flushes it). A mid-frame region copy+flush here would (a) enqueue a
    // redundant second copy_area + flush per prompt frame and, worse, (b)
    // snapshot the off-screen pixmap BEFORE sibling segments in the same
    // batch are painted, briefly showing stale neighbors. Let the batch-end
    // full blit win.
    return end_x;
}

/// This module's bar-segment contribution. The prompt is a runtime overlay
/// on the title slot: it is NOT configurable from config (configurable =
/// false) but still joins the bar's uniform lifecycle/poll loops.
fn drawHook(ctx: *anyopaque, x: u16) !u16 {
    const dc = segmod.castDraw(ctx);
    return draw(dc, x);
}

pub const module: @import("plugin").Segment = .{
    .name = "prompt",
    .configurable = false,
    .init = init,
    .deinit = deinit,
    .pollTimeoutMs = blinkPollTimeoutMs,
    .onPollWakeup = blinkTick,
    .draw = drawHook,
    .handleKeypress = handlePromptKeypress,
    .consumeRedrawRequest = consumeRedrawRequest,
    .invalidateReloadCaches = invalidateReloadCaches,
    .overlay = .{
        .is_active = isActive,
        .toggle = toggle,
        .draw = drawHook,
        .needsRepaint = overlayNeedsRepaint,
    },
};
