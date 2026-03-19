//! XKB (X Keyboard Extension) bindings and keyboard state management.

const std       = @import("std");
const constants = @import("constants");
const defs      = @import("defs");

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

const MAX_ATTEMPTS: u8 = 3;

pub const XkbState = struct {
    context:     *xkb_context,
    keymap:      *xkb_keymap,
    state:       *xkb_state,
    device_id:   i32,
    /// Keysym -> keycode map built at init time for O(1) config-time lookups.
    reverse_map: std.AutoHashMap(u32, u8),

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

        // Pre-size for standard keycode range (8..255 = 248 entries); best-effort.
        reverse_map.ensureTotalCapacity(248) catch {};
        for (8..256) |kc| {
            const keycode: u8 = @intCast(kc);
            const keysym: u32 = xkb.xkb_state_key_get_one_sym(st, keycode);
            if (keysym != xkb.XKB_KEY_NoSymbol) reverse_map.put(keysym, keycode) catch {};
        }

        return XkbState{
            .context     = ctx,
            .keymap      = km,
            .state       = st,
            .device_id   = device_id,
            .reverse_map = reverse_map,
        };
    }

    pub fn deinit(self: *XkbState) void {
        self.reverse_map.deinit();
        xkb.xkb_state_unref(self.state);
        xkb.xkb_keymap_unref(self.keymap);
        xkb.xkb_context_unref(self.context);
    }

    /// Convert an X11 keycode to a keysym (used during event processing).
    pub inline fn keycodeToKeysym(self: *XkbState, keycode: u8) u32 {
        return xkb.xkb_state_key_get_one_sym(self.state, keycode);
    }

    /// Reverse-look up a keysym to its keycode (used during config parsing).
    pub inline fn keysymToKeycode(self: *XkbState, keysym: u32) ?u8 {
        return self.reverse_map.get(keysym);
    }
};

/// Sleep between retry attempts; skips the sleep on the final attempt to avoid
/// a pointless wait before the error propagates to the caller.
/// Uses the global blocking Io instance — retryDelay runs during init before
/// any Io context is threaded through. Failure (e.g. unsupported clock) just
/// retries sooner.
inline fn retryDelay(attempt: u8) void {
    if (attempt < MAX_ATTEMPTS - 1)
        std.Io.Clock.Duration.sleep(
            .{ .clock = .awake, .raw = .fromMilliseconds(constants.XKB_RETRY_DELAY_MS) },
            std.Options.debug_io,
        ) catch {};
}

fn retrySetup(xcb_conn: *anyopaque) !void {
    for (0..MAX_ATTEMPTS) |i| {
        const ok = xkb.xkb_x11_setup_xkb_extension(
            @ptrCast(xcb_conn),
            xkb.XKB_X11_MIN_MAJOR_XKB_VERSION,
            xkb.XKB_X11_MIN_MINOR_XKB_VERSION,
            xkb.XKB_X11_SETUP_XKB_EXTENSION_NO_FLAGS,
            null, null, null, null,
        );
        if (ok != 0) return;
        retryDelay(@intCast(i));
    }
    return error.XkbSetupFailed;
}

/// Accept a keymap only if it has at least 40 reachable keysyms in the 8..128
/// range — guards against a partially-initialised keymap on early startup.
fn retryKeymap(ctx: *xkb_context, xcb_conn: *anyopaque, device_id: i32) !*xkb_keymap {
    for (0..MAX_ATTEMPTS) |i| {
        const km = xkb.xkb_x11_keymap_new_from_device(
            ctx, @ptrCast(xcb_conn), device_id, xkb.XKB_KEYMAP_COMPILE_NO_FLAGS,
        ) orelse {
            retryDelay(@intCast(i));
            continue;
        };

        if (xkb.xkb_state_new(km)) |test_state| {
            defer xkb.xkb_state_unref(test_state);
            var valid_keys: u32 = 0;
            for (8..128) |kc| {
                if (xkb.xkb_state_key_get_one_sym(test_state, @intCast(kc)) != xkb.XKB_KEY_NoSymbol)
                    valid_keys += 1;
            }
            if (valid_keys >= 40) return km;
        }

        xkb.xkb_keymap_unref(km);
        retryDelay(@intCast(i));
    }
    return error.XkbKeymapFailed;
}
