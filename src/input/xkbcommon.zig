//! XKB (X Keyboard Extension) bindings and keyboard state management.

const std  = @import("std");
const defs = @import("defs");

pub const xkb = @cImport({
    @cInclude("xkbcommon/xkbcommon.h");
    @cInclude("xkbcommon/xkbcommon-x11.h");
});

// Re-exports for callers that don't want to reach through `xkb.*`.
pub const XKB_KEYSYM_CASE_INSENSITIVE:            u32 = xkb.XKB_KEYSYM_CASE_INSENSITIVE;
pub const XKB_KEY_NoSymbol:                       u32 = xkb.XKB_KEY_NoSymbol;
pub const xkb_context                                 = xkb.struct_xkb_context;
pub const xkb_keymap                                  = xkb.struct_xkb_keymap;
pub const xkb_state                                   = xkb.struct_xkb_state;
pub const xkb_keysym_from_name                        = xkb.xkb_keysym_from_name;
pub const xkb_context_new                             = xkb.xkb_context_new;
pub const xkb_context_unref                           = xkb.xkb_context_unref;
pub const xkb_x11_setup_xkb_extension                = xkb.xkb_x11_setup_xkb_extension;
pub const xkb_x11_get_core_keyboard_device_id        = xkb.xkb_x11_get_core_keyboard_device_id;
pub const xkb_x11_keymap_new_from_device             = xkb.xkb_x11_keymap_new_from_device;
pub const xkb_state_new                              = xkb.xkb_state_new;
pub const xkb_state_unref                            = xkb.xkb_state_unref;
pub const xkb_keymap_unref                           = xkb.xkb_keymap_unref;
pub const xkb_state_key_get_one_sym                  = xkb.xkb_state_key_get_one_sym;

pub const XkbState = struct {
    context:     *xkb_context,
    keymap:      *xkb_keymap,
    state:       *xkb_state,
    device_id:   i32,
    // Keysym → keycode; built at init time for O(1) config-time lookups.
    reverse_map: std.AutoHashMap(u32, u8),
    allocator:   std.mem.Allocator,

    pub fn init(xcb_conn: *anyopaque, allocator: std.mem.Allocator) !XkbState {
        const ctx = xkb.xkb_context_new(xkb.XKB_CONTEXT_NO_FLAGS) orelse
            return error.XkbContextFailed;
        errdefer xkb.xkb_context_unref(ctx);

        try retrySetup(xcb_conn);

        const device_id = xkb.xkb_x11_get_core_keyboard_device_id(@ptrCast(xcb_conn));
        if (device_id == -1) return error.XkbNoKeyboard;

        const km = try retryKeymap(ctx, xcb_conn, device_id);
        errdefer xkb.xkb_keymap_unref(km);

        const st = xkb.xkb_state_new(km) orelse return error.XkbStateFailed;

        var reverse_map = std.AutoHashMap(u32, u8).init(allocator);
        errdefer reverse_map.deinit();

        // Populate reverse map for the standard keycode range.
        // Best-effort: OOM on put is silently ignored — missing entries degrade
        // gracefully (keybinding won't bind, no crash).
        for (8..256) |kc| {
            const keycode: u8  = @intCast(kc);
            const keysym: u32  = xkb.xkb_state_key_get_one_sym(st, keycode);
            if (keysym != XKB_KEY_NoSymbol) reverse_map.put(keysym, keycode) catch {};
        }

        return XkbState{
            .context     = ctx,
            .keymap      = km,
            .state       = st,
            .device_id   = device_id,
            .reverse_map = reverse_map,
            .allocator   = allocator,
        };
    }

    pub fn deinit(self: *XkbState) void {
        self.reverse_map.deinit();
        xkb.xkb_state_unref(self.state);
        xkb.xkb_keymap_unref(self.keymap);
        xkb.xkb_context_unref(self.context);
    }

    /// Converts an X11 keycode to a keysym (used during event processing).
    pub fn keycodeToKeysym(self: *XkbState, keycode: u8) u32 {
        return xkb.xkb_state_key_get_one_sym(self.state, keycode);
    }

    /// Reverse-looks up a keysym to its keycode (used during config parsing).
    pub fn keysymToKeycode(self: *XkbState, keysym: u32) ?u8 {
        return self.reverse_map.get(keysym);
    }
};

/// Attempts to set up the XKB extension up to 3 times with a short delay between tries.
fn retrySetup(xcb_conn: *anyopaque) !void {
    var attempts: u8 = 0;
    while (attempts < 3) : (attempts += 1) {
        const ok = xkb.xkb_x11_setup_xkb_extension(
            @ptrCast(xcb_conn),
            xkb.XKB_X11_MIN_MAJOR_XKB_VERSION,
            xkb.XKB_X11_MIN_MINOR_XKB_VERSION,
            xkb.XKB_X11_SETUP_XKB_EXTENSION_NO_FLAGS,
            null, null, null, null,
        );
        if (ok != 0) return;
        if (attempts + 1 < 3) std.posix.nanosleep(0, defs.XKB_RETRY_DELAY_MS * std.time.ns_per_ms);
    }
    return error.XkbSetupFailed;
}

/// Creates a keymap from the device, retrying up to 3 times.
/// Validates that the keymap has at least 40 reachable keysyms before accepting it.
fn retryKeymap(ctx: *xkb_context, xcb_conn: *anyopaque, device_id: i32) !*xkb_keymap {
    var attempts: u8 = 0;
    while (attempts < 3) : (attempts += 1) {
        const km = xkb.xkb_x11_keymap_new_from_device(
            ctx, @ptrCast(xcb_conn), device_id, xkb.XKB_KEYMAP_COMPILE_NO_FLAGS,
        ) orelse {
            if (attempts + 1 < 3) std.posix.nanosleep(0, defs.XKB_RETRY_DELAY_MS * std.time.ns_per_ms);
            continue;
        };

        if (xkb.xkb_state_new(km)) |test_state| {
            defer xkb.xkb_state_unref(test_state);
            var valid_keys: u32 = 0;
            var keycode: u32 = 8;
            while (keycode < 128) : (keycode += 1) {
                if (xkb.xkb_state_key_get_one_sym(test_state, keycode) != xkb.XKB_KEY_NoSymbol)
                    valid_keys += 1;
            }
            if (valid_keys >= 40) return km;
        }

        xkb.xkb_keymap_unref(km);
        if (attempts + 1 < 3) std.posix.nanosleep(0, defs.XKB_RETRY_DELAY_MS * std.time.ns_per_ms);
    }
    return error.XkbKeymapFailed;
}
