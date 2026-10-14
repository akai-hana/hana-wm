//! XKB keyboard state: the live keycode->keysym table, its construction from
//! the server's keymap, and the one-shot XKB extension negotiation that
//! makes the table possible. Absorbs xkbcommon.zig plus the state variable
//! and lifecycle functions input.zig used to hold.
//!
//! This is the lowest layer of src/core/input: it depends on nothing else in
//! the directory (only `keymap`, the connection-free table vocabulary), so
//! everything above it -- keybinds, keys, dispatch -- can read the live
//! keyboard without any of them reaching back.
const std = @import("std");

const core = @import("core");

const log = @import("log");

// Single @cImport owner for libxkbcommon lives in keymap.zig: the same two
// headers were translated once here and once in keysyms.zig (since merged
// into keymap), giving two translation units to keep in sync for no benefit.
const keymap = @import("keymap");
const xkb = keymap.xkb;

const xkb_context = keymap.xkb_context;

// ---------------------------------------------------------------------------
// Module-owned XKB state (from input.zig).
// ---------------------------------------------------------------------------

var xkb_state: ?XkbState = null;

/// Initialises the XKB context, keymap, and key state
/// from the server's current keyboard configuration.
pub fn initXkb(conn: core.Connection) !void {
    xkb_state = try XkbState.init(conn);
}

/// Tears down XKB state. Must be called after all other deinit steps.
pub fn deinitXkb() void {
    if (xkb_state) |*s| s.deinit();
    xkb_state = null;
}

/// Returns a read-only view of the module-owned XkbState, or null only at boot
/// before initXkb has run and at shutdown after deinitXkb (there is no reload
/// window; see the reload path in config/reload.zig). The pointer is invalidated by
/// deinitXkb and must not be cached across it.
///
/// Const, deliberately. Zig has no private fields, so a struct's fields are
/// reachable by anyone holding a pointer to it -- which made the live
/// keycode->keysym table and the reverse index a mutation surface: any module
/// could overwrite a key's keysym or truncate the index, and the dispatch path
/// would read the damage with no way to tell it from a real mapping. Handing
/// out `*const` closes every field but one: `rebuild`, which this module calls
/// below and which rebuilds both tables as a unit.
pub fn getXkbState() ?*const XkbState {
    return if (xkb_state) |*s| s else null;
}

/// The one mutable handle on the XKB state, kept inside this module: the
/// mapping-change path needs to replace the tables, and nothing else does.
fn getXkbStateMut() ?*XkbState {
    return if (xkb_state) |*s| s else null;
}

/// Rebuilds the keycode->keysym table after the server changes the keyboard
/// mapping (setxkbmap/xmodmap). `keyboard` is the event's `request` field
/// narrowed to MappingKeyboard; false for the modifier-map and pointer
/// mapping events that arrive through the same type, which are ignored.
/// Keybind resolution is keysym-indexed, so rebuilding the flat keycode->keysym
/// table keeps existing bindings working under the new layout.
///
/// Returns true when the table was actually rebuilt, i.e. when the keycodes
/// may have moved under the caller and everything derived from them (the key
/// grabs, the compiled bind list) is now stale. Returns false for the
/// modifier-map and pointer-button remaps that arrive through the same
/// event: those are common (`xmodmap` touches both), and rebuilding for them
/// threw away working state and made the user pay a full ungrab/regrab storm
/// over a change that cannot have affected any binding. The modifier map is
/// not part of the keycode->keysym table, and button remapping is the
/// client's own business.
///
/// This is deliberately the XKB HALF only. Re-resolving the compiled binds
/// from the new table belongs to `keybinds.handleMappingNotify`, which calls
/// this; making the composite live here would put a keybinds -> xkb ->
/// keybinds import cycle back into the directory this refactor exists to
/// make acyclic.
pub fn rebuildKeymap(keyboard: bool) bool {
    if (!keyboard) return false;
    const state = getXkbStateMut() orelse return false;
    state.rebuild(core.getState().conn);
    return true;
}

// ---------------------------------------------------------------------------
// XKB state, retry ladder, and detectable auto-repeat (from xkbcommon.zig).
// ---------------------------------------------------------------------------
/// The XKB setup requests are sent once after setup; these retries cover the
/// surrounding early-startup negotiation (xkb_x11_setup_xkb_extension,
/// get_core_keyboard_device_id, keymap creation), while the X server is still
/// being established.
const max_xkb_retries: u8 = 3;

/// Delay between those retries. Short enough to be imperceptible, long enough
/// to avoid busy-spinning while XKB initialises (~1 polling cycle at 50 Hz).
const xkb_retry_delay_ms: u64 = 20;

/// Detectable auto-repeat: the server emits a held key's repeat as KeyPress
/// events WITHOUT the deactivating KeyRelease X11's default autorepeat elides
/// between them. Without it a held binding key flaps between do/undo of a
/// toggle action every repeat. Set via XkbPerClientFlags (minor opcode 21):
/// there is no XkbSetDetectableAutoRepeat request — the old hand-marshalled
/// minor opcode 34 does not exist, so the feature was silently never enabled.
const xkb_detectable_auto_repeat_mask: u32 = 1; // XkbPCF_DetectableAutoRepeatMask

