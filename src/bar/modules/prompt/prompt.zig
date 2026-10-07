//! Inline command prompt for the bar.
//! Embeds an interactive command runner into the bar's title segment.

const std = @import("std");

const core = @import("core");
const xcb = core.xcb;
const log = @import("log");

const types = @import("types");
const contract = @import("contract");
const seams = @import("seams");

const masks = @import("masks");
const segmod = @import("segment");
const editor = @import("editor");
const completion = @import("completion");
const render = @import("render");
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

// Editor contract re-exports: the vim extensor and the tests import
// these through the package core (`prompt`), never through the
// private `editor` sibling, so the split is invisible to them.
pub const XK = editor.XK;
pub const xk_return = editor.xk_return;
pub const xk_escape = editor.xk_escape;
pub const xk_left = editor.xk_left;
pub const xk_right = editor.xk_right;
pub const xk_home = editor.xk_home;
pub const xk_end = editor.xk_end;
pub const Action = editor.Action;
pub const Mode = editor.Mode;
pub const EditorState = editor.EditorState;
pub const Handlers = editor.Handlers;
pub const handleCtrl = editor.handleCtrl;
pub const insertChar = editor.insertChar;
pub const insertSlice = editor.insertSlice;
pub const deleteRange = editor.deleteRange;
pub const overwriteAt = editor.overwriteAt;
pub const isPrintableAscii = editor.isPrintableAscii;
pub const registerHandlers = editor.registerHandlers;
// Completion seam re-exports: `wordAtCursor` is the pure
// token-under-cursor split, pinned by completion_test.zig through
// the package core like the editor contract above.
pub const WordAtCursor = completion.WordAtCursor;
pub const wordAtCursor = completion.wordAtCursor;
pub const CompletionSource = completion.CompletionSource;
pub const handleInsertBasic = editor.handleInsertBasic;
const default_max_input = editor.default_max_input;

// XCB keysyms bindings (link with -lxcb-keysyms).

const xcb_key_symbols_t = opaque {};

extern fn xcb_key_symbols_alloc(conn: *xcb.xcb_connection_t) ?*xcb_key_symbols_t;
extern fn xcb_key_symbols_free(syms: *xcb_key_symbols_t) void;
extern fn xcb_key_symbols_get_keysym(
    syms: *xcb_key_symbols_t,
    code: xcb.xcb_keycode_t,
    col: c_int,
) xcb.xcb_keysym_t;

// Cursor blink half-period: cursor is visible for this many ms, then
// invisible for the same duration.
const cursor_blink_ms: u64 = 300;

const PromptState = struct {
    is_active: bool = false,
    vim_state: EditorState = .{},

    allocator: std.mem.Allocator = undefined,

    /// Bar-provided service handles (present/dismiss/isBarWindow), set at init;
    /// prompt never imports the bar orchestrator.
    handlers: ?*const segmod.BarHandlers = null,

    key_syms: ?*xcb_key_symbols_t = null,

    // Set by key handlers, `activate`, and `deactivate` to notify the bar
    // that the prompt area needs to be redrawn.  Consumed (read + cleared)
    // by `consumeRedrawRequest` to avoid a circular import between prompt <-> bar.
    redraw_pending: bool = false,
};

var g: PromptState = .{};

/// Invalidates every cache derived from config/font metrics or bar height.
/// Called from bar.applyReload: the renderer's module globals are built
/// against the OLD config's fonts and bar height, and a reload can change
/// both. Without this the prompt renders with stale widths/geometry until
/// its next full cycle (the old "constant between reloads" assumption was
/// wrong).
fn invalidateReloadCaches() void {
    render.invalidateReloadCaches();
}

/// Returns true when the prompt is currently active and accepting key input.
fn isActive() bool {
    return g.is_active;
}

