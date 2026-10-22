//! Inline command prompt for the bar. Embeds an interactive command
//! runner into the bar's title segment.

const std = @import("std");

const core = @import("core");
const xcb = core.xcb;
const log = std.log.scoped(.prompt);

const types = @import("types");
const contract = @import("bar_contract");

const masks = @import("masks");
const segmod = @import("segment");
const editor = @import("editor");
const completion = @import("completion");
const render = @import("overlay");
// The vim modal-editing engine is a prompt addon: its lifecycle rides the
// generated `prompt_subs` registry, so this module never names it; dropping
// vim.zig just shortens `addons`, leaving the basic editor handlers.
pub const Addon = struct {
    register: *const fn () void,
    init: *const fn (std.mem.Allocator, usize) anyerror!void,
    deinit: *const fn (std.mem.Allocator) void,
};

/// The registry-facing spelling of this contract: build.zig types the
/// generated `prompt_subs` array through it, so no module names the struct.
pub const Binding = Addon;
pub const addons = @import("prompt_subs").addons;

// Editor contract re-exports: the vim extensor and the tests import these
// through the package core (`prompt`), never the private `editor` sibling.
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
pub const handleCtrl = editor.handleCtrl;
pub const insertChar = editor.insertChar;
pub const insertSlice = editor.insertSlice;
pub const deleteRange = editor.deleteRange;
pub const overwriteAt = editor.overwriteAt;
pub const isPrintableAscii = editor.isPrintableAscii;
pub const registerHandlers = editor.registerHandlers;
// Completion re-exports: `wordAtCursor` is the pure token-under-cursor
// split, pinned by completion_test.zig through the package core.
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

/// Cursor blink half-period: visible for this many ms, then invisible for
/// the same duration.
const cursor_blink_ms: u64 = 300;

const PromptState = struct {
    is_active: bool = false,
    vim_state: EditorState = .{},

    allocator: std.mem.Allocator = undefined,

    /// Bar-provided service handles (present/dismiss/isBarWindow), set at
    /// init; prompt never imports the bar orchestrator.
    handlers: ?*const segmod.BarHandlers = null,

    key_syms: ?*xcb_key_symbols_t = null,

    // Set by key handlers/`activate`/`deactivate` to notify the bar the
    // prompt needs redraw; `consumeRedrawRequest` clears it (one-way import).
    redraw_pending: bool = false,
};

var g: PromptState = .{};

/// Invalidates every cache derived from config/font metrics or bar height.
/// Called from bar.applyReload: these module globals are built against the
/// OLD config's fonts and bar height.
fn invalidateReloadCaches() void {
    render.invalidateReloadCaches();
}

fn isActive() bool {
    return g.is_active;
}

/// Milliseconds until the next blink toggle, or -1 when the blink
/// animation isn't running (non-negative only in insert mode).
fn blinkPollTimeoutMs() i32 {
    if (!g.is_active or g.vim_state.mode != .insert) return -1;
    return cursor_blink_ms;
}

/// Toggle cursor blink visibility; called by the bar's blink timer.
/// Flags a scoped repaint as well: while the prompt covers the title slot,
/// the title's needsRepaint hook forwards the overlay's query, so the
/// toggled caret reaches the screen without a whole-bar redraw. The bar
/// runs every onPollWakeup hook on any timer wakeup, so this guard
/// (matching blinkPollTimeoutMs) keeps a non-blinking prompt from
/// toggling invisible state.
fn blinkTick() void {
    if (!g.is_active or g.vim_state.mode != .insert) return;
    render.blinkTick();
}
/// Overlay repaint query (contract.BarOverlay.needsRepaint): true while a
/// caret toggle is waiting to be drawn. Cleared inside `draw`.
fn overlayNeedsRepaint() bool {
    return render.overlayNeedsRepaint();
}

/// Returns true and clears the flag if a prompt-driven redraw is
/// outstanding. Call once per event-loop iteration from bar.updateIfDirty.
fn consumeRedrawRequest() bool {
    const pending = g.redraw_pending;
    g.redraw_pending = false;
    return pending;
}

