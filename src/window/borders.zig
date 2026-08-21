//! Shared border management helpers.
//!
//! Unifies border color resolution, width calculation, and atomic apply
//! logic that was previously duplicated across tiling.zig, window.zig,
//! and fullscreen.zig.

const core = @import("core");
const xcb = core.xcb;
const utils = @import("utils");
const focus = @import("focus");
const fullscreen = @import("fullscreen");
const build_options = @import("build_options");
const tiling = if (build_options.has_tiling) @import("tiling") else null;

/// Returns the border color for `win`: 0 for fullscreen windows,
/// focused or unfocused color otherwise.
pub inline fn color(win: u32) u32 {
    if (fullscreen.isFullscreen(win)) return 0;
    const cfg = &core.getState().config.tiling;
    return if (focus.getFocused() == win) cfg.border_focused else cfg.border_unfocused;
}

/// Returns the effective border width for tiled windows. Falls back to
/// the scaled config value when tiling is disabled or not compiled in.
pub inline fn width() u16 {
    const bw: u16 = if (build_options.has_tiling) tiling.getBorderWidth() else 0;
    if (bw != 0) return bw;
    const cs = core.getState();
    return utils.scaling.scaleBorderWidth(
        cs.config.tiling.border_width,
        cs.screen.height_in_pixels,
    );
}

/// Applies the configured border width to `win`, skipping the configure
/// when the cache shows that exact width is already applied.
pub inline fn applyWidth(conn: core.Connection, win: u32) void {
    const w = width();
    if (w == 0) return;
    if (build_options.has_tiling and tiling.cacheBorderWidth(win, w)) return;
    _ = xcb.xcb_configure_window(conn, win, xcb.XCB_CONFIG_WINDOW_BORDER_WIDTH, &[_]u32{w});
}

/// Applies both border width and color to `win`. Color goes through the
/// layout-cache dedup so repeated sweeps don't spam ChangeWindowAttributes;
/// that dedup always records the sent/verified color, keeping the cache
/// truthful across forced values applied outside it (fullscreen's pixel 0)
/// so the next real color change is never stale-skipped. When tiling state
/// is unavailable, the send is unconditional.
pub inline fn apply(conn: core.Connection, win: u32) void {
    applyWidth(conn, win);
    const c = color(win);
    if (build_options.has_tiling) {
        if (tiling.sendBorderColorIfChanged(win, c)) return;
    }
    utils.setBorderPixel(conn, win, c);
}
