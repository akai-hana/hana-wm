//! drun — dwm-style command runner for the status bar.
//!
//! When active, the title segment area becomes a text input field. The user can
//! type a shell command and press Return to execute it via sh(1), or press Escape
//! to dismiss without running anything. Full inline cursor editing is supported.
//!
//! ── Vim-mode ─────────────────────────────────────────────────────────────────
//!
//!  drun opens in INSERT mode. A mode label is anchored to the left of the
//!  prompt area and updates live:
//!
//!    [INSERT]   — normal typing; Escape enters NORMAL mode
//!    [NORMAL]   — motion / delete commands; i/a re-enters INSERT mode
//!
//!  NORMAL mode bindings:
//!
//!    i / a     — enter INSERT mode (a places cursor one step right, like vim)
//!    h / l     — move left / right one character
//!    w         — move forward one word
//!    b         — move backward one word
//!    $         — move to end of line
//!    ^ / 0     — move to start of line
//!    d + w     — delete forward one word
//!    d + b     — delete backward one word
//!    d + $     — delete to end of line
//!    d + ^ / 0 — delete to start of line
//!    d + d     — delete entire line (clear buffer)
//!    Return    — execute and close (works in either mode)
//!    Escape    — close drun (from NORMAL mode)
//!    Ctrl+C    — close drun (from either mode)
//!
//! ── Integration checklist ────────────────────────────────────────────────────
//!
//!  1. bar.zig  — In drawSegment(), replace the `.title` arm dispatch so that
//!                when drun.isActive() is true, drun.draw() is called instead
//!                of title_segment.draw(). Both share the same signature, so it
//!                is a straight drop-in:
//!
//!                  .title => if (drun.isActive())
//!                      try drun.draw(self.dc, self.config, self.height, x,
//!                          width orelse 100, self.conn, snap.focused_window,
//!                          snap.current_ws_wins.items, snap.minimized.items,
//!                          &self.cached_title, &self.cached_title_window,
//!                          snap.title_invalidated, self.allocator)
//!                  else
//!                      try title_segment.draw(...)
//!
//!                Also do the same in drawTitleOnly() — guard it with
//!                `if (!drun.isActive())`.
//!
//!  2. event loop — In the XCB_KEY_PRESS handler, call drun.handleKeyPress()
//!                  *before* the normal keybind dispatch:
//!
//!                  const kp: *xcb.xcb_key_press_event_t = @ptrCast(event);
//!                  if (drun.handleKeyPress(kp, wm)) {
//!                      bar.submitDrawAsync(wm);  // or markDirty + updateIfDirty
//!                      continue;
//!                  }
//!                  // ... normal keybind dispatch ...
//!
//!  3. action dispatch — Add a "drun_toggle" action and call drun.toggle(wm).
//!
//!  4. bar init / deinit — Call drun.init(conn) after the bar window is created,
//!                         and drun.deinit() before bar teardown.
//!
//! ── config.toml ──────────────────────────────────────────────────────────────
//!
//!   Mod+Shift+Tab = "drun_toggle"
//!
//! ─────────────────────────────────────────────────────────────────────────────

const std     = @import("std");
const defs    = @import("defs");
const xcb     = defs.xcb;
const drawing = @import("drawing");
const title   = @import("title");
const debug   = @import("debug");

const c = @cImport({
    @cInclude("unistd.h");
    @cInclude("stdlib.h");
    @cInclude("sys/wait.h");
});

// ── xcb-keysyms bindings (link with -lxcb-keysyms) ───────────────────────────

/// Opaque handle for the keysym table allocated by xcb_key_symbols_alloc().
const xcb_key_symbols_t = opaque {};

extern fn xcb_key_symbols_alloc(c: *xcb.xcb_connection_t) ?*xcb_key_symbols_t;
extern fn xcb_key_symbols_free(syms: *xcb_key_symbols_t) void;
/// Returns the keysym for keycode `code` at column `col` (0 = unshifted).
extern fn xcb_key_symbols_get_keysym(syms: *xcb_key_symbols_t, code: xcb.xcb_keycode_t, col: c_int) xcb.xcb_keysym_t;

// ── X11 keysym constants ──────────────────────────────────────────────────────

const XK_BackSpace : xcb.xcb_keysym_t = 0xff08;
const XK_Return    : xcb.xcb_keysym_t = 0xff0d;
const XK_Escape    : xcb.xcb_keysym_t = 0xff1b;
const XK_Delete    : xcb.xcb_keysym_t = 0xffff;
const XK_Left      : xcb.xcb_keysym_t = 0xff51;
const XK_Right     : xcb.xcb_keysym_t = 0xff53;
const XK_Home      : xcb.xcb_keysym_t = 0xff50;
const XK_End       : xcb.xcb_keysym_t = 0xff57;

