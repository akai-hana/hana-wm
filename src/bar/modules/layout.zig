//! Layout icon bar segment.
//! Displays the active tiling layout symbol on the status bar.

const core = @import("core");
const types = @import("types");
const drawing = @import("drawing");
const pipeline = @import("pipeline");
const actions = @import("actions");
const build_options = @import("build_options");
const segmod = @import("segment");

// Layout registry (build-generated); the active layout is a `u8` index into
// it, and each module carries its own bar icon metadata. Empty (and
// unreachable: the icon falls back to "><>") when the tiling subsystem is
// absent.
const tiling_mods = @import("plugin").tiling_mods;

// Reserved row width (moved here from bar.zig: width policy belongs to
// the segment that owns the pixels).
//
// This is the ACTUAL drawn width from the last render, not a constant:
// bar.zig advances x by the reserved width on non-dirty frames, so any
// mismatch between the reservation and what was really painted makes every
// downstream segment (title included) jump on partial redraws. The icon
// renders at its measured text width once per frame, so caching that number
// here keeps reserved == painted and the row layout stable.
var cached_width: u16 = 0;

/// Last-measured drawn width, read by segment.naturalWidth for the row
/// reservation (0 until the first draw).
pub fn getCachedWidth() u16 {
    return cached_width;
}

/// Drops the measured width; next draw() re-measures (config reload path).
pub fn invalidate() void {
    cached_width = 0;
}

/// Resolves the active layout's bar icon from metadata; "><>" when tiling is
/// disabled or the tiling subsystem is absent (all windows float by
/// definition).
fn getIcon() []const u8 {
    if (!core.getState().config.tiling.enabled) return "><>";
    if (!build_options.has_tiling) return "><>";
    const kind = pipeline.getCurrentLayout();
    if (kind < tiling_mods.len) {
        if (tiling_mods[kind].icon) |ic| return ic;
    }
    return "><>";
}

/// Returns the x coordinate immediately after the drawn segment.
pub fn draw(dc: *drawing.DrawContext, config: types.BarConfig, height: u16, start_x: u16) !u16 {
    const icon = getIcon();
    const end_x = try dc.drawSegment(start_x, height, icon, config.scaledSegmentPadding(height), config.bg, config.fg);
    cached_width = end_x - start_x;
    return end_x;
}

/// This module's bar-segment contribution (registry binding).
fn naturalWidthHook(_: *const anyopaque, _: u16) u16 {
    return getCachedWidth();
}

fn drawHook(ctx: *anyopaque, x: u16) !u16 {
    const c = segmod.castDraw(ctx);
    return draw(c.dc, c.config, c.height, x);
}

fn onClickHook(_: u16, left: bool, _: bool, _: *anyopaque, _: *const fn (*anyopaque, u16) void, redraw: *const fn () void) bool {
    actions.cycleLayoutKind(if (left) 1 else -1);
    redraw();
    return true;
}

pub const module: @import("plugin").Segment = .{
    .name = "layout",
    .invalidate = invalidate,
    .naturalWidth = naturalWidthHook,
    .draw = drawHook,
    .onClick = onClickHook,
};
