//! Process lifecycle signals — running flag and config-reload request.
//!
//! These are module-level atomics rather than WM struct fields because they
//! are process control state, not window-manager state.  Keeping them here
//! removes two pointer indirections from every consumer and makes the
//! dependency explicit: signal handlers and keybind actions write here;
//! the main event loop reads here.

const std = @import("std");

/// Set to false by SIGTERM / SIGINT to break the main event loop.
pub var running = std.atomic.Value(bool).init(true);

/// Set to true by SIGHUP or the reload_config keybinding; consumed (swapped
/// to false) by maybeReload in the main event loop.
pub var should_reload = std.atomic.Value(bool).init(false);

pub inline fn quit() void {
    running.store(false, .release);
}

pub inline fn reload() void {
    should_reload.store(true, .release);
}

/// Atomically consume the reload flag.  Returns true exactly once per
/// request — whichever call path checks first wins; the second is a no-op.
pub inline fn consumeReload() bool {
    return should_reload.swap(false, .acq_rel);
}
