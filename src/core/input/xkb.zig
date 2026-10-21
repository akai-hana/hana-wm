//! XKB keyboard state: the live keycode->keysym table, its construction from the
//! server's keymap, and the one-shot XKB extension negotiation that makes it
//! possible. The lowest layer of src/core/input -- it depends on nothing else in the
//! directory (only `keymap`, the connection-free table vocabulary), so everything
//! above (keybinds, keys, dispatch) can read the live keyboard without reaching back.
const std = @import("std");

const core = @import("core");

const log = std.log.scoped(.xkb);

/// Single @cImport owner for libxkbcommon lives in keymap.zig.
const keymap = @import("keymap");
const xkb = keymap.xkb;

const xkb_context = keymap.xkb_context;

var xkb_state: ?XkbState = null;

/// Initialises the XKB context, keymap, and key state from the server's current
/// keyboard configuration.
pub fn initXkb(conn: core.Connection) !void {
    xkb_state = try XkbState.init(conn);
}

/// Tears down XKB state. Must be called after all other deinit steps.
pub fn deinitXkb() void {
    if (xkb_state) |*s| s.deinit();
    xkb_state = null;
}

/// Read-only view of the module-owned XkbState; null only at boot before initXkb and
/// at shutdown after deinitXkb (no reload window). Invalidated by deinitXkb -- never
/// cache it across that.
///
/// Const, deliberately: Zig has no private fields, so anyone holding a pointer could
/// overwrite a key's keysym or truncate the reverse index, and dispatch would read the
/// damage as a real mapping. Handing out `*const` closes every field but `rebuild`,
/// which this module alone calls and which replaces both tables as a unit.
pub fn getXkbState() ?*const XkbState {
    return if (xkb_state) |*s| s else null;
}

/// The one mutable handle on the XKB state, kept inside this module: the
/// mapping-change path must replace the tables and nothing else does.
fn getXkbStateMut() ?*XkbState {
    return if (xkb_state) |*s| s else null;
}

/// Rebuilds the keycode->keysym table after the server changes the keyboard mapping
/// (setxkbmap/xmodmap). `keyboard` is the event's `request` field narrowed to
/// MappingKeyboard, so the modifier-map and pointer remaps sharing that type are
/// ignored. Keybind resolution is keysym-indexed, so the rebuild keeps existing
/// bindings working under the new layout.
///
/// True only when the table actually rebuilt (keycodes may have moved under the
/// caller). False for the common modifier-map/pointer-button remaps: rebuilding would
/// impose a full ungrab/regrab storm over a change that cannot affect a binding -- the
/// modifier map is not part of this table, and button remapping is the client's own
/// business.
///
/// Deliberately the XKB HALF only: re-resolving compiled binds belongs to
/// `keybinds.handleMappingNotify`, which calls this. A composite here would put a
/// keybinds -> xkb -> keybinds import cycle back into a directory laid out to stay
/// acyclic.
pub fn rebuildKeymap(keyboard: bool) bool {
    if (!keyboard) return false;
    const state = getXkbStateMut() orelse return false;
    state.rebuild(core.getState().conn);
    return true;
}

/// Retry ladder for the early-startup negotiation around XKB setup
/// (xkb_x11_setup_xkb_extension, get_core_keyboard_device_id, keymap creation) while
/// the X server is still being established. The setup requests themselves are sent
/// once.
const max_xkb_retries: u8 = 3;

/// Delay between retries: short enough to be imperceptible, long enough to avoid
/// busy-spinning while XKB initialises (~1 polling cycle at 50 Hz).
const xkb_retry_delay_ms: u64 = 20;

/// Detectable auto-repeat: the server emits a held key's repeat as KeyPress events
/// WITHOUT the deactivating KeyRelease X11's default autorepeat elides between them.
/// Without it a held binding key flaps between do/undo of a toggle action every
/// repeat. Set via XkbPerClientFlags (minor opcode 21) -- there is no
/// XkbSetDetectableAutoRepeat request, and hand-marshalling minor opcode 34 would
/// silently never enable the feature.
const xkb_detectable_auto_repeat_mask: u32 = 1; // XkbPCF_DetectableAutoRepeatMask

