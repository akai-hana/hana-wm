//! Layout variants bar module.
//! Renders the active tiling layout variant as a short text string in the bar.

const types = @import("types");
const drawing = @import("drawing");
const pipeline = @import("pipeline");
const actions = @import("actions");
const contract = @import("contract");
const core = @import("core");
const scaffold = @import("scaffold");

// Layout registry (build-generated); the active layout is a `u8` index into
// it, and each module carries its own variant indicator list. Empty when the
// tiling subsystem is absent.

// No `tiling_mods` local: the variants module resolves its metadata through
// contract.activeLayoutMeta, so it never names the tiling registry at all.

/// Empty-indicator sentinel: a layout with no variant indicator reserves no
/// row width (the segment draws nothing and contributes a 0-width slot).
const no_variant_icon = "";

/// Resolves the active layout's variant indicator from metadata, by the
/// current workspace's variant_idx. The live kind comes from the model
/// (pipeline); the contract's pure `activeLayoutKind` applies the
/// registry/tiling gates for both this module and its layout sibling.
fn getIndicator() []const u8 {
    return contract.activeLayoutMeta(
        pipeline.getCurrentLayout(),
        core.tilingEnabled(),
        struct {
            /// The indicator is the ACTIVE VARIANT's entry, so the variant
            /// lookup happens here (inside the pick, which owns the registry
            /// module) rather than in the shared helper: the layout segment
            /// has no variant dimension, and this is the only place that does.
            fn pick(m: contract.Layout) ?[]const u8 {
                const inds = m.indicators orelse return null;
                const idx = pipeline.getCurrentVariantIdx();
                if (idx >= inds.len) return null;
                return inds[idx];
            }
        }.pick,
        no_variant_icon,
    );
}

/// Paints the variant indicator, or nothing at all when tiling is disabled or
/// no indicator is available -- a successful zero-width draw, which is not the
/// same thing as a failed one (see contract.Painted).
fn draw(dc: *drawing.DrawContext, config: types.BarConfig, height: u16, start_x: u16) !contract.Painted {
    return scaffold.drawAndStore("variants", dc, config, height, start_x, getIndicator());
}

pub const module = scaffold.module("variants", draw, actions.stepVariantDir, .{ .mode = .measured_relayout });