/// Initialises prompt state needed regardless of whether the prompt is
/// ever opened: the bar service handles, vim engine, and key-symbol table.
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
fn deinit(allocator: std.mem.Allocator) void {
    inline for (addons) |a| a.deinit(allocator);
    if (g.key_syms) |ks| {
        xcb_key_symbols_free(ks);
        g.key_syms = null;
    }
    if (g.vim_state.buf.len != 0) g.vim_state.deinit();
    g = .{};
}

fn toggle() void {
    if (g.is_active) deactivate() else activate();
}

/// Query the X pointer and decide what close_window should do while the
/// prompt is active: cursor over the bar -> kill the prompt; over a
/// program -> let the WM close it; over nothing -> swallow the key.
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

/// Complete key-event routing entry point called by
/// `core/input/keys.zig`. Keeps prompt-specific routing out of the key
/// handler: returns false immediately when inactive (normal keybind
/// dispatch), routes `close_window` by cursor position, and otherwise
/// delegates to `handleKeyPress`. `bound_action` is whatever the keybind
/// map resolved (null is fine when there's no binding).
fn handlePromptKeypress(
    event: *const contract.KeyPressEvent,
    bound_action: ?*const types.Action,
) bool {
    if (!g.is_active) return false;
    // The hook receives the opaque event (contract is X-free); the fields
    // are read here, on the X side, via the concrete xcb type.
    const xevent: *const core.xcb.xcb_key_press_event_t = @ptrCast(@alignCast(event));

    // With the mod key (Super) held and a WM action bound to this key, let
    // the normal dispatcher run so WM operations don't cancel the prompt;
    // close_window still routes here when the cursor is over the bar.
    if (bound_action) |action| {
        if (action.* == .close_window) return closeWindowOrPromptUnderCursor();
        if (xevent.state & xcb.XCB_MOD_MASK_4 != 0)
            return false; // let WM dispatch execute the bind; prompt stays open
    }
    return handleKeyPress(xevent);
}

/// Low-level key-press handler, called after all prompt-level routing.
fn handleKeyPress(event: *const xcb.xcb_key_press_event_t) bool {
    // Only process XCB_KEY_PRESS events: press and release share the same
    // struct layout, so the loop sometimes casts a release and dispatches
    // it here. Without this guard the Escape release is a trap:
    // handleInsert switches to .normal on press, then handleNormal sees
    // xk_escape with a clean pending and deactivates -- the prompt is gone
    // before the next editing key arrives. Returning true keeps the
    // release from falling through to WM keybind dispatch.
    if (masks.coreEventType(event.response_type) != xcb.XCB_KEY_PRESS) return true;

    const syms = g.key_syms orelse return false;

    const shift_held = event.state & xcb.XCB_MOD_MASK_SHIFT != 0;
    const ctrl_held = event.state & xcb.XCB_MOD_MASK_CONTROL != 0;
    const col: c_int = if (shift_held) 1 else 0;
    const sym = xcb_key_symbols_get_keysym(syms, event.detail, col);

    // Drop bare modifier key events (Shift, Ctrl, Alt, Super, Meta, Hyper).
    // XCB delivers a key event for every key including modifiers, so Shift
    // before '$'/'^' fires XK_Shift_L/R first. Reaching handleNormal, that
    // falls through to resetPendingCmd(), clearing any pending
    // operator/count: why d$, d^, c$, y^, visual 3W silently become bare
    // cursor moves. Keysyms occupy 0xFFE1-0xFFEE; the band widens by one.
    if (masks.isModifierKeysym(sym)) return true;

    // Ctrl-modified keys. Route EVERY Ctrl key through the mode handler,
    // not just in vim mode: otherwise Ctrl-C (and Ctrl-W with vim on) is
    // swallowed by the `.none` fallback and can't cancel the prompt.
    if (ctrl_held) {
        const action = editor.handlers.handle_ctrl(&g.vim_state, sym);
        // handleCtrl may have deleted text (Ctrl-W / Ctrl-U), so the ghost
        // is recomputed in the shared tail; the blink phase is untouched.
        return finishKeyPress(action, false);
    }

    // Tab: accept ghost completion
    if (sym == @intFromEnum(XK.Tab) and g.vim_state.mode == .insert) {
        return acceptGhost();
    }

    // No handler installed means there is no modal engine to dispatch to,
    // so insert mode falls back to the basic editor. With one installed,
    // insert keys go to the handler like every other mode.
    const action = if (!editor.addon_active and g.vim_state.mode == .insert)
        handleInsertBasic(&g.vim_state, sym)
    else switch (g.vim_state.mode) {
        .insert => editor.handlers.handle_insert(&g.vim_state, sym),
        .normal => editor.handlers.handle_normal(&g.vim_state, sym),
    };
    return finishKeyPress(action, true);
}