/// Enables detectable auto-repeat on the XKB core device. Must be called after the
/// extension is negotiated and its opcode discoverable via xcb_get_extension_data.
/// Best-effort: failures are logged and ignored -- the WM still works, it just reverts
/// to the flappy autorepeat this eliminates.
fn enableDetectableAutoRepeat(conn: core.Connection) void {
    const c = core.xcb;

    const xconn: ?*c.struct_xcb_connection_t = conn;
    const ext = c.xcb_get_extension_data(xconn, &c.xcb_xkb_id) orelse {
        log.warn("XKB: extension data unavailable; detectable auto-repeat not enabled", .{});
        return;
    };
    if (ext.*.present == 0) {
        log.warn("XKB: extension not present; detectable auto-repeat not enabled", .{});
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
            log.info("XKB: detectable auto-repeat enabled", .{});
        } else {
            log.warn("XKB: server does not support detectable auto-repeat", .{});
        }
    } else {
        log.warn("XKB: failed to enable detectable auto-repeat", .{});
    }
}

pub const XkbState = struct {
    context: *xkb_context,
    /// Flat keycode->keysym table for the standard X11 range (0..255); entries outside
    /// 8..255 hold XKB_KEY_NoSymbol. No allocator needed -- 256 x 4 bytes lives inside
    /// XkbState.
    keysym_by_keycode: [keymap.x11_max_keycode]u32,
    /// Reverse index over the same table, sorted by keysym. One value rather than a
    /// bare array plus a count so the pair can never be updated apart; `len` is the
    /// live count, the rest is uninitialized.
    reverse: keymap.ReverseIndex,

    /// Initialises an XKB context and builds the keysym table from the live X
    /// connection, retrying up to max_xkb_retries times against early-startup races.
    /// No xkb_state/keymap handles are retained: dispatch resolves from the flat table
    /// by design, so (CapsLock at startup aside) lock state cannot pin shifted symbols.
    pub fn init(xcb_conn: core.Connection) !XkbState {
        const ctx = xkb.xkb_context_new(xkb.XKB_CONTEXT_NO_FLAGS) orelse
            return error.XkbContextFailed;
        errdefer xkb.xkb_context_unref(ctx);

        try retrySetup(xcb_conn);

        // After the extension is negotiated; see `xkb_detectable_auto_repeat_mask` for
        // why correct held-key repeat handling requires this.
        enableDetectableAutoRepeat(xcb_conn);

        const device_id = try retryDeviceId(xcb_conn);

        const table = try retryKeymap(ctx, xcb_conn, device_id);
        const built = keymap.buildReverseIndex(table);
        return XkbState{
            .context = ctx,
            .keysym_by_keycode = table,
            .reverse = built,
        };
    }

    /// Releases the XKB context.
    pub fn deinit(self: *XkbState) void {
        xkb.xkb_context_unref(self.context);
    }

    /// Rebuilds the keycode->keysym table after a server-side mapping change
    /// (setxkbmap/xmodmap -> XCB_MAPPING_NOTIFY). Dispatch resolves keysyms from it, so
    /// it must track the new mapping or bindings silently stop matching; on failure the
    /// old mapping is kept. Caller must be on the main thread. Exactly ONE keymap
    /// attempt, the opposite of `init`'s retry ladder: the server just told us the
    /// keyboard changed, so the new keymap is already there and retries would only
    /// sleep `retryDelay` in front of every other event the batch carried.
    pub fn rebuild(self: *XkbState, xcb_conn: core.Connection) void {
        const device_id = xkb.xkb_x11_get_core_keyboard_device_id(@ptrCast(xcb_conn));
        if (device_id == -1) {
            // The core keyboard can be absent (headless/virtual X server). Returning
            // silently would make that indistinguishable from a device with nothing to
            // rebuild -- the failure that reads as "my keybinds stopped working after
            // xmodmap".
            log.warn("XKB: no core keyboard device id; keymap not rebuilt after mapping change", .{});
            return;
        }
        // Swap only after the new keymap built: a failed rebuild leaves dispatch fully
        // functional on the old mapping.
        const table = keymapOnce(keymapOnceArgs{ .ctx = self.context, .conn = xcb_conn, .device_id = device_id }) orelse {
            log.warn("XKB: keymap rebuild failed after mapping change; keeping old mapping", .{});
            return;
        };
        self.keysym_by_keycode = table;
        const built = keymap.buildReverseIndex(table);
        self.reverse = built;
    }

    /// Level-0 keysym for `keycode`, unaffected by lock modifiers (NumLock, CapsLock,
    /// ScrollLock); the flat table indexes by raw keycode.
    pub inline fn keycodeToKeysym(self: *const XkbState, keycode: u8) u32 {
        return self.keysym_by_keycode[keycode];
    }

    /// Reverse-lookup a keysym to its keycode via the reverse index. Serves config
    /// parsing AND the live grab path (resolveKeycodes). The table holds level-0
    /// symbols, so a Shift-only keysym (e.g. `@`) can resolve to null -- callers should
    /// warn, since such a binding cannot be grabbed. Returns only the first keycode
    /// when several map to it.
    pub inline fn keysymToKeycode(self: *const XkbState, keysym: u32) ?u8 {
        return self.reverse.find(keysym);
    }
};

