//! Root-window grab installation: the keybinding grabs
//! (`grabKeybindings`) and the Super+Button mouse grabs
//! (`grabMouseButtons`), split out of events.zig (review
//! 05-input round 2). Both are lifecycle concerns -- installed
//! once at boot, reinstalled on config reload and on a
//! keyboard-mapping change -- not per-event path work, so they
//! live apart from the event loop, beside the input layer whose
//! resolved keybind list they read (and, for the button set, beside the
//! reachability rule in keybind.zig that judges against it).

const std = @import("std");

const core = @import("core");
const xcb = core.xcb;
const masks = @import("masks");
const keybind = @import("keybind");
const log = @import("log");
const input = @import("input");

/// Upper bound for the XCB cookie scratch buffer in grabKeybindings
/// (max distinct keybindings x lock_modifiers.len combinations).
/// Raise if you ever exceed 128 keybindings.
const max_keybind_cookies = 1024;

const CookieEntry = struct { cookie: xcb.xcb_void_cookie_t, keycode: u8 };

fn fillGrabCookies(cookies: []CookieEntry) usize {
    var n: usize = 0;
    const cs = core.getState();
    // The compiled list, not cs.config.keybindings: keycodes are derived from
    // the live keyboard and deliberately not stored in config.
    for (input.resolvedKeybinds()) |kb| {
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

fn checkGrabCookies(cookies: []const CookieEntry) usize {
    var failed: usize = 0;
    const conn = core.getState().conn;
    for (cookies) |entry| {
        if (xcb.xcb_request_check(conn, entry.cookie)) |err| {
            std.c.free(err);
            log.warn("Failed to grab keycode: {}", .{entry.keycode});
            failed += 1;
        }
    }
    return failed;
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
    var grabs: [keybind.mouse_grab_buttons.len * masks.lock_modifiers.len]MouseGrab = undefined;
    var n: usize = 0;
    for (keybind.mouse_grab_buttons) |button| {
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
    var failed: usize = 0;
    for (grabs[0..n]) |grab| {
        if (xcb.xcb_request_check(cs.conn, grab.cookie)) |err| {
            std.c.free(err);
            failed += 1;
            if (failed <= 4) log.warn(
                "Failed to grab Super+Button{d}{s} on the root window; " ++
                    "another client is holding it, so that mouse binding will not fire",
                .{ grab.label.button, if (grab.label.lock == 0) "" else " (with a lock modifier held)" },
            );
        }
    }
    if (failed > 4) log.warn("{} further mouse grab(s) failed", .{failed - 4});
    _ = xcb.xcb_flush(cs.conn);
}

/// Ungrabs all keys, then re-grabs every configured keybinding across all
/// lock modifier combinations. Fires all grab cookies before reading any
/// reply to reduce round-trips.
pub fn grabKeybindings() void {
    const cs = core.getState();
    _ = xcb.xcb_ungrab_key(cs.conn, xcb.XCB_GRAB_ANY, cs.root, xcb.XCB_MOD_MASK_ANY);

    var cookies: [max_keybind_cookies]CookieEntry = undefined;
    const n = fillGrabCookies(&cookies);

    const failed = checkGrabCookies(cookies[0..n]);
    if (failed > 0) log.warn("{} keybinding(s) failed to grab", .{failed});

    _ = xcb.xcb_flush(cs.conn);
}
