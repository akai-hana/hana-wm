//! XKB (X Keyboard Extension) bindings and initialization.
//!
//! Handles keyboard state management including:
//! - XKB context and keymap initialization
//! - Keycode to keysym translation
//! - Keysym to keycode reverse lookup
//! - Retry logic for race conditions during X server startup

const std = @import("std");
const log = @import("logging");

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

// Re-export functions
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

/// Maximum retry attempts for XKB initialization
const MAX_RETRIES = 50;
/// Delay between retries in milliseconds
const RETRY_DELAY_MS = 20;

/// Managed XKB state with context, keymap, and device
pub const XkbState = struct {
    context: *xkb_context,
    keymap: *xkb_keymap,
    state: *xkb_state,
    device_id: i32,

    /// Initialize XKB state with retry logic for X server race conditions
    pub fn init(xcb_conn: *anyopaque) !XkbState {
        log.debugXkbInitializing();

        // Create XKB context
        const ctx = xkb.xkb_context_new(xkb.XKB_CONTEXT_NO_FLAGS) orelse
            return error.XkbContextFailed;
        errdefer xkb.xkb_context_unref(ctx);

        // Setup XKB extension (with retry for startx race conditions)
        try retrySetup(xcb_conn);

        // Get keyboard device ID
        const device_id = xkb.xkb_x11_get_core_keyboard_device_id(@ptrCast(xcb_conn));
        if (device_id == -1) return error.XkbNoKeyboard;
        log.debugXkbDeviceId(device_id);

        // Create and verify keymap (with retry)
        const keymap = try retryKeymap(ctx, xcb_conn, device_id);
        errdefer xkb.xkb_keymap_unref(keymap);

        // Create state from keymap
        const state = xkb.xkb_state_new(keymap) orelse return error.XkbStateFailed;

        log.debugXkbInitComplete();
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

    /// Convert X11 keycode to keysym
    pub fn keycodeToKeysym(self: *XkbState, keycode: u8) u32 {
        return xkb.xkb_state_key_get_one_sym(self.state, keycode);
    }

    /// Reverse lookup: find keycode for a given keysym
    pub fn keysymToKeycode(self: *XkbState, keysym: u32) ?u8 {
        // Scan valid keycode range (8-255)
        for (8..256) |kc| {
            const keycode: u8 = @intCast(kc);
            if (xkb.xkb_state_key_get_one_sym(self.state, keycode) == keysym) {
                return keycode;
            }
        }
        log.warnXkbKeycodeNotFound(keysym);
        return null;
    }
};

/// Retry XKB setup with delays to handle X server race conditions
fn retrySetup(xcb_conn: *anyopaque) !void {
    var attempts: usize = 0;
    
    while (attempts < MAX_RETRIES) : (attempts += 1) {
        const result = xkb.xkb_x11_setup_xkb_extension(
            @ptrCast(xcb_conn),
            xkb.XKB_X11_MIN_MAJOR_XKB_VERSION,
            xkb.XKB_X11_MIN_MINOR_XKB_VERSION,
            xkb.XKB_X11_SETUP_XKB_EXTENSION_NO_FLAGS,
            null, null, null, null
        );
        
        if (result != 0) return;
        
        if (attempts + 1 < MAX_RETRIES) {
            std.posix.nanosleep(0, RETRY_DELAY_MS * std.time.ns_per_ms);
        }
    }
    
    return error.XkbSetupFailed;
}

/// Retry keymap creation with delays to handle X server race conditions
fn retryKeymap(ctx: *xkb_context, xcb_conn: *anyopaque, device_id: i32) !*xkb_keymap {
    var attempts: usize = 0;
    
    while (attempts < MAX_RETRIES) : (attempts += 1) {
        const km = xkb.xkb_x11_keymap_new_from_device(
            ctx, @ptrCast(xcb_conn), device_id, xkb.XKB_KEYMAP_COMPILE_NO_FLAGS
        ) orelse {
            if (attempts + 1 < MAX_RETRIES) {
                std.posix.nanosleep(0, RETRY_DELAY_MS * std.time.ns_per_ms);
                continue;
            }
            return error.XkbKeymapFailed;
        };

        // Verify keymap works by testing Return key (keycode 36)
        if (xkb.xkb_state_new(km)) |test_state| {
            defer xkb.xkb_state_unref(test_state);
            if (xkb.xkb_state_key_get_one_sym(test_state, 36) != xkb.XKB_KEY_NoSymbol) {
                return km;
            }
        }

        xkb.xkb_keymap_unref(km);
        
        if (attempts + 1 < MAX_RETRIES) {
            std.posix.nanosleep(0, RETRY_DELAY_MS * std.time.ns_per_ms);
        }
    }
    
    return error.XkbKeymapFailed;
}
