//! WM-wide state diagnostics: on-demand, read-only log snapshots used by the
//! dump-state command. Lives on the core side of the facade so the window
//! facade keeps rendering/protocol concerns only.

const std = @import("std");
const core = @import("core");
const log = std.log.scoped(.diagnostic);
const query = @import("query");
const focus = @import("focus");
const build_options = @import("build_options");
const pipeline = @import("pipeline");
const model = @import("model");
// Layout-name resolution for the state dump, via the build-generated seam.
const tiling = @import("tiling_seam").tiling;

/// WM-wide state dump diagnostic: logs a live snapshot of model and subsystem
/// state on demand (read-only); used by the dump-state command.
pub fn dumpState() void {
    // A stack array is the right owner here (no State to hang it off), and it
    // keeps `query` free of module-level scratch.
    var scratch: [model.store_capacity]query.Entry = undefined;
    const all = query.allWindowsInto(&scratch);

    log.info("========== STATE DUMP ==========", .{});
    log.info("Focused:        {?x}", .{focus.getFocused()});
    log.info("Total windows:  {}", .{all.len});
    log.info("Suppress focus: {s}", .{@tagName(focus.getSuppressReason())});

    if (build_options.has_workspaces) {
        const ws_count = query.getWorkspaceCount();
        for (0..ws_count) |i| {
            var n: usize = 0;
            for (all) |e| {
                if (model.maskedOn(e.mask, model.WSId.fromIndex(i))) n += 1;
            }
            log.info(
                "  WS{}: {} windows",
                .{ i + 1, n },
            );
        }
    }

    if (build_options.has_tiling and core.tilingEnabled()) {
        const m = pipeline.state();
        log.info("Tiling enabled: true", .{});
        log.info("Tiling layout:  {s}", .{tiling.moduleName(pipeline.getCurrentLayout())});
        log.info("Tiled windows:  {}", .{model.tiledCountOnWs(m, m.current)});
    }

    log.info("================================", .{});
}
