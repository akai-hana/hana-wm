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
pub const xkb_keysym_case_insensitive = xkb.XKB_KEYSYM_CASE_INSENSITIVE;
pub const XKB_KEY_NoSymbol: u32 = xkb.XKB_KEY_NoSymbol;
pub const xkb_keysym_from_name = xkb.xkb_keysym_from_name;
const xkb_context = xkb.struct_xkb_context;
const xkb_keymap = xkb.struct_xkb_keymap;

const max_attempts: u8 = 3;

pub const XkbState = struct {
    context: *xkb_context,
    /// Flat keycode->keysym table for the standard X11 range (indices 0..255).
    /// Populated at init time; entries outside 8..255 hold XKB_KEY_NoSymbol.
    /// No allocator needed; 256 x 4 bytes = 1 KiB, lives inside XkbState.
    keysym_by_keycode: [256]u32,

    /// Initialises an XKB context and builds the keysym table from the live
    /// X connection. Retries up to max_attempts times to handle early-startup
    /// races.
    ///
    /// ND-26 (S8F5): no xkb_state/keymap handles are retained — nothing ever
    /// read them (dispatch resolves from the flat table by design, so CapsLock
    /// at startup cannot pin shifted symbols); they were write+unref-only
    /// lifecycle weight. The keymap is used transiently here and released.
    pub fn init(xcb_conn: *anyopaque) !XkbState {
        const ctx = xkb.xkb_context_new(xkb.XKB_CONTEXT_NO_FLAGS) orelse
            return error.XkbContextFailed;
        errdefer xkb.xkb_context_unref(ctx);

        try retrySetup(xcb_conn);

        const device_id = try retryDeviceId(xcb_conn);

        const km = try retryKeymap(ctx, xcb_conn, device_id);
        defer xkb.xkb_keymap_unref(km);

        return XkbState{
            .context = ctx,
            .keysym_by_keycode = buildKeysymTable(km),
        };
    }

    /// Releases the XKB context.
    pub fn deinit(self: *XkbState) void {
        xkb.xkb_context_unref(self.context);
    }

    /// Rebuilds the keysym table after a server-side mapping change
    /// (setxkbmap/xmodmap -> XCB_MAPPING_NOTIFY). Dispatch resolves keysyms
    /// from the table, so it must track the new mapping or bindings silently
    /// stop matching; on failure the old mapping is kept.
    pub fn rebuild(self: *XkbState, xcb_conn: *anyopaque) void {
        const device_id = xkb.xkb_x11_get_core_keyboard_device_id(@ptrCast(xcb_conn));
        if (device_id == -1) return;
        const km = retryKeymap(self.context, xcb_conn, device_id) catch {
            debug.warn("XKB: keymap rebuild failed after mapping change; keeping old mapping", .{});
            return;
        };
        defer xkb.xkb_keymap_unref(km);
        // Table swapped only after the new keymap built successfully, so a
        // failed rebuild leaves dispatch fully functional on the old mapping.
        self.keysym_by_keycode = buildKeysymTable(km);
    }

    /// Returns the level-0 keysym for `keycode`, unaffected by lock modifiers
    /// (NumLock, CapsLock, ScrollLock). The flat table is indexed by raw keycode.
    pub inline fn keycodeToKeysym(self: *const XkbState, keycode: u8) u32 {
        return self.keysym_by_keycode[keycode];
    }

    /// Reverse-look up a keysym to its keycode (config parsing only). Scans the
    /// flat table (248 entries, all in L1 cache).
    ///
    /// The table holds level-0 symbols, so a Shift-only keysym, e.g. `@` on a
    /// US layout, resolves to null; callers should warn, since such a binding
    /// cannot be grabbed.
    pub inline fn keysymToKeycode(self: *const XkbState, keysym: u32) ?u8 {
        for (8..256) |kc| {
            if (self.keysym_by_keycode[kc] == keysym) return @intCast(kc);
        }
        return null;
    }
};

/// Base (level-0) symbol for `kc`, independent of lock state; reads the
/// keymap's level-0 entry directly. A lock-sensitive resolve (xkb_state's
/// `get_one_sym`) would apply current locks: a CapsLock held at startup
/// would pin the table to shifted symbols and break lowercase bindings.
inline fn baseSymbol(km: *xkb_keymap, kc: u8) u32 {
    var syms: [*c]const u32 = null;
    const n = xkb.xkb_keymap_key_get_syms_by_level(km, @intCast(kc), 0, 0, &syms);
    if (n > 0 and syms != null) return syms[0];
    return xkb.XKB_KEY_NoSymbol;
}

