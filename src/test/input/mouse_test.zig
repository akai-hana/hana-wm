//! Unit tests for the mouse press-classification rule (`classifyMousePress`),
//! the pure routing function the X-facing dispatch cannot be exercised
//! without a live grab. The ORDER pinned here is the whole contract:
//! scroll binds precede the managed-window guard; focus precedes the bind
//! lookup; drag and replay are both "Super and unbound", told apart by the
//! button number only.

const std = @import("std");
const testing = std.testing;

const mouse = @import("mouse");
const constants = @import("constants");

const intent = mouse.MouseIntent;

fn classify(super_held: bool, button: u8, target_managed: bool, bind_fired: bool) mouse.MouseIntent {
    return mouse.classifyMousePress(.{
        .super_held = super_held,
        .button = button,
        .target_managed = target_managed,
        .bind_fired = bind_fired,
    });
}

test "scroll binds precede the managed-window guard (fire over desktop and bar)" {
    // Super+wheel, unbound: the viewport-bind intent even on the root.
    try testing.expectEqual(intent.scroll_bind, classify(true, constants.mouse_button_scroll_up, false, false));
    try testing.expectEqual(intent.scroll_bind, classify(true, constants.mouse_button_scroll_down, false, false));
    // ...and the same over a managed window: wheel is never a click or drag.
    try testing.expectEqual(intent.scroll_bind, classify(true, constants.mouse_button_scroll_up, true, false));
}

test "a fired bind reports bound_action for every gesture, scroll included" {
    // One intent per grab outcome: a fired scroll bind is bound_action, not
    // scroll_bind, so the grab can never be released twice.
    try testing.expectEqual(intent.bound_action, classify(true, constants.mouse_button_scroll_up, false, true));
    try testing.expectEqual(intent.bound_action, classify(true, constants.mouse_button_left, true, true));
}

test "root/unmanaged presses are unmanaged (after scroll)" {
    try testing.expectEqual(intent.unmanaged, classify(false, constants.mouse_button_left, false, false));
    // Super+left on the desktop: not a drag — there is no window to drag.
    try testing.expectEqual(intent.unmanaged, classify(true, constants.mouse_button_left, false, false));
}

test "plain click on a managed window focuses (Super not held)" {
    try testing.expectEqual(intent.focus_click, classify(false, constants.mouse_button_left, true, false));
    try testing.expectEqual(intent.focus_click, classify(false, constants.mouse_button_middle, true, false));
}

test "Super+left/right on a managed unbound window starts a drag" {
    try testing.expectEqual(intent.start_drag, classify(true, constants.mouse_button_left, true, false));
    try testing.expectEqual(intent.start_drag, classify(true, constants.mouse_button_right, true, false));
}

test "Super+other-button on a managed unbound window replays (thaws the grab)" {
    // Middle is neither left nor right: the replay fallback, which is what
    // unfreezes both devices. Omitting it is a frozen pointer.
    try testing.expectEqual(intent.replay, classify(true, constants.mouse_button_middle, true, false));
}
