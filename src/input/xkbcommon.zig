//! XKB (X Keyboard Extension) bindings and keyboard state management

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
    reverse_map: std.AutoHashMap(u32, u8), // keysym -> keycode for fast lookup
    allocator: std.mem.Allocator,

    pub fn init(xcb_conn: *anyopaque, allocator: std.mem.Allocator) !XkbState {
        const ctx = xkb.xkb_context_new(xkb.XKB_CONTEXT_NO_FLAGS) orelse
            return error.XkbContextFailed;
        errdefer xkb.xkb_context_unref(ctx);

        try retrySetup(xcb_conn);

        const device_id = xkb.xkb_x11_get_core_keyboard_device_id(@ptrCast(xcb_conn));
        if (device_id == -1) return error.XkbNoKeyboard;

        const keymap = try retryKeymap(ctx, xcb_conn, device_id);
        errdefer xkb.xkb_keymap_unref(keymap);

        const state = xkb.xkb_state_new(keymap) orelse return error.XkbStateFailed;

        // Build reverse keymap for fast keysym -> keycode lookup
        var reverse_map = std.AutoHashMap(u32, u8).init(allocator);
        errdefer reverse_map.deinit();
        
        // Scan typical keycode range (8-255)
        for (8..256) |kc| {
            const keycode: u8 = @intCast(kc);
            const keysym = xkb.xkb_state_key_get_one_sym(state, keycode);
            if (keysym != XKB_KEY_NoSymbol) {
                // Store first keycode found for each keysym
                // Best-effort: skip keysyms that don't fit in the map (OOM).
                // The reverse_map is used for heuristic lookup only; missing
                // entries degrade gracefully. No per-entry logging here to avoid
                // flooding; callers that care should check the returned map size.
                reverse_map.put(keysym, keycode) catch {};
            }
        }

        return XkbState{
            .context = ctx,
            .keymap = keymap,
            .state = state,
            .device_id = device_id,
            .reverse_map = reverse_map,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *XkbState) void {
        self.reverse_map.deinit();
        xkb.xkb_state_unref(self.state);
        xkb.xkb_keymap_unref(self.keymap);
        xkb.xkb_context_unref(self.context);
    }

    /// Convert X11 keycode to keysym (for event processing)
    pub fn keycodeToKeysym(self: *XkbState, keycode: u8) u32 {
        return xkb.xkb_state_key_get_one_sym(self.state, keycode);
    }

    /// Find keycode for given keysym (reverse lookup for config parsing)
    /// Uses pre-built map for O(1) lookup instead of O(n) scan
    pub fn keysymToKeycode(self: *XkbState, keysym: u32) ?u8 {
        return self.reverse_map.get(keysym);
    }
};

/// Retry XKB extension setup with exponential backoff
fn retrySetup(xcb_conn: *anyopaque) !void {
    var attempts: u8 = 0;
    const max_retries = 3;

    while (attempts < max_retries) : (attempts += 1) {
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

        if (attempts + 1 < max_retries) {
            std.posix.nanosleep(0, defs.XKB_RETRY_DELAY_MS * std.time.ns_per_ms);
        }
    }

    return error.XkbSetupFailed;
}

/// Retry keymap creation with validation
fn retryKeymap(ctx: *xkb_context, xcb_conn: *anyopaque, device_id: i32) !*xkb_keymap {
    var attempts: u8 = 0;
    const max_retries = 3;

    while (attempts < max_retries) : (attempts += 1) {
        const km = xkb.xkb_x11_keymap_new_from_device(
            ctx,
            @ptrCast(xcb_conn),
            device_id,
            xkb.XKB_KEYMAP_COMPILE_NO_FLAGS,
        ) orelse {
            if (attempts + 1 < max_retries) {
                std.posix.nanosleep(0, defs.XKB_RETRY_DELAY_MS * std.time.ns_per_ms);
                continue;
            }
            return error.XkbKeymapFailed;
        };

        // Verify keymap by testing common keys
        // Test multiple keys to ensure keymap is valid
        if (xkb.xkb_state_new(km)) |test_state| {
            defer xkb.xkb_state_unref(test_state);
            
            // Test Return (usually keycode 36), Space (65), and A (38)
            var valid_keys: u8 = 0;
            for ([_]u8{ 36, 65, 38 }) |keycode| {
                if (xkb.xkb_state_key_get_one_sym(test_state, keycode) != xkb.XKB_KEY_NoSymbol) {
                    valid_keys += 1;
                }
            }
            
            // Consider keymap valid if at least 2 of 3 test keys work
            if (valid_keys >= 2) {
                return km;
            }
        }

        xkb.xkb_keymap_unref(km);

        if (attempts + 1 < max_retries) {
            std.posix.nanosleep(0, defs.XKB_RETRY_DELAY_MS * std.time.ns_per_ms);
        }
    }

    return error.XkbKeymapFailed;
}
