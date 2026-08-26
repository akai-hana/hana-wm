//! Uniform segment contract (D3).
//!
//! ONE dispatch point per segment concern; adding a segment touches this
//! file plus its own module instead of six switches across bar.zig:
//!
//!   naturalWidth(seg, frame, clock_w) — reserved row width
//!   draw(seg, env, x, frame)          — render at x, return advanced x
//!   onClick(seg, offset, left, redraw)- action dispatch for recorded bounds
//!
//! Rendering uses per-segment dirty tracking: only segments whose dirty bit
//! is set get repainted on each frame. Title/prompt keep their richer
//! internal machinery behind the thin adapter in draw()'s `.title` arm;
//! their complexity does not leak into the orchestrator. Width policy
//! constants moved INTO their owning segments
//! (tags.fallback_width, layout.natural_width, title.min_width).

const drawing = @import("drawing");
const types = @import("types");
const actions = @import("actions");
const focus = @import("focus");
const build_options = @import("build_options");

const tags = if (build_options.has_seg_tags) @import("tags") else struct {
    pub fn getCachedWorkspaceWidth() u16 { return 0; }
    pub const fallback_width: u16 = 0;
    pub fn draw(_: anytype, _: anytype, _: anytype, x: u16, _: anytype, _: anytype, _: anytype) !u16 { return x; }
};
const clock = if (build_options.has_seg_clock) @import("clock") else struct {
    pub fn draw(_: anytype, _: anytype, _: anytype, x: u16) !u16 { return x; }
};
const layout_seg = if (build_options.has_seg_layout) @import("layout") else struct {
    pub const natural_width: u16 = 0;
    pub fn draw(_: anytype, _: anytype, _: anytype, x: u16) !u16 { return x; }
};
const variants = if (build_options.has_seg_variants) @import("variants") else struct {
    pub fn draw(_: anytype, _: anytype, _: anytype, x: u16) !u16 { return x; }
};
const title = if (build_options.has_seg_title) @import("title") else struct {
    pub const min_width: u16 = 0;
};
const prompt = if (build_options.has_seg_prompt) @import("prompt") else struct {
    pub fn isActive() bool { return false; }
    pub fn toggle() void {}
};

/// Live workspace state for one bar frame, collected fresh by bar.zig
/// every draw. The only segment-visible slice of WM state.
pub const Frame = struct {
    workspace_count: u32 = 0,
    current_workspace: u8 = 0,
    is_all_view_active: bool = false,
    workspace_has_windows: []const bool = &.{},
};

/// Render environment shared by every segment's draw call.
pub const Env = struct {
    dc: *drawing.DrawContext,
    config: types.BarConfig,
    height: u16,
};

// -- Width ------------------------------------------------------------------

pub fn naturalWidth(seg: types.BarSegment, frame: *const Frame, clock_width: u16) u16 {
    return switch (seg) {
        .workspaces => if (build_options.has_seg_tags and frame.workspace_count > 0)
            @intCast(frame.workspace_count * tags.getCachedWorkspaceWidth())
        else if (build_options.has_seg_tags)
            tags.fallback_width
        else
            0,
        .layout, .variants => layout_seg.natural_width,
        .title => title.min_width,
        .clock => clock_width,
    };
}

// -- Draw ---------------------------------------------------------------------

/// Draws `seg` at `x`. Returns the new x ("drew nothing" is signalled by
/// returning x unchanged, per drawRowSegment).
pub fn draw(
    seg: types.BarSegment,
    env: Env,
    x: u16,
    frame: *const Frame,
) !u16 {
    switch (seg) {
        .workspaces => return try tags.draw(env.dc, env.config, env.height, x, frame.current_workspace, frame.workspace_has_windows, frame.is_all_view_active),
        .layout => return try layout_seg.draw(env.dc, env.config, env.height, x),
        .variants => return try variants.draw(env.dc, env.config, env.height, x),
        .clock => return try clock.draw(env.dc, env.config, env.height, x),
        // Title is handled by bar.zig's adapter: it needs the bar's mutable
        // scratch and doesn't fit the normal width/draw/click contracts.
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
            if (!build_options.has_seg_tags) return false;
            const idx = resolveWorkspaceClick(offset) orelse return true;
            if (left) {
                actions.switchTo(@intCast(idx));
            } else if (right) {
                const win = focus.getFocused() orelse return true;
                actions.moveWindowTo(win, @intCast(idx));
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
            actions.cycleLayoutKind(if (left) 1 else -1);
            redraw();
            return true;
        },
        .variants => {
            actions.stepVariantDir(if (left) 1 else -1);
            redraw();
            return true;
        },
        .clock => return false,
    }
}

fn resolveWorkspaceClick(offset: u16) ?usize {
    if (!build_options.has_seg_tags) return null;
    const cell_w = tags.getCachedWorkspaceWidth();
    if (cell_w == 0) return null;
    if (!build_options.has_workspaces) return null;
    const ws_state = @import("workspaces").getState() orelse return null;
    const idx: usize = @intCast(offset / cell_w);
    if (idx >= ws_state.workspaces.len) return null;
    return idx;
}