/// Milliseconds until the next blink toggle, or -1 when the blink animation
/// isn't running.  Pass this (with the clock timeout) to poll() so the loop
/// wakes exactly when a redraw is needed.  Non-negative only while the
/// prompt is active in insert mode.
fn blinkPollTimeoutMs() i32 {
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
fn blinkTick() void {
    if (!g.is_active or g.vim_state.mode != .insert) return;
    render.blinkTick();
}

/// Overlay repaint query (contract.BarOverlay.needsRepaint): true while a caret
/// toggle is waiting to be drawn. Cleared inside `draw`.
fn overlayNeedsRepaint() bool {
    return render.overlayNeedsRepaint();
}

/// Returns true and clears the flag if a prompt-driven redraw is outstanding.
/// Call once per event-loop iteration from `bar.updateIfDirty`.
fn consumeRedrawRequest() bool {
    const pending = g.redraw_pending;
    g.redraw_pending = false;
    return pending;
}

/// Initialises prompt state that is needed regardless of whether the prompt
/// is ever opened: the bar service handles, vim engine, and key-symbol table.
/// The completion/history/ghost buffers are embedded in the global (~99 KiB).
fn init(
    allocator: std.mem.Allocator,
    conn: *const anyopaque,
    bar_handlers: ?*const anyopaque,
) !void {
    if (g.vim_state.buf.len != 0) return; // already initialised
    g.handlers = @ptrCast(@alignCast(bar_handlers));
    g.allocator = allocator;
    g.vim_state = try EditorState.init(allocator, default_max_input);
    // The segment hook's connection is `*const anyopaque` (contract is
    // X-free); the one segment that needs it casts back to the real handle.
    g.key_syms = xcb_key_symbols_alloc(@ptrCast(@constCast(conn)));
    if (g.key_syms == null)
        log.warn("prompt: xcb_key_symbols_alloc failed: key input will not work", .{});
    // The addon lifecycle lives here: each registered engine binds its
    // handlers into this module's state on init and tears down on deinit.
    inline for (addons) |a| {
        a.register();
        try a.init(allocator, default_max_input);
    }
}

/// Releases all prompt resources including the keyboard grab and vim state.
/// The completion/history/ghost buffers are embedded in the global (no heap).
fn deinit(allocator: std.mem.Allocator) void {
    inline for (addons) |a| a.deinit(allocator);
    if (g.key_syms) |ks| {
        xcb_key_symbols_free(ks);
        g.key_syms = null;
    }
    if (g.vim_state.buf.len != 0) g.vim_state.deinit();
    g = .{};
}

/// Open the prompt if closed, or close it if open.
fn toggle() void {
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
fn handlePromptKeypress(
    event: *const contract.KeyPressEvent,
    bound_action: ?*const types.Action,
) bool {
    if (!g.is_active) return false;
    // The hook receives the opaque event (contract is X-free); the fields are
    // read here, on the X side, via `seams`'s concrete type. The only
    // producer is the bar's chrome keypress route.
    const xevent: *const seams.KeyPressEvent = @ptrCast(@alignCast(event));

    // When the mod key (Super) is held and a WM action is bound to this key,
    // let the normal dispatcher run so WM operations don't cancel the prompt;
    // close_window is still routed here to dismiss the prompt, but only when
    // the cursor is over the bar itself.
    if (bound_action) |action| {
        if (action.* == .close_window) return closeWindowOrPromptUnderCursor();
        if (xevent.state & xcb.XCB_MOD_MASK_4 != 0)
            return false; // let WM dispatch execute the bind; prompt stays open
    }
    return handleKeyPress(xevent);
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
    if (event.response_type & masks.core_event_code_mask != xcb.XCB_KEY_PRESS) return true;

    const syms = g.key_syms orelse return false;

    const shift_held = event.state & xcb.XCB_MOD_MASK_SHIFT != 0;
    const ctrl_held = event.state & xcb.XCB_MOD_MASK_CONTROL != 0;
    const col: c_int = if (shift_held) 1 else 0;
    const sym = xcb_key_symbols_get_keysym(syms, event.detail, col);

    // Drop bare modifier key events (Shift, Ctrl, Alt, Super, Meta, Hyper ...).
    //
    // XCB delivers a key event for every key including modifiers, so Shift
    // before '$'/'^' fires XK_Shift_L/R first.  Reaching handleNormal, that
    // falls through to resetPendingCmd(), clearing any pending operator/count:
    // why d$, d^, c$, y^, visual 3W, etc. silently become bare cursor moves.
    //
    // Modifier keysyms occupy 0xFFE1-0xFFEE; the check widens that band by
    // one key on each side, none of which are valid editing keys.
    if (masks.isModifierKeysym(sym)) return true;

    // Ctrl-modified keys. Route EVERY Ctrl key through the mode handler,
    // not just in vim mode: otherwise Ctrl-C (and Ctrl-W with vim on) is
    // swallowed by the `.none` fallback and can't cancel the prompt.
    if (ctrl_held) {
        const action = editor.handlers.handle_ctrl(&g.vim_state, sym);
        // handleCtrl may have deleted text (Ctrl-W / Ctrl-U), so the ghost is
        // recomputed in the shared tail.  The blink phase is left untouched.
        return finishKeyPress(action, false);
    }

    // Tab: accept ghost completion
    if (sym == @intFromEnum(XK.Tab) and g.vim_state.mode == .insert) {
        return acceptGhost();
    }

    // (27.4) No handler installed means there is no modal engine to dispatch
    // to, so insert mode falls back to the basic editor. With one installed,
    // insert keys go to the handler like every other mode -- an extensor that
    // implements this contract is no longer bypassed for not being "vim".
    const action = if (!editor.addon_active and g.vim_state.mode == .insert)
        handleInsertBasic(&g.vim_state, sym)
    else switch (g.vim_state.mode) {
        .insert => editor.handlers.handle_insert(&g.vim_state, sym),
        .normal => editor.handlers.handle_normal(&g.vim_state, sym),
    };
    return finishKeyPress(action, true);
}

/// Shared tail for every key that edited the buffer: run the action, recompute
/// the ghost suggestion (a mode handler may have deleted or inserted text),
/// and schedule a redraw.  Returns true (event consumed).
fn finishKeyPress(action: Action, refresh_blink: bool) bool {
    handleAction(action);
    completion.updateGhost(&g.vim_state);
    if (refresh_blink) render.showCaret();
    render.markLayoutDirty();
    g.redraw_pending = true;
    return true;
}

/// Inserts as much of the ghost completion as fits (clamped to the input
/// limit), then finishes the key press, which recomputes the ghost for the
/// new buffer. Returns true (event consumed).
fn acceptGhost() bool {
    const ghost = completion.ghost();
    const n_ghost: usize = if (ghost.len > 0 and g.vim_state.cursor == g.vim_state.len)
        @min(ghost.len, g.vim_state.max_input - 1 - g.vim_state.len)
    else
        0;
    if (n_ghost > 0) insertSlice(&g.vim_state, ghost[0..n_ghost]);
    return finishKeyPress(.none, true);
}

/// Draw the title segment's content when the prompt is active, covering the
/// whole title slot. Returns the right edge (start_x + width). Only invoked by
/// the title segment's draw delegation while the prompt is open.
fn draw(ctx: *segmod.DrawCtx, x: u16) !u16 {
    // Clearing before the draw (not after) means a draw error still consumes
    // the request, so a persistently failing overlay can't re-request forever.
    render.clearBlinkRepaint();
    // While covered, title's pollTimeoutMsHook contributes no marquee wakeup
    // (title owns that decision), so no explicit carousel pause is needed here.
    return render.drawActive(ctx.dc, &ctx.config, ctx.height, x, ctx.width, &g.vim_state);
}

/// Dispatches a vim.Action returned by a mode handler: executes/closes on spawn,
/// deactivates on deactivate, no-ops on none.
fn handleAction(action: Action) void {
    switch (action) {
        .none => {},
        .deactivate => deactivate(),
        .spawn => {
            const cmd = g.vim_state.buf[0..g.vim_state.len];
            if (cmd.len > 0) completion.spawnCommand(cmd);
            deactivate();
        },
    }
}

fn activate() void {
    g.vim_state.reset();
    completion.clearGhost();
    render.markLayoutDirty();
    // Load completions and history on first activation.
    if (!completion.isCompletionsLoaded()) completion.loadCompletions();
    if (!completion.isHistLoaded()) completion.loadHistory(g.allocator);
    render.showCaret();

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
        log.warn("prompt: xcb_grab_keyboard_reply returned null: aborting activation", .{});
        return;
    }
    defer std.c.free(grab_reply);
    if (grab_reply.*.status != xcb.XCB_GRAB_STATUS_SUCCESS) {
        log.warn(
            "prompt: keyboard grab failed (status {}): aborting activation",
            .{grab_reply.*.status},
        );
        return;
    }
    g.is_active = true;
    render.markLayoutDirty();
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
    // on_deactivate must be called in exactly the situations dispatch routed
    // key input through the vim/normal handlers -- which is gated on
    // editor.addon_active, not the vim_mode config key. With the editor
    // addon registered but the key off, gating on vimModeEnabled() left a
    // pending operator/count prefix in g.vim_state across sessions.
    if (editor.addon_active) editor.handlers.on_deactivate(&g.vim_state);
    const conn = core.getState().conn;
    _ = xcb.xcb_ungrab_keyboard(conn, xcb.XCB_CURRENT_TIME);
    _ = xcb.xcb_flush(conn);
    g.redraw_pending = true;
    // Return the bar to whatever state it was actually in before the prompt
    // forced it to the top (e.g. re-hide it if a fullscreen window is still
    // active): see the comment on presentForPrompt() in activate().
    if (g.handlers) |h| h.dismissAfterPrompt();
}

/// This module's bar-segment contribution. The prompt is a runtime overlay
/// on the title slot: it never appears in a config's `[bar] segments` list
/// but still joins the bar's uniform lifecycle/poll loops.
/// The SEGMENT draw. The prompt paints the full slot it was reserved, so its
/// width is the reserved width; the report is what the row advances by, and
/// `Painted.span` states that rather than leaving it implied.
fn drawHook(ctx: *anyopaque, x: u16) !contract.Painted {
    const dc = segmod.castDraw(ctx);
    return contract.Painted.span(x, try draw(dc, x));
}

/// The OVERLAY draw. The overlay contract is a different hook with a
/// different return (advanced x, no width report -- the host slot owns the
/// geometry), so the same body needs its own adapter. Sharing one function
/// across both used to be possible only because neither said what it returned.
fn overlayDrawHook(ctx: *anyopaque, x: u16) !u16 {
    const dc = segmod.castDraw(ctx);
    return draw(dc, x);
}

pub const module: @import("contract").Segment = .{
    .name = "prompt",
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
        .draw = overlayDrawHook,
        .needsRepaint = overlayNeedsRepaint,
    },
};
