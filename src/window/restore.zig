//! Session adoption: the re-exec-only path where a successor window manager
//! takes over the X clients a predecessor left behind.
//!
//! hana never reparents, so clients stay direct root children across an execv
//! and the successor can adopt them by scanning the root's children. main calls
//! adoptSession exactly once -- after surfaces.init() (bar up so bar-aware work
//! area is live) and before events.run() -- sequencing persist, window adoption,
//! and focus against each other. Pure subsystem ordering; no X requests, config,
//! or dispatch of its own.

const std = @import("std");
const core = @import("core");
const log = @import("log");
const persist = @import("persist");
const pipeline = @import("pipeline");
const window = @import("window");
const actions = @import("actions");

/// Adopt the session described by `restore_path`, if there is one to adopt.
///
/// Called after the bar is up, so the bar-aware work area is already live and
/// the single reconcile that follows places windows against the same geometry a
/// normal boot would use. A missing or unreadable restore file is not an
/// error: that is an ordinary first boot.
pub fn adoptSession(restore_path: []const u8) void {
    if (!persist.loadToGlobal(core.getState().alloc, restore_path)) return;

    const n = window.adoptRootWindows() catch |err| blk: {
        log.err("Window adoption failed: {}", .{err});
        break :blk 0;
    };
    // Nothing adopted: the file named windows the server no longer has, and
    // there is no level to re-apply and nothing to focus.
    if (n == 0) return;

    actions.applyRestoredLevel();
    actions.focusAfterGeometry();
}
