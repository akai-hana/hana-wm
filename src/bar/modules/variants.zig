//! Layout variants bar module.
//! Renders the active tiling layout variant as a short text string in the bar.

const types = @import("types");
const drawing = @import("drawing");
const pipeline = @import("pipeline");
const actions = @import("actions");
const segmod = @import("segment");
const segdraw = @import("segdraw");

// Layout registry (build-generated); each module carries its own variant
// indicator list. Empty when the tiling subsystem is absent.
const tiling_mods = @import("plugin").tiling_mods;

const W = segdraw.widthState("variants");

/// Resolves the active layout's variant indicator from metadata, by the
/// current workspace's variant_idx.
fn getIndicator() []const u8 {
    const kind = segmod.currentLayoutKind() orelse return "";
    const mod = tiling_mods[kind];
    const inds = mod.indicators orelse return "";
    const idx = pipeline.model().ws[pipeline.model().current].params.variant_idx;
    if (idx >= inds.len) return "";
    return inds[idx];
}

/// Returns the updated x position after drawing the segment, or the original
/// start_x when tiling is disabled or no indicator is available.
fn draw(dc: *drawing.DrawContext, config: types.BarConfig, height: u16, start_x: u16) !u16 {
    const indicator = getIndicator();
    var end_x = start_x;
    if (indicator.len != 0) {
        end_x = try dc.drawSegment(
            start_x,
            height,
            indicator,
            config.scaledSegmentPadding(height),
            config.bg,
            config.fg,
        );
    }
    W.store(end_x - start_x);
    return end_x;
}

pub const module = segdraw.module("variants", draw, actions.stepVariantDir, true);