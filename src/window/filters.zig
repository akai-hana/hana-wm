//! Window Filtering Module
//!
//! Provides unified filtering and validation functions for windows.
//! Eliminates duplicate validation logic across window.zig and tiling.zig.

const defs       = @import("defs");
const bar        = @import("bar");
const workspaces = @import("workspaces");

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

