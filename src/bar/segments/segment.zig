//! Uniform segment contract (D3).
//!
//! ONE dispatch point per segment concern; adding a segment touches this
//! file plus its own module instead of six switches across bar.zig:
//!
//!   naturalWidth(seg, snap, clock_w)  — reserved row width
//!   draw(seg, env, x, width, ...)     — render at x, return advanced x
//!   isClickable(seg)                  — comptime participation table
//!   shouldSkip(snap, seg)             — dirty-diff skip
//!   onClick(seg, offset, left, redraw)- action dispatch for recorded bounds
//!
//! Title/prompt keep their richer internal machinery behind the thin
//! adapters here (DrawEnv.tctx/.tsnap); their complexity does not leak into
//! the orchestrator. Width policy constants moved INTO their owning segments
//! (tags.fallback_width, layout.natural_width, title.min_width).

const std = @import("std");

const drawing = @import("drawing");
const types = @import("types");

const tags = @import("tags");
const clock = @import("clock");
const layout_seg = @import("layout");
const variants = @import("variants");
const title = @import("title");
const prompt = @import("prompt");

const snapshot = @import("snapshot");

/// Render environment shared by every segment's draw call.
pub const Env = struct {
    dc: *drawing.DrawContext,
    config: types.BarConfig,
    height: u16,
};

/// Extra inputs only the title adapter consumes (built by bar.zig's
/// titleCtx / makeTitleSnapshot; ignored by every other arm).
pub const TitleInputs = struct {
    ctx: title.TitleRenderContext,
    tsnap: title.TitleSnapshot,
    allocator: std.mem.Allocator,
    invalidated: bool,
};

// -- Width ------------------------------------------------------------------

pub fn naturalWidth(seg: types.BarSegment, snap: *const snapshot.BarSnapshot, clock_width: u16) u16 {
    return switch (seg) {
        .workspaces => if (snap.workspace_count > 0)
            @intCast(snap.workspace_count * tags.getCachedWorkspaceWidth())
        else
            tags.fallback_width,
        .layout, .variants => layout_seg.natural_width,
        .title => title.min_width,
        .clock => clock_width,
    };
}

// -- Skip logic ---------------------------------------------------------------

/// Returns true when `seg` should be skipped because its data has not changed
/// since the last frame and a full redraw is not required.
pub fn shouldSkip(snap: *const snapshot.BarSnapshot, seg: types.BarSegment) bool {
    if (snap.is_full_redraw) return false;
    return switch (seg) {
        .workspaces => !snap.is_workspace_dirty,
        .title => !snap.is_title_dirty,
        else => false,
    };
}

// -- Clickability -------------------------------------------------------------

/// Comptime participation table: which segments record hit-test bounds and
/// route clicks. Adding a clickable segment means an entry here plus an
/// onClick arm — nothing else.
pub fn isClickable(seg: types.BarSegment) bool {
    return switch (seg) {
        .workspaces, .layout, .variants, .title => true,
        .clock => false,
    };
}

// -- Draw ---------------------------------------------------------------------

/// Draws `seg` at `x`. `width` is the reserved width (title center layout);
/// other arms ignore it and use their own measured width. Returns the new x
/// ("drew nothing" is signalled by returning x unchanged, per drawRowSegment).
pub fn draw(
    seg: types.BarSegment,
    env: Env,
    x: u16,
    width: u16,
    snap: *const snapshot.BarSnapshot,
    ti: TitleInputs,
) !u16 {
    _ = width;
    _ = ti;
    switch (seg) {
        .workspaces => return try tags.draw(env.dc, env.config, env.height, x, snap.current_workspace, snap.workspace_has_windows.items, snap.is_all_view_active),
        .layout => return try layout_seg.draw(env.dc, env.config, env.height, x),
        .variants => return try variants.draw(env.dc, env.config, env.height, x),
        .clock => return try clock.draw(env.dc, env.config, env.height, x),
        // Routed through bar.zig's title/prompt adapter instead: prompt.draw
        // needs caller-owned title-cache pointers that live on bar.State.
        // Threading four extra optionals through every arm for exactly one
        // caller would tax all segments for the sake of one.
        .title => unreachable,
    }
}

// -- Clicks -------------------------------------------------------------------

/// Action dispatch for a click inside a recorded segment bound. `offset` is
/// relative to the segment start. `left` distinguishes button; anything that
/// is not left/right is rejected by the caller. `redraw` is bar's
/// redrawInsideGrab (passed in so this module doesn't import bar).
/// Returns true when the click was consumed.
pub fn onClick(
    seg: types.BarSegment,
    offset: u16,
    left: bool,
    right: bool,
    state_ptr: *anyopaque,
    title_click: *const fn (*anyopaque, u16) void,
    redraw: *const fn () void,
) bool {
    switch (seg) {
        .workspaces => {
            const idx = resolveWorkspaceClick(offset) orelse return true;
            var actx = makeActionCtx();
            if (left) {
                actions.switchTo(&actx, @intCast(idx));
            } else if (right) {
                const win = focus.getFocused() orelse return true;
                actions.moveWindowTo(&actx, win, @intCast(idx));
            }
            return true;
        },
        .title => {
            if (right) {
                if (!prompt.isActive()) prompt.toggle();
            } else if (!prompt.isActive()) {
                title_click(state_ptr, offset);
            }
            return true;
        },
        .layout => {
            var actx = makeActionCtx();
            actions.cycleLayoutKind(&actx, if (left) 1 else -1);
            redraw();
            return true;
        },
        .variants => {
            var actx = makeActionCtx();
            actions.stepVariantDir(&actx, if (left) 1 else -1);
            redraw();
            return true;
        },
        .clock => return false,
    }
}

fn makeActionCtx() actions.Ctx {
    return .{ .focused_window_id = focus.getFocused() };
}

const actions = @import("actions");
const focus = @import("focus");

fn resolveWorkspaceClick(offset: u16) ?usize {
    const cell_w = tags.getCachedWorkspaceWidth();
    if (cell_w == 0) return null;
    const ws_state = @import("workspaces").getState() orelse return null;
    const idx: usize = @intCast(offset / cell_w);
    if (idx >= ws_state.workspaces.len) return null;
    return idx;
}
