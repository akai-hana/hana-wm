//! Central location for core constants used across multiple files.

const xcb = @cImport(@cInclude("xcb/xcb.h"));

// Modifier masks
// Must be u16 as per XCB API
pub const MOD_SHIFT:    u16 = xcb.XCB_MOD_MASK_SHIFT;
pub const MOD_CAPSLOCK: u16 = xcb.XCB_MOD_MASK_LOCK;
pub const MOD_CONTROL:  u16 = xcb.XCB_MOD_MASK_CONTROL;
pub const MOD_ALT:      u16 = xcb.XCB_MOD_MASK_1;
pub const MOD_NUMLOCK:  u16 = xcb.XCB_MOD_MASK_2;
pub const MOD_SUPER:    u16 = xcb.XCB_MOD_MASK_4;

// Mask applied before comparing a received modifier state against a keybinding.
// Excludes CapsLock and NumLock so bindings fire regardless of lock-key state;
// those are handled separately via LOCK_MODIFIERS grabs.
pub const MOD_MASK_BINDING: u16 = MOD_SHIFT | MOD_CONTROL | MOD_ALT | MOD_SUPER;

// Window constraints
pub const MIN_WINDOW_DIM:   u16 = 50;
pub const MIN_MASTER_WIDTH: f32 = 0.05;

// XKB retry parameters
// 20 ms is short enough to be imperceptible to the user yet long enough to avoid
// busy-spinning while the XKB extension finishes initialising (~1 polling cycle
// at 50 Hz).
pub const XKB_RETRY_DELAY_MS: u64 = 20;

// Offscreen positioning
// Windows on inactive workspaces are parked at OFFSCREEN_X_POSITION so they
// are hidden without being unmapped (unmapping causes some apps to pause).
// -4000 clears the widest common display in use today (4K = 3840 px wide) with
// a small margin; increase if ultra-wide support beyond 4000 px is ever needed.
pub const OFFSCREEN_X_POSITION: i32 = -4000;

/// Lower bound for detecting whether a window is parked offscreen.
/// A fixed upper bound is intentionally absent: multi-monitor desktops can
/// exceed 10 000 px, so only the sentinel minimum is safe to check against.
pub const OFFSCREEN_SENTINEL_MIN: i32 = -1000;

/// Maximum depth when walking the X11 window tree in findManagedWindow.
pub const MAX_WINDOW_TREE_DEPTH: usize = 10;

// XCB property helpers
/// Maximum number of 32-bit words to request when fetching an XCB window property.
/// 256 words = 1 KiB, sufficient for all fixed-size properties the WM reads.
pub const PROPERTY_MAX_LENGTH: u32 = 256;
/// Value for the `delete` argument to xcb_get_property that leaves the property intact.
pub const PROPERTY_NO_DELETE: u8 = 0;

// DPI / scaling
/// Standard DPI for a 1× display. All scale factors are computed relative to this value.
pub const BASELINE_DPI: f32 = 96.0;

// Event masks
pub const EventMasks = struct {
    // DWM verbatim (setup() in dwm.c):
    //   wa.event_mask = SubstructureRedirectMask|SubstructureNotifyMask
    //       |ButtonPressMask|PointerMotionMask|EnterWindowMask
    //       |LeaveWindowMask|StructureNotifyMask|PropertyChangeMask;
    //   XChangeWindowAttributes(dpy, root, CWEventMask|CWCursor, &wa);
    //   XSelectInput(dpy, root, wa.event_mask);
    // KEY_PRESS is kept (not in DWM's root mask) because our keybinding grabs
    // land on root via xcb_grab_key and the events are dispatched here.
    // POINTER_MOTION_HINT is used instead of plain POINTER_MOTION so the X
    // server coalesces motion events and we re-arm with xcb_query_pointer,
    // matching the drag/suppression logic in input.zig.
    pub const ROOT_WINDOW = xcb.XCB_EVENT_MASK_SUBSTRUCTURE_REDIRECT |
                            xcb.XCB_EVENT_MASK_SUBSTRUCTURE_NOTIFY |
                            xcb.XCB_EVENT_MASK_KEY_PRESS |
                            xcb.XCB_EVENT_MASK_BUTTON_PRESS |
                            xcb.XCB_EVENT_MASK_POINTER_MOTION_HINT | // DWM: PointerMotionMask
                            xcb.XCB_EVENT_MASK_ENTER_WINDOW |
                            xcb.XCB_EVENT_MASK_LEAVE_WINDOW |
                            xcb.XCB_EVENT_MASK_STRUCTURE_NOTIFY | // DWM: StructureNotifyMask
                            xcb.XCB_EVENT_MASK_PROPERTY_CHANGE;

    // DWM verbatim (manage() in dwm.c):
    //   XSelectInput(dpy, w, EnterWindowMask|FocusChangeMask|PropertyChangeMask
    //                        |StructureNotifyMask);
    //   grabbuttons(c, 0);
    //
    // DWM does NOT subscribe managed windows to ButtonPressMask via XSelectInput.
    // Button events on unfocused windows arrive via XGrabButton (grabbuttons),
    // and button events on the focused window arrive via the focused-specific
    // grabs set in grabbuttons(c, 1).  Adding BUTTON_PRESS here would mean the
    // WM receives button events through *both* the grab mechanism and the event
    // mask, creating duplicates and interfering with SYNC-mode grab sequencing.
    pub const MANAGED_WINDOW = xcb.XCB_EVENT_MASK_ENTER_WINDOW |       // DWM: EnterWindowMask
                               xcb.XCB_EVENT_MASK_FOCUS_CHANGE |        // DWM: FocusChangeMask
                               xcb.XCB_EVENT_MASK_PROPERTY_CHANGE |     // DWM: PropertyChangeMask
                               xcb.XCB_EVENT_MASK_STRUCTURE_NOTIFY;     // DWM: StructureNotifyMask
};

/// Lock key combinations grabbed alongside every keybinding so binds work
/// regardless of NumLock / CapsLock state.
pub const LOCK_MODIFIERS = [_]u16{
    0,
    MOD_CAPSLOCK,
    MOD_NUMLOCK,
    MOD_CAPSLOCK | MOD_NUMLOCK,
};

/// X11 cursor glyph IDs (mask is always source + 1 by convention).
pub const CURSOR_LEFT_PTR      = 68;
pub const CURSOR_LEFT_PTR_MASK = CURSOR_LEFT_PTR + 1;

pub const Limits = struct {
    /// Dispatch table size — covers all X11 event types up to XCB_FOCUS_OUT=10.
    pub const EVENT_DISPATCH_TABLE = 36;

    /// Upper bound for the XCB cookie scratch buffer in grabKeybindings
    /// (max distinct keybindings × 4 LOCK_MODIFIERS combinations).
    /// Raise if you ever exceed 128 keybindings.
    pub const MAX_KEYBIND_COOKIES = 512;
};