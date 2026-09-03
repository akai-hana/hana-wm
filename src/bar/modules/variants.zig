//! Layout variants bar module.
//! Renders the active tiling layout variant as a short text string in the bar.

const core = @import("core");
const types = @import("types");
const drawing = @import("drawing");
const pipeline = @import("pipeline");
const actions = @import("actions");
const build_options = @import("build_options");
const segmod = @import("segment");

// Layout registry (build-generated); each module carries its own variant
// indicator list. Empty when the tiling subsystem is absent.
const tiling_mods = @import("plugin").tiling_mods;

// Last-measured drawn width, read by segment.naturalWidth for the row
// reservation (see the matching note in layout.zig). 0 when the segment
// rendered nothing (tiling disabled, or the active layout has no variants),
// so the non-dirty advance path leaves no phantom 60px hole on those
// layouts.
var cached_width: u16 = 0;

// Set when draw() collapses the segment to zero width (active layout has no
// variants), so the bar re-measures the row the same batch. Without this the
// reservation only shrinks on the next unrelated redraw, leaving a
// background-colored gap where the indicator used to be until then. Consumed
// (read + cleared) by `consumeRedrawRequest`, mirroring the prompt module to
// avoid a circular import between variants <-> bar.
var redraw_pending: bool = false;

pub fn getCachedWidth() u16 {
    return cached_width;
}

/// Drops the measured width; next draw() re-measures (config reload path).
pub fn invalidate() void {
    cached_width = 0;
}

/// Returns true and clears the flag if a variant-collapse redraw is
/// outstanding. Call once per event-loop iteration from `bar.updateIfDirty`.
pub fn consumeRedrawRequest() bool {
    const pending = redraw_pending;
    redraw_pending = false;
    return pending;
}

/// Resolves the active layout's variant indicator from metadata, by the
/// current workspace's variant_idx.
fn getIndicator() []const u8 {
    if (!core.getState().config.tiling.enabled) return "";
    if (!build_options.has_tiling) return "";
    const kind = pipeline.getCurrentLayout();
    if (kind >= tiling_mods.len) return "";
    const mod = tiling_mods[kind];
    const inds = mod.indicators orelse return "";
    const idx = pipeline.model().ws[pipeline.model().current].params.variant_idx;
    if (idx >= inds.len) return "";
    return inds[idx];
}

/// Returns the updated x position after drawing the segment, or the original
/// start_x when tiling is disabled or no indicator is available.
pub fn draw(dc: *drawing.DrawContext, config: types.BarConfig, height: u16, start_x: u16) !u16 {
    const indicator = getIndicator();
    var end_x = start_x;
    if (indicator.len != 0) {
        end_x = try dc.drawSegment(start_x, height, indicator, config.scaledSegmentPadding(height), config.bg, config.fg);
    }
    const new_width = end_x - start_x;
    // The row is laid out with the PREVIOUS frame's reservation; if this draw
    // changed the reserved width (collapse to zero on a no-variant layout, or
    // reappear on a layout that has variants again), request an immediate
    // re-lay. Otherwise the neighbouring segments keep sitting on the stale
    // offset (a gap on collapse, an overlap on reappear) until some unrelated
    // update triggers a redraw.
    if (new_width != cached_width) redraw_pending = true;
    cached_width = new_width;
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
    actions.stepVariantDir(if (left) 1 else -1);
    redraw();
    return true;
}

pub const module: @import("plugin").Segment = .{
    .name = "variants",
    .invalidate = invalidate,
    .naturalWidth = naturalWidthHook,
    .consumeRedrawRequest = consumeRedrawRequest,
    .draw = drawHook,
    .onClick = onClickHook,
};
