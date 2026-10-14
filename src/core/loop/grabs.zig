//! Root-window grab installation: the keybinding grabs
//! (`grabKeybindings`) and the Super+Button mouse grabs
//! (`grabMouseButtons`), split out of events.zig (review
//! 05-input round 2). Both are lifecycle concerns -- installed
//! once at boot, reinstalled on config reload and on a
//! keyboard-mapping change -- not per-event path work, so they
//! live apart from the event loop.

const std = @import("std");

const core = @import("core");
const xcb = core.xcb;
const masks = @import("masks");
const constants = @import("constants");
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

/// The buttons the root mouse grab covers, in grab order. Published because
/// `input.undeliverableMouseBindReason` has to judge reachability against the
/// very set that is grabbed here; one list, so the grab and the check cannot
/// disagree about which buttons can ever arrive.
pub const mouse_grab_buttons = [_]u8{
    constants.mouse_button_left,
    constants.mouse_button_middle,
    constants.mouse_button_right,
    constants.mouse_button_scroll_up,
    constants.mouse_button_scroll_down,
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
    var cookies: [mouse_grab_buttons.len * masks.lock_modifiers.len]xcb.xcb_void_cookie_t = undefined;
    var labels: [mouse_grab_buttons.len * masks.lock_modifiers.len]MouseGrabLabel = undefined;
    var n: usize = 0;
    for (mouse_grab_buttons) |button| {
        for (masks.lock_modifiers) |lock| {
            cookies[n] = xcb.xcb_grab_button(
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
            );
            labels[n] = .{ .button = button, .lock = lock };
            n += 1;
        }
    }
    // Fire every cookie before reading any reply, the same round-trip
    // discipline as the key grabs.
    var failed: usize = 0;
    for (cookies[0..n], labels[0..n]) |cookie, label| {
        if (xcb.xcb_request_check(cs.conn, cookie)) |err| {
            std.c.free(err);
            failed += 1;
            if (failed <= 4) log.warn(
                "Failed to grab Super+Button{d}{s} on the root window; " ++
                    "another client is holding it, so that mouse binding will not fire",
                .{ label.button, if (label.lock == 0) "" else " (with a lock modifier held)" },
            );
        }
    }
    if (failed > 4) log.warn("{} further mouse grab(s) failed", .{failed - 4});
    _ = xcb.xcb_flush(cs.conn);
}

const MouseGrabLabel = struct { button: u8, lock: u16 };

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
