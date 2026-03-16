//! Layout variation indicator bar segment.
//!
//! Displays the 3-character variation indicator for the active tiling layout.
//! Can be placed independently from the layout icon in the bar layout config.

const core    = @import("core");
const drawing = @import("drawing");
const has_tiling = @import("build_options").has_tiling;
const tiling = if (has_tiling) @import("tiling") else struct {
    pub const State = struct {
        layout: enum { master, monocle, grid, fibonacci } = .master,
        layout_variations: struct {
            master:  enum { lifo, fifo }          = .lifo,
            monocle: enum { gapless, gaps }        = .gapless,
            grid:    enum { rigid, relaxed }       = .rigid,
        } = .{},
        fibonacci_indicator: [3]u8 = .{ '-', '-', '-' },
    };
    pub fn getStateOpt() ?*State { return null; }
};

pub fn getIndicator(s: *const tiling.State) []const u8 {
    return switch (s.layout) {
        .master => switch (s.layout_variations.master) {
            .lifo => "[N]",
            .fifo => "=N=",
        },
        .monocle => switch (s.layout_variations.monocle) {
            .gapless => "<->",
            .gaps    => ">-<",
        },
        .grid => switch (s.layout_variations.grid) {
            .rigid   => "[#]",
            .relaxed => "[~]",
        },
        .fibonacci => &s.fibonacci_indicator,
    };
}

pub fn draw(dc: *drawing.DrawContext, config: core.BarConfig, height: u16, start_x: u16) !u16 {
    const t_state = tiling.getStateOpt() orelse return start_x;
    const indicator = getIndicator(t_state);
    return dc.drawSegment(start_x, height, indicator, config.scaledSegmentPadding(height), config.bg, config.fg);
}
