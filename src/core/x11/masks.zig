//! XCB modifier masks and event masks.
//!
//! Separated from the core constants to keep the model layer (which imports
//! constants) free of transitive XCB dependencies.

const xcb = @import("xcb").xcb;

// Modifier masks
// Must be u16 as per XCB API
pub const mod_shift: u16 = xcb.XCB_MOD_MASK_SHIFT;
pub const mod_capslock: u16 = xcb.XCB_MOD_MASK_LOCK;
pub const mod_control: u16 = xcb.XCB_MOD_MASK_CONTROL;
pub const mod_alt: u16 = xcb.XCB_MOD_MASK_1;
pub const mod_numlock: u16 = xcb.XCB_MOD_MASK_2;
pub const mod_scrolllock: u16 = xcb.XCB_MOD_MASK_3;
pub const mod_super: u16 = xcb.XCB_MOD_MASK_4;

// Mask applied before comparing a received modifier state against a keybinding.
// Excludes CapsLock and NumLock so bindings fire regardless of lock-key state;
// those are handled separately via lock_modifiers grabs.
pub const mod_mask_binding: u16 = mod_shift | mod_control | mod_alt | mod_super;

// Modifier keysym band. X11 reserves XK_Shift_L..XK_Hyper_R (0xFFE1..0xFFEE)
// for modifier keys; the check widens that band by one key on each side (none
// of which are valid editing/navigation keys) so bare modifier presses can be
// dropped without logging noise. Shared by input.zig and the prompt.
pub const modifier_keysym_lo: u32 = 0xFFE0;
pub const modifier_keysym_hi: u32 = 0xFFEF;

/// True when `keysym` falls in the modifier keysym band (see above). A bare
/// modifier press can never match a binding; callers use this to stay silent
/// instead of logging keystroke noise.
pub inline fn isModifierKeysym(keysym: u32) bool {
    return keysym >= modifier_keysym_lo and keysym <= modifier_keysym_hi;
}

/// Lock key combinations grabbed alongside every keybinding so binds work
/// regardless of NumLock / CapsLock / ScrollLock state. All 2^3 subsets of
/// the three lock modifiers in the historical grab order (size 0, the three
/// singles, the three pairs, the triple). Consumers only iterate it / use `.len`.
pub const lock_modifiers: [8]u16 = .{
    0,
    mod_capslock,
    mod_numlock,
    mod_scrolllock,
    mod_capslock | mod_numlock,
    mod_capslock | mod_scrolllock,
    mod_numlock | mod_scrolllock,
    mod_capslock | mod_numlock | mod_scrolllock,
};

// Event masks
/// Strips the XCB synthetic-event bit (bit 7) from a raw event `response_type`
/// to recover the core event code. Core event codes are 0..0x7F; the top bit
/// marks events delivered via SendEvent. Core events keep their low-7 bits
/// under a SendEvent, so masking recovers the true code; extension bases can
/// legitimately sit at/above 0x80, so extension-range tests compare the RAW
/// type byte before any mask (see isRandrEvent).
pub const synthetic_event_mask: u8 = 0x7f;

pub const EventMasks = struct {
    // DWM verbatim (setup() in dwm.c): SubstructureRedirect|Notify, ButtonPress,
    // PointerMotion, Enter/LeaveWindow, StructureNotify, PropertyChange.
    //
    // Three deliberate deviations, all because this WM differs from DWM:
    //  - KEY_PRESS: our keybinding grabs land on root via xcb_grab_key.
    //  - POINTER_MOTION (raw): the server reports every pointer move; raw
    //    volume is bounded by motion coalescing in events.handleXcbEvents,
    //    which collapses runs to the last event per poll wakeup (replaces
    //    the old POINTER_MOTION_HINT + per-tick QueryPointer re-arm).
    //  - BUTTON_RELEASE: DWM's drags run their own blocking XGrabPointer +
    //    XMaskEvent loop, so root never needs it. Ours are async; the
    //    Super+Button grab from input.setupGrabs stays engaged for the whole
    //    gesture (AsyncPointer; see keepDragGrab in input.zig), so this bit is
    //    what lets the release reach input.handleButtonRelease and clear
    //    drag.active. Without it, drag.active sticks true and handleEnterNotify
    //    drops every hover-focus EnterNotify until the WM restarts.
    //  - KEY_RELEASE: the release half of every binding press. Key RELEASE
    //    also covers a passive grab's repeated presses re-firing: with
    //    detectable auto-repeat held binding keys re-fire their action on
    //    every repeat (a passive grab reports the release to the grab window,
    //    but the root mask, not the grab, decides which events the WM actually
    //    receives — without the release bit, the detectable-auto-repeat
    //    press/release stream in input.zig would still work for presses but
    //    releases would be lost).
    pub const root_window = xcb.XCB_EVENT_MASK_SUBSTRUCTURE_REDIRECT |
        xcb.XCB_EVENT_MASK_SUBSTRUCTURE_NOTIFY |
        xcb.XCB_EVENT_MASK_KEY_PRESS |
        xcb.XCB_EVENT_MASK_KEY_RELEASE |
        xcb.XCB_EVENT_MASK_BUTTON_PRESS |
        xcb.XCB_EVENT_MASK_BUTTON_RELEASE |
        xcb.XCB_EVENT_MASK_POINTER_MOTION |
        xcb.XCB_EVENT_MASK_ENTER_WINDOW |
        xcb.XCB_EVENT_MASK_LEAVE_WINDOW |
        xcb.XCB_EVENT_MASK_STRUCTURE_NOTIFY | // DWM: StructureNotifyMask
        xcb.XCB_EVENT_MASK_PROPERTY_CHANGE;

    // DWM verbatim (manage() in dwm.c): EnterWindow|FocusChange|PropertyChange|
    // StructureNotify via XSelectInput; buttons via XGrabButton (grabbuttons).
    //
    // Deliberately NO BUTTON_PRESS: DWM does not subscribe managed windows to
    // it either; unfocused-window buttons arrive via grabbuttons' grabs and
    // focused-window buttons via the focus-specific grabs. Adding it here would
    // deliver button events through both mechanisms, duplicating events and
    // interfering with SYNC-mode grab sequencing.
    pub const managed_window = xcb.XCB_EVENT_MASK_ENTER_WINDOW | // DWM: EnterWindowMask
        xcb.XCB_EVENT_MASK_FOCUS_CHANGE | // DWM: FocusChangeMask
        xcb.XCB_EVENT_MASK_PROPERTY_CHANGE | // DWM: PropertyChangeMask
        xcb.XCB_EVENT_MASK_STRUCTURE_NOTIFY; // DWM: StructureNotifyMask
};