/// Builds the flat keycode->keysym table from level-0 symbols.
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

const xkb_retry_delay_ms = constants.xkb_retry_delay_ms;

/// Sleeps between retry attempts (skipped on the final one). Uses nanosleep
/// directly; std.time.sleep is absent in this Zig build. Resumes on EINTR
/// (the WM's SIGCHLD handler can interrupt the sleep) so a signal doesn't
/// shorten the delay.
inline fn retryDelay(attempt: u8) void {
    if (attempt >= max_attempts - 1) return;
    const ns = xkb_retry_delay_ms * std.time.ns_per_ms;
    var req = std.os.linux.timespec{ .sec = @intCast(ns / std.time.ns_per_s), .nsec = @intCast(ns % std.time.ns_per_s) };
    var rem = std.os.linux.timespec{ .sec = 0, .nsec = 0 };
    while (true) {
        const rc = std.os.linux.nanosleep(&req, &rem);
        if (std.posix.errno(rc) != .INTR) break;
        req = rem;
    }
}

/// Runs `op.call()` up to max_attempts times, sleeping retryDelay between
/// tries, and returns the first non-null result (null = that attempt failed).
/// `op` is a value-capturing struct with a `call(self) ?T` method so each
/// retrying wrapper passes the args its attempt needs without a closure.
fn retryPoll(comptime T: type, op: anytype) ?T {
    for (0..max_attempts) |i| {
        if (op.call()) |result| return result;
        retryDelay(@intCast(i));
    }
    return null;
}

/// Calls xkb_x11_setup_xkb_extension, retrying up to max_attempts times.
/// The extension may not be ready immediately at WM startup.
fn retrySetup(xcb_conn: *anyopaque) !void {
    var ok: c_int = 0;
    inline for (0..max_attempts) |i| {
        ok = xkb.xkb_x11_setup_xkb_extension(
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

/// Calls xkb_x11_get_core_keyboard_device_id, retrying up to max_attempts
/// times; the core keyboard device may not be enumerable yet in the same
/// early-startup window retrySetup guards against.
fn retryDeviceId(xcb_conn: *anyopaque) !i32 {
    inline for (0..max_attempts) |i| {
        const device_id = xkb.xkb_x11_get_core_keyboard_device_id(@ptrCast(xcb_conn));
        if (device_id != -1) return device_id;
        retryDelay(@intCast(i));
    }
    return error.XkbNoKeyboard;
}

/// Minimum reachable keysyms in 8..128 for a keymap to count as populated.
/// A healthy keymap has 100+; 40 accepts minimal/embedded keymaps while
/// still rejecting the empty keymap a not-yet-ready XKB returns at startup.
const min_keymap_symbols: u32 = 40;

/// Returns true if `km` has at least min_keymap_symbols reachable keysyms in the 8..128 range.
/// Guards against accepting a partially-initialised keymap on early startup.
fn keymapHasEnoughSymbols(km: *xkb_keymap) bool {
    var valid_keys: u32 = 0;
    for (8..128) |kc| {
        if (baseSymbol(km, @intCast(kc)) != xkb.XKB_KEY_NoSymbol)
            valid_keys += 1;
    }
    return valid_keys >= min_keymap_symbols;
}

/// Retries keymap creation up to max_attempts times, accepting only a
/// sufficiently populated keymap to guard against early-startup races.
fn retryKeymap(ctx: *xkb_context, xcb_conn: *anyopaque, device_id: i32) !*xkb_keymap {
    return retryPoll(*xkb_keymap, struct {
        ctx: *xkb_context,
        conn: *anyopaque,
        device_id: i32,
        fn call(self: @This()) ?*xkb_keymap {
            const km = xkb.xkb_x11_keymap_new_from_device(
                self.ctx,
                @ptrCast(self.conn),
                self.device_id,
                xkb.XKB_KEYMAP_COMPILE_NO_FLAGS,
            ) orelse return null;
            if (keymapHasEnoughSymbols(km)) return km;
            xkb.xkb_keymap_unref(km);
            return null;
        }
    }{ .ctx = ctx, .conn = xcb_conn, .device_id = device_id }) orelse error.XkbKeymapFailed;
}