// ── Constants ─────────────────────────────────────────────────────────────────

/// Maximum number of bytes in the input buffer (UTF-8 aware but capped here).
const MAX_INPUT: usize  = 512;
/// Minimum visible cursor width in pixels (for an empty field).
const MIN_CURSOR_PX: u16 = 8;
/// Vertical inset for the cursor block, in pixels.
const CURSOR_V_PAD: u16  = 2;

/// The two editing modes, displayed as a label anchored left of the prompt.
const Mode = enum {
    insert,
    normal,

    fn label(self: Mode) []const u8 {
        return switch (self) {
            .insert => "[INSERT]",
            .normal => "[NORMAL]",
        };
    }
};

// ── Module state ──────────────────────────────────────────────────────────────

const DrunState = struct {
    active:          bool                = false,
    mode:            Mode                = .insert,
    /// Set to true when 'd' has been pressed in NORMAL mode and we are waiting
    /// for the second key of a delete motion (dw / db / d$ / d^ / dd).
    pending_d:       bool                = false,
    buf:             [MAX_INPUT]u8       = undefined,
    len:             usize               = 0,
    /// Byte offset of the text-insertion point within buf[0..len].
    cursor:          usize               = 0,
    key_syms:        ?*xcb_key_symbols_t = null,
    /// Cached pixel width of the prompt string. Measured once per activation
    /// (on the first drawActive call) and reused for all subsequent keystrokes.
    /// Reset to null on deactivate so a font reload between sessions re-measures.
    cached_prompt_w: ?u16                = null,
    /// Cached pixel widths for each mode label; index matches Mode ordinal.
    /// Both are reset to null on deactivate.
    cached_mode_w:   [2]?u16            = .{ null, null },
};

var g: DrunState = .{};

// ── Public API ────────────────────────────────────────────────────────────────

/// Returns true while the command runner is displayed and accepting input.
pub fn isActive() bool { return g.active; }

/// Allocates the keysym table. Call once after the XCB connection is open.
pub fn init(conn: *xcb.xcb_connection_t) void {
    if (g.key_syms != null) return;
    g.key_syms = xcb_key_symbols_alloc(conn);
    if (g.key_syms == null)
        debug.warn("drun: xcb_key_symbols_alloc failed — key input will not work", .{});
}

/// Frees the keysym table. Call before bar teardown.
pub fn deinit() void {
    if (g.key_syms) |ks| {
        xcb_key_symbols_free(ks);
        g.key_syms = null;
    }
}

/// Activate or dismiss the command runner.
/// Grabs/ungrabs the keyboard so all key events are routed here while active.
pub fn toggle(wm: *defs.WM) void {
    if (g.active) deactivate(wm) else activate(wm);
}

/// Process an XCB key-press event. Must be called from the main event loop
/// *before* the normal keybind dispatch.
///
/// Returns true when the event was consumed (i.e. drun is active).
/// The caller is responsible for triggering a bar redraw after a true return.
pub fn handleKeyPress(event: *const xcb.xcb_key_press_event_t, wm: *defs.WM) bool {
    if (!g.active) return false;

    const syms = g.key_syms orelse return true; // active but no syms: swallow events

    // Resolve the keysym. Use the shifted column so Shift+char gives the right glyph.
    const col: c_int = if (event.state & xcb.XCB_MOD_MASK_SHIFT != 0) 1 else 0;
    const sym        = xcb_key_symbols_get_keysym(syms, event.detail, col);

    // Ctrl+C — cancel from either mode.
    if (event.state & xcb.XCB_MOD_MASK_CONTROL != 0 and sym == 'c') {
        deactivate(wm);
        return true;
    }

    switch (g.mode) {
        .insert => handleInsert(sym, wm),
        .normal => handleNormal(sym, wm),
    }

    return true;
}

