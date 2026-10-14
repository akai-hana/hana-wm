//! Root-window grab installation: the keybinding grabs
//! (`grabKeybindings`) and the Super+Button mouse grabs
//! (`grabMouseButtons`), split out of events.zig (review
//! 05-input round 2). Both are lifecycle concerns -- installed
//! once at boot, reinstalled on config reload and on a
//! keyboard-mapping change -- not per-event path work, so they
//! live apart from the event loop, beside the input layer. The resolved
//! keybind list is handed in by each caller (so grabs never imports input,
//! which keeps mouse -> grabs -> input cycles impossible), and the button
//! set's spec and reachability rule live here next to the grab using them.

const std = @import("std");

const core = @import("core");
const xcb = core.xcb;
const masks = @import("masks");
const keybind = @import("keybind");
const constants = @import("constants");
const types = @import("types");
const log = @import("log");

/// Upper bound for the XCB cookie scratch buffer in grabKeybindings
/// (max distinct keybindings x lock_modifiers.len combinations).
/// Raise if you ever exceed 128 keybindings.
const max_keybind_cookies = 1024;

const CookieEntry = struct { cookie: xcb.xcb_void_cookie_t, keycode: u8 };

/// Failures detail-logged individually before the "N further ..." tail.
const cap_detail: usize = 4;

/// One grab-failure log policy for both grab paths: name the first
/// `cap_detail` failures, then summarize the rest in one line.
const FailureReporter = struct {
    failed: usize = 0,

    /// Count a failure; true = the caller should log this one individually.
    fn detail(self: *FailureReporter) bool {
        self.failed += 1;
        return self.failed <= cap_detail;
    }

    /// The "N further ..." tail, emitted only when anything was capped.
    fn tail(self: *const FailureReporter, comptime what: []const u8) void {
        if (self.failed > cap_detail)
            log.warn("{} further {s} failed", .{ self.failed - cap_detail, what });
    }
};

fn fillGrabCookies(cookies: []CookieEntry, resolved: []const keybind.ResolvedBind) usize {
    var n: usize = 0;
    const cs = core.getState();
    // The compiled list handed in by the caller, not cs.config.keybindings:
    // keycodes are derived from the live keyboard and deliberately not stored
    // in config.
    for (resolved) |kb| {
        const keycode = kb.keycode orelse continue;

        // Check once per keybinding that the full lock-modifier set fits.
        // Avoids a per-lock branch and prevents partial grabs if the buffer is nearly full.
        if (n + masks.lock_modifiers.len > cookies.len) {
            log.warn(
                "Too many keybindings. Increase max_keybind_cookies (currently {})",
                .{max_keybind_cookies},
            );
            break;
        }

        for (masks.lock_modifiers) |lock| {
            cookies[n] = .{
                .cookie = xcb.xcb_grab_key_checked(
                    cs.conn,
                    0,
                    cs.root,
                    @intCast(kb.modifiers | lock),
                    keycode,
                    xcb.XCB_GRAB_MODE_ASYNC,
                    xcb.XCB_GRAB_MODE_ASYNC,
                ),
                .keycode = keycode,
            };
            n += 1;
        }
    }
    return n;
}

fn checkGrabCookies(cookies: []const CookieEntry) void {
    const conn = core.getState().conn;
    var reporter: FailureReporter = .{};
    for (cookies) |entry| {
        if (xcb.xcb_request_check(conn, entry.cookie)) |err| {
            std.c.free(err);
            if (reporter.detail()) log.warn("Failed to grab keycode: {}", .{entry.keycode});
        }
    }
    reporter.tail("keybinding grab");
}

/// The root-window mouse grab, as data. `mouse.zig` builds this from the very
/// tables `grabMouseButtons` iterates, so the grab and the reachability rule
/// cannot drift apart; the rule below stays pure (config in, reason out) and
/// unit-testable without an X server.
pub const MouseGrabSpec = struct {
    /// Button numbers the grab covers.
    buttons: []const u8,
    /// The non-lock modifier the grab is taken with (Super).
    modifiers: u16,
    /// Lock bits, which the grab takes in every combination and which
    /// `normalizeModifiers` masks off before dispatch -- so they can neither
    /// make a bind reachable nor unreachable.
    lock_bits: u16,
};

/// The buttons the root mouse grab covers, in grab order: the table
/// `grabMouseButtons` fires, the spec `mouse.zig`'s report builds, and the
/// reachability rule below judges -- one home so all three cannot drift.
pub const mouse_grab_buttons = [_]u8{
    constants.mouse_button_left,
    constants.mouse_button_middle,
    constants.mouse_button_right,
    constants.mouse_button_scroll_up,
    constants.mouse_button_scroll_down,
};

