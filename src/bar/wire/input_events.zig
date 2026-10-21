//! The bar's input event intake: expose/button handlers and click dispatch
//! routing a hit-tested position to a segment's onClick hook. Handlers are
//! thin -- hit-test against the bounds the last layout pass RECORDED (never
//! re-derive geometry here), then delegate to the registry's uniform hooks;
//! the bounds' machinery and state live in `state.zig`. `bar.zig` imports
//! this file for handler binding and the chrome-overlay click; this file
//! reads state through `state.zig`, never through `bar.zig`, so the edge is
//! one-way.

const std = @import("std");
const xcb = @import("core").xcb;
const window = @import("window");
const focus = @import("focus");
const masks = @import("masks");
const title_geom = @import("geom");
const contract = @import("bar_contract");
const segmod = @import("segment");

const state = @import("state");
const render = @import("render");
const State = state.State;
const SegBound = state.SegBound;

/// The title segment's recorded on-screen bound, or null when the title
/// addon isn't registered (`title_id`) or never placed. Shared by the
/// prompt-open click path and chromeToggleOverlay so the id/name/bound
/// resolution lives in one place.
pub fn titleIdBound(s: *State) ?SegBound {
    const center_id = state.title_id orelse return null;
    return render.recordedBound(s, center_id);
}

/// Routes one click at `offset` pixels into segment `id` to its onClick hook
/// (not present -> no-op). `is_left`/`is_right` select the module's click
/// semantics. Exported as a `BarHandlers.dispatchClick`-shaped trampoline.
pub fn dispatchClick(s: *State, id: usize, offset: u16, is_left: bool, is_right: bool) void {
    if (segmod.segmentAt(id).onClick) |oc| {
        // Named, not inline `&.{}`: the temporary only lives to the end of
        // the call expression; a `ctx` that outlived it (a module storing
        // the pointer) would be a silent lifetime bug. This says the ctx
        // cannot outlive the call.
        const ctx: contract.ClickCtx = .{
            .offset = offset,
            .is_left = is_left,
            .is_right = is_right,
            .state = s,
            .title_click = titleClickTrampoline,
            .redraw = render.redrawInsideGrab,
        };
        _ = oc(&ctx);
    }
}

pub fn handleExpose(event: *const xcb.xcb_expose_event_t) void {
    if (state.gBar.state) |s| if (event.window == s.win.win_id and event.count == 0) {
        // A damaged region must be REPAINTED now, even mid-drag: setting the
        // dirty flag and skipping performDraw loses the expose entirely --
        // the tick-driven next draw sees no seg bits dirty, skips
        // repainting, and clears the flag. The drag defers its own per-tick
        // blit, so the expose deserves a full performDraw here.
        render.performDraw();
    };
}

/// Scroll direction for a ButtonPress detail: wheel-up is +1, wheel-down is
/// −1, everything else not a scroll (null). Split out of
/// `handleButtonPress` so the mapping is testable without an `onScroll`
/// binder in the build.
pub fn scrollDir(detail: u8) ?i8 {
    if (detail == masks.mouse_button_scroll_up) return 1;
    if (detail == masks.mouse_button_scroll_down) return -1;
    return null;
}

/// Routes a ButtonPress on the bar window to whichever segment was clicked.
/// Called from core/input/mouse.zig before its managed-window click path:
/// the bar is never a managed window, so that path would just replay and
/// swallow it.
///
/// Hit-testing walks the bounds RECORDED DURING THE LAST LAYOUT PASS in
/// record order (first containing bound wins), then delegates to the
/// resolved module's single onClick hook. Per-segment click/scroll/drag
/// semantics live with each module's hook.
pub fn handleButtonPress(event: *const xcb.xcb_button_press_event_t) void {
    const s = state.gBar.state orelse return;
    if (!s.vis.shown) return;
    if (event.event_x < 0) return;
    const x: u16 = @intCast(event.event_x);

    const h = for (s.clicks.bounds[0..s.clicks.len]) |b| {
        if (b.contains(x)) break b;
    } else return;
    const id = h.id;

    const detail = event.detail;
    if (detail == masks.mouse_button_left) {
        s.drag_segment = id;
        dispatchClick(s, id, x - h.x, true, false);
        return;
    }
    if (detail == masks.mouse_button_right) {
        dispatchClick(s, id, x - h.x, false, true);
        return;
    }
    // Scroll buttons 4/5: no click semantics, no drag anchor. The repaint is
    // segment-scoped (see redrawScopedSegment) so a fast wheel sweep never
    // forces full-bar redraws.
    //
    // `s.drag_segment` is deliberately NOT nulled on a scroll press -- a
    // button-1 drag currently in flight has its anchor here, and clearing it
    // would make handleButtonRelease's `orelse return` drop onDragEnd
    // (throttled commit unflushed, drag render mode stuck).
    if (scrollDir(detail)) |dir| {
        if (segmod.segmentAt(id).onScroll) |scroll| {
            s.scroll_segment = id;
            _ = scroll(dir, render.redrawScopedSegment);
            s.scroll_segment = null;
            return;
        }
    }
}

