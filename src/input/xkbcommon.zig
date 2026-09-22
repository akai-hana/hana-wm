//! XKB bindings and keyboard state
//! Wraps the XKB library to provide keyboard state tracking and keysym resolution.

const std = @import("std");

const constants = @import("constants");
const debug = @import("debug");
const core = @import("core");

const xkb = @cImport({
    @cInclude("xkbcommon/xkbcommon.h");
    @cInclude("xkbcommon/xkbcommon-x11.h");
});

const xkb_context = xkb.struct_xkb_context;
const xkb_keymap = xkb.struct_xkb_keymap;

/// The XKB setup requests are sent once after setup; these retries cover the
/// surrounding early-startup negotiation (xkb_x11_setup_xkb_extension,
/// get_core_keyboard_device_id, keymap creation), while the X server is still
/// being established.
const max_xkb_retries: u8 = 3;

/// Detectable auto-repeat. Enabling it makes the server emit a held key's
/// repeat as repeated KeyPress events WITHOUT the interleaved, deactivating
/// KeyRelease that X11's default autorepeat produces on every cycle. With it,
/// a held binding key re-fires its action cleanly: every repeat is a fresh
/// KeyPress dispatched as a normal press. Without it, each autorepeat cycle
/// interleaves a deactivating KeyRelease, so holding e.g. Super+1 flaps
/// between the do/undo of a toggle action every repeat. Detectable auto-repeat
/// turns the hold into steady, single-sided signalling.
///
/// Set through XkbPerClientFlags (minor opcode 21), the request the XKB
/// protocol actually defines for this. There is no XkbSetDetectableAutoRepeat
/// request: the old hand-marshalled minor opcode 34 does not exist, so the
/// feature was silently never enabled.
const xkb_detectable_auto_repeat_mask: u32 = 1; // XkbPCF_DetectableAutoRepeatMask

/// Enables detectable auto-repeat on the XKB core device. Must be called after
/// the XKB extension is negotiated (xkb_x11_setup_xkb_extension) and the
/// extension opcode is discoverable via xcb_get_extension_data. Best-effort: a
/// failure to look up the opcode or to send the request is logged and ignored —
/// the WM still functions, it just reverts to the flappy autorepeat behaviour
/// this is meant to eliminate.
fn enableDetectableAutoRepeat(conn: *anyopaque) void {
    const c = core.xcb;

    const xconn: ?*c.struct_xcb_connection_t = @ptrCast(@alignCast(conn));
    const ext = c.xcb_get_extension_data(xconn, &c.xcb_xkb_id) orelse {
        debug.warn("XKB: extension data unavailable; detectable auto-repeat not enabled", .{});
        return;
    };
    if (ext.*.present == 0) {
        debug.warn("XKB: extension not present; detectable auto-repeat not enabled", .{});
        return;
    }

    // XkbUseCoreKbd = 0x0100 selects the core keyboard device.
    const xkb_use_core_kbd: c.xcb_xkb_device_spec_t = 0x0100;
    const cookie = c.xcb_xkb_per_client_flags(
        xconn,
        xkb_use_core_kbd,
        xkb_detectable_auto_repeat_mask, // change
        xkb_detectable_auto_repeat_mask, // value: enable
        0, // ctrlsToChange
        0, // autoCtrls
        0, // autoCtrlsValues
    );
    if (c.xcb_xkb_per_client_flags_reply(xconn, cookie, null)) |reply| {
        defer std.c.free(reply);
        if (reply.*.supported & xkb_detectable_auto_repeat_mask != 0) {
            debug.info("XKB: detectable auto-repeat enabled", .{});
        } else {
            debug.warn("XKB: server does not support detectable auto-repeat", .{});
        }
    } else {
        debug.warn("XKB: failed to enable detectable auto-repeat", .{});
    }
}

/// Base (level-0) symbol for `kc`, independent of lock state; reads the
/// keymap's level-0 entry directly. A lock-sensitive resolve (xkb_state's
/// `get_one_sym`) would apply current locks: a CapsLock held at startup
/// would pin the table to shifted symbols and break lowercase bindings.
fn baseSymbol(km: *xkb_keymap, kc: u8) u32 {
    var syms: [*c]const u32 = undefined;
    const n = xkb.xkb_keymap_key_get_syms_by_level(km, @intCast(kc), 0, 0, &syms);
    if (n > 0) return syms[0];
    return xkb.XKB_KEY_NoSymbol;
}

/// Builds the flat keycode->keysym table from level-0 symbols.
/// Keycodes below 8 are reserved by X11 and produce no real keysym.
fn buildKeysymTable(km: *xkb_keymap) [constants.x11_max_keycode]u32 {
    var table: [constants.x11_max_keycode]u32 = [_]u32{xkb.XKB_KEY_NoSymbol} ** constants.x11_max_keycode;
    for (@as(usize, constants.x11_min_keycode)..constants.x11_max_keycode) |kc| {
        table[kc] = baseSymbol(km, @intCast(kc));
    }
    return table;
}

