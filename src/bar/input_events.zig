//! The bar's input event intake: expose/button-press/motion/release
//! handlers and the click dispatch that routes a hit-tested
//! position to a segment's onClick hook. The handlers are thin
//! -- hit-test against the bounds the last layout pass RECORDED
//! (never re-derive geometry here), then delegate to the
//! registry's uniform hooks; the draw/dirty primitives and the
//! recorded-bound machinery stay in `bar.zig`, exposed pub.
//!
//! `bar.zig` imports this file to bind the handlers into its
//! `surfaces` struct and to dispatch the chrome-overlay click:
//! the two files form the bar subsystem's one intentional import
//! cycle (runtime accesses only, never comptime -- the same
//! hub-and-spoke shape check-layers.sh documents for
//! core<->window). Named `input_events` because the `events`
//! stem is taken by the core event loop.

const std = @import("std");
const build_options = @import("build_options");
const xcb = @import("core").xcb;
const actions = @import("actions");
const focus = @import("focus");
const constants = @import("constants");
const title_geom = @import("geom");
const contract = @import("contract");

const bar = @import("bar");
const draw = @import("draw");
const State = bar.State;
const SegBound = bar.SegBound;

/// The title segment's recorded on-screen bound, or null when the title
/// addon isn't registered (`title_id`) or the last layout pass never placed
/// it. Shared by the prompt-open click path and chromeToggleOverlay, so the
/// title id/name/bound resolution lives in one place.
pub fn titleIdBound(s: *State) ?SegBound {
    const center_id = bar.title_id orelse return null;
    return s.recordedBound(center_id);
}

/// Routes one click at `offset` pixels into segment `id` to its onClick hook
/// (not present -> no-op). `is_left`/`is_right` select the click's semantics
/// for the module (e.g. cycle direction for the layout/clock, minimize vs
/// focus for the title). Exported as a `BarHandlers.dispatchClick`-shaped
/// trampoline (see titleClickTrampoline).
pub fn dispatchClick(s: *State, id: usize, offset: u16, is_left: bool, is_right: bool) void {
    if (bar.segAt(id).onClick) |oc| {
        // Named, not inline `&.{}`: the temporary is only guaranteed to live
        // to the end of the call expression, and a `ctx` that outlived it (a
        // module storing the pointer) would be a silent lifetime bug. This
        // says the ctx cannot outlive the call.
        const ctx: contract.ClickCtx = .{
            .offset = offset,
            .is_left = is_left,
            .is_right = is_right,
            .state = s,
            .title_click = titleClickTrampoline,
            .redraw = draw.redrawInsideGrab,
        };
        _ = oc(&ctx);
    }
}

pub fn handleExpose(event: *const xcb.xcb_expose_event_t) void {
    if (bar.gBar.state) |s| if (event.window == s.win.win_id and event.count == 0) {
        if (build_options.has_floating and actions.isDragging()) s.dirty.flag = true else draw.performDraw();
    };
}

// Mouse click handling

