//! Window Filtering Module
//!
//! Provides unified filtering and validation functions for windows.
//! Eliminates duplicate validation logic across window.zig and tiling.zig.

const std = @import("std");
const defs = @import("defs");
const bar = @import("bar");
const workspaces = @import("workspaces");

/// Check if a window is a system window (root, null, or bar)
/// System windows should not be managed or receive focus
pub inline fn isSystemWindow(wm: *defs.WM, win: u32) bool {
    return win == wm.root or win == 0 or bar.isBarWindow(win);
}

/// Check if a window is valid and tracked by the window manager
/// This is the core validation for any window operation
pub inline fn isValidManagedWindow(wm: *defs.WM, win: u32) bool {
    return win != 0 and 
           win != wm.root and 
           !bar.isBarWindow(win) and
           wm.hasWindow(win);
}

/// Check if a window is on the current workspace
/// Combines managed window check with workspace check
pub inline fn isOnCurrentWorkspace(wm: *defs.WM, win: u32) bool {
    return isValidManagedWindow(wm, win) and 
           workspaces.isOnCurrentWorkspace(win);
}

/// Collect all windows from a list that are on the current workspace
/// This is a common operation in tiling and focus management
pub fn collectCurrentWorkspaceWindows(
    wm: *defs.WM,
    all_windows: []const u32,
    out_buffer: []u32,
) usize {
    var count: usize = 0;
    for (all_windows) |win| {
        if (count >= out_buffer.len) break;
        if (isOnCurrentWorkspace(wm, win)) {
            out_buffer[count] = win;
            count += 1;
        }
    }
    return count;
}