/// Sleeps between retry attempts (skipped on the final one). Uses nanosleep directly
/// (std.time.sleep is absent in this Zig build) and resumes on EINTR (the WM's SIGCHLD
/// handler can interrupt it) so a signal can't shorten it.
fn retryDelay(attempt: u8) void {
    if (attempt >= max_xkb_retries - 1) return;
    const ns = xkb_retry_delay_ms * std.time.ns_per_ms;
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

/// Shared early-startup retry skeleton behind the three XKB probes: runs
/// `attempt(args)` up to max_xkb_retries times with `retryDelay` between, accepting
/// the first non-null result and falling back to `failure` when every try fails. Each
/// probe reports "not ready yet" as null.
fn withRetries(
    comptime T: type,
    args: anytype,
    comptime attempt: fn (@TypeOf(args)) ?T,
    comptime failure: anytype,
) !T {
    for (0..max_xkb_retries) |i| {
        if (attempt(args)) |result| return result;
        retryDelay(@intCast(i));
    }
    return failure;
}

fn setupOnce(conn: core.Connection) ?void {
    const ok = xkb.xkb_x11_setup_xkb_extension(
        @ptrCast(conn),
        xkb.XKB_X11_MIN_MAJOR_XKB_VERSION,
        xkb.XKB_X11_MIN_MINOR_XKB_VERSION,
        xkb.XKB_X11_SETUP_XKB_EXTENSION_NO_FLAGS,
        null,
        null,
        null,
        null,
    );
    return if (ok == 0) null else {};
}

/// Retries xkb_x11_setup_xkb_extension; the extension may not be ready immediately at
/// WM startup.
fn retrySetup(xcb_conn: core.Connection) !void {
    _ = try withRetries(void, xcb_conn, setupOnce, error.XkbSetupFailed);
}

fn deviceOnce(conn: core.Connection) ?i32 {
    const device_id = xkb.xkb_x11_get_core_keyboard_device_id(@ptrCast(conn));
    return if (device_id == -1) null else device_id;
}

/// Retries xkb_x11_get_core_keyboard_device_id; the core keyboard device may not be
/// enumerable yet in the same early-startup window retrySetup guards.
fn retryDeviceId(xcb_conn: core.Connection) !i32 {
    return withRetries(i32, xcb_conn, deviceOnce, error.XkbNoKeyboard);
}

/// Builds a fresh keysym table for the connection's current keymap.
const keymapOnceArgs = struct {
    ctx: *xkb_context,
    conn: core.Connection,
    device_id: i32,
};

fn keymapOnce(args: keymapOnceArgs) ?[keymap.x11_max_keycode]u32 {
    const km = xkb.xkb_x11_keymap_new_from_device(
        args.ctx,
        @ptrCast(args.conn),
        args.device_id,
        xkb.XKB_KEYMAP_COMPILE_NO_FLAGS,
    ) orelse return null;
    defer xkb.xkb_keymap_unref(km);
    const built = keymap.buildKeysymTable(km);
    return if (built.healthy) built.table else null;
}

/// Retries keymap creation, accepting only a sufficiently populated keymap to guard
/// against early-startup races.
fn retryKeymap(ctx: *xkb_context, conn: core.Connection, device_id: i32) ![keymap.x11_max_keycode]u32 {
    return withRetries(
        [keymap.x11_max_keycode]u32,
        keymapOnceArgs{ .ctx = ctx, .conn = conn, .device_id = device_id },
        keymapOnce,
        error.XkbKeymapFailed,
    );
}
