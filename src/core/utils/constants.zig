//! Core constants
//! Defines shared constants used across multiple modules.

const xcb = @import("x11").xcb;

// Modifier masks
// Must be u16 as per XCB API
pub const mod_shift: u16 = xcb.XCB_MOD_MASK_SHIFT;
const mod_capslock: u16 = xcb.XCB_MOD_MASK_LOCK;
pub const mod_control: u16 = xcb.XCB_MOD_MASK_CONTROL;
pub const mod_alt: u16 = xcb.XCB_MOD_MASK_1;
const mod_numlock: u16 = xcb.XCB_MOD_MASK_2;
const mod_scrolllock: u16 = xcb.XCB_MOD_MASK_3;
pub const mod_super: u16 = xcb.XCB_MOD_MASK_4;

// Mask applied before comparing a received modifier state against a keybinding.
// Excludes CapsLock and NumLock so bindings fire regardless of lock-key state;
// those are handled separately via lock_modifiers grabs.
pub const mod_mask_binding: u16 = mod_shift | mod_control | mod_alt | mod_super;

// Window constraints
pub const min_window_dim: u16 = 50;
pub const min_master_width: f32 = 0.05;
/// Master pane width is capped at 95% so the stack column always keeps some
/// screen. Single-sourced: config validation, the runtime pixel->ratio
/// conversion, and the increase_master_width action all clamp to this same
/// bound (tiling.zig's local `max_master_width_ratio` used to duplicate it).
pub const max_master_width: f32 = 0.95;

/// Maximum number of concurrently minimized windows.
///
/// Sourced from legacy minimize.zig's `max_minimized`, which read
/// build_options.max_minimized_windows -- a build option build.zig never
/// defines, so the effective value has always been this fallback of 32.
/// Hoisted here so the model layer can reach it without importing
/// build_options (model layer rule: std + utils + constants ONLY).
/// Intentionally distinct from Limits.max_tiled_windows: this bounds the
/// concurrently-minimized buffer, not the tiled-window pool.
pub const max_minimized: usize = 32;

// XKB retry parameters
// Short enough to be imperceptible, long enough to avoid busy-spinning while
// XKB initialises (~1 polling cycle at 50 Hz).
pub const xkb_retry_delay_ms: u64 = 20;

// Offscreen positioning
// Windows on inactive workspaces are parked here so they are hidden without
// being unmapped (unmapping causes some apps to pause).
//
// X11's ConfigureWindow encodes x/y as INT16 on the wire (hence utils.Rect.x/y
// being i16), so -32768 is the hard floor. The old -4000 only cleared a single
// 3840px-wide display: on multi-monitor layouts with a display left of primary,
// ultrawides, or 5K/6K panels, -4000 can land back inside real screen estate.
// -30000 clears any realistic combined desktop while leaving headroom below
// the INT16 floor.
pub const offscreen_x_position: i32 = -30000;

/// Maximum depth when walking the X11 window tree in findManagedWindow.
pub const max_window_tree_depth: usize = 10;

/// Hard ceiling on the number of workspaces the WM can meaningfully support.
///
/// Not an arbitrary round number: tiling.zig's geometry-validity cache packs
/// one bit per workspace into a u64 (`workspace_geom_valid_bits`), and
/// workspaces.zig's per-workspace layout/master-count override tables are
/// fixed-size arrays sized to match. Raising this requires widening those
/// first; it is not just a config-side number. config.zig validates parsed
/// workspace numbers against it at parse time so oversized configs warn
/// immediately instead of silently no-oping once workspaces.init() builds its
/// lookup tables.
pub const max_workspaces: usize = 64;

// XCB property helpers
/// Maximum number of 32-bit words to request when fetching an XCB window property.
/// 256 words = 1 KiB, sufficient for all fixed-size properties the WM reads.
pub const property_max_length: u32 = 256;
/// Value for the `delete` argument to xcb_get_property that leaves the property intact.
pub const property_no_delete: u8 = 0;

// Mouse button codes (X11 button numbering)
pub const mouse_button_left: u8 = 1;
pub const mouse_button_right: u8 = 3;

// DPI / scaling
/// Standard DPI for a 1x display. All scale factors are computed relative to this value.
pub const baseline_dpi: f32 = 96.0;

// Event masks
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
    pub const root_window = xcb.XCB_EVENT_MASK_SUBSTRUCTURE_REDIRECT |
        xcb.XCB_EVENT_MASK_SUBSTRUCTURE_NOTIFY |
        xcb.XCB_EVENT_MASK_KEY_PRESS |
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

/// Lock key combinations grabbed alongside every keybinding so binds work
/// regardless of NumLock / CapsLock / ScrollLock state. All 2^3 subsets of
/// the three lock modifiers.
pub const lock_modifiers = [_]u16{
    0,
    mod_capslock,
    mod_numlock,
    mod_scrolllock,
    mod_capslock | mod_numlock,
    mod_capslock | mod_scrolllock,
    mod_numlock | mod_scrolllock,
    mod_capslock | mod_numlock | mod_scrolllock,
};

pub const Limits = struct {
    /// Dispatch table size, covers all X11 event types up to XCB_FOCUS_OUT=10.
    pub const event_dispatch_table = 36;

    /// Upper bound for the XCB cookie scratch buffer in grabKeybindings
    /// (max distinct keybindings x lock_modifiers.len combinations).
    /// Raise if you ever exceed 128 keybindings.
    pub const max_keybind_cookies = 1024;

    /// Maximum tiled windows across the whole WM (all workspaces combined),
    /// not per workspace. Buffers sized from this are indexed by usize/u16,
    /// so raising it only costs memory; keep it a compile-time bound so
    /// stack buffers stay stack buffers.
    pub const max_tiled_windows = 200;
};
