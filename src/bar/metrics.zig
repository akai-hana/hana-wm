//! Bar font-metric / height resolution (D2 decomposition of bar.zig).
//!
//! Owns everything needed to decide the bar's pixel height and effective
//! font size from config + font metrics, including the percentage-font-size
//! probe. No window ownership; pure measurement plus the documented
//! config write in calcBarHeightAndFontSize (scaled_font_size is runtime
//! state that happens to live on BarConfig).

const std = @import("std");

const core = @import("core");
const scale = @import("scale");
const debug = @import("debug");

const drawing = @import("drawing");

pub const min_bar_height: u32 = scale.bar_min_height_px;
pub const max_bar_height: u32 = 200;
pub const default_bar_height: u32 = 24;

/// D9: `size_override` lets callers probe metrics at a trial size WITHOUT
/// mutating the live config (the old save/mutate/restore hack). Null uses
/// the configured scaled size.
pub fn loadBarFonts(dc: anytype, size_override: ?u16) !void {
    const cs = core.getState();
    const font_size: u16 = size_override orelse cs.config.bar.scaled_font_size;
    const fonts = cs.config.bar.fonts.items;
    if (fonts.len == 0) return;
    const sized = try cs.alloc.alloc([]const u8, fonts.len);
    defer {
        for (sized, fonts) |s, orig| if (s.ptr != orig.ptr) cs.alloc.free(s);
        cs.alloc.free(sized);
    }
    for (fonts, sized) |f, *out| {
        out.* = if (font_size > 0)
            try std.fmt.allocPrint(cs.alloc, "{s}:size={}", .{ f, font_size })
        else
            f;
    }
    try dc.font.loadFonts(sized);
    if (sized.len > 1) debug.info("Loaded {} fonts with fallback support", .{sized.len});
}

pub fn measureFontMetrics() ?struct { asc: i32, desc: i32 } {
    var mc = drawing.MeasureContext.init(core.getState().alloc, core.dpi_info.load(.acquire)) catch return null;
    defer mc.deinit();
    loadBarFonts(&mc, null) catch return null;
    const asc, const desc = mc.font.getMetrics();
    return .{ .asc = asc, .desc = desc };
}

fn resolvePercentageFontSize(bar_height: u16) ?u16 {
    // D9: probe metrics at a trial point size via the override parameter —
    // no save/mutate/restore round on cs.config.
    const trial_pt: u16 = 100;
    var mc = drawing.MeasureContext.init(core.getState().alloc, core.dpi_info.load(.acquire)) catch return null;
    defer mc.deinit();
    loadBarFonts(&mc, trial_pt) catch return null;
    const asc, const desc = mc.font.getMetrics();
    const px_per_pt: f32 = @as(f32, @floatFromInt(@max(1, asc + desc))) / @as(f32, @floatFromInt(trial_pt));
    const max_size_pt = @as(f32, @floatFromInt(bar_height)) / px_per_pt;
    const cfg_pct = core.getState().config.bar.font_size.value / 100.0;
    return @max(1, @as(u16, @intFromFloat(@round(max_size_pt * cfg_pct))));
}

pub fn calcBarHeightAndFontSize() !u16 {
    const cs = core.getState();
    if (cs.config.bar.height) |h| {
        const height = scale.scaleBarHeight(h, cs.screen.height_in_pixels);
        if (cs.config.bar.font_size.is_percentage) {
            if (resolvePercentageFontSize(height)) |sz|
                cs.config.bar.scaled_font_size = sz;
        }
        return height;
    }
    const m = measureFontMetrics() orelse return default_bar_height;
    return @intCast(std.math.clamp(@as(u32, @intCast(m.asc + m.desc)), min_bar_height, max_bar_height));
}
