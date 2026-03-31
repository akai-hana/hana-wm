//! Prompt segment — dwm-style command runner embedded in the status bar.
//!
//! When active, the title segment area becomes a text input field. The user
//! can type a shell command and press Return to execute it via sh(1). A full
//! vim-style modal editing layer is built in; see vim.zig for details.
//!
//! Integration points:
//!   - `bar.zig` dispatches the `.title` segment to `prompt.draw()` when
//!     `isActive()` is true and guards `drawTitleOnly()` accordingly.
//!   - The main event loop routes key-press events through
//!     `handlePromptKeypress()` before normal keybind dispatch.
//!   - A "toggle_prompt" action calls `toggle()`.
//!   - `bar.init` / `bar.deinit` call `prompt.init` / `prompt.deinit`.

const std     = @import("std");
const core    = @import("core");
const types   = @import("types");
const xcb     = core.xcb;
const drawing = @import("drawing");
const title   = @import("title");
const debug   = @import("debug");
pub const vim = @import("vim");

const c = @cImport({
    @cInclude("unistd.h");
    @cInclude("stdlib.h");
    @cInclude("stdio.h");
    @cInclude("fcntl.h");
    @cInclude("dirent.h");
    @cInclude("sys/stat.h");
    @cInclude("sys/wait.h");
});

// ---------------------------------------------------------------------------
// xcb-keysyms bindings (link with -lxcb-keysyms)
// ---------------------------------------------------------------------------

const xcb_key_symbols_t = opaque {};

extern fn xcb_key_symbols_alloc(conn: *xcb.xcb_connection_t) ?*xcb_key_symbols_t;
extern fn xcb_key_symbols_free(syms: *xcb_key_symbols_t) void;
extern fn xcb_key_symbols_get_keysym(syms: *xcb_key_symbols_t, code: xcb.xcb_keycode_t, col: c_int) xcb.xcb_keysym_t;

// ---------------------------------------------------------------------------
// Module constants
// ---------------------------------------------------------------------------

/// Minimum pixel width of the block cursor; ensures it is visible even on
/// the narrowest glyphs (e.g. '.', '!').
const min_cursor_px: u16 = 8;
/// Width of the blinking caret in insert mode (pixels).
const cursor_width: u16 = 1;
/// Cursor blink half-period: cursor is visible for this many ms, then
/// invisible for the same duration.
const cursor_blink_ms: u64 = 300;
/// Vertical padding (pixels) above and below the block cursor / selection.
const cursor_v_pad: u16 = 2;
/// Maximum number of executable names stored for tab-completion.
const max_completions: usize = 4096;
/// Maximum byte length of a single completion entry (executable name).
const max_completion_len: usize = 64;
/// Maximum number of history entries kept in memory.
const max_history: usize = 512;
/// Maximum byte length of a single history entry.
const max_history_line: usize = vim.default_max_input;

// ---------------------------------------------------------------------------
// Module state
// ---------------------------------------------------------------------------

/// All mutable state owned by this module.
const PromptState = struct {
    is_active: bool         = false,
    vim_state: vim.VimState = .{},

    allocator: std.mem.Allocator = undefined,

    key_syms:        ?*xcb_key_symbols_t = null,
    cached_prompt_w: ?u16                = null,
    /// Cached pixel width of each mode label, indexed by `vim.Mode` integer value.
    cached_mode_w:   [4]?u16             = .{ null, null, null, null },

    // PATH completion
    comp_names: []u8  = &.{},
    comp_count: usize = 0,

    /// Ghost text: the completion suffix shown dimmed after the cursor.
    ghost_buf: []u8  = &.{},
    ghost_len: usize = 0,
    /// True when the current buffer contains at least one space.  Maintained
    /// incrementally so `updateGhost` can skip a full buffer scan on every call.
    has_space: bool = false,

    is_blink_visible: bool = true,

    /// Caret geometry cached after the first insert-mode draw.  Font metrics
    /// and bar height are constant between reloads, so these never need clearing.
    cached_caret_top: ?u16 = null,
    cached_caret_h:   ?u16 = null,

    // Command history (newest at index 0)
    hist_entries: []u8  = &.{},
    hist_count:   usize = 0,
    is_hist_loaded: bool = false,

    /// Set by key handlers, `activate`, and `deactivate` to notify the bar
    /// that the prompt area needs to be redrawn.  Consumed (read + cleared)
    /// by `consumeRedrawRequest` to avoid a circular import between prompt ↔ bar.
    redraw_pending: bool = false,
};

var g: PromptState = .{};

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

pub fn isActive() bool { return g.is_active; }

/// Returns true when the prompt is active in insert mode, signalling that
/// the bar should schedule a periodic redraw for the cursor blink animation.
pub fn needsRedraw() bool {
    if (!g.is_active) return false;
    return g.vim_state.mode == .insert or vim.colonInput(&g.vim_state) != null;
}

/// Returns the milliseconds until the next blink toggle, or -1 if the cursor
/// blink animation is not running.  Pass this (combined with the clock timeout)
/// to poll() so the event loop wakes up exactly when a redraw is needed.
pub fn blinkPollTimeoutMs() i32 {
    if (!g.is_active) return -1;
    if (g.vim_state.mode == .insert or vim.colonInput(&g.vim_state) != null)
        return cursor_blink_ms;
    return -1;
}

/// Toggle cursor visibility.  Call from the event loop on every poll timeout
/// where `blinkPollTimeoutMs() >= 0`, then trigger a bar redraw.
pub fn blinkTick() void {
    g.is_blink_visible = !g.is_blink_visible;
}

/// Returns true and clears the flag if a prompt-driven redraw is outstanding.
/// Call once per event-loop iteration from `bar.updateIfDirty`.
pub fn consumeRedrawRequest() bool {
    const pending = g.redraw_pending;
    g.redraw_pending = false;
    return pending;
}

