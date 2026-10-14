//! WM-wide state dump diagnostic: logs a live snapshot of model and subsystem
//! state on demand (read-only); used by the dump-state action.

const std = @import("std");
const core = @import("core");
const log = @import("log");
const model = @import("model");
const tracking = @import("tracking");
const focus = @import("focus");
const pipeline = @import("pipeline");
const build_options = @import("build_options");
// Layout-name resolution for diagnostics; via the build-generated tiling_seam.
const tiling = @import("tiling_seam").tiling;

pub fn dumpState() void {
    // A stack array is the right owner here (no State to hang it off), and it
    // keeps `tracking` free of module-level scratch.
    var scratch: [model.store_capacity]tracking.Entry = undefined;
    const all = tracking.allWindowsInto(&scratch);

    log.info("========== STATE DUMP ==========", .{});
    log.info("Focused:        {?x}", .{focus.getFocused()});
    log.info("Total windows:  {}", .{all.len});
    log.info("Suppress focus: {s}", .{@tagName(focus.getSuppressReason())});

    if (build_options.has_workspaces) {
        const ws_count = tracking.getWorkspaceCount();
        for (0..ws_count) |i| {
            var n: usize = 0;
            for (all) |e| {
                if (model.maskedOn(e.mask, core.WorkspaceId.fromIndex(i))) n += 1;
            }
            log.info(
                "  WS{}: {} windows",
                .{ i + 1, n },
            );
        }
    }

    if (build_options.has_tiling and core.tilingEnabled()) {
        const m = pipeline.model();
        log.info("Tiling enabled: true", .{});
        log.info("Tiling layout:  {s}", .{tiling.moduleName(pipeline.getCurrentLayout())});
        log.info("Tiled windows:  {}", .{model.tiledCountOnWs(m, m.current)});
    }

    log.info("================================", .{});
}