/// Enables detectable auto-repeat on the XKB core device. Must be called after
/// the XKB extension is negotiated (xkb_x11_setup_xkb_extension) and the
/// extension opcode is discoverable via xcb_get_extension_data. Best-effort: a
/// failure to look up the opcode or to send the request is logged and ignored —
/// the WM still functions, it just reverts to the flappy autorepeat behaviour
/// this is meant to eliminate.
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
    /// Flat keycode->keysym table for the standard X11 range (indices 0..255).
    /// Populated at init time; entries outside 8..255 hold XKB_KEY_NoSymbol.
    /// No allocator needed; 256 x 4 bytes = 1 KiB, lives inside XkbState.
    keysym_by_keycode: [keymap.x11_max_keycode]u32,
    /// Reverse index over the same table, sorted by keysym. Held as one value
    /// (not a bare array plus a separate count) so the pair can never be
    /// updated apart -- `len` is how many entries are live, and the rest of
    /// the array is uninitialized.
    reverse: keymap.ReverseIndex,

    /// Initialises an XKB context and builds the keysym table from the live
    /// X connection. Retries up to max_xkb_retries times to handle early-startup
    /// races.
    ///
    /// No xkb_state/keymap handles are retained: dispatch resolves from the
    /// flat table by design, so (CapsLock at startup aside) lock state cannot
    /// pin shifted symbols.
    pub fn init(xcb_conn: core.Connection) !XkbState {
        const ctx = xkb.xkb_context_new(xkb.XKB_CONTEXT_NO_FLAGS) orelse
            return error.XkbContextFailed;
        errdefer xkb.xkb_context_unref(ctx);

        try retrySetup(xcb_conn);

        // Enable detectable auto-repeat after the XKB extension is negotiated.
        // See the note on `xkb_detectable_auto_repeat_mask` above for why this
        // is required for correct held-key repeat handling.
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
    /// (setxkbmap/xmodmap -> XCB_MAPPING_NOTIFY); dispatch resolves keysyms
    /// from it, so it must track the new mapping or bindings silently stop
    /// matching. On failure the old mapping is kept. Caller must be on the
    /// main thread; it runs inside the event loop and makes exactly one
    /// keymap attempt: the opposite of `init`'s retry ladder. The server has
    /// just told us the keyboard changed, so the new keymap is already there
    /// and retries would only add `retryDelay` sleeps in front of every other
    /// event the batch carried, on a path an `xmodmap` can trigger at any
    /// time. A failure here is a logged one-line miss on a table that is
    /// still serving the previous mapping.
    pub fn rebuild(self: *XkbState, xcb_conn: core.Connection) void {
        const device_id = xkb.xkb_x11_get_core_keyboard_device_id(@ptrCast(xcb_conn));
        if (device_id == -1) {
            // The core keyboard can be absent (a headless or purely virtual
            // X server). Returning silently here made a missing device
            // indistinguishable from a device that simply had nothing to
            // rebuild, which is exactly the kind of failure that reads as
            // "my keybinds stopped working after xmodmap".
            log.warn("XKB: no core keyboard device id; keymap not rebuilt after mapping change", .{});
            return;
        }
        // Table swapped only after the new keymap built successfully, so a
        // failed rebuild leaves dispatch fully functional on the old mapping.
        const table = keymapOnce(keymapOnceArgs{ .ctx = self.context, .conn = xcb_conn, .device_id = device_id }) orelse {
            log.warn("XKB: keymap rebuild failed after mapping change; keeping old mapping", .{});
            return;
        };
        self.keysym_by_keycode = table;
        const built = keymap.buildReverseIndex(table);
        self.reverse = built;
    }

    /// Returns the level-0 keysym for `keycode`, unaffected by lock modifiers
    /// (NumLock, CapsLock, ScrollLock). The flat table is indexed by raw keycode.
    pub inline fn keycodeToKeysym(self: *const XkbState, keycode: u8) u32 {
        return self.keysym_by_keycode[keycode];
    }

    /// Reverse-look up a keysym to its keycode: bisects the reverse index
    /// built over the flat table. Serves config parsing AND the live grab
    /// path (resolveKeycodes), not config alone.
    ///
    /// The table holds level-0 symbols, so a Shift-only keysym (e.g. `@`) can
    /// resolve to null; callers should warn, since such a binding cannot be
    /// grabbed. Returns only the first keycode when several map to the keysym.
    pub inline fn keysymToKeycode(self: *const XkbState, keysym: u32) ?u8 {
        return self.reverse.find(keysym);
    }
};

/// Sleeps between retry attempts (skipped on the final one). Uses nanosleep
/// directly; std.time.sleep is absent in this Zig build. Resumes on EINTR
/// (the WM's SIGCHLD handler can interrupt the sleep) so a signal doesn't
/// shorten the delay.
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
/// `attempt(args)` up to max_xkb_retries times with `retryDelay` between
/// tries, accepting the first non-null result and falling back to `failure`
/// when every try fails. Each probe reports its own "not ready yet" as null.
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

/// Retries xkb_x11_setup_xkb_extension up to max_xkb_retries times; the
/// extension may not be ready immediately at WM startup.
fn retrySetup(xcb_conn: core.Connection) !void {
    _ = try withRetries(void, xcb_conn, setupOnce, error.XkbSetupFailed);
}

fn deviceOnce(conn: core.Connection) ?i32 {
    const device_id = xkb.xkb_x11_get_core_keyboard_device_id(@ptrCast(conn));
    return if (device_id == -1) null else device_id;
}

/// Retries xkb_x11_get_core_keyboard_device_id up to max_xkb_retries times;
/// the core keyboard device may not be enumerable yet in the same
/// early-startup window retrySetup guards against.
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

/// Retries keymap creation up to max_xkb_retries times, accepting only a
/// sufficiently populated keymap to guard against early-startup races.
fn retryKeymap(ctx: *xkb_context, conn: core.Connection, device_id: i32) ![keymap.x11_max_keycode]u32 {
    return withRetries(
        [keymap.x11_max_keycode]u32,
        keymapOnceArgs{ .ctx = ctx, .conn = conn, .device_id = device_id },
        keymapOnce,
        error.XkbKeymapFailed,
    );
}