pub fn init(allocator: std.mem.Allocator, conn: *xcb.xcb_connection_t) !void {
    if (g.vim_state.buf.len != 0) return; // already initialised
    g.allocator   = allocator;
    g.vim_state   = try vim.VimState.init(allocator, vim.default_max_input, vim.default_undo_max);
    g.comp_names  = try allocator.alloc(u8, (max_completion_len + 1) * max_completions);
    g.ghost_buf   = try allocator.alloc(u8, max_completion_len);
    g.hist_entries= try allocator.alloc(u8, (max_history_line + 1) * max_history);
    g.key_syms    = xcb_key_symbols_alloc(conn);
    if (g.key_syms == null)
        debug.warn("prompt: xcb_key_symbols_alloc failed — key input will not work", .{});
}

pub fn deinit() void {
    if (g.key_syms) |ks| {
        xcb_key_symbols_free(ks);
        g.key_syms = null;
    }
    if (g.vim_state.buf.len != 0) g.vim_state.deinit();
    if (g.hist_entries.len  != 0) g.allocator.free(g.hist_entries);
    if (g.ghost_buf.len     != 0) g.allocator.free(g.ghost_buf);
    if (g.comp_names.len    != 0) g.allocator.free(g.comp_names);
    g = .{};
}

pub fn toggle() void {
    if (g.is_active) deactivate() else activate();
}

/// Complete key-event routing entry point called by `input.zig`.
///
/// Owns all prompt-specific routing decisions so `input.zig` stays free of
/// prompt internals:
///   - Returns false immediately when the prompt is inactive, so the caller
///     falls through to normal keybind dispatch without any special-casing.
///   - If the key is bound to `close_window`, dismisses the prompt instead of
///     closing a window or silently swallowing the keystroke.
///   - Otherwise delegates to `handleKeyPress` which processes the raw key.
///
/// `bound_action` is whatever the keybind map resolved for this key; pass
/// `state.map.get(key)` directly — null is fine when there is no binding.
pub fn handlePromptKeypress(
    event:        *const xcb.xcb_key_press_event_t,
    bound_action: ?*const types.Action,
) bool {
    if (!g.is_active) return false;
    if (bound_action) |action| if (action.* == .close_window) {
        deactivate();
        return true;
    };
    return handleKeyPress(event);
}

/// Low-level key-press handler.  Called by `handlePromptKeypress` after all
/// prompt-level routing decisions have been made.
///
/// Exposed as `pub` so the bar's legacy key dispatch path can call it
/// directly when it has already confirmed the prompt is active.  Prefer
/// `handlePromptKeypress` for new call sites.
pub fn handleKeyPress(event: *const xcb.xcb_key_press_event_t) bool {
    if (!g.is_active) return false;

    // Only process XCB_KEY_PRESS events.  xcb_key_press_event_t and
    // xcb_key_release_event_t share the same struct layout, so the event loop
    // can (and sometimes does) cast a release event and dispatch it here.
    //
    // Without this guard the XCB_KEY_RELEASE for Escape is a fatal trap:
    //   1. XCB_KEY_PRESS  (Escape): handleInsert switches mode to .normal ✓
    //   2. XCB_KEY_RELEASE(Escape): handleNormal sees XK_Escape with a clean
    //      pending (op=0, count=0) → returns .deactivate → prompt closes.
    // The user then presses 'b' or an arrow key to start editing in normal
    // mode, but the prompt is already gone — so those keys get the blame.
    //
    // Returning true (not false) for non-press events ensures the caller
    // considers the event consumed and does not fall through to WM keybind
    // dispatch for the release.
    if (event.response_type & 0x7F != xcb.XCB_KEY_PRESS) return true;

    const syms = g.key_syms orelse return false;

    const shift_held = event.state & xcb.XCB_MOD_MASK_SHIFT   != 0;
    const ctrl_held  = event.state & xcb.XCB_MOD_MASK_CONTROL != 0;
    const col: c_int = if (shift_held) 1 else 0;
    const sym        = xcb_key_symbols_get_keysym(syms, event.detail, col);

    // Drop bare modifier key events (Shift, Ctrl, Alt, Super, Meta, Hyper …).
    //
    // XCB delivers a XCB_KEY_PRESS event for every key including modifiers, so
    // pressing Shift before typing '$' or '^' fires a key event with keysym
    // 0xFFE1/0xFFE2 (XK_Shift_L/R) before the '$'/'^' event arrives.  If that
    // event reaches handleNormal it falls through to resetPendingCmd(), clearing
    // any pending operator ('d', 'c', 'y') or accumulated count — which is why
    // operator+motion sequences that require Shift (d$, d^, dW, dE, c$, y^,
    // visual 3W, …) silently turn into bare cursor moves instead of edits.
    //
    // Modifier keysyms occupy the contiguous range 0xFFE1–0xFFEE; nothing in
    // that band is a valid editing key (editing specials such as Escape/Return/
    // BackSpace/Delete/Arrow/Home/End all live elsewhere in 0xFF00–0xFFFF).
    if (sym >= 0xFFE0 and sym <= 0xFFEF) return true;

    // Ctrl-modified keys
    if (ctrl_held) {
        const action   = vim.handleCtrl(&g.vim_state, sym);
        const prev_len = g.vim_state.len;
        handleAction(action);
        if (g.vim_state.len != prev_len)
            g.has_space = std.mem.indexOfScalar(u8, g.vim_state.buf[0..g.vim_state.len], ' ') != null;
        g.redraw_pending = true;
        return true;
    }

    // Tab: accept ghost completion
    if (sym == vim.XK_Tab and g.vim_state.mode == .insert) {
        const n_ghost: usize = if (g.ghost_len > 0 and g.vim_state.cursor == g.vim_state.len)
            @min(g.ghost_len, g.vim_state.max_input - 1 - g.vim_state.len)
        else 0;
        if (n_ghost > 0) {
            vim.insertSlice(&g.vim_state, g.ghost_buf[0..n_ghost]);
            g.ghost_len = 0;
        }
        g.is_blink_visible = true;
        g.redraw_pending   = true;
        return true;
    }

    // Dispatch to mode handler
    const action = switch (g.vim_state.mode) {
        .insert  => vim.handleInsert(&g.vim_state, sym),
        .normal  => vim.handleNormal(&g.vim_state, sym),
        .visual  => vim.handleVisual(&g.vim_state, sym),
        .replace => vim.handleReplace(&g.vim_state, sym),
    };
    const prev_len = g.vim_state.len;
    handleAction(action);
    if (g.vim_state.len != prev_len)
        g.has_space = std.mem.indexOfScalar(u8, g.vim_state.buf[0..g.vim_state.len], ' ') != null;
    updateGhost();
    g.is_blink_visible = true;
    g.redraw_pending   = true;
    return true;
}

