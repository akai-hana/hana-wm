//! Layout icon bar segment.
//! Displays the active tiling layout symbol on the status bar.

const types = @import("types");
const drawing = @import("drawing");
const actions = @import("actions");
const pipeline = @import("pipeline");
const contract = @import("contract");
const segdraw = @import("segdraw");

// Layout registry (build-generated); the active layout is a `u8` index into
// it, and each module carries its own bar icon metadata. Empty (and
// unreachable: the icon falls back to "><>") when the tiling subsystem is
// absent.
const tiling_mods = contract.tiling_mods;

const W = segdraw.widthState("layout");

/// Fallback glyph when no tiling layout is resolvable (tiling disabled or the
/// tiling subsystem absent: all windows float by definition).
const fallback_icon = "><>";

/// Resolves the active layout's bar icon from metadata; "><>" when tiling is
/// disabled or the tiling subsystem is absent (all windows float by
/// definition). The live kind comes from the model (pipeline); the contract's
/// pure `activeLayoutKind` applies the registry/tiling gates for both this
/// module and its variants sibling.
fn getIcon() []const u8 {
    if (tiling_mods.len == 0) return fallback_icon;
    const kind = contract.activeLayoutKind(pipeline.getCurrentLayout()) orelse return fallback_icon;
    return tiling_mods[kind].icon orelse fallback_icon;
}

fn draw(dc: *drawing.DrawContext, config: types.BarConfig, height: u16, start_x: u16) !u16 {
    const end_x = try drawing.drawPaddedSegment(dc, config, height, start_x, "layout", getIcon(), null, config.segmentProps("layout"));
    W.store(end_x - start_x);
    return end_x;
}

pub const module = segdraw.module("layout", draw, actions.cycleLayoutKind, .{ .with_collapse = false });