/// Routes a ButtonPress on the bar window to whichever segment was clicked.
/// Called from input.zig before its managed-window click path: the bar is
/// never a managed window, so that path would just replay and swallow it.
///
/// Hit-testing walks the bounds RECORDED DURING THE LAST LAYOUT PASS in
/// record order (first containing bound wins), then delegates behavior to
/// the resolved module's single onClick hook (uniform registry dispatch).
///
/// Left-clicking a workspace icon switches to it; right-clicking one sends
/// the currently focused window to it. Right-clicking anywhere in the title
/// segment (empty or over any window's title, regardless of that window's
/// state) opens the prompt; left-clicking the title otherwise
/// focuses/minimizes/unminimizes the window shown there.
/// Left/right-clicking the layout indicator cycles the tiling layout
/// forward/backward; left/right-clicking the layout variants indicator
/// cycles the current layout's variant forward/backward the same way.
/// Left/right-clicking the clock cycles its display mode (date-time by
/// default, then time or date).
/// Scroll-wheel over a segment (buttons 4/5) routes to its `onScroll` hook
/// (the slider sub's clamp-step); a left press on a clickable segment arms
/// its `onDragMotion` hook for the duration of the press-hold.
pub fn handleButtonPress(event: *const xcb.xcb_button_press_event_t) void {
    const s = bar.gBar.state orelse return;
    if (!s.vis.shown) return;
    if (event.event_x < 0) return;
    const x: u16 = @intCast(event.event_x);

    const h = for (s.clicks.bounds[0..s.clicks.len]) |b| {
        if (b.contains(x)) break b;
    } else return;
    const id = h.id;

    const detail = event.detail;
    if (detail == constants.mouse_button_left) {
        s.drag_segment = id;
        dispatchClick(s, id, x - h.x, true, false);
        return;
    }
    if (detail == constants.mouse_button_right) {
        dispatchClick(s, id, x - h.x, false, true);
        return;
    }
    // Scroll buttons 4/5: no click semantics, no drag anchor. The repaint is
    // segment-scoped (see redrawScrolledSegment) so a fast wheel sweep never
    // forces full-bar redraws.
    s.drag_segment = null;
    if (detail == constants.mouse_button_scroll_up or
        detail == constants.mouse_button_scroll_down)
    {
        if (bar.segAt(id).onScroll) |scroll| {
            const dir: i8 = if (detail == constants.mouse_button_scroll_up) 1 else -1;
            s.scroll_segment = id;
            _ = scroll(dir, draw.redrawScopedSegment);
            s.scroll_segment = null;
            return;
        }
    }
}

/// Routes press-hold motion over the bar to the segment that owns the
/// in-flight button-1 scrub (`drag_segment`), if it declares `onDragMotion`.
/// X's implicit grab delivers motion to the grabbing (bar) window even when
/// the pointer leaves the bar, so the offset can span outside the segment;
/// segments clamp their own state. No drag owner -> no-op.
pub fn handleButtonMotion(event: *const xcb.xcb_motion_notify_event_t) void {
    const s = bar.gBar.state orelse return;
    const id = s.drag_segment orelse return;
    if (!s.vis.shown) return;
    if (bar.segAt(id).onDragMotion) |drag| {
        const tb = s.recordedBound(id) orelse return;
        const off_i = @as(i32, event.event_x) - @as(i32, tb.x);
        const offset: u16 = @intCast(std.math.clamp(off_i, 0, std.math.maxInt(u16)));
        // Scoped repaint, not redrawInsideGrab: a scrub only mutates the
        // dragged segment's slot, and a full-bar redraw per motion is the
        // frame-rate killer for subprocess-bound segments.
        _ = drag(offset, draw.redrawScopedSegment);
    }
}

/// Ends a press-hold scrub: clears the drag anchor and lets the segment
/// settle the drag (flush a throttled commit, leave its drag render mode).
pub fn handleButtonRelease(_: *const xcb.xcb_button_release_event_t) void {
    const s = bar.gBar.state orelse return;
    const id = s.drag_segment orelse return;
    s.drag_segment = null;
    if (bar.segAt(id).onDragEnd) |end| end(draw.redrawInsideGrab);
}

/// `offset` is the click position relative to the title segment's start.
/// Resolves which window is under the click via the title snapshot captured
/// by the last draw (title_geom.hitTest never touches X11: titles/geoms come from the
/// frame's in-process per-window caches), then:
///   - no window under the click -> no-op (empty title is handled by the
///     right-click prompt path in `handleButtonPress`, before this is called)
///   - the window is minimized -> unminimizes that window
///   - the window is already focused -> minimizes it
///   - otherwise -> focuses it
fn handleTitleClick(s: *State, offset: u16) void {
    if (s.frame.wins_len == 0) return;
    const tb = titleIdBound(s) orelse return;

    const target = title_geom.hitTest(s.frame.last_ctx.titleSnapshot(), tb.w, offset) orelse return;

    // `target.minimized` comes from the title snapshot's minimized set, which
    // the title addon synthesizes fresh; bar.zig never names minimize.
    if (target.minimized)
        actions.restore(target.window)
    else if (focus.getFocused() == target.window)
        actions.minimize(target.window)
    else
        focus.grabFocus(target.window, .mouse_click);
}

fn titleClickTrampoline(ptr: *anyopaque, offset: u16) void {
    const s: *State = @ptrCast(@alignCast(ptr));
    handleTitleClick(s, offset);
}