/// Routes press-hold motion to the segment that owns the in-flight
/// button-1 scrub (`drag_segment`), if it declares `onDragMotion`. X's
/// implicit grab delivers motion to the grabbing (bar) window even when the
/// pointer leaves the bar, so the offset can span outside the segment;
/// segments clamp their own state. No drag owner -> no-op.
pub fn handleButtonMotion(event: *const xcb.xcb_motion_notify_event_t) void {
    const s = state.gBar.state orelse return;
    const id = s.drag_segment orelse return;
    if (!s.vis.shown) return;
    if (segmod.segmentAt(id).onDragMotion) |drag| {
        const tb = render.recordedBound(s, id) orelse return;
        const off_i = @as(i32, event.event_x) - @as(i32, tb.x);
        const offset: u16 = @intCast(std.math.clamp(off_i, 0, std.math.maxInt(u16)));
        // Scoped repaint, not redrawInsideGrab: a scrub only mutates the
        // dragged segment's slot, and a full-bar redraw per motion is the
        // frame-rate killer for subprocess-bound segments.
        _ = drag(offset, render.redrawScopedSegment);
    }
}

/// Ends a press-hold scrub: clears the drag anchor, lets the segment settle
/// (flush a throttled commit, leave its drag render mode).
pub fn handleButtonRelease(_: *const xcb.xcb_button_release_event_t) void {
    const s = state.gBar.state orelse return;
    const id = s.drag_segment orelse return;
    s.drag_segment = null;
    if (segmod.segmentAt(id).onDragEnd) |end| end(render.redrawInsideGrab);
}

/// Which title-click hook fires for a hit-tested target. Priority contract:
/// a minimized window always restores -- even when it is ALSO the focused
/// window -- a focused window minimizes, anything else takes focus. Pure, so
/// the ordering is testable without the reconcile-bound hooks it selects.
pub const TitleAction = enum { unminimize, minimize, focus };

pub fn titleClickAction(target: title_geom.ClickTarget, focused: ?u32) TitleAction {
    if (target.minimized) return .unminimize;
    if (focused != null and focused.? == target.window) return .minimize;
    return .focus;
}

/// `offset` is the click position relative to the title segment's start.
/// Resolves which window is under the click via the title snapshot captured
/// by the last draw (title_geom.hitTest never touches X11: titles/geoms come
/// from the frame's in-process per-window caches), then dispatches the
/// branch `titleClickAction` picks. No window under the click -> no-op
/// (empty-title right-click is the prompt path in `handleButtonPress`,
/// before this is called).
fn handleTitleClick(s: *State, offset: u16) void {
    if (s.frame.entries_len == 0) return;
    const tb = titleIdBound(s) orelse return;

    const target = title_geom.hitTest(s.frame.last_ctx.titleSnapshot(), tb.w, offset) orelse return;

    // `target.minimized` comes from the title snapshot's minimized set,
    // which the title addon synthesizes fresh; bar.zig never names minimize.
    switch (titleClickAction(target, focus.getFocused())) {
        .unminimize => window.command.callHook(.unminimize, .{target.window}),
        .minimize => window.command.callHook(.minimizeWindow, .{target.window}),
        .focus => focus.grabFocus(target.window, .mouse_click),
    }
}

fn titleClickTrampoline(ptr: *anyopaque, offset: u16) void {
    const s: *State = @ptrCast(@alignCast(ptr));
    handleTitleClick(s, offset);
}
