//! Bar-owned derived metrics.
//!
//! `scaled_font_size` depends on the live screen (DPI) and on whether the
//! configured font size is a percentage of the bar height, so it is runtime
//! state rather than config. It lives here, next to its only reader
//! (`drawing.buildSizedFontList`) and writer (`bar.calcBarHeightAndFontSize`),
//! instead of leaking onto `BarConfig` where it looked like user input.
//!
//! `recompute` is called every time the bar resolves its height (boot and
//! reload); percentage font sizes are then refined per bar height by
//! `bar.calcBarHeightAndFontSize`.

const core = @import("core");
const scale = @import("scale");

const default_scaled_font_size: u16 = 10;

var scaled_font_size: u16 = default_scaled_font_size;

pub fn getScaledFontSize() u16 {
    return scaled_font_size;
}

pub fn setScaledFontSize(size: u16) void {
    scaled_font_size = size;
}

/// Sets the DPI-scaled size for a plain (non-percentage) font size. Callers
/// with `font_size.is_percentage` override the result once the bar height is
/// known.
pub fn recompute() void {
    const cs = core.getState();
    scaled_font_size = scale.scaleFontSize(cs.config.bar.font_size, cs.screen);
}
