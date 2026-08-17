//! Inline command prompt for the bar
//! Embeds an interactive command runner into the bar's title segment.

const std = @import("std");

const core = @import("core");
const xcb = core.xcb;

const bar = @import("bar");
const types = @import("types");

const drawing = @import("drawing");
const title = @import("title");
const vim = @import("vim.zig");

const debug = @import("debug");

const c = @cImport({
    @cInclude("unistd.h");
    @cInclude("stdlib.h");
    @cInclude("stdio.h");
    @cInclude("fcntl.h");
    @cInclude("dirent.h");
    @cInclude("sys/stat.h");
    @cInclude("sys/wait.h");
});

// xcb-keysyms bindings (link with -lxcb-keysyms)

const xcb_key_symbols_t = opaque {};

extern fn xcb_key_symbols_alloc(conn: *xcb.xcb_connection_t) ?*xcb_key_symbols_t;
extern fn xcb_key_symbols_free(syms: *xcb_key_symbols_t) void;
extern fn xcb_key_symbols_get_keysym(syms: *xcb_key_symbols_t, code: xcb.xcb_keycode_t, col: c_int) xcb.xcb_keysym_t;

// Module constants

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
/// Number of editing modes (derived from vim.Mode at comptime).
const num_modes = @typeInfo(vim.Mode).@"enum".fields.len;

// Module state

/// All mutable state owned by this module.
const PromptState = struct {
    is_active: bool = false,
    vim_state: vim.VimState = .{},

    allocator: std.mem.Allocator = undefined,

    key_syms: ?*xcb_key_symbols_t = null,
    cached_prompt_w: ?u16 = null,
    /// Cached pixel width of each mode label, indexed by `vim.Mode` integer value.
    cached_mode_w: [num_modes]?u16 = .{null} ** num_modes,

    // PATH completion
    comp_names: []u8 = &.{},
    comp_count: usize = 0,

    /// Ghost text: the completion suffix shown dimmed after the cursor.
    ghost_buf: []u8 = &.{},
    ghost_len: usize = 0,
    /// True when the current buffer contains at least one space.  Maintained
    /// incrementally so `updateGhost` can skip a full buffer scan on every call.
    has_space: bool = false,

    is_blink_visible: bool = true,

    /// Caret geometry cached after the first insert-mode draw.  Font metrics
    /// and bar height are constant between reloads, so these never need clearing.
    cached_caret_top: ?u16 = null,
    cached_caret_h: ?u16 = null,

    // Command history (newest at index 0)
    hist_entries: []u8 = &.{},
    hist_count: usize = 0,
    is_hist_loaded: bool = false,

    /// Set by key handlers, `activate`, and `deactivate` to notify the bar
    /// that the prompt area needs to be redrawn.  Consumed (read + cleared)
    /// by `consumeRedrawRequest` to avoid a circular import between prompt ↔ bar.
    redraw_pending: bool = false,

    // Layout cache: pixel width of the pre-caret text, the block-caret width,
    // and the scroll offset keeping the caret visible. Recomputed in
    // `drawActive` only when `layout_dirty` is set (keypress, activate,
    // spawn_keep, or bar-height change) — the caret-blink redraws an identical
    // frame each blink, so ticks reuse these instead of ~20 Pango shape passes.
    cached_pre_w: u16 = 0,
    cached_caret_w: u16 = 0,
    cached_scroll_x: u16 = 0,
    cached_height: u16 = 0,
    layout_dirty: bool = true,
};

var g: PromptState = .{};

// Module helpers

fn vimModeEnabled() bool {
    return core.getState().config.bar.vim_mode;
}

fn copyToZ(dest: []u8, src: []const u8) ?[*:0]u8 {
    if (src.len >= dest.len) return null;
    @memcpy(dest[0..src.len], src);
    dest[src.len] = 0;
    return @ptrCast(dest.ptr);
}

// Public API

/// Returns true when the prompt is currently active and accepting key input.
pub fn isActive() bool {
    return g.is_active;
}