/// Why `mb` can never be delivered by `grab`, or null when it can.
///
/// The two unreachable shapes, both of which parse cleanly and then do
/// nothing: a button the grab does not cover (a bare Button1 click is delivered
/// to the client, so the WM never sees it), and a modifier the grab does not
/// take (Super+Shift+Button1 is never grabbed, and the dispatcher compares
/// modifiers exactly). This is the worst failure mode a config surface has --
/// the bind loads, the config looks valid, the key does nothing -- so it is
/// reported rather than left to be discovered by pressing the combo.
pub fn undeliverableMouseBindReason(mb: types.MouseBind, grab: MouseGrabSpec) ?[]const u8 {
    if (std.mem.indexOfScalar(u8, grab.buttons, mb.button) == null) {
        return "the root grab covers Button1-5 only";
    }
    if (mb.modifiers & ~grab.lock_bits & ~grab.modifiers != 0)
        return "the root grab is taken with Super+Button only, with no other modifier";
    if (mb.modifiers & grab.modifiers == 0)
        return "the root grab is taken with Super held";
    return null;
}

/// The label that names a mouse grab in a failure message.
const MouseGrabLabel = struct { button: u8, lock: u16 };

/// One fired mouse-grab request with its failure label. The AoS pair for the
/// two parallel arrays (cookies + labels, same length, same index) this
/// replaces -- the key path already stored its cookie with its keycode the
/// same way (`CookieEntry`), and a label that travelled separately could
/// desynchronize from its cookie only by a range-slice typo.
const MouseGrab = struct {
    cookie: xcb.xcb_void_cookie_t,
    label: MouseGrabLabel,
};

/// Grabs Super+Button{1,2,3,4,5} (including the scroll buttons) on the root
/// window for every lock-modifier combination, checking each one.
///
/// Lives beside `grabKeybindings` and uses its discipline on purpose. This
/// used to fire forty unverified grabs in the input layer: a grab that failed
/// (another client already holds Super+Button1 -- a screenshot tool, a
/// keymap tool, or the WM that was here before) was indistinguishable from one
/// that succeeded, so the mouse binds silently stopped firing with nothing on
/// stderr to say why. Each failure now names the button and modifier that did
/// not take.
pub fn grabMouseButtons() void {
    const cs = core.getState();
    var grabs: [mouse_grab_buttons.len * masks.lock_modifiers.len]MouseGrab = undefined;
    var n: usize = 0;
    for (mouse_grab_buttons) |button| {
        for (masks.lock_modifiers) |lock| {
            grabs[n] = .{
                .cookie = xcb.xcb_grab_button(
                    cs.conn,
                    0,
                    cs.root,
                    xcb.XCB_EVENT_MASK_BUTTON_PRESS |
                        xcb.XCB_EVENT_MASK_BUTTON_RELEASE |
                        xcb.XCB_EVENT_MASK_POINTER_MOTION,
                    xcb.XCB_GRAB_MODE_SYNC,
                    xcb.XCB_GRAB_MODE_SYNC,
                    cs.root,
                    xcb.XCB_NONE,
                    button,
                    @intCast(masks.mod_super | lock),
                ),
                .label = .{ .button = button, .lock = lock },
            };
            n += 1;
        }
    }
    // Fire every cookie before reading any reply, the same round-trip
    // discipline as the key grabs.
    var reporter: FailureReporter = .{};
    for (grabs[0..n]) |grab| {
        if (xcb.xcb_request_check(cs.conn, grab.cookie)) |err| {
            std.c.free(err);
            if (reporter.detail()) log.warn(
                "Failed to grab Super+Button{d}{s} on the root window; " ++
                    "another client is holding it, so that mouse binding will not fire",
                .{ grab.label.button, if (grab.label.lock == 0) "" else " (with a lock modifier held)" },
            );
        }
    }
    reporter.tail("mouse grab");
    _ = xcb.xcb_flush(cs.conn);
}

/// Ungrabs all keys, then re-grabs every configured keybinding across all
/// lock modifier combinations. Fires all grab cookies before reading any
/// reply to reduce round-trips. `resolved` is the caller's snapshot from
/// `input.resolvedKeybinds()`; taking it as an argument is what lets this
/// file stay free of the input import.
pub fn grabKeybindings(resolved: []const keybind.ResolvedBind) void {
    const cs = core.getState();
    _ = xcb.xcb_ungrab_key(cs.conn, xcb.XCB_GRAB_ANY, cs.root, xcb.XCB_MOD_MASK_ANY);

    var cookies: [max_keybind_cookies]CookieEntry = undefined;
    const n = fillGrabCookies(&cookies, resolved);

    checkGrabCookies(cookies[0..n]);

    _ = xcb.xcb_flush(cs.conn);
}