pub fn draw(
    dc:                  *drawing.DrawContext,
    config:              types.BarConfig,
    height:              u16,
    start_x:             u16,
    width:               u16,
    conn:                *xcb.xcb_connection_t,
    focused_window:      ?u32,
    focused_title:       []const u8,
    current_ws_wins:     []const u32,
    minimized_set:       *const std.AutoHashMapUnmanaged(u32, void),
    cached_title:        *std.ArrayList(u8),
    cached_title_window: *?u32,
    title_invalidated:   bool,
    allocator:           std.mem.Allocator,
) !u16 {
    if (!g.is_active) return title.draw(
        .{
            .dc      = dc,
            .config  = config,
            .height  = height,
            .start_x = start_x,
            .width   = width,
            .conn    = conn,
        },
        .{
            .focused_window  = focused_window,
            .focused_title   = focused_title,
            .minimized_title = "",
            .current_ws_wins = current_ws_wins,
            .minimized_set   = minimized_set,
        },
        .{
            .cached_title        = cached_title,
            .cached_title_window = cached_title_window,
        },
        allocator,
        title_invalidated,
    );
    return drawActive(dc, config, height, start_x, width);
}

// ---------------------------------------------------------------------------
// Private — action handling
// ---------------------------------------------------------------------------

fn handleAction(action: vim.Action) void {
    switch (action) {
        .none       => {},
        .deactivate => deactivate(),
        .spawn      => {
            const cmd = g.vim_state.buf[0..g.vim_state.len];
            if (cmd.len > 0) spawnCommand(cmd);
            deactivate();
        },
        // :w — execute the current command but keep the prompt open so the
        // user can immediately type a new one.  The buffer is cleared and the
        // mode is reset to INSERT, mirroring what activate() does without the
        // keyboard-grab overhead (the grab is already held).
        .spawn_keep => {
            const cmd = g.vim_state.buf[0..g.vim_state.len];
            if (cmd.len > 0) spawnCommand(cmd);
            resetVimEditing(&g.vim_state);
            g.ghost_len = 0;
            g.has_space = false;
        },
    }
}

// ---------------------------------------------------------------------------
// Private — activate / deactivate
// ---------------------------------------------------------------------------

/// Reset all `VimState` editing fields to their defaults without touching the
/// heap-allocated buffers (buf, yank_buf, undo/redo stacks, etc.).
fn resetVimEditing(vs: *vim.VimState) void {
    const allocator         = vs.allocator;
    const max_input         = vs.max_input;
    const undo_max          = vs.undo_max;
    const buf               = vs.buf;
    const yank_buf          = vs.yank_buf;
    const replace_origin_buf= vs.replace_origin_buf;
    const insert_rec_buf    = vs.insert_rec_buf;
    const dot_insert_buf    = vs.dot_insert_buf;
    const undo_entries      = vs.undo.entries;
    const redo_entries      = vs.redo.entries;
    vs.* = .{
        .allocator          = allocator,
        .max_input          = max_input,
        .undo_max           = undo_max,
        .buf                = buf,
        .yank_buf           = yank_buf,
        .replace_origin_buf = replace_origin_buf,
        .insert_rec_buf     = insert_rec_buf,
        .dot_insert_buf     = dot_insert_buf,
        // Preserve heap allocations; top and base default to 0 (history cleared).
        .undo = .{ .entries = undo_entries },
        .redo = .{ .entries = redo_entries },
    };
}

fn activate() void {
    resetVimEditing(&g.vim_state); // reset editing state, preserve heap allocations
    g.ghost_len = 0;
    g.has_space = false;
    // Load completions and history on first activation.
    if (g.comp_count == 0)   loadCompletions();
    if (!g.is_hist_loaded)   loadHistory();
    g.is_blink_visible = true;

    const cookie = xcb.xcb_grab_keyboard(
        core.conn, 0, core.root, xcb.XCB_CURRENT_TIME,
        xcb.XCB_GRAB_MODE_ASYNC, xcb.XCB_GRAB_MODE_ASYNC,
    );
    const grab_reply = xcb.xcb_grab_keyboard_reply(core.conn, cookie, null);
    if (grab_reply == null) {
        debug.warn("prompt: xcb_grab_keyboard_reply returned null — aborting activation", .{});
        return;
    }
    defer std.c.free(grab_reply);
    if (grab_reply.*.status != xcb.XCB_GRAB_STATUS_SUCCESS) {
        debug.warn("prompt: keyboard grab failed (status {}) — aborting activation", .{grab_reply.*.status});
        return;
    }
    g.is_active      = true;
    g.redraw_pending = true;
    _ = xcb.xcb_flush(core.conn);
}

fn deactivate() void {
    g.is_active                   = false;
    g.vim_state.is_replaying_dot  = false;
    g.vim_state.is_recording_insert = false;
    vim.resetPendingCmd(&g.vim_state);
    _ = xcb.xcb_ungrab_keyboard(core.conn, xcb.XCB_CURRENT_TIME);
    _ = xcb.xcb_flush(core.conn);
    g.redraw_pending = true;
}