/// Shared tail for every key that edited the buffer: run the action,
/// recompute the ghost suggestion, and schedule a redraw. Returns true.
fn finishKeyPress(action: Action, refresh_blink: bool) bool {
    handleAction(action);
    completion.updateGhost(&g.vim_state);
    if (refresh_blink) render.showCaret();
    render.markLayoutDirty();
    g.redraw_pending = true;
    return true;
}

/// Inserts as much of the ghost completion as fits (clamped to the input
/// limit), then finishes the key press, which recomputes the ghost.
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
/// whole title slot; returns the right edge (title's draw delegation).
fn draw(ctx: *segmod.DrawCtx, x: u16) !u16 {
    // Clearing before the draw (not after) means a draw error still
    // consumes the request, so a failing overlay can't re-request forever.
    render.clearBlinkRepaint();
    // While covered, title's pollTimeoutMsHook contributes no marquee
    // wakeup (title owns that decision), so no explicit pause is needed.
    return render.drawActive(ctx.dc, &ctx.config, ctx.height, x, ctx.width, &g.vim_state);
}

/// Dispatches a vim.Action returned by a mode handler: executes/closes on
/// spawn, deactivates on deactivate, no-ops on none.
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
    // always visible; reversed in deactivate() via dismissAfterPrompt().
    if (g.handlers) |h| h.presentForPrompt();
    // No xcb_flush: xcb_grab_keyboard_reply already drained the output
    // buffer, and presentForPrompt() flushes its own requests.
}

fn deactivate() void {
    g.is_active = false;
    // on_deactivate must be called in exactly the situations dispatch
    // routed key input through the vim/normal handlers -- gated on
    // editor.addon_active (a modal handler set is installed), not a config key.
    if (editor.addon_active) editor.handlers.on_deactivate(&g.vim_state);
    const conn = core.getState().conn;
    _ = xcb.xcb_ungrab_keyboard(conn, xcb.XCB_CURRENT_TIME);
    _ = xcb.xcb_flush(conn);
    g.redraw_pending = true;
    // Return the bar to whatever state it was in before the prompt forced
    // it to the top (e.g. re-hide it if a fullscreen window is still active).
    if (g.handlers) |h| h.dismissAfterPrompt();
}

/// This module's bar-segment contribution. The prompt is a runtime overlay
/// on the title slot, so a config's `[bar] segments` list does not carry it
/// by default -- but `prompt` IS a valid entry (listing it renders the
/// segment inline; the SEGMENT draw hook below is bound for that path): the
/// prompt paints the full slot it was reserved, so its width is that slot.
fn drawHook(ctx: *anyopaque, x: u16) !contract.Painted {
    const dc = segmod.castDraw(ctx);
    return contract.Painted.span(x, try draw(dc, x));
}

/// The OVERLAY draw: the overlay contract is a different hook with a
/// different return (advanced x, no width report -- the host slot owns
/// the geometry), so the same body needs its own adapter.
fn overlayDrawHook(ctx: *anyopaque, x: u16) !u16 {
    const dc = segmod.castDraw(ctx);
    return draw(dc, x);
}

pub const module = segmod.module(
    "prompt",
    drawHook,
    null,
    .{
        .mode = .unmeasured,
        .init = init,
        .deinit = deinit,
        .pollTimeoutMs = blinkPollTimeoutMs,
        .onPollWakeup = blinkTick,
        .handleKeypress = handlePromptKeypress,
        .consumeRedrawRequest = consumeRedrawRequest,
        .invalidateReloadCaches = invalidateReloadCaches,
        .overlay = .{
            .is_active = isActive,
            .toggle = toggle,
            .draw = overlayDrawHook,
            .needsRepaint = overlayNeedsRepaint,
        },
    },
);