/// Milliseconds until the next blink toggle, or -1 when the blink animation
/// isn't running. Pass this (with the clock timeout) to poll() so the loop
/// wakes exactly when a redraw is needed. Non-negative only in insert or
/// colon-command mode.
pub fn blinkPollTimeoutMs() i32 {
    if (!g.is_active) return -1;
    if (g.vim_state.mode == .insert or (vimModeEnabled() and vim.colonInput(&g.vim_state) != null))
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

/// Initialises all prompt state: vim engine, key-symbol table, completions, and history buffers.
/// No-op if already initialised (idempotent).
pub fn init(allocator: std.mem.Allocator, conn: *xcb.xcb_connection_t) !void {
    if (g.vim_state.buf.len != 0) return; // already initialised
    g.allocator = allocator;
    g.vim_state = try vim.VimState.init(allocator, vim.default_max_input, vim.default_undo_max);
    g.comp_names = try allocator.alloc(u8, (max_completion_len + 1) * max_completions);
    g.ghost_buf = try allocator.alloc(u8, max_completion_len);
    g.hist_entries = try allocator.alloc(u8, (max_history_line + 1) * max_history);
    g.key_syms = xcb_key_symbols_alloc(conn);
    if (g.key_syms == null)
        debug.warn("prompt: xcb_key_symbols_alloc failed — key input will not work", .{});
}

/// Frees all prompt resources and resets state to zero. Safe to call multiple times.
pub fn deinit() void {
    if (g.key_syms) |ks| {
        xcb_key_symbols_free(ks);
        g.key_syms = null;
    }
    if (g.vim_state.buf.len != 0) g.vim_state.deinit();
    if (g.hist_entries.len != 0) g.allocator.free(g.hist_entries);
    if (g.ghost_buf.len != 0) g.allocator.free(g.ghost_buf);
    if (g.comp_names.len != 0) g.allocator.free(g.comp_names);
    g = .{};
}

/// Activates the prompt if inactive, or deactivates it if active.
pub fn toggle() void {
    if (g.is_active) deactivate() else activate();
}

/// Query the X pointer and decide what close_window should do while the prompt
/// is active: cursor over the bar → kill the prompt; over a program → let the
/// WM close it (false); over nothing → swallow the key silently.
fn closeWindowOrPromptUnderCursor() bool {
    const cs = core.getState();
    const ptr_cookie = xcb.xcb_query_pointer(cs.conn, cs.root);
    const ptr_reply = xcb.xcb_query_pointer_reply(cs.conn, ptr_cookie, null);
    defer if (ptr_reply) |r| std.c.free(r);

    const child: u32 = if (ptr_reply) |r| r.*.child else 0;

    if (bar.isBarWindow(child)) {
        // Cursor is on the bar — kill the prompt.
        deactivate();
        return true;
    }
    if (child == 0 or child == cs.root) {
        // Cursor is over the desktop / no window — do nothing, swallow key.
        return true;
    }
    // Cursor is over a real program window — let the WM close it.
    return false;
}

/// Complete key-event routing entry point called by `input.zig`.
///
/// Keeps all prompt-specific routing out of `input.zig`: returns false
/// immediately when inactive (normal keybind dispatch), routes `close_window`
/// by cursor position (bar → kill prompt, window → WM close, desktop →
/// swallow), and otherwise delegates to `handleKeyPress`.
///
/// `bound_action` is whatever the keybind map resolved for this key; pass
/// `state.map.get(key)` directly — null is fine when there's no binding.
pub fn handlePromptKeypress(
    event: *const xcb.xcb_key_press_event_t,
    bound_action: ?*const types.Action,
) bool {
    if (!g.is_active) return false;

    // When the mod key (Super) is held and a WM action is bound to this key,
    // let the normal dispatcher run so WM operations don't cancel the prompt;
    // close_window is still routed here to dismiss the prompt — but only when
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
    // Only process XCB_KEY_PRESS events — press and release events share the
    // same struct layout, so the loop sometimes casts a release and dispatches
    // it here. Without this guard the Escape release is a trap: handleInsert
    // switches to .normal on press, then handleNormal sees XK_Escape with a
    // clean pending and deactivates — and the prompt is gone before the next
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

    // Drop bare modifier key events (Shift, Ctrl, Alt, Super, Meta, Hyper …).
    //
    // XCB delivers a key event for every key including modifiers, so Shift
    // before '$'/'^' fires XK_Shift_L/R first. Reaching handleNormal, that
    // falls through to resetPendingCmd(), clearing any pending operator/count —
    // why d$, d^, c$, y^, visual 3W, etc. silently become bare cursor moves.
    //
    // Modifier keysyms occupy 0xFFE1–0xFFEE, a band with no valid editing key.
    if (sym >= 0xFFE0 and sym <= 0xFFEF) return true;

    // Ctrl-modified keys
    if (ctrl_held) {
        const action = if (vim_mode) vim.handleCtrl(&g.vim_state, sym) else .none;
        // handleCtrl may have deleted text (Ctrl-W / Ctrl-U), so the ghost is
        // recomputed in the shared tail. The blink phase is left untouched.
        return finishKeyPress(action, false);
    }

    // Tab: accept ghost completion
    if (sym == @intFromEnum(vim.XK.Tab) and g.vim_state.mode == .insert) {
        return acceptGhost();
    }

    const action = if (!vim_mode and g.vim_state.mode == .insert)
        vim.handleInsertBasic(&g.vim_state, sym)
    else switch (g.vim_state.mode) {
        .insert => vim.handleInsert(&g.vim_state, sym),
        .normal => vim.handleNormal(&g.vim_state, sym),
        .visual => vim.handleVisual(&g.vim_state, sym),
        .replace => vim.handleReplace(&g.vim_state, sym),
    };
    return finishKeyPress(action, true);
}

/// Shared tail for every key that edited the buffer: run the action, recompute
/// the ghost suggestion (a mode handler may have deleted or inserted text),
/// and schedule a redraw. Returns true (event consumed).
fn finishKeyPress(action: vim.Action, refresh_blink: bool) bool {
    applyAction(action);
    updateGhost();
    if (refresh_blink) g.is_blink_visible = true;
    g.layout_dirty = true;
    g.redraw_pending = true;
    return true;
}

/// Accepts the ghost completion on Tab: inserts as much of the suggestion as
/// fits (clamped to the input limit), clears it, and schedules a redraw.
/// Returns true (event consumed).
fn acceptGhost() bool {
    const n_ghost: usize = if (g.ghost_len > 0 and g.vim_state.cursor == g.vim_state.len)
        @min(g.ghost_len, g.vim_state.max_input - 1 - g.vim_state.len)
    else
        0;
    if (n_ghost > 0) {
        vim.insertSlice(&g.vim_state, g.ghost_buf[0..n_ghost]);
    }
    return finishKeyPress(.none, true);
}

pub fn draw(
    ctx: title.TitleRenderContext,
    snap: title.TitleSnapshot,
    allocator: std.mem.Allocator,
    title_invalidated: bool,
) !u16 {
    if (!g.is_active) return title.draw(ctx, snap, allocator, title_invalidated);
    return drawActive(ctx.dc, ctx.config, ctx.height, ctx.start_x, ctx.width);
}

// Private — action handling

/// Runs `action` through handleAction, then resyncs g.has_space if the buffer
/// length changed. Shared by the Ctrl-key and normal-key paths in
/// handleKeyPress, which otherwise duplicated this exact sequence.
fn applyAction(action: vim.Action) void {
    const prev_len = g.vim_state.len;
    handleAction(action);
    if (g.vim_state.len != prev_len)
        g.has_space = std.mem.indexOfScalar(u8, g.vim_state.buf[0..g.vim_state.len], ' ') != null;
}

/// Dispatches a vim.Action returned by a mode handler: executes/closes on spawn,
/// resets and keeps open on spawn_keep, deactivates on deactivate, no-ops on none.
fn handleAction(action: vim.Action) void {
    switch (action) {
        .none => {},
        .deactivate => deactivate(),
        .spawn => {
            runPromptCommand();
            deactivate();
        },
        // :w — execute the command but keep the prompt open for the next one.
        // Clears the buffer and resets to INSERT like activate(), minus the
        // keyboard-grab overhead (the grab is already held).
        .spawn_keep => {
            runPromptCommand();
            resetPromptEditing();
        },
    }
}

/// Run the command currently in the buffer, if any.
fn runPromptCommand() void {
    const cmd = g.vim_state.buf[0..g.vim_state.len];
    if (cmd.len > 0) spawnCommand(cmd);
}

/// Reset editing state and prompt-editing flags, preserving heap allocations.
fn resetPromptEditing() void {
    g.vim_state.reset();
    g.ghost_len = 0;
    g.has_space = false;
    g.layout_dirty = true;
}

// Private — activate / deactivate

/// Reset all `VimState` editing fields to their defaults without touching the
/// heap-allocated buffers (buf, yank_buf, undo/redo stacks, etc.).
/// Grabs the keyboard, resets editing state, and marks the prompt active.
fn activate() void {
    resetPromptEditing();
    // Load completions and history on first activation.
    if (g.comp_count == 0) loadCompletions();
    if (!g.is_hist_loaded) loadHistory();
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
        debug.warn("prompt: xcb_grab_keyboard_reply returned null — aborting activation", .{});
        return;
    }
    defer std.c.free(grab_reply);
    if (grab_reply.*.status != xcb.XCB_GRAB_STATUS_SUCCESS) {
        debug.warn("prompt: keyboard grab failed (status {}) — aborting activation", .{grab_reply.*.status});
        return;
    }
    g.is_active = true;
    g.layout_dirty = true;
    g.redraw_pending = true;
    // Force the bar to the absolute top for the prompt's duration so it's
    // always visible/reachable; reversed in deactivate() via dismissAfterPrompt().
    bar.presentForPrompt();
    // No xcb_flush: xcb_grab_keyboard_reply already drained the output buffer
    // and presentForPrompt() flushes its own requests — nothing is pending
    // here. Contrast with deactivate(), where xcb_ungrab_keyboard must arrive
    // promptly.
}

