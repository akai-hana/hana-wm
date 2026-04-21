//! XKB (X Keyboard Extension) bindings and keyboard state management.

const std  = @import("std");

const constants = @import("constants");

pub const xkb = @cImport({
    @cInclude("xkbcommon/xkbcommon.h");
    @cInclude("xkbcommon/xkbcommon-x11.h");
});

// Re-exports for callers that don't want to reach through `xkb.*`.
pub const XKB_KEYSYM_CASE_INSENSITIVE:    u32 = xkb.XKB_KEYSYM_CASE_INSENSITIVE;
pub const XKB_KEY_NoSymbol:               u32 = xkb.XKB_KEY_NoSymbol;
pub const xkb_context                         = xkb.struct_xkb_context;
pub const xkb_keymap                          = xkb.struct_xkb_keymap;
pub const xkb_state                           = xkb.struct_xkb_state;
pub const xkb_keysym_from_name                = xkb.xkb_keysym_from_name;
pub const xkb_context_new                     = xkb.xkb_context_new;
pub const xkb_context_unref                   = xkb.xkb_context_unref;
pub const xkb_x11_setup_xkb_extension         = xkb.xkb_x11_setup_xkb_extension;
pub const xkb_x11_get_core_keyboard_device_id = xkb.xkb_x11_get_core_keyboard_device_id;
pub const xkb_x11_keymap_new_from_device      = xkb.xkb_x11_keymap_new_from_device;
pub const xkb_state_new                       = xkb.xkb_state_new;
pub const xkb_state_unref                     = xkb.xkb_state_unref;
pub const xkb_keymap_unref                    = xkb.xkb_keymap_unref;
pub const xkb_state_key_get_one_sym           = xkb.xkb_state_key_get_one_sym;

const MAX_ATTEMPTS: u8 = 3;

pub const XkbState = struct {
    context:           *xkb_context,
    keymap:            *xkb_keymap,
    state:             *xkb_state,
    device_id:         i32,
    /// Flat keycode->keysym table for the standard X11 range (indices 0..255).
    /// Populated at init time; entries outside 8..255 hold XKB_KEY_NoSymbol.
    /// No allocator needed — 256 × 4 bytes = 1 KiB, lives inside XkbState.
    keysym_by_keycode: [256]u32,

    /// Initialises an XKB context, keymap, and state from the live X connection.
    /// Retries up to MAX_ATTEMPTS times to handle early-startup races.
    pub fn init(xcb_conn: *anyopaque) !XkbState {
        const ctx = xkb.xkb_context_new(xkb.XKB_CONTEXT_NO_FLAGS) orelse
            return error.XkbContextFailed;
        errdefer xkb.xkb_context_unref(ctx);

        try retrySetup(xcb_conn);

        const device_id = xkb.xkb_x11_get_core_keyboard_device_id(@ptrCast(xcb_conn));
        if (device_id == -1) return error.XkbNoKeyboard;

        const km = try retryKeymap(ctx, xcb_conn, device_id);
        errdefer xkb.xkb_keymap_unref(km);

        const st = xkb.xkb_state_new(km) orelse return error.XkbStateFailed;

        // Populate the flat table. Keycodes below 8 are reserved by X11 and
        // will never produce a real keysym; fill them with NoSymbol so the
        // array is always fully initialised and index arithmetic stays trivial.
        var table: [256]u32 = [_]u32{xkb.XKB_KEY_NoSymbol} ** 256;
        for (8..256) |kc| {
            table[kc] = xkb.xkb_state_key_get_one_sym(st, @intCast(kc));
        }

        return XkbState{
            .context           = ctx,
            .keymap            = km,
            .state             = st,
            .device_id         = device_id,
            .keysym_by_keycode = table,
        };
    }

    /// Releases the XKB state, keymap, and context in reverse-init order.
    pub fn deinit(self: *XkbState) void {
        xkb.xkb_state_unref(self.state);
        xkb.xkb_keymap_unref(self.keymap);
        xkb.xkb_context_unref(self.context);
    }

    /// Convert an X11 keycode to a keysym for keybinding dispatch.
    /// Uses the lock-modifier-free table built at init so results are
    /// unaffected by NumLock / CapsLock state.
    pub inline fn keycodeToKeysym(self: *const XkbState, keycode: u8) u32 {
        return self.keysym_by_keycode[keycode];
    }

    /// Reverse-look up a keysym to its keycode (used during config parsing).
    ///
    /// Scans the flat table (248 entries, all in L1 cache). This is called
    /// only at config-parse time — never on the hot key-press path — so the
    /// linear scan costs nothing in practice.
    /// When a keysym is reachable from multiple keycodes (e.g. base and
    /// shifted variants), returns the first match in keycode order (8..255).
    pub inline fn keysymToKeycode(self: *const XkbState, keysym: u32) ?u8 {
        for (8..256) |kc| {
            if (self.keysym_by_keycode[kc] == keysym) return @intCast(kc);
        }
        return null;
    }
};

const XKB_RETRY_DELAY_MS = constants.XKB_RETRY_DELAY_MS;

/// Sleep between retry attempts; skips the sleep on the final attempt to avoid
/// a pointless wait before the error propagates to the caller.
/// Failure is benign — retries simply happen sooner.
inline fn retryDelay(attempt: u8) void {
    if (attempt >= MAX_ATTEMPTS - 1) return;
    const ns = XKB_RETRY_DELAY_MS * std.time.ns_per_ms;
    var req = std.os.linux.timespec{
        .sec  = @intCast(ns / std.time.ns_per_s),
        .nsec = @intCast(ns % std.time.ns_per_s),
    };
    var rem = std.os.linux.timespec{ .sec = 0, .nsec = 0 };
    _ = std.os.linux.nanosleep(&req, &rem);
}

/// Calls xkb_x11_setup_xkb_extension, retrying up to MAX_ATTEMPTS times with a brief delay.
/// The extension may not be ready immediately at WM startup.
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

/// Returns true if `km` has at least 40 reachable keysyms in the 8..128 range.
/// Guards against accepting a partially-initialised keymap on early startup.
fn keymapHasEnoughSymbols(km: *xkb_keymap) bool {
    const test_state = xkb.xkb_state_new(km) orelse return false;
    defer xkb.xkb_state_unref(test_state);
    var valid_keys: u32 = 0;
    for (8..128) |kc| {
        if (xkb.xkb_state_key_get_one_sym(test_state, @intCast(kc)) != xkb.XKB_KEY_NoSymbol)
            valid_keys += 1;
    }
    return valid_keys >= 40;
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

        if (keymapHasEnoughSymbols(km)) return km;

        xkb.xkb_keymap_unref(km);
        retryDelay(@intCast(i));
    }
    return error.XkbKeymapFailed;
}