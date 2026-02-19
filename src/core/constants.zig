//! Central location for the constants used across all files.

const defs = @import("defs");
const xcb = defs.xcb;

/// X coordinate for positioning windows off-screen (far left)
pub const OFFSCREEN_X_POSITION: i32 = -4000;

/// Minimum X coordinate threshold for detecting off-screen windows
pub const OFFSCREEN_THRESHOLD_MIN: i32 = -1000;

/// Maximum X coordinate threshold for detecting off-screen windows
pub const OFFSCREEN_THRESHOLD_MAX: i32 = 10000;

/// Event masks for window types
pub const EventMasks = struct {
    /// Event mask for the root window (window manager control)
    pub const ROOT_WINDOW = xcb.XCB_EVENT_MASK_SUBSTRUCTURE_REDIRECT |
                            xcb.XCB_EVENT_MASK_SUBSTRUCTURE_NOTIFY |
                            xcb.XCB_EVENT_MASK_KEY_PRESS |
                            xcb.XCB_EVENT_MASK_BUTTON_PRESS |
                            xcb.XCB_EVENT_MASK_ENTER_WINDOW |
                            xcb.XCB_EVENT_MASK_LEAVE_WINDOW |
                            xcb.XCB_EVENT_MASK_PROPERTY_CHANGE;

    /// Event mask for managed windows (click-to-focus, property changes).
    /// LEAVE_WINDOW is intentionally omitted: handleLeaveNotify only processes
    /// events from root (it returns immediately for all other windows), so
    /// subscribing managed windows to leave events would generate traffic that
    /// is always discarded.
    pub const MANAGED_WINDOW = xcb.XCB_EVENT_MASK_ENTER_WINDOW |
                               xcb.XCB_EVENT_MASK_BUTTON_PRESS |
                               xcb.XCB_EVENT_MASK_STRUCTURE_NOTIFY |
                               xcb.XCB_EVENT_MASK_PROPERTY_CHANGE;
};

/// Lock key combinations grabbed
pub const LOCK_MODIFIERS = [_]u16{ 
    0, 
    defs.MOD_LOCK, 
    defs.MOD_2, // NumLock
    defs.MOD_LOCK | defs.MOD_2 
};

/// X11 Cursor constants (mask glyph is always source + 1 by convention)
pub const CURSOR_LEFT_PTR      = 68;
pub const CURSOR_LEFT_PTR_MASK = CURSOR_LEFT_PTR + 1;

/// Size constants
pub const Sizes = struct {
    /// Dispatch table size (covers all X11 event types)
    pub const EVENT_DISPATCH_TABLE = 36;
    
    /// Pre-allocation capacity for window tracking structures.
    /// Sized for a typical session; structures grow automatically beyond this.
    pub const WINDOW_CAPACITY = 32;
};