/// Ungrabs the keyboard and marks the prompt inactive.
fn deactivate() void {
    g.is_active = false;
    if (vimModeEnabled()) vim.onDeactivate(&g.vim_state);
    const conn = core.getState().conn;
    _ = xcb.xcb_ungrab_keyboard(conn, xcb.XCB_CURRENT_TIME);
    _ = xcb.xcb_flush(conn);
    g.redraw_pending = true;
    // Return the bar to whatever state it was actually in before the prompt
    // forced it to the top (e.g. re-hide it if a fullscreen window is still
    // active) — see the comment on presentForPrompt() in activate().
    bar.dismissAfterPrompt();
}

// Private — PATH completion

/// Scan every directory in $PATH and collect executable names into the static
/// completion table.  Called once on first activation.
fn loadCompletions() void {
    g.comp_count = 0;
    const path_env_ptr = c.getenv("PATH") orelse return;
    const path_env = std.mem.span(path_env_ptr);

    var dir_buf: [std.fs.max_path_bytes:0]u8 = undefined;

    var dir_it = std.mem.splitScalar(u8, path_env, ':');
    outer: while (dir_it.next()) |dir_path| {
        if (dir_path.len == 0) continue;
        _ = copyToZ(&dir_buf, dir_path) orelse continue;

        const dirp = c.opendir(&dir_buf) orelse continue;
        defer _ = c.closedir(dirp);

        while (c.readdir(dirp)) |entry| {
            const name = std.mem.span(@as([*:0]const u8, @ptrCast(&entry.*.d_name)));
            // d_type 0 (DT_UNKNOWN on filesystems with no type) counts as a
            // candidate — it rules out only "obviously not a plain file"; the
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
/// command completion. Filters empty/oversized/dot-prefixed names and probes
/// the executable bit on the joined path.
fn isRunnableFile(dir_path: []const u8, name: []const u8) bool {
    if (name.len == 0 or name.len > max_completion_len) return false;
    if (name[0] == '.') return false;

    var full_path_buf: [std.fs.max_path_bytes:0]u8 = undefined;
    _ = std.fmt.bufPrintZ(&full_path_buf, "{s}/{s}", .{ dir_path, name }) catch return false;
    return c.access(&full_path_buf, c.X_OK) == 0;
}

/// Stores `name` into the next completion slot. Returns true when the table is
/// full and the $PATH scan should stop.
fn offerCompletion(name: []const u8) bool {
    const slot = g.comp_count * (max_completion_len + 1);
    @memcpy(g.comp_names[slot .. slot + name.len], name);
    g.comp_names[slot + name.len] = 0;
    g.comp_count += 1;
    return g.comp_count >= max_completions;
}

/// Binary searches the sorted completion table for the first entry ≥ `prefix`.
/// Returns the insertion index (0..comp_count) — use with compExistsExact for lookup.
fn compLowerBound(prefix: []const u8) usize {
    var lo: usize = 0;
    var hi: usize = g.comp_count;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (std.mem.order(u8, compName(mid), prefix) == .lt) lo = mid + 1 else hi = mid;
    }
    return lo;
}

/// Returns true when `name` exists verbatim in the sorted completion table.
/// Delegates to `compLowerBound` to avoid duplicating the binary-search logic.
fn compExistsExact(name: []const u8) bool {
    const idx = compLowerBound(name);
    if (idx >= g.comp_count) return false;
    return std.mem.eql(u8, compName(idx), name);
}

/// The `i`th completion name (fixed-stride slot read from the sorted table).
fn compName(i: usize) []const u8 {
    const slot = i * (max_completion_len + 1);
    return std.mem.sliceTo(g.comp_names[slot .. slot + max_completion_len + 1], 0);
}

/// The `i`th history entry (newest at index 0).
fn histEntry(i: usize) []const u8 {
    const slot = i * (max_history_line + 1);
    return std.mem.sliceTo(g.hist_entries[slot .. slot + max_history_line + 1], 0);
}

/// Clamps `suffix` into g.ghost_buf/g.ghost_len. Shared by both updateGhost
/// branches, which only differ in how they find the match.
inline fn setGhost(suffix: []const u8) void {
    const n = @min(suffix.len, max_completion_len);
    @memcpy(g.ghost_buf[0..n], suffix[0..n]);
    g.ghost_len = n;
}

/// Recompute the ghost-text suggestion based on the current buffer.
/// Priority: history (newest first) -> any executable match.
/// Only operates in INSERT mode with cursor at end and no spaces typed.
fn updateGhost() void {
    g.ghost_len = 0;

    if (g.vim_state.mode != .insert) return;
    if (g.vim_state.len == 0 or g.vim_state.cursor != g.vim_state.len) return;
    if (g.has_space) return;

    const prefix = g.vim_state.buf[0..g.vim_state.len];

    // 1. History-based suggestion (newest first)
    var hi: usize = 0;
    while (hi < g.hist_count) : (hi += 1) {
        const entry = histEntry(hi);
        if (entry.len == 0) continue;

        const cmd_end = std.mem.indexOfScalar(u8, entry, ' ') orelse entry.len;
        const cmd_tok = entry[0..cmd_end];

        if (cmd_tok.len <= prefix.len) continue;
        if (!std.mem.startsWith(u8, cmd_tok, prefix)) continue;
        if (!compExistsExact(cmd_tok)) continue;

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

// Private — history

/// Prepend `cmd` to the in-memory history ring (newest at index 0), shifting
/// entries right by one slot.
/// Silently no-ops when cmd is empty or exceeds max_history_line.
fn histPrepend(cmd: []const u8) void {
    if (cmd.len == 0 or cmd.len > max_history_line) return;

    const keep = @min(g.hist_count, max_history - 1);
    var i: usize = keep;
    while (i > 0) : (i -= 1) {
        const src = (i - 1) * (max_history_line + 1);
        const dst = i * (max_history_line + 1);
        @memcpy(g.hist_entries[dst .. dst + max_history_line + 1], g.hist_entries[src .. src + max_history_line + 1]);
    }
    @memcpy(g.hist_entries[0..cmd.len], cmd);
    g.hist_entries[cmd.len] = 0;
    if (g.hist_count < max_history) g.hist_count += 1;
}

/// Append `cmd` to the prompt's own history file (~/.local/share/drun/history).
fn histAppendToFile(cmd: []const u8) void {
    if (cmd.len == 0) return;
    const home = std.mem.span(c.getenv("HOME") orelse return);

    var path_buf: [512:0]u8 = undefined;
    const file_path = std.fmt.bufPrintZ(&path_buf, "{s}/.local/share/drun/history", .{home}) catch return;

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
/// (0 to skip). Understands fish `"- cmd: …"`, zsh `": <ts>:<elapsed>;…"` or
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

/// Splits `text` into lines, recording each [start, end) range (exclusive of
/// the trailing '\n') into the parallel `line_starts`/`line_ends` arrays.
/// Returns the number of lines (capped at `line_starts.len`).
fn collectLines(text: []const u8, line_starts: []usize, line_ends: []usize) usize {
    var n_lines: usize = 0;
    var pos: usize = 0;
    while (pos < text.len and n_lines < line_starts.len) {
        const line_start = pos;
        while (pos < text.len and text[pos] != '\n') : (pos += 1) {}
        const line_end = pos;
        if (pos < text.len) pos += 1;
        line_starts[n_lines] = line_start;
        line_ends[n_lines] = line_end;
        n_lines += 1;
    }
    return n_lines;
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
    const lines_buf = @as([*]usize, @ptrCast(@alignCast(lines_raw)));
    const line_starts = lines_buf[0..max_lines_cap];
    const line_ends = lines_buf[max_lines_cap .. max_lines_cap * 2];

    const n_lines = collectLines(text, line_starts, line_ends);

    var out_line: [max_history_line]u8 = undefined;

    // Build a hash set of already-loaded entries so duplicate detection is O(1)
    // instead of O(n²).  Pre-populate with any entries that were prepended by
    // earlier histLoadFile calls in the same session.
    var seen = std.AutoHashMapUnmanaged(u64, void){};
    defer seen.deinit(g.allocator);
    for (0..g.hist_count) |di| {
        seen.put(g.allocator, std.hash.Wyhash.hash(0, histEntry(di)), {}) catch {};
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

/// Load history from drun -> bash -> zsh -> fish (load order).
/// Because `histPrepend()` inserts at index 0, fish ends up with the highest
/// suggestion priority in `updateGhost`.
fn loadHistory() void {
    g.is_hist_loaded = true;

    var path_buf: [512]u8 = undefined;
    const home = std.mem.span(c.getenv("HOME") orelse return);

    const history_fmts = [_][]const u8{
        "{s}/.local/share/drun/history",
        "{s}/.bash_history",
        "{s}/.zsh_history",
        "{s}/.local/share/fish/fish_history",
    };
    inline for (history_fmts) |fmt| {
        if (tryOpenHistoryFile(&path_buf, fmt, .{home})) |fp| {
            defer _ = c.fclose(fp);
            histLoadFile(fp);
        }
    }
}

fn tryOpenHistoryFile(buf: []u8, comptime fmt: []const u8, args: anytype) ?*c.FILE {
    _ = std.fmt.bufPrintZ(buf, fmt, args) catch return null;
    return c.fopen(@ptrCast(buf.ptr), "r");
}

// Private — command spawning

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

// Private — rendering helpers

/// Binary search: first byte offset where `measureTextWidth(text[0..offset])
/// >= target_px`.  Returns `text.len` if the whole string is narrower.
/// Used to map a pixel scroll offset back to a character boundary.
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
/// `px` is the virtual pen position (scroll-space, may be negative), always
/// advanced by the full text width whether or not anything is drawn — callers
/// rely on this to keep the pen consistent.
///
/// Both edges clip without ellipsis: characters whose right edges fall before
/// `text_left_x` are skipped; characters past `scroll_end_x` are dropped —
/// correct for pre-cursor text, where the caret must sit right after the last
/// visible character. `text_w` is the caller's already-measured width (null to
/// measure here), avoiding a second Pango pass.
inline fn drawSpan(
    dc: *drawing.DrawContext,
    px: *i32,
    text_left_x: u16,
    scroll_end_x: u16,
    baseline: u16,
    text: []const u8,
    text_w: ?u16,
    color: u32,
) !void {
    const w = text_w orelse dc.measureTextWidth(text);
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

    const draw_x: u16 = @intCast(@max(px.*, tl));
    const available: u16 = @intCast(se - @as(i32, draw_x));

    // Clip the visible suffix to the available width on the right.  When no
    // left clip occurred, `w` is already the full width, so reuse it instead
    // of letting textPrefixFit re-measure the same slice on its fast path.
    const visible = if (start == 0)
        (if (w <= available) text else textPrefixFit(dc, text, available))
    else
        textPrefixFit(dc, text[start..], available);
    if (visible.len > 0)
        try dc.drawText(draw_x, baseline, visible, color);
}

/// Draw `text` from `px` to the right edge, ellipsizing on overflow.
/// Shared by the insert, normal, and visual branches of `drawActive` for
/// post-cursor text.
inline fn drawPostSpan(
    dc: *drawing.DrawContext,
    px: i32,
    text_left_x: u16,
    scroll_end_x: u16,
    baseline: u16,
    text: []const u8,
    color: u32,
) !void {
    if (text.len == 0 or px >= @as(i32, scroll_end_x)) return;
    const draw_x: u16 = @intCast(@max(px, @as(i32, text_left_x)));
    const remaining: u16 = scroll_end_x -| draw_x;
    if (remaining > 0)
        try dc.drawTextEllipsis(draw_x, baseline, text, remaining, color);
}

/// Compute the clamped `draw_x` and `vis_w` for a block cursor or selection
/// highlight.  Returns null when the block is entirely off-screen.
inline fn cursorBlockGeom(
    px: i32,
    block_w: u16,
    text_left_x: u16,
    scroll_end_x: u16,
) ?struct { draw_x: u16, vis_w: u16 } {
    if (px + @as(i32, block_w) <= @as(i32, text_left_x) or px >= @as(i32, scroll_end_x))
        return null;
    const draw_x: u16 = @intCast(@max(px, @as(i32, text_left_x)));
    const vis_w: u16 = @intCast(@min(@as(i32, block_w), @as(i32, scroll_end_x) - px));
    if (vis_w == 0) return null;
    return .{ .draw_x = draw_x, .vis_w = vis_w };
}

const CursorStyle = struct {
    text_left_x: u16,
    scroll_end_x: u16,
    baseline: u16,
    height: u16,
    accent: u32,
    bg: u32,
    fg: u32,
};

fn makeCursorStyle(text_left_x: u16, scroll_end_x: u16, baseline: u16, height: u16, accent: u32, bg: u32, fg: u32) CursorStyle {
    return .{ .text_left_x = text_left_x, .scroll_end_x = scroll_end_x, .baseline = baseline, .height = height, .accent = accent, .bg = bg, .fg = fg };
}

/// Draw a filled block cursor over `buf[lo..hi]` and advance `px.*` past it.
///
/// Shared by visual selection highlighting and the normal/replace character
/// cursor — "highlight a byte range with an accent block and inverse text",
/// differing only in range width and whether `text_only` suppresses the fill
/// (colon-command mode: the caret lives in the pill, so the character shows as
/// plain text). `lo == hi` draws an empty space-sized block (end-of-line).
inline fn drawBlockCursor(
    dc: *drawing.DrawContext,
    px: *i32,
    style: CursorStyle,
    buf: []const u8,
    lo: usize,
    hi: usize,
    text_w: ?u16,
    text_only: bool,
) !void {
    const block_text = if (hi > lo) buf[lo..hi] else " ";
    const block_w = @max(text_w orelse dc.measureTextWidth(block_text), min_cursor_px);

    if (cursorBlockGeom(px.*, block_w, style.text_left_x, style.scroll_end_x)) |block| {
        if (!text_only)
            dc.fillRect(block.draw_x, cursor_v_pad, block.vis_w, style.height -| cursor_v_pad * 2, style.accent);
        if (hi > lo)
            try dc.drawText(block.draw_x, style.baseline, block_text, if (text_only) style.fg else style.bg);
    }
    px.* += @intCast(block_w);
}

// Private — active-mode rendering

/// Lazily cache the caret geometry: font metrics and bar height are constant
/// between reloads, so this runs at most once. Hoisted before the pill and
/// mode branches so the lazy-init runs exactly once regardless of which
/// branch executes first.
fn ensureCaretGeom(dc: *drawing.DrawContext, height: u16) void {
    if (g.cached_caret_top == null) {
        const asc, const desc = dc.font.getMetrics();
        const font_h: u16 = @intCast(@max(0, @as(i32, asc) + @as(i32, desc)));
        g.cached_caret_top = (height -| font_h) / 2;
        g.cached_caret_h = @min(font_h, height);
    }
}

/// Pixel width of the prompt text, measured once and cached (font and prompt
/// are constant between reloads).
fn promptWidth(dc: *drawing.DrawContext, prompt: []const u8) u16 {
    return g.cached_prompt_w orelse blk: {
        const w = dc.measureTextWidth(prompt);
        g.cached_prompt_w = w;
        break :blk w;
    };
}

/// Recompute the cached caret widths and scroll offset — but only when
/// `layout_dirty` or a bar-height change demands it. The caret-blink redraws
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

    g.cached_pre_w = dc.measureTextWidth(pre_cur_text);
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
        // character begins past it in virtual space — a phantom gap next to the
        // caret.
        if (min_scroll <= prompt_w) {
            const idx = textOffsetAtPx(dc, prompt, min_scroll);
            scroll_x = dc.measureTextWidth(prompt[0..idx]);
        } else {
            const min_in_pre: u16 = min_scroll - prompt_w;
            const idx = textOffsetAtPx(dc, pre_cur_text, min_in_pre);
            scroll_x = prompt_w + dc.measureTextWidth(pre_cur_text[0..idx]);
        }
    }
    g.cached_scroll_x = scroll_x;
    g.cached_height = height;
    g.layout_dirty = false;
}

fn drawColonPillContent(
    dc: *drawing.DrawContext,
    pill_x: u16,
    pill_w: u16,
    pill_h_pad: u16,
    baseline: u16,
    ct: []const u8,
    white: u32,
) !void {
    var ppx: i32 = @as(i32, pill_x) + @as(i32, pill_h_pad);
    const colon_w: i32 = @intCast(dc.measureTextWidth(":"));
    try dc.drawText(@intCast(ppx), baseline, ":", white);
    ppx += colon_w;
    if (ct.len > 0) {
        try dc.drawText(@intCast(ppx), baseline, ct, white);
        ppx += @intCast(dc.measureTextWidth(ct));
    }
    const caret_top = g.cached_caret_top.?;
    const caret_h = g.cached_caret_h.?;
    const pill_inner_end: i32 = @as(i32, pill_x) + @as(i32, pill_w) - @as(i32, pill_h_pad);
    if (g.is_blink_visible and ppx < pill_inner_end) {
        dc.fillRect(@intCast(ppx), caret_top, cursor_width, caret_h, white);
    }
}

/// Right-pinned mode widget: a filled pill (accent bg, white text) with
/// `pill_h_pad` on both sides so the text never touches the pill edge and
/// there's a gap to the scrollable region. In colon-command mode the label is
/// replaced by ":typed_chars" plus a blinking block cursor.
///
/// Returns the scrollable region's right edge (the pill's left edge), or null
/// when no room remains for text — callers return immediately.
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
    const mode_w: u16 = g.cached_mode_w[mode_idx] orelse blk: {
        const w = dc.measureTextWidth(mode_label);
        g.cached_mode_w[mode_idx] = w;
        break :blk w;
    };

    // The pill only exists when there is a mode label (vim mode enabled);
    // basic mode gets the full width for the scrollable text region.
    const show_pill = mode_w > 0;
    const pill_w: u16 = mode_w + pill_h_pad * 2;
    const pill_fits = text_end_x >= pill_w;

    // Reserve the pill width on the right; the scrollable region ends here.
    const scroll_end_x: u16 = if (show_pill and pill_fits)
        text_end_x - pill_w
    else if (show_pill)
        text_left_x
    else
        text_end_x;
    if (text_left_x >= scroll_end_x) return null;

    if (show_pill and pill_fits) {
        const pill_x: u16 = text_end_x - pill_w;
        // Filled pill background.
        dc.fillRect(pill_x, cursor_v_pad, pill_w, height -| cursor_v_pad * 2, accent);

        if (vim.colonInput(&g.vim_state)) |ct| {
            try drawColonPillContent(dc, pill_x, pill_w, pill_h_pad, baseline, ct, white);
        } else {
            // Normal mode label centred (left-padded) inside the pill.
            try dc.drawText(pill_x + pill_h_pad, baseline, mode_label, white);
        }
    }

    return scroll_end_x;
}

/// Visual mode: highlight `buf[sel[0]..sel[1]]` with an accent block and
/// inverse text; everything before/after is drawn plain.
fn drawVisualMode(
    dc: *drawing.DrawContext,
    height: u16,
    baseline: u16,
    text_left_x: u16,
    scroll_end_x: u16,
    ellipsis_end_x: u16,
    px: *i32,
    accent: u32,
    bg: u32,
    fg: u32,
) !void {
    const sel = vim.visualRange(&g.vim_state);
    const pre_sel = g.vim_state.buf[0..sel[0]];
    const post_sel = g.vim_state.buf[sel[1]..g.vim_state.len];

    if (pre_sel.len > 0)
        try drawSpan(dc, px, text_left_x, scroll_end_x, baseline, pre_sel, null, fg);

    try drawBlockCursor(dc, px, makeCursorStyle(text_left_x, scroll_end_x, baseline, height, accent, bg, fg), g.vim_state.buf, sel[0], sel[1], null, false);

    try drawPostSpan(dc, px.*, text_left_x, ellipsis_end_x, baseline, post_sel, fg);
}

/// Insert mode: blinking thin caret; the caret position does not consume its
/// character, and ghost text appears dimmed after the cursor when at end.
fn drawInsertMode(
    dc: *drawing.DrawContext,
    baseline: u16,
    text_left_x: u16,
    scroll_end_x: u16,
    ellipsis_end_x: u16,
    px: *i32,
    accent: u32,
    fg: u32,
) !void {
    const pre_cur_text = g.vim_state.buf[0..g.vim_state.cursor];
    if (pre_cur_text.len > 0)
        try drawSpan(dc, px, text_left_x, scroll_end_x, baseline, pre_cur_text, g.cached_pre_w, fg);

    // Caret geometry was pre-computed in ensureCaretGeom.
    const caret_top = g.cached_caret_top.?;
    const caret_h = g.cached_caret_h.?;
    if (g.is_blink_visible and px.* >= @as(i32, text_left_x) and px.* < @as(i32, scroll_end_x)) {
        dc.fillRect(@intCast(px.*), caret_top, cursor_width, caret_h, accent);
    }

    // Ghost text (only when cursor is at end).
    if (g.ghost_len > 0 and g.vim_state.cursor == g.vim_state.len)
        try drawPostSpan(dc, px.*, text_left_x, scroll_end_x, baseline, g.ghost_buf[0..g.ghost_len], accent);

    try drawPostSpan(dc, px.*, text_left_x, ellipsis_end_x, baseline, g.vim_state.buf[g.vim_state.cursor..g.vim_state.len], fg);
}

/// NORMAL / REPLACE: full-character block cursor. When colon-command mode is
/// active the cursor lives in the pill widget, so the character underneath is
/// shown as plain text instead of being boxed.
fn drawNormalMode(
    dc: *drawing.DrawContext,
    height: u16,
    baseline: u16,
    text_left_x: u16,
    scroll_end_x: u16,
    ellipsis_end_x: u16,
    px: *i32,
    accent: u32,
    bg: u32,
    fg: u32,
    colon_active: bool,
) !void {
    const pre_text = g.vim_state.buf[0..g.vim_state.cursor];
    const cur_hi = @min(g.vim_state.cursor + 1, g.vim_state.len);

    if (pre_text.len > 0)
        try drawSpan(dc, px, text_left_x, scroll_end_x, baseline, pre_text, g.cached_pre_w, fg);

    try drawBlockCursor(dc, px, makeCursorStyle(text_left_x, scroll_end_x, baseline, height, accent, bg, fg), g.vim_state.buf, g.vim_state.cursor, cur_hi, g.cached_caret_w, colon_active);

    const post_text: []const u8 = if (g.vim_state.cursor < g.vim_state.len)
        g.vim_state.buf[g.vim_state.cursor + 1 .. g.vim_state.len]
    else
        "";
    try drawPostSpan(dc, px.*, text_left_x, ellipsis_end_x, baseline, post_text, fg);
}

/// Render the active input UI.
///
/// Layout: [ pad | scrollable: PROMPT | pre | CURSOR/SELECTION | post |
/// MODE_LABEL | pad ]. The mode label is pinned right (never scrolls); the
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
    const prompt = config.drun_prompt orelse types.DEFAULT_DRUN_PROMPT;
    const vim_mode = vimModeEnabled();

    dc.fillRect(start_x, 0, width, height, bg);

    const baseline = dc.baselineY(height);
    const text_left_x = start_x + pad;
    const text_end_x = end_x -| pad;
    if (text_left_x >= text_end_x) return end_x;

    ensureCaretGeom(dc, height);

    // Mode widget — pinned right; does not scroll. Its left edge bounds the
    // scrollable text region.
    const scroll_end_x = drawPill(dc, height, baseline, text_left_x, text_end_x, accent) orelse return end_x;
    // Clip post-cursor text 2 px before the pill so ink never bleeds into it.
    const ellipsis_end_x = scroll_end_x -| 2;

    const max_scroll_px: u16 = scroll_end_x - text_left_x;
    const prompt_w = promptWidth(dc, prompt);

    // In INSERT mode the caret doesn't consume its character — post_text
    // starts at cursor and caret_w is `cursor_width`; all other modes use a
    // full-character block.
    const pre_cur_text = g.vim_state.buf[0..g.vim_state.cursor];
    refreshLayoutCache(dc, height, prompt, prompt_w, pre_cur_text, max_scroll_px);
    const scroll_x = g.cached_scroll_x;

    // Draw prompt.
    var px: i32 = @as(i32, text_left_x) - @as(i32, scroll_x);
    try drawSpan(dc, &px, text_left_x, scroll_end_x, baseline, prompt, prompt_w, accent);

    // Mode-specific text rendering. When colon-command mode is active the
    // cursor lives in the pill widget, not here.
    const colon_active = vim_mode and vim.colonInput(&g.vim_state) != null;
    switch (g.vim_state.mode) {
        .visual => try drawVisualMode(dc, height, baseline, text_left_x, scroll_end_x, ellipsis_end_x, &px, accent, bg, fg),
        .insert => try drawInsertMode(dc, baseline, text_left_x, scroll_end_x, ellipsis_end_x, &px, accent, fg),
        else => try drawNormalMode(dc, height, baseline, text_left_x, scroll_end_x, ellipsis_end_x, &px, accent, bg, fg, colon_active),
    }

    dc.blitAndFlush(start_x, width);
    return end_x;
}