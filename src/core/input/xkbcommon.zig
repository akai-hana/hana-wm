//! XKB bindings and keyboard state
//! Wraps the XKB library to provide keyboard state tracking and keysym resolution.

const std = @import("std");

const constants = @import("constants");
const debug = @import("debug");

pub const xkb = @cImport({
    @cInclude("xkbcommon/xkbcommon.h");
    @cInclude("xkbcommon/xkbcommon-x11.h");
});

// Re-exports for callers that don't want to reach through `xkb.*`.
pub const XKB_KEYSYM_CASE_INSENSITIVE = xkb.XKB_KEYSYM_CASE_INSENSITIVE;
pub const XKB_KEY_NoSymbol: u32 = xkb.XKB_KEY_NoSymbol;
pub const xkb_keysym_from_name = xkb.xkb_keysym_from_name;
const xkb_context = xkb.struct_xkb_context;
const xkb_keymap = xkb.struct_xkb_keymap;
const xkb_state = xkb.struct_xkb_state;

const MAX_ATTEMPTS: u8 = 3;

pub const XkbState = struct {
    context: *xkb_context,
    keymap: *xkb_keymap,
    state: *xkb_state,
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

        const device_id = try retryDeviceId(xcb_conn);

        const km = try retryKeymap(ctx, xcb_conn, device_id);
        errdefer xkb.xkb_keymap_unref(km);

        const st = xkb.xkb_state_new(km) orelse return error.XkbStateFailed;

        return XkbState{
            .context = ctx,
            .keymap = km,
            .state = st,
            .keysym_by_keycode = buildKeysymTable(km),
        };
    }

    /// Releases the XKB state, keymap, and context in reverse-init order.
    pub fn deinit(self: *XkbState) void {
        xkb.xkb_state_unref(self.state);
        xkb.xkb_keymap_unref(self.keymap);
        xkb.xkb_context_unref(self.context);
    }

/// Rebuilds the keymap, state, and keysym table after a server-side mapping
/// change (setxkbmap/xmodmap → XCB_MAPPING_NOTIFY). Dispatch resolves keysyms
/// from the table, so it must track the new mapping or bindings silently stop
/// matching; on failure the old mapping is kept.
    pub fn rebuild(self: *XkbState, xcb_conn: *anyopaque) void {
        const device_id = xkb.xkb_x11_get_core_keyboard_device_id(@ptrCast(xcb_conn));
        if (device_id == -1) return;
        const km = retryKeymap(self.context, xcb_conn, device_id) catch {
            debug.warn("XKB: keymap rebuild failed after mapping change; keeping old mapping", .{});
            return;
        };
        const st = xkb.xkb_state_new(km) orelse {
            xkb.xkb_keymap_unref(km);
            debug.warn("XKB: state rebuild failed after mapping change; keeping old mapping", .{});
            return;
        };

        // Build the table before freeing anything; failure above already
        // returned, so the swap below cannot fail.
        const new_table = buildKeysymTable(km);
        xkb.xkb_state_unref(self.state);
        xkb.xkb_keymap_unref(self.keymap);
        self.state = st;
        self.keymap = km;
        self.keysym_by_keycode = new_table;
    }

    /// Convert an X11 keycode to a keysym for keybinding dispatch.
    /// Uses the level-0 (lock-free) table so results are unaffected by
    /// NumLock / CapsLock / ScrollLock state.
    pub inline fn keycodeToKeysym(self: *const XkbState, keycode: u8) u32 {
        return self.keysym_by_keycode[keycode];
    }

/// Reverse-look up a keysym to its keycode (config parsing only). Scans the
/// flat table (248 entries, all in L1 cache).
///
/// The table holds level-0 symbols, so a Shift-only keysym — e.g. `@` on a
/// US layout — resolves to null; callers should warn, since such a binding
/// cannot be grabbed.
    pub inline fn keysymToKeycode(self: *const XkbState, keysym: u32) ?u8 {
        for (8..256) |kc| {
            if (self.keysym_by_keycode[kc] == keysym) return @intCast(kc);
        }
        return null;
    }
};

/// Base (level-0) symbol for `kc`, independent of lock state — reads the
/// keymap's level-0 entry directly rather than the live xkb_state, whose
/// `get_one_sym` resolves under current locks (a CapsLock held at startup
/// would pin the table to shifted symbols and break lowercase bindings).
inline fn baseSymbol(km: *xkb_keymap, kc: u8) u32 {
    var syms: [*c]const u32 = null;
    const n = xkb.xkb_keymap_key_get_syms_by_level(km, @intCast(kc), 0, 0, &syms);
    if (n > 0 and syms != null) return syms[0];
    return xkb.XKB_KEY_NoSymbol;
}

/// Builds the flat keycode→keysym table from level-0 symbols.
/// Keycodes below 8 are reserved by X11 and produce no real keysym.
fn buildKeysymTable(km: *xkb_keymap) [256]u32 {
    var table: [256]u32 = [_]u32{xkb.XKB_KEY_NoSymbol} ** 256;
    for (8..256) |kc| {
        table[kc] = baseSymbol(km, @intCast(kc));
    }
    return table;
}