/// Draw the drun segment.
///
/// Signature is identical to title_segment.draw() so it can be dropped in as a
/// direct substitute. When inactive the call is forwarded to title_segment.draw()
/// unchanged, so no conditional logic is needed at the call site if the caller
/// always routes through this function.
pub fn draw(
    dc:                  *drawing.DrawContext,
    config:              defs.BarConfig,
    height:              u16,
    start_x:             u16,
    width:               u16,
    conn:                *xcb.xcb_connection_t,
    focused_window:      ?u32,
    current_ws_wins:     []const u32,
    minimized:           []const u32,
    cached_title:        *std.ArrayList(u8),
    cached_title_window: *?u32,
    title_invalidated:   bool,
    allocator:           std.mem.Allocator,
) !u16 {
    if (!g.active) {
        return title.draw(
            dc, config, height, start_x, width,
            conn, focused_window, current_ws_wins, minimized,
            cached_title, cached_title_window, title_invalidated, allocator,
        );
    }

    return drawActive(dc, config, height, start_x, width);
}

// ── Internal: mode handlers ───────────────────────────────────────────────────

/// Key handler for INSERT mode.
fn handleInsert(sym: xcb.xcb_keysym_t, wm: *defs.WM) void {
    switch (sym) {

        // Escape: enter NORMAL mode instead of quitting.
        XK_Escape => {
            g.mode      = .normal;
            g.pending_d = false;
        },

        XK_Return => {
            const cmd = g.buf[0..g.len];
            if (cmd.len > 0) spawnCommand(cmd);
            deactivate(wm);
        },

        XK_BackSpace => deleteBefore(),
        XK_Delete    => deleteAfter(),
        XK_Left      => { if (g.cursor > 0) g.cursor -= 1; },
        XK_Right     => { if (g.cursor < g.len) g.cursor += 1; },
        XK_Home      => g.cursor = 0,
        XK_End       => g.cursor = g.len,

        else => {
            // Accept printable ASCII (0x20–0x7e).
            if (sym >= 0x20 and sym <= 0x7e) {
                insertChar(@truncate(sym));
            }
        },
    }
}

/// Key handler for NORMAL mode.
fn handleNormal(sym: xcb.xcb_keysym_t, wm: *defs.WM) void {
    // ── Pending-d: resolve the second key of a delete motion ─────────────────
    if (g.pending_d) {
        g.pending_d = false;
        switch (sym) {
            'w'           => deleteRange(g.cursor, wordForwardPos()),
            'b'           => deleteRange(wordBackwardPos(), g.cursor),
            '$', XK_End   => deleteRange(g.cursor, g.len),
            '^', '0',
            XK_Home       => deleteRange(0, g.cursor),
            'd'           => { g.cursor = 0; g.len = 0; }, // dd — clear line
            else          => {}, // unrecognised second key — cancel silently
        }
        return;
    }

    // ── Normal single-key commands ────────────────────────────────────────────
    switch (sym) {

        // Escape in NORMAL mode: quit drun entirely.
        XK_Escape => deactivate(wm),

        XK_Return => {
            const cmd = g.buf[0..g.len];
            if (cmd.len > 0) spawnCommand(cmd);
            deactivate(wm);
        },

        // Enter INSERT mode at cursor position.
        'i' => g.mode = .insert,

        // Enter INSERT mode, advance cursor one step first (vim 'a' — append).
        'a' => {
            if (g.cursor < g.len) g.cursor += 1;
            g.mode = .insert;
        },

        // Character motions (h/l mirror the arrow keys).
        'h', XK_Left  => { if (g.cursor > 0) g.cursor -= 1; },
        'l', XK_Right => { if (g.cursor < g.len) g.cursor += 1; },

        // Word motions.
        'w' => g.cursor = wordForwardPos(),
        'b' => g.cursor = wordBackwardPos(),

        // Line-end motions.
        '$', XK_End => g.cursor = g.len,
        '^', '0',
        XK_Home     => g.cursor = 0,

        // Begin a delete motion — arm pending_d and wait for the second key.
        'd' => g.pending_d = true,

        else => {}, // ignore unbound keys in normal mode
    }
}

// ── Internal: editing helpers ─────────────────────────────────────────────────

fn activate(wm: *defs.WM) void {
    g.len           = 0;
    g.cursor        = 0;
    g.mode          = .insert;
    g.pending_d     = false;
    g.active        = true;

    const cookie = xcb.xcb_grab_keyboard(
        wm.conn,
        0,                          // owner_events: false — don't re-deliver to focused win
        wm.root,
        xcb.XCB_CURRENT_TIME,
        xcb.XCB_GRAB_MODE_ASYNC,
        xcb.XCB_GRAB_MODE_ASYNC,
    );
    // The grab either succeeds or it doesn't; we proceed the same way either
    // way, so there's no point blocking for the status reply.
    xcb.xcb_discard_reply(wm.conn, cookie.sequence);
    _ = xcb.xcb_flush(wm.conn);
}

