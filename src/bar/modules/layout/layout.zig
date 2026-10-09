//! Layout icon bar segment.
//! Displays the active tiling layout symbol on the status bar.

const types = @import("types");
const drawing = @import("drawing");
const actions = @import("actions");
const pipeline = @import("pipeline");
const contract = @import("contract");
const core = @import("core");
const segmod = @import("segment");

// Layout registry (build-generated); the active layout is a `u8` index into
// it, and each module carries its own bar icon metadata. Empty (and
// unreachable: the icon falls back to "><>") when the tiling subsystem is
// absent.

// No `tiling_mods` local: the layout module resolves its metadata through
// contract.activeLayoutMeta, so it never names the tiling registry at all.

/// Fallback glyph when no tiling layout is resolvable (tiling disabled or the
/// tiling subsystem absent: all windows float by definition).
const fallback_icon = "><>";

/// Resolves the active layout's bar icon from metadata; "><>" when tiling is
/// disabled or the tiling subsystem is absent (all windows float by
/// definition). The live kind comes from the model (pipeline); the contract's
/// pure `activeLayoutKind` applies the registry/tiling gates for both this
/// module and its variants sibling.
fn getIcon() []const u8 {
    return contract.activeLayoutMeta(
        pipeline.getCurrentLayout(),
        core.tilingEnabled(),
        struct {
            fn pick(m: contract.Layout) ?[]const u8 {
                return m.icon;
            }
        }.pick,
        fallback_icon,
    );
}

fn draw(dc: *drawing.DrawContext, config: types.BarConfig, height: u16, start_x: u16) !contract.Painted {
    return segmod.drawAndStore("layout", dc, config, height, start_x, getIcon());
}

pub const module = segmod.module("layout", draw, actions.cycleLayoutKind, .{ .mode = .measured_no_relayout });
