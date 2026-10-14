//! The prompt's overlay renderer: the scroll-aware text
//! spans, the mode pill, the block/blink carets, and the
//! layout cache that keeps a caret-blink frame allocation-
//! and measurement-free. All measurement caches live in this
//! module's global; the editor state (buffer, cursor, mode)
//! and the ghost suffix are passed in by the package core,
//! which owns activation and key routing.

const types = @import("types");
const drawing = @import("drawing");
const editor = @import("editor");
const completion = @import("completion");

// Minimum pixel width of the block cursor; ensures it is visible even on
// the narrowest glyphs (e.g. '.', '!').
const min_cursor_px: u16 = 8;
// Number of editing modes (derived from the editor's Mode enum at
// comptime).
const num_modes = @typeInfo(editor.Mode).@"enum".fields.len;

const cursor_width: u16 = 1;
const cursor_v_pad: u16 = 2;
/// Ink/pill margin: scrolled post-cursor text stops this many px short of the
/// mode pill so ink never bleeds into it.
const pill_ink_gap_px: u16 = 2;

const RenderState = struct {
    cached_prompt_w: ?u16 = null,
    // Cached pixel width of each mode label, indexed by `vim.Mode` integer value.
    cached_mode_w: [num_modes]?u16 = .{null} ** num_modes,

    is_blink_visible: bool = true,

    // Caret geometry cached after the first insert-mode draw.  Font metrics
    // and bar height are constant between reloads, so these never need clearing.
    cached_caret_top: ?u16 = null,
    cached_caret_h: ?u16 = null,

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

var g: RenderState = .{};

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

/// Overlay repaint query (contract.BarOverlay.needsRepaint): true while a
/// caret toggle is waiting to be drawn. Cleared inside `draw`.
pub fn overlayNeedsRepaint() bool {
    return g.blink_repaint;
}

/// Toggle cursor blink visibility and flag the scoped repaint. Called by
/// the package core's blink tick, which owns the active/insert-mode guard
/// (a non-blinking prompt must not toggle invisible state or queue
/// repaints off the clock's cadence).
pub fn blinkTick() void {
    g.is_blink_visible = !g.is_blink_visible;
    g.blink_repaint = true;
}

/// Clears the scoped repaint flag. Called by the package core's `draw`
/// BEFORE painting (not after): clearing first means a draw error still
/// consumes the request, so a persistently failing overlay can't
/// re-request forever.
pub fn clearBlinkRepaint() void {
    g.blink_repaint = false;
}

/// Flag the layout cache stale: the next draw recomputes caret widths
/// and the scroll offset. Called by the package core on keypress and
/// activation (buffer/cursor/mode changed).
pub fn markLayoutDirty() void {
    g.layout_dirty = true;
}

/// Force the caret visible (e.g. right after an edit: the user just
/// typed, so blink restarts from the visible phase).
pub fn showCaret() void {
    g.is_blink_visible = true;
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

/// On-screen origin of a `w`-wide span at pen `px` clipped to the visible
/// window `[tl, se)`, or null when the span lies fully off-screen. Shared by
/// the pre-cursor span draw and the block cursor: both must skip the
/// invisible prefix and start painting at `max(px, tl)`.
inline fn clipOrigin(px: i32, w: u32, tl: i32, se: i32) ?i32 {
    if (px + @as(i32, @intCast(w)) <= tl or px >= se) return null;
    return @max(px, tl);
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
            dc.drawTextEllipsis(draw_x, baseline, text, remaining, color);
        return;
    }
    const w = text_w orelse dc.measureTextWidth(text);
    defer px.* += @intCast(w);
    if (w == 0) return;

    const tl: i32 = text_left_x;
    const se: i32 = scroll_end_x;
    const origin = clipOrigin(px.*, w, tl, se) orelse return;

    // Skip the prefix that lies off-screen to the left.
    const start: usize = if (px.* < tl) measureBound(dc, text, @intCast(tl - px.*), .ge) else 0;

    const draw_x: u16 = @intCast(origin);
    const available: u16 = @intCast(se - origin);

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
        dc.drawText(draw_x, baseline, visible, color);
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
) void {
    const block_text = if (hi > lo) buf[lo..hi] else " ";
    const block_w = @max(text_w orelse dc.measureTextWidth(block_text), min_cursor_px);

    if (clipOrigin(px.*, block_w, style.text_left_x, style.scroll_end_x)) |origin| {
        const draw_x: u16 = @intCast(origin);
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
                dc.drawText(draw_x, style.baseline, block_text, style.bg);
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
        const asc, const desc = dc.metrics();
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

/// Pixel width of the prompt text, measured once and cached (font and prompt
/// are constant between reloads).
fn promptWidth(dc: *drawing.DrawContext, prompt: []const u8) u16 {
    return editor.measureCached(&g.cached_prompt_w, dc, prompt);
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
    vim_state: *const editor.EditorState,
    pre_cur_text: []const u8,
    max_scroll_px: u16,
) void {
    if (!g.layout_dirty and height == g.cached_height) return;

    if (g.layout_dirty) g.cached_pre_w = dc.measureTextWidth(pre_cur_text);
    // When !layout_dirty: only height changed; text and cursor are unchanged,
    // so cached_pre_w remains valid.
    g.cached_caret_w = if (vim_state.mode == .insert)
        cursor_width
    else
        @max(
            dc.measureTextWidth(if (vim_state.cursor < vim_state.len)
                vim_state.buf[vim_state.cursor .. vim_state.cursor + 1]
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
    vim_state: *const editor.EditorState,
    accent: u32,
) ?u16 {
    const pill_h_pad: u16 = 6;
    const white: u32 = 0xFFFFFFFF;

    // (27.4) The pill describes the mode the handler is actually in. Gating it
    // on the config key suppressed it for exactly the addons that installed a
    // mode engine, so the bar showed a mode the user was in with no label.
    // (27.5) The width comes from the mode, not from measuring here: the bar no
    // longer owns the "label implies pill" rule, only the drawing of it.
    const mode_idx: usize = @intFromEnum(vim_state.mode);
    const mode_w: u16 = if (editor.addon_active)
        vim_state.mode.hintWidth(dc, &g.cached_mode_w[mode_idx])
    else
        0;
    const mode_label = if (editor.addon_active) vim_state.mode.label() else "";

    // The pill only exists when the mode has a hint; with no addon, or no
    // hint, the text region gets the full width.
    const show_pill = mode_w > 0;
    const pill_w: u16 = mode_w + pill_h_pad * 2;
    const pill_fits = text_end_x >= pill_w;

    // Reserve the pill width on the right; the scrollable region ends here.
    // When the label cannot fit we drop the pill but still give the text the
    // whole region: blanking the prompt because the mode pill didn't fit hid
    // the user's typing.
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
        dc.drawText(pill_x + pill_h_pad, baseline, mode_label, white);
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
    vim_state: *const editor.EditorState,
    accent: u32,
) !void {
    // Caret geometry was pre-computed in ensureCaretGeom.
    const caret_top = g.cached_caret_top.?;
    const caret_h = g.cached_caret_h.?;
    if (g.is_blink_visible and px.* >= @as(i32, text_left_x) and px.* < @as(i32, scroll_end_x)) {
        dc.fillRect(@intCast(px.*), caret_top, cursor_width, caret_h, accent);
    }

    // Ghost text (only when cursor is at end).
    const ghost = completion.ghost();
    if (ghost.len > 0 and vim_state.cursor == vim_state.len)
        try drawScrollSpan(true, dc, px, text_left_x, scroll_end_x, baseline, ghost, null, accent);
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
    vim_state: *const editor.EditorState,
    accent: u32,
    bg: u32,
) !void {
    const cur_hi = @min(vim_state.cursor + @intFromBool(vim_state.mode != .insert), vim_state.len);

    const style: CursorStyle = .{ .text_left_x = text_left_x, .scroll_end_x = scroll_end_x, .baseline = baseline, .height = height, .accent = accent, .bg = bg };
    drawBlockCursor(
        dc,
        px,
        style,
        vim_state.buf,
        vim_state.cursor,
        cur_hi,
        g.cached_caret_w,
    );
}

/// Render the active input UI.
///
/// Layout: [ pad | scrollable: PROMPT | pre | CURSOR/SELECTION | post |
/// MODE_LABEL | pad ].  The mode label is pinned right (never scrolls); the
/// scrollable region keeps the cursor in view.
pub fn drawActive(
    dc: *drawing.DrawContext,
    // By pointer, not by value: this is a per-frame draw that only READS
    // config, and a full `BarConfig` struct copy per frame bought nothing.
    config: *const types.BarConfig,
    height: u16,
    start_x: u16,
    width: u16,
    vim_state: *const editor.EditorState,
) !u16 {
    const end_x = start_x + width;
    const pad = config.scaledSegmentPadding(height);
    const accent = config.runPromptColor();
    const bg = config.runBg();
    const fg = config.runFg();
    const prompt = config.run_prompt orelse types.default_run_prompt;

    dc.fillRect(start_x, 0, width, height, bg);

    const baseline = dc.baselineY(height);
    const text_left_x = start_x + pad;
    const text_end_x = end_x -| pad;
    if (text_left_x >= text_end_x) return end_x;

    ensureCaretGeom(dc, height);

    // Mode widget, pinned right; does not scroll.  Its left edge bounds the
    // scrollable text region.
    const scroll_end_x = drawPill(dc, height, baseline, text_left_x, text_end_x, vim_state, accent) orelse
        return end_x;
    // Clip post-cursor text 2 px before the pill so ink never bleeds into it.
    const post_clip_end_x = scroll_end_x -| pill_ink_gap_px;

    const max_scroll_px: u16 = scroll_end_x - text_left_x;
    const prompt_w = promptWidth(dc, prompt);

    // In INSERT mode the caret doesn't consume its character; post_text
    // starts at cursor and caret_w is `cursor_width`; all other modes use a
    // full-character block.
    const pre_cur_text = vim_state.buf[0..vim_state.cursor];
    refreshLayoutCache(dc, height, prompt, prompt_w, vim_state, pre_cur_text, max_scroll_px);

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
    switch (vim_state.mode) {
        .insert => try drawInsertMode(dc, baseline, text_left_x, scroll_end_x, &px, vim_state, accent),
        else => try drawNormalMode(dc, height, baseline, text_left_x, scroll_end_x, &px, vim_state, accent, bg),
    }

    const post_start = @min(vim_state.cursor + @intFromBool(vim_state.mode != .insert), vim_state.len);
    try drawScrollSpan(true, dc, &px, text_left_x, post_clip_end_x, baseline, vim_state.buf[post_start..vim_state.len], null, fg);

    // No blitRegion here: the prompt draws as a segment inside performDraw,
    // whose end-of-batch queueBlit copies the whole frame (and the caller
    // flushes it). A mid-frame region copy+flush here would (a) enqueue a
    // redundant second copy_area + flush per prompt frame and, worse, (b)
    // snapshot the off-screen pixmap BEFORE sibling segments in the same
    // batch are painted, briefly showing stale neighbors. Let the batch-end
    // full blit win.
    return end_x;
}