fn deactivate(wm: *defs.WM) void {
    g.active          = false;
    g.pending_d       = false;
    g.cached_prompt_w = null;
    g.cached_mode_w   = .{ null, null };
    _ = xcb.xcb_ungrab_keyboard(wm.conn, xcb.XCB_CURRENT_TIME);
    _ = xcb.xcb_flush(wm.conn);
}

/// Insert a single ASCII byte at the cursor position.
fn insertChar(ch: u8) void {
    if (g.len >= MAX_INPUT - 1) return;
    if (g.cursor < g.len) {
        // Shift bytes after cursor one position to the right.
        std.mem.copyBackwards(
            u8,
            g.buf[g.cursor + 1 .. g.len + 1],
            g.buf[g.cursor     .. g.len],
        );
    }
    g.buf[g.cursor] = ch;
    g.len    += 1;
    g.cursor += 1;
}

/// Delete the byte immediately before the cursor (Backspace).
fn deleteBefore() void {
    if (g.cursor == 0) return;
    g.cursor -= 1;
    deleteAfter();
}

/// Delete the byte at the cursor position (Delete key).
fn deleteAfter() void {
    if (g.cursor >= g.len) return;
    if (g.cursor < g.len - 1) {
        std.mem.copyForwards(
            u8,
            g.buf[g.cursor     .. g.len - 1],
            g.buf[g.cursor + 1 .. g.len],
        );
    }
    g.len -= 1;
}

/// Delete the half-open byte range [from, to) and place the cursor at `from`.
fn deleteRange(from: usize, to: usize) void {
    if (from >= to or to > g.len) return;
    const count = to - from;
    std.mem.copyForwards(u8, g.buf[from .. g.len - count], g.buf[to .. g.len]);
    g.len    -= count;
    g.cursor  = from;
}

/// Return the cursor position after a 'w' (forward-word) motion.
/// Skips the current run of non-space chars, then skips any following spaces.
fn wordForwardPos() usize {
    var p = g.cursor;
    while (p < g.len and g.buf[p] != ' ') p += 1; // skip word chars
    while (p < g.len and g.buf[p] == ' ') p += 1; // skip spaces
    return p;
}

/// Return the cursor position after a 'b' (backward-word) motion.
/// Skips any spaces going left, then skips the preceding run of non-space chars.
fn wordBackwardPos() usize {
    var p = g.cursor;
    while (p > 0 and g.buf[p - 1] == ' ') p -= 1; // skip spaces
    while (p > 0 and g.buf[p - 1] != ' ') p -= 1; // skip word chars
    return p;
}

/// Spawn `sh -c <cmd>` detached via double-fork so the grandchild is re-parented
/// to init. Mirrors the pattern used by input.zig's executeShellCommand.
fn spawnCommand(cmd: []const u8) void {
    // Need a null-terminated copy for execvp.
    var buf: [MAX_INPUT + 1]u8 = undefined;
    if (cmd.len >= buf.len) return;
    @memcpy(buf[0..cmd.len], cmd);
    buf[cmd.len] = 0;
    const cmd_z: [*:0]const u8 = buf[0..cmd.len :0];

    const pid = c.fork();
    if (pid == 0) {
        // Intermediate child: fork grandchild then exit so init inherits it.
        const pid2 = c.fork();
        if (pid2 == 0) {
            // Grandchild: become a new session and exec the command.
            _ = c.setsid();
            _ = c.execvp("/bin/sh", @ptrCast(&[_:null]?[*:0]const u8{
                "/bin/sh", "-c", cmd_z, null,
            }));
            std.process.exit(1);
        }
        std.process.exit(0);
    } else if (pid > 0) {
        // WM: reap the short-lived intermediate child immediately.
        var status: c_int = 0;
        _ = c.waitpid(pid, &status, 0);
    }
}

// ── Rendering ─────────────────────────────────────────────────────────────────

