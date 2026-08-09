//! Core constants
//! Defines shared constants used across multiple modules.

const xcb = @cImport(@cInclude("xcb/xcb.h"));

// Modifier masks
// Must be u16 as per XCB API
pub const MOD_SHIFT: u16 = xcb.XCB_MOD_MASK_SHIFT;
const MOD_CAPSLOCK: u16 = xcb.XCB_MOD_MASK_LOCK;
pub const MOD_CONTROL: u16 = xcb.XCB_MOD_MASK_CONTROL;
pub const MOD_ALT: u16 = xcb.XCB_MOD_MASK_1;
const MOD_NUMLOCK: u16 = xcb.XCB_MOD_MASK_2;
pub const MOD_SUPER: u16 = xcb.XCB_MOD_MASK_4;

// Mask applied before comparing a received modifier state against a keybinding.
// Excludes CapsLock and NumLock so bindings fire regardless of lock-key state;
// those are handled separately via LOCK_MODIFIERS grabs.
pub const MOD_MASK_BINDING: u16 = MOD_SHIFT | MOD_CONTROL | MOD_ALT | MOD_SUPER;

// Window constraints
pub const MIN_WINDOW_DIM: u16 = 50;
pub const MIN_MASTER_WIDTH: f32 = 0.05;

// XKB retry parameters
// 20 ms is short enough to be imperceptible to the user yet long enough to avoid
// busy-spinning while the XKB extension finishes initialising (~1 polling cycle
// at 50 Hz).
pub const XKB_RETRY_DELAY_MS: u64 = 20;

// Offscreen positioning
// Windows on inactive workspaces are parked at OFFSCREEN_X_POSITION so they
// are hidden without being unmapped (unmapping causes some apps to pause).
//
// X11's ConfigureWindow request encodes x/y as INT16 on the wire (this is
// also why utils.Rect.x/y are i16), so -32768 is the hard floor for how far
// off the left edge a window can ever be parked. The previous value, -4000,
// only cleared a single 3840px-wide (4K) display with a small margin — on a
// multi-monitor layout with a display to the left of the primary, an
// ultrawide, or a 5K/6K panel, -4000 can land back inside real screen real
// estate instead of off it. -30000 clears any realistic combined desktop
// while leaving headroom below the INT16 floor.
pub const OFFSCREEN_X_POSITION: i32 = -30000;

/// Lower bound for detecting whether a window is parked offscreen.
/// A fixed upper bound is intentionally absent: multi-monitor desktops can
/// exceed 10 000 px, so only the sentinel minimum is safe to check against.
pub const OFFSCREEN_SENTINEL_MIN: i32 = -1000;

/// Maximum depth when walking the X11 window tree in findManagedWindow.
pub const MAX_WINDOW_TREE_DEPTH: usize = 10;

/// Hard ceiling on the number of workspaces the WM can meaningfully support.
///
/// This is not an arbitrary round number: tiling.zig's geometry-validity cache
/// packs one bit per workspace into a u64 (`workspace_geom_valid_bits`), and
/// workspaces.zig's per-workspace layout/master-count override lookup tables
/// are fixed-size arrays sized to match. Raising this would require widening
/// that bitmask (and the arrays) first — it is not just a config-side number.
///
/// config.zig checks parsed workspace numbers against this at parse time so a
/// config declaring more workspaces (or overrides targeting workspace indices)
/// than the WM can apply produces a visible warning immediately, rather than
/// silently doing nothing once workspaces.init() builds its lookup tables.
pub const MAX_WORKSPACES: usize = 64;

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
    //
    // BUTTON_RELEASE is ALSO kept (not in DWM's root mask either) for a
    // related reason: DWM's movemouse()/resizemouse() run their own blocking
    // XGrabPointer + XMaskEvent loop for the whole drag and read
    // ButtonRelease directly off that grab, so root never needs to select it.
    // This WM tracks drags asynchronously instead: input.startDrag() arms
    // drag.zig's state and returns immediately, and the Super+Button grab
    // from input.setupGrabs stays engaged (AsyncPointer, not ReplayPointer)
    // for the rest of the gesture, so MotionNotify/ButtonRelease keep
    // arriving to us — see keepDragGrab in input.zig for why ReplayPointer
    // is NOT used there. This bit is what lets that ButtonRelease (delivered
    // to root, the grab window) reach input.handleButtonRelease, whose
    // `if (drag.isDragging()) drag.stopDrag();` clears drag.active: without
    // it the release would be dropped, drag.active would stay stuck true
    // forever, and every hover-focus EnterNotify — for every window, on
    // every workspace — would be silently dropped by handleEnterNotify's
    // `if (drag.isDragging()) return;` guard until the WM restarts and
    // resets drag.zig's module state.
    pub const ROOT_WINDOW = xcb.XCB_EVENT_MASK_SUBSTRUCTURE_REDIRECT |
        xcb.XCB_EVENT_MASK_SUBSTRUCTURE_NOTIFY |
        xcb.XCB_EVENT_MASK_KEY_PRESS |
        xcb.XCB_EVENT_MASK_BUTTON_PRESS |
        xcb.XCB_EVENT_MASK_BUTTON_RELEASE |
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
    pub const MANAGED_WINDOW = xcb.XCB_EVENT_MASK_ENTER_WINDOW | // DWM: EnterWindowMask
        xcb.XCB_EVENT_MASK_FOCUS_CHANGE | // DWM: FocusChangeMask
        xcb.XCB_EVENT_MASK_PROPERTY_CHANGE | // DWM: PropertyChangeMask
        xcb.XCB_EVENT_MASK_STRUCTURE_NOTIFY; // DWM: StructureNotifyMask
};

/// Lock key combinations grabbed alongside every keybinding so binds work
/// regardless of NumLock / CapsLock state.
pub const LOCK_MODIFIERS = [_]u16{
    0,
    MOD_CAPSLOCK,
    MOD_NUMLOCK,
    MOD_CAPSLOCK | MOD_NUMLOCK,
};

pub const Limits = struct {
    /// Dispatch table size — covers all X11 event types up to XCB_FOCUS_OUT=10.
    pub const EVENT_DISPATCH_TABLE = 36;

    /// Upper bound for the XCB cookie scratch buffer in grabKeybindings
    /// (max distinct keybindings × 4 LOCK_MODIFIERS combinations).
    /// Raise if you ever exceed 128 keybindings.
    pub const MAX_KEYBIND_COOKIES = 512;

    /// Maximum tiled windows across the whole WM (all workspaces combined),
    /// not per workspace — see tracking.Tracking, which this backs.
    /// tracking.Tracking.len is a u8 (max 255), so this must stay <= 255
    /// unless that field is widened too.
    pub const MAX_TILED_WINDOWS = 200;
};
