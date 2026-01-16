// XKB bindings for keyboard handling

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

pub const XkbState = struct {
    context: *xkb_context,
    keymap: *xkb_keymap,
    state: *xkb_state,
    device_id: i32,

    pub fn init(xcb_conn: *anyopaque) !XkbState {
        log.debugXkbInitializing();

        const ctx = xkb.xkb_context_new(xkb.XKB_CONTEXT_NO_FLAGS) orelse
            return error.XkbContextFailed;
        errdefer xkb.xkb_context_unref(ctx);

        // Setup XKB extension with retry for startx
        var setup_result: i32 = 0;

        for (0..50) |_| { // 50 -> max xkb setup retries
            setup_result = xkb.xkb_x11_setup_xkb_extension(
                @ptrCast(xcb_conn), xkb.XKB_X11_MIN_MAJOR_XKB_VERSION,
                xkb.XKB_X11_MIN_MINOR_XKB_VERSION, xkb.XKB_X11_SETUP_XKB_EXTENSION_NO_FLAGS,
                null, null, null, null
            );
            if (setup_result != 0) break;
            std.posix.nanosleep(0, 20 * std.time.ns_per_ms); // 20 -> xcb retry delay ms
        }
        if (setup_result == 0) return error.XkbSetupFailed;

        const device_id = xkb.xkb_x11_get_core_keyboard_device_id(@ptrCast(xcb_conn));
        if (device_id == -1) return error.XkbNoKeyboard;
        log.debugXkbDeviceId(device_id);

        // Create and verify keymap with retry
        var keymap: ?*xkb_keymap = null;
        for (0..50) |_| {
            keymap = xkb.xkb_x11_keymap_new_from_device(
                ctx, @ptrCast(xcb_conn), device_id, xkb.XKB_KEYMAP_COMPILE_NO_FLAGS
            );

            if (keymap) |km| {
                // Verify keymap is usable by testing Return key (keycode 36)
                if (xkb.xkb_state_new(km)) |st| {
                    defer xkb.xkb_state_unref(st);
                    if (xkb.xkb_state_key_get_one_sym(st, 36) != xkb.XKB_KEY_NoSymbol) break;
                }
                xkb.xkb_keymap_unref(km);
                keymap = null;
            }

            std.posix.nanosleep(0, 20 * std.time.ns_per_ms);
        }

        const final_keymap = keymap orelse return error.XkbKeymapFailed;
        errdefer xkb.xkb_keymap_unref(final_keymap);

        const state = xkb.xkb_state_new(final_keymap) orelse return error.XkbStateFailed;

        log.debugXkbInitComplete();
        return XkbState{
            .context = ctx,
            .keymap = final_keymap,
            .state = state,
            .device_id = device_id,
        };
    }

    pub fn deinit(self: *XkbState) void {
        xkb.xkb_state_unref(self.state);
        xkb.xkb_keymap_unref(self.keymap);
        xkb.xkb_context_unref(self.context);
    }

    pub fn keycodeToKeysym(self: *XkbState, keycode: u8) u32 {
        return xkb.xkb_state_key_get_one_sym(self.state, keycode);
    }

    pub fn keysymToKeycode(self: *XkbState, keysym: u32) ?u8 {
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
