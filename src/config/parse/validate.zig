//! Config semantic validation: the domain invariants a freshly loaded
//! Config must hold. Pure by construction -- no IO, no allocation, no
//! document access -- so every layer above config may call it and it is
//! trivially testable without a filesystem.

const constants = @import("constants");
const log = @import("log");
const scaling = @import("scaling");
const types = @import("types");

/// Validates domain invariants on a freshly loaded config.
fn invalid(comptime fmt: []const u8, args: anytype) error{InvalidConfig} {
    log.err("Invalid config: " ++ fmt ++ ", keeping old", args);
    return error.InvalidConfig;
}

pub fn validate(cfg: *const types.Config) !void {
    // master_width is a ScalableValue: percentages validate as a
    // [min_master_width, max_master_width] ratio; pixels only as >= 0, since
    // the screen width for a ratio isn't available here and the runtime clamps:
    // a pixel-vs-ratio check would wrongly refuse `master_width = 600`.
    const mw = cfg.tiling.master_width;
    if (mw.is_percentage) {
        const mw_ratio: f32 = scaling.asRatio(mw);
        if (mw_ratio < constants.min_master_width or mw_ratio > constants.max_master_width)
            return invalid("master_width {d:.0}% out of [{d:.0}%, {d:.0}%]", .{
                mw_ratio * 100.0,
                constants.min_master_width * 100.0,
                constants.max_master_width * 100.0,
            });
    } else if (mw.value < 0.0) {
        return invalid("master_width {d}px must be >= 0", .{mw.value});
    }
    warnOnly(cfg);
}

/// The warn-first half of validation: values that are legal but almost certainly
/// not what the user meant, or that a subsystem will silently clamp. They must
/// NOT fail the load: a config that boots with a loud warning is recoverable,
/// and a config that refuses to boot over a cosmetic value is not. Every entry
/// here is therefore `log.warn` with no effect on the returned Config.
///
/// Kept separate from the failing checks above on purpose, so the line between
/// "wrong config" and "odd config" is visible in the source rather than implied
/// by whether a given `return invalid(...)` happens to be present.
///
/// NOT here, on purpose: bar segment names and layout names are validated
/// against the `bar_modules` / `tiling_mods` registries, and those live in
/// their own modules -- config is below both in the dependency graph, so
/// importing them to check names would invert it and break the no-bar and
/// no-tiling builds the modularity matrix exists to prove. The name checks
/// therefore sit with their owners (see `bar.warnUnknownSegments` and
/// `tiling`'s registry resolution), which is the only place they can see the
/// registry.
fn warnOnly(cfg: *const types.Config) void {
    if (cfg.workspaces.count == 0)
        log.warn("workspaces.count is 0; the WM will have no workspace to draw", .{});
    if (cfg.tiling.master_count == 0)
        log.warn("tiling.master_count is 0; layouts will fall back to 1 master pane", .{});
    // A percentage font size of 0 (or a negative pixel size) is a typo, not a
    // design: the bar's text metrics then compute a zero or negative height and
    // the bar draws as a bare strip.
    if (cfg.bar.font_size.is_percentage) {
        if (scaling.asRatio(cfg.bar.font_size) <= 0.0)
            log.warn("bar.font_size is 0%; the bar will have no readable text", .{});
    } else if (cfg.bar.font_size.value <= 0.0) {
        log.warn("bar.font_size is {d}px; the bar will have no readable text", .{cfg.bar.font_size.value});
    }
}