/// Render the active input UI into the title area.
///
/// Layout (left to right, all within the padded region):
///
///   [ pad | MODE_LABEL | scrollable: PROMPT | pre | CURSOR | post | pad ]
///
/// The mode label ([INSERT] / [NORMAL]) is pinned to the left edge and does
/// not scroll. Everything to its right — the prompt and input text — scrolls
/// horizontally to keep the cursor in view.
fn drawActive(
    dc:      *drawing.DrawContext,
    config:  defs.BarConfig,
    height:  u16,
    start_x: u16,
    width:   u16,
) !u16 {
    const end_x  = start_x + width;
    const pad    = config.scaledSegmentPadding(height);
    const accent = config.getDrunPromptColor();
    const bg     = config.getDrunBg();
    const fg     = config.getDrunFg();
    const prompt = config.drun_prompt;

    // Full background.
    dc.fillRect(start_x, 0, width, height, bg);

    const baseline    = dc.baselineY(height);
    const text_left_x = start_x + pad;  // absolute x where text area begins
    const text_end_x  = end_x   -| pad; // absolute x where text area ends

    if (text_left_x >= text_end_x) return end_x; // no usable space

    // ── Mode label (pinned, not scrolled) ─────────────────────────────────────
    const mode_label = g.mode.label();
    const mode_idx: usize = @intFromEnum(g.mode);

    const mode_w: u16 = g.cached_mode_w[mode_idx] orelse blk: {
        const w = dc.textWidth(mode_label);
        g.cached_mode_w[mode_idx] = w;
        break :blk w;
    };

    if (mode_w > 0 and text_left_x + mode_w <= text_end_x) {
        try dc.drawText(text_left_x, baseline, mode_label, accent);
    }

    // The scrollable region starts right after the mode label.
    const scroll_left_x = text_left_x + mode_w;
    if (scroll_left_x >= text_end_x) return end_x;

    const max_scroll_px: u16 = text_end_x - scroll_left_x;

    // ── Measure scrollable content ────────────────────────────────────────────
    const prompt_w: u16 = g.cached_prompt_w orelse blk: {
        const w = dc.textWidth(prompt);
        g.cached_prompt_w = w;
        break :blk w;
    };

    const pre_text  = g.buf[0..g.cursor];
    const cur_text  = if (g.cursor < g.len) g.buf[g.cursor .. g.cursor + 1] else " ";
    const post_text = if (g.cursor < g.len) g.buf[g.cursor + 1 .. g.len]   else "";

    const pre_w  = dc.textWidth(pre_text);
    const cur_w  = @max(dc.textWidth(cur_text), MIN_CURSOR_PX);
    const post_w = dc.textWidth(post_text);

    // Total scrollable content width; may exceed max_scroll_px for long inputs.
    const content_w = prompt_w + pre_w + cur_w + post_w;

    // ── Scroll offset — keeps the cursor block visible ────────────────────────
    var scroll_x: u16 = 0;
    if (content_w > max_scroll_px) {
        const cursor_left  = prompt_w + pre_w;
        const cursor_right = cursor_left + cur_w;
        if (cursor_right > max_scroll_px) {
            scroll_x = cursor_right -| max_scroll_px +| cur_w;
        }
    }

    // ── Draw scrollable content ───────────────────────────────────────────────
    var px: i32 = @as(i32, scroll_left_x) - @as(i32, scroll_x);

    // Prompt
    if (px + @as(i32, prompt_w) > @as(i32, scroll_left_x) and px < @as(i32, text_end_x)) {
        const draw_x: u16 = @intCast(@max(px, @as(i32, scroll_left_x)));
        try dc.drawText(draw_x, baseline, prompt, accent);
    }
    px += @intCast(prompt_w);

    // Text before cursor
    if (pre_text.len > 0) {
        if (px + @as(i32, pre_w) > @as(i32, scroll_left_x) and px < @as(i32, text_end_x)) {
            const draw_x: u16 = @intCast(@max(px, @as(i32, scroll_left_x)));
            try dc.drawText(draw_x, baseline, pre_text, fg);
        }
        px += @intCast(pre_w);
    }

    // Cursor block
    if (px + @as(i32, cur_w) > @as(i32, scroll_left_x) and px < @as(i32, text_end_x)) {
        const draw_x: u16 = @intCast(@max(px, @as(i32, scroll_left_x)));
        const visible_w: u16 = @intCast(@min(
            @as(i32, cur_w),
            @as(i32, text_end_x) - px,
        ));
        if (visible_w > 0) {
            dc.fillRect(draw_x, CURSOR_V_PAD, visible_w, height -| CURSOR_V_PAD * 2, accent);
            if (g.cursor < g.len)
                try dc.drawText(draw_x, baseline, cur_text, bg);
        }
    }
    px += @intCast(cur_w);

    // Text after cursor
    if (post_text.len > 0 and px < @as(i32, text_end_x)) {
        const draw_x: u16 = @intCast(@max(px, @as(i32, scroll_left_x)));
        const remaining: u16 = text_end_x -| draw_x;
        if (remaining > 0)
            try dc.drawTextEllipsis(draw_x, baseline, post_text, remaining, fg);
    }

    return end_x;
}
