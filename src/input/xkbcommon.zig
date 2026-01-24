//! XKB (X Keyboard Extension) bindings and keyboard state management.
//!
//! This module wraps xkbcommon-x11 to provide:
//! - Keyboard state initialization with retry logic (X server race conditions)
//! - Keycode to keysym translation for event processing
//! - Keysym to keycode lookup for configuration parsing
//!
//! The retry logic is critical for reliability when starting alongside other
//! X11 applications that may be initializing the keyboard simultaneously.

const std = @import("std");
const defs = @import("defs");

pub const xkb = @cImport({
    @cInclude("xkbcommon/xkbcommon.h");
    @cInclude("xkbcommon/xkbcommon-x11.h");
});

// Re-exports for cleaner usage
pub const XKB_KEYSYM_CASE_INSENSITIVE: u32 = xkb.XKB_KEYSYM_CASE_INSENSITIVE;
pub const XKB_KEY_NoSymbol: u32 = xkb.XKB_KEY_NoSymbol;
pub const xkb_context = xkb.struct_xkb_context;
pub const xkb_keymap = xkb.struct_xkb_keymap;
pub const xkb_state = xkb.struct_xkb_state;
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

pub const XkbState = struct {
    context: *xkb_context,
    keymap: *xkb_keymap,
    state: *xkb_state,
    device_id: i32,

    /// Initialize with retry logic for X server race conditions
    ///
    /// When multiple X11 clients start simultaneously, keyboard initialization
    /// can fail. We retry with exponential backoff to handle this gracefully.
    pub fn init(xcb_conn: *anyopaque) !XkbState {
        const ctx = xkb.xkb_context_new(xkb.XKB_CONTEXT_NO_FLAGS) orelse
            return error.XkbContextFailed;
        errdefer xkb.xkb_context_unref(ctx);

        try retrySetup(xcb_conn);

        const device_id = xkb.xkb_x11_get_core_keyboard_device_id(@ptrCast(xcb_conn));
        if (device_id == -1) return error.XkbNoKeyboard;

        const keymap = try retryKeymap(ctx, xcb_conn, device_id);
        errdefer xkb.xkb_keymap_unref(keymap);

        const state = xkb.xkb_state_new(keymap) orelse return error.XkbStateFailed;

        return XkbState{
            .context = ctx,
            .keymap = keymap,
            .state = state,
            .device_id = device_id,
        };
    }

    pub fn deinit(self: *XkbState) void {
        xkb.xkb_state_unref(self.state);
        xkb.xkb_keymap_unref(self.keymap);
        xkb.xkb_context_unref(self.context);
    }

    /// Convert X11 keycode to keysym (for event processing)
    pub inline fn keycodeToKeysym(self: *XkbState, keycode: u8) u32 {
        return xkb.xkb_state_key_get_one_sym(self.state, keycode);
    }

    /// Find keycode for given keysym (reverse lookup for config parsing)
    ///
    /// Scans the keymap to find which keycode produces the desired keysym.
    /// Returns null if the keysym is not mapped to any key.
    pub fn keysymToKeycode(self: *XkbState, keysym: u32) ?u8 {
        // Scan typical keycode range (8-255 on most systems)
        for (8..256) |kc| {
            const keycode: u8 = @intCast(kc);
            if (xkb.xkb_state_key_get_one_sym(self.state, keycode) == keysym) {
                return keycode;
            }
        }
        return null;
    }
};

/// Retry XKB extension setup with exponential backoff
fn retrySetup(xcb_conn: *anyopaque) !void {
    var attempts: usize = 0;

    while (attempts < defs.XKB_MAX_RETRIES) : (attempts += 1) {
        const result = xkb.xkb_x11_setup_xkb_extension(
            @ptrCast(xcb_conn),
            xkb.XKB_X11_MIN_MAJOR_XKB_VERSION,
            xkb.XKB_X11_MIN_MINOR_XKB_VERSION,
            xkb.XKB_X11_SETUP_XKB_EXTENSION_NO_FLAGS,
            null,
            null,
            null,
            null,
        );

        if (result != 0) return;

        if (attempts + 1 < defs.XKB_MAX_RETRIES) {
            std.posix.nanosleep(0, defs.XKB_RETRY_DELAY_MS * std.time.ns_per_ms);
        }
    }

    return error.XkbSetupFailed;
}

/// Retry keymap creation with validation
fn retryKeymap(ctx: *xkb_context, xcb_conn: *anyopaque, device_id: i32) !*xkb_keymap {
    var attempts: usize = 0;

    while (attempts < defs.XKB_MAX_RETRIES) : (attempts += 1) {
        const km = xkb.xkb_x11_keymap_new_from_device(
            ctx,
            @ptrCast(xcb_conn),
            device_id,
            xkb.XKB_KEYMAP_COMPILE_NO_FLAGS,
        ) orelse {
            if (attempts + 1 < defs.XKB_MAX_RETRIES) {
                std.posix.nanosleep(0, defs.XKB_RETRY_DELAY_MS * std.time.ns_per_ms);
                continue;
            }
            return error.XkbKeymapFailed;
        };

        // Verify keymap by testing Return key (keycode 36 on most systems)
        // If the keymap is corrupt, it might return NoSymbol for basic keys
        if (xkb.xkb_state_new(km)) |test_state| {
            defer xkb.xkb_state_unref(test_state);
            if (xkb.xkb_state_key_get_one_sym(test_state, 36) != xkb.XKB_KEY_NoSymbol) {
                return km;
            }
        }

        xkb.xkb_keymap_unref(km);

        if (attempts + 1 < defs.XKB_MAX_RETRIES) {
            std.posix.nanosleep(0, defs.XKB_RETRY_DELAY_MS * std.time.ns_per_ms);
        }
    }

    return error.XkbKeymapFailed;
}