pub const XkbState = struct {
    context: *xkb_context,
    /// Flat keycode->keysym table for the standard X11 range (indices 0..255).
    /// Populated at init time; entries outside 8..255 hold XKB_KEY_NoSymbol.
    /// No allocator needed; 256 x 4 bytes = 1 KiB, lives inside XkbState.
    keysym_by_keycode: [constants.x11_max_keycode]u32,

    /// Initialises an XKB context and builds the keysym table from the live
    /// X connection. Retries up to max_xkb_retries times to handle early-startup
    /// races.
    ///
    /// No xkb_state/keymap handles are retained; nothing ever read them
    /// (dispatch resolves from the flat table by design, so CapsLock at
    /// startup cannot pin shifted symbols); they were write+unref-only
    /// lifecycle weight. The keymap is used transiently here and released.
    pub fn init(xcb_conn: *anyopaque) !XkbState {
        const ctx = xkb.xkb_context_new(xkb.XKB_CONTEXT_NO_FLAGS) orelse
            return error.XkbContextFailed;
        errdefer xkb.xkb_context_unref(ctx);

        try retrySetup(xcb_conn);

        // Enable detectable auto-repeat after the XKB extension is negotiated.
        // See the constants block above for why this is required for correct
        // held-key repeat handling.
        enableDetectableAutoRepeat(xcb_conn);

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
    ///
    /// Returns only the FIRST (lowest) keycode if multiple keycodes map to the
    /// same keysym (e.g. duplicate Enter keys). Dispatch is keysym-based, so
    /// pressing the other physical key would still match the binding in theory,
    /// but the X11 grab covers only the returned keycode — the other key's
    /// press goes ungrabbed and is never delivered. This is acceptable because
    /// truly symmetric multi-keycode keysyms are rare in WM bindings (modifier
    /// left/right pairs have distinct keysyms: Shift_L ≠ Shift_R, etc.).
    pub inline fn keysymToKeycode(self: *const XkbState, keysym: u32) ?u8 {
        for (@as(usize, constants.x11_min_keycode)..constants.x11_max_keycode) |kc| {
            if (self.keysym_by_keycode[kc] == keysym) return @intCast(kc);
        }
        return null;
    }
};

/// Sleeps between retry attempts (skipped on the final one). Uses nanosleep
/// directly; std.time.sleep is absent in this Zig build. Resumes on EINTR
/// (the WM's SIGCHLD handler can interrupt the sleep) so a signal doesn't
/// shorten the delay.
fn retryDelay(attempt: u8) void {
    if (attempt >= max_xkb_retries - 1) return;
    const ns = constants.xkb_retry_delay_ms * std.time.ns_per_ms;
    var req = std.os.linux.timespec{
        .sec = @intCast(ns / std.time.ns_per_s),
        .nsec = @intCast(ns % std.time.ns_per_s),
    };
    var rem = std.os.linux.timespec{ .sec = 0, .nsec = 0 };
    while (true) {
        const rc = std.os.linux.nanosleep(&req, &rem);
        if (std.posix.errno(rc) != .INTR) break;
        req = rem;
    }
}

/// Runs `op.call()` up to max_xkb_retries times, sleeping retryDelay between
/// tries, and returns the first non-null result (null = that attempt failed).
/// `op` is a value-capturing struct with a `call(self) ?T` method so each
/// retried XKB lookup passes the args its attempt needs without a closure.
/// All three retried operations (extension setup, core device id, keymap)
/// share this primitive; each caller inlines its own attempt.
fn retryPoll(comptime T: type, op: anytype) ?T {
    for (0..max_xkb_retries) |i| {
        if (op.call()) |result| return result;
        retryDelay(@intCast(i));
    }
    return null;
}

/// Retries xkb_x11_setup_xkb_extension up to max_xkb_retries times; the
/// extension may not be ready immediately at WM startup.
fn retrySetup(xcb_conn: *anyopaque) !void {
    if (retryPoll(c_int, struct {
        conn: *anyopaque,
        fn call(self: @This()) ?c_int {
            const ok = xkb.xkb_x11_setup_xkb_extension(
                @ptrCast(self.conn),
                xkb.XKB_X11_MIN_MAJOR_XKB_VERSION,
                xkb.XKB_X11_MIN_MINOR_XKB_VERSION,
                xkb.XKB_X11_SETUP_XKB_EXTENSION_NO_FLAGS,
                null,
                null,
                null,
                null,
            );
            return if (ok != 0) ok else null;
        }
    }{ .conn = xcb_conn }) == null) return error.XkbSetupFailed;
}

/// Retries xkb_x11_get_core_keyboard_device_id up to max_xkb_retries times;
/// the core keyboard device may not be enumerable yet in the same
/// early-startup window retrySetup guards against.
fn retryDeviceId(xcb_conn: *anyopaque) !i32 {
    return retryPoll(i32, struct {
        conn: *anyopaque,
        fn call(self: @This()) ?i32 {
            const device_id = xkb.xkb_x11_get_core_keyboard_device_id(@ptrCast(self.conn));
            return if (device_id != -1) device_id else null;
        }
    }{ .conn = xcb_conn }) orelse error.XkbNoKeyboard;
}

/// Minimum reachable keysyms in the health-check window for a keymap to count
/// as populated. A healthy keymap has 100+; 40 accepts minimal/embedded
/// keymaps while still rejecting the empty keymap a not-yet-ready XKB returns
/// at startup.
const min_keymap_symbols: u32 = 40;

/// Upper bound of the reachable-symbols health-check window (8..128).
const keymap_health_hi: u8 = 128;

/// Returns true if `km` has at least min_keymap_symbols reachable keysyms in the 8..128 range.
/// Guards against accepting a partially-initialised keymap on early startup.
fn keymapHasEnoughSymbols(km: *xkb_keymap) bool {
    var valid_keys: u32 = 0;
    for (constants.x11_min_keycode..keymap_health_hi) |kc| {
        if (baseSymbol(km, @intCast(kc)) != xkb.XKB_KEY_NoSymbol)
            valid_keys += 1;
    }
    return valid_keys >= min_keymap_symbols;
}

/// Retries keymap creation up to max_xkb_retries times, accepting only a
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
