//! Layout icon bar segment.
//! Displays the active tiling layout symbol on the status bar.

const types = @import("types");
const drawing = @import("drawing");
const actions = @import("actions");
const segmod = @import("segment");
const segdraw = @import("segdraw");

// Layout registry (build-generated); the active layout is a `u8` index into
// it, and each module carries its own bar icon metadata. Empty (and
// unreachable: the icon falls back to "><>") when the tiling subsystem is
// absent.
const tiling_mods = @import("plugin").tiling_mods;

const W = segdraw.widthState("layout");

/// Resolves the active layout's bar icon from metadata; "><>" when tiling is
/// disabled or the tiling subsystem is absent (all windows float by
/// definition).
fn getIcon() []const u8 {
    const kind = segmod.currentLayoutKind() orelse return "><>";
    return tiling_mods[kind].icon orelse "><>";
}

fn draw(dc: *drawing.DrawContext, config: types.BarConfig, height: u16, start_x: u16) !u16 {
    const end_x = try drawing.drawPaddedSegment(dc, config, height, start_x, getIcon());
    W.store(end_x - start_x);
    return end_x;
}

pub const module = segdraw.module("layout", draw, actions.cycleLayoutKind, .{ .with_collapse = false });
