//! Layout variants bar module.
//! Renders the active tiling layout variant as a short text string in the bar.

const bar_config = @import("bar_config");
const drawing = @import("drawing");
const pipeline = @import("pipeline");
const window = @import("window");
const layout = @import("layout_provider").provider;
const bar_contract = @import("bar_contract");
const segmod = @import("segment");

// The active layout's variant metadata comes from the generic provider status,
// so this segment names no tiling type and needs no registry local.

/// Empty-indicator sentinel: a layout with no variant indicator reserves no
/// row width (the segment draws nothing and contributes a 0-width slot).
const no_variant_icon = "";

/// Resolves the active layout's variant indicator from the provider status, by
/// the current workspace's variant_idx.
fn getIndicator() []const u8 {
    const st = layout.status(pipeline.getCurrentLayout());
    const inds = st.variant_indicators orelse return no_variant_icon;
    const idx = pipeline.getCurrentVariantIdx();
    if (idx >= inds.len) return no_variant_icon;
    return inds[idx];
}

/// Paints the variant indicator, or nothing at all when tiling is disabled or
/// no indicator is available -- a successful zero-width draw, which is not the
/// same thing as a failed one (see bar_contract.Painted).
fn draw(dc: *drawing.DrawContext, config: *const bar_config.Config, height: u16, start_x: u16) !bar_contract.Painted {
    return segmod.drawAndStore("variants", dc, config, height, start_x, getIndicator());
}

pub const module = segmod.module("variants", draw, window.stepVariantDir, .{ .mode = .measured_relayout });
