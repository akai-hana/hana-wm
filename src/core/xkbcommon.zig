// XKB bindings for keyboard handling
// This provides the interface between our config system and X11 keyboard events

const std = @import("std");

// C imports for xkbcommon
pub const xkb = @cImport({
    @cInclude("xkbcommon/xkbcommon.h");
    @cInclude("xkbcommon/xkbcommon-x11.h");
});

// Re-export common constants
pub const XKB_KEYSYM_CASE_INSENSITIVE: u32 = xkb.XKB_KEYSYM_CASE_INSENSITIVE;
pub const XKB_KEY_NoSymbol: u32 = xkb.XKB_KEY_NoSymbol;

// Re-export types
pub const xkb_context = xkb.struct_xkb_context;
pub const xkb_keymap = xkb.struct_xkb_keymap;
pub const xkb_state = xkb.struct_xkb_state;

// Re-export functions we need
pub const xkb_keysym_from_name = xkb.xkb_keysym_from_name;
pub const xkb_context_new = xkb.xkb_context_new;
pub const xkb_context_unref = xkb.xkb_context_unref;
pub const xkb_x11_setup_xkb_extension = xkb.xkb_x11_setup_xkb_extension;
pub const xkb_x11_get_core_keyboard_device_id = xkb.xkb_x11_get_core_keyboard_device_id;
pub const xkb_x11_keymap_new_from_device = xkb.xkb_x11_keymap_new_from_device;
pub const xkb_state_new = xkb.xkb_state_new;
pub const xkb_state_unref = xkb.xkb_state_unref;
pub const xkb_keymap_unref = xkb.xkb_keymap_unref;
pub const xkb_state_key_get_one_sym = xkb.xkb_state_key_get_one_sym;

// Helper struct to manage XKB state
pub const XkbState = struct {
    context: *xkb_context,
    keymap: *xkb_keymap,
    state: *xkb_state,
    device_id: i32,

    /// Initialize XKB for the given X11 connection
    pub fn init(xcb_conn: *anyopaque) !XkbState {
        // Create XKB context
        const ctx = xkb.xkb_context_new(xkb.XKB_CONTEXT_NO_FLAGS) orelse 
            return error.XkbContextFailed;
        errdefer xkb.xkb_context_unref(ctx);

        // Setup XKB extension on X11 connection
        const setup_result = xkb.xkb_x11_setup_xkb_extension(
            @ptrCast(xcb_conn),
            xkb.XKB_X11_MIN_MAJOR_XKB_VERSION,
            xkb.XKB_X11_MIN_MINOR_XKB_VERSION,
            xkb.XKB_X11_SETUP_XKB_EXTENSION_NO_FLAGS,
            null, null, null, null
        );
        if (setup_result == 0) return error.XkbSetupFailed;

        // Get the keyboard device ID
        const device_id = xkb.xkb_x11_get_core_keyboard_device_id(@ptrCast(xcb_conn));
        if (device_id == -1) return error.XkbNoKeyboard;

        // Create keymap from the X11 keyboard
        const keymap = xkb.xkb_x11_keymap_new_from_device(
            ctx,
            @ptrCast(xcb_conn),
            device_id,
            xkb.XKB_KEYMAP_COMPILE_NO_FLAGS
        ) orelse return error.XkbKeymapFailed;
        errdefer xkb.xkb_keymap_unref(keymap);

        // Create state tracker
        const state = xkb.xkb_state_new(keymap) orelse return error.XkbStateFailed;

        return XkbState{
            .context = ctx,
            .keymap = keymap,
            .state = state,
            .device_id = device_id,
        };
    }

    /// Clean up XKB resources
    pub fn deinit(self: *XkbState) void {
        xkb.xkb_state_unref(self.state);
        xkb.xkb_keymap_unref(self.keymap);
        xkb.xkb_context_unref(self.context);
    }

    /// Convert X11 keycode to keysym
    pub fn keycodeToKeysym(self: *XkbState, keycode: u8) u32 {
        return xkb.xkb_state_key_get_one_sym(self.state, keycode);
    }

    /// Find first keycode that produces the given keysym
    /// Returns null if no keycode produces this keysym
    pub fn keysymToKeycode(self: *XkbState, keysym: u32) ?u8 {
        // Could build a lookup table at init time, but costs memory
        // Current linear search is fine for 255 keys max
        
        const min_keycode: u8 = 8;
        const max_keycode: u8 = 255;
        
        var keycode: u8 = min_keycode;
        while (keycode <= max_keycode) : (keycode += 1) {
            const sym = xkb.xkb_state_key_get_one_sym(self.state, keycode);
            if (sym == keysym) {
                @branchHint(.likely); // Found it
                return keycode;
            }
        }
        
        return null;   
    }
};