/// Renders a keysym to its XKB name (e.g. XKB_KEY_at -> "at") into `buf`,
/// returning a slice of `buf` holding the name. Used for diagnostic messages.
pub fn keysymGetName(keysym: u32, buf: []u8) []const u8 {
    if (buf.len == 0) return "";
    const n = xkb.xkb_keysym_get_name(keysym, @ptrCast(buf.ptr), buf.len);
    const len: usize = if (n < 0) 0 else @min(@as(usize, @intCast(n)), buf.len);
    return buf[0..len];
}

const XKB_RETRY_DELAY_MS = constants.XKB_RETRY_DELAY_MS;

/// Sleeps between retry attempts (skipped on the final one). Uses nanosleep
/// directly — std.time.sleep is absent in this Zig build. Resumes on EINTR
/// (the WM's SIGCHLD handler can interrupt the sleep) so a signal doesn't
/// shorten the delay.
inline fn retryDelay(attempt: u8) void {
    if (attempt >= MAX_ATTEMPTS - 1) return;
    const ns = XKB_RETRY_DELAY_MS * std.time.ns_per_ms;
    var req = std.os.linux.timespec{ .sec = @intCast(ns / std.time.ns_per_s), .nsec = @intCast(ns % std.time.ns_per_s) };
    var rem = std.os.linux.timespec{ .sec = 0, .nsec = 0 };
    while (true) {
        const rc = std.os.linux.nanosleep(&req, &rem);
        if (std.posix.errno(rc) != .INTR) break;
        // Signal interrupted the sleep — resume for the remaining time.
        req = rem;
    }
}

// retrySetup, retryDeviceId, and retryKeymap share a retry-loop shape but
// differ in return type (!void vs !i32 vs !*xkb_keymap), so they're separate.

/// Calls xkb_x11_setup_xkb_extension, retrying up to MAX_ATTEMPTS times.
/// The extension may not be ready immediately at WM startup.
fn retrySetup(xcb_conn: *anyopaque) !void {
    for (0..MAX_ATTEMPTS) |i| {
        const ok = xkb.xkb_x11_setup_xkb_extension(
            @ptrCast(xcb_conn),
            xkb.XKB_X11_MIN_MAJOR_XKB_VERSION,
            xkb.XKB_X11_MIN_MINOR_XKB_VERSION,
            xkb.XKB_X11_SETUP_XKB_EXTENSION_NO_FLAGS,
            null,
            null,
            null,
            null,
        );
        if (ok != 0) return;
        retryDelay(@intCast(i));
    }
    return error.XkbSetupFailed;
}

/// Calls xkb_x11_get_core_keyboard_device_id, retrying up to MAX_ATTEMPTS
/// times — the core keyboard device may not be enumerable yet in the same
/// early-startup window retrySetup guards against.
fn retryDeviceId(xcb_conn: *anyopaque) !i32 {
    for (0..MAX_ATTEMPTS) |i| {
        const device_id = xkb.xkb_x11_get_core_keyboard_device_id(@ptrCast(xcb_conn));
        if (device_id != -1) return device_id;
        retryDelay(@intCast(i));
    }
    return error.XkbNoKeyboard;
}

/// Minimum reachable keysyms in 8..128 for a keymap to count as populated.
/// A healthy keymap has 100+; 40 accepts minimal/embedded keymaps while
/// still rejecting the empty keymap a not-yet-ready XKB returns at startup.
const MIN_KEYMAP_SYMBOLS: u32 = 40;

/// Returns true if `km` has at least MIN_KEYMAP_SYMBOLS reachable keysyms in the 8..128 range.
/// Guards against accepting a partially-initialised keymap on early startup.
fn keymapHasEnoughSymbols(km: *xkb_keymap) bool {
    const test_state = xkb.xkb_state_new(km) orelse return false;
    defer xkb.xkb_state_unref(test_state);
    var valid_keys: u32 = 0;
    for (8..128) |kc| {
        if (xkb.xkb_state_key_get_one_sym(test_state, @intCast(kc)) != xkb.XKB_KEY_NoSymbol)
            valid_keys += 1;
    }
    return valid_keys >= MIN_KEYMAP_SYMBOLS;
}

/// Retries keymap creation up to MAX_ATTEMPTS times, accepting only a
/// sufficiently populated keymap to guard against early-startup races.
fn retryKeymap(ctx: *xkb_context, xcb_conn: *anyopaque, device_id: i32) !*xkb_keymap {
    for (0..MAX_ATTEMPTS) |i| {
        const km = xkb.xkb_x11_keymap_new_from_device(
            ctx,
            @ptrCast(xcb_conn),
            device_id,
            xkb.XKB_KEYMAP_COMPILE_NO_FLAGS,
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