// ---------------------------------------------------------------------------
// Private — PATH completion
// ---------------------------------------------------------------------------

/// Scan every directory in $PATH and collect executable names into the static
/// completion table.  Called once on first activation.
fn loadCompletions() void {
    g.comp_count = 0;
    const path_env_ptr = c.getenv("PATH") orelse return;
    const path_env = std.mem.span(path_env_ptr);

    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;

    var dir_it = std.mem.splitScalar(u8, path_env, ':');
    outer: while (dir_it.next()) |dir_path| {
        if (dir_path.len == 0 or dir_path.len >= dir_buf.len) continue;
        @memcpy(dir_buf[0..dir_path.len], dir_path);
        dir_buf[dir_path.len] = 0;

        const dirp = c.opendir(&dir_buf) orelse continue;
        defer _ = c.closedir(dirp);

        while (c.readdir(dirp)) |entry| {
            const d_name: [*:0]const u8 = @ptrCast(&entry.*.d_name);
            const name = std.mem.span(d_name);
            if (name.len == 0 or name.len > max_completion_len) continue;
            if (name[0] == '.') continue;

            const dt = entry.*.d_type;
            if (dt != 0 and dt != c.DT_REG and dt != c.DT_LNK) continue;

            const slot = g.comp_count * (max_completion_len + 1);
            @memcpy(g.comp_names[slot .. slot + name.len], name);
            g.comp_names[slot + name.len] = 0;
            g.comp_count += 1;
            if (g.comp_count >= max_completions) break :outer;
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

/// Binary search `comp_names` (which must be sorted) for an exact match.
fn compExistsExact(name: []const u8) bool {
    var lo: usize = 0;
    var hi: usize = g.comp_count;
    while (lo < hi) {
        const mid  = lo + (hi - lo) / 2;
        const slot = mid * (max_completion_len + 1);
        const entry = std.mem.sliceTo(g.comp_names[slot .. slot + max_completion_len + 1], 0);
        switch (std.mem.order(u8, entry, name)) {
            .lt => lo = mid + 1,
            .gt => hi = mid,
            .eq => return true,
        }
    }
    return false;
}

/// Binary search for the first `comp_names` entry >= prefix.
/// Used as the starting point for prefix scanning in `updateGhost`.
fn compLowerBound(prefix: []const u8) usize {
    var lo: usize = 0;
    var hi: usize = g.comp_count;
    while (lo < hi) {
        const mid  = lo + (hi - lo) / 2;
        const slot = mid * (max_completion_len + 1);
        const entry = std.mem.sliceTo(g.comp_names[slot .. slot + max_completion_len + 1], 0);
        if (std.mem.order(u8, entry, prefix) == .lt) lo = mid + 1 else hi = mid;
    }
    return lo;
}

/// Recompute the ghost-text suggestion based on the current buffer.
/// Priority: history (newest first) → any executable match.
/// Only operates in INSERT mode with cursor at end and no spaces typed.
fn updateGhost() void {
    g.ghost_len = 0;

    if (g.vim_state.mode != .insert)                          return;
    if (g.vim_state.len == 0 or g.vim_state.cursor != g.vim_state.len) return;
    if (g.has_space)                                          return;

    const prefix = g.vim_state.buf[0..g.vim_state.len];

    // 1. History-based suggestion (newest first)
    var hi: usize = 0;
    while (hi < g.hist_count) : (hi += 1) {
        const hslot = hi * (max_history_line + 1);
        const entry = std.mem.sliceTo(g.hist_entries[hslot .. hslot + max_history_line + 1], 0);
        if (entry.len == 0) continue;

        const cmd_end = std.mem.indexOfScalar(u8, entry, ' ') orelse entry.len;
        const cmd_tok = entry[0..cmd_end];

        if (cmd_tok.len <= prefix.len)               continue;
        if (!std.mem.startsWith(u8, cmd_tok, prefix)) continue;
        if (!compExistsExact(cmd_tok))                continue;

        const suffix = cmd_tok[prefix.len..];
        const n = @min(suffix.len, max_completion_len);
        @memcpy(g.ghost_buf[0..n], suffix[0..n]);
        g.ghost_len = n;
        return;
    }

    // 2. Fallback: shortest executable that starts with prefix.
    //    comp_names is sorted, so the first entry past the lower bound that
    //    starts with prefix and is longer than prefix IS the shortest match.
    var i: usize = compLowerBound(prefix);
    while (i < g.comp_count) : (i += 1) {
        const slot = i * (max_completion_len + 1);
        const name = std.mem.sliceTo(g.comp_names[slot .. slot + max_completion_len + 1], 0);
        if (!std.mem.startsWith(u8, name, prefix)) return; // past all prefix matches
        if (name.len <= prefix.len) continue;              // exact match, not a completion
        const suffix = name[prefix.len..];
        const n = @min(suffix.len, max_completion_len);
        @memcpy(g.ghost_buf[0..n], suffix[0..n]);
        g.ghost_len = n;
        return;
    }
}

// ---------------------------------------------------------------------------
// Private — history
// ---------------------------------------------------------------------------

/// Prepend `cmd` to the in-memory history ring (newest at index 0).
fn histPrepend(cmd: []const u8) void {
    if (cmd.len == 0 or cmd.len > max_history_line) return;

    const keep = @min(g.hist_count, max_history - 1);
    var i: usize = keep;
    while (i > 0) : (i -= 1) {
        const src = (i - 1) * (max_history_line + 1);
        const dst =  i      * (max_history_line + 1);
        @memcpy(g.hist_entries[dst .. dst + max_history_line + 1],
                g.hist_entries[src .. src + max_history_line + 1]);
    }
    @memcpy(g.hist_entries[0..cmd.len], cmd);
    g.hist_entries[cmd.len] = 0;
    if (g.hist_count < max_history) g.hist_count += 1;
}

/// Append `cmd` to the prompt's own history file (~/.local/share/drun/history).
fn histAppendToFile(cmd: []const u8) void {
    if (cmd.len == 0) return;
    const home = std.mem.span(c.getenv("HOME") orelse return);

    var dir_buf:  [512:0]u8 = undefined;
    var file_buf: [512:0]u8 = undefined;

    _ = std.fmt.bufPrintZ(&dir_buf,  "{s}/.local/share/drun",        .{home}) catch return;
    _ = std.fmt.bufPrintZ(&file_buf, "{s}/.local/share/drun/history", .{home}) catch return;

    _ = c.mkdir(&dir_buf, 0o700);

    const fd = c.open(&file_buf, c.O_WRONLY | c.O_CREAT | c.O_APPEND, @as(c_int, 0o600));
    if (fd < 0) return;
    defer _ = c.close(fd);
    _ = c.write(fd, cmd.ptr, cmd.len);
    _ = c.write(fd, "\n", 1);
}

/// Parse one line from a shell history file into `out`, returning its length.
/// Returns 0 to skip the line.
///
/// Formats understood:
///   fish  : `"- cmd: <command>"` (YAML block)
///   zsh   : `": <ts>:<elapsed>;<command>"` OR bare line
///   bash  : bare line (may have `"#<timestamp>"` markers which are skipped)
///   drun  : bare line
fn histParseLine(line: []const u8, out: []u8) usize {
    if (line.len == 0) return 0;

    var cmd = line;

    if (std.mem.startsWith(u8, cmd, "- cmd: ")) {
        cmd = cmd["- cmd: ".len..];
    } else if (cmd.len > 2 and cmd[0] == ':' and cmd[1] == ' ') {
        if (std.mem.indexOfScalar(u8, cmd, ';')) |semi| {
            cmd = cmd[semi + 1..];
        }
    } else if (cmd[0] == '#') {
        return 0;
    }

    cmd = std.mem.trim(u8, cmd, " \t\r");

    if (cmd.len == 0 or cmd.len > max_history_line) return 0;
    @memcpy(out[0..cmd.len], cmd);
    return cmd.len;
}

/// Load history from a file, processing lines in reverse so the newest entry
/// ends up at index 0.
fn histLoadFile(fp: *c.FILE) void {
    const file_buf_size = 256 * 1024;
    const file_buf: []u8 = blk: {
        const ptr = c.malloc(file_buf_size) orelse return;
        break :blk @as([*]u8, @ptrCast(ptr))[0..file_buf_size];
    };
    defer c.free(file_buf.ptr);

    const n_read = c.fread(file_buf.ptr, 1, file_buf_size - 1, fp);
    if (n_read == 0) return;
    const text = file_buf[0..n_read];

    const max_lines_cap = max_history * 2;
    const lines_raw = c.malloc(@sizeOf(usize) * max_lines_cap * 2) orelse return;
    defer c.free(lines_raw);
    const lines_buf   = @as([*]usize, @ptrCast(@alignCast(lines_raw)));
    const line_starts = lines_buf[0..max_lines_cap];
    const line_ends   = lines_buf[max_lines_cap .. max_lines_cap * 2];

    var n_lines: usize = 0;
    var pos: usize = 0;
    while (pos < text.len and n_lines < max_lines_cap) {
        const line_start = pos;
        while (pos < text.len and text[pos] != '\n') : (pos += 1) {}
        const line_end = pos;
        if (pos < text.len) pos += 1;
        line_starts[n_lines] = line_start;
        line_ends[n_lines]   = line_end;
        n_lines += 1;
    }

    var out_line: [max_history_line]u8 = undefined;

    // Build a hash set of already-loaded entries so duplicate detection is O(1)
    // instead of O(n²).  Pre-populate with any entries that were prepended by
    // earlier histLoadFile calls in the same session.
    var seen = std.AutoHashMapUnmanaged(u64, void){};
    defer seen.deinit(g.allocator);
    for (0..g.hist_count) |di| {
        const dslot    = di * (max_history_line + 1);
        const existing = std.mem.sliceTo(g.hist_entries[dslot .. dslot + max_history_line + 1], 0);
        seen.put(g.allocator, std.hash.Wyhash.hash(0, existing), {}) catch {};
    }

    var li: usize = n_lines;
    while (li > 0) {
        li -= 1;
        if (g.hist_count >= max_history) break;
        const line = text[line_starts[li]..line_ends[li]];
        const len = histParseLine(line, &out_line);
        if (len == 0) continue;
        const h = std.hash.Wyhash.hash(0, out_line[0..len]);
        if (seen.contains(h)) continue;
        histPrepend(out_line[0..len]);
        seen.put(g.allocator, h, {}) catch {};
    }
}

/// Load history from drun → bash → zsh → fish (load order).
/// Because `histPrepend()` inserts at index 0, fish ends up with the highest
/// suggestion priority in `updateGhost`.
fn loadHistory() void {
    g.is_hist_loaded = true;

    var path_buf: [512]u8 = undefined;
    const home = std.mem.span(c.getenv("HOME") orelse return);

    // Local helper: format a path and open it for reading.
    const tryOpen = struct {
        fn f(buf: []u8, comptime fmt: []const u8, args: anytype) ?*c.FILE {
            const s = std.fmt.bufPrint(buf[0..buf.len-1], fmt, args) catch return null;
            buf[s.len] = 0;
            return c.fopen(@ptrCast(buf.ptr), "r");
        }
    }.f;

    if (tryOpen(&path_buf, "{s}/.local/share/drun/history",          .{home})) |fp| {
        defer _ = c.fclose(fp);
        histLoadFile(fp);
    }
    if (tryOpen(&path_buf, "{s}/.bash_history",                       .{home})) |fp| {
        defer _ = c.fclose(fp);
        histLoadFile(fp);
    }
    if (tryOpen(&path_buf, "{s}/.zsh_history",                        .{home})) |fp| {
        defer _ = c.fclose(fp);
        histLoadFile(fp);
    }
    if (tryOpen(&path_buf, "{s}/.local/share/fish/fish_history",      .{home})) |fp| {
        defer _ = c.fclose(fp);
        histLoadFile(fp);
    }
}

// ---------------------------------------------------------------------------
// Private — command spawning
// ---------------------------------------------------------------------------

fn spawnCommand(cmd: []const u8) void {
    histPrepend(cmd);
    histAppendToFile(cmd);

    // cmd.len <= vim.default_max_input - 1 (enforced by insertChar), so buf
    // always has room for the null terminator.
    var buf: [vim.default_max_input]u8 = undefined;
    @memcpy(buf[0..cmd.len], cmd);
    buf[cmd.len] = 0;
    const cmd_z: [*:0]const u8 = buf[0..cmd.len :0];

    const pid = c.fork();
    if (pid == 0) {
        const pid2 = c.fork();
        if (pid2 == 0) {
            _ = c.setsid();
            _ = c.execvp("/bin/sh", @ptrCast(&[_:null]?[*:0]const u8{ "/bin/sh", "-c", cmd_z, null }));
            std.process.exit(1);
        }
        std.process.exit(0);
    } else if (pid > 0) {
        var status: c_int = 0;
        _ = c.waitpid(pid, &status, 0);
    }
}

// ---------------------------------------------------------------------------
// Private — rendering helpers
// ---------------------------------------------------------------------------

/// Binary search: first byte offset where `measureTextWidth(text[0..offset])
/// >= target_px`.  Returns `text.len` if the whole string is narrower.
fn textOffsetAtPx(dc: *drawing.DrawContext, text: []const u8, target_px: u16) usize {
    var lo: usize = 0;
    var hi: usize = text.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (dc.measureTextWidth(text[0..mid]) < target_px) lo = mid + 1 else hi = mid;
    }
    return lo;
}

/// Return the longest prefix of `text` whose pixel width is ≤ `max_px`.
/// Fast path: returns the full slice when the text already fits.
fn textPrefixFit(dc: *drawing.DrawContext, text: []const u8, max_px: u16) []const u8 {
    if (dc.measureTextWidth(text) <= max_px) return text;
    var lo: usize = 0;
    var hi: usize = text.len;
    while (lo < hi) {
        const mid = lo + (hi - lo + 1) / 2; // round up to avoid infinite loop
        if (dc.measureTextWidth(text[0..mid]) <= max_px) lo = mid else hi = mid - 1;
    }
    return text[0..lo];
}

/// Draw `text` with hard pixel clipping to `[text_left_x, scroll_end_x)`.
///
/// `px` is the virtual pen position (scroll-space, may be negative).  It is
/// always advanced by the full text width whether or not anything is drawn —
/// callers rely on this to keep the pen position consistent.
///
/// Both edges are clipped without ellipsis:
///   Left  — characters whose right edges fall before `text_left_x` are skipped.
///   Right — characters that would extend past `scroll_end_x` are dropped.
///
/// This is the correct behaviour for pre-cursor text in a scrolling field:
/// the cursor must appear immediately after the last visible character with no "…".
inline fn drawSpan(
    dc:           *drawing.DrawContext,
    px:           *i32,
    text_left_x:  u16,
    scroll_end_x: u16,
    baseline:     u16,
    text:         []const u8,
    color:        u32,
) !void {
    const w = dc.measureTextWidth(text);
    defer px.* += @intCast(w);
    if (w == 0) return;

    const tl: i32 = text_left_x;
    const se: i32 = scroll_end_x;

    // Fully off-screen to the left or right — nothing to draw.
    if (px.* + @as(i32, w) <= tl or px.* >= se) return;

    // Skip the prefix that lies off-screen to the left.
    const start: usize = if (px.* < tl)
        textOffsetAtPx(dc, text, @intCast(tl - px.*))
    else
        0;

    const draw_x: u16  = @intCast(@max(px.*, tl));
    const available: u16 = @intCast(se - @as(i32, draw_x));

    // Clip the visible suffix to the available width on the right.
    const visible = textPrefixFit(dc, text[start..], available);
    if (visible.len > 0)
        try dc.drawText(draw_x, baseline, visible, color);
}

/// Draw `text` from `px` to the right edge, ellipsizing on overflow.
/// Shared by the insert, normal, and visual branches of `drawActive` for
/// post-cursor text.
inline fn drawPostSpan(
    dc:           *drawing.DrawContext,
    px:           i32,
    text_left_x:  u16,
    scroll_end_x: u16,
    baseline:     u16,
    text:         []const u8,
    color:        u32,
) !void {
    if (text.len == 0 or px >= @as(i32, scroll_end_x)) return;
    const draw_x: u16    = @intCast(@max(px, @as(i32, text_left_x)));
    const remaining: u16 = scroll_end_x -| draw_x;
    if (remaining > 0)
        try dc.drawTextEllipsis(draw_x, baseline, text, remaining, color);
}

/// Compute the clamped `draw_x` and `vis_w` for a block cursor or selection
/// highlight.  Returns null when the block is entirely off-screen.
inline fn cursorBlockGeom(
    px:           i32,
    block_w:      u16,
    text_left_x:  u16,
    scroll_end_x: u16,
) ?struct { draw_x: u16, vis_w: u16 } {
    if (px + @as(i32, block_w) <= @as(i32, text_left_x) or px >= @as(i32, scroll_end_x))
        return null;
    const draw_x: u16 = @intCast(@max(px, @as(i32, text_left_x)));
    const vis_w: u16  = @intCast(@min(@as(i32, block_w), @as(i32, scroll_end_x) - px));
    if (vis_w == 0) return null;
    return .{ .draw_x = draw_x, .vis_w = vis_w };
}

// ---------------------------------------------------------------------------
// Private — active-mode rendering
// ---------------------------------------------------------------------------

/// Render the active input UI.
///
/// Layout:
///
///   [ pad | scrollable: PROMPT | pre | CURSOR/SELECTION | post | MODE_LABEL | pad ]
///
/// The mode label is pinned to the right edge (does not scroll).
/// The scrollable region keeps the cursor in view.
fn drawActive(
    dc:      *drawing.DrawContext,
    config:  types.BarConfig,
    height:  u16,
    start_x: u16,
    width:   u16,
) !u16 {
    const end_x  = start_x + width;
    const pad    = config.scaledSegmentPadding(height);
    const accent = config.drunPromptColor();
    const bg     = config.drunBg();
    const fg     = config.drunFg();
    const prompt = config.drun_prompt;

    dc.fillRect(start_x, 0, width, height, bg);

    const baseline    = dc.baselineY(height);
    const text_left_x = start_x + pad;
    const text_end_x  = end_x   -| pad;
    if (text_left_x >= text_end_x) return end_x;

    // Mode widget — pinned to the right edge; does not scroll.
    //
    // Rendered as a filled pill: accent-coloured background, white text.
    // Horizontal padding of `pill_h_pad` is applied on both sides so the text
    // never touches the pill edge and there is a natural gap between the pill
    // and the scrollable text region.
    //
    // In colon-command mode the mode label is replaced by an ex-command input
    // field that shows ":typed_chars" followed by a block cursor.
    const pill_h_pad: u16 = 6;
    const white: u32 = 0xFFFFFFFF;

    const mode_label = g.vim_state.mode.label();
    const mode_idx: usize = @intFromEnum(g.vim_state.mode);

    const mode_w: u16 = g.cached_mode_w[mode_idx] orelse blk: {
        const w = dc.measureTextWidth(mode_label);
        g.cached_mode_w[mode_idx] = w;
        break :blk w;
    };

    // Total pill width = inner text width + left pad + right pad.
    const pill_w: u16 = mode_w + pill_h_pad * 2;

    // Reserve the pill width on the right; the scrollable region ends here.
    const scroll_end_x: u16 = if (text_end_x >= pill_w) text_end_x - pill_w else text_left_x;
    // Clip post-cursor text 2 px before the pill so ink never bleeds into it.
    const ellipsis_end_x: u16 = scroll_end_x -| 2;

    if (pill_w > 0 and text_end_x >= pill_w) {
        const pill_x: u16 = text_end_x - pill_w;
        if (pill_x >= text_left_x) {
            // Filled pill background.
            dc.fillRect(pill_x, cursor_v_pad, pill_w, height -| cursor_v_pad * 2, accent);

            if (vim.colonInput(&g.vim_state)) |ct| {
                // Ex-command input: ":typed_chars" + blinking insert-style caret.
                var ppx: i32 = @as(i32, pill_x) + @as(i32, pill_h_pad);
                const colon_w: i32 = @intCast(dc.measureTextWidth(":"));
                try dc.drawText(@intCast(ppx), baseline, ":", white);
                ppx += colon_w;
                if (ct.len > 0) {
                    try dc.drawText(@intCast(ppx), baseline, ct, white);
                    ppx += @intCast(dc.measureTextWidth(ct));
                }
                // Blinking thin caret — same geometry as the insert-mode caret
                // in the main text area so both look identical.
                if (g.cached_caret_top == null) {
                    const asc, const desc = dc.getMetrics();
                    const font_h: u16 = @intCast(@max(0, @as(i32, asc) + @as(i32, desc)));
                    g.cached_caret_top = (height -| font_h) / 2;
                    g.cached_caret_h   = @min(font_h, height);
                }
                const caret_top = g.cached_caret_top.?;
                const caret_h   = g.cached_caret_h.?;
                const pill_inner_end: i32 = @as(i32, pill_x) + @as(i32, pill_w) - @as(i32, pill_h_pad);
                if (g.is_blink_visible and ppx < pill_inner_end) {
                    dc.fillRect(@intCast(ppx), caret_top, cursor_width, caret_h, white);
                }
            } else {
                // Normal mode label centred (left-padded) inside the pill.
                try dc.drawText(pill_x + pill_h_pad, baseline, mode_label, white);
            }
        }
    }

    if (text_left_x >= scroll_end_x) return end_x;

    const max_scroll_px: u16 = scroll_end_x - text_left_x;

    // Measure prompt width (cached).
    const prompt_w: u16 = g.cached_prompt_w orelse blk: {
        const w = dc.measureTextWidth(prompt);
        g.cached_prompt_w = w;
        break :blk w;
    };

    // Compute scroll offset to keep the cursor visible.
    //
    // In INSERT mode the cursor is a thin caret; the character it sits on is
    // NOT consumed, so `post_text` starts at cursor (not cursor+1) and the
    // caret_w used for layout is `cursor_width`.
    // In all other modes a full-character block model is used.
    const pre_cur_text = g.vim_state.buf[0..g.vim_state.cursor];
    const pre_w_cur    = dc.measureTextWidth(pre_cur_text);

    const caret_w: u16 = if (g.vim_state.mode == .insert)
        cursor_width
    else
        @max(
            dc.measureTextWidth(if (g.vim_state.cursor < g.vim_state.len)
                g.vim_state.buf[g.vim_state.cursor..g.vim_state.cursor + 1]
            else " "),
            min_cursor_px,
        );

    const post_text: []const u8 = if (g.vim_state.mode == .insert)
        g.vim_state.buf[g.vim_state.cursor..g.vim_state.len]
    else
        (if (g.vim_state.cursor < g.vim_state.len)
            g.vim_state.buf[g.vim_state.cursor + 1 .. g.vim_state.len]
        else "");

    var scroll_x: u16 = 0;
    const cursor_right = prompt_w + pre_w_cur + caret_w;
    if (cursor_right > max_scroll_px) {
        const min_scroll: u16 = cursor_right -| max_scroll_px;
        // Snap scroll_x to the nearest character boundary at or past min_scroll.
        // Without snapping, `drawSpan` draws text[start..] at text_left_x even
        // though character `start` begins some pixels past text_left_x in virtual
        // space.  That shift creates a gap between the rendered text and the caret
        // that looks like a phantom extra character to the right of the cursor.
        if (min_scroll <= prompt_w) {
            const idx = textOffsetAtPx(dc, prompt, min_scroll);
            scroll_x = dc.measureTextWidth(prompt[0..idx]);
        } else {
            const min_in_pre: u16 = min_scroll - prompt_w;
            const idx = textOffsetAtPx(dc, pre_cur_text, min_in_pre);
            scroll_x = prompt_w + dc.measureTextWidth(pre_cur_text[0..idx]);
        }
    }

    // Draw prompt
    var px: i32 = @as(i32, text_left_x) - @as(i32, scroll_x);
    try drawSpan(dc, &px, text_left_x, scroll_end_x, baseline, prompt, accent);

    // Mode-specific text rendering.
    // When colon-command mode is active the cursor lives in the pill widget,
    // not here — so we skip all cursor drawing in the main text area.
    const colon_active = vim.colonInput(&g.vim_state) != null;

    if (g.vim_state.mode == .visual) {
        const sel      = vim.visualRange(&g.vim_state);
        const sel_lo   = sel[0];
        const sel_hi   = sel[1];

        const pre_sel  = g.vim_state.buf[0..sel_lo];
        const sel_text = g.vim_state.buf[sel_lo..sel_hi];
        const post_sel = g.vim_state.buf[sel_hi..g.vim_state.len];
        const sel_w    = @max(dc.measureTextWidth(sel_text), min_cursor_px);

        if (pre_sel.len > 0)
            try drawSpan(dc, &px, text_left_x, scroll_end_x, baseline, pre_sel, fg);

        if (cursorBlockGeom(px, sel_w, text_left_x, scroll_end_x)) |block| {
            dc.fillRect(block.draw_x, cursor_v_pad, block.vis_w, height -| cursor_v_pad * 2, accent);
            if (sel_text.len > 0)
                try dc.drawText(block.draw_x, baseline, sel_text, bg);
        }
        px += @intCast(sel_w);

        try drawPostSpan(dc, px, text_left_x, ellipsis_end_x, baseline, post_sel, fg);

    } else if (g.vim_state.mode == .insert) {
        // Blinking thin caret; text NOT consumed by cursor position.
        if (pre_cur_text.len > 0)
            try drawSpan(dc, &px, text_left_x, scroll_end_x, baseline, pre_cur_text, fg);

        // Caret geometry — cached since font metrics and bar height are constant
        // between reloads.
        if (g.cached_caret_top == null) {
            const asc, const desc = dc.getMetrics();
            const font_h: u16 = @intCast(@max(0, @as(i32, asc) + @as(i32, desc)));
            g.cached_caret_top = (height -| font_h) / 2;
            g.cached_caret_h   = @min(font_h, height);
        }
        const caret_top = g.cached_caret_top.?;
        const caret_h   = g.cached_caret_h.?;

        if (g.is_blink_visible and !colon_active and px >= @as(i32, text_left_x) and px < @as(i32, scroll_end_x)) {
            dc.fillRect(@intCast(px), caret_top, cursor_width, caret_h, accent);
        }

        // Ghost text (only when cursor is at end).
        if (g.ghost_len > 0 and g.vim_state.cursor == g.vim_state.len and px < @as(i32, scroll_end_x)) {
            const ghost = g.ghost_buf[0..g.ghost_len];
            const draw_x: u16  = @intCast(@max(px, @as(i32, text_left_x)));
            const remaining: u16 = scroll_end_x -| draw_x;
            if (remaining > 0)
                try dc.drawTextEllipsis(draw_x, baseline, ghost, remaining, accent);
        }

        try drawPostSpan(dc, px, text_left_x, ellipsis_end_x, baseline, post_text, fg);

    } else {
        // NORMAL / REPLACE: full-character block cursor.
        const pre_text = g.vim_state.buf[0..g.vim_state.cursor];
        const cur_text = if (g.vim_state.cursor < g.vim_state.len)
            g.vim_state.buf[g.vim_state.cursor .. g.vim_state.cursor + 1]
        else " ";
        const cur_w    = @max(dc.measureTextWidth(cur_text), min_cursor_px);

        if (pre_text.len > 0)
            try drawSpan(dc, &px, text_left_x, scroll_end_x, baseline, pre_text, fg);

        if (colon_active) {
            // No cursor box — draw the character under the cursor as plain text
            // so it isn't swallowed when the cursor moves to the pill widget.
            if (g.vim_state.cursor < g.vim_state.len) {
                if (cursorBlockGeom(px, cur_w, text_left_x, scroll_end_x)) |block|
                    try dc.drawText(block.draw_x, baseline, cur_text, fg);
            }
        } else {
            if (cursorBlockGeom(px, cur_w, text_left_x, scroll_end_x)) |block| {
                dc.fillRect(block.draw_x, cursor_v_pad, block.vis_w, height -| cursor_v_pad * 2, accent);
                if (g.vim_state.cursor < g.vim_state.len)
                    try dc.drawText(block.draw_x, baseline, cur_text, bg);
            }
        }
        px += @intCast(cur_w);

        try drawPostSpan(dc, px, text_left_x, ellipsis_end_x, baseline, post_text, fg);
    }

    dc.flushRect(start_x, width);
    return end_x;
}
