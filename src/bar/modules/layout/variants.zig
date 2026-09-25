//! Layout variants bar module.
//! Renders the active tiling layout variant as a short text string in the bar.

const types = @import("types");
const drawing = @import("drawing");
const pipeline = @import("pipeline");
const actions = @import("actions");
const contract = @import("contract");
const segdraw = @import("segdraw");

// Layout registry (build-generated); the active layout is a `u8` index into
// it, and each module carries its own variant indicator list. Empty when the
// tiling subsystem is absent.
const tiling_mods = contract.tiling_mods;

/// Empty-indicator sentinel: a layout with no variant indicator reserves no
/// row width (the segment draws nothing and contributes a 0-width slot).
const no_variant_icon = "";

/// Resolves the active layout's variant indicator from metadata, by the
/// current workspace's variant_idx. The live kind comes from the model
/// (pipeline); the contract's pure `activeLayoutKind` applies the
/// registry/tiling gates for both this module and its layout sibling.
fn getIndicator() []const u8 {
    if (tiling_mods.len == 0) return no_variant_icon;
    const kind = contract.activeLayoutKind(pipeline.getCurrentLayout()) orelse return no_variant_icon;
    const mod = tiling_mods[kind];
    const inds = mod.indicators orelse return no_variant_icon;
    const m = pipeline.model();
    const idx = m.ws[m.current.index].params.variant_idx;
    if (idx >= inds.len) return no_variant_icon;
    return inds[idx];
}

/// Returns the updated x position after drawing the segment, or the original
/// start_x when tiling is disabled or no indicator is available (a 0-width
/// reservation, per drawAndStore's empty-text path).
fn draw(dc: *drawing.DrawContext, config: types.BarConfig, height: u16, start_x: u16) !u16 {
    return segdraw.drawAndStore("variants", dc, config, height, start_x, getIndicator());
}

pub const module = segdraw.module("variants", draw, actions.stepVariantDir, .{ .with_collapse = true });
