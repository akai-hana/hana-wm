//! Layout icon bar segment.
//! Displays the active tiling layout symbol on the status bar.

const bar_config = @import("bar_config");
const drawing = @import("drawing");
const window = @import("window");
const pipeline = @import("pipeline");
const layout = @import("layout_provider").provider;
const bar_contract = @import("bar_contract");
const segmod = @import("segment");

// The active layout's bar metadata comes from the generic provider status, so
// this segment names no tiling type and needs no registry local.

/// Fallback glyph when no layout provider is active (no layout subsystem
/// present: all windows float by definition).
const fallback_icon = "><>";

/// Resolves the active layout's bar icon from the provider status; "><>" when
/// no provider is active.
fn getIcon() []const u8 {
    const st = layout.status(pipeline.getCurrentLayout());
    return st.icon orelse fallback_icon;
}

fn draw(dc: *drawing.DrawContext, config: *const bar_config.Config, height: u16, start_x: u16) !bar_contract.Painted {
    return segmod.drawAndStore("layout", dc, config, height, start_x, getIcon());
}

pub const module = segmod.module("layout", draw, window.cycleLayoutKind, .{ .mode = .measured_no_relayout });
