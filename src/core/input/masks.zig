//! Input-layer protocol vocabulary: modifier masks, event masks, mouse button codes,
//! and the binding-mask helpers. A member of the pure shelf (build.zig's
//! pureLayerAllows), so config/ may import it; it lives beside its consumers in
//! src/core/input/. Constants are spelled as their X protocol values rather than
//! `@import("xcb")` names, keeping the file xcb-free; masks_test.zig pins every
//! literal against the XCB names so a divergence fails there.

// Modifier masks (X protocol: Shift=1<<0, Lock=1<<1, Control=1<<2, Mod1..Mod5=1<<3..1<<7).
// u16 as the XCB API's modifier fields require.
pub const mod_shift: u16 = 1 << 0;
pub const mod_capslock: u16 = 1 << 1;
pub const mod_control: u16 = 1 << 2;
pub const mod_alt: u16 = 1 << 3;
pub const mod_numlock: u16 = 1 << 4;
pub const mod_scrolllock: u16 = 1 << 5;
pub const mod_super: u16 = 1 << 6;

// Mouse button codes (X11 button numbering)
pub const mouse_button_left: u8 = 1;
pub const mouse_button_middle: u8 = 2;
pub const mouse_button_right: u8 = 3;
pub const mouse_button_scroll_up: u8 = 4;
pub const mouse_button_scroll_down: u8 = 5;

// Modifier keysym band. X11 reserves XK_Shift_L..XK_Hyper_R (0xFFE1..0xFFEE) for
// modifier keys; the check widens it by one key on each side (neither a valid
// editing/navigation key) so bare modifier presses drop without log noise. Shared by
// core/input/keys.zig and the prompt.
pub const modifier_keysym_lo: u32 = 0xFFE0;
pub const modifier_keysym_hi: u32 = 0xFFEF;

/// True when `keysym` is in the modifier band (see above): a bare modifier press can
/// never match a binding, so callers stay silent rather than log keystroke noise.
pub inline fn isModifierKeysym(keysym: u32) bool {
    return keysym >= modifier_keysym_lo and keysym <= modifier_keysym_hi;
}

/// Lock key combinations grabbed alongside every keybinding so binds work regardless
/// of NumLock / CapsLock / ScrollLock state: all 2^3 subsets of the three lock
/// modifiers, in the historical grab order (size 0, singles, pairs, triple).
/// Consumers only iterate it / use `.len`.
pub const lock_bits: u16 = mod_capslock | mod_numlock | mod_scrolllock;

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

/// Strips the XCB synthetic-event bit (bit 7) from a raw event `response_type` to
/// recover the core event code: core codes are 0..0x7F and the top bit marks a
/// SendEvent delivery, which preserves the low 7 bits. Callers fold through
/// `coreEventType` rather than spelling the mask.
pub const core_event_code_mask: u8 = 0x7f;

/// THE one spelling of "strip the SendEvent bit": dispatch routing, window
/// extraction, trace naming and the prompt's key filter all fold through here.
pub inline fn coreEventType(response_type: u8) u8 {
    return response_type & core_event_code_mask;
}

pub const EventMasks = struct {
    // DWM verbatim (setup() in dwm.c): SubstructureRedirect|Notify, ButtonPress,
    // PointerMotion, Enter/LeaveWindow, StructureNotify, PropertyChange -- except for
    // these deliberate deviations, all because this WM differs:
    //  - KEY_PRESS: our keybind grabs land on root via xcb_grab_key.
    //  - POINTER_MOTION (raw): volume bounded by motion coalescing in
    //    events.handleXcbEvents (collapses a run to its last event per poll wakeup).
    //  - BUTTON_RELEASE: DWM's drags run their own blocking XGrabPointer loop so root
    //    never needs it; ours are async, with the Super+Button grab engaged for the
    //    whole gesture. Without this bit drag.active sticks true and hover-focus drops
    //    every EnterNotify until the WM restarts.
    //  - KEY_RELEASE: the release half of every binding press, and the way a passive
    //    grab's held key keeps re-firing under detectable auto-repeat (the root mask,
    //    not the grab, decides what the WM receives).
    pub const root_window: u32 = 1 << 20 | // SubstructureRedirect
        1 << 19 | // SubstructureNotify
        1 << 0 | // KeyPress
        1 << 1 | // KeyRelease
        1 << 2 | // ButtonPress
        1 << 3 | // ButtonRelease
        1 << 6 | // PointerMotion
        1 << 4 | // EnterWindow
        1 << 5 | // LeaveWindow
        1 << 17 | // StructureNotify (DWM: StructureNotifyMask)
        1 << 22; // PropertyChange

    // DWM verbatim (manage() in dwm.c): EnterWindow|FocusChange|PropertyChange|
    // StructureNotify via XSelectInput; buttons via XGrabButton (grabbuttons).
    // Deliberately NO BUTTON_PRESS: unfocused-window buttons arrive via grabbuttons'
    // grabs and focused ones via the focus-specific grabs. Adding it here would
    // duplicate them and interfere with SYNC-mode grab sequencing.
    pub const managed_window: u32 = 1 << 4 | // EnterWindow (DWM: EnterWindowMask)
        1 << 21 | // FocusChange (DWM: FocusChangeMask)
        1 << 22 | // PropertyChange (DWM: PropertyChangeMask)
        1 << 17; // StructureNotify (DWM: StructureNotifyMask)
};

/// The four modifiers a binding can be expressed in, as a 4-bit value.
///
/// A raw `u16` carries lock bits (NumLock, CapsLock, ScrollLock) and pointer button
/// bits that can never match a configured mask, which made an un-normalized value a
/// SILENT failure: the binding simply never fires, with no compiler hint. At four bits
/// the type cannot represent those bits, so the mistake becomes a compile error at the
/// call site -- the only place it can be diagnosed, since the symptom is "my binding
/// is dead" weeks later.
pub const BindingMods = packed struct(u4) {
    shift: bool = false,
    control: bool = false,
    alt: bool = false,
    super: bool = false,

    /// True when no binding modifier is held.
    pub inline fn isEmpty(m: BindingMods) bool {
        return @as(u4, @bitCast(m)) == 0;
    }
};

/// Strips lock-key and pointer-button bits from a raw event modifier state, leaving
/// only the bits the WM uses for keybind matching. A mask operation, so it lives with
/// the masks it filters; the input layer is the only caller.
pub inline fn normalizeModifiers(state: u16) BindingMods {
    return .{
        .shift = state & mod_shift != 0,
        .control = state & mod_control != 0,
        .alt = state & mod_alt != 0,
        .super = state & mod_super != 0,
    };
}

/// Widens back to a `u16` mask for paths comparing against a config's stored masks
/// (mouse binds) or printing one. The reverse of `normalizeModifiers` and lossy in
/// the same way: bits outside the four are not representable.
pub inline fn toMask(m: BindingMods) u16 {
    var mask: u16 = 0;
    if (m.shift) mask |= mod_shift;
    if (m.control) mask |= mod_control;
    if (m.alt) mask |= mod_alt;
    if (m.super) mask |= mod_super;
    return mask;
}
